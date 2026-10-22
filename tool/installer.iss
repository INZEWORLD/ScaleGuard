; ScaleGuard — установщик для Windows.
;
; Собирает один ScaleGuard-Setup-<версия>.exe из готового бандла в
; build\dist-new. Ставится в профиль пользователя, поэтому права
; администратора при установке не нужны: приложение само запросит их при
; первом подключении (это нужно сетевому туннелю и системному прокси).
;
; Компиляция:
;   "C:\Users\<user>\AppData\Local\Programs\Inno Setup 6\ISCC.exe" tool\installer.iss

#define AppName "ScaleGuard"
#define AppVersion "1.1.0"
#define AppExe "ScaleGuard.exe"
#define AppUrl "https://scaleguard.inzeworld.com"
#define SrcDir "..\build\dist-new"
#define OutDir "..\build\dist"

[Setup]
AppId={{D379CB59-8C00-406A-AD61-E1E7285000EF}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=ScaleGuard
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}
VersionInfoVersion=1.1.0.0
VersionInfoCompany=ScaleGuard
VersionInfoDescription=ScaleGuard - установщик
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutDir}
OutputBaseFilename=ScaleGuard-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern dark includetitlebar
WizardSizePercent=120
WizardBackColor=#0B0714
WizardBackImageFile=..\installer\assets\back.png
WizardImageFile=..\installer\assets\hero.png
WizardImageBackColor=#0B0714
WizardImageStretch=yes
WizardSmallImageFile=..\installer\assets\small.png
WizardSmallImageBackColor=#0B0714
DisableWelcomePage=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Messages]
russian.WelcomeLabel1=ScaleGuard
russian.WelcomeLabel2=Приватный интернет без лишних настроек.%n%nУстановим ScaleGuard на этот компьютер? Это займёт меньше минуты, права администратора не нужны.
russian.InstallingLabel=Устанавливаем ScaleGuard…
russian.FinishedLabel=ScaleGuard установлен.%n%nЗапустите его и нажмите «Подключиться» — остальное приложение сделает само.
russian.ClickFinish=Нажмите «Готово», чтобы закрыть установку.

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Ярлыки:"; Flags: checkedonce

[Files]
Source: "{#SrcDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Картинки полосы прогресса для [Code] (загружаются во временную папку).
Source: "..\installer\assets\bar-track.png"; DestDir: "{tmp}"; Flags: dontcopy
Source: "..\installer\assets\bar-fill.png"; DestDir: "{tmp}"; Flags: dontcopy

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Удалить {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; Ссылки scaleguard:// (вход по QR и письму). Приложение всё равно
; перерегистрирует их при старте, но так они работают сразу после установки.
Root: HKCU; Subkey: "Software\Classes\scaleguard"; ValueType: string; ValueName: ""; ValueData: "URL:ScaleGuard Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\scaleguard"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\scaleguard\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExe},0"
Root: HKCU; Subkey: "Software\Classes\scaleguard\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""
Root: HKCU; Subkey: "Software\{#AppName}"; ValueType: string; ValueName: "InstallDir"; ValueData: "{app}"

[Run]
Filename: "{app}\{#AppExe}"; Description: "Запустить {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Данные входа и подписка живут в %APPDATA%\com.scaleguard и не трогаются.
Type: filesandordirs; Name: "{app}"

[Code]
var
  SgTrack, SgFill: TBitmapImage;
  SgTimerID: Longword;
  SgTarget, SgShown: Integer;
  SgBaseL, SgBaseT, SgBaseW, SgBaseH: Integer;
  SgAnim: Integer;

function SetTimer(hWnd, nIDEvent, uElapse, lpTimerFunc: Longword): Longword;
external 'SetTimer@user32.dll stdcall';

function KillTimer(hWnd, nIDEvent: Longword): Bool;
external 'KillTimer@user32.dll stdcall';

function CmdFound(const ImageName: string): Boolean;
var
  Code: Integer;
begin
  Exec(
    ExpandConstant('{cmd}'),
    '/c tasklist /FI "IMAGENAME eq ' + ImageName + '" /NH | find /I "' + ImageName + '" >nul',
    '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := Code = 0;
end;

function AppIsRunning(): Boolean;
begin
  Result := CmdFound('ScaleGuard.exe') or CmdFound('scaleguard_mobile.exe');
end;

function AskCloseApp(const Title: string): Boolean;
begin
  Result := MsgBox(
    Title + #13#10#13#10 +
    'Закройте ScaleGuard: правый клик по значку в трее -> "Выход".' + #13#10 +
    'Затем нажмите "Повторить".',
    mbError, MB_RETRYCANCEL) = IDRETRY;
end;

procedure SgPlaceBar();
begin
  if SgTrack = nil then
    Exit;
  SgTrack.SetBounds(
    WizardForm.ProgressGauge.Left, WizardForm.ProgressGauge.Top,
    WizardForm.ProgressGauge.Width, WizardForm.ProgressGauge.Height);
  SgFill.Left := SgTrack.Left;
  SgFill.Top := SgTrack.Top;
  SgFill.Height := SgTrack.Height;
end;

procedure SgShowProgress();
var
  W: Integer;
begin
  if (SgTrack = nil) or (SgFill = nil) then
    Exit;
  W := Round(SgTrack.Width * SgShown / 1000.0);
  if W < 0 then
    W := 0;
  SgFill.Width := W;
  SgFill.Visible := W > 0;
end;

procedure SgTick(Arg1, Arg2, Arg3, Arg4: Longword);
var
  T, E, K: Double;
  W, H: Integer;
begin
  if WizardForm = nil then
    Exit;

  // Логотип на первой странице: мягко проявляется, чуть увеличиваясь.
  if (SgAnim >= 0) and (SgAnim < 30) then
  begin
    Inc(SgAnim);
    T := SgAnim / 30.0;
    E := 1 - (1 - T) * (1 - T) * (1 - T);
    K := 0.92 + 0.08 * E;
    W := Round(SgBaseW * K);
    H := Round(SgBaseH * K);
    WizardForm.WizardBitmapImage.SetBounds(
      SgBaseL + (SgBaseW - W) div 2,
      SgBaseT + (SgBaseH - H) div 2 + Round(10 * (1 - E)),
      W, H);
    if SgAnim >= 30 then
      WizardForm.WizardBitmapImage.SetBounds(SgBaseL, SgBaseT, SgBaseW, SgBaseH);
  end;

  // Полоса загрузки плавно догоняет реальный прогресс.
  if SgShown < SgTarget then
  begin
    SgShown := SgShown + ((SgTarget - SgShown) div 4) + 1;
    if SgShown > SgTarget then
      SgShown := SgTarget;
    SgShowProgress;
  end;
end;

procedure InitializeWizard();
begin
  ExtractTemporaryFile('bar-track.png');
  ExtractTemporaryFile('bar-fill.png');

  SgTrack := TBitmapImage.Create(WizardForm);
  SgTrack.Parent := WizardForm.ProgressGauge.Parent;
  SgTrack.PngImage.LoadFromFile(ExpandConstant('{tmp}\bar-track.png'));
  SgTrack.AutoSize := False;
  SgTrack.Stretch := True;
  SgTrack.Center := False;
  SgTrack.Visible := False;

  SgFill := TBitmapImage.Create(WizardForm);
  SgFill.Parent := WizardForm.ProgressGauge.Parent;
  SgFill.PngImage.LoadFromFile(ExpandConstant('{tmp}\bar-fill.png'));
  SgFill.AutoSize := False;
  SgFill.Stretch := True;
  SgFill.Center := False;
  SgFill.Visible := False;

  WizardForm.ProgressGauge.Visible := False;

  SgBaseL := WizardForm.WizardBitmapImage.Left;
  SgBaseT := WizardForm.WizardBitmapImage.Top;
  SgBaseW := WizardForm.WizardBitmapImage.Width;
  SgBaseH := WizardForm.WizardBitmapImage.Height;

  SgAnim := -1;
  SgShown := 0;
  SgTarget := 0;
  SgTimerID := SetTimer(0, 0, 16, CreateCallback(@SgTick));
end;

procedure DeinitializeSetup();
begin
  if SgTimerID <> 0 then
  begin
    KillTimer(0, SgTimerID);
    SgTimerID := 0;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpWelcome then
  begin
    SgAnim := 0;
  end
  else
  begin
    SgAnim := -1;
    if SgBaseW > 0 then
      WizardForm.WizardBitmapImage.SetBounds(SgBaseL, SgBaseT, SgBaseW, SgBaseH);
  end;

  if CurPageID = wpInstalling then
  begin
    SgPlaceBar;
    SgShown := 0;
    SgTarget := 0;
    SgShowProgress;
    SgTrack.Visible := True;
  end
  else if SgTrack <> nil then
    SgTrack.Visible := False;
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
begin
  if MaxProgress > 0 then
    SgTarget := (CurProgress * 1000) div MaxProgress;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  // Молчаливая установка — это скрипт или развёртывание: диалог там некому
  // нажимать, а файлы новой копии всё равно не совпадают с работающими.
  if WizardSilent then
    Exit;
  while AppIsRunning() do
  begin
    if not AskCloseApp('ScaleGuard сейчас запущен.') then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
  if UninstallSilent then
    Exit;
  while AppIsRunning() do
  begin
    if not AskCloseApp('ScaleGuard сейчас запущен.') then
    begin
      Result := False;
      Exit;
    end;
  end;
end;
