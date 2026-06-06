# localvector

A small **Delphi / Object Pascal** command-line tool that produces **local
sentence embeddings** with **ONNX Runtime**, using the
[`onnx-models/all-MiniLM-L6-v2-onnx`](https://huggingface.co/onnx-models/all-MiniLM-L6-v2-onnx)
model. Give it text, get back a 384-dimensional embedding vector as JSON.

It uses the ONNX Runtime Pascal bindings already in this repo
(`onnxruntime.pas`, `onnxruntime_pas_api.pas`) and follows the same approach as
[FMXExpress/ONNX-Image-Tagger](https://github.com/FMXExpress/ONNX-Image-Tagger):
load `onnxruntime.dll`, build input tensors, run, read outputs.

```
localvector "The quick brown fox jumps over the lazy dog"
[0.0419,-0.0213,0.0688, ... ,0.0157]      # 384 floats
```

## How it works

```
text
  -> BERT WordPiece tokenizer (vocab.txt)        LocalVector.Tokenizer
  -> input_ids / attention_mask / token_type_ids
  -> ONNX Runtime inference (model.onnx)         LocalVector.Embedder
  -> last_hidden_state [1, seq, 384]
  -> mean pooling over tokens + L2 normalize
  -> 384-dim float32 vector -> JSON array
```

- **Tokenizer** — a self-contained BERT (uncased) WordPiece tokenizer reading a
  plain `vocab.txt`. No regex/JSON dependencies, so it compiles under both
  Delphi and FPC.
- **Embedder** — feeds the three int64 inputs, reads the **true** ONNX output
  shape, mean-pools the token embeddings (sentence-transformers style), and
  L2-normalizes. If a model variant emits an already-pooled `[1, 384]` vector,
  that is used directly.
- **Downloader** — on first run, fetches `model.onnx` (~90 MB) and `vocab.txt`
  into `models/all-MiniLM-L6-v2/` next to the executable.

## Build

### Delphi (Win64) — recommended

- IDE: open `localvector.dproj`, set the platform to **Win64**, Build.
- Command line: run `build_delphi.bat` (it calls `rsvars.bat`, then `dcc64`).

### Free Pascal

```
build_fpc.bat        # Windows
./build_fpc.sh       # Linux/macOS
```

`localvector`'s own units are written to compile under both Delphi and FPC
(verified with FPC 3.2.2: the program compiles and the tokenizer's unit tests
pass). Two caveats for FPC:

- The **bundled ONNX bindings** (`onnxruntime.pas`, `onnxruntime_pas_api.pas`)
  use Delphi-style unit names (`System.SysUtils`, …). A stock FPC CLI doesn't
  map those to its RTL, so a full FPC build needs those names reachable — e.g.
  an FPC whose RTL is namespaced, the Lazarus environment, or thin alias units.
  Building with Delphi avoids this entirely.
- FPC HTTPS downloads go through OpenSSL, so `libssl`/`libcrypto` must be
  available at runtime.

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

## The onnxruntime.dll that matters (read this)

ONNX Runtime ships inside recent Windows, but **the in-box copy can be old**.
The bindings link `onnxruntime.dll` as a static import, so **the OS loader picks
the DLL**, not the program. For a plain console exe the search order is:

1. the **executable's own directory** (your `Win64\Release` / `Win64\Debug`
   output folder — *not* the project folder),
2. then `C:\Windows\System32\` (the in-box copy),
3. then the rest of the search path.

So a newer `onnxruntime.dll` only wins if it sits **next to the built `.exe`**.

### Symptom: "Unsupported model IR version"

```
Load model from ...\model.onnx failed:
onnxruntime::Model::Model Unsupported model IR version: 10, max supported IR version: 8
```

This means an **old** runtime got loaded (max IR 8 ≈ ORT 1.12, the typical
in-box build) while modern Hugging Face exports are **IR version 10**. The old
runtime refuses to load the graph. This is a runtime-too-old-for-model
mismatch — not a bug in the model or this code.

**Fix:** put a current `onnxruntime.dll` (**≥ 1.17**, which supports IR 10) in
the same folder as `localvector.exe`, then confirm:

```
localvector --diag
[localvector] onnxruntime library:
[localvector]   loaded from : C:\...\Win64\Release\onnxruntime.dll
[localvector]   version     : 1.26.0
[localvector]   bindings ask: ORT_API_VERSION 10  (GetApi True)
```

If `--diag` reports a `System32` path or an old version, the right DLL is not
next to the exe.

Where to get a current `onnxruntime.dll`:
- ONNX Runtime GitHub release **v1.26.0** → asset
  [`onnxruntime-win-x64-1.26.0.zip`](https://github.com/microsoft/onnxruntime/releases/tag/v1.26.0)
  → copy `lib\onnxruntime.dll` next to `localvector.exe`, or
- NuGet `Microsoft.ML.OnnxRuntime` → `runtimes/win-x64/native/onnxruntime.dll`.

> Verified: the `LocalVector.Runtime` diagnostic, linked against the real
> ONNX Runtime **1.26.0** library, reports `version 1.26.0` and
> `GetApi(ORT_API_VERSION=10) = True` — i.e. 1.26 supports the model's IR v10.

> The bindings request `ORT_API_VERSION = 10` (define `ONNX_NEW_VERSION` for 13).
> A *lower* request is intentionally compatible with the widest range of DLLs —
> the IR-version limit above is about the model graph, a separate thing from the
> C-API version.

## Files

| File | Purpose |
|------|---------|
| `localvector.dpr` | Program entry point |
| `src/LocalVector.App.pas` | CLI parsing, orchestration, JSON output |
| `src/LocalVector.Tokenizer.pas` | BERT WordPiece tokenizer (vocab.txt) |
| `src/LocalVector.Embedder.pas` | ONNX inference + mean pooling + normalize |
| `src/LocalVector.Downloader.pas` | First-run model/vocab download |
| `src/LocalVector.Runtime.pas` | Reports the loaded onnxruntime DLL + version |
| `onnxruntime.pas`, `onnxruntime_pas_api.pas` | ONNX Runtime Pascal bindings |
