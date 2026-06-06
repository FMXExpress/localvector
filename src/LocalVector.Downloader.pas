unit LocalVector.Downloader;

{ First-run model acquisition. Downloads the two files localvector needs --
  model.onnx and vocab.txt -- from the Hugging Face repo
  onnx-models/all-MiniLM-L6-v2-onnx into a local models directory.

  HTTP is provided by the Delphi RTL (System.Net.HttpClient, TLS via SChannel)
  or, under Free Pascal, by fphttpclient + opensslsockets (needs the OpenSSL
  runtime libraries to be present). }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$ENDIF}

const
  HF_BASE_URL = 'https://huggingface.co/onnx-models/all-MiniLM-L6-v2-onnx/resolve/main/';
  MODEL_FILE  = 'model.onnx';
  VOCAB_FILE  = 'vocab.txt';

type
  TModelDownloader = class
  private
    FModelDir: string;
    FModelPath: string;
    FVocabPath: string;
    FVerbose: Boolean;
    procedure DownloadTo(const AUrl, ADestPath: string);
  public
    constructor Create(const AModelDir: string; AVerbose: Boolean = False);
    { Ensures both files exist locally, downloading whatever is missing. }
    procedure EnsureFiles;
    property ModelPath: string read FModelPath;
    property VocabPath: string read FVocabPath;
  end;

implementation

uses
  {$IFDEF FPC}
  fphttpclient, opensslsockets
  {$ELSE}
  System.Net.HttpClient, System.Net.URLClient
  {$ENDIF};

{ ---- small helpers ---- }

function JoinPath(const ADir, AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ADir) + AName;
end;

function FileSizeOf(const APath: string): Int64;
var
  FS: TFileStream;
begin
  Result := -1;
  if not FileExists(APath) then
    Exit;
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    Result := FS.Size;
  finally
    FS.Free;
  end;
end;

{ ---- TModelDownloader ---- }

constructor TModelDownloader.Create(const AModelDir: string; AVerbose: Boolean);
begin
  inherited Create;
  FModelDir := AModelDir;
  FVerbose := AVerbose;
  FModelPath := JoinPath(FModelDir, MODEL_FILE);
  FVocabPath := JoinPath(FModelDir, VOCAB_FILE);
end;

{$IFDEF FPC}
procedure TModelDownloader.DownloadTo(const AUrl, ADestPath: string);
var
  Client: TFPHTTPClient;
  FS: TFileStream;
begin
  WriteLn(ErrOutput, '[localvector] downloading ', ExtractFileName(ADestPath), ' ...');
  WriteLn(ErrOutput, '[localvector]   from ', AUrl);
  Client := TFPHTTPClient.Create(nil);
  try
    Client.AllowRedirect := True; // HF resolve/ URLs redirect to a CDN
    Client.AddHeader('User-Agent', 'localvector/1.0');
    FS := TFileStream.Create(ADestPath, fmCreate);
    try
      Client.Get(AUrl, FS);
    finally
      FS.Free;
    end;
  finally
    Client.Free;
  end;
  WriteLn(ErrOutput, '[localvector]   saved ', ADestPath, ' (',
          FileSizeOf(ADestPath), ' bytes)');
end;
{$ELSE}
procedure TModelDownloader.DownloadTo(const AUrl, ADestPath: string);
var
  Client: THTTPClient;
  Response: IHTTPResponse;
  FS: TFileStream;
begin
  WriteLn(ErrOutput, '[localvector] downloading ', ExtractFileName(ADestPath), ' ...');
  WriteLn(ErrOutput, '[localvector]   from ', AUrl);
  Client := THTTPClient.Create;
  try
    Client.ConnectionTimeout := 30000;
    Client.ResponseTimeout := 1800000; // up to 30 min for the ~90 MB model
    FS := TFileStream.Create(ADestPath, fmCreate);
    try
      Response := Client.Get(AUrl, FS);
      if Response.StatusCode <> 200 then
        raise Exception.CreateFmt('Download failed (%d %s) for %s',
          [Response.StatusCode, Response.StatusText, AUrl]);
    finally
      FS.Free;
    end;
  finally
    Client.Free;
  end;
  WriteLn(ErrOutput, '[localvector]   saved ', ADestPath, ' (',
          FileSizeOf(ADestPath), ' bytes)');
end;
{$ENDIF}

procedure TModelDownloader.EnsureFiles;
begin
  if not DirectoryExists(FModelDir) then
    ForceDirectories(FModelDir);

  if not FileExists(FVocabPath) then
    DownloadTo(HF_BASE_URL + VOCAB_FILE, FVocabPath);

  // Treat a suspiciously tiny model file as a failed/partial download.
  if (not FileExists(FModelPath)) or (FileSizeOf(FModelPath) < 1024 * 1024) then
  begin
    if FileExists(FModelPath) then
      DeleteFile(FModelPath);
    DownloadTo(HF_BASE_URL + MODEL_FILE, FModelPath);
  end;
end;

end.
