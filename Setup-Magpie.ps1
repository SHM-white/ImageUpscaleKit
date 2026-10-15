# Pinned official preview: first release series with native screenshot hotkeys.
$ErrorActionPreference = 'Stop'
$binDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'bin'))
$destination = Join-Path $binDir 'magpie'
$version = 'v0.13.0-preview02'
$expectedHash = 'D320E0AC744A9FA597D08567B5FC77FA53D31E382D73304DF7C01DDE89675BCA'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$stage = Join-Path $binDir ('magpie-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    # Refuse to replace running binaries; never terminate a user's active session.
    $running = Get-Process Magpie -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq (Join-Path $destination 'Magpie.exe')
    }
    if ($running) { throw 'Close the portable Magpie instance before upgrading.' }
    Write-Host "Installing Magpie $version x64 (preview, screenshot hotkey support)..."
    $zip = Join-Path $stage 'magpie.zip'
    Invoke-WebRequest "https://github.com/Blinue/Magpie/releases/download/$version/Magpie-$version-x64.zip" -OutFile $zip -TimeoutSec 120
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Magpie archive SHA-256 verification failed.' }
    $unpacked = Join-Path $stage 'unpacked'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
    $exe = Get-ChildItem -LiteralPath $unpacked -Recurse -Filter Magpie.exe -File | Select-Object -First 1
    if (-not $exe) { throw 'Magpie.exe was not found in the official archive.' }
    $payload = $exe.Directory.FullName
    $effects = Join-Path $payload 'effects'
    if (@(Get-ChildItem -LiteralPath $effects -Recurse -Filter '*.hlsl' -File).Count -eq 0) { throw 'Magpie archive contains no HLSL effects.' }

    $oldConfig = Join-Path $destination 'config'
    if (Test-Path -LiteralPath $oldConfig) {
        Copy-Item -LiteralPath $oldConfig -Destination $payload -Recurse -Force
    } else {
        New-Item -ItemType Directory -Force -Path (Join-Path $payload 'config') | Out-Null
    }
    # Keep additional custom effects/includes. Updated official files come from the release;
    # local edits to official files remain available in the full backup below.
    $oldEffects = Join-Path $destination 'effects'
    if (Test-Path -LiteralPath $oldEffects) {
        foreach ($file in Get-ChildItem -LiteralPath $oldEffects -Recurse -File) {
            $target = Join-Path $effects ([IO.Path]::GetRelativePath($oldEffects, $file.FullName))
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $target
            }
        }
    }

    $backup = $null
    # Validate all directory move targets before touching the current installation.
    foreach ($path in @($destination, $payload)) {
        if (-not [IO.Path]::GetFullPath($path).StartsWith($binDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Installation path escapes bin directory: $path"
        }
    }
    if (Test-Path -LiteralPath $destination) {
        $backup = Join-Path $binDir ('magpie-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        if (-not [IO.Path]::GetFullPath($backup).StartsWith($binDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid backup path.' }
        Move-Item -LiteralPath $destination -Destination $backup
    }
    try {
        Move-Item -LiteralPath $payload -Destination $destination
    } catch {
        if ($backup -and -not (Test-Path -LiteralPath $destination)) { Move-Item -LiteralPath $backup -Destination $destination }
        throw
    }
    Write-Host "Magpie installed: $destination" -ForegroundColor Green
    if ($backup) { Write-Host "Previous installation backed up: $backup" }
} finally {
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    if ($resolvedStage.StartsWith($binDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedStage) -like 'magpie-install-*') {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
