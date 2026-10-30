#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef BundleDir
  #error BundleDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
[Setup]
AppId={{7B446786-D4EC-4974-88C5-AC332BA9BF33}
AppName=Alero
AppVersion={#AppVersion}
AppPublisher=Alero
DefaultDirName={localappdata}\Programs\Alero
DefaultGroupName=Alero
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=Alero-{#AppVersion}-windows-x64-setup
SetupIconFile={#BundleDir}\app_icon.ico
UninstallDisplayIcon={app}\alero.exe
LicenseFile={#BundleDir}\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=alero.exe,alero_daemon.exe,*.dll
RestartApplications=no
Uninstallable=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Excludes: "app_icon.ico"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Alero"; Filename: "{app}\alero.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Alero"; Filename: "{app}\alero.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\alero.exe"; Description: "Abrir Alero"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
