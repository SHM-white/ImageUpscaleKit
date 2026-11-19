$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Assert($Cond, [string]$Msg) {
    if (-not $Cond) { throw "Assertion failed: $Msg" }
}

function Initialize-TestMetrics {
    if ('ImageUpscaleKit.Metrics.ImageMetricsCalculator' -as [type]) { return }
    Add-Type -AssemblyName System.Drawing
    $null = [System.Drawing.Bitmap]
    $refMap = @{}
    $psRefDir = Join-Path $PSHOME 'ref'
    if (Test-Path -LiteralPath $psRefDir -PathType Container) {
        foreach ($f in Get-ChildItem -LiteralPath $psRefDir -Filter '*.dll' -File) { $refMap[$f.Name] = $f.FullName }
    }
    foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
        if ($asm.IsDynamic -or [string]::IsNullOrEmpty($asm.Location)) { continue }
        $name = [IO.Path]::GetFileName($asm.Location)
        if (-not $refMap.ContainsKey($name)) { $refMap[$name] = $asm.Location }
    }
    $source = Get-Content -LiteralPath (Join-Path $root 'src\ImageMetrics.cs') -Raw -Encoding UTF8
    Add-Type -ReferencedAssemblies @($refMap.Values) -TypeDefinition $source -Language CSharp
}

Initialize-TestMetrics
Add-Type -AssemblyName System.Drawing

$work = Join-Path $root ('temp/bench-test-' + [guid]::NewGuid().ToString('N'))
$dir = Join-Path $work '中文 评测集'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

try {
    # 1. Analytical PSNR / SSIM / Alignment tests
    $refImg = Join-Path $dir 'ref.png'
    $plus10Img = Join-Path $dir 'plus10.png'
    $mildBlurImg = Join-Path $dir 'mild.png'
    $heavyBlurImg = Join-Path $dir 'heavy.png'
    $halfSizeImg = Join-Path $dir 'half.png'

    $bRef = [System.Drawing.Bitmap]::new(64, 64, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bPlus10 = [System.Drawing.Bitmap]::new(64, 64, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt 64; $y++) {
        for ($x = 0; $x -lt 64; $x++) {
            $r = 40 + (($x * 3) % 160)
            $g = 50 + (($y * 2) % 150)
            $b = 60 + ((($x + $y) * 2) % 140)
            $bRef.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $r, $g, $b))
            $bPlus10.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $r + 10, $g + 10, $b + 10))
        }
    }
    try {
        $bRef.Save($refImg, [System.Drawing.Imaging.ImageFormat]::Png)
        $bPlus10.Save($plus10Img, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bRef.Dispose(); $bPlus10.Dispose() }

    function Make-Blurred([string]$Src, [string]$Dst, [int]$MidSize) {
        $orig = [System.Drawing.Image]::FromFile($Src)
        $mid = [System.Drawing.Bitmap]::new($MidSize, $MidSize)
        $fin = [System.Drawing.Bitmap]::new(64, 64)
        $g1 = [System.Drawing.Graphics]::FromImage($mid)
        $g2 = [System.Drawing.Graphics]::FromImage($fin)
        try {
            $g1.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Bilinear
            $g1.DrawImage($orig, 0, 0, $MidSize, $MidSize)
            $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Bilinear
            $g2.DrawImage($mid, 0, 0, 64, 64)
            $fin.Save($Dst, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $g2.Dispose(); $g1.Dispose(); $fin.Dispose(); $mid.Dispose(); $orig.Dispose() }
    }
    Make-Blurred $refImg $mildBlurImg 32
    Make-Blurred $refImg $heavyBlurImg 12

    $halfBmp = [System.Drawing.Bitmap]::new(32, 32)
    $gh = [System.Drawing.Graphics]::FromImage($halfBmp)
    $srcIm = [System.Drawing.Image]::FromFile($refImg)
    try {
        $gh.DrawImage($srcIm, 0, 0, 32, 32)
        $halfBmp.Save($halfSizeImg, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $srcIm.Dispose(); $gh.Dispose(); $halfBmp.Dispose() }

    $mSame = [ImageUpscaleKit.Metrics.ImageMetricsCalculator]::CompareFiles($refImg, $refImg)
    Assert ([double]::IsPositiveInfinity($mSame.PsnrRgb) -and [double]::IsPositiveInfinity($mSame.PsnrY)) 'Identical image PSNR must be Infinity'
    Assert ([Math]::Abs($mSame.SsimY - 1.0) -lt 1e-6) "Identical image SSIM must be 1.0, got $($mSame.SsimY)"
    Assert ($mSame.ExactSizeMatch -and $mSame.AlignmentPolicy -eq 'exact') 'Expected exact alignment'

    $m10 = [ImageUpscaleKit.Metrics.ImageMetricsCalculator]::CompareFiles($refImg, $plus10Img)
    $expectedPsnr10 = 20.0 * [Math]::Log10(255.0 / 10.0) # 28.1308 dB
    Assert ([Math]::Abs($m10.PsnrRgb - $expectedPsnr10) -lt 0.02) "Expected +10 PSNR_RGB ~$expectedPsnr10, got $($m10.PsnrRgb)"
    Assert ([Math]::Abs($m10.PsnrY - $expectedPsnr10) -lt 0.05) "Expected +10 PSNR_Y ~$expectedPsnr10, got $($m10.PsnrY)"

    $mMild = [ImageUpscaleKit.Metrics.ImageMetricsCalculator]::CompareFiles($refImg, $mildBlurImg)
    $mHeavy = [ImageUpscaleKit.Metrics.ImageMetricsCalculator]::CompareFiles($refImg, $heavyBlurImg)
    Assert ($mMild.PsnrY -gt $mHeavy.PsnrY -and $mMild.SsimY -gt $mHeavy.SsimY) 'Mild blur should outperform heavy blur on both PSNR and SSIM'

    $mAligned = [ImageUpscaleKit.Metrics.ImageMetricsCalculator]::CompareFiles($refImg, $halfSizeImg)
    Assert ((-not $mAligned.ExactSizeMatch) -and $mAligned.AlignmentPolicy -eq 'bicubic_aligned_to_hr') "Expected bicubic alignment policy, got $($mAligned.AlignmentPolicy)"

    # 2. Generate 6-category test set
    $datasetDir = Join-Path $dir 'dataset'
    $dsManifest = & (Join-Path $root 'tests\benchmark\Generate-TestSet.ps1') -OutputDir $datasetDir
    Assert (Test-Path -LiteralPath $dsManifest -PathType Leaf) 'dataset_manifest.json missing'
    $dsObj = Get-Content -LiteralPath $dsManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($dsObj.items.Count -eq 6) "Expected 6 benchmark categories, got $($dsObj.items.Count)"
    foreach ($it in $dsObj.items) {
        Assert (Test-Path -LiteralPath $it.hr_path) "Missing HR: $($it.hr_path)"
        Assert (Test-Path -LiteralPath $it.lr_x2_path) "Missing LR x2: $($it.lr_x2_path)"
        Assert (Test-Path -LiteralPath $it.lr_x4_path) "Missing LR x4: $($it.lr_x4_path)"
    }

    # 3. End-to-end Benchmark.ps1 run (runs real installed local backends & records clean skips)
    $benchOut = Join-Path $dir 'bench_out'
    $res = & (Join-Path $root 'Benchmark.ps1') -TestSetDir $datasetDir -OutputDir $benchOut -Scale 2 -AcProcessor auto
    Assert (Test-Path -LiteralPath $res.CsvPath -PathType Leaf) 'Missing benchmark_results.csv'
    Assert (Test-Path -LiteralPath $res.ReportPath -PathType Leaf) 'Missing benchmark_report.md'
    Assert (Test-Path -LiteralPath $res.ComparisonManifestPath -PathType Leaf) 'Missing comparison_manifest.json'

    $compObj = Get-Content -LiteralPath $res.ComparisonManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($compObj.items.Count -eq 6) 'comparison_manifest.json should cover all 6 images'

    Write-Host '--- Benchmark Report Preview ---'
    Get-Content -LiteralPath $res.ReportPath -Raw | Write-Host
    Write-Host 'PASS: Analytical PSNR/SSIM/Alignment metrics, 6-category dataset synthesis, and end-to-end Benchmark.ps1.'
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'bench-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
