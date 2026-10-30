[CmdletBinding()]
param(
    [string]$FlutterRoot = 'C:\src\flutter',
    [string]$IsccPath = '',
    [string]$OutputDirectory = '',
    [string]$WorkDirectory = '',
    [switch]$SkipAnalyze
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
if (!$WorkDirectory) { $WorkDirectory = Join-Path ([IO.Path]::GetTempPath()) ('alero-package-' + [guid]::NewGuid().ToString('N')) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
$flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) { throw "Flutter not found: $flutter" }
if (!$IsccPath) {
    $candidates = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", (Join-Path ([IO.Path]::GetTempPath()) 'alero-inno-6.7.3\compiler\ISCC.exe'))
    $IsccPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (!$IsccPath -or !(Test-Path -LiteralPath $IsccPath)) { throw 'Pass -IsccPath with the path to Inno Setup 6 ISCC.exe.' }
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed ($LASTEXITCODE)" }
}
New-Item -ItemType Directory -Force -Path $OutputDirectory,$WorkDirectory | Out-Null
$oldPath = $env:PATH
$mappedDrive = $null
$env:PATH = "$FlutterRoot\bin;$env:USERPROFILE\.cargo\bin;$oldPath"
try {
    # Dart's Windows LSP transport can truncate initialization JSON on non-ASCII paths.
    # Keep all Flutter/CMake paths ASCII without relocating the checkout.
    if ($root -match '[^\x00-\x7F]') {
        # Keep CMake on the same drive letter as its existing cache.
        $letters = @('P','Q','R','S','T','U','V','W','X','Y','Z')
        $cachePath = Join-Path $root 'app\build\windows\x64\CMakeCache.txt'
        if (Test-Path -LiteralPath $cachePath) {
            $homeLine = Get-Content -LiteralPath $cachePath | Where-Object { $_ -match '^CMAKE_HOME_DIRECTORY:INTERNAL=([P-Zp-z]):[/\\]' } | Select-Object -First 1
            if ($homeLine -match '^CMAKE_HOME_DIRECTORY:INTERNAL=([P-Zp-z]):') {
                $cachedLetter = $Matches[1].ToUpperInvariant()
                $letters = @($cachedLetter) + @($letters | Where-Object { $_ -ne $cachedLetter })
            }
        }
        foreach ($letter in $letters) {
            if (!(Test-Path -LiteralPath ($letter + ':\'))) {
                & subst ($letter + ':') $root
                if ($LASTEXITCODE -ne 0) { throw 'Unable to create a temporary ASCII build path.' }
                $mappedDrive = $letter + ':'
                $root = $mappedDrive + '\'
                break
            }
        }
        if (!$mappedDrive) { throw 'A free drive letter is required to build from this non-ASCII path.' }
    }
    Push-Location $root
    try {
        & (Join-Path $PSScriptRoot 'sync-licenses.ps1')
        if (!(Test-Path -LiteralPath (Join-Path $root 'third_party\scrcpy\scrcpy.exe'))) {
            & (Join-Path $PSScriptRoot 'fetch-scrcpy.ps1')
        }
        Invoke-Checked 'cargo' @('build','--release','--locked','-p','pb-daemon')
        Push-Location (Join-Path $root 'app')
        try {
            Invoke-Checked $flutter @('pub','get','--enforce-lockfile')
            if (!$SkipAnalyze) { Invoke-Checked $flutter @('analyze','--no-pub') }
            Invoke-Checked $flutter @('build','windows','--release','--no-pub')
        } finally { Pop-Location }
        $bundle = Join-Path $WorkDirectory 'bundle'
        if (Test-Path -LiteralPath $bundle) { throw "Use an empty work directory: $WorkDirectory" }
        New-Item -ItemType Directory -Path $bundle | Out-Null
        Copy-Item -Path (Join-Path $root 'app\build\windows\x64\runner\Release\*') -Destination $bundle -Recurse
        Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $bundle
        Copy-Item -LiteralPath (Join-Path $root 'app\windows\runner\resources\app_icon.ico') -Destination $bundle
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (!$vs) { throw 'Visual Studio C++ tools are required.' }
        $redist = Get-ChildItem -Path (Join-Path $vs 'VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT') -Directory | Sort-Object FullName -Descending | Select-Object -First 1
        if (!$redist) { throw 'Visual C++ app-local redistributables were not found.' }
        Copy-Item -Path (Join-Path $redist.FullName '*.dll') -Destination $bundle
        $licenses = Join-Path $bundle 'licenses'
        New-Item -ItemType Directory -Path $licenses | Out-Null
        Copy-Item -Path (Join-Path $root 'packaging\licenses\*') -Destination $licenses -Recurse
        Copy-Item -Path (Join-Path $root 'app\assets\fonts\OFL.txt'),(Join-Path $root 'app\assets\fonts\TRADEMARKS.md') -Destination $licenses
        # Preserve the notices of the Rust dependencies resolved for the Windows target.
        $metadataText = & cargo metadata --locked --offline --filter-platform x86_64-pc-windows-msvc --format-version 1
        if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve dependency license metadata.' }
        $metadata = $metadataText | ConvertFrom-Json
        foreach ($p in $metadata.packages) {
            if (!$p.source) { continue }
            $dest = Join-Path $licenses ($p.name + '-' + $p.version)
            $files = Get-ChildItem -LiteralPath (Split-Path $p.manifest_path) -File | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT)' }
            if ($files) {
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                $files | Copy-Item -Destination $dest
            }
        }
        [IO.File]::WriteAllText((Join-Path $licenses 'THIRD-PARTY.txt'), "Alero includes Flutter/Dart and Rust dependencies. Flutter notices are in data/flutter_assets/NOTICES.Z.\nThis software is based in part on the work of the Independent JPEG Group.\nBundled scrcpy: https://github.com/Genymobile/scrcpy (Apache-2.0).\nADB: https://android.googlesource.com/platform/packages/modules/adb/ (Apache-2.0).\nFFmpeg: https://ffmpeg.org/legal.html (LGPL; shared libraries).\nSDL: https://libsdl.org/license.php (zlib).\nlibusb: https://libusb.info/ (LGPL-2.1).\n".Replace('\n', [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        # Launch helpers and developer artifacts do not belong in the installed payload.
        Get-ChildItem -LiteralPath (Join-Path $bundle 'scrcpy') -File | Where-Object { $_.Extension -in '.bat','.vbs' } | Remove-Item -Force
        Get-ChildItem -LiteralPath $bundle -Recurse -File | Where-Object { $_.Extension -in '.pdb','.log','.ilk','.exp','.lib' } | Remove-Item -Force
        foreach ($required in @('alero.exe','alero_daemon.exe','pb_bridge.dll','flutter_windows.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','data\icudtl.dat','data\app.so','scrcpy\adb.exe','scrcpy\scrcpy.exe','scrcpy\scrcpy-server')) {
            if (!(Test-Path -LiteralPath (Join-Path $bundle $required))) { throw "Missing runtime file: $required" }
        }
        $versionLine = Get-Content -LiteralPath (Join-Path $root 'app\pubspec.yaml') | Where-Object { $_ -match '^version:' } | Select-Object -First 1
        $version = ($versionLine -replace '^version:\s*','').Split('+')[0].Trim()
        Invoke-Checked $IsccPath @('/Q', "/DAppVersion=$version", "/DBundleDir=$bundle", "/DOutputDir=$OutputDirectory", (Join-Path $root 'packaging\alero.iss'))
        $installer = Join-Path $OutputDirectory "Alero-$version-windows-x64-setup.exe"
        if (!(Test-Path -LiteralPath $installer)) { throw 'Installer was not generated.' }
        $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText("$installer.sha256", "$hash  $([IO.Path]::GetFileName($installer))" + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Write-Output "INSTALLER=$installer"
        Write-Output "BUNDLE=$bundle"
    } finally { Pop-Location }
} finally {
    $env:PATH = $oldPath
    if ($mappedDrive) { & subst $mappedDrive /d }
}
