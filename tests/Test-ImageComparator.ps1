$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'ImageComparator.ps1')

Initialize-IUKComparatorTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Assert($Cond, [string]$Msg) {
    if (-not $Cond) { throw "Assertion failed: $Msg" }
}

function Sample-ControlBitmap([System.Windows.Forms.Control]$Ctrl, [int]$W, [int]$H) {
    $Ctrl.Size = [System.Drawing.Size]::new($W, $H)
    $Ctrl.PerformLayout()
    $bmp = [System.Drawing.Bitmap]::new($W, $H)
    $Ctrl.DrawToBitmap($bmp, [System.Drawing.Rectangle]::new(0, 0, $W, $H))
    return $bmp
}

$work = Join-Path $root ('temp/comp-test-' + [guid]::NewGuid().ToString('N'))
$dir = Join-Path $work '中文 对比'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

try {
    $origPath = Join-Path $dir '原图 透明.png'
    $res2xPath = Join-Path $dir '结果 x2.png'
    $res4xPath = Join-Path $dir '结果 x4.png'
    $bigPath = Join-Path $dir '大图 4k.png'

    # 1. Original 200x100: top-left transparent, bottom-left Red, right half Green
    $bmp = [System.Drawing.Bitmap]::new(200, 100, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.FillRectangle([System.Drawing.Brushes]::Red, 0, 50, 100, 50)
        $g.FillRectangle([System.Drawing.Brushes]::Lime, 100, 0, 100, 100)
        $bmp.Save($origPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose(); $bmp.Dispose() }

    # 2. Result 2x (400x200): left half Blue, right half Yellow
    $bmp = [System.Drawing.Bitmap]::new(400, 200, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.FillRectangle([System.Drawing.Brushes]::Blue, 0, 0, 200, 200)
        $g.FillRectangle([System.Drawing.Brushes]::Yellow, 200, 0, 200, 200)
        $bmp.Save($res2xPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose(); $bmp.Dispose() }

    # 3. Result 4x (800x400): solid Cyan
    $bmp = [System.Drawing.Bitmap]::new(800, 400, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Cyan)
        $bmp.Save($res4xPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose(); $bmp.Dispose() }

    # 4. Large 3072x2048 image for mipmap pyramid test
    $bmp = [System.Drawing.Bitmap]::new(3072, 2048, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Purple)
        $bmp.Save($bigPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose(); $bmp.Dispose() }

    # Mipmap pyramid check
    $bigPyr = [ImageUpscaleKit.UI.ImagePyramid]::Load($bigPath)
    try {
        Assert ($bigPyr.LevelCount -ge 2) "Expected mipmap levels >= 2 for 3072x2048, got $($bigPyr.LevelCount)"
        $smallMip = $bigPyr.SelectLevel(400.0)
        $fullMip = $bigPyr.SelectLevel(3000.0)
        Assert ($smallMip.Width -lt 3072) "Expected downscaled mipmap for 400px view, got $($smallMip.Width)"
        Assert ($fullMip.Width -eq 3072) "Expected full-res level for 3000px view, got $($fullMip.Width)"
    } finally { $bigPyr.Dispose() }

    $ctrl = [ImageUpscaleKit.UI.ImageComparatorControl]::new()
    try {
        $ctrl.Size = [System.Drawing.Size]::new(800, 400)
        $ctrl.LoadOriginal($origPath)

        # File lock test: must be able to open exclusively right after LoadOriginal
        $fs = [IO.File]::Open($origPath, 'Open', 'ReadWrite', 'None')
        $fs.Dispose()

        $r2 = [ImageUpscaleKit.UI.ComparatorResultItem]@{ Id = 'x2'; Label = 'ACNet x2'; Engine = 'anime4kcpp'; FilePath = $res2xPath }
        $r4 = [ImageUpscaleKit.UI.ComparatorResultItem]@{ Id = 'x4'; Label = 'RealESRGAN x4'; Engine = 'ncnn'; FilePath = $res4xPath }
        $ctrl.SetResults(@($r2, $r4), 0)

        $fs2 = [IO.File]::Open($res2xPath, 'Open', 'ReadWrite', 'None')
        $fs2.Dispose()

        # Normalized coordinate alignment check
        $ctrl.SetZoomPercent(100.0)
        $leftPane = $ctrl.SideBySideLeftPane
        $rightPane = $ctrl.SideBySideRightPane
        $nl = $ctrl.ScreenToNormalized([System.Drawing.Point]::new([int]($leftPane.Left + $leftPane.Width / 2), [int]($leftPane.Top + $leftPane.Height / 2)), $leftPane, $ctrl.LeftViewport)
        $nr = $ctrl.ScreenToNormalized([System.Drawing.Point]::new([int]($rightPane.Left + $rightPane.Width / 2), [System.Drawing.Point]::new(0, 0).Y + [int]($rightPane.Height / 2)), $rightPane, $ctrl.RightViewport)
        Assert ([Math]::Abs($nl.X - 0.5) -lt 0.02 -and [Math]::Abs($nl.Y - 0.5) -lt 0.02) "Left center normalized mismatch: $($nl.X),$($nl.Y)"
        Assert ([Math]::Abs($nr.X - 0.5) -lt 0.02 -and [Math]::Abs($nr.Y - 0.5) -lt 0.02) "Right center normalized mismatch: $($nr.X),$($nr.Y)"

        # SideBySide render & pixel verification
        $ctrl.ViewMode = [ImageUpscaleKit.UI.CompareViewMode]::SideBySide
        $ctrl.FitToWindow()
        $shot = Sample-ControlBitmap $ctrl 800 400
        try {
            $lr = $ctrl.ComputeImageRect($ctrl.SideBySideLeftPane, $ctrl.LeftViewport)
            $rr = $ctrl.ComputeImageRect($ctrl.SideBySideRightPane, $ctrl.RightViewport)
            # Original bottom-left (0.25, 0.75) should be Red
            $pxOrig = $shot.GetPixel([int]($lr.Left + $lr.Width * 0.25), [int]($lr.Top + $lr.Height * 0.75))
            Assert ($pxOrig.R -gt 220 -and $pxOrig.G -lt 30 -and $pxOrig.B -lt 30) "SideBySide left bottom-left expected Red, got $pxOrig"
            # Original top-left (0.25, 0.25) transparent -> checkerboard grey
            $pxAlpha = $shot.GetPixel([int]($lr.Left + $lr.Width * 0.25), [int]($lr.Top + $lr.Height * 0.25))
            Assert ([Math]::Abs($pxAlpha.R - $pxAlpha.G) -lt 5 -and $pxAlpha.R -ge 45 -and $pxAlpha.R -le 85) "Transparent region expected checkerboard, got $pxAlpha"
            # Result left half (0.25, 0.75) -> Blue
            $pxResL = $shot.GetPixel([int]($rr.Left + $rr.Width * 0.25), [int]($rr.Top + $rr.Height * 0.75))
            Assert ($pxResL.B -gt 220 -and $pxResL.R -lt 30) "SideBySide right left-half expected Blue, got $pxResL"
            # Result right half (0.75, 0.75) -> Yellow
            $pxResR = $shot.GetPixel([int]($rr.Left + $rr.Width * 0.75), [int]($rr.Top + $rr.Height * 0.75))
            Assert ($pxResR.R -gt 220 -and $pxResR.G -gt 220 -and $pxResR.B -lt 30) "SideBySide right right-half expected Yellow, got $pxResR"
        } finally { $shot.Dispose() }

        # Sync OFF independent viewport check
        $ctrl.SyncViewports = $false
        $ctrl.RightViewport.CenterU = 0.8
        $ctrl.RightViewport.Zoom = 2.0
        Assert ([Math]::Abs($ctrl.LeftViewport.CenterU - 0.5) -lt 0.001) 'Unsynced RightViewport modified LeftViewport'
        $ctrl.SyncViewports = $true
        Assert ([Math]::Abs($ctrl.RightViewport.CenterU - 0.5) -lt 0.001) 'Re-enabling sync did not align RightViewport'

        # SplitSlider verification
        $ctrl.ViewMode = [ImageUpscaleKit.UI.CompareViewMode]::SplitSlider
        $ctrl.FitToWindow()
        $ctrl.SplitRatio = 0.25
        $shot25 = Sample-ControlBitmap $ctrl 800 400
        try {
            $sr = $ctrl.ComputeImageRect($ctrl.SplitPane, $ctrl.LeftViewport)
            # u=0.15 (< 0.25) bottom -> Red (Original)
            $pLeft = $shot25.GetPixel([int]($sr.Left + $sr.Width * 0.15), [int]($sr.Top + $sr.Height * 0.75))
            Assert ($pLeft.R -gt 220 -and $pLeft.B -lt 30) "SplitRatio 0.25 left expected Red, got $pLeft"
            # u=0.60 (> 0.25) -> Yellow (Result right half)
            $pRight = $shot25.GetPixel([int]($sr.Left + $sr.Width * 0.60), [int]($sr.Top + $sr.Height * 0.75))
            Assert ($pRight.R -gt 220 -and $pRight.G -gt 220 -and $pRight.B -lt 30) "SplitRatio 0.25 right expected Yellow, got $pRight"
        } finally { $shot25.Dispose() }

        $ctrl.SplitRatio = 0.75
        $shot75 = Sample-ControlBitmap $ctrl 800 400
        try {
            $sr = $ctrl.ComputeImageRect($ctrl.SplitPane, $ctrl.LeftViewport)
            # u=0.60 (< 0.75) -> Lime Green (Original right half)
            $pMid = $shot75.GetPixel([int]($sr.Left + $sr.Width * 0.60), [int]($sr.Top + $sr.Height * 0.75))
            Assert ($pMid.G -gt 220 -and $pMid.R -lt 30) "SplitRatio 0.75 left-of-divider expected Green, got $pMid"
        } finally { $shot75.Dispose() }

        # RoiZoom verification
        $ctrl.ViewMode = [ImageUpscaleKit.UI.CompareViewMode]::RoiZoom
        $ctrl.RoiNormalized = [System.Drawing.RectangleF]::new(0.1, 0.6, 0.2, 0.2)
        $shotRoi1 = Sample-ControlBitmap $ctrl 800 400
        try {
            $op = $ctrl.RoiOriginalPane
            $rp = $ctrl.RoiResultPane
            $po = $shotRoi1.GetPixel([int]($op.Left + $op.Width / 2), [int]($op.Top + $op.Height / 2))
            $pr = $shotRoi1.GetPixel([int]($rp.Left + $rp.Width / 2), [int]($rp.Top + $rp.Height / 2))
            Assert ($po.R -gt 220 -and $po.G -lt 30) "ROI detail original bottom-left expected Red, got $po"
            Assert ($pr.B -gt 220 -and $pr.R -lt 30) "ROI detail result bottom-left expected Blue, got $pr"
        } finally { $shotRoi1.Dispose() }

        $ctrl.RoiNormalized = [System.Drawing.RectangleF]::new(0.7, 0.6, 0.2, 0.2)
        $shotRoi2 = Sample-ControlBitmap $ctrl 800 400
        try {
            $op = $ctrl.RoiOriginalPane
            $rp = $ctrl.RoiResultPane
            $po = $shotRoi2.GetPixel([int]($op.Left + $op.Width / 2), [int]($op.Top + $op.Height / 2))
            $pr = $shotRoi2.GetPixel([int]($rp.Left + $rp.Width / 2), [int]($rp.Top + $rp.Height / 2))
            Assert ($po.G -gt 220 -and $po.R -lt 30) "Moved ROI original expected Green, got $po"
            Assert ($pr.R -gt 220 -and $pr.G -gt 220 -and $pr.B -lt 30) "Moved ROI result expected Yellow, got $pr"
        } finally { $shotRoi2.Dispose() }

        # OverrideMode verification
        $ctrl.ViewMode = [ImageUpscaleKit.UI.CompareViewMode]::SideBySide
        $ctrl.FitToWindow()
        $ctrl.OverrideMode = [ImageUpscaleKit.UI.ImageOverrideMode]::OriginalOnly
        $shotOrig = Sample-ControlBitmap $ctrl 800 400
        try {
            $rFull = $ctrl.ComputeImageRect($ctrl.SplitPane, $ctrl.LeftViewport)
            $p = $shotOrig.GetPixel([int]($rFull.Left + $rFull.Width * 0.75), [int]($rFull.Top + $rFull.Height * 0.75))
            Assert ($p.G -gt 220 -and $p.R -lt 30) "Override OriginalOnly expected Green at 0.75, got $p"
        } finally { $shotOrig.Dispose() }

        $ctrl.OverrideMode = [ImageUpscaleKit.UI.ImageOverrideMode]::ResultOnly
        $shotRes = Sample-ControlBitmap $ctrl 800 400
        try {
            $rFull = $ctrl.ComputeImageRect($ctrl.SplitPane, $ctrl.LeftViewport)
            $p = $shotRes.GetPixel([int]($rFull.Left + $rFull.Width * 0.75), [int]($rFull.Top + $rFull.Height * 0.75))
            Assert ($p.R -gt 220 -and $p.G -gt 220 -and $p.B -lt 30) "Override ResultOnly expected Yellow at 0.75, got $p"
        } finally { $shotRes.Dispose() }
        $ctrl.OverrideMode = [ImageUpscaleKit.UI.ImageOverrideMode]::None

        # Multi-result switching preserving viewport position & physical drawn width
        $ctrl.LeftViewport.CenterU = 0.25
        $ctrl.LeftViewport.CenterV = 0.75
        $ctrl.SetZoomPercent(200.0)
        $physWidthBefore = $ctrl.ReferenceWidth * $ctrl.LeftViewport.Zoom
        $ctrl.SelectResult(1) # switch from 400x200 to 800x400
        $physWidthAfter = $ctrl.ReferenceWidth * $ctrl.LeftViewport.Zoom
        Assert ([Math]::Abs($physWidthBefore - $physWidthAfter) -lt 0.5) "Physical width changed on switch: $physWidthBefore vs $physWidthAfter"
        Assert ([Math]::Abs($ctrl.LeftViewport.CenterU - 0.25) -lt 0.0001) 'CenterU changed on result switch'
        Assert ([Math]::Abs($ctrl.LeftViewport.CenterV - 0.75) -lt 0.0001) 'CenterV changed on result switch'

        # Verify switched result (Cyan) actually paints
        $shotCyan = Sample-ControlBitmap $ctrl 800 400
        try {
            $rr = $ctrl.ComputeImageRect($ctrl.SideBySideRightPane, $ctrl.RightViewport)
            $pc = $shotCyan.GetPixel([int]($ctrl.SideBySideRightPane.Left + $ctrl.SideBySideRightPane.Width / 2), [int]($ctrl.SideBySideRightPane.Top + $ctrl.SideBySideRightPane.Height / 2))
            Assert ($pc.G -gt 200 -and $pc.B -gt 200 -and $pc.R -lt 30) "Switched x4 result expected Cyan, got $pc"
        } finally { $shotCyan.Dispose() }
    } finally { $ctrl.Dispose() }

    # Composite Panel + Resize test + Manifest window test
    $panelWrap = New-IUKComparatorPanel -ShowFileButtons
    $hostForm = [System.Windows.Forms.Form]::new()
    try {
        $hostForm.Size = [System.Drawing.Size]::new(600, 400)
        $hostForm.Controls.Add($panelWrap.Panel)
        $hostForm.CreateControl()
        $hostForm.PerformLayout()
        $panelWrap.Control.LoadOriginal($origPath)
        $panelWrap.Control.LoadResult($res2xPath, 'ACNet x2')
        Assert ($panelWrap.ResultSelector.Items.Count -eq 1) 'ResultSelector count mismatch'
        $hostForm.Size = [System.Drawing.Size]::new(1600, 900)
        $hostForm.PerformLayout()
        Assert ($panelWrap.Control.Width -gt 1400 -and $panelWrap.Control.Height -gt 750) "Comparator did not resize properly: $($panelWrap.Control.Size)"
    } finally { $hostForm.Dispose() }

    $manifestPath = Join-Path $dir 'manifest.json'
    @{
        items = @(
            @{
                name = '样本 01'
                hr_path = $res4xPath
                lr_path = $origPath
                results = @(
                    @{ backend = 'anime4kcpp'; label = 'ACNet x2'; model = 'acnet'; file_path = $res2xPath; elapsed_ms = 42.5 }
                )
            }
        )
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

    $win = Show-IUKComparatorWindow -ManifestPath $manifestPath -TestMode
    try {
        Assert ($win.Comparator.Control.ResultCount -ge 2) 'Manifest results did not load into comparator'
    } finally { $win.Form.Dispose() }

    Write-Host 'PASS: ImageComparator mipmap, lock-free load, SideBySide/Split/ROI/Override, multi-result viewport preservation, resize & manifest.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'comp-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
