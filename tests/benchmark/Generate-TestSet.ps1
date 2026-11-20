param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dataset'),
    [int]$Size = 512
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$hrDir = Join-Path $OutputDir 'hr'
$lr2Dir = Join-Path $OutputDir 'lr_x2'
$lr4Dir = Join-Path $OutputDir 'lr_x4'
New-Item -ItemType Directory -Force -Path $hrDir, $lr2Dir, $lr4Dir | Out-Null

function Save-ResizedPng([string]$SrcPath, [string]$DestPath, [int]$W, [int]$H) {
    $bytes = [IO.File]::ReadAllBytes($SrcPath)
    $ms = [IO.MemoryStream]::new($bytes, $false)
    $img = [System.Drawing.Image]::FromStream($ms, $false, $true)
    $dst = [System.Drawing.Bitmap]::new($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    try {
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.DrawImage($img, [System.Drawing.Rectangle]::new(0, 0, $W, $H))
        $dst.Save($DestPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $g.Dispose(); $dst.Dispose(); $img.Dispose(); $ms.Dispose()
    }
}

function Save-DegradedJpegBlurred([string]$SrcPath, [string]$DestPath, [int]$W, [int]$H, [long]$JpegQuality = 35) {
    $bytes = [IO.File]::ReadAllBytes($SrcPath)
    $ms = [IO.MemoryStream]::new($bytes, $false)
    $img = [System.Drawing.Image]::FromStream($ms, $false, $true)
    # Two-step slight down/up blur + JPEG Q35 recompression to simulate compressed web imagery.
    $blurW = [Math]::Max(32, [int]($W * 0.72))
    $blurH = [Math]::Max(32, [int]($H * 0.72))
    $b1 = [System.Drawing.Bitmap]::new($blurW, $blurH)
    $b2 = [System.Drawing.Bitmap]::new($W, $H)
    $g1 = [System.Drawing.Graphics]::FromImage($b1)
    $g2 = [System.Drawing.Graphics]::FromImage($b2)
    $jpgMs = [IO.MemoryStream]::new()
    try {
        $g1.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Bilinear
        $g1.DrawImage($img, 0, 0, $blurW, $blurH)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Bilinear
        $g2.DrawImage($b1, 0, 0, $W, $H)

        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
        $encParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
        $encParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, $JpegQuality)
        $b2.Save($jpgMs, $codec, $encParams)
        $jpgMs.Position = 0
        $reloaded = [System.Drawing.Image]::FromStream($jpgMs)
        try {
            $reloaded.Save($DestPath, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $reloaded.Dispose() }
    } finally {
        $jpgMs.Dispose(); $g2.Dispose(); $g1.Dispose(); $b2.Dispose(); $b1.Dispose(); $img.Dispose(); $ms.Dispose()
    }
}

$s = $Size
$categories = @(
    @{ File = '01_anime_character.png'; Type = '动漫人物'; Focus = '五官、眼睛高光、发丝线条、手部轮廓、服装边界一致性'; Degrade = 'bicubic' },
    @{ File = '02_illustration_lineart.png'; Type = '插画/线稿'; Focus = '黑色弧线连续性、网格阴影、锯齿与色块溢色'; Degrade = 'bicubic' },
    @{ File = '03_realistic_portrait.png'; Type = '真实人像'; Focus = '皮肤过渡、眉眼细节、毛发自然度与质感真实性'; Degrade = 'bicubic' },
    @{ File = '04_nature_landscape.png'; Type = '自然风景'; Focus = '树叶高频纹理、建筑砖缝、远景天空平滑度'; Degrade = 'bicubic' },
    @{ File = '05_text_screenshot.png'; Type = '文字/截图'; Focus = '中英文字号可读性、笔画粘连、1px UI 边框清晰度'; Degrade = 'bicubic' },
    @{ File = '06_blur_compressed.png'; Type = '模糊和压缩图'; Focus = 'JPEG 块状振铃伪影去除、边缘去模糊与细节重建'; Degrade = 'blur_jpeg35' }
)

# 1. Anime Character (cel-shaded face, eyes, hair strands, hand & outfit)
$bmp = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $bg = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.Point]::new(0, 0), [System.Drawing.Point]::new(0, $s), [System.Drawing.Color]::FromArgb(220, 236, 255), [System.Drawing.Color]::FromArgb(245, 248, 255))
    $g.FillRectangle($bg, 0, 0, $s, $s); $bg.Dispose()
    # Jacket / collar
    $jacket = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(44, 62, 110))
    $g.FillPolygon($jacket, [System.Drawing.Point[]]@(
        [System.Drawing.Point]::new(110, $s), [System.Drawing.Point]::new(170, 320),
        [System.Drawing.Point]::new(342, 320), [System.Drawing.Point]::new(402, $s)
    ))
    $jacket.Dispose()
    # White collar + red ribbon
    $g.FillPolygon([System.Drawing.Brushes]::White, [System.Drawing.Point[]]@(
        [System.Drawing.Point]::new(195, 320), [System.Drawing.Point]::new(256, 405), [System.Drawing.Point]::new(317, 320)
    ))
    $g.FillPolygon([System.Drawing.Brushes]::Crimson, [System.Drawing.Point[]]@(
        [System.Drawing.Point]::new(244, 385), [System.Drawing.Point]::new(220, 445), [System.Drawing.Point]::new(256, 415), [System.Drawing.Point]::new(292, 445), [System.Drawing.Point]::new(268, 385)
    ))
    # Face & cel shadow
    $skin = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 224, 200))
    $skinShadow = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(236, 195, 168))
    $g.FillEllipse($skin, 172, 120, 168, 195)
    $g.FillRectangle($skinShadow, 236, 295, 40, 42)
    $outline = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(45, 30, 35), [float]3)
    $g.DrawEllipse($outline, 172, 120, 168, 195)
    # Eyes with iris gradient & specular highlights
    foreach ($ex in @(205, 275)) {
        $g.FillEllipse([System.Drawing.Brushes]::White, $ex, 196, 36, 42)
        $g.FillEllipse([System.Drawing.Brushes]::RoyalBlue, $ex + 6, 200, 24, 34)
        $g.FillEllipse([System.Drawing.Brushes]::MidnightBlue, $ex + 12, 209, 12, 16)
        $g.FillEllipse([System.Drawing.Brushes]::White, $ex + 8, 203, 9, 9)
        $g.FillEllipse([System.Drawing.Brushes]::White, $ex + 22, 224, 4, 4)
        $g.DrawArc($outline, $ex - 2, 192, 40, 24, 195, 150)
    }
    $g.DrawArc($outline, 242, 268, 28, 14, 15, 150)
    # Hair strands
    $hairBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(52, 42, 86))
    $g.FillPie($hairBrush, 150, 74, 212, 180, 180, 180)
    for ($i = 0; $i -lt 9; $i++) {
        $hx = 165 + $i * 22
        $g.FillPolygon($hairBrush, [System.Drawing.Point[]]@(
            [System.Drawing.Point]::new($hx, 140), [System.Drawing.Point]::new($hx + 12, 140), [System.Drawing.Point]::new($hx + 4, 195 + ($i % 3) * 14)
        ))
        $g.DrawLine($outline, $hx, 140, $hx + 4, 195 + ($i % 3) * 14)
    }
    # Hand raised near shoulder (5 fine fingers for finger-consistency test)
    $g.FillEllipse($skin, 118, 352, 46, 54)
    for ($f = 0; $f -lt 5; $f++) {
        $fx = 116 + $f * 10
        $g.FillRectangle($skin, $fx, 322 + [Math]::Abs($f - 2) * 4, 8, 34)
        $g.DrawRectangle([System.Drawing.Pens]::Sienna, $fx, 322 + [Math]::Abs($f - 2) * 4, 8, 34)
    }
    $skin.Dispose(); $skinShadow.Dispose(); $outline.Dispose(); $hairBrush.Dispose()
    $bmp.Save((Join-Path $hrDir '01_anime_character.png'), [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $g.Dispose(); $bmp.Dispose() }

# 2. Illustration / Lineart
$bmp = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(250, 248, 242))
    $thin = [System.Drawing.Pen]::new([System.Drawing.Color]::Black, [float]1.5)
    $med = [System.Drawing.Pen]::new([System.Drawing.Color]::Black, [float]3)
    $g.FillEllipse([System.Drawing.Brushes]::Moccasin, 96, 96, 320, 320)
    $g.DrawEllipse($med, 96, 96, 320, 320)
    for ($a = 0; $a -lt 360; $a += 15) {
        $rad = $a * [Math]::PI / 180.0
        $g.DrawLine($thin, 256, 256, [int](256 + 210 * [Math]::Cos($rad)), [int](256 + 210 * [Math]::Sin($rad)))
    }
    # Cross-hatching box
    for ($i = 0; $i -lt 180; $i += 8) {
        $g.DrawLine($thin, 40 + $i, 360, 40, 360 + $i)
    }
    $g.DrawBezier($med, [System.Drawing.Point]::new(60, 120), [System.Drawing.Point]::new(200, 30), [System.Drawing.Point]::new(320, 480), [System.Drawing.Point]::new(460, 110))
    $thin.Dispose(); $med.Dispose()
    $bmp.Save((Join-Path $hrDir '02_illustration_lineart.png'), [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $g.Dispose(); $bmp.Dispose() }

# 3. Realistic Portrait (smooth skin lighting gradients, micro-grain, iris/hair)
$bmp = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(38, 42, 50))
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddEllipse(145, 95, 222, 285)
    $pgb = [System.Drawing.Drawing2D.PathGradientBrush]::new($path)
    $pgb.CenterColor = [System.Drawing.Color]::FromArgb(242, 198, 174)
    $pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(165, 118, 96))
    $g.FillPath($pgb, $path)
    $pgb.Dispose(); $path.Dispose()
    # Natural eyes & brows
    foreach ($ex in @(192, 276)) {
        $g.FillEllipse([System.Drawing.Brushes]::WhiteSmoke, $ex, 212, 44, 24)
        $g.FillEllipse([System.Drawing.Brushes]::SaddleBrown, $ex + 13, 214, 18, 18)
        $g.FillEllipse([System.Drawing.Brushes]::Black, $ex + 18, 219, 8, 8)
        $g.FillEllipse([System.Drawing.Brushes]::White, $ex + 22, 217, 3, 3)
        $brow = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(65, 42, 30), [float]5)
        $g.DrawArc($brow, $ex - 4, 194, 52, 16, 195, 150)
        $brow.Dispose()
    }
    # Subtle deterministic skin/fabric micro-texture
    $rng = [Random]::new(2026)
    for ($k = 0; $k -lt 4500; $k++) {
        $px = $rng.Next(150, 360)
        $py = $rng.Next(110, 370)
        $c = $bmp.GetPixel($px, $py)
        $d = $rng.Next(-6, 7)
        $bmp.SetPixel($px, $py, [System.Drawing.Color]::FromArgb(
            [Math]::Clamp($c.R + $d, 0, 255),
            [Math]::Clamp($c.G + $d, 0, 255),
            [Math]::Clamp($c.B + $d, 0, 255)))
    }
    $bmp.Save((Join-Path $hrDir '03_realistic_portrait.png'), [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $g.Dispose(); $bmp.Dispose() }

# 4. Nature Landscape (sky, stone/brick building, fine foliage)
$bmp = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $sky = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.Point]::new(0, 0), [System.Drawing.Point]::new(0, 320), [System.Drawing.Color]::FromArgb(65, 138, 215), [System.Drawing.Color]::FromArgb(198, 228, 248))
    $g.FillRectangle($sky, 0, 0, $s, 320); $sky.Dispose()
    $g.FillRectangle([System.Drawing.Brushes]::ForestGreen, 0, 320, $s, $s - 320)
    # Brick tower / building with window grid
    $g.FillRectangle([System.Drawing.Brushes]::Sienna, 290, 150, 160, 220)
    for ($by = 158; $by -lt 365; $by += 14) {
        $g.DrawLine([System.Drawing.Pens]::Peru, 290, $by, 450, $by)
    }
    for ($wx = 310; $wx -le 410; $wx += 45) {
        for ($wy = 175; $wy -le 295; $wy += 45) {
            $g.FillRectangle([System.Drawing.Brushes]::LightSkyBlue, $wx, $wy, 26, 30)
            $g.DrawRectangle([System.Drawing.Pens]::DarkSlateGray, $wx, $wy, 26, 30)
        }
    }
    # Foliage leaf clusters
    $rng = [Random]::new(77)
    for ($i = 0; $i -lt 550; $i++) {
        $lx = $rng.Next(25, 250)
        $ly = $rng.Next(180, 420)
        $shade = $rng.Next(60, 185)
        $leaf = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(30, $shade, 40))
        $g.FillEllipse($leaf, $lx, $ly, $rng.Next(6, 16), $rng.Next(4, 12))
        $leaf.Dispose()
    }
    $bmp.Save((Join-Path $hrDir '04_nature_landscape.png'), [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $g.Dispose(); $bmp.Dispose() }

# 5. Text / UI Screenshot (English + Chinese + 1px borders)
$bmp = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear([System.Drawing.Color]::FromArgb(248, 250, 252))
    $g.FillRectangle([System.Drawing.Brushes]::White, 24, 24, 464, 464)
    $g.DrawRectangle([System.Drawing.Pens]::SteelBlue, 24, 24, 464, 464)
    $fTitle = [System.Drawing.Font]::new('Microsoft YaHei', 18, [System.Drawing.FontStyle]::Bold)
    $fBody = [System.Drawing.Font]::new('Microsoft YaHei', 11)
    $fSmall = [System.Drawing.Font]::new('Consolas', 9)
    $g.DrawString('超分辨率文字清晰度测试', $fTitle, [System.Drawing.Brushes]::Black, 42, 42)
    $g.DrawString('ImageUpscaleKit Benchmark 2026 - 1234567890', $fBody, [System.Drawing.Brushes]::DarkSlateBlue, 42, 96)
    $g.DrawString('细节对比：繁體中文 / 简体中文 / ABCDEFG abcdefg', $fBody, [System.Drawing.Brushes]::Black, 42, 134)
    $g.DrawString('Small UI Text 9pt: Tile=512, PSNR=32.45dB, SSIM=0.9412', $fSmall, [System.Drawing.Brushes]::DimGray, 42, 180)
    $g.FillRectangle([System.Drawing.Brushes]::DodgerBlue, 42, 230, 140, 38)
    $g.DrawString('开始处理 Start', $fBody, [System.Drawing.Brushes]::White, 58, 238)
    $g.DrawRectangle([System.Drawing.Pens]::Gray, 42, 290, 420, 160)
    $g.DrawString('0123456789  ABCDEFGHIJKLMNOPQRSTUVWXYZ  @ # % & *', $fSmall, [System.Drawing.Brushes]::Black, 54, 312)
    $fTitle.Dispose(); $fBody.Dispose(); $fSmall.Dispose()
    $bmp.Save((Join-Path $hrDir '05_text_screenshot.png'), [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $g.Dispose(); $bmp.Dispose() }

# 6. Sharp HR reference for Blur & JPEG Compression test
$bmp = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(24, 30, 44))
    for ($y = 40; $y -lt 472; $y += 24) {
        $col = [System.Drawing.Color]::FromArgb(80 + ($y % 150), 180, 255 - ($y % 120))
        $pen = [System.Drawing.Pen]::new($col, [float]2)
        $g.DrawLine($pen, 40, $y, 472, $y + 12)
        $pen.Dispose()
    }
    $g.FillRectangle([System.Drawing.Brushes]::Gold, 110, 110, 120, 120)
    $g.FillEllipse([System.Drawing.Brushes]::Crimson, 270, 260, 140, 140)
    $f = [System.Drawing.Font]::new('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
    $g.DrawString('DEBLOCK & SHARPEN', $f, [System.Drawing.Brushes]::White, 108, 200)
    $f.Dispose()
    $bmp.Save((Join-Path $hrDir '06_blur_compressed.png'), [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $g.Dispose(); $bmp.Dispose() }

# Generate LR x2 / x4 pairs for all HR files (including any user-added HR files)
$manifestItems = [System.Collections.Generic.List[object]]::new()
$catLookup = @{}
foreach ($c in $categories) { $catLookup[$c.File] = $c }

foreach ($hrFile in Get-ChildItem -LiteralPath $hrDir -File | Where-Object { $_.Extension -in @('.png', '.jpg', '.jpeg', '.bmp', '.webp') } | Sort-Object Name) {
    $bytes = [IO.File]::ReadAllBytes($hrFile.FullName)
    $ms = [IO.MemoryStream]::new($bytes, $false)
    $im = [System.Drawing.Image]::FromStream($ms, $false, $true)
    $hw = $im.Width; $hh = $im.Height
    $im.Dispose(); $ms.Dispose()

    $lr2Path = Join-Path $lr2Dir ($hrFile.BaseName + '.png')
    $lr4Path = Join-Path $lr4Dir ($hrFile.BaseName + '.png')
    $meta = $catLookup[$hrFile.Name]

    if ($meta -and $meta.Degrade -eq 'blur_jpeg35') {
        Save-DegradedJpegBlurred $hrFile.FullName $lr2Path ([Math]::Max(16, [int]($hw / 2))) ([Math]::Max(16, [int]($hh / 2))) 35
        Save-DegradedJpegBlurred $hrFile.FullName $lr4Path ([Math]::Max(16, [int]($hw / 4))) ([Math]::Max(16, [int]($hh / 4))) 35
    } else {
        Save-ResizedPng $hrFile.FullName $lr2Path ([Math]::Max(16, [int]($hw / 2))) ([Math]::Max(16, [int]($hh / 2)))
        Save-ResizedPng $hrFile.FullName $lr4Path ([Math]::Max(16, [int]($hw / 4))) ([Math]::Max(16, [int]($hh / 4)))
    }

    [void]$manifestItems.Add([pscustomobject]@{
        file = $hrFile.Name
        category = if ($meta) { $meta.Type } else { '自定义图片' }
        focus = if ($meta) { $meta.Focus } else { '自定义画质评估' }
        degradation = if ($meta) { $meta.Degrade } else { 'bicubic' }
        hr_width = $hw
        hr_height = $hh
        hr_path = $hrFile.FullName
        lr_x2_path = $lr2Path
        lr_x4_path = $lr4Path
    })
}

$manifestPath = Join-Path $OutputDir 'dataset_manifest.json'
([pscustomobject]@{
    generated_at = (Get-Date).ToString('o')
    items = @($manifestItems)
}) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

Write-Host "Generated benchmark dataset at: $OutputDir ($($manifestItems.Count) HR/LR pairs)" -ForegroundColor Green
return $manifestPath
