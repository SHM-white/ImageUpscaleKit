param(
    [Parameter(Mandatory=$true)] [string]$InputPath,
    [string]$OutputPath,
    [ValidateSet('mode','family','effect')] [string]$SelectionType,
    [string]$Mode,
    [string]$Family,
    [string]$Tier,
    [string]$Effect,
    [string]$Preset
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
. (Join-Path $Root 'MagpieHelpers.ps1')

function Resolve-KitPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    if ([System.IO.Path]::IsPathRooted($p)) { return [System.IO.Path]::GetFullPath($p) }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $p))
}
function Set-ObjProp($obj,[string]$Name,$Value) {
    if ($null -eq $obj) { return }
    if ($obj.PSObject.Properties[$Name]) { $obj.$Name = $Value }
    else { $obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}
function New-DefaultProfile {
    [pscustomobject]@{
        scalingMode = 0
        captureMethod = 0
        multiMonitorUsage = 0
        initialWindowedScaleFactor = 6
        customInitialWindowedScaleFactor = 1.0
        graphicsCardId = [pscustomobject]@{ idx=-1; vendorId=0; deviceId=0 }
        frameRateLimiterEnabled = $false
        maxFrameRate = 60.0
        '3DGameMode' = $false
        captureTitleBar = $false
        adjustCursorSpeed = $false
        disableDirectFlip = $false
        cursorScaling = 2
        customCursorScaling = 1.0
        autoHideCursorEnabled = $true
        autoHideCursorDelay = 0.1
        croppingEnabled = $false
        cropping = [pscustomobject]@{ left=0; top=0; right=0; bottom=0 }
        outputAlignment = 4
    }
}
function New-SyntheticMagpieConfig($Effects,$ShotDir) {
    $effectItems = @()
    foreach ($e in @($Effects)) {
        $item = [ordered]@{ name = [string]$e.name }
        if ($null -ne $e.scalingType) { $item.scalingType = [int]$e.scalingType }
        if ($null -ne $e.scale) { $item.scale = [ordered]@{ x=[double]$e.scale.x; y=[double]$e.scale.y } }
        if ($null -ne $e.parameters) {
            $params = [ordered]@{}
            foreach ($p in $e.parameters.PSObject.Properties) { $params[$p.Name] = [double]$p.Value }
            $item.parameters = $params
        }
        $effectItems += [pscustomobject]$item
    }

    return [pscustomobject]@{
        language = ''
        shortcuts = [pscustomobject]@{ scale=3137; windowedModeScale=3153; toolbar=3140 }
        allowScalingMaximized = $true
        showNotifyIcon = $false
        scalingModes = @([pscustomobject]@{ name='ImageUpscaleKit'; effects=$effectItems })
        profiles = @((New-DefaultProfile))
        overlay = [pscustomobject]@{
            fullscreenInitialToolbarState = 1
            windowedInitialToolbarState = 1
            screenshotsDir = $ShotDir
            windows = [pscustomobject]@{}
        }
    }
}
function Build-MagpieConfigForModeFromOfficial([string]$SourceConfigFile,[string]$ModeName,[string]$ShotDir) {
    $cfgObj = Read-IUKMagpieConfig $SourceConfigFile
    $modes = @($cfgObj.scalingModes)
    if ($modes.Count -eq 0) { throw "No scalingModes found in Magpie config: $SourceConfigFile" }
    $modeIndex = -1
    for($i=0;$i -lt $modes.Count;$i++){ if([string]$modes[$i].name -eq $ModeName){ $modeIndex=$i; break } }
    if ($modeIndex -lt 0) { throw "Mode '$ModeName' not found in Magpie config: $SourceConfigFile" }

    if (-not $cfgObj.profiles -or @($cfgObj.profiles).Count -eq 0) {
        Set-ObjProp $cfgObj 'profiles' @((New-DefaultProfile))
    }
    $profile0 = @($cfgObj.profiles)[0]
    if ($null -eq $profile0) {
        Set-ObjProp $cfgObj 'profiles' @((New-DefaultProfile))
        $profile0 = @($cfgObj.profiles)[0]
    }
    Set-ObjProp $profile0 'scalingMode' $modeIndex

    if (-not $cfgObj.shortcuts) { Set-ObjProp $cfgObj 'shortcuts' ([pscustomobject]@{}) }
    Set-ObjProp $cfgObj.shortcuts 'scale' 3137
    Set-ObjProp $cfgObj.shortcuts 'windowedModeScale' 3153
    Set-ObjProp $cfgObj.shortcuts 'toolbar' 3140

    if (-not $cfgObj.overlay) { Set-ObjProp $cfgObj 'overlay' ([pscustomobject]@{}) }
    Set-ObjProp $cfgObj.overlay 'fullscreenInitialToolbarState' 1
    Set-ObjProp $cfgObj.overlay 'windowedInitialToolbarState' 1
    Set-ObjProp $cfgObj.overlay 'screenshotsDir' $ShotDir
    if (-not $cfgObj.overlay.windows) { Set-ObjProp $cfgObj.overlay 'windows' ([pscustomobject]@{}) }

    Set-ObjProp $cfgObj 'showNotifyIcon' $false
    Set-ObjProp $cfgObj 'allowScalingMaximized' $true
    return $cfgObj
}

$mag = $Cfg.magpie
$MagpieExe = Resolve-KitPath ([string]$mag.exe_path)
$EffectsDir = Resolve-KitPath ([string]$mag.effects_dir)
$ModeFile = Resolve-KitPath ([string]$mag.mode_file)
$OfficialConfigFile = if($mag.config_file){ Resolve-KitPath ([string]$mag.config_file) } else { Join-Path (Split-Path -Parent $MagpieExe) 'config\config.json' }
$ShotDir = Join-Path $Root 'temp\magpie_screenshots'
$HostScript = Join-Path $Root 'ImageHost.ps1'
if (-not (Test-Path -LiteralPath $MagpieExe)) { throw "Magpie backend is not installed. Run Setup.cmd first.`nExpected: $MagpieExe" }
if (-not (Test-Path -LiteralPath $InputPath)) { throw "Input does not exist: $InputPath" }

$SelectedEffects = $null
$SelectionLabel = ''
$ConfigBuildMode = 'synthetic'
$ModeSource = 'none'

# Backward compatibility with v2 preset JSON files.
if ($Preset) {
    $PresetDir = Join-Path $Root 'magpie_presets'
    $PresetPath = Join-Path $PresetDir ($Preset + '.json')
    if (-not (Test-Path -LiteralPath $PresetPath)) { throw "Magpie preset not found: $PresetPath" }
    $PresetCfg = Get-Content -LiteralPath $PresetPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $SelectedEffects = @($PresetCfg.effects)
    $SelectionLabel = "Preset: $Preset"
} else {
    if (-not $SelectionType) { $SelectionType=[string]$mag.selection_type }
    if ($SelectionType -eq 'effect') {
        if (-not $Effect) { $Effect=[string]$mag.raw_effect }
        if (-not $Effect) { throw 'No Magpie HLSL effect selected.' }
        $SelectedEffects = @([pscustomobject]@{name=$Effect})
        $SelectionLabel = "Effect: $Effect"
    } elseif ($SelectionType -eq 'family') {
        if (-not $Family) { $Family=[string]$mag.family }
        if (-not $Tier) { $Tier=[string]$mag.tier }
        $SelectedEffects = @(Resolve-IUKFamilyEffect $Family $Tier $EffectsDir)
        $SelectionLabel = "Family: $Family / $Tier"
    } else {
        if (-not $Mode) { $Mode=[string]$mag.mode }
        if (-not $Tier) { $Tier=[string]$mag.tier }
        $ModeSource = Get-IUKPreferredModeSource $OfficialConfigFile $ModeFile $Mode
        if ($ModeSource -eq 'config') {
            $ConfigBuildMode = 'official'
            $SelectionLabel = "Mode: $Mode (from Magpie config.json)"
        } else {
            $SelectedEffects = @(Resolve-IUKModeEffects $ModeFile $Mode $Tier $EffectsDir)
            $SelectionLabel = "Mode: $Mode / $Tier (from magpie_modes.json)"
        }
    }
}
if ($SelectedEffects) {
    if (-not $SelectedEffects -or @($SelectedEffects).Count -eq 0) { throw 'Selected Magpie mode/effect chain is empty.' }
    Test-IUKEffectsExist $SelectedEffects $EffectsDir
}
Write-Host "Engine: MagpieFX"
Write-Host $SelectionLabel
if ($SelectedEffects) {
    Write-Host "Effects:"
    @($SelectedEffects) | ForEach-Object { Write-Host "  $($_.name)" }
}

# Win32 helpers: find/activate Magpie windows, synthesize hotkeys, click the toolbar screenshot button.
$nativeCode = @'
using System;
using System.Runtime.InteropServices;
public static class IUKWin32 {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public const uint KEYUP = 0x0002;
    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP = 0x0004;
    public struct RECT { public int Left, Top, Right, Bottom; }
    public static void Hotkey(byte key) {
        keybd_event(0x12,0,0,UIntPtr.Zero); // ALT
        keybd_event(0x10,0,0,UIntPtr.Zero); // SHIFT
        keybd_event(key,0,0,UIntPtr.Zero);
        keybd_event(key,0,KEYUP,UIntPtr.Zero);
        keybd_event(0x10,0,KEYUP,UIntPtr.Zero);
        keybd_event(0x12,0,KEYUP,UIntPtr.Zero);
    }
    public static void Click(int x, int y) {
        SetCursorPos(x,y);
        mouse_event(LEFTDOWN,0,0,0,UIntPtr.Zero);
        mouse_event(LEFTUP,0,0,0,UIntPtr.Zero);
    }
}
'@
if (-not ('IUKWin32' -as [type])) { Add-Type -TypeDefinition $nativeCode }

function Start-PwshChild([object[]]$ArgumentList) {
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName='pwsh.exe'
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    foreach($a in $ArgumentList){[void]$psi.ArgumentList.Add([string]$a)}
    return [Diagnostics.Process]::Start($psi)
}

function Wait-Window([string]$ClassName, [string]$Title, [int]$TimeoutMs, [Diagnostics.Process]$Process = $null) {
    # String parameters coerce $null to ''; Win32 needs null to omit a filter.
    $windowClass = if ([string]::IsNullOrEmpty($ClassName)) { [System.Management.Automation.Language.NullString]::Value } else { $ClassName }
    $windowTitle = if ([string]::IsNullOrEmpty($Title)) { [System.Management.Automation.Language.NullString]::Value } else { $Title }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $h = [IUKWin32]::FindWindow($windowClass, $windowTitle)
        if ($h -ne [IntPtr]::Zero) { return $h }
        if ($Process -and $Process.HasExited) { return [IntPtr]::Zero }
        Start-Sleep -Milliseconds 100
    } while ($sw.ElapsedMilliseconds -lt $TimeoutMs)
    return [IntPtr]::Zero
}

function Stop-PortableMagpie {
    $target = [System.IO.Path]::GetFullPath($MagpieExe)
    Get-CimInstance Win32_Process -Filter "Name='Magpie.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.ExecutablePath -and [System.IO.Path]::GetFullPath($_.ExecutablePath) -eq $target) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

# Magpie is single-instance. Refuse to hijack another installed Magpie process.
$foreign = Get-CimInstance Win32_Process -Filter "Name='Magpie.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.ExecutablePath -and ([System.IO.Path]::GetFullPath($_.ExecutablePath) -ne [System.IO.Path]::GetFullPath($MagpieExe))
}
if ($foreign) { throw 'Another Magpie instance is running. Close Magpie first, then retry.' }
Stop-PortableMagpie

New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
Get-ChildItem -LiteralPath $ShotDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$MagpieDir = Split-Path -Parent $MagpieExe
$MagpieConfigDir = Join-Path $MagpieDir 'config'
$TargetMagpieConfigPath = Join-Path $MagpieConfigDir 'config.json'
New-Item -ItemType Directory -Force -Path $MagpieConfigDir | Out-Null
$OriginalConfigExisted = Test-Path -LiteralPath $TargetMagpieConfigPath
$OriginalConfigRaw = if ($OriginalConfigExisted) { Get-Content -LiteralPath $TargetMagpieConfigPath -Raw -Encoding UTF8 } else { $null }

if ($ConfigBuildMode -eq 'official') {
    $magpieConfig = Build-MagpieConfigForModeFromOfficial $OfficialConfigFile $Mode $ShotDir
} else {
    $magpieConfig = New-SyntheticMagpieConfig $SelectedEffects $ShotDir
}
$magpieConfig | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $TargetMagpieConfigPath -Encoding utf8NoBOM

$InputResolved = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $InputPath).Path)
$InputItem = Get-Item -LiteralPath $InputResolved
$suffix = [string]$Cfg.output_suffix

function Get-OutputForFile([System.IO.FileInfo]$file, [string]$baseOutput) {
    if ($baseOutput) {
        if ((Test-Path -LiteralPath $baseOutput -PathType Container) -or $InputItem.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $baseOutput | Out-Null
            return Join-Path $baseOutput ($file.BaseName + $suffix + '.png')
        }
        return [System.IO.Path]::GetFullPath($baseOutput)
    }
    return Join-Path $file.Directory.FullName ($file.BaseName + $suffix + '.png')
}

$files = if ($InputItem.PSIsContainer) {
    @(Get-ChildItem -LiteralPath $InputResolved -File | Where-Object { $_.Extension.ToLowerInvariant() -in @('.png','.jpg','.jpeg','.bmp','.gif','.tif','.tiff') })
} else { @($InputItem) }
if ($files.Count -eq 0) { throw 'No supported images found.' }
if ($InputItem.PSIsContainer -and -not $OutputPath) { $OutputPath = Join-Path $InputItem.Parent.FullName ($InputItem.Name + $suffix) }
if ($InputItem.PSIsContainer) { New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null }

$magpieProc = Start-Process -FilePath $MagpieExe -WorkingDirectory $MagpieDir -ArgumentList '-t' -PassThru
Start-Sleep -Milliseconds ([int]$mag.startup_wait_ms)

try {
    $index = 0
    foreach ($file in $files) {
        $index++
        Write-Host "[$index/$($files.Count)] MagpieFX: $($file.Name)"
        Get-ChildItem -LiteralPath $ShotDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

        $title = 'IUK_ImageHost_' + [guid]::NewGuid().ToString('N')
        $imageHostProcess = Start-PwshChild @('-NoProfile','-STA','-File',$HostScript,'-ImagePath',$file.FullName,'-WindowTitle',$title)
        $hostOutputTask = $imageHostProcess.StandardOutput.ReadToEndAsync()
        $hostErrorTask = $imageHostProcess.StandardError.ReadToEndAsync()
        try {
            $src = Wait-Window $null $title 15000 $imageHostProcess
            if ($src -eq [IntPtr]::Zero) {
                if ($imageHostProcess.HasExited) {
                    $hostDetails = ($hostErrorTask.GetAwaiter().GetResult() + "`n" + $hostOutputTask.GetAwaiter().GetResult()).Trim()
                    throw "Image host exited with code $($imageHostProcess.ExitCode) for $($file.Name).`n$hostDetails"
                }
                throw "Image host window did not appear within 15 seconds for $($file.Name) (PID $($imageHostProcess.Id))."
            }
            [IUKWin32]::SetForegroundWindow($src) | Out-Null
            Start-Sleep -Milliseconds 250

            # Alt+Shift+Q: windowed scaling.
            [IUKWin32]::Hotkey([byte][char]'Q')
            $scaleWnd = Wait-Window 'Window_Magpie_967EB565-6F73-4E94-AE53-00CC42592A22' $null 7000
            if ($scaleWnd -eq [IntPtr]::Zero) { throw 'Magpie scaling window did not appear.' }
            Start-Sleep -Milliseconds ([int]$mag.scale_wait_ms)

            # v0.12.1 has no screenshot hotkey; click the native toolbar camera button.
            $rect = [IUKWin32+RECT]::new()
            if (-not [IUKWin32]::GetWindowRect($scaleWnd, [ref]$rect)) { throw 'Failed to query Magpie scaling window geometry.' }
            $dpi = [IUKWin32]::GetDpiForWindow($scaleWnd)
            if ($dpi -le 0) { $dpi = 96 }
            $factor = $dpi / 96.0
            $cx = [int](($rect.Left + $rect.Right) / 2 + ([double]$mag.toolbar_x_offset_dip * $factor))
            $cy = [int]($rect.Top + ([double]$mag.toolbar_y_dip * $factor))
            [IUKWin32]::SetForegroundWindow($scaleWnd) | Out-Null
            [IUKWin32]::SetCursorPos($cx, $cy) | Out-Null
            Start-Sleep -Milliseconds 500
            [IUKWin32]::Click($cx, $cy)

            $sw = [Diagnostics.Stopwatch]::StartNew()
            $shot = $null
            do {
                $shot = Get-ChildItem -LiteralPath $ShotDir -Filter '*.png' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                if ($shot) { break }
                Start-Sleep -Milliseconds 100
            } while ($sw.ElapsedMilliseconds -lt [int]$mag.screenshot_wait_ms)
            if (-not $shot) { throw 'Magpie did not create a screenshot. If the toolbar layout changed, adjust toolbar_x_offset_dip / toolbar_y_dip in config.json.' }

            $dest = Get-OutputForFile $file $OutputPath
            $parent = Split-Path -Parent $dest
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            Move-Item -LiteralPath $shot.FullName -Destination $dest -Force
            Write-Host "  -> $dest" -ForegroundColor Green

            # Toggle windowed scaling off before moving to the next source image.
            [IUKWin32]::Hotkey([byte][char]'Q')
            Start-Sleep -Milliseconds 350
        }
        finally {
            if ($imageHostProcess -and -not $imageHostProcess.HasExited) { Stop-Process -Id $imageHostProcess.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}
finally {
    if ($magpieProc -and -not $magpieProc.HasExited) { Stop-Process -Id $magpieProc.Id -Force -ErrorAction SilentlyContinue }
    if ($OriginalConfigExisted) {
        Set-Content -LiteralPath $TargetMagpieConfigPath -Value $OriginalConfigRaw -Encoding utf8NoBOM
    } else {
        Remove-Item -LiteralPath $TargetMagpieConfigPath -Force -ErrorAction SilentlyContinue
    }
    Stop-PortableMagpie
}
