param(
    [Parameter(Mandatory=$true, Position=0)] [string]$InputPath,
    [string]$OutputPath,
    [ValidateSet('ncnn','magpie','anime4kcpp','comfyui','realcugan')] [string]$Engine,
    [string]$Model,
    [string]$Scale,
    [int]$Tile = -1,
    [string]$Gpu,
    [string]$Threads,
    [string]$Format,
    [switch]$Tta,
    [switch]$NoTta,
    [switch]$VerboseLog,
    [ValidateSet('mode','family','effect')] [string]$MagpieSelectionType,
    [string]$MagpieMode,
    [string]$MagpieFamily,
    [string]$MagpieTier,
    [string]$MagpieEffect,
    [ValidateSet('auto','cpu','opencl','cuda')] [string]$AcProcessor,
    [ValidateRange(-1,65535)] [int]$AcDevice = -1,
    [ValidateSet('error','overwrite','rename')] [string]$ExistingOutput,
    [ValidateRange(1,256)] [int]$AcBatchSize,
    [string]$MagpiePreset,
    [string]$ComfyEndpoint,
    [string]$ComfyInstance,
    [string]$ComfyPreset,
    [string]$ComfyWorkflow,
    [string]$ComfyWorkflowMap,
    [hashtable]$ComfyParams,
    [ValidateSet(-1,0,1,2,3)] [int]$NoiseLevel = -1,
    [ValidateRange(0,3)] [int]$SyncGap = 3
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$Cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Engine) { $Engine = [string]$Cfg.engine }

if ($PSBoundParameters.ContainsKey('AcBatchSize') -and $Engine -ne 'anime4kcpp') { throw 'AcBatchSize applies only to Anime4KCPP.' }
if ($ExistingOutput -and $Engine -ne 'anime4kcpp') { throw 'ExistingOutput currently applies only to the Anime4KCPP backend.' }
if ($PSBoundParameters.ContainsKey('NoiseLevel') -and $Engine -ne 'realcugan') { throw 'NoiseLevel applies only to Real-CUGAN.' }
if ($PSBoundParameters.ContainsKey('SyncGap') -and $Engine -ne 'realcugan') { throw 'SyncGap applies only to Real-CUGAN.' }
if ($Engine -eq 'anime4kcpp') {
    if ($Scale -and $Scale -notin @('auto','2')) { throw 'Anime4KCPP currently supports 2x output in this kit.' }
    $acParams = @{ InputPath=$InputPath; Device=$AcDevice }
    if ($OutputPath) { $acParams.OutputPath=$OutputPath }
    if ($Model) { $acParams.Model=$Model }
    if ($AcProcessor) { $acParams.Processor=$AcProcessor }
    if ($ExistingOutput) { $acParams.ExistingOutput=$ExistingOutput }
    if ($PSBoundParameters.ContainsKey('AcBatchSize')) { $acParams.BatchSize=$AcBatchSize }
    & (Join-Path $Root 'Anime4KCPP.ps1') @acParams
    return
}
if ($Engine -eq 'magpie') {
    # PowerShell script calls require a hashtable for named parameter splatting.
    $bridgeParams = @{ InputPath = $InputPath }
    if ($OutputPath) { $bridgeParams.OutputPath = $OutputPath }
    if ($MagpiePreset) { $bridgeParams.Preset = $MagpiePreset }
    else {
        if ($MagpieSelectionType) { $bridgeParams.SelectionType = $MagpieSelectionType }
        if ($MagpieMode) { $bridgeParams.Mode = $MagpieMode }
        if ($MagpieFamily) { $bridgeParams.Family = $MagpieFamily }
        if ($MagpieTier) { $bridgeParams.Tier = $MagpieTier }
        if ($MagpieEffect) { $bridgeParams.Effect = $MagpieEffect }
    }
    & (Join-Path $Root 'MagpieBridge.ps1') @bridgeParams
    exit $LASTEXITCODE
}
if ($Engine -eq 'comfyui') {
    $comfyParamsSplat = @{ InputPath = $InputPath }
    if ($OutputPath) { $comfyParamsSplat.OutputPath = $OutputPath }
    if ($ComfyEndpoint) { $comfyParamsSplat.ApiUrl = $ComfyEndpoint }
    if ($ComfyInstance) { $comfyParamsSplat.InstanceName = $ComfyInstance }
    if ($ComfyPreset) { $comfyParamsSplat.PresetName = $ComfyPreset }
    if ($ComfyWorkflow) { $comfyParamsSplat.WorkflowPath = $ComfyWorkflow }
    if ($ComfyWorkflowMap) { $comfyParamsSplat.WorkflowMapPath = $ComfyWorkflowMap }
    if ($ComfyParams) { $comfyParamsSplat.WorkflowParams = $ComfyParams }
    & (Join-Path $Root 'ComfyUI.ps1') @comfyParamsSplat
    return
}
if ($Engine -eq 'realcugan') {
    $rcParams = @{ InputPath = $InputPath }
    if ($OutputPath) { $rcParams.OutputPath = $OutputPath }
    if ($Model) { $rcParams.Model = $Model }
    if ($Scale -and $Scale -ne 'auto') { $rcParams.Scale = $Scale }
    if ($PSBoundParameters.ContainsKey('NoiseLevel')) { $rcParams.NoiseLevel = $NoiseLevel }
    if ($Tile -ge 0) { $rcParams.Tile = $Tile }
    if ($PSBoundParameters.ContainsKey('SyncGap')) { $rcParams.SyncGap = $SyncGap }
    if ($Gpu) { $rcParams.Gpu = $Gpu }
    if ($Threads) { $rcParams.Threads = $Threads }
    if ($Format) { $rcParams.Format = $Format }
    if ($Tta) { $rcParams.Tta = $true }
    if ($VerboseLog) { $rcParams.VerboseLog = $true }
    & (Join-Path $Root 'RealCUGAN.ps1') @rcParams
    return
}

$n = $Cfg.ncnn
function Resolve-KitPath([string]$p) { if ([IO.Path]::IsPathRooted($p)) { return $p }; return [IO.Path]::GetFullPath((Join-Path $Root $p)) }
function Detect-Scale([string]$Name) { if ($Name -match '(?i)(?:^|[^0-9])([234])x') { return $Matches[1] }; if ($Name -match '(?i)x([234])(?:[^0-9]|$)') { return $Matches[1] }; return '4' }

$Backend = Resolve-KitPath ([string]$n.backend_path)
$ModelDir = Resolve-KitPath ([string]$n.model_dir)
if (-not (Test-Path $Backend)) { throw "NCNN backend not installed: $Backend`nRun Setup.cmd first." }
if (-not (Test-Path $InputPath)) { throw "Input does not exist: $InputPath" }
$InputPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $InputPath).Path)
if (-not $Model) { $Model = [string]$n.model }
if (-not $Scale) { $Scale = [string]$n.scale }
if (-not $Gpu) { $Gpu = [string]$n.gpu }
if (-not $Threads) { $Threads = [string]$n.threads }
if (-not $Format) { $Format = [string]$n.format }
if ($Tile -lt 0) { $Tile = [int]$n.tile }
if ($Scale -eq 'auto' -or [string]::IsNullOrWhiteSpace($Scale)) { $Scale = Detect-Scale $Model }
if ($Tta) { $UseTta=$true } elseif ($NoTta) { $UseTta=$false } else { $UseTta=[bool]$n.tta }
$UseVerbose = $VerboseLog -or [bool]$n.verbose
if (-not (Test-Path (Join-Path $ModelDir ($Model+'.param'))) -or -not (Test-Path (Join-Path $ModelDir ($Model+'.bin')))) { throw "Model pair not found: $Model" }

$InputItem=Get-Item -LiteralPath $InputPath
if (-not $OutputPath) {
    $Suffix=[string]$Cfg.output_suffix
    if ($InputItem.PSIsContainer) { $OutputPath=Join-Path $InputItem.Parent.FullName ($InputItem.Name+$Suffix) }
    else { $OutputPath=Join-Path $InputItem.Directory.FullName ($InputItem.BaseName+$Suffix+'.'+$Format) }
}
$OutputPath=[IO.Path]::GetFullPath($OutputPath)
if ($InputItem.PSIsContainer) { New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null } else { $p=Split-Path -Parent $OutputPath; if ($p) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }
$Args=@('-i',$InputPath,'-o',$OutputPath,'-m',$ModelDir,'-n',$Model,'-s',$Scale,'-t',[string]$Tile)
if ($Gpu -and $Gpu -ne 'auto') { $Args+=@('-g',$Gpu) }
if ($Threads) { $Args+=@('-j',$Threads) }
if ($Format) { $Args+=@('-f',$Format) }
if ($UseTta) { $Args+='-x' }
if ($UseVerbose) { $Args+='-v' }
$LogDir=Join-Path $Root 'logs'; New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile=Join-Path $LogDir ('ncnn-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
Write-Host "Engine: NCNN / Real-ESRGAN"; Write-Host "Model : $Model"; Write-Host "Scale : x$Scale"; Write-Host "Input : $InputPath"; Write-Host "Output: $OutputPath"; Write-Host ''
& $Backend @Args 2>&1 | Tee-Object -FilePath $LogFile
$Code=$LASTEXITCODE
if ($Code -ne 0) { throw "NCNN upscale failed with exit code $Code. Log: $LogFile" }
Write-Host "Done: $OutputPath" -ForegroundColor Green
