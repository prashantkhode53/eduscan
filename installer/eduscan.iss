; ============================================================================
;  EduScan — Inno Setup script
;  Produces a single Setup.exe that installs the Windows desktop build.
;
;  Build the app first:
;      flutter build windows --release
;  Then compile this script (from the repo root):
;      "C:\Program Files\Inno Setup 7\ISCC.exe" installer\eduscan.iss
;  Output:
;      installer\Output\EduScan-Setup-1.0.0.exe
;
;  NOTE: Flutter ships a *folder* (exe + DLLs + data\), not a standalone exe,
;  so the whole Release directory must be packaged — done below with a
;  recursive Files entry.
; ============================================================================

#define MyAppName        "EduScan"
#define MyAppVersion     "1.0.0"
#define MyAppPublisher   "EduScan"
#define MyAppExeName     "eduscan.exe"
; AppId is a fixed GUID identifying this product for upgrades/uninstall.
; Generated once; keep it constant across releases so updates replace cleanly.
#define MyAppId          "{{8B2F4C1A-7E3D-4A6B-9C5E-1D2F3A4B5C6D}"

; Paths are relative to this .iss file (installer\), so ".." is the repo root.
#define ReleaseDir       "..\build\windows\x64\runner\Release"
#define AppIcon          "..\windows\runner\resources\app_icon.ico"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyAppVersion}

; Install per-user-or-machine depending on privileges; default to admin so it
; lands in Program Files for all users.
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}

; 64-bit only (Flutter Windows desktop is x64).
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Single self-contained Setup.exe.
OutputDir=Output
OutputBaseFilename=EduScan-Setup-{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes

SetupIconFile={#AppIcon}
WizardStyle=modern
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Package the entire Release folder (exe, DLLs, and data\flutter_assets, icudtl,
; AOT lib). recursesubdirs + createallsubdirs preserves the data\ tree exactly.
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}";          Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";    Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Offer to launch the app at the end of installation.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
