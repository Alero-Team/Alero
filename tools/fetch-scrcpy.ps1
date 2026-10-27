# Downloads the pinned scrcpy release for Windows, checks its SHA-256 and unpacks it to third_party/scrcpy.
# The Windows build copies that folder next to alero.exe ("Ver pantalla"). Apache-2.0; see docs/research/Licenses.md.
# Upgrade: change both values below to a newer release and its hash from that release's SHA256SUMS.txt.
$ErrorActionPreference = 'Stop'
$version = 'v4.1'
$sha256 = '5b12172b3264b2889f4583ee64752ce832e29bc8b1089dca81093459697165db'

$root = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $root 'third_party\scrcpy'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "scrcpy-$version"
New-Item -ItemType Directory -Force $tmp | Out-Null
$zip = Join-Path $tmp "scrcpy-win64-$version.zip"
Invoke-WebRequest "https://github.com/Genymobile/scrcpy/releases/download/$version/scrcpy-win64-$version.zip" -OutFile $zip
$got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($got -ne $sha256) { throw "Hash mismatch for scrcpy ${version}: $got" }
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
Expand-Archive $zip -DestinationPath $tmp -Force
Move-Item (Join-Path $tmp "scrcpy-win64-$version") $dest
Write-Output "scrcpy $version -> $dest"
