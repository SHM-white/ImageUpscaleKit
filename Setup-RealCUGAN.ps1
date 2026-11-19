param(
    [string]$LocalArchive = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = $PSScriptRoot
$version = '20220728'
$expectedHash = 'C6E08D46C11704B1E3A1ADA9DDD591CB5005F52F132136C8633BA25DEF400E01'
$work = Join-Path $root ('temp\realcugan-setup-' + [guid]::NewGuid().ToString('N'))
$destination = Join-Path $root 'bin\realcugan'
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $archive = Join-Path $work 'realcugan.zip'
    if ($LocalArchive -and (Test-Path -LiteralPath $LocalArchive -PathType Leaf)) {
        Write-Host "Using local archive: $LocalArchive"
        Copy-Item -LiteralPath $LocalArchive -Destination $archive -Force
    } else {
        $uri = "https://github.com/nihui/realcugan-ncnn-vulkan/releases/download/$version/realcugan-ncnn-vulkan-$version-windows.zip"
        Write-Host "Downloading Real-CUGAN NCNN Vulkan $version..."
        Invoke-WebRequest -Uri $uri -OutFile $archive -TimeoutSec 300
    }

    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($actualHash -ine $expectedHash) {
        throw "Real-CUGAN archive SHA-256 mismatch. Expected: $expectedHash, Actual: $actualHash"
    }

    $expanded = Join-Path $work 'expanded'
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
    $exe = Get-ChildItem -LiteralPath $expanded -Recurse -Filter 'realcugan-ncnn-vulkan.exe' -File | Select-Object -First 1
    if (-not $exe) {
        throw 'Official archive is missing realcugan-ncnn-vulkan.exe.'
    }

    $payloadDir = $exe.Directory.FullName
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -Path (Join-Path $payloadDir '*') -Destination $destination -Recurse -Force

    $installedExe = Join-Path $destination 'realcugan-ncnn-vulkan.exe'
    $helpOut = & $installedExe -h 2>&1 | Out-String
    if (-not ($helpOut -match 'realcugan-ncnn-vulkan')) {
        throw 'Real-CUGAN executable did not respond with expected usage text.'
    }

    Write-Host "Installed Real-CUGAN: $destination (SHA-256 verified)" -ForegroundColor Green
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'realcugan-setup-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
