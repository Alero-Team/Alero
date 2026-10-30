$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$assetDir = Join-Path $root 'app\assets'
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $assetDir 'ALERO-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $assetDir 'fonts\OFL.txt') -Destination (Join-Path $assetDir 'FONT-LICENSE.txt')
$text = [Text.StringBuilder]::new()
[void]$text.AppendLine('Alero: avisos de los componentes nativos incluidos con la aplicación.')
[void]$text.AppendLine('This software is based in part on the work of the Independent JPEG Group.')
Push-Location $root
try {
    $raw = & cargo metadata --locked --offline --format-version 1
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve native dependency licenses.' }
    $metadata = $raw | ConvertFrom-Json
    foreach ($package in ($metadata.packages | Where-Object { $_.source } | Sort-Object name,version)) {
        $files = Get-ChildItem -LiteralPath (Split-Path $package.manifest_path) -File | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT)' }
        foreach ($file in $files) {
            [void]$text.AppendLine("`n============================================================")
            [void]$text.AppendLine("$($package.name) $($package.version) — $($file.Name)")
            [void]$text.AppendLine([IO.File]::ReadAllText($file.FullName))
        }
    }
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $root 'packaging\licenses') -File | Sort-Object Name)) {
        [void]$text.AppendLine("`n============================================================")
        [void]$text.AppendLine("Componentes del escritorio — $($file.Name)")
        [void]$text.AppendLine([IO.File]::ReadAllText($file.FullName))
    }
    [IO.File]::WriteAllText((Join-Path $assetDir 'NATIVE-LICENSES.txt'),$text.ToString(),[Text.UTF8Encoding]::new($false))
    Write-Output 'Project, font and native dependency licenses are bundled for the in-app license screen.'
} finally { Pop-Location }
