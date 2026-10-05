# Renders the Buy Me a Coffee cover for the "Zeppilwow Addons" profile
# (1600 x 400) to bmc-cover.png in the repo root.
#   powershell -File tools\make-bmc-cover.ps1
# Uses the fonts bundled with Better Damage Text and its flame logo.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root  = Split-Path -Parent $PSScriptRoot
$fonts = Join-Path $root 'BetterDamageText\Fonts'
$out   = Join-Path $root 'bmc-cover.png'

$W = 1600; $H = 400
$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

function C($html) { [System.Drawing.ColorTranslator]::FromHtml($html) }
function A($alpha, $color) { [System.Drawing.Color]::FromArgb($alpha, $color.R, $color.G, $color.B) }

# background: the same dark as the logo's own background
$logo = [System.Drawing.Bitmap]::FromFile((Join-Path $root 'logo.png'))
$bg = $logo.GetPixel(2, 2)
$g.Clear($bg)

function Glow($cx, $cy, $r, $color) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddEllipse([single]($cx - $r), [single]($cy - $r), [single](2 * $r), [single](2 * $r))
    $b = New-Object System.Drawing.Drawing2D.PathGradientBrush($p)
    $b.CenterColor = $color
    $b.SurroundColors = [System.Drawing.Color[]]@((A 0 $color))
    $g.FillPath($b, $p)
    $b.Dispose(); $p.Dispose()
}
Glow 260 170 520 (A 80 (C '#FF6A14'))
Glow 1320 210 460 (A 60 (C '#FFB400'))

# fonts bundled with the addon
$pfc = New-Object System.Drawing.Text.PrivateFontCollection
foreach ($f in 'LuckiestGuy-Regular.ttf', 'BebasNeue-Regular.ttf') { $pfc.AddFontFile((Join-Path $fonts $f)) }
function Family($name) {
    $fam = $pfc.Families | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fam) { throw "font '$name' not found; have: $(($pfc.Families | ForEach-Object Name) -join ', ')" }
    $fam
}
$luckiest = Family 'Luckiest Guy'
$bebas    = Family 'Bebas Neue'
$ui = New-Object System.Drawing.FontFamily('Segoe UI')
$fmt = [System.Drawing.StringFormat]::GenericTypographic

function TextPath($text, $family, $size, $x, $y) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddString($text, $family, 0, [single]$size, (New-Object System.Drawing.PointF([single]$x, [single]$y)), $fmt)
    $p
}

# WoW-style text: drop shadow, black outline, gradient fill
function GameText($text, $family, $size, $x, $y, $fillTop, $fillBottom, $outline, $alpha) {
    $p = TextPath $text $family $size $x $y
    $b = $p.GetBounds()
    $shadow = New-Object System.Drawing.SolidBrush((A ([int](0.55 * $alpha)) (C '#000000')))
    $shadowPen = New-Object System.Drawing.Pen((A ([int](0.55 * $alpha)) (C '#000000')), [single]$outline)
    $shadowPen.LineJoin = 'Round'
    $g.TranslateTransform(3, 4)
    $g.DrawPath($shadowPen, $p); $g.FillPath($shadow, $p)
    $g.ResetTransform()
    $pen = New-Object System.Drawing.Pen((A $alpha (C '#000000')), [single]$outline)
    $pen.LineJoin = 'Round'
    $g.DrawPath($pen, $p)
    $rect = New-Object System.Drawing.RectangleF($b.X, ($b.Y - 1), $b.Width, ($b.Height + 2))
    $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (A $alpha $fillTop), (A $alpha $fillBottom), [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($fill, $p)
    $fill.Dispose(); $pen.Dispose(); $shadow.Dispose(); $shadowPen.Dispose(); $p.Dispose()
    $b
}

# the flame logo with its square background keyed out
$attr = New-Object System.Drawing.Imaging.ImageAttributes
$lo = [System.Drawing.Color]::FromArgb([Math]::Max(0, $bg.R - 10), [Math]::Max(0, $bg.G - 10), [Math]::Max(0, $bg.B - 10))
$hi = [System.Drawing.Color]::FromArgb([Math]::Min(255, $bg.R + 10), [Math]::Min(255, $bg.G + 10), [Math]::Min(255, $bg.B + 10))
$attr.SetColorKey($lo, $hi)
function DrawLogo($x, $y, $size) {
    $dest = New-Object System.Drawing.Rectangle([int]$x, [int]$y, [int]$size, [int]$size)
    $g.DrawImage($logo, $dest, 0, 0, $logo.Width, $logo.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
}

$goldLight = C '#FFF08A'
$goldDeep  = C '#FFAA00'
$white     = C '#FFFFFF'
$grey      = C '#C9C9D1'
$glyphGold = C '#E9B94E'

# ---- left: profile name, tagline, one line about the coffee
$tb = GameText 'Zeppilwow Addons' $luckiest 96 92 76 $goldLight $goldDeep 12 255
$tag = TextPath 'Addons for World of Warcraft: Forever' $bebas 54 98 ($tb.Bottom + 16)
$g.FillPath((New-Object System.Drawing.SolidBrush($white)), $tag)
$tagB = $tag.GetBounds(); $tag.Dispose()
$sub = New-Object System.Drawing.Font($ui, 25, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$g.DrawString(('Free addons  ' + [char]0x00B7 + '  Your coffee keeps the updates coming'), $sub, (New-Object System.Drawing.SolidBrush($grey)), [single]98, [single]($tagB.Bottom + 16))

# ---- right: an action bar of addon slots. The first is Better Damage Text,
# the rest hint at more to come. Add new addon icons here as they ship.
function RoundedRect($x, $y, $w, $h, $r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90)
    $p.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
    $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), [single]$d, [single]$d, 0, 90)
    $p.AddArc([single]$x, [single]($y + $h - $d), [single]$d, [single]$d, 90, 90)
    $p.CloseFigure()
    $p
}
function Slot($x, $y, $size) {
    $shadow = RoundedRect ($x + 3) ($y + 5) $size $size 10
    $g.FillPath((New-Object System.Drawing.SolidBrush((A 140 (C '#000000')))), $shadow); $shadow.Dispose()
    $p = RoundedRect $x $y $size $size 10
    $rect = New-Object System.Drawing.RectangleF([single]$x, [single]$y, [single]$size, [single]$size)
    $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C '#26262e'), (C '#101014'), [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($fill, $p); $fill.Dispose()
    $pen = New-Object System.Drawing.Pen((C '#9A7A33'), 3)
    $g.DrawPath($pen, $p); $pen.Dispose()
    $inner = RoundedRect ($x + 3) ($y + 3) ($size - 6) ($size - 6) 8
    $pen2 = New-Object System.Drawing.Pen((A 90 (C '#000000')), 2)
    $g.DrawPath($pen2, $inner); $pen2.Dispose(); $inner.Dispose(); $p.Dispose()
}
$glyphBrush = New-Object System.Drawing.SolidBrush((A 225 $glyphGold))
$holeBrush  = New-Object System.Drawing.SolidBrush((C '#1a1a20'))

function Gear($cx, $cy) {
    $pts = @()
    for ($i = 0; $i -lt 16; $i++) {
        if ($i % 2 -eq 0) { $r = 30 } else { $r = 22 }
        $a0 = ($i * 22.5 - 6) * [Math]::PI / 180
        $a1 = ($i * 22.5 + 6) * [Math]::PI / 180
        $pts += New-Object System.Drawing.PointF([single]($cx + $r * [Math]::Cos($a0)), [single]($cy + $r * [Math]::Sin($a0)))
        $pts += New-Object System.Drawing.PointF([single]($cx + $r * [Math]::Cos($a1)), [single]($cy + $r * [Math]::Sin($a1)))
    }
    $g.FillPolygon($glyphBrush, [System.Drawing.PointF[]]$pts)
    $g.FillEllipse($holeBrush, [single]($cx - 10), [single]($cy - 10), [single]20, [single]20)
}
function Shield($cx, $cy) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.StartFigure()
    $p.AddLine([single]($cx - 26), [single]($cy - 26), [single]($cx + 26), [single]($cy - 26))
    $p.AddLine([single]($cx + 26), [single]($cy - 26), [single]($cx + 26), [single]($cy + 2))
    $p.AddBezier([single]($cx + 26), [single]($cy + 2), [single]($cx + 26), [single]($cy + 20), [single]($cx + 10), [single]($cy + 28), [single]$cx, [single]($cy + 32))
    $p.AddBezier([single]$cx, [single]($cy + 32), [single]($cx - 10), [single]($cy + 28), [single]($cx - 26), [single]($cy + 20), [single]($cx - 26), [single]($cy + 2))
    $p.CloseFigure()
    $g.FillPath($glyphBrush, $p); $p.Dispose()
    $g.FillRectangle($holeBrush, [single]($cx - 3), [single]($cy - 16), [single]6, [single]34)
    $g.FillRectangle($holeBrush, [single]($cx - 14), [single]($cy - 8), [single]28, [single]6)
}
function Bars($cx, $cy) {
    $heights = 22, 42, 32
    for ($i = 0; $i -lt 3; $i++) {
        $h = $heights[$i]
        $x = $cx - 26 + $i * 19
        $g.FillRectangle($glyphBrush, [single]$x, [single]($cy + 24 - $h), [single]14, [single]$h)
    }
}
function Plus($cx, $cy) {
    $b = New-Object System.Drawing.SolidBrush((A 120 $glyphGold))
    $g.FillRectangle($b, [single]($cx - 4), [single]($cy - 22), [single]8, [single]44)
    $g.FillRectangle($b, [single]($cx - 22), [single]($cy - 4), [single]44, [single]8)
    $b.Dispose()
}

$size = 84; $gap = 18
$slotY = 158
$x = 1096
Slot $x $slotY $size; DrawLogo ($x + 6) ($slotY + 6) ($size - 12)
$x += $size + $gap; Slot $x $slotY $size; Gear   ($x + $size / 2) ($slotY + $size / 2)
$x += $size + $gap; Slot $x $slotY $size; Shield ($x + $size / 2) ($slotY + $size / 2 - 2)
$x += $size + $gap; Slot $x $slotY $size; Bars   ($x + $size / 2) ($slotY + $size / 2)
$x += $size + $gap; Slot $x $slotY $size; Plus   ($x + $size / 2) ($slotY + $size / 2)

# ---- bottom accent line
$lineRect = New-Object System.Drawing.Rectangle(0, ($H - 4), $W, 4)
$line = New-Object System.Drawing.Drawing2D.LinearGradientBrush($lineRect, (A 0 $goldDeep), (A 0 $goldDeep), [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
$blend = New-Object System.Drawing.Drawing2D.ColorBlend(3)
$blend.Colors = [System.Drawing.Color[]]@((A 0 $goldDeep), (A 230 $goldDeep), (A 0 $goldDeep))
$blend.Positions = [single[]]@(0, 0.5, 1)
$line.InterpolationColors = $blend
$g.FillRectangle($line, $lineRect)

$g.Dispose()
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose(); $logo.Dispose()
Write-Output "saved $out"
