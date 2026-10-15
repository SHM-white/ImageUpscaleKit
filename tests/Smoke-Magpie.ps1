param([switch]$Integration)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'MagpieHelpers.ps1')
Add-Type -AssemblyName System.Drawing
$work = Join-Path $root ('temp/magpie-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Assert-Fails([scriptblock]$Action, [string]$pattern) {
    $failed = $false
    try { & $Action } catch { if ($_.Exception.Message -notmatch $pattern) { throw }; $failed = $true }
    Assert $failed "Expected failure: $pattern"
}
function Assert-Image([string]$path, [string]$expectedColor) {
    $img = [Drawing.Image]::FromFile($path)
    try {
        # Magpie's final screenshot includes its window-size-dependent final resampling.
        Assert ($img.Width -gt 320 -and $img.Height -gt 240) "Image was not enlarged: $($img.Width)x$($img.Height)"
        Assert ([math]::Abs($img.Width / $img.Height - 4.0 / 3) -lt 0.01) 'Aspect ratio changed'
        $pixel = $img.GetPixel([int]($img.Width / 2), [int]($img.Height / 4))
        if ($expectedColor -eq 'white') { Assert ($pixel.R -gt 240 -and $pixel.G -gt 240 -and $pixel.B -gt 240) 'First source was not captured correctly' }
        if ($expectedColor -eq 'blue') { Assert ($pixel.R -lt 15 -and $pixel.G -lt 15 -and $pixel.B -gt 240) 'Second source was not captured correctly' }
    }
    finally { $img.Dispose() }
}

Assert (Test-IUKMagpieScreenshotHotkey '0.13.0-preview02') 'Preview version was rejected'
Assert (Test-IUKMagpieScreenshotHotkey '0.13.0.0') 'Stable version was rejected'
Assert (-not (Test-IUKMagpieScreenshotHotkey '0.12.1.0')) 'Old backend should require upgrade'
Assert (-not (Test-IUKMagpieScreenshotHotkey 'unknown')) 'Unknown version should require upgrade'
# Old overlay migration must not override the runtime profile screenshot directory.
foreach ($oldSchema in @($true, $false)) {
    $config = [pscustomobject]@{
        shortcuts = [pscustomobject]@{scale=3137; takeScreenshot=0}
        profiles = @([pscustomobject]@{scalingMode=2; screenshotsDir='old'; screenshotFilenameTemplate='custom'},
                     [pscustomobject]@{scalingMode=1; name='user profile'; screenshotsDir='other'})
        scalingModes = @([pscustomobject]@{name='custom'; effects=@([pscustomobject]@{name='Lanczos'; parameters=@{test=0.5}})})
        overlay = [pscustomobject]@{windows=[pscustomobject]@{keep=1}}
    }
    if ($oldSchema) { $config.overlay | Add-Member screenshotsDir 'legacy'; $config.overlay | Add-Member fullscreenInitialToolbarState 1 }
    $modesBefore = $config.scalingModes | ConvertTo-Json -Depth 20 -Compress
    Set-IUKMagpieCaptureConfig $config $work
    Assert ($config.shortcuts.takeScreenshot -eq 3155 -and $config.shortcuts.scale -eq 3137) 'Shortcut configuration failed'
    foreach ($profile in $config.profiles) {
        Assert ($profile.screenshotsDir -eq $work -and $profile.screenshotFilenameTemplate -eq '%WT%') 'Profile screenshot settings missing'
        Assert ($profile.windowedInitialToolbarState -eq 0) 'Toolbar should be hidden'
    }
    Assert (-not $config.overlay.PSObject.Properties['screenshotsDir']) 'Legacy field still overrides profiles'
    Assert ($config.overlay.windows.keep -eq 1 -and $config.profiles[1].name -eq 'user profile') 'User settings were lost'
    Assert (($config.scalingModes | ConvertTo-Json -Depth 20 -Compress) -eq $modesBefore) 'Effect chain was changed'
}

$inputs = Join-Path $work '中文 输入'
New-Item -ItemType Directory -Path $inputs | Out-Null
$first = Join-Path $inputs '线条 一.png'
$second = Join-Path $inputs '线条 二.bmp'
$bitmap = [Drawing.Bitmap]::new(320,240)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.Clear([Drawing.Color]::White)
    $graphics.FillRectangle([Drawing.Brushes]::Red,20,20,100,80)
    $graphics.DrawLine([Drawing.Pens]::Black,0,0,319,239)
    $bitmap.Save($first,[Drawing.Imaging.ImageFormat]::Png)
    $graphics.Clear([Drawing.Color]::Blue)
    $bitmap.Save($second,[Drawing.Imaging.ImageFormat]::Bmp)
} finally { $graphics.Dispose(); $bitmap.Dispose() }

# Ignore screenshots from other source windows and incomplete files.
Copy-Item -LiteralPath $first -Destination (Join-Path $work 'stale.png')
$partial = Join-Path $work 'current.png'
[IO.File]::WriteAllBytes($partial, [byte[]]@(137,80,78,71))
Assert-Fails { Wait-IUKMagpieScreenshot $work 'current' 200 } 'timed out'
Copy-Item -LiteralPath $first -Destination $partial -Force
$locked = [IO.File]::Open($partial, 'Open', 'ReadWrite', 'None')
try { Assert-Fails { Wait-IUKMagpieScreenshot $work 'current' 200 } 'timed out' } finally { $locked.Dispose() }
$shot = Wait-IUKMagpieScreenshot $work 'current' 1000
Assert ($shot.FullName -eq $partial) 'Wrong screenshot selected'
Write-Host 'PASS: old/new profile schema, effect preservation, stale/partial/locked screenshots, timeout and complete PNG.'

if ($Integration) {
    $configPath = Join-Path $root 'bin/magpie/config/config.json'
    $existed = Test-Path -LiteralPath $configPath
    $before = if ($existed) { (Get-FileHash -LiteralPath $configPath).Hash } else { $null }
    function Assert-Restored {
        Assert ((Test-Path -LiteralPath $configPath) -eq $existed) 'Config existence changed'
        if ($existed) { Assert ((Get-FileHash -LiteralPath $configPath).Hash -eq $before) 'Config was not restored byte-for-byte' }
    }
    $entry = Join-Path $root 'Upscale.ps1'
    $single = Join-Path $work '中文 输出/单图.png'
    & pwsh -NoProfile -File $entry -Engine magpie -MagpiePreset 'Lanczos x2' -InputPath $first -OutputPath $single
    Assert ($LASTEXITCODE -eq 0) 'Single image integration failed'
    Assert-Image $single 'white'
    Assert-Restored
    $batch = Join-Path $work '批量 输出'
    & pwsh -NoProfile -File $entry -Engine magpie -MagpiePreset 'Lanczos x2' -InputPath $inputs -OutputPath $batch
    Assert ($LASTEXITCODE -eq 0) 'Batch integration failed'
    Assert-Image (Join-Path $batch '线条 一_upscaled.png') 'white'
    Assert-Image (Join-Path $batch '线条 二_upscaled.png') 'blue'
    Assert ((Get-FileHash -LiteralPath (Join-Path $batch '线条 一_upscaled.png')).Hash -ne (Get-FileHash -LiteralPath (Join-Path $batch '线条 二_upscaled.png')).Hash) 'Batch captured the same image twice'
    Assert-Restored
    # Exercise the official config mode branch in addition to synthetic preset configs.
    $nativeConfig = if ($existed) { Read-IUKMagpieConfig $configPath } else { $null }
    if ($nativeConfig -and @($nativeConfig.scalingModes.name) -contains 'Lanczos') {
        $officialOutput = Join-Path $work 'official-mode.png'
        & pwsh -NoProfile -File $entry -Engine magpie -MagpieSelectionType mode -MagpieMode Lanczos -InputPath $first -OutputPath $officialOutput
        Assert ($LASTEXITCODE -eq 0) 'Official mode integration failed'
        Assert-Image $officialOutput 'white'
        Assert-Restored
    }
    $bad = Join-Path $work 'corrupt.png'
    'not an image' | Set-Content -LiteralPath $bad
    & pwsh -NoProfile -File $entry -Engine magpie -MagpiePreset 'Lanczos x2' -InputPath $bad -OutputPath (Join-Path $work 'bad.png')
    Assert ($LASTEXITCODE -ne 0) 'Corrupt input should fail'
    Assert (-not (Test-Path -LiteralPath (Join-Path $work 'bad.png'))) 'Corrupt input produced output'
    Assert-Restored
    Write-Host 'PASS: native hotkey single/batch, Chinese paths, distinct source content, failure cleanup and exact config restoration.'
}
Write-Host "Test artifacts: $work"
