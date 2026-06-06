# localvector

A small **Delphi / Object Pascal** command-line tool that produces **local
sentence embeddings** with **ONNX Runtime**. Give it text, get back an embedding
vector as JSON.

It uses the ONNX Runtime Pascal bindings already in this repo
(`onnxruntime.pas`, `onnxruntime_pas_api.pas`) and follows the same approach as
[FMXExpress/ONNX-Image-Tagger](https://github.com/FMXExpress/ONNX-Image-Tagger):
load `onnxruntime.dll`, build input tensors, run, read outputs.

```
localvector "The quick brown fox jumps over the lazy dog"
[0.0419,-0.0213,0.0688, ... ,0.0157]      # 384 floats

localvector --model bge "The quick brown fox jumps over the lazy dog"
[-0.1047,-0.0224,-0.0126, ... ]            # 384 floats, CLS-pooled
```

## Models

Choose one with `--model NAME` (default `minilm`). On first use the model +
vocab are downloaded into `models/<name>/` next to the executable.

| `--model` | Model | Dim | Pooling | Size | Source |
|-----------|-------|-----|---------|------|--------|
| `minilm`  | all-MiniLM-L6-v2 | 384 | mean | ~90 MB | [onnx-models/all-MiniLM-L6-v2-onnx](https://huggingface.co/onnx-models/all-MiniLM-L6-v2-onnx) |
| `bge`     | bge-small-en-v1.5 | 384 | CLS | ~133 MB | [Xenova/bge-small-en-v1.5](https://huggingface.co/Xenova/bge-small-en-v1.5) |
| `mxbai`   | mxbai-embed-large-v1 (int8) | 1024 | CLS | ~337 MB | [mixedbread-ai/mxbai-embed-large-v1](https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1) |

All three are BERT/WordPiece models (`mxbai` is the quantized int8 export).
`--pooling mean|cls|last` overrides the default.

## How it works

```
text
  -> BERT WordPiece tokenizer (vocab.txt)        LocalVector.Tokenizer
  -> input_ids / attention_mask [/ token_type_ids]
  -> ONNX Runtime inference (model.onnx)         LocalVector.Embedder
  -> last_hidden_state [1, seq, dim]
  -> pooling (mean / CLS / last) + L2 normalize
  -> float32 vector -> JSON array
```

- **Models** (`LocalVector.Models`) — a small registry: each entry knows its HF
  repo, pooling mode, dimensionality, and whether it takes `token_type_ids`.
- **Tokenizer** — a self-contained BERT (uncased) WordPiece tokenizer reading a
  plain `vocab.txt`. No regex/JSON dependencies, so it compiles under both
  Delphi and FPC.
- **Embedder** — feeds the int64 inputs, reads the **true** ONNX output shape,
  pools the token embeddings per the model's mode, and L2-normalizes. If a model
  emits an already-pooled `[1, dim]` vector, that is used directly.
- **Downloader** — on first run, fetches `model.onnx` and `vocab.txt` for the
  selected model.

## Build

### Delphi (Win64) — recommended

- IDE: open `localvector.dproj`, set the platform to **Win64**, Build.
- Command line: run `build_delphi.bat` (it calls `rsvars.bat`, then `dcc64`).

### Free Pascal

```
build_fpc.bat        # Windows
./build_fpc.sh       # Linux/macOS
```

The whole program builds and runs under FPC. It was verified end-to-end with
**FPC 3.2.2 + ONNX Runtime 1.26.0 on Linux x64**: for **both** `minilm` (mean)
and `bge` (CLS) it downloads the model, embeds text, and the output **matches the
Python reference (`transformers` + `onnxruntime`) to float precision —
cosine `1.0000`.**

To make this work, a few small, Windows-safe changes were applied to the bundled
bindings:

- `onnxruntime_pas_api.pas` — define `size_t` for FPC; **load onnxruntime
  dynamically** (`LoadOnnxRuntime`/`InitOrtApi`) instead of as a static import,
  so the program starts even when no runtime is present.
- `onnxruntime.pas` — FPC-friendly RTL unit names; `TORTSession.Create` encodes
  the model path as `char*` on POSIX (`ORTCHAR_T`), keeping `wchar_t` on
  Windows; `EnsureOrtDefaults` (re)creates the default env/options/allocator
  after the runtime is loaded; init/finalization tolerate a not-yet-loaded
  runtime.

Notes:
- FPC HTTPS downloads go through OpenSSL, so `libssl`/`libcrypto` must be
  present at runtime. On a stock FPC install you may also need the
  `rtl-generics`, `fcl-web`, `openssl`, and `paszlib` unit paths on the search
  path.
- On non-Windows you must supply a matching `onnxruntime` shared library on the
  loader path (`LD_LIBRARY_PATH` / rpath); auto-download is Windows-x64 only.

## Run

```
localvector "text to embed"
localvector --file notes.txt
localvector --diag                 # print which onnxruntime.dll loaded + version
localvector --verbose "hello"      # progress + runtime info on stderr
```

Options: `-t/--text`, `-f/--file`, `-m/--model`, `--vocab`, `--max-length N`
(default 256), `--no-normalize`, `--diag`, `-v/--verbose`, `-h/--help`,
`-V/--version`. The JSON vector is written to **stdout**; everything else goes
to **stderr**, so `localvector "x" > vec.json` is clean.

## The onnxruntime runtime (auto-provisioned)

ONNX Runtime ships inside recent Windows, but **the in-box copy is often old**.
`localvector` **loads onnxruntime dynamically** (not as a static import), so it
controls exactly which library is used:

1. If `onnxruntime.dll` sits **next to the executable**, that one is used.
2. Otherwise, on first run (Windows x64), it **downloads ONNX Runtime
   v1.26.0** from the official GitHub release and extracts `onnxruntime.dll`
   next to the exe — so you get a current runtime (IR v10 capable) without
   touching the old in-box copy.
3. Failing that, it falls back to the system loader (`PATH` / in-box DLL).

Check what actually loaded with `--diag`:

```
localvector --diag
[localvector] onnxruntime library:
[localvector]   loaded from : C:\...\Win64\Release\onnxruntime.dll
[localvector]   version     : 1.26.0
[localvector]   bindings ask: ORT_API_VERSION 10  (GetApi True)
```

On Linux/macOS there is no auto-download: provide an `onnxruntime` shared
library next to the exe or on the loader path (`LD_LIBRARY_PATH`).

### Symptom: "Unsupported model IR version"

```
onnxruntime::Model::Model Unsupported model IR version: 10, max supported IR version: 8
```

If you ever see this, an **old** runtime was loaded (max IR 8 ≈ ORT 1.12) — e.g.
an old `onnxruntime.dll` you placed next to the exe, or a system fallback when
the download was blocked. Modern HF exports are **IR v10** (needs ORT ≥ ~1.17).
Delete the stale `onnxruntime.dll` (so it re-downloads) or drop in a current one
from the [v1.26.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.26.0)
(`onnxruntime-win-x64-1.26.0.zip` → `lib\onnxruntime.dll`).

> Verified against the real ONNX Runtime **1.26.0**: `--diag` reports
> `version 1.26.0`, `GetApi(ORT_API_VERSION=10) = True`, and full embedding runs
> for all three models match the Python reference to float precision
> (cosine `1.0000`).

> **ONNX Runtime 1.22+ note:** newer runtimes no longer auto-select an
> execution provider, so `localvector` registers the **CPU EP** explicitly
> before creating the session (`OrtSessionOptionsAppendExecutionProvider_CPU`).
> Without an EP, ORT raises *"No execution providers were provided or selected."*

> The bindings request `ORT_API_VERSION = 10` (define `ONNX_NEW_VERSION` for 13).
> A *lower* request is intentionally compatible with the widest range of DLLs —
> the IR-version limit above is about the model graph, a separate thing from the
> C-API version.

## Files

| File | Purpose |
|------|---------|
| `localvector.dpr` | Program entry point |
| `src/LocalVector.App.pas` | CLI parsing, orchestration, JSON output |
| `src/LocalVector.Models.pas` | Model registry (repo, pooling, dim, inputs) |
| `src/LocalVector.OrtProvision.pas` | Dynamic runtime load + first-run onnxruntime download |
| `src/LocalVector.Tokenizer.pas` | BERT WordPiece tokenizer (vocab.txt) |
| `src/LocalVector.Embedder.pas` | ONNX inference + pooling (mean/CLS/last) + normalize |
| `src/LocalVector.Downloader.pas` | First-run model/vocab download |
| `src/LocalVector.Runtime.pas` | Reports the loaded onnxruntime DLL + version |
| `onnxruntime.pas`, `onnxruntime_pas_api.pas` | ONNX Runtime Pascal bindings |
