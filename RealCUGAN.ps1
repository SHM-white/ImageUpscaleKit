param(
    [Parameter(Mandatory = $true)] [string]$InputPath,
    [string]$OutputPath,
    [ValidateSet('models-se', 'models-pro', 'models-nose')] [string]$Model = 'models-se',
    [ValidateSet('2', '3', '4')] [string]$Scale = '2',
    [ValidateSet(-1, 0, 1, 2, 3)] [int]$NoiseLevel = -1,
    [int]$Tile = 0,
    [ValidateRange(0, 3)] [int]$SyncGap = 3,
    [string]$Gpu = 'auto',
    [string]$Threads = '1:2:2',
    [ValidateSet('png', 'jpg', 'webp')] [string]$Format = 'png',
    [switch]$Tta,
    [switch]$VerboseLog
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$rcDir = Join-Path $root 'bin\realcugan'
$exe = Join-Path $rcDir 'realcugan-ncnn-vulkan.exe'

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Real-CUGAN is not installed ($exe). Run: pwsh -File .\Setup-RealCUGAN.ps1"
}

function Test-IUKRealCuganCombination([string]$M, [string]$S, [int]$N) {
    if ($M -eq 'models-nose') {
        if ($S -ne '2' -or $N -ne -1) {
            throw "Real-CUGAN '$M' supports only Scale=2 and NoiseLevel=-1 (no-denoise). Got Scale=$S, NoiseLevel=$N."
        }
        return
    }
    if ($M -eq 'models-pro') {
        if ($S -notin @('2', '3') -or $N -notin @(-1, 0, 3)) {
            throw "Real-CUGAN '$M' supports Scale 2/3 and NoiseLevel -1/0/3. Got Scale=$S, NoiseLevel=$N."
        }
        return
    }
    if ($M -eq 'models-se') {
        if ($S -eq '2') { return }
        if ($S -in @('3', '4') -and $N -in @(-1, 0, 3)) { return }
        throw "Real-CUGAN '$M' at Scale=${S}x supports NoiseLevel -1, 0, or 3 (not $N)."
    }
}

Test-IUKRealCuganCombination -M $Model -S $Scale -N $NoiseLevel

$modelDir = Join-Path $rcDir $Model
if (-not (Test-Path -LiteralPath $modelDir -PathType Container)) {
    throw "Real-CUGAN model pack not found: $modelDir"
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input does not exist: $InputPath"
}

$resolvedInput = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $InputPath).Path)
$inputItem = Get-Item -LiteralPath $resolvedInput
$supportedExts = @('.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tif', '.tiff')
$nativeExts = @('.png', '.jpg', '.jpeg', '.webp')

$files = if ($inputItem.PSIsContainer) {
    @(Get-ChildItem -LiteralPath $inputItem.FullName -File |
        Where-Object { $_.Extension.ToLowerInvariant() -in $supportedExts } |
        Sort-Object Name)
} else {
    if ($inputItem.Extension.ToLowerInvariant() -notin $supportedExts) {
        throw "Unsupported image format for Real-CUGAN: $($inputItem.Extension)"
    }
    @($inputItem)
}
if ($files.Count -eq 0) { throw 'No supported images found for Real-CUGAN.' }

if (-not $OutputPath) {
    $OutputPath = if ($inputItem.PSIsContainer) {
        $inputItem.FullName.TrimEnd('\') + "_realcugan_x$Scale"
    } else {
        Join-Path $inputItem.DirectoryName ("{0}_realcugan_x{1}.{2}" -f $inputItem.BaseName, $Scale, $Format)
    }
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$isDirOutput = $inputItem.PSIsContainer -or (Test-Path -LiteralPath $OutputPath -PathType Container)

if ($isDirOutput) {
    if ([IO.Path]::GetFullPath($inputItem.FullName).TrimEnd('\') -eq $OutputPath.TrimEnd('\')) {
        throw 'Input and output directories must differ.'
    }
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
} else {
    $parent = Split-Path -Parent $OutputPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
}

$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ('realcugan-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.log')

Write-Host "Engine: Real-CUGAN NCNN Vulkan"
Write-Host "Model : $Model | Scale: x$Scale | Noise: $NoiseLevel | SyncGap: $SyncGap"
Write-Host "Log   : $logFile"

Add-Type -AssemblyName System.Drawing

$work = Join-Path $root ('temp\realcugan-job-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    foreach ($file in $files) {
        $dest = if ($isDirOutput) {
            Join-Path $OutputPath ("{0}.{1}" -f $file.BaseName, $Format)
        } else {
            $OutputPath
        }
        if ($dest -eq $file.FullName) {
            throw "Output must not replace input image: $dest"
        }

        $ext = $file.Extension.ToLowerInvariant()
        # Use ASCII relative paths inside temp staging to avoid Windows Unicode path issues in native CLI.
        $stageInName = 'in_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + $(if ($ext -in $nativeExts) { $ext } else { '.png' })
        $stageOutName = 'out_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.' + $Format
        $stageIn = Join-Path $work $stageInName
        $stageOut = Join-Path $work $stageOutName

        if ($ext -in $nativeExts) {
            Copy-Item -LiteralPath $file.FullName -Destination $stageIn -Force
        } else {
            $img = [System.Drawing.Image]::FromFile($file.FullName)
            try { $img.Save($stageIn, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }
        }

        $relDir = '..\..\temp\' + (Split-Path -Leaf $work)
        $relIn = "$relDir\$stageInName"
        $relOut = "$relDir\$stageOutName"
        $cliArgs = @('-i', $relIn, '-o', $relOut, '-m', $Model, '-s', $Scale, '-n', [string]$NoiseLevel, '-t', [string]$Tile, '-c', [string]$SyncGap, '-f', $Format)
        if ($Gpu -and $Gpu -ne 'auto') { $cliArgs += @('-g', $Gpu) }
        if ($Threads) { $cliArgs += @('-j', $Threads) }
        if ($Tta) { $cliArgs += '-x' }
        if ($VerboseLog) { $cliArgs += '-v' }

        "Processing: $($file.FullName) -> $dest" | Add-Content -LiteralPath $logFile -Encoding utf8
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $exe
        $psi.WorkingDirectory = $rcDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($a in $cliArgs) { [void]$psi.ArgumentList.Add($a) }

        $proc = [Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $details = ($outTask.GetAwaiter().GetResult() + "`n" + $errTask.GetAwaiter().GetResult()).Trim()
        if ($details) { $details | Add-Content -LiteralPath $logFile -Encoding utf8 }

        if ($proc.ExitCode -ne 0) {
            throw "Real-CUGAN failed (exit $($proc.ExitCode)) for $($file.Name). Log: $logFile`n$details"
        }
        if (-not (Test-Path -LiteralPath $stageOut -PathType Leaf) -or (Get-Item -LiteralPath $stageOut).Length -eq 0) {
            throw "Real-CUGAN produced no output for $($file.Name). Log: $logFile"
        }

        [IO.File]::Move($stageOut, $dest, $true)
        Remove-Item -LiteralPath $stageIn -Force -ErrorAction SilentlyContinue
        Write-Host "Saved: $dest" -ForegroundColor Green
    }
} finally {
    $resolvedWork = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\') + '\'
    if ($resolvedWork.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedWork) -like 'realcugan-job-*') {
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force -ErrorAction SilentlyContinue
    }
}
