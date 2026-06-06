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
  LocalVector.Tokenizer in 'src/LocalVector.Tokenizer.pas',
  LocalVector.Embedder in 'src/LocalVector.Embedder.pas',
  LocalVector.Downloader in 'src/LocalVector.Downloader.pas',
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
