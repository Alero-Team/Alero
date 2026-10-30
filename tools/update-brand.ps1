[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ink = [Drawing.ColorTranslator]::FromHtml('#111315')
$ivory = [Drawing.ColorTranslator]::FromHtml('#F5F5F2')
$path1 = [Drawing.Drawing2D.GraphicsPath]::new()
$path1.AddLine(18,78,18,30)
$path1.AddBezier(18,30,18,22,22,18,30,18)
$path1.AddLine(30,18,47,18)
$path1.AddBezier(47,18,55,18,59,22,59,30)
$path1.AddLine(59,30,59,42)
$path1.AddBezier(59,42,59,50,63,54,71,54)
$path1.AddLine(71,54,100,54)
$path2 = $path1.Clone()
$halfTurn = [Drawing.Drawing2D.Matrix]::new(-1,0,0,-1,118,96)
$path2.Transform($halfTurn)

function Make-Png([int]$Size, [bool]$Tile) {
    $hi = $Size * 4
    $bitmap = [Drawing.Bitmap]::new($hi,$hi)
    $g = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([Drawing.Color]::Transparent)
        if ($Tile) {
            $shape = [Drawing.Drawing2D.GraphicsPath]::new()
            $d = [single]($hi * .344)
            $shape.AddArc(0,0,$d,$d,180,90)
            $shape.AddArc(($hi-$d),0,$d,$d,270,90)
            $shape.AddArc(($hi-$d),($hi-$d),$d,$d,0,90)
            $shape.AddArc(0,($hi-$d),$d,$d,90,90)
            $shape.CloseFigure()
            $brush = [Drawing.SolidBrush]::new($ink)
            $g.FillPath($brush,$shape)
            $brush.Dispose(); $shape.Dispose()
        }
        # The same optical size as the approved 210px identity tile; exact centering.
        $k = [single]($(if ($Tile) { .447 } else { .85 }) * $hi / 92)
        $matrix = [Drawing.Drawing2D.Matrix]::new($k,0,0,$k,($hi/2-59*$k),($hi/2-48*$k))
        $g.Transform = $matrix
        $pen = [Drawing.Pen]::new($ivory,10)
        $pen.StartCap = $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
        $g.DrawPath($pen,$path1); $g.DrawPath($pen,$path2)
        $pen.Dispose(); $matrix.Dispose()
        $small = [Drawing.Bitmap]::new($Size,$Size)
        $resample = [Drawing.Graphics]::FromImage($small)
        try {
            $resample.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $resample.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $resample.DrawImage($bitmap,0,0,$Size,$Size)
            $stream = [IO.MemoryStream]::new()
            try { $small.Save($stream,[Drawing.Imaging.ImageFormat]::Png); return ,$stream.ToArray() }
            finally { $stream.Dispose() }
        } finally { $resample.Dispose(); $small.Dispose() }
    } finally { $g.Dispose(); $bitmap.Dispose() }
}
function Save-Bytes([string]$Relative, [byte[]]$Bytes) {
    $dest = Join-Path $root $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    [IO.File]::WriteAllBytes($dest,$Bytes)
}
function Save-Text([string]$Relative, [string]$Text) {
    $dest = Join-Path $root $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    [IO.File]::WriteAllText($dest,$Text,[Text.UTF8Encoding]::new($false))
}
try {
    $sizes = @(16,24,32,48,64,128,256)
    $payloads = @($sizes | ForEach-Object { ,(Make-Png $_ $true) })
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i=0; $i -lt $sizes.Count; $i++) {
        $dimension = [byte]$(if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] })
        $writer.Write($dimension); $writer.Write($dimension); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$payloads[$i].Length); $writer.Write([uint32]$offset)
        $offset += $payloads[$i].Length
    }
    foreach ($bytes in $payloads) { $writer.Write([byte[]]$bytes) }
    $writer.Flush()
    $ico = $stream.ToArray()
    Save-Bytes 'app\assets\icon.ico' $ico
    Save-Bytes 'app\windows\runner\resources\app_icon.ico' $ico
    Save-Bytes 'app\assets\32x32.png' (Make-Png 32 $true)
    Save-Bytes 'daemon\icon.png' (Make-Png 64 $true)
    foreach ($density in @(@('mdpi',48),@('hdpi',72),@('xhdpi',96),@('xxhdpi',144),@('xxxhdpi',192))) {
        Save-Bytes ("app\android\app\src\main\res\mipmap-" + $density[0] + '\ic_launcher.png') (Make-Png $density[1] $true)
    }
    $p1 = 'M18,78 V30 Q18,18 30,18 H47 Q59,18 59,30 V42 Q59,54 71,54 H100'
    $p2 = 'M100,18 V66 Q100,78 88,78 H71 Q59,78 59,66 V54 Q59,42 47,42 H18'
    foreach ($variant in @(@('ic_launcher_foreground.xml','#F5F5F2'),@('ic_launcher_monochrome.xml','#FF000000'))) {
        Save-Text ('app\android\app\src\main\res\drawable\' + $variant[0]) @"
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
  <group android:translateX="24.5" android:translateY="30" android:scaleX="0.5" android:scaleY="0.5">
    <path android:pathData="$p1" android:strokeColor="$($variant[1])" android:strokeWidth="10" android:strokeLineCap="round" android:strokeLineJoin="round"/>
    <path android:pathData="$p2" android:strokeColor="$($variant[1])" android:strokeWidth="10" android:strokeLineCap="round" android:strokeLineJoin="round"/>
  </group>
</vector>
"@
    }
    Save-Text 'app\android\app\src\main\res\drawable\ic_stat_alero.xml' @"
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="24dp" android:height="24dp" android:viewportWidth="24" android:viewportHeight="24">
  <group android:translateX="-0.826087" android:translateY="1.565217" android:scaleX="0.217391304" android:scaleY="0.217391304">
    <path android:pathData="$p1" android:strokeColor="#FFFFFFFF" android:strokeWidth="10" android:strokeLineCap="round" android:strokeLineJoin="round"/>
    <path android:pathData="$p2" android:strokeColor="#FFFFFFFF" android:strokeWidth="10" android:strokeLineCap="round" android:strokeLineJoin="round"/>
  </group>
</vector>
"@
    Save-Text 'app\android\app\src\main\res\values\ic_launcher_background.xml' '<?xml version="1.0" encoding="utf-8"?><resources><color name="ic_launcher_background">#111315</color></resources>'
    Write-Output 'Brand assets updated: symmetric geometry, graphite #111315.'
} finally {
    $path1.Dispose(); $path2.Dispose(); $halfTurn.Dispose()
    if ($writer) { $writer.Dispose() }
    if ($stream) { $stream.Dispose() }
}
