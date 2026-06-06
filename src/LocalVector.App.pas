unit LocalVector.App;

{ Command-line front end. Three commands:
    localvector "text"               -> print the embedding (JSON)
    localvector index <file>         -> chunk + embed a file into a hybrid store
    localvector search "query"       -> FTS5 + vector (RRF) search over the store
  Diagnostics/progress go to stderr; results to stdout. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

function RunApp: Integer;

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  LocalVector.Runtime, LocalVector.OrtProvision, LocalVector.Models,
  LocalVector.Tokenizer, LocalVector.Embedder, LocalVector.Downloader,
  LocalVector.VecProvision, LocalVector.VectorStore;

const
  APP_NAME    = 'localvector';
  APP_VERSION = '1.2.0';

type
  TCommand = (cmdEmbed, cmdIndex, cmdSearch);

  TOptions = record
    Command: TCommand;
    Positional: string;      // text / file / query depending on command
    HasPositional: Boolean;
    TextFile: string;
    ModelName: string;
    ModelPath: string;
    VocabPath: string;
    PoolingStr: string;
    MaxLen: Integer;
    Normalize: Boolean;
    DbPath: string;
    ModeStr: string;
    ChunkMode: string;
    K: Integer;
    Verbose: Boolean;
    ShowDiag: Boolean;
    ShowHelp: Boolean;
    ShowVersion: Boolean;
  end;

procedure PrintHelp;
begin
  WriteLn(APP_NAME, ' v', APP_VERSION, ' - local embeddings + hybrid search (ONNX Runtime + sqlite-vec)');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  ', APP_NAME, ' "text to embed"                 print a JSON embedding');
  WriteLn('  ', APP_NAME, ' index <file> [--db vectors.db]   chunk + embed a text file');
  WriteLn('  ', APP_NAME, ' search "query" [--db vectors.db] hybrid FTS5+vector search');
  WriteLn('  ', APP_NAME, ' --diag');
  WriteLn;
  WriteLn('Models (--model NAME, default ', DEFAULT_MODEL, '): ', ModelKeys);
  WriteLn('      minilm  all-MiniLM-L6-v2  384-d mean   |  bge  bge-small-en-v1.5  384-d CLS');
  WriteLn('      mxbai   mxbai-embed-large-v1 (int8) 1024-d CLS');
  WriteLn;
  WriteLn('Common options:');
  WriteLn('  -m, --model NAME     Model preset (default: ', DEFAULT_MODEL, ').');
  WriteLn('  -v, --verbose        Progress + runtime info on stderr.');
  WriteLn('      --max-length N   Truncate to N tokens (default: 256).');
  WriteLn('Embed: -f/--file <path>, --pooling mean|cls|last, --no-normalize, --model-path, --vocab');
  WriteLn('Index/Search: --db <path> (default localvector.db)');
  WriteLn('Index: --chunk paragraphs|lines (default paragraphs)');
  WriteLn('Search: --k N (default 5), --mode hybrid|vector|keyword (default hybrid)');
  WriteLn;
  WriteLn('On first run the chosen model, the onnxruntime, and sqlite-vec are downloaded.');
end;

function ExeDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
end;

function ParseArgs: TOptions;
var
  I: Integer;
  Arg, First: string;

  function Take: string;
  begin
    Inc(I);
    if I > ParamCount then
      raise Exception.CreateFmt('Missing value after %s', [Arg]);
    Result := ParamStr(I);
  end;

begin
  Result := Default(TOptions);
  Result.Command := cmdEmbed;
  Result.ModelName := DEFAULT_MODEL;
  Result.MaxLen := 256;
  Result.Normalize := True;
  Result.DbPath := 'localvector.db';
  Result.ModeStr := 'hybrid';
  Result.ChunkMode := 'paragraphs';
  Result.K := 5;

  I := 1;
  First := ParamStr(1);
  if SameText(First, 'index') then begin Result.Command := cmdIndex; I := 2; end
  else if SameText(First, 'search') then begin Result.Command := cmdSearch; I := 2; end;

  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if (Arg = '-h') or (Arg = '--help') then Result.ShowHelp := True
    else if (Arg = '-V') or (Arg = '--version') then Result.ShowVersion := True
    else if Arg = '--diag' then Result.ShowDiag := True
    else if (Arg = '-v') or (Arg = '--verbose') then Result.Verbose := True
    else if (Arg = '-m') or (Arg = '--model') then Result.ModelName := Take
    else if Arg = '--model-path' then Result.ModelPath := Take
    else if (Arg = '-f') or (Arg = '--file') then Result.TextFile := Take
    else if Arg = '--pooling' then Result.PoolingStr := Take
    else if Arg = '--vocab' then Result.VocabPath := Take
    else if Arg = '--max-length' then Result.MaxLen := StrToIntDef(Take, 256)
    else if Arg = '--no-normalize' then Result.Normalize := False
    else if Arg = '--db' then Result.DbPath := Take
    else if Arg = '--mode' then Result.ModeStr := Take
    else if Arg = '--chunk' then Result.ChunkMode := Take
    else if (Arg = '-k') or (Arg = '--k') then Result.K := StrToIntDef(Take, 5)
    else if (Arg <> '') and (Arg[1] = '-') then
      raise Exception.CreateFmt('Unknown argument: %s', [Arg])
    else if not Result.HasPositional then
    begin
      Result.Positional := Arg;
      Result.HasPositional := True;
    end
    else
      raise Exception.CreateFmt('Unexpected extra argument: %s', [Arg]);
    Inc(I);
  end;
end;

function ReadFileUtf8(const APath: string): string;
var
  FS: TFileStream;
  Bytes: TBytes;
begin
  if not FileExists(APath) then
    raise Exception.CreateFmt('File not found: %s', [APath]);
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Bytes, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Bytes[0], FS.Size);
  finally
    FS.Free;
  end;
  Result := string(TEncoding.UTF8.GetString(Bytes));
end;

function VectorToJson(const AVec: TArray<Single>): string;
var
  Fmt: TFormatSettings;
  SB: TStringBuilder;
  I: Integer;
begin
  Fmt := {$IFDEF FPC}DefaultFormatSettings{$ELSE}TFormatSettings.Create{$ENDIF};
  Fmt.DecimalSeparator := '.';
  SB := TStringBuilder.Create(Length(AVec) * 12 + 2);
  try
    SB.Append('[');
    for I := 0 to High(AVec) do
    begin
      if I > 0 then SB.Append(',');
      SB.Append(FloatToStrF(AVec[I], ffGeneral, 8, 0, Fmt));
    end;
    SB.Append(']');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ Resolve model files (downloading if needed), ensure the runtime is loaded, and
  build a ready tokenizer + embedder for ASpec. Caller frees both. }
procedure BuildEmbedder(const ASpec: TModelSpec; AVerbose: Boolean;
  const AModelPathOverride, AVocabOverride: string;
  out ATokenizer: TBertTokenizer; out AEmbedder: TEmbedder);
var
  ModelDir, ModelPath, VocabPath: string;
  Downloader: TModelDownloader;
begin
  ModelDir := ExeDir + 'models' + PathDelim + ASpec.SubDir;
  ModelPath := AModelPathOverride;
  if ModelPath = '' then
    ModelPath := IncludeTrailingPathDelimiter(ModelDir) + MODEL_FILE;
  VocabPath := AVocabOverride;
  if VocabPath = '' then
    VocabPath := IncludeTrailingPathDelimiter(ExtractFilePath(ModelPath)) + VOCAB_FILE;

  if (not FileExists(ModelPath)) or (not FileExists(VocabPath)) then
  begin
    Downloader := TModelDownloader.Create(ASpec, ExtractFileDir(ModelPath), AVerbose);
    try
      Downloader.EnsureFiles;
      if not FileExists(VocabPath) then
        VocabPath := Downloader.VocabPath;
    finally
      Downloader.Free;
    end;
  end;

  EnsureOnnxRuntime(ExeDir, True, AVerbose);
  ATokenizer := TBertTokenizer.Create(VocabPath, ASpec.DoLowerCase);
  AEmbedder := TEmbedder.Create(ModelPath);
  AEmbedder.Load(AVerbose);
end;

function DoEmbed(const AOpt: TOptions; const ASpec: TModelSpec): Integer;
var
  Pooling: TPooling;
  Tok: TBertTokenizer;
  Emb: TEmbedder;
  Text: string;
  Ids: TArray<Int64>;
  Vec: TArray<Single>;
begin
  Result := 0;
  if AOpt.PoolingStr <> '' then
  begin
    if not ParsePooling(AOpt.PoolingStr, Pooling) then
      raise Exception.CreateFmt('Unknown pooling "%s" (mean|cls|last).', [AOpt.PoolingStr]);
  end
  else
    Pooling := ASpec.Pooling;

  if AOpt.TextFile <> '' then
    Text := ReadFileUtf8(AOpt.TextFile)
  else
    Text := AOpt.Positional;
  if Trim(Text) = '' then
    raise Exception.Create('No input text. Pass text as an argument or use --file.');

  Tok := nil; Emb := nil;
  try
    BuildEmbedder(ASpec, AOpt.Verbose, AOpt.ModelPath, AOpt.VocabPath, Tok, Emb);
    Ids := Tok.Encode(UnicodeString(Text), AOpt.MaxLen);
    Vec := Emb.Embed(Ids, Pooling, ASpec.NeedsTokenTypeIds, AOpt.Normalize, AOpt.Verbose);
    WriteLn(VectorToJson(Vec));
  finally
    Tok.Free;
    Emb.Free;
  end;
end;

function DoIndex(const AOpt: TOptions; const ASpec: TModelSpec): Integer;
var
  Tok: TBertTokenizer;
  Emb: TEmbedder;
  Store: IVectorStore;
  VecExt, FileText, Src: string;
  Chunks: TArray<string>;
  Ids: TArray<Int64>;
  Vec: TArray<Single>;
  I: Integer;
begin
  Result := 0;
  if not AOpt.HasPositional then
    raise Exception.Create('index needs a file: localvector index <file>');
  FileText := ReadFileUtf8(AOpt.Positional);
  Src := ExtractFileName(AOpt.Positional);
  Chunks := ChunkText(FileText, AOpt.ChunkMode);
  if Length(Chunks) = 0 then
    raise Exception.Create('No chunks to index (file empty?).');

  VecExt := EnsureVec0(ExeDir, True, AOpt.Verbose);

  Tok := nil; Emb := nil;
  try
    BuildEmbedder(ASpec, AOpt.Verbose, AOpt.ModelPath, AOpt.VocabPath, Tok, Emb);

    Store := CreateVectorStore;
    Store.OpenStore(AOpt.DbPath, VecExt);
    Store.InitSchema(ASpec.Dim, ASpec.Key);
    Store.BeginBatch;
    try
      for I := 0 to High(Chunks) do
      begin
        Ids := Tok.Encode(UnicodeString(Chunks[I]), AOpt.MaxLen);
        Vec := Emb.Embed(Ids, ASpec.Pooling, ASpec.NeedsTokenTypeIds, True, False);
        Store.AddChunk(Src, I, Chunks[I], Vec);
        if AOpt.Verbose and (((I + 1) mod 25) = 0) then
          WriteLn(ErrOutput, '[localvector] indexed ', I + 1, '/', Length(Chunks));
      end;
      Store.CommitBatch;
    except
      Store.CommitBatch;
      raise;
    end;
    Store.CloseStore;
    WriteLn(ErrOutput, '[localvector] indexed ', Length(Chunks), ' chunk(s) from ',
            Src, ' into ', AOpt.DbPath, ' (model ', ASpec.Key, ')');
  finally
    Tok.Free;
    Emb.Free;
  end;
end;

function DoSearch(const AOpt: TOptions): Integer;
var
  Spec: TModelSpec;
  Tok: TBertTokenizer;
  Emb: TEmbedder;
  Store: IVectorStore;
  VecExt, ModelName, Snippet: string;
  Mode: TSearchMode;
  Ids: TArray<Int64>;
  Qv: TArray<Single>;
  Hits: TSearchHits;
  I: Integer;
begin
  Result := 0;
  if not AOpt.HasPositional then
    raise Exception.Create('search needs a query: localvector search "query"');
  if not ParseSearchMode(AOpt.ModeStr, Mode) then
    raise Exception.CreateFmt('Unknown mode "%s" (hybrid|vector|keyword).', [AOpt.ModeStr]);
  if not FileExists(AOpt.DbPath) then
    raise Exception.CreateFmt('No index at %s. Run: localvector index <file> --db %s',
      [AOpt.DbPath, AOpt.DbPath]);

  VecExt := EnsureVec0(ExeDir, True, AOpt.Verbose);

  Store := CreateVectorStore;
  Store.OpenStore(AOpt.DbPath, VecExt);
  Store.InitSchema(0, '');   // load existing meta (model/dim) or raise
  ModelName := Store.MetaModel;
  if not FindModelSpec(ModelName, Spec) then
    raise Exception.CreateFmt('Index was built with unknown model "%s".', [ModelName]);

  Tok := nil; Emb := nil;
  try
    BuildEmbedder(Spec, AOpt.Verbose, '', '', Tok, Emb);
    Ids := Tok.Encode(UnicodeString(AOpt.Positional), AOpt.MaxLen);
    Qv := Emb.Embed(Ids, Spec.Pooling, Spec.NeedsTokenTypeIds, True, False);

    Hits := Store.Search(AOpt.Positional, Qv, Mode, AOpt.K);
    if AOpt.Verbose then
      WriteLn(ErrOutput, '[localvector] model=', Spec.Key, ' mode=',
              SearchModeName(Mode), ' hits=', Length(Hits));

    for I := 0 to High(Hits) do
    begin
      Snippet := StringReplace(Hits[I].Text, sLineBreak, ' ', [rfReplaceAll]);
      if Length(Snippet) > 200 then
        Snippet := Copy(Snippet, 1, 200) + ' ...';
      if Hits[I].VecDistance >= 0 then
        WriteLn(Format('%d. [%s#%d] score=%.4f dist=%.4f',
          [I + 1, Hits[I].Source, Hits[I].ChunkIndex, Hits[I].Score, Hits[I].VecDistance]))
      else
        WriteLn(Format('%d. [%s#%d] score=%.4f',
          [I + 1, Hits[I].Source, Hits[I].ChunkIndex, Hits[I].Score]));
      WriteLn('   ', Snippet);
    end;
    Store.CloseStore;
  finally
    Tok.Free;
    Emb.Free;
  end;
end;

function RunApp: Integer;
var
  Opt: TOptions;
  Spec: TModelSpec;
begin
  Result := 0;
  try
    Opt := ParseArgs;

    if Opt.ShowHelp then begin PrintHelp; Exit(0); end;
    if Opt.ShowVersion then begin WriteLn(APP_NAME, ' v', APP_VERSION); Exit(0); end;
    if Opt.ShowDiag then
    begin
      try EnsureOnnxRuntime(ExeDir, True, Opt.Verbose);
      except on E: Exception do WriteLn(ErrOutput, '[localvector] ', E.Message); end;
      PrintOrtRuntimeInfo;
      Exit(0);
    end;

    if not FindModelSpec(Opt.ModelName, Spec) then
      raise Exception.CreateFmt('Unknown model "%s". Available: %s',
        [Opt.ModelName, ModelKeys]);

    case Opt.Command of
      cmdIndex:  Result := DoIndex(Opt, Spec);
      cmdSearch: Result := DoSearch(Opt);
    else
      Result := DoEmbed(Opt, Spec);
    end;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'Error: ', E.Message);
      Result := 1;
    end;
  end;
end;

end.
