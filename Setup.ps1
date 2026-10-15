param([ValidateSet('all','anime4kcpp','magpie')] [string]$Engine = 'all')
$ErrorActionPreference='Stop'
if ($Engine -eq 'magpie') { & (Join-Path $PSScriptRoot 'Setup-Magpie.ps1'); return }
& (Join-Path $PSScriptRoot 'Setup-Anime4KCPP.ps1')
if ($Engine -eq 'anime4kcpp') { return }
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg=Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$BinDir=Join-Path $Root 'bin'; $ModelDir=Join-Path $Root 'models'
New-Item -ItemType Directory -Force -Path $BinDir,$ModelDir | Out-Null
$Temp=Join-Path $env:TEMP ('IUK_'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $Temp | Out-Null
try {
    Write-Host '[1/4] Real-ESRGAN NCNN Vulkan...'
    $u1='https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip'
    $z1=Join-Path $Temp 'realesrgan.zip'; Invoke-WebRequest $u1 -OutFile $z1
    $d1=Join-Path $Temp 'realesrgan'; Expand-Archive $z1 $d1 -Force
    $exe=Get-ChildItem $d1 -Recurse -Filter 'realesrgan-ncnn-vulkan.exe' | Select-Object -First 1
    Copy-Item $exe.FullName (Join-Path $BinDir 'realesrgan-ncnn-vulkan.exe') -Force
    Get-ChildItem $d1 -Recurse -File | Where-Object { $_.Extension -in '.param','.bin' } | ForEach-Object { Copy-Item $_.FullName (Join-Path $ModelDir $_.Name) -Force }
    Get-ChildItem $exe.Directory.FullName -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName (Join-Path $BinDir $_.Name) -Force }

    & (Join-Path $PSScriptRoot 'Setup-Magpie.ps1')
    $MagpieDest=Join-Path $BinDir 'magpie'
    Write-Host 'Verify all Magpie HLSL effects...'
    $effects=@(Get-ChildItem (Join-Path $MagpieDest 'effects') -Recurse -Filter '*.hlsl' -File -ErrorAction SilentlyContinue)
    if(-not $effects -or $effects.Count -eq 0){throw 'Magpie HLSL effects were not found in the official archive.'}
    Write-Host ("  Found {0} HLSL effects." -f $effects.Count)

    Write-Host 'Verify binaries...'
    if (-not (Test-Path (Join-Path $BinDir 'realesrgan-ncnn-vulkan.exe'))) { throw 'Real-ESRGAN setup failed.' }
    if (-not (Test-Path (Join-Path $MagpieDest 'Magpie.exe'))) { throw 'Magpie setup failed.' }
    Write-Host ''
    Write-Host 'Setup complete.' -ForegroundColor Green
    Write-Host 'Run Run-GUI.cmd.'
} finally { Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue }
