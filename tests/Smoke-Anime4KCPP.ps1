# Run with PowerShell 7 after installing Anime4KCPP.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $root 'Upscale.ps1'
$work = Join-Path $root ('temp/acnet-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
function Assert-Image($path,$width,$height) {
    $image = [Drawing.Image]::FromFile($path)
    try { if ($image.Width -ne $width -or $image.Height -ne $height) { throw "Wrong image dimensions: $path" } } finally { $image.Dispose() }
}
function Assert-Fails([scriptblock]$Action,[string]$Pattern) {
    $caught=$false
    try { & $Action } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; $caught=$true }
    if (-not $caught) { throw "Expected error: $Pattern" }
}
try {
    Add-Type -AssemblyName System.Drawing
    $inputs = Join-Path $work '中文 输入'
    New-Item -ItemType Directory -Path $inputs | Out-Null
    $first = Join-Path $inputs '线条 一.png'
    $second = Join-Path $inputs '线条 二.bmp'
    $bitmap = [Drawing.Bitmap]::new(24,16)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::White)
        $graphics.DrawLine([Drawing.Pens]::Black,1,1,22,14)
        $bitmap.Save($first,[Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Save($second,[Drawing.Imaging.ImageFormat]::Bmp)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    $single = Join-Path $work '中文 输出/单图.png'
    & $entry -Engine anime4kcpp -ExistingOutput error -InputPath $first -OutputPath $single -Model acnet-legacy-gan -AcProcessor cpu
    Assert-Image $single 48 32
    $before=(Get-FileHash -LiteralPath $single).Hash
    Assert-Fails { & $entry -Engine anime4kcpp -ExistingOutput error -InputPath $first -OutputPath $single } 'already exists'
    if((Get-FileHash -LiteralPath $single).Hash -ne $before){throw 'Existing output was changed'}
    $batch = Join-Path $work '批量 输出'
    & $entry -Engine anime4kcpp -ExistingOutput error -InputPath $inputs -OutputPath $batch -Model acnet-legacy-hdn0 -AcProcessor auto
    Assert-Image (Join-Path $batch '线条 一.png') 48 32
    Assert-Image (Join-Path $batch '线条 二.png') 48 32
    & $entry -Engine anime4kcpp -ExistingOutput error -InputPath $first -Model acnet-legacy-gan -AcProcessor cpu
    Assert-Image (Join-Path $inputs '线条 一_acnet_x2.png') 48 32
    Assert-Fails { & $entry -Engine anime4kcpp -ExistingOutput error -InputPath $first -Scale 4 } '2x'
    Assert-Fails { & $entry -Engine anime4kcpp -ExistingOutput error -InputPath $inputs -OutputPath $inputs } 'directories must differ'
    Copy-Item -LiteralPath $second -Destination (Join-Path $inputs '线条 一.bmp')
    Assert-Fails { & $entry -Engine anime4kcpp -ExistingOutput error -InputPath $inputs -OutputPath (Join-Path $work 'collision') } 'Duplicate output'
    $bad=Join-Path $work 'corrupt.png'; 'not an image' | Set-Content -LiteralPath $bad
    $badOutput=Join-Path $work 'bad-result.png'
    Assert-Fails { & $entry -Engine anime4kcpp -ExistingOutput error -InputPath $bad -OutputPath $badOutput -AcProcessor cpu } 'produced no image|failed'
    if(Test-Path -LiteralPath $badOutput){throw 'Failed job left a result'}
    # Existing files: stop, replace after success, or preserve and number.
    & $entry -Engine anime4kcpp -InputPath $first -OutputPath $single -ExistingOutput rename -AcProcessor cpu
    & $entry -Engine anime4kcpp -InputPath $first -OutputPath $single -ExistingOutput rename -AcProcessor cpu
    Assert-Image (Join-Path (Split-Path -Parent $single) '单图_1.png') 48 32
    Assert-Image (Join-Path (Split-Path -Parent $single) '单图_2.png') 48 32
    if((Get-FileHash -LiteralPath $single).Hash -ne $before){throw 'Rename changed existing output'}
    'old output' | Set-Content -LiteralPath $single
    $oldHash=(Get-FileHash -LiteralPath $single).Hash
    Assert-Fails { & $entry -Engine anime4kcpp -InputPath $bad -OutputPath $single -ExistingOutput overwrite -AcProcessor cpu } 'produced no image|failed'
    if((Get-FileHash -LiteralPath $single).Hash -ne $oldHash){throw 'Failed inference changed existing output'}
    & $entry -Engine anime4kcpp -InputPath $first -OutputPath $single -ExistingOutput overwrite -AcProcessor cpu
    Assert-Image $single 48 32
    Assert-Fails { & $entry -Engine anime4kcpp -InputPath $first -OutputPath $first -ExistingOutput overwrite } 'must not replace'
    $numbered=Join-Path $work 'numbered batch'
    & $entry -Engine anime4kcpp -InputPath $inputs -OutputPath $numbered -ExistingOutput rename -AcProcessor cpu
    Assert-Image (Join-Path $numbered '线条 一.png') 48 32
    Assert-Image (Join-Path $numbered '线条 一_1.png') 48 32
    $five=Join-Path $work 'five';New-Item -ItemType Directory -Path $five | Out-Null
    foreach($n in 1..5){Copy-Item -LiteralPath $first -Destination (Join-Path $five "$n.png")}
    $fiveOut=Join-Path $work 'five-out'
    $transcript=& $entry -Engine anime4kcpp -InputPath $five -OutputPath $fiveOut -AcBatchSize 2 -AcProcessor cpu -ExistingOutput error *>&1
    $headers=@($transcript | ForEach-Object {"$_"} | Where-Object {$_ -match '^Batch \d+/3: \d+ images$'})
    if(($headers -join '|') -ne 'Batch 1/3: 2 images|Batch 2/3: 2 images|Batch 3/3: 1 images'){throw "Wrong batching: $headers"}
    foreach($n in 1..5){Assert-Image (Join-Path $fiveOut "$n.png") 48 32}
    Assert-Fails { & $entry -Engine anime4kcpp -InputPath $first -AcBatchSize 0 } 'BatchSize'
    Assert-Fails { & $entry -Engine anime4kcpp -InputPath $first -AcBatchSize 257 } 'BatchSize'
    $mixed=Join-Path $work 'mixed';New-Item -ItemType Directory -Path $mixed | Out-Null
    Copy-Item -LiteralPath $first -Destination (Join-Path $mixed 'good.png')
    Copy-Item -LiteralPath $bad -Destination (Join-Path $mixed 'bad.png')
    $mixedOut=Join-Path $work 'mixed-out';New-Item -ItemType Directory -Path $mixedOut | Out-Null
    $oldGood=Join-Path $mixedOut 'good.png';'previous result' | Set-Content -LiteralPath $oldGood
    $previousHash=(Get-FileHash -LiteralPath $oldGood).Hash
    Assert-Fails { & $entry -Engine anime4kcpp -InputPath $mixed -OutputPath $mixedOut -AcBatchSize 2 -AcProcessor cpu -ExistingOutput overwrite } 'produced no image|failed'
    if((Get-FileHash -LiteralPath $oldGood).Hash -ne $previousHash){throw 'Failed batch replaced old output'}
    'PASS: 5 images split into 2+2+1; invalid limits rejected; failed batch preserves previous outputs.'
    'PASS: overwrite, incrementing names, batch stem collisions, input protection and failure preserves previous result.'
    'PASS: Chinese/space paths, 2x dimensions, single/batch/default output, CPU/auto, overwrite protection, invalid scale, same directory, duplicate names and corrupt input.'
} finally {
    $resolved=[IO.Path]::GetFullPath($work)
    $tempRoot=[IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\')+'\'
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'acnet-test-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}