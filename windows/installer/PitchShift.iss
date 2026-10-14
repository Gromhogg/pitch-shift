; Pitch Shift for Windows (beta): the installer (Inno Setup 6.6 or newer). One file for x64 and ARM64 PCs.
;
;   ISCC /DAppVersion=2.0.0-beta.3 /DDistX64=C:\dist-x64 /DDistArm64=C:\dist-arm64 PitchShift.iss
;   -> output\PitchShift-Setup.exe
;
; Each dist folder holds PitchShift.exe, PitchShiftEngine.dll and PitchShiftTool.exe for that processor.
;
; Options when running Setup (on top of Inno Setup's own /SILENT, /VERYSILENT, /NORESTART...):
;   /NOLAUNCH      don't open Pitch Shift at the end (for the GitHub checks)
;   /CABLESILENT   install VB-CABLE without VB-Audio's window (for the GitHub checks)
; Options for the uninstaller (unins000.exe), used when it runs silently:
;   /REMOVECABLE   also remove Pitch Shift Mic (VB-CABLE), if Pitch Shift installed it
;   /DELETESETTINGS  also delete the person's Pitch Shift settings

#ifndef AppVersion
  #define AppVersion "2.0.0-beta"
#endif
#ifndef NumericVersion
  #define NumericVersion "2.0.0.0"
#endif
#ifndef DistX64
  #define DistX64 "..\..\dist-x64"
#endif
#ifndef DistArm64
  #define DistArm64 "..\..\dist-arm64"
#endif

; VB-CABLE (the virtual microphone) by VB-Audio.
;   0 = download it from vb-audio.com (checked against a known SHA-256 by PitchShiftTool) and show
;       VB-Audio's own setup window, where the person clicks "Install Driver".
;   1 = put the VB-CABLE pack inside this installer and install it without a window.
;       Only switch to 1 once VB-Audio has said bundling is OK. Put VBCABLE_Driver_Pack45.zip next to this file.
#ifndef BundleCable
  #define BundleCable 0
#endif
#define CablePack "VBCABLE_Driver_Pack45.zip"

[Setup]
AppId={{6F1C2B7E-4D8A-4E3B-9A61-7C2E5D0B8F14}
AppName=Pitch Shift
AppVersion={#AppVersion}
AppVerName=Pitch Shift {#AppVersion}
VersionInfoVersion={#NumericVersion}
AppPublisher=Pitch Shift
AppPublisherURL=https://github.com/Gromhogg/pitch-shift
AppSupportURL=https://github.com/Gromhogg/pitch-shift/issues
AppUpdatesURL=https://github.com/Gromhogg/pitch-shift/releases
AppCopyright=GPL-3.0-or-later
DefaultDirName={autopf}\Pitch Shift
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir=output
OutputBaseFilename=PitchShift-Setup
SetupIconFile=..\app\AppIcon.ico
UninstallDisplayIcon={app}\PitchShift.exe
UninstallDisplayName=Pitch Shift (beta)
WizardStyle=modern dynamic
Compression=lzma2/max
SolidCompression=yes
InfoBeforeFile=notice.txt
; Pitch Shift is closed by our own code below (it lives in the tray, so Windows' way doesn't fit).
CloseApplications=no
RestartApplications=no
SetupLogging=yes

[Messages]
InfoBeforeLabel=Please read this before installing Pitch Shift.

[Files]
Source: "{#DistX64}\PitchShift.exe"; DestDir: "{app}"; Check: not IsArm64; Flags: ignoreversion
Source: "{#DistX64}\PitchShiftEngine.dll"; DestDir: "{app}"; Check: not IsArm64; Flags: ignoreversion
Source: "{#DistX64}\PitchShiftTool.exe"; DestDir: "{app}"; Check: not IsArm64; Flags: ignoreversion
Source: "{#DistArm64}\PitchShift.exe"; DestDir: "{app}"; Check: IsArm64; Flags: ignoreversion
Source: "{#DistArm64}\PitchShiftEngine.dll"; DestDir: "{app}"; Check: IsArm64; Flags: ignoreversion
Source: "{#DistArm64}\PitchShiftTool.exe"; DestDir: "{app}"; Check: IsArm64; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "notice.txt"; DestDir: "{app}"; DestName: "NOTICE.txt"; Flags: ignoreversion
#if BundleCable
Source: "{#CablePack}"; DestDir: "{tmp}"; Flags: deleteafterinstall
#endif

[Icons]
Name: "{autoprograms}\Pitch Shift"; Filename: "{app}\PitchShift.exe"
Name: "{autoprograms}\Pitch Shift Diagnostics"; Filename: "{app}\PitchShift.exe"; Parameters: "--diag"; Comment: "Puts a report about this PC's sound setup on the Desktop"
Name: "{autodesktop}\Pitch Shift"; Filename: "{app}\PitchShift.exe"

[Run]
; Opens Pitch Shift as the person who started Setup (not as administrator).
Filename: "{app}\PitchShift.exe"; Description: "Open Pitch Shift"; Flags: nowait postinstall runasoriginaluser; Check: ShouldLaunch

[UninstallDelete]
Type: files; Name: "{app}\*.log"

[Code]
var
  MicNeedsRestart: Boolean;
  RemoveCable: Boolean;
  DeleteSettings: Boolean;

function HasParam(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), Name) = 0 then
      Result := True;
end;

function ShouldLaunch: Boolean;
begin
  Result := not HasParam('/NOLAUNCH');
end;

// Did Pitch Shift install VB-CABLE? (PitchShiftTool setup-mic writes this down.)
function InstalledCable: Boolean;
var
  Value: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM64, 'SOFTWARE\Pitch Shift', 'InstalledByPitchShift', Value) and (Value <> 0);
end;

// Runs PitchShiftTool with no window and writes what it says into Setup's log.
function RunTool(const Params: String): Integer;
var
  Code: Integer;
begin
  Code := -1;
  if FileExists(ExpandConstant('{app}\PitchShiftTool.exe')) then
  begin
    Log('PitchShiftTool ' + Params);
    if not ExecAndLogOutput(ExpandConstant('{app}\PitchShiftTool.exe'), Params, '', SW_HIDE, ewWaitUntilTerminated, Code, nil) then
      Code := -1;
    Log('PitchShiftTool finished with code ' + IntToStr(Code));
  end;
  Result := Code;
end;

// Closes a running Pitch Shift. It quits cleanly (puts app volumes and the default microphone back);
// anything still running after that is ended.
procedure CloseRunningApp;
var
  Code: Integer;
begin
  if FileExists(ExpandConstant('{app}\PitchShift.exe')) then
    Exec(ExpandConstant('{app}\PitchShift.exe'), '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code);
  // The watchdog (PitchShiftTool watch) finishes a few seconds after the app; wait for it, then end leftovers.
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -Command "Wait-Process -Name PitchShiftTool -Timeout 12 -ErrorAction SilentlyContinue; ' +
    'Stop-Process -Name PitchShift,PitchShiftTool -Force -ErrorAction SilentlyContinue"',
    '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  CloseRunningApp;
  Result := '';
end;

// Installs VB-CABLE if needed and names it "Pitch Shift Mic" (PitchShiftTool setup-mic).
procedure SetUpMic;
var
  Params: String;
  Code: Integer;
begin
  Params := 'setup-mic --work "' + ExpandConstant('{tmp}\cable') + '"';
#if BundleCable
  Params := Params + ' --silent --pack "' + ExpandConstant('{tmp}\{#CablePack}') + '"';
  WizardForm.StatusLabel.Caption := 'Setting up Pitch Shift Mic (VB-CABLE by VB-Audio)...';
#else
  if HasParam('/CABLESILENT') then
    Params := Params + ' --silent';
  WizardForm.StatusLabel.Caption := 'Setting up Pitch Shift Mic. If VB-Audio''s window opens, click "Install Driver".';
#endif
  Code := RunTool(Params);
  // 0 = ready, 3010 = installed but Windows needs a restart, 1223 = VB-Audio's window was closed
  // without installing (no restart; Pitch Shift offers "Repair Pitch Shift Mic").
  if Code = 3010 then
    MicNeedsRestart := True
  else if Code = 1223 then
    SuppressibleMsgBox('Pitch Shift Mic (for your voice in calls) was not installed.' + #13#10#13#10 +
      'Everything else works. To add it later, open Pitch Shift and click "Repair Pitch Shift Mic".',
      mbInformation, MB_OK, IDOK)
  else if Code <> 0 then
    SuppressibleMsgBox('Pitch Shift Mic (for your voice in calls) could not be set up this time.' + #13#10#13#10 +
      'Everything else works. To try again later, open Pitch Shift and click "Repair Pitch Shift Mic".',
      mbInformation, MB_OK, IDOK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    SetUpMic;
end;

function NeedRestart(): Boolean;
begin
  Result := MicNeedsRestart;
end;

// ---------- Uninstall ----------

function InitializeUninstall(): Boolean;
begin
  RemoveCable := HasParam('/REMOVECABLE');
  DeleteSettings := HasParam('/DELETESETTINGS');
  Result := True;
end;

// After "Are you sure?": two boxes, both unticked, for the things that are kept by default.
procedure AskWhatElseToRemove;
var
  Form: TSetupForm;
  Info: TNewStaticText;
  CableBox, SettingsBox: TNewCheckBox;
  OKButton: TNewButton;
  Y: Integer;
begin
  Form := CreateCustomForm(ScaleX(420), ScaleY(150), False, False);
  try
    Form.Caption := 'Uninstall Pitch Shift';
    Info := TNewStaticText.Create(Form);
    Info.Parent := Form;
    Info.Left := ScaleX(16);
    Info.Top := ScaleY(16);
    Info.Caption := 'Also remove:';
    Y := ScaleY(42);
    CableBox := nil;
    if InstalledCable then
    begin
      CableBox := TNewCheckBox.Create(Form);
      CableBox.Parent := Form;
      CableBox.Left := ScaleX(16);
      CableBox.Top := Y;
      CableBox.Width := Form.ClientWidth - ScaleX(32);
      CableBox.Height := ScaleY(20);
      CableBox.Caption := 'Pitch Shift Mic (VB-CABLE by VB-Audio)';
      Y := Y + ScaleY(28);
    end;
    SettingsBox := TNewCheckBox.Create(Form);
    SettingsBox.Parent := Form;
    SettingsBox.Left := ScaleX(16);
    SettingsBox.Top := Y;
    SettingsBox.Width := Form.ClientWidth - ScaleX(32);
    SettingsBox.Height := ScaleY(20);
    SettingsBox.Caption := 'My Pitch Shift settings';
    OKButton := TNewButton.Create(Form);
    OKButton.Parent := Form;
    OKButton.Caption := 'Continue';
    OKButton.Width := ScaleX(90);
    OKButton.Height := ScaleY(26);
    OKButton.Left := Form.ClientWidth - OKButton.Width - ScaleX(16);
    OKButton.Top := Form.ClientHeight - OKButton.Height - ScaleY(14);
    OKButton.ModalResult := mrOk;
    OKButton.Default := True;
    OKButton.Cancel := True;
    Form.ActiveControl := OKButton;
    Form.ShowModal();
    RemoveCable := (CableBox <> nil) and CableBox.Checked;
    DeleteSettings := SettingsBox.Checked;
  finally
    Form.Free();
  end;
end;

procedure InitializeUninstallProgressForm();
begin
  if not UninstallSilent then
    AskWhatElseToRemove;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    CloseRunningApp;
    // Put back app volumes and the default microphone.
    RunTool('restore');
    if RemoveCable and InstalledCable then
      RunTool('remove-cable')
    else if InstalledCable then
      RunTool('restore-names');  // VB-CABLE stays, with its own names ("CABLE Input" / "CABLE Output")
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\RunOnce', '!PitchShiftRestore');
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    if DeleteSettings then
    begin
      DelTree(ExpandConstant('{userappdata}\Pitch Shift'), True, True, True);
      DelTree(ExpandConstant('{localappdata}\Pitch Shift'), True, True, True);
    end;
  end;
end;
