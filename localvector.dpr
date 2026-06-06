program localvector;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  onnxruntime_pas_api in 'onnxruntime_pas_api.pas',
  onnxruntime in 'onnxruntime.pas',
  LocalVector.Runtime in 'src/LocalVector.Runtime.pas',
  LocalVector.OrtProvision in 'src/LocalVector.OrtProvision.pas',
  LocalVector.Models in 'src/LocalVector.Models.pas',
  LocalVector.Tokenizer in 'src/LocalVector.Tokenizer.pas',
  LocalVector.Embedder in 'src/LocalVector.Embedder.pas',
  LocalVector.Downloader in 'src/LocalVector.Downloader.pas',
  LocalVector.VecProvision in 'src/LocalVector.VecProvision.pas',
  LocalVector.VectorStore in 'src/LocalVector.VectorStore.pas',
{$IFDEF FPC}
  LocalVector.Sqlite3 in 'src/LocalVector.Sqlite3.pas',
  LocalVector.VectorStore.Sqlite in 'src/LocalVector.VectorStore.Sqlite.pas',
{$ELSE}
  {$IFDEF LV_PORTABLE_SQLITE}
  LocalVector.Sqlite3 in 'src/LocalVector.Sqlite3.pas',
  LocalVector.VectorStore.Sqlite in 'src/LocalVector.VectorStore.Sqlite.pas',
  {$ELSE}
  LocalVector.VectorStore.FireDAC in 'src/LocalVector.VectorStore.FireDAC.pas',
  {$ENDIF}
{$ENDIF}
  LocalVector.App in 'src/LocalVector.App.pas';

begin
  try
    ExitCode := RunApp;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'Fatal: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
