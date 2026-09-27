$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$version = 'v3.2.0'
$expectedHash = '82897b0f03ddb88ab3d1affb745baf99506cfe3ceffaeaf73796c6dea4077f19'
$work = Join-Path $root ('temp/acnet-setup-' + [guid]::NewGuid().ToString('N'))
$destination = Join-Path $root 'bin/anime4kcpp'
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $archive = Join-Path $work 'cli.zip'
    $uri = "https://github.com/TianZerL/Anime4KCPP/releases/download/$version/Anime4KCPP-CLI-$version-x64-MSVC.zip"
    Write-Host "Downloading Anime4KCPP $version..."
    Invoke-WebRequest -Uri $uri -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Anime4KCPP archive SHA-256 mismatch.' }
    $expanded = Join-Path $work 'expanded'
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    if (-not (Test-Path -LiteralPath (Join-Path $expanded 'ac_cli.exe'))) { throw 'Official archive is missing ac_cli.exe.' }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -Path (Join-Path $expanded '*') -Destination $destination -Recurse -Force
    & (Join-Path $destination 'ac_cli.exe') --version
    if ($LASTEXITCODE -ne 0) { throw 'Anime4KCPP could not start. Check the Microsoft Visual C++ x64 runtime.' }
    Write-Host "Installed: $destination" -ForegroundColor Green
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'acnet-setup-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}