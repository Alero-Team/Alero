[CmdletBinding()]
param(
    [string]$FlutterRoot = 'C:\src\flutter',
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$OutputDirectory = '',
    [switch]$SkipAnalyze,
    [string]$JavaSocketDirectory = ''
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) { throw 'Flutter SDK was not found.' }
if (!(Test-Path -LiteralPath $AndroidSdk)) { throw 'Android SDK was not found.' }
$oldPath = $env:PATH
$oldSdk = $env:ANDROID_HOME
$oldSdkRoot = $env:ANDROID_SDK_ROOT
$oldJava = $env:JAVA_HOME
$oldJavaOptions = $env:JAVA_TOOL_OPTIONS
$drive = $null
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed ($LASTEXITCODE)" }
}
try {
    $env:PATH = "$FlutterRoot\bin;$env:USERPROFILE\.cargo\bin;$oldPath"
    $env:ANDROID_HOME = $AndroidSdk
    $env:ANDROID_SDK_ROOT = $AndroidSdk
    # Optional compatibility with runners whose default temporary folder cannot host Java sockets.
    # This setting applies only to the Java build process.
    if ($JavaSocketDirectory) {
        $JavaSocketDirectory = [IO.Path]::GetFullPath($JavaSocketDirectory)
        New-Item -ItemType Directory -Force -Path $JavaSocketDirectory | Out-Null
        $env:JAVA_TOOL_OPTIONS = '-Djdk.net.unixdomain.tmpdir="' + $JavaSocketDirectory + '"'
    }
    if (Test-Path -LiteralPath 'C:\Program Files\Android\Android Studio\jbr') {
        $env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
    }
    if ($root -match '[^\x00-\x7F]') {
        foreach ($letter in @('P','Q','R','S','T','U','V','W','X','Y','Z')) {
            if (!(Test-Path -LiteralPath ($letter + ':\'))) {
                & subst ($letter + ':') $root
                if ($LASTEXITCODE -ne 0) { throw 'Could not map the ASCII build path.' }
                $drive = $letter + ':'
                $root = $drive + '\'
                break
            }
        }
        if (!$drive) { throw 'A free drive letter is required.' }
    }
    & (Join-Path $PSScriptRoot 'sync-licenses.ps1')
    Push-Location (Join-Path $root 'app')
    try {
        Invoke-Checked $flutter @('pub','get','--enforce-lockfile')
        if (!$SkipAnalyze) { Invoke-Checked $flutter @('analyze','--no-pub') }
        Invoke-Checked $flutter @('build','apk','--release','--target-platform','android-arm64','--no-pub')
        $version = ((Get-Content 'pubspec.yaml' | Where-Object { $_ -match '^version:' } | Select-Object -First 1) -replace '^version:\s*','').Split('+')[0].Trim()
        New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        $apk = Join-Path $OutputDirectory "Alero-$version-android-arm64.apk"
        Copy-Item -LiteralPath 'build\app\outputs\flutter-apk\app-release.apk' -Destination $apk
        $hash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText(($apk + '.sha256'), "$hash  $([IO.Path]::GetFileName($apk))" + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Write-Output "APK=$apk"
    } finally { Pop-Location }
} finally {
    $env:PATH = $oldPath
    $env:ANDROID_HOME = $oldSdk
    $env:ANDROID_SDK_ROOT = $oldSdkRoot
    $env:JAVA_HOME = $oldJava
    $env:JAVA_TOOL_OPTIONS = $oldJavaOptions
    if ($drive) { & subst $drive /d }
}
