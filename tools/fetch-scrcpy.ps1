# Download the pinned Windows runtime and verify its published SHA-256.
$ErrorActionPreference = 'Stop'
$version = 'v5.0.1'
$sha256 = 'b12a2c4ee8be317422451fc7dcf8ee20a71b5ea7ef9ad73ddd825a25316227a5'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$dest = [IO.Path]::GetFullPath((Join-Path $root 'third_party\scrcpy'))
if (!$dest.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid runtime destination.' }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tmp = Join-Path $tempRoot ('alero-scrcpy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp "scrcpy-win64-$version.zip"
    Invoke-WebRequest "https://github.com/Genymobile/scrcpy/releases/download/$version/scrcpy-win64-$version.zip" -OutFile $zip
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha256) { throw 'scrcpy checksum mismatch.' }
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp
    $unpacked = Join-Path $tmp "scrcpy-win64-$version"
    if (Test-Path -LiteralPath $dest) {
        if ((Get-Item -LiteralPath $dest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Runtime destination cannot be a link.' }
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item -LiteralPath $unpacked -Destination $dest -Recurse
    foreach ($helper in @('open_a_terminal_here.bat','scrcpy-noconsole.vbs')) {
        $helperPath = Join-Path $dest $helper
        if (Test-Path -LiteralPath $helperPath) { Remove-Item -LiteralPath $helperPath -Force }
    }
    Write-Output "scrcpy $version -> $dest"
} finally {
    $resolvedTmp = [IO.Path]::GetFullPath($tmp)
    if ($resolvedTmp.StartsWith($tempRoot + '\alero-scrcpy-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTmp -Recurse -Force
    }
}
