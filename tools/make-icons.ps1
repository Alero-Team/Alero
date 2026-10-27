# Renders the Alero mark (docs/design/aero identidad.svg) to the raster icons the platforms need.
# The two paths below are copied from that SVG; keep them in sync with app/lib/ui/brand.dart and the Android vectors.
# Usage: pwsh tools/make-icons.ps1   (Windows only: System.Drawing)
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$graphite = [System.Drawing.ColorTranslator]::FromHtml('#17191D')
$ivory = [System.Drawing.ColorTranslator]::FromHtml('#F5F5F2')

# Each segment: Q (quadratic: cx cy x y), L (line: x y). Start point first.
$paths = @(
  @{ start = @(18, 78); seg = @(@('L', 18, 30), @('Q', 18, 18, 30, 18), @('L', 47, 18), @('Q', 59, 18, 59, 30), @('L', 59, 43), @('Q', 59, 55, 71, 55), @('L', 100, 55)) },
  @{ start = @(100, 30); seg = @(@('L', 100, 66), @('Q', 100, 78, 88, 78), @('L', 71, 78), @('Q', 59, 78, 59, 66), @('L', 59, 55), @('Q', 59, 43, 47, 43), @('L', 18, 43)) }
)

function Get-Mark([float]$scale, [float]$cx, [float]$cy) {
  # Mark centre in SVG units is (59, 48); returns GraphicsPaths placed so that centre lands on ($cx, $cy).
  $out = @()
  foreach ($p in $paths) {
    $g = New-Object System.Drawing.Drawing2D.GraphicsPath
    $px = $p.start[0]; $py = $p.start[1]
    foreach ($s in $p.seg) {
      if ($s[0] -eq 'L') { $nx = $s[1]; $ny = $s[2]; $g.AddLine(($cx + ($px - 59) * $scale), ($cy + ($py - 48) * $scale), ($cx + ($nx - 59) * $scale), ($cy + ($ny - 48) * $scale)) }
      else {
        $qx = $s[1]; $qy = $s[2]; $nx = $s[3]; $ny = $s[4]
        # quadratic -> cubic
        $c1x = $px + 2 / 3 * ($qx - $px); $c1y = $py + 2 / 3 * ($qy - $py)
        $c2x = $nx + 2 / 3 * ($qx - $nx); $c2y = $ny + 2 / 3 * ($qy - $ny)
        $f = { param($x, $y) New-Object System.Drawing.PointF(($cx + ($x - 59) * $scale), ($cy + ($y - 48) * $scale)) }
        $g.AddBezier((& $f $px $py), (& $f $c1x $c1y), (& $f $c2x $c2y), (& $f $nx $ny))
        $nx = $nx; $ny = $ny
      }
      $px = $nx; $py = $ny
    }
    $out += $g
  }
  $out
}

# size px, tile = rounded square (null for transparent), markFrac = mark width / size
function New-Icon([int]$size, [bool]$tile, $fg, [double]$markFrac) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
  if ($tile) {
    $r = $size * 36 / 210 * 2
    $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
    $tp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tp.AddArc(0, 0, $r, $r, 180, 90); $tp.AddArc($size - $r, 0, $r, $r, 270, 90)
    $tp.AddArc($size - $r, $size - $r, $r, $r, 0, 90); $tp.AddArc(0, $size - $r, $r, $r, 90, 90); $tp.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush($graphite)), $tp)
  }
  $scale = $size * $markFrac / 92   # the mark spans ~92 SVG units including stroke
  $pen = New-Object System.Drawing.Pen($fg, [float](10 * $scale))
  $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
  foreach ($m in (Get-Mark $scale ($size / 2) ($size / 2))) { $g.DrawPath($pen, $m) }
  $g.Dispose(); $bmp
}

function Save-Png($bmp, $path) { New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null; $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }

function Save-Ico($sizes, $path) {
  $imgs = foreach ($s in $sizes) { $b = New-Icon $s $true $ivory 0.5; $ms = New-Object System.IO.MemoryStream; $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() }
  $fs = [System.IO.File]::Create($path); $w = New-Object System.IO.BinaryWriter($fs)
  $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
  $off = 6 + 16 * $sizes.Count
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $d = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$d); $w.Write([byte]$d); $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$imgs[$i].Length); $w.Write([uint32]$off); $off += $imgs[$i].Length
  }
  foreach ($i in $imgs) { $w.Write($i) }
  $w.Close()
}

Save-Ico @(16, 24, 32, 48, 64, 128, 256) "$root/app/windows/runner/resources/app_icon.ico"
Save-Png (New-Icon 64 $true $ivory 0.56) "$root/daemon/icon.png"
Save-Png (New-Icon 512 $true $ivory 0.5) "$root/docs/design/alero-icon-512.png"
# Legacy launcher icons (Android < 8); Android 8+ uses the adaptive vectors.
foreach ($d in @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }.GetEnumerator()) {
  Save-Png (New-Icon $d.Value $true $ivory 0.5) "$root/app/android/app/src/main/res/mipmap-$($d.Key)/ic_launcher.png"
}
Write-Host 'icons written'
