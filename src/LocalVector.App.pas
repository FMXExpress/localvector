unit LocalVector.App;

{ Command-line front end: take one piece of text and print its embedding as a
  JSON array on stdout. A model is chosen with --model (minilm | bge); each
  preset knows its repo, pooling, and dimensionality. Diagnostics and progress
  go to stderr so stdout stays clean for piping. }

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
  LocalVector.Runtime, LocalVector.Models, LocalVector.Tokenizer,
  LocalVector.Embedder, LocalVector.Downloader;

const
  APP_NAME    = 'localvector';
  APP_VERSION = '1.1.0';

type
  TOptions = record
    Text: string;
    TextFile: string;
    ModelName: string;       // preset selector (minilm | bge)
    ModelPath: string;       // explicit model.onnx override
    VocabPath: string;       // explicit vocab.txt override
    PoolingStr: string;      // pooling override ('' = model default)
    MaxLen: Integer;
    Normalize: Boolean;
    Verbose: Boolean;
    ShowDiag: Boolean;
    ShowHelp: Boolean;
    ShowVersion: Boolean;
    HasText: Boolean;
  end;

procedure PrintHelp;
begin
  WriteLn(APP_NAME, ' v', APP_VERSION,
          ' - local sentence embeddings via ONNX Runtime');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  ', APP_NAME, ' "text to embed"');
  WriteLn('  ', APP_NAME, ' --model bge "text to embed"');
  WriteLn('  ', APP_NAME, ' --file input.txt');
  WriteLn('  ', APP_NAME, ' --diag');
  WriteLn;
  WriteLn('Models (--model NAME, default ', DEFAULT_MODEL, '):');
  WriteLn('      minilm   all-MiniLM-L6-v2   384-d, mean pooling   (~90 MB)');
  WriteLn('      bge      bge-small-en-v1.5  384-d, CLS pooling    (~133 MB)');
  WriteLn;
  WriteLn('Options:');
  WriteLn('  -m, --model NAME     Model preset: ', ModelKeys, '  (default: ', DEFAULT_MODEL, ').');
  WriteLn('  -t, --text <s>       Text to embed (or pass it as the first argument).');
  WriteLn('  -f, --file <path>    Read the input text from a UTF-8 file.');
  WriteLn('      --pooling MODE   Override pooling: mean | cls | last.');
  WriteLn('      --model-path <p> Path to a custom model.onnx (overrides the preset file).');
  WriteLn('      --vocab <path>   Path to vocab.txt (default: alongside the model).');
  WriteLn('      --max-length N   Truncate to N tokens incl. [CLS]/[SEP] (default: 256).');
  WriteLn('      --no-normalize   Skip L2 normalization (default: normalized).');
  WriteLn('      --diag           Print the loaded onnxruntime DLL path + version, then exit.');
  WriteLn('  -v, --verbose        Progress + runtime info on stderr.');
  WriteLn('  -h, --help           This help.');
  WriteLn('  -V, --version        Print version.');
  WriteLn;
  WriteLn('Output: a JSON array of float32 values on stdout.');
  WriteLn('On first run the chosen model + vocab are downloaded from Hugging Face.');
end;

function ParseArgs: TOptions;
var
  I: Integer;
  Arg: string;

  function Take: string;
  begin
    Inc(I);
    if I > ParamCount then
      raise Exception.CreateFmt('Missing value after %s', [Arg]);
    Result := ParamStr(I);
  end;

begin
  Result.Text := '';
  Result.TextFile := '';
  Result.ModelName := DEFAULT_MODEL;
  Result.ModelPath := '';
  Result.VocabPath := '';
  Result.PoolingStr := '';
  Result.MaxLen := 256;
  Result.Normalize := True;
  Result.Verbose := False;
  Result.ShowDiag := False;
  Result.ShowHelp := False;
  Result.ShowVersion := False;
  Result.HasText := False;

  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if (Arg = '-h') or (Arg = '--help') then
      Result.ShowHelp := True
    else if (Arg = '-V') or (Arg = '--version') then
      Result.ShowVersion := True
    else if Arg = '--diag' then
      Result.ShowDiag := True
    else if (Arg = '-v') or (Arg = '--verbose') then
      Result.Verbose := True
    else if (Arg = '-m') or (Arg = '--model') then
      Result.ModelName := Take
    else if Arg = '--model-path' then
      Result.ModelPath := Take
    else if (Arg = '-t') or (Arg = '--text') then
    begin
      Result.Text := Take;
      Result.HasText := True;
    end
    else if (Arg = '-f') or (Arg = '--file') then
      Result.TextFile := Take
    else if Arg = '--pooling' then
      Result.PoolingStr := Take
    else if Arg = '--vocab' then
      Result.VocabPath := Take
    else if Arg = '--max-length' then
      Result.MaxLen := StrToIntDef(Take, 256)
    else if Arg = '--no-normalize' then
      Result.Normalize := False
    else if (Arg <> '') and (Arg[1] = '-') then
      raise Exception.CreateFmt('Unknown argument: %s', [Arg])
    else if not Result.HasText then
    begin
      Result.Text := Arg;
      Result.HasText := True;
    end
    else
      raise Exception.CreateFmt('Unexpected extra argument: %s', [Arg]);
    Inc(I);
  end;
end;

function ExeDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
end;

function ReadInputText(const AOpt: TOptions): UnicodeString;
var
  FS: TFileStream;
  Bytes: TBytes;
begin
  if AOpt.TextFile <> '' then
  begin
    if not FileExists(AOpt.TextFile) then
      raise Exception.CreateFmt('Input file not found: %s', [AOpt.TextFile]);
    FS := TFileStream.Create(AOpt.TextFile, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Bytes, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(Bytes[0], FS.Size);
    finally
      FS.Free;
    end;
    Result := TEncoding.UTF8.GetString(Bytes);
  end
  else
    Result := UnicodeString(AOpt.Text);

  if Trim(Result) = '' then
    raise Exception.Create('No input text. Pass text as an argument or use --file.');
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
      if I > 0 then
        SB.Append(',');
      SB.Append(FloatToStrF(AVec[I], ffGeneral, 8, 0, Fmt));
    end;
    SB.Append(']');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function RunApp: Integer;
var
  Opt: TOptions;
  Spec: TModelSpec;
  Pooling: TPooling;
  ModelDir: string;
  Downloader: TModelDownloader;
  Tokenizer: TBertTokenizer;
  Embedder: TEmbedder;
  Ids: TArray<Int64>;
  Vec: TArray<Single>;
  Text: UnicodeString;
begin
  Result := 0;
  try
    Opt := ParseArgs;

    if Opt.ShowHelp then
    begin
      PrintHelp;
      Exit(0);
    end;
    if Opt.ShowVersion then
    begin
      WriteLn(APP_NAME, ' v', APP_VERSION);
      Exit(0);
    end;
    if Opt.ShowDiag then
    begin
      PrintOrtRuntimeInfo;
      Exit(0);
    end;

    if not FindModelSpec(Opt.ModelName, Spec) then
      raise Exception.CreateFmt('Unknown model "%s". Available: %s',
        [Opt.ModelName, ModelKeys]);

    // Pooling: explicit override, otherwise the model's default.
    if Opt.PoolingStr <> '' then
    begin
      if not ParsePooling(Opt.PoolingStr, Pooling) then
        raise Exception.CreateFmt('Unknown pooling "%s" (mean|cls|last).', [Opt.PoolingStr]);
    end
    else
      Pooling := Spec.Pooling;

    // Resolve default model/vocab paths under <exe>/models/<subdir>.
    ModelDir := ExeDir + 'models' + PathDelim + Spec.SubDir;
    if Opt.ModelPath = '' then
      Opt.ModelPath := IncludeTrailingPathDelimiter(ModelDir) + MODEL_FILE;
    if Opt.VocabPath = '' then
      Opt.VocabPath := IncludeTrailingPathDelimiter(
        ExtractFilePath(Opt.ModelPath)) + VOCAB_FILE;

    // Read input before any large download so bad input fails fast.
    Text := ReadInputText(Opt);

    if (not FileExists(Opt.ModelPath)) or (not FileExists(Opt.VocabPath)) then
    begin
      Downloader := TModelDownloader.Create(Spec,
        ExtractFileDir(Opt.ModelPath), Opt.Verbose);
      try
        Downloader.EnsureFiles;
        if not FileExists(Opt.VocabPath) then
          Opt.VocabPath := Downloader.VocabPath;
      finally
        Downloader.Free;
      end;
    end;

    Tokenizer := nil;
    Embedder := nil;
    try
      Tokenizer := TBertTokenizer.Create(Opt.VocabPath, Spec.DoLowerCase);
      Ids := Tokenizer.Encode(Text, Opt.MaxLen);
      if Opt.Verbose then
        WriteLn(ErrOutput, '[localvector] model=', Spec.Key,
                ' token count=', Length(Ids));

      Embedder := TEmbedder.Create(Opt.ModelPath);
      Embedder.Load(Opt.Verbose);
      Vec := Embedder.Embed(Ids, Pooling, Spec.NeedsTokenTypeIds,
                            Opt.Normalize, Opt.Verbose);

      WriteLn(VectorToJson(Vec));
    finally
      Tokenizer.Free;
      Embedder.Free;
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
