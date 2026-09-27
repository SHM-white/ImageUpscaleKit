param(
    [Parameter(Mandatory=$true)] [string]$InputPath,
    [string]$OutputPath,
    [string]$Model,
    [ValidateSet('auto','cpu','opencl','cuda')] [string]$Processor,
    [ValidateRange(-1,65535)] [int]$Device = -1,
    [ValidateSet('error','overwrite','rename')] [string]$ExistingOutput,
    [ValidateRange(1,256)] [int]$BatchSize
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$settings = $cfg.anime4kcpp
$backend = if ($settings.backend_path) { [string]$settings.backend_path } else { 'bin/anime4kcpp/ac_cli.exe' }
if (-not [IO.Path]::IsPathRooted($backend)) { $backend = Join-Path $PSScriptRoot $backend }
if (-not (Test-Path -LiteralPath $backend -PathType Leaf)) { throw 'Anime4KCPP is not installed. Run: pwsh -File .\Setup-Anime4KCPP.ps1' }
if (-not $Model) { $Model = if ($settings.model) { [string]$settings.model } else { 'acnet-legacy-gan' } }
if (-not $Processor) { $Processor = if ($settings.processor) { [string]$settings.processor } else { 'auto' } }
if ($Processor -notin @('auto','cpu','opencl','cuda')) { throw "Unsupported processor: $Processor" }
if ($Device -lt 0) { $Device = if ($null -ne $settings.device) { [int]$settings.device } else { 0 } }
if ($Device -lt 0) { throw 'Device must be nonnegative.' }
if (-not $ExistingOutput) { $ExistingOutput = if ($settings.existing_output) { [string]$settings.existing_output } else { 'error' } }
if ($ExistingOutput -notin @('error','overwrite','rename')) { throw "Unsupported existing-output policy: $ExistingOutput" }
if (-not $PSBoundParameters.ContainsKey('BatchSize')) { $BatchSize = if ($null -ne $settings.batch_size) { [int]$settings.batch_size } else { 16 } }
if ($BatchSize -lt 1 -or $BatchSize -gt 256) { throw 'BatchSize must be between 1 and 256.' }
$item = Get-Item -LiteralPath $InputPath
$extensions = @('.png','.jpg','.jpeg','.bmp','.webp','.tif','.tiff')
$files = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $item.FullName -File | Where-Object { $_.Extension.ToLowerInvariant() -in $extensions } | Sort-Object Name) } else { @($item) }
if ($files.Count -eq 0) { throw 'No supported images found.' }
if (-not $item.PSIsContainer -and $item.Extension.ToLowerInvariant() -notin $extensions) { throw 'Unsupported image format. Use PNG, JPEG, BMP, WebP or TIFF (single frame).' }
if (-not $OutputPath) {
    $OutputPath = if ($item.PSIsContainer) { $item.FullName.TrimEnd('\') + '_acnet_x2' } else { Join-Path $item.DirectoryName ($item.BaseName + '_acnet_x2.png') }
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$isDirectory = $item.PSIsContainer -or (Test-Path -LiteralPath $OutputPath -PathType Container)
if ($isDirectory) {
    if ([IO.Path]::GetFullPath($item.FullName).TrimEnd('\') -eq $OutputPath.TrimEnd('\')) { throw 'Input and output directories must differ.' }
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
} elseif ([IO.Path]::GetExtension($OutputPath) -ine '.png') { throw 'Anime4KCPP output must be a PNG file or an existing directory.' }
# Preflight the whole batch before processing, including name collisions and overwrites.
$destinations = @{}
$jobs = foreach ($file in $files) {
    $dest = if ($isDirectory) { Join-Path $OutputPath ($file.BaseName + '.png') } else { $OutputPath }
    if ($dest -eq $file.FullName) { throw 'Output must not replace the input image.' }
    if ($ExistingOutput -eq 'rename') {
        $basePath = Join-Path (Split-Path -Parent $dest) ([IO.Path]::GetFileNameWithoutExtension($dest))
        $number = 1
        while ($destinations.ContainsKey($dest) -or (Test-Path -LiteralPath $dest)) {
            $dest = "${basePath}_$number.png"
            $number++
        }
    } else {
        if ($destinations.ContainsKey($dest)) { throw "Duplicate output name: $dest. Use rename mode to keep both images." }
        if (Test-Path -LiteralPath $dest -PathType Container) { throw "Output is a directory: $dest" }
        if ($ExistingOutput -eq 'error' -and (Test-Path -LiteralPath $dest)) { throw "Output already exists: $dest. Choose overwrite or rename mode." }
    }
    $destinations[$dest] = $true
    [pscustomobject]@{ Source=$file.FullName; Destination=$dest }
}
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ('acnet-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.log')
Write-Host "Engine: Anime4KCPP / ACNet`nModel: $Model`nScale: 2x`nProcessor: $Processor / Device: $Device`nLog: $log"
$jobs = @($jobs)
$batchCount = [int][Math]::Ceiling($jobs.Count / [double]$BatchSize)
Write-Host "Batch size: $BatchSize / Batches: $batchCount (one image worker per process)"
for ($offset = 0; $offset -lt $jobs.Count; $offset += $BatchSize) {
    $batchNumber = [int]($offset / $BatchSize) + 1
    $last = [Math]::Min($offset + $BatchSize, $jobs.Count) - 1
    $batch = @($jobs[$offset..$last])
    $work = Join-Path $PSScriptRoot ('temp/acnet-job-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $process = $null
    try {
        # ASCII relative paths work around the native image loader's Unicode limitation.
        $inputs = @()
        $outputs = @()
        for ($i = 0; $i -lt $batch.Count; $i++) {
            $inputs += ('in{0:D3}' -f $i) + [IO.Path]::GetExtension($batch[$i].Source).ToLowerInvariant()
            $outputs += 'out{0:D3}.png' -f $i
            Copy-Item -LiteralPath $batch[$i].Source -Destination (Join-Path $work $inputs[$i])
        }
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $backend
        $psi.WorkingDirectory = $work
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # One image-processing worker avoids initializing a model for many parallel workers.
        $arguments = @('-i') + $inputs + @('-o') + $outputs + @('-m',$Model,'-p',$Processor,'-d',[string]$Device,'-f','2','-t','1')
        foreach ($arg in $arguments) { [void]$psi.ArgumentList.Add($arg) }
        $header = "Batch $batchNumber/${batchCount}: $($batch.Count) images"
        Write-Host $header
        $header | Add-Content -LiteralPath $log -Encoding utf8
        for ($i = 0; $i -lt $batch.Count; $i++) {
            "$($inputs[$i]) = $($batch[$i].Source) -> $($batch[$i].Destination)" | Add-Content -LiteralPath $log -Encoding utf8
        }
        $process = [Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $details = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $details | Add-Content -LiteralPath $log -Encoding utf8
        if ($details) { Write-Host $details.Trim() }
        if ($process.ExitCode -ne 0) { throw "Anime4KCPP failed (exit $($process.ExitCode)). Log: $log" }
        # Validate every output before replacing any previous result in this batch.
        for ($i = 0; $i -lt $batch.Count; $i++) {
            $temporaryOutput = Join-Path $work $outputs[$i]
            if (-not (Test-Path -LiteralPath $temporaryOutput) -or (Get-Item -LiteralPath $temporaryOutput).Length -eq 0) {
                throw "Anime4KCPP produced no image for $($batch[$i].Source). Batch $batchNumber was not saved. Log: $log"
            }
        }
        for ($i = 0; $i -lt $batch.Count; $i++) {
            $parent = Split-Path -Parent $batch[$i].Destination
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
            [IO.File]::Move((Join-Path $work $outputs[$i]), $batch[$i].Destination, ($ExistingOutput -eq 'overwrite'))
            Write-Host "Saved: $($batch[$i].Destination)" -ForegroundColor Green
        }
    } finally {
        if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
        $resolved = [IO.Path]::GetFullPath($work)
        $tempRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'temp')).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'acnet-job-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}