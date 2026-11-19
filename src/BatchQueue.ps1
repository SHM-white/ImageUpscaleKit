function Initialize-IUKAsyncRunnerTypes {
    if ('ImageUpscaleKit.Execution.IukAsyncProcessRunner' -as [type]) {
        return
    }
    $refMap = @{}
    $psRefDir = Join-Path $PSHOME 'ref'
    if (Test-Path -LiteralPath $psRefDir -PathType Container) {
        foreach ($f in Get-ChildItem -LiteralPath $psRefDir -Filter '*.dll' -File) {
            $refMap[$f.Name] = $f.FullName
        }
    }
    foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
        if ($asm.IsDynamic -or [string]::IsNullOrEmpty($asm.Location)) { continue }
        $name = [IO.Path]::GetFileName($asm.Location)
        if (-not $refMap.ContainsKey($name)) {
            $refMap[$name] = $asm.Location
        }
    }
    $csPath = Join-Path $PSScriptRoot 'AsyncProcessRunner.cs'
    if (-not (Test-Path -LiteralPath $csPath -PathType Leaf)) {
        throw "AsyncProcessRunner.cs not found: $csPath"
    }
    $source = Get-Content -LiteralPath $csPath -Raw -Encoding UTF8
    Add-Type -ReferencedAssemblies @($refMap.Values) -TypeDefinition $source -Language CSharp
}

$Script:IUKSupportedImageExtensions = @('.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp', '.tif', '.tiff')

function Expand-IUKDroppedPaths {
    param(
        [string[]]$Paths
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($raw in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if (-not (Test-Path -LiteralPath $raw)) { continue }
        $full = [IO.Path]::GetFullPath($raw)
        $item = Get-Item -LiteralPath $full
        if ($item.PSIsContainer) {
            $children = Get-ChildItem -LiteralPath $item.FullName -File |
                Where-Object { $_.Extension.ToLowerInvariant() -in $Script:IUKSupportedImageExtensions } |
                Sort-Object Name
            foreach ($c in $children) {
                if ($seen.Add($c.FullName)) {
                    [void]$result.Add($c.FullName)
                }
            }
        } elseif ($item.Extension.ToLowerInvariant() -in $Script:IUKSupportedImageExtensions) {
            if ($seen.Add($item.FullName)) {
                [void]$result.Add($item.FullName)
            }
        }
    }
    return @($result)
}

function New-IUKQueueItem {
    param(
        [Parameter(Mandatory = $true)] [string]$InputPath,
        [string]$Engine = 'anime4kcpp',
        [string]$PresetLabel = ''
    )
    $full = [IO.Path]::GetFullPath($InputPath)
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('N')
        InputPath = $full
        FileName = [IO.Path]::GetFileName($full)
        Status = '待处理'
        Engine = $Engine
        PresetLabel = $PresetLabel
        OutputPath = ''
        ElapsedMs = 0.0
        ErrorMessage = ''
        Results = [System.Collections.Generic.List[object]]::new()
    }
}

function Resolve-IUKItemOutputPath {
    param(
        [Parameter(Mandatory = $true)] [string]$InputPath,
        [string]$OutputDir,
        [string]$Engine = 'anime4kcpp',
        [string]$Suffix = '_upscaled',
        [string]$Format = 'png',
        [string]$ExistingPolicy = 'rename',
        [hashtable]$UsedPaths = $null
    )
    $fullInput = [IO.Path]::GetFullPath($InputPath)
    $inputDir = Split-Path -Parent $fullInput
    $baseName = [IO.Path]::GetFileNameWithoutExtension($fullInput)

    $targetDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) { $inputDir } else { [IO.Path]::GetFullPath($OutputDir) }
    $effSuffix = switch ($Engine) {
        'anime4kcpp' { '_acnet_x2' }
        'realcugan' { '_realcugan' }
        'comfyui' { '_comfyui' }
        default { if ($Suffix) { $Suffix } else { '_upscaled' } }
    }
    $ext = if ($Engine -in @('anime4kcpp', 'magpie', 'comfyui')) { 'png' } elseif ($Format) { $Format.TrimStart('.').ToLowerInvariant() } else { 'png' }

    $candidate = Join-Path $targetDir ($baseName + $effSuffix + '.' + $ext)
    if ($candidate -eq $fullInput) {
        $candidate = Join-Path $targetDir ($baseName + '_out.' + $ext)
    }

    if ($ExistingPolicy -eq 'rename') {
        $n = 1
        while ((Test-Path -LiteralPath $candidate) -or ($UsedPaths -and $UsedPaths.ContainsKey($candidate))) {
            $candidate = Join-Path $targetDir ('{0}{1}_{2}.{3}' -f $baseName, $effSuffix, $n, $ext)
            $n++
        }
    }
    if ($UsedPaths) {
        $UsedPaths[$candidate] = $true
    }
    return $candidate
}

function Build-IUKUpscaleArguments {
    param(
        [Parameter(Mandatory = $true)] [string]$UpscaleScriptPath,
        [Parameter(Mandatory = $true)] $Item,
        [Parameter(Mandatory = $true)] [hashtable]$Options
    )
    $engine = [string]$Options.Engine
    $args = [System.Collections.Generic.List[string]]::new()
    [void]$args.Add('-NoProfile')
    [void]$args.Add('-File')
    [void]$args.Add($UpscaleScriptPath)
    [void]$args.Add('-InputPath')
    [void]$args.Add([string]$Item.InputPath)
    [void]$args.Add('-Engine')
    [void]$args.Add($engine)

    if ($Item.OutputPath) {
        [void]$args.Add('-OutputPath')
        [void]$args.Add([string]$Item.OutputPath)
    }

    if ($engine -eq 'anime4kcpp') {
        if ($Options.AcModel) { [void]$args.Add('-Model'); [void]$args.Add([string]$Options.AcModel) }
        [void]$args.Add('-Scale'); [void]$args.Add('2')
        if ($Options.AcProcessor) { [void]$args.Add('-AcProcessor'); [void]$args.Add([string]$Options.AcProcessor) }
        if ($null -ne $Options.AcDevice) { [void]$args.Add('-AcDevice'); [void]$args.Add([string]$Options.AcDevice) }
        if ($Options.AcBatchSize) { [void]$args.Add('-AcBatchSize'); [void]$args.Add([string]$Options.AcBatchSize) }
        if ($Options.ExistingOutput) { [void]$args.Add('-ExistingOutput'); [void]$args.Add([string]$Options.ExistingOutput) }
    } elseif ($engine -eq 'ncnn') {
        if ($Options.NcnnModel) { [void]$args.Add('-Model'); [void]$args.Add([string]$Options.NcnnModel) }
        if ($Options.NcnnScale) { [void]$args.Add('-Scale'); [void]$args.Add([string]$Options.NcnnScale) }
        if ($null -ne $Options.NcnnTile) { [void]$args.Add('-Tile'); [void]$args.Add([string]$Options.NcnnTile) }
        if ($Options.NcnnGpu) { [void]$args.Add('-Gpu'); [void]$args.Add([string]$Options.NcnnGpu) }
        if ($Options.NcnnThreads) { [void]$args.Add('-Threads'); [void]$args.Add([string]$Options.NcnnThreads) }
        if ($Options.NcnnTta) { [void]$args.Add('-Tta') } else { [void]$args.Add('-NoTta') }
    } elseif ($engine -eq 'magpie') {
        $sel = if ($Options.MagpieSelectionType) { [string]$Options.MagpieSelectionType } else { 'mode' }
        [void]$args.Add('-MagpieSelectionType'); [void]$args.Add($sel)
        if ($sel -eq 'effect') {
            if ($Options.MagpieEffect) { [void]$args.Add('-MagpieEffect'); [void]$args.Add([string]$Options.MagpieEffect) }
        } elseif ($sel -eq 'family') {
            if ($Options.MagpieFamily) { [void]$args.Add('-MagpieFamily'); [void]$args.Add([string]$Options.MagpieFamily) }
            if ($Options.MagpieTier) { [void]$args.Add('-MagpieTier'); [void]$args.Add([string]$Options.MagpieTier) }
        } else {
            if ($Options.MagpieMode) { [void]$args.Add('-MagpieMode'); [void]$args.Add([string]$Options.MagpieMode) }
            if ($Options.MagpieTier) { [void]$args.Add('-MagpieTier'); [void]$args.Add([string]$Options.MagpieTier) }
        }
    } elseif ($engine -eq 'realcugan') {
        if ($Options.RealCuganModel) { [void]$args.Add('-Model'); [void]$args.Add([string]$Options.RealCuganModel) }
        if ($Options.RealCuganScale) { [void]$args.Add('-Scale'); [void]$args.Add([string]$Options.RealCuganScale) }
        if ($null -ne $Options.RealCuganNoiseLevel) { [void]$args.Add('-NoiseLevel'); [void]$args.Add([string]$Options.RealCuganNoiseLevel) }
        if ($null -ne $Options.RealCuganSyncGap) { [void]$args.Add('-SyncGap'); [void]$args.Add([string]$Options.RealCuganSyncGap) }
        if ($null -ne $Options.RealCuganTile) { [void]$args.Add('-Tile'); [void]$args.Add([string]$Options.RealCuganTile) }
        if ($Options.RealCuganGpu) { [void]$args.Add('-Gpu'); [void]$args.Add([string]$Options.RealCuganGpu) }
        if ($Options.RealCuganTta) { [void]$args.Add('-Tta') } else { [void]$args.Add('-NoTta') }
    } elseif ($engine -eq 'comfyui') {
        if ($Options.ComfyEndpoint) { [void]$args.Add('-ComfyEndpoint'); [void]$args.Add([string]$Options.ComfyEndpoint) }
        if ($Options.ComfyInstance) { [void]$args.Add('-ComfyInstance'); [void]$args.Add([string]$Options.ComfyInstance) }
        if ($Options.ComfyPreset) { [void]$args.Add('-ComfyPreset'); [void]$args.Add([string]$Options.ComfyPreset) }
        if ($Options.ComfyWorkflow) { [void]$args.Add('-ComfyWorkflow'); [void]$args.Add([string]$Options.ComfyWorkflow) }
    }

    return @($args)
}

function Get-IUKQueueSummary {
    param(
        [System.Collections.IEnumerable]$Items
    )
    $summary = @{
        Total = 0
        Pending = 0
        Running = 0
        Completed = 0
        Failed = 0
        Cancelled = 0
    }
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        $summary.Total++
        switch ([string]$it.Status) {
            '待处理' { $summary.Pending++ }
            '处理中' { $summary.Running++ }
            '已完成' { $summary.Completed++ }
            '失败' { $summary.Failed++ }
            '已取消' { $summary.Cancelled++ }
        }
    }
    return $summary
}
