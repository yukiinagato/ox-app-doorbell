; Doorbell for Windows — production installer (Inno Setup 6).
;
; Built by win\build.cmd from a finished release bundle (win\dist\<build-id>): the WPF shell,
; both core DLLs, the watchdog service and the ABI probes. What the installer adds on top of
; "copy the bundle":
;   - a first-run page that chooses the device role (door station / indoor panel), device name
;     and door ID, written to %ProgramData%\Doorbell\boot.json with setup_complete=true so the
;     shell starts straight into the cluster pairing flow;
;   - the watchdog service (DoorbellWatchdog), which is what starts the shell at boot and keeps
;     it alive; the Run-key autostart is the alternative when the service is not wanted;
;   - inbound firewall rules through the shell's own elevated repair mode (the same rules the
;     app offers to repair at runtime) plus the RTP/mDNS rules of provision.cmd;
;   - optional kiosk hardening (provision.cmd: NTP, power, WER, Windows Update policies);
;   - in-place upgrades: the same AppId re-runs over an existing installation, stops the service
;     and the shell, replaces the files, keeps %ProgramData%\Doorbell, and restarts what was
;     running. /VERYSILENT /SUPPRESSMSGBOXES /NORESTART is what the in-app updater uses.
;
; Preprocessor inputs (all passed by build.cmd):
;   SourceDir  – the bundle directory (app\, doorbell-watchdog.exe, checks\, SHA256SUMS)
;   BuildId    – the bundle's build id (artifact directory name)
;   AppVersion – dotted numeric version for the Windows version resource
;   ProvisionDir – deploy\provision\windows (kiosk / provisioning scripts)
;   UpdatePublisher – CN of the Authenticode certificate release installers are signed with;
;                  the in-app updater refuses any installer not signed by it (empty: refuse all)
;
; Data layout (security protocol v3):
;   %ProgramData%\Doorbell          SYSTEM/Administrators full, Users read
;   %ProgramData%\Doorbell\service  the watchdog service's state and log, administrators only
;   %ProgramData%\Doorbell\data     the app's data (boot.json, store, logs), Users modify
;   %ProgramData%\Doorbell\data\secure  DPAPI secrets: SYSTEM, Administrators and the
;                                   "Doorbell Operators" group, which holds the accounts that
;                                   run the app (the installing user, and /KIOSKUSER=name)

#ifndef SourceDir
  #error SourceDir must point at a finished win\dist\<build-id> bundle
#endif
#ifndef BuildId
  #define BuildId "dev"
#endif
#ifndef AppVersion
  #define AppVersion "0.2.0"
#endif
#ifndef ProvisionDir
  #define ProvisionDir "..\..\deploy\provision\windows"
#endif
#ifndef UpdatePublisher
  #define UpdatePublisher ""
#endif

#define MyAppName "Doorbell"
#define MyAppPublisher "ox"
#define MyAppExeName "DoorbellApp.exe"
#define WatchdogExe "doorbell-watchdog.exe"
#define ServiceName "DoorbellWatchdog"
#define RegKey "Software\Doorbell"
#define OperatorsGroup "Doorbell Operators"

[Setup]
AppId={{7D2E3B60-5B1E-4C7A-9C8B-6C1D3F0A5E21}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppVerName={#MyAppName} {#AppVersion} ({#BuildId})
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#AppVersion}
VersionInfoProductTextVersion={#BuildId}
DefaultDirName={autopf}\Doorbell
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=6.1sp1
OutputDir={#SourceDir}\installer
OutputBaseFilename=DoorbellSetup-{#BuildId}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
CloseApplications=yes
CloseApplicationsFilter=*.exe
RestartApplications=no
UninstallDisplayIcon={app}\app\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
UsePreviousTasks=yes
ShowLanguageDialog=auto

[Languages]
Name: "ja"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
ja.RolePageCaption=端末の役割
ja.RolePageDescription=この端末をどの役割で使いますか。後から管理画面で変更できます。
ja.RoleDoor=門口機（玄関に設置し、カメラで来訪者を映します）
ja.RoleIndoor=室内機（呼び出しを受け、応答します）
ja.IdentityPageCaption=端末の名前
ja.IdentityPageDescription=クラスタ内で表示される名前と、門口機のドア ID を設定します。
ja.DeviceName=端末名:
ja.DoorId=ドア ID（門口機のみ、door- で始まる英数字）:
ja.DoorIdInvalid=ドア ID は door- で始まり、英数字・ハイフンのみを使ってください。
ja.TaskService=常駐サービス（DoorbellWatchdog）を登録して起動時に自動実行する
ja.TaskAutostart=サービスを使わず、サインイン時にアプリを自動起動する
ja.TaskFirewall=Windows ファイアウォールの受信規則を追加する（メッシュ・管理・SIP・RTP）
ja.TaskProvision=キオスク向けシステム設定（NTP・電源・エラー通知・Windows Update 抑制）
ja.TaskDesktop=デスクトップにショートカットを作成する
ja.GroupSetup=セットアップ
ja.GroupSystem=システム
ja.KeepDataPrompt=設定とペアリング情報（%ProgramData%\Doorbell）を残しますか？%n「いいえ」を選ぶとクラスタ鍵を含めてすべて削除されます。
ja.UpgradeNote=既存の Doorbell が見つかりました。設定を保持したまま更新します。
ja.NetFx48Missing=.NET Framework 4.8 が見つかりません。Microsoft から .NET Framework 4.8 をインストールしてから、もう一度セットアップを実行してください。
ja.Kb3140245Missing=この Windows 7 には更新プログラム KB3140245 がありません。インストールされるまで、Telegram・Web Push・アプリ内アップデートなどの HTTPS 連携は動作しません（呼び出し・通話・SOS は動作します）。続行しますか？
en.RolePageCaption=Device role
en.RolePageDescription=How will this device be used? The role can be changed later in the admin console.
en.RoleDoor=Door station (at the entrance, shows visitors through its camera)
en.RoleIndoor=Indoor panel (receives and answers calls)
en.IdentityPageCaption=Device identity
en.IdentityPageDescription=The name shown inside the cluster, and the door ID for a door station.
en.DeviceName=Device name:
en.DoorId=Door ID (door stations only, starts with door-):
en.DoorIdInvalid=The door ID must start with door- and contain only letters, digits and hyphens.
en.TaskService=Register the DoorbellWatchdog service so the app starts at boot and is kept alive
en.TaskAutostart=Start the app at sign-in without the service (Run key)
en.TaskFirewall=Add Windows Firewall inbound rules (mesh, admin, SIP, RTP)
en.TaskProvision=Kiosk system settings (NTP, power, error dialogs, Windows Update policies)
en.TaskDesktop=Create a desktop shortcut
en.GroupSetup=Setup
en.GroupSystem=System
en.KeepDataPrompt=Keep the settings and pairing data (%ProgramData%\Doorbell)?%nChoose No to delete everything, including the cluster key.
en.UpgradeNote=An existing Doorbell installation was found. It will be updated in place with its settings kept.
en.NetFx48Missing=.NET Framework 4.8 was not found. Install .NET Framework 4.8 from Microsoft, then run setup again.
en.Kb3140245Missing=This Windows 7 system is missing update KB3140245. Until it is installed, HTTPS integrations (Telegram, Web Push, in-app updates) will not work; calls, intercom and SOS still do. Continue?

[Tasks]
Name: "service"; Description: "{cm:TaskService}"; GroupDescription: "{cm:GroupSetup}"
Name: "autostart"; Description: "{cm:TaskAutostart}"; GroupDescription: "{cm:GroupSetup}"; Flags: unchecked
Name: "firewall"; Description: "{cm:TaskFirewall}"; GroupDescription: "{cm:GroupSystem}"
Name: "provision"; Description: "{cm:TaskProvision}"; GroupDescription: "{cm:GroupSystem}"; Flags: unchecked
Name: "desktopicon"; Description: "{cm:TaskDesktop}"; GroupDescription: "{cm:GroupSystem}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\{#WatchdogExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\checks\*"; DestDir: "{app}\checks"; Flags: ignoreversion
Source: "{#SourceDir}\SHA256SUMS"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProvisionDir}\provision.cmd"; DestDir: "{app}\provision"; Flags: ignoreversion
Source: "{#ProvisionDir}\kiosk-enable.cmd"; DestDir: "{app}\provision"; Flags: ignoreversion
Source: "{#ProvisionDir}\kiosk-disable.cmd"; DestDir: "{app}\provision"; Flags: ignoreversion

[Dirs]
; Access control is applied explicitly in ApplyDataAcls; Inno's Permissions only adds entries.
Name: "{commonappdata}\Doorbell"; Flags: uninsneveruninstall
Name: "{commonappdata}\Doorbell\data"; Flags: uninsneveruninstall
Name: "{commonappdata}\Doorbell\service"; Flags: uninsneveruninstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\app\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\app\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; What the in-app updater reads to know what is installed, and where.
Root: HKLM; Subkey: "{#RegKey}"; ValueType: string; ValueName: "InstallDir"; ValueData: "{app}"; Flags: uninsdeletekey
Root: HKLM; Subkey: "{#RegKey}"; ValueType: string; ValueName: "BuildId"; ValueData: "{#BuildId}"
Root: HKLM; Subkey: "{#RegKey}"; ValueType: string; ValueName: "Version"; ValueData: "{#AppVersion}"
Root: HKLM; Subkey: "{#RegKey}"; ValueType: string; ValueName: "UpdatePublisher"; ValueData: "{#UpdatePublisher}"
Root: HKLM; Subkey: "{#RegKey}"; ValueType: dword; ValueName: "ServiceInstalled"; ValueData: "1"; Tasks: service
Root: HKLM; Subkey: "{#RegKey}"; ValueType: dword; ValueName: "ServiceInstalled"; ValueData: "0"; Tasks: not service; Check: not ServiceWasInstalled
; Sign-in autostart when the service is not used.
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Doorbell"; ValueData: """{app}\app\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Doorbell"; Flags: deletevalue; Tasks: not autostart

[Run]
; Firewall rules for the shell itself go through its elevated repair mode (same rules it offers
; to repair at runtime); RTP for the Asterisk leg and mDNS come from the provisioning script.
Filename: "{app}\app\{#MyAppExeName}"; Parameters: "--configure-firewall --firewall-mesh=47172 --firewall-admin=47180 --firewall-discovery=47171 --firewall-sip=47190"; Flags: runhidden waituntilterminated; Tasks: firewall; StatusMsg: "Firewall"
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Doorbell RTP"""; Flags: runhidden waituntilterminated; Tasks: firewall
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Doorbell RTP"" dir=in action=allow protocol=UDP localport=4000-4099"; Flags: runhidden waituntilterminated; Tasks: firewall
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Doorbell mDNS"""; Flags: runhidden waituntilterminated; Tasks: firewall
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Doorbell mDNS"" dir=in action=allow protocol=UDP localport=5353"; Flags: runhidden waituntilterminated; Tasks: firewall
Filename: "{app}\provision\provision.cmd"; Flags: runhidden waituntilterminated; Tasks: provision; StatusMsg: "Provisioning"
; The service starts the shell in the console session; without it, launch the app now.
Filename: "{app}\app\{#MyAppExeName}"; Flags: nowait postinstall skipifsilent; Check: not WillRunService; Description: "{cm:LaunchProgram,{#MyAppName}}"

[UninstallRun]
Filename: "{app}\{#WatchdogExe}"; Parameters: "--uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "svc"
Filename: "taskkill"; Parameters: "/IM {#MyAppExeName} /F"; Flags: runhidden waituntilterminated; RunOnceId: "kill"
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Doorbell Cluster TCP"""; Flags: runhidden waituntilterminated; RunOnceId: "fw1"
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Doorbell Cluster UDP"""; Flags: runhidden waituntilterminated; RunOnceId: "fw2"
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Doorbell RTP"""; Flags: runhidden waituntilterminated; RunOnceId: "fw3"
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Doorbell mDNS"""; Flags: runhidden waituntilterminated; RunOnceId: "fw4"

[Code]
var
  RolePage: TInputOptionWizardPage;
  IdentityPage: TInputQueryWizardPage;
  UpgradeDetected: Boolean;
  ServiceExistedBefore: Boolean;

function DataRoot(): String;
begin
  Result := ExpandConstant('{commonappdata}\Doorbell');
end;

function DataDir(): String;
begin
  Result := DataRoot() + '\data';
end;

{ Where boot.json lives now; before the first v3 install it is still at the top level. }
function BootJsonPath(): String;
begin
  Result := DataDir() + '\boot.json';
  if not FileExists(Result) and FileExists(DataRoot() + '\boot.json') then
    Result := DataRoot() + '\boot.json';
end;

{ setup_complete:true in boot.json means the device was already set up (by a previous
  installer run or by the shell's own first-run window); the wizard then skips its pages. }
function NeedsDeviceSetup(): Boolean;
var
  Text: AnsiString;
begin
  Result := True;
  if not FileExists(BootJsonPath()) then Exit;
  if not LoadStringFromFile(BootJsonPath(), Text) then Exit;
  if Pos('"setup_complete": true', Text) > 0 then Result := False;
  if Pos('"setup_complete":true', Text) > 0 then Result := False;
end;

function ServiceExists(): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('sc.exe', 'query {#ServiceName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
            and (ResultCode = 0);
end;

function ServiceWasInstalled(): Boolean;
begin
  Result := ServiceExistedBefore;
end;

function WillRunService(): Boolean;
begin
  Result := WizardIsTaskSelected('service') or ServiceExistedBefore;
end;

function RandomHex(Count: Integer): String;
var
  Digits: String;
  I: Integer;
begin
  Digits := '0123456789abcdef';
  Result := '';
  for I := 1 to Count do
    Result := Result + Digits[Random(16) + 1];
end;

function ValidDoorId(const Value: String): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := False;
  if (Length(Value) < 6) or (Length(Value) > 64) then Exit;
  if Copy(Value, 1, 5) <> 'door-' then Exit;
  for I := 6 to Length(Value) do
  begin
    C := Value[I];
    if not (((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
            ((C >= '0') and (C <= '9')) or (C = '-')) then Exit;
  end;
  Result := True;
end;

function JsonEscape(const Value: String): String;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(Value) do
  begin
    C := Value[I];
    if (C = '"') or (C = '\') then
      Result := Result + '\' + C
    else if Ord(C) < 32 then
      Result := Result + ' '
    else
      Result := Result + C;
  end;
end;

function NetFx48Installed(): Boolean;
var
  Release: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full',
                               'Release', Release) and (Release >= 528040);
end;

{ KB3140245 updates winhttp.dll to 6.1.7601.23375; before it WinHTTP on Windows 7 cannot be
  restricted to TLS 1.2, and the app refuses to fall back to anything older. }
function Win7WinHttpLacksTls12(): Boolean;
var
  Version: TWindowsVersion;
  Packed: Int64;
begin
  Result := False;
  GetWindowsVersionEx(Version);
  if (Version.Major <> 6) or (Version.Minor <> 1) then Exit;
  if not GetPackedVersion(ExpandConstant('{sys}\winhttp.dll'), Packed) then Exit;
  Result := ComparePackedVersion(Packed, PackVersionComponents(6, 1, 7601, 23375)) < 0;
end;

function InitializeSetup(): Boolean;
var
  Previous: String;
begin
  Result := True;
  if not NetFx48Installed() then
  begin
    SuppressibleMsgBox(CustomMessage('NetFx48Missing'), mbCriticalError, MB_OK, IDOK);
    Result := False;
    Exit;
  end;
  if Win7WinHttpLacksTls12() then
    if SuppressibleMsgBox(CustomMessage('Kb3140245Missing'), mbConfirmation, MB_YESNO,
                          IDYES) = IDNO then
    begin
      Result := False;
      Exit;
    end;
  UpgradeDetected := RegQueryStringValue(HKLM, '{#RegKey}', 'InstallDir', Previous);
  ServiceExistedBefore := ServiceExists();
end;

procedure InitializeWizard();
begin
  RolePage := CreateInputOptionPage(wpSelectTasks, CustomMessage('RolePageCaption'),
    CustomMessage('RolePageDescription'), '', True, False);
  RolePage.Add(CustomMessage('RoleDoor'));
  RolePage.Add(CustomMessage('RoleIndoor'));
  RolePage.SelectedValueIndex := 1;

  IdentityPage := CreateInputQueryPage(RolePage.ID, CustomMessage('IdentityPageCaption'),
    CustomMessage('IdentityPageDescription'), '');
  IdentityPage.Add(CustomMessage('DeviceName'), False);
  IdentityPage.Add(CustomMessage('DoorId'), False);
  IdentityPage.Values[0] := Lowercase(GetComputerNameString());
  IdentityPage.Values[1] := 'door-' + RandomHex(8);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (PageID = RolePage.ID) or (PageID = IdentityPage.ID) then
    Result := not NeedsDeviceSetup();
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = IdentityPage.ID then
  begin
    if Trim(IdentityPage.Values[0]) = '' then
      IdentityPage.Values[0] := 'doorbell';
    if (RolePage.SelectedValueIndex = 0) and not ValidDoorId(Trim(IdentityPage.Values[1])) then
    begin
      MsgBox(CustomMessage('DoorIdInvalid'), mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  Role: String;
begin
  Result := '';
  if UpgradeDetected then
    Result := Result + CustomMessage('UpgradeNote') + NewLine + NewLine;
  if MemoDirInfo <> '' then
    Result := Result + MemoDirInfo + NewLine + NewLine;
  if NeedsDeviceSetup() then
  begin
    if RolePage.SelectedValueIndex = 0 then
      Role := CustomMessage('RoleDoor')
    else
      Role := CustomMessage('RoleIndoor');
    Result := Result + CustomMessage('RolePageCaption') + NewLine + Space + Role + NewLine;
    Result := Result + Space + CustomMessage('DeviceName') + ' ' + Trim(IdentityPage.Values[0]) + NewLine;
    if RolePage.SelectedValueIndex = 0 then
      Result := Result + Space + CustomMessage('DoorId') + ' ' + Trim(IdentityPage.Values[1]) + NewLine;
    Result := Result + NewLine;
  end;
  if MemoTasksInfo <> '' then
    Result := Result + MemoTasksInfo + NewLine;
end;

{ Stop what is running before files are replaced: the service (which would otherwise restart
  the shell mid-copy) and the shell itself. Data under %ProgramData% is never touched here. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  if ServiceExistedBefore then
    Exec('sc.exe', 'stop {#ServiceName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/IM {#MyAppExeName} /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(1500);
end;

procedure WriteBootJson();
var
  Role, Door, Name, Lang, Json: String;
begin
  if RolePage.SelectedValueIndex = 0 then
  begin
    Role := 'door_station';
    Door := Trim(IdentityPage.Values[1]);
  end
  else
  begin
    Role := 'indoor_panel';
    Door := '';
  end;
  Name := Trim(IdentityPage.Values[0]);
  if Name = '' then Name := 'doorbell';
  if ActiveLanguage() = 'ja' then Lang := 'ja' else Lang := 'en';
  Json := '{ "name": "' + JsonEscape(Name) + '", "role": "' + Role + '", "door": "' +
          JsonEscape(Door) + '", "listen_port": 47172, "http_port": 47180, "ui_lang": "' +
          Lang + '", "kiosk": false, "setup_complete": true }';
  ForceDirectories(DataDir());
  if FileExists(DataDir() + '\boot.json') then
    FileCopy(DataDir() + '\boot.json', DataDir() + '\boot.json.bak', False);
  SaveStringToFile(DataDir() + '\boot.json', Json, False);
end;

procedure RunHidden(const FileName, Params: String);
var
  ResultCode: Integer;
begin
  if not Exec(FileName, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Log('could not run ' + FileName + ' ' + Params)
  else if ResultCode <> 0 then
    Log(FileName + ' ' + Params + ' exited ' + IntToStr(ResultCode));
end;

{ The accounts that run the app need the DPAPI secret directory; nobody else does. }
procedure EnsureOperatorsGroup();
var
  Kiosk: String;
begin
  RunHidden('net.exe', 'localgroup "{#OperatorsGroup}" /add /comment:"Accounts that run the Doorbell app"');
  RunHidden('net.exe', 'localgroup "{#OperatorsGroup}" "' + GetUserNameString() + '" /add');
  Kiosk := Trim(ExpandConstant('{param:KIOSKUSER|}'));
  if Kiosk <> '' then
    RunHidden('net.exe', 'localgroup "{#OperatorsGroup}" "' + Kiosk + '" /add');
end;

{ Versions before security protocol v3 kept everything at the top level, which ordinary users
  could modify and where the SYSTEM service also wrote. App data moves into data\; the service's
  old files and the retired kiosk unlock flag are dropped. }
procedure MigrateLegacyData();
var
  Find: TFindRec;
  Name: String;
begin
  if FindFirst(DataRoot() + '\*', Find) then
  try
    repeat
      Name := Find.Name;
      if (Name = '.') or (Name = '..') or (CompareText(Name, 'data') = 0) or
         (CompareText(Name, 'service') = 0) then
        Continue;
      if (CompareText(Name, 'watchdog-state.txt') = 0) or
         (CompareText(Name, 'watchdog-state.txt.tmp') = 0) or
         (CompareText(Name, 'watchdog.log') = 0) or
         (CompareText(Name, 'admin_unlocked.flag') = 0) then
      begin
        DeleteFile(DataRoot() + '\' + Name);
        Continue;
      end;
      if CompareText(Name, 'updates') = 0 then
      begin
        DelTree(DataRoot() + '\updates', True, True, True);
        Continue;
      end;
      if not RenameFile(DataRoot() + '\' + Name, DataDir() + '\' + Name) then
        Log('could not move ' + Name + ' into data');
    until not FindNext(Find);
  finally
    FindClose(Find);
  end;
end;

procedure ApplyDataAcls();
var
  Secure: String;
begin
  RunHidden('icacls.exe', '"' + DataRoot() + '" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F ' +
            '*S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX');
  RunHidden('icacls.exe', '"' + DataRoot() + '\service" /inheritance:r /grant:r ' +
            '*S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-11:(OI)(CI)RX');
  RunHidden('icacls.exe', '"' + DataDir() + '" /grant *S-1-5-32-545:(OI)(CI)M');
  Secure := DataDir() + '\secure';
  if not DirExists(Secure) then
  begin
    ForceDirectories(Secure);
    RunHidden('icacls.exe', '"' + Secure + '" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F ' +
              '*S-1-5-32-544:(OI)(CI)F "{#OperatorsGroup}":(OI)(CI)F');
  end
  else
    RunHidden('icacls.exe', '"' + Secure + '" /grant "{#OperatorsGroup}":(OI)(CI)F');
end;

procedure InstallOrRestartService();
var
  ResultCode: Integer;
begin
  { Re-register rather than reuse: a service left by a manual bundle install points at the
    old directory, and --install returns 4 without touching an existing registration.
    --uninstall returns 0 when there is nothing to remove. }
  Exec(ExpandConstant('{app}\{#WatchdogExe}'), '--uninstall', '', SW_HIDE, ewWaitUntilTerminated,
       ResultCode);
  Exec(ExpandConstant('{app}\{#WatchdogExe}'), '--install "' +
       ExpandConstant('{app}\app\{#MyAppExeName}') + '"', '', SW_HIDE, ewWaitUntilTerminated,
       ResultCode);
  if ResultCode = 4 then
    Exec('sc.exe', 'start {#ServiceName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    EnsureOperatorsGroup();
    ForceDirectories(DataDir());
    MigrateLegacyData();
    ApplyDataAcls();
    if NeedsDeviceSetup() then WriteBootJson();
    if WillRunService() then InstallOrRestartService();
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    if not UninstallSilent() then
    begin
      if MsgBox(CustomMessage('KeepDataPrompt'), mbConfirmation, MB_YESNO) = IDNO then
        DelTree(ExpandConstant('{commonappdata}\Doorbell'), True, True, True);
    end;
  end;
end;
