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
AppVerName=Alero {#AppVersion}
AppPublisherURL=https://github.com/Alero-Team/Alero
; The setup program itself is Inno Setup's 32-bit loader (Windows lists it as "32 bits"); it installs the
; 64-bit Alero in 64-bit mode. x64compatible = x64 Windows, and Windows 11 on ARM through its x64 emulation.
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Alero
VersionInfoProductVersion={#AppVersion}
VersionInfoDescription=Instalador de Alero para Windows x64
VersionInfoCompany=Alero
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
; [Code] below stops Alero first; the Restart Manager is only a fallback (it cannot close a tray app).
CloseApplications=force
CloseApplicationsFilter=alero.exe,alero_daemon.exe,*.dll
RestartApplications=no
Uninstallable=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; Flags: unchecked
Name: "firewall"; Description: "Permitir Alero en el Firewall de Windows (pide permiso de administrador; sin esto el teléfono puede tardar en encontrar el ordenador en redes Públicas)"

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Excludes: "app_icon.ico"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Alero"; Filename: "{app}\alero.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Alero"; Filename: "{app}\alero.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Alero"""; Verb: runas; Flags: runhidden shellexec waituntilterminated; Tasks: firewall; StatusMsg: "Configurando el Firewall de Windows..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Alero"" dir=in action=allow program=""{app}\alero_daemon.exe"" profile=any enable=yes"; Verb: runas; Flags: runhidden shellexec waituntilterminated; Tasks: firewall; StatusMsg: "Configurando el Firewall de Windows..."
Filename: "{app}\alero.exe"; Description: "Abrir Alero"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[Code]
{ Alero's window, its tray daemon, scrcpy and the bundled adb keep files open, so an update or uninstall used to
  stop and ask to close them by hand. Stops every process started from the install folder, and nothing else. }
procedure StopAlero();
var
  Dir: String;
  Code: Integer;
begin
  Dir := ExpandConstant('{app}');
  if not DirExists(Dir) then Exit;
  StringChangeEx(Dir, '''', '''''', True);
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith(''' + Dir + '\'', [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force"',
    '', SW_HIDE, ewWaitUntilTerminated, Code);
  Sleep(800);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopAlero();
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  StopAlero();
  Result := True;
end;
