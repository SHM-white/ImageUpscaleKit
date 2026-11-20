param(
    [string]$InputPath,
    [string]$OutputPath,
    [string]$ApiUrl,
    [string]$InstanceName,
    [string]$PresetName,
    [string]$WorkflowPath,
    [string]$WorkflowMapPath,
    [hashtable]$WorkflowParams
)

$Script:IUKComfyObjectInfoCache = @{}
$Script:IUKComfyKnownNodeHints = @{
    'UltimateSDUpscale' = '请安装 ComfyUI_UltimateSDUpscale: https://github.com/ssitu/ComfyUI_UltimateSDUpscale'
    'UltimateSDUpscaleNoUpscale' = '请安装 ComfyUI_UltimateSDUpscale: https://github.com/ssitu/ComfyUI_UltimateSDUpscale'
    'SUPIR_model_loader_v2' = '请安装 ComfyUI-SUPIR: https://github.com/kijai/ComfyUI-SUPIR'
    'SUPIR_first_stage' = '请安装 ComfyUI-SUPIR: https://github.com/kijai/ComfyUI-SUPIR'
    'SUPIR_conditioner' = '请安装 ComfyUI-SUPIR: https://github.com/kijai/ComfyUI-SUPIR'
    'SUPIR_sample' = '请安装 ComfyUI-SUPIR: https://github.com/kijai/ComfyUI-SUPIR'
    'SUPIR_decode' = '请安装 ComfyUI-SUPIR: https://github.com/kijai/ComfyUI-SUPIR'
}

function Convert-IUKHttpToWsUrl([string]$HttpUrl) {
    $u = $HttpUrl.TrimEnd('/')
    if ($u -match '^https://') { return ($u -replace '^https://', 'wss://') }
    return ($u -replace '^http://', 'ws://')
}

function Get-IUKComfyBackendFamily($SystemInfo) {
    if (-not $SystemInfo) { return 'Unknown' }
    $pt = [string]($SystemInfo.system.pytorch_version ?? '')
    $devs = @($SystemInfo.devices)
    foreach ($d in $devs) {
        $dtype = ([string]($d.type ?? '')).ToLowerInvariant()
        $dname = [string]($d.name ?? '')
        if ($dtype -eq 'xpu' -or $dname -match 'Intel.*Arc') { return 'XPU' }
    }
    if ($pt -match '\+xpu') { return 'XPU' }
    foreach ($d in $devs) {
        if (([string]($d.type ?? '')).ToLowerInvariant() -eq 'cuda') { return 'CUDA' }
    }
    if ($pt -match '\+cu') { return 'CUDA' }
    foreach ($d in $devs) {
        $dtype = ([string]($d.type ?? '')).ToLowerInvariant()
        if ($dtype -eq 'mps') { return 'MPS' }
        if ($dtype -eq 'cpu') { return 'CPU' }
    }
    return 'Unknown'
}

function Test-IUKComfyUIConnection {
    param(
        [string]$ApiUrl = 'http://127.0.0.1:8188',
        [int]$TimeoutSec = 5,
        [switch]$IncludeObjectInfo
    )
    $base = if ($ApiUrl) { $ApiUrl.TrimEnd('/') } else { 'http://127.0.0.1:8188' }
    try {
        $stats = Invoke-RestMethod -Uri "$base/system_stats" -Method Get -TimeoutSec $TimeoutSec
        $objInfo = $null
        $nodeCount = 0
        try {
            $objInfo = Invoke-RestMethod -Uri "$base/object_info" -Method Get -TimeoutSec ([Math]::Max($TimeoutSec, 8))
            if ($objInfo) {
                $Script:IUKComfyObjectInfoCache[$base] = $objInfo
                $nodeCount = @($objInfo.PSObject.Properties).Count
            }
        } catch {
            # Partial servers may only expose /system_stats on probe.
        }
        $devs = @($stats.devices)
        $primary = if ($devs.Count -gt 0) { $devs[0] } else { $null }
        $vramTotal = if ($primary -and $primary.vram_total) { [math]::Round(([double]$primary.vram_total) / 1MB, 1) } else { 0.0 }
        $vramFree = if ($primary -and $primary.vram_free) { [math]::Round(([double]$primary.vram_free) / 1MB, 1) } else { 0.0 }
        $family = Get-IUKComfyBackendFamily $stats
        return [pscustomobject]@{
            Connected = $true
            ApiUrl = $base
            ComfyVersion = [string]($stats.system.comfyui_version ?? 'unknown')
            PyTorchVersion = [string]($stats.system.pytorch_version ?? 'unknown')
            Os = [string]($stats.system.os ?? 'unknown')
            Devices = $devs
            BackendFamily = $family
            PrimaryDeviceName = [string]($primary.name ?? 'Unknown Device')
            VramTotalMb = $vramTotal
            VramFreeMb = $vramFree
            NodeCount = $nodeCount
            ObjectInfo = if ($IncludeObjectInfo) { $objInfo } else { $null }
            Error = ''
        }
    } catch {
        return [pscustomobject]@{
            Connected = $false
            ApiUrl = $base
            ComfyVersion = ''
            PyTorchVersion = ''
            Os = ''
            Devices = @()
            BackendFamily = 'Unknown'
            PrimaryDeviceName = ''
            VramTotalMb = 0.0
            VramFreeMb = 0.0
            NodeCount = 0
            ObjectInfo = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-IUKComfyUIObjectInfo {
    param(
        [string]$ApiUrl = 'http://127.0.0.1:8188',
        [switch]$ForceRefresh,
        [int]$TimeoutSec = 10
    )
    $base = $ApiUrl.TrimEnd('/')
    if (-not $ForceRefresh -and $Script:IUKComfyObjectInfoCache.ContainsKey($base)) {
        return $Script:IUKComfyObjectInfoCache[$base]
    }
    $info = Invoke-RestMethod -Uri "$base/object_info" -Method Get -TimeoutSec $TimeoutSec
    $Script:IUKComfyObjectInfoCache[$base] = $info
    return $info
}

function Find-IUKComfyUIInstall {
    param(
        [Parameter(Mandatory = $true)] [string]$InstallDir
    )
    if ([string]::IsNullOrWhiteSpace($InstallDir) -or -not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
        return [pscustomobject]@{
            Found = $false
            InstallDir = $InstallDir
            MainPyPath = ''
            PythonPath = ''
            Launchers = @()
            DetectedFlavor = 'Missing'
            RecommendedArgs = ''
            NeedsManualOverride = $true
            Message = "目录不存在: $InstallDir"
        }
    }

    $root = [IO.Path]::GetFullPath($InstallDir)
    $mainCandidates = @(
        (Join-Path $root 'ComfyUI\main.py'),
        (Join-Path $root 'main.py')
    )
    $mainPy = $mainCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

    $pythonCandidates = @(
        (Join-Path $root 'python_embeded\python.exe'),
        (Join-Path $root 'python_embedded\python.exe'),
        (Join-Path $root '.venv\Scripts\python.exe'),
        (Join-Path $root 'venv\Scripts\python.exe'),
        (Join-Path $root 'env\Scripts\python.exe'),
        (Join-Path $root 'ComfyUI\.venv\Scripts\python.exe'),
        (Join-Path $root 'ComfyUI\venv\Scripts\python.exe')
    )
    $pythonExe = $pythonCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

    $launcherNames = @('RUN_Launcher.bat', 'run_intel_xpu.bat', 'run_xpu.bat', 'run_nvidia_gpu.bat', 'run_cpu.bat', 'run.bat')
    $foundLaunchers = @()
    foreach ($ln in $launcherNames) {
        $lp = Join-Path $root $ln
        if (Test-Path -LiteralPath $lp -PathType Leaf) { $foundLaunchers += $lp }
    }
    # Also scan top-level *.bat files referencing main.py or python
    foreach ($bat in @(Get-ChildItem -LiteralPath $root -Filter '*.bat' -File -ErrorAction SilentlyContinue)) {
        if ($foundLaunchers -notcontains $bat.FullName) { $foundLaunchers += $bat.FullName }
    }

    $flavor = 'Unknown'
    $launcherText = ''
    foreach ($l in $foundLaunchers) {
        try { $launcherText += "`n" + (Get-Content -LiteralPath $l -Raw -ErrorAction SilentlyContinue) } catch {}
    }
    if ($foundLaunchers -match 'xpu' -or $launcherText -match '(?i)(xpu|oneapi|ipex|WinPortable-XPU)') {
        $flavor = 'XPU'
    } elseif ($foundLaunchers -match 'nvidia' -or $launcherText -match '(?i)(nvidia|cuda)') {
        $flavor = 'CUDA'
    } elseif ($pythonExe -match 'python_embeded') {
        $flavor = 'Portable'
    } elseif ($pythonExe -match 'venv|\.venv|env') {
        $flavor = 'Venv'
    }

    $recArgs = if ($pythonExe -match 'python_embeded') { '-s "{0}" --windows-standalone-build' -f $mainPy }
               elseif ($mainPy) { '"{0}"' -f $mainPy }
               else { '' }

    $found = (-not [string]::IsNullOrEmpty($mainPy)) -and ((-not [string]::IsNullOrEmpty($pythonExe)) -or $foundLaunchers.Count -gt 0)
    $needsManual = [string]::IsNullOrEmpty($mainPy) -or [string]::IsNullOrEmpty($pythonExe)

    $msg = if ($found -and -not $needsManual) {
        "识别成功 [$flavor]：Python=$pythonExe | Entry=$mainPy"
    } elseif ($found) {
        "部分识别 [$flavor]：发现启动脚本但未自动定位全部路径，建议确认启动配置。"
    } else {
        '未能自动识别 ComfyUI 入口或 Python 环境，请手动指定启动脚本或 Python 路径。'
    }

    return [pscustomobject]@{
        Found = $found
        InstallDir = $root
        MainPyPath = [string]($mainPy ?? '')
        PythonPath = [string]($pythonExe ?? '')
        Launchers = $foundLaunchers
        DetectedFlavor = $flavor
        RecommendedArgs = $recArgs
        NeedsManualOverride = $needsManual
        Message = $msg
    }
}

function Start-IUKComfyUIInstance {
    param(
        [Parameter(Mandatory = $true)] $Instance,
        [int]$WaitReadySec = 60,
        [string]$Root = $PSScriptRoot
    )
    $apiUrl = if ($Instance.api_url) { ([string]$Instance.api_url).TrimEnd('/') } else { 'http://127.0.0.1:8188' }
    $probe = Test-IUKComfyUIConnection -ApiUrl $apiUrl -TimeoutSec 2
    if ($probe.Connected) {
        return [pscustomobject]@{ AlreadyRunning = $true; Process = $null; LogFile = ''; Ready = $true; ConnectionInfo = $probe }
    }

    $installDir = [string]($Instance.install_dir ?? '')
    $detected = if ($installDir) { Find-IUKComfyUIInstall -InstallDir $installDir } else { $null }

    $pythonPath = if ($Instance.python_path) { [string]$Instance.python_path } elseif ($detected) { [string]$detected.PythonPath } else { '' }
    $startupScript = [string]($Instance.startup_script ?? '')
    $startupArgs = [string]($Instance.startup_args ?? '')

    $logDir = Join-Path $Root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = ([string]($Instance.name ?? 'comfyui')) -replace '[^\w\-]', '_'
    $outLog = Join-Path $logDir "comfyui-$safeName-$stamp.stdout.log"
    $errLog = Join-Path $logDir "comfyui-$safeName-$stamp.stderr.log"

    $workDir = if ($installDir -and (Test-Path -LiteralPath $installDir -PathType Container)) { $installDir }
               elseif ($startupScript -and (Test-Path -LiteralPath $startupScript)) { Split-Path -Parent $startupScript }
               else { $Root }

    $proc = $null
    if ($startupScript -and (Test-Path -LiteralPath $startupScript -PathType Leaf)) {
        if ($startupScript -match '\.(bat|cmd)$') {
            $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$startupScript`" $startupArgs") -WorkingDirectory $workDir -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
        } else {
            if (-not $pythonPath) { throw 'Specified Python startup script requires PythonPath.' }
            $proc = Start-Process -FilePath $pythonPath -ArgumentList "`"$startupScript`" $startupArgs" -WorkingDirectory $workDir -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
        }
    } else {
        if (-not $pythonPath -or -not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
            throw "ComfyUI Python executable not found. Configure python_path or startup_script for instance '$($Instance.name)'."
        }
        $mainPy = if ($detected -and $detected.MainPyPath) { $detected.MainPyPath } else { throw 'ComfyUI main.py not found.' }
        $isEmbed = ($pythonPath -match 'python_embeded|python_embedded')
        $prefix = if ($isEmbed) { '-s ' } else { '' }
        $argsStr = "${prefix}`"$mainPy`" $startupArgs".Trim()
        $proc = Start-Process -FilePath $pythonPath -ArgumentList $argsStr -WorkingDirectory $workDir -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($WaitReadySec)
    $readyInfo = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($proc.HasExited) {
            $errText = if (Test-Path -LiteralPath $errLog) { Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue } else { '' }
            throw "ComfyUI exited unexpectedly (code $($proc.ExitCode)). Log: $outLog / $errLog`n$errText"
        }
        $check = Test-IUKComfyUIConnection -ApiUrl $apiUrl -TimeoutSec 2
        if ($check.Connected) {
            $readyInfo = $check
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $readyInfo) {
        throw "Timed out waiting for ComfyUI at $apiUrl after ${WaitReadySec}s. Check logs: $outLog / $errLog"
    }

    return [pscustomobject]@{
        AlreadyRunning = $false
        Process = $proc
        LogFile = $outLog
        ErrorLogFile = $errLog
        Ready = $true
        ConnectionInfo = $readyInfo
    }
}

function Stop-IUKComfyUIInstance {
    param($Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            $Process.WaitForExit(3000) | Out-Null
        }
    } catch {}
}

function Get-IUKComfyPresets {
    param(
        [string]$Root = $PSScriptRoot
    )
    $dir = Join-Path $Root 'workflows\presets'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name) {
        try {
            $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $wfRel = [string]($obj.workflow ?? '')
            $mapRel = [string]($obj.workflow_map ?? '')
            $wfAbs = if ($wfRel) { if ([IO.Path]::IsPathRooted($wfRel)) { $wfRel } else { [IO.Path]::GetFullPath((Join-Path $Root $wfRel)) } } else { '' }
            $mapAbs = if ($mapRel) { if ([IO.Path]::IsPathRooted($mapRel)) { $mapRel } else { [IO.Path]::GetFullPath((Join-Path $Root $mapRel)) } } else { '' }
            [void]$list.Add([pscustomobject]@{
                Id = $f.BaseName
                Name = [string]($obj.name ?? $f.BaseName)
                Category = [string]($obj.category ?? 'general')
                Description = [string]($obj.description ?? '')
                PresetPath = $f.FullName
                WorkflowPath = $wfAbs
                WorkflowMapPath = $mapAbs
                Defaults = $obj.defaults
                Compatibility = $obj.compatibility
                Raw = $obj
            })
        } catch {}
    }
    return @($list)
}

function Resolve-IUKComfyNodeId {
    param(
        [Parameter(Mandatory = $true)] $WorkflowObj,
        [Parameter(Mandatory = $true)] $Selector
    )
    if ($Selector -is [string]) {
        if ($WorkflowObj.PSObject.Properties[$Selector]) { return $Selector }
        # Fall back to matching class_type
        foreach ($prop in $WorkflowObj.PSObject.Properties) {
            if ([string]$prop.Value.class_type -eq $Selector) { return $prop.Name }
        }
        return $null
    }

    if ($Selector.node_id -and $WorkflowObj.PSObject.Properties[[string]$Selector.node_id]) {
        return [string]$Selector.node_id
    }

    $targetClass = [string]($Selector.class_type ?? '')
    $titlePat = [string]($Selector.title_pattern ?? '')
    foreach ($prop in $WorkflowObj.PSObject.Properties) {
        $node = $prop.Value
        if ($null -eq $node -or -not $node.PSObject.Properties['class_type']) { continue }
        if ($targetClass -and [string]$node.class_type -ne $targetClass) { continue }
        if ($titlePat) {
            $title = [string]($node._meta.title ?? '')
            if ($title -notmatch $titlePat) { continue }
        }
        return $prop.Name
    }
    return $null
}

function Convert-IUKParamValue($Value, [string]$Type) {
    switch ($Type) {
        'int' { return [int]$Value }
        'float' { return [double]$Value }
        'bool' {
            if ($Value -is [bool]) { return $Value }
            if ($Value -is [string]) { return ($Value -match '^(true|1|yes)$') }
            return [bool]$Value
        }
        default { return [string]$Value }
    }
}

function Apply-IUKComfyWorkflowMapping {
    param(
        [Parameter(Mandatory = $true)] $WorkflowObj,
        $MappingObj,
        [hashtable]$ParamValues = @{},
        [string]$UploadedImageName
    )
    $cloned = ($WorkflowObj | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $applied = [ordered]@{}
    $outputNodeId = $null

    if ($MappingObj) {
        if ($MappingObj.input_image -and $UploadedImageName) {
            $inNodeId = Resolve-IUKComfyNodeId $cloned $MappingObj.input_image
            if (-not $inNodeId) { throw "Could not resolve input_image node in workflow." }
            $field = if ($MappingObj.input_image.input) { [string]$MappingObj.input_image.input } else { 'image' }
            $cloned.$inNodeId.inputs.$field = $UploadedImageName
            $applied['input_image'] = "$inNodeId.$field=$UploadedImageName"
        }
        if ($MappingObj.output_node) {
            $outputNodeId = Resolve-IUKComfyNodeId $cloned $MappingObj.output_node
        }
        if ($MappingObj.parameters) {
            foreach ($p in $MappingObj.parameters.PSObject.Properties) {
                $key = $p.Name
                $spec = $p.Value
                if (-not $ParamValues.ContainsKey($key)) { continue }
                $nid = Resolve-IUKComfyNodeId $cloned $spec
                if (-not $nid) { throw "Could not resolve node for mapped parameter '$key'." }
                $inpName = [string]($spec.input ?? $key)
                $coerced = Convert-IUKParamValue $ParamValues[$key] ([string]($spec.type ?? 'string'))
                $cloned.$nid.inputs | Add-Member -NotePropertyName $inpName -NotePropertyValue $coerced -Force
                $applied[$key] = $coerced
            }
        }
    } else {
        if ($UploadedImageName) {
            $loadId = Resolve-IUKComfyNodeId $cloned @{ class_type = 'LoadImage' }
            if ($loadId) {
                $cloned.$loadId.inputs.image = $UploadedImageName
                $applied['input_image'] = "$loadId.image=$UploadedImageName"
            }
        }
        if ($ParamValues -and $ParamValues.ContainsKey('upscale_model') -and $ParamValues['upscale_model']) {
            $upId = Resolve-IUKComfyNodeId $cloned @{ class_type = 'UpscaleModelLoader' }
            if ($upId) {
                $cloned.$upId.inputs | Add-Member -NotePropertyName 'model_name' -NotePropertyValue ([string]$ParamValues['upscale_model']) -Force
                $applied['upscale_model'] = [string]$ParamValues['upscale_model']
            }
        }
        $outputNodeId = Resolve-IUKComfyNodeId $cloned @{ class_type = 'SaveImage' }
        if (-not $outputNodeId) {
            $outputNodeId = Resolve-IUKComfyNodeId $cloned @{ class_type = 'PreviewImage' }
        }
    }

    if (-not $outputNodeId) {
        $outputNodeId = Resolve-IUKComfyNodeId $cloned @{ class_type = 'SaveImage' }
    }

    return [pscustomobject]@{
        Workflow = $cloned
        OutputNodeId = $outputNodeId
        AppliedParams = $applied
    }
}

function Format-IUKComfyError {
    param(
        [string]$RawError,
        [string]$BackendFamily = 'Unknown'
    )
    $msg = [string]($RawError ?? '')
    if ($msg -match '(?i)(torch not compiled with cuda|no cuda gpus|cuda.*required|xformers|triton|bitsandbytes|flash_attn|cublas|cudnn|cuda driver|cuda unavailable)') {
        return [pscustomobject]@{
            Category = 'CudaNodeIncompatible'
            Message = "检测到 CUDA 专用节点或依赖不兼容（非模型文件损坏）：当前 ComfyUI 设备类型为 $BackendFamily。建议切换兼容的通用/XPU 方案，或在 NVIDIA CUDA 环境执行。原始错误: $msg"
            RawError = $msg
        }
    }
    if ($msg -match '(?i)(out of memory|cuda error: out of memory|xpu.*out of memory|allocation on device|not enough memory)') {
        return [pscustomobject]@{
            Category = 'OutOfMemory'
            Message = "显存不足 (OOM)：请减小 Tile 尺寸、开启 Tiled VAE 或使用低显存预设。原始错误: $msg"
            RawError = $msg
        }
    }
    if ($msg -match '(?i)(value not in list|model.*not found|ckpt.*not found|upscale_model.*not found|no such file.*\.(safetensors|pth|ckpt|pt|bin))') {
        return [pscustomobject]@{
            Category = 'MissingModel'
            Message = "ComfyUI 缺少所需模型文件，请确认模型已放入 ComfyUI 对应 models 目录。原始错误: $msg"
            RawError = $msg
        }
    }
    if ($msg -match '(?i)(missing.*node|not exist|cannot execute because a node is missing)') {
        return [pscustomobject]@{
            Category = 'MissingNode'
            Message = "ComfyUI 缺少工作流所需自定义节点。原始错误: $msg"
            RawError = $msg
        }
    }
    return [pscustomobject]@{
        Category = 'WorkflowError'
        Message = "ComfyUI 执行失败: $msg"
        RawError = $msg
    }
}

function Get-IUKComfyInputOptions {
    param($FieldSpec)
    if ($null -eq $FieldSpec) { return $null }
    if ($FieldSpec -is [System.Array]) {
        if ($FieldSpec.Count -ge 1 -and ($FieldSpec[0] -is [System.Array])) {
            return ,(@($FieldSpec[0] | ForEach-Object { [string]$_ }))
        }
        if ($FieldSpec.Count -ge 2 -and [string]$FieldSpec[0] -eq 'COMBO' -and $null -ne $FieldSpec[1] -and $FieldSpec[1].PSObject.Properties['options']) {
            return ,(@($FieldSpec[1].options | ForEach-Object { [string]$_ }))
        }
    }
    return $null
}

function Get-IUKComfyAvailableModels {
    param($ObjectInfo)
    $upscaleModels = @()
    $checkpoints = @()
    if ($ObjectInfo) {
        if ($ObjectInfo.PSObject.Properties['UpscaleModelLoader']) {
            $um = $ObjectInfo.UpscaleModelLoader
            if ($um.input -and $um.input.required -and $um.input.required.PSObject.Properties['model_name']) {
                $opts = Get-IUKComfyInputOptions $um.input.required.model_name
                if ($null -ne $opts) { $upscaleModels = @($opts | Sort-Object -Unique) }
            }
        }
        if ($ObjectInfo.PSObject.Properties['CheckpointLoaderSimple']) {
            $ck = $ObjectInfo.CheckpointLoaderSimple
            if ($ck.input -and $ck.input.required -and $ck.input.required.PSObject.Properties['ckpt_name']) {
                $opts = Get-IUKComfyInputOptions $ck.input.required.ckpt_name
                if ($null -ne $opts) { $checkpoints = @($opts | Sort-Object -Unique) }
            }
        }
    }
    return [pscustomobject]@{
        UpscaleModels = $upscaleModels
        Checkpoints = $checkpoints
    }
}

function Test-IUKComfyWorkflowPreflight {
    param(
        [Parameter(Mandatory = $true)] $WorkflowObj,
        [Parameter(Mandatory = $true)] $ObjectInfo,
        $SystemInfo = $null
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $missingNodes = [System.Collections.Generic.List[string]]::new()
    $missingModels = [System.Collections.Generic.List[string]]::new()

    $modelFieldNames = @('ckpt_name', 'model_name', 'supir_model', 'vae_name', 'lora_name')

    foreach ($prop in $WorkflowObj.PSObject.Properties) {
        $node = $prop.Value
        if ($null -eq $node -or -not $node.PSObject.Properties['class_type']) { continue }
        $cls = [string]$node.class_type
        if (-not $ObjectInfo.PSObject.Properties[$cls]) {
            if ($missingNodes -notcontains $cls) {
                [void]$missingNodes.Add($cls)
                $hint = if ($Script:IUKComfyKnownNodeHints.ContainsKey($cls)) { " ($($Script:IUKComfyKnownNodeHints[$cls]))" } else { '' }
                [void]$errors.Add("MissingNode: 节点 '$cls' 未安装$hint")
            }
            continue
        }

        $nodeSpec = $ObjectInfo.$cls
        if ($node.inputs -and $nodeSpec.input) {
            foreach ($mf in $modelFieldNames) {
                if (-not $node.inputs.PSObject.Properties[$mf]) { continue }
                $val = $node.inputs.$mf
                if ($val -is [System.Array]) { continue } # Connected link, not a filename
                $sVal = [string]$val
                if ([string]::IsNullOrWhiteSpace($sVal)) { continue }
                $fieldSpec = $null
                if ($nodeSpec.input.required -and $nodeSpec.input.required.PSObject.Properties[$mf]) {
                    $fieldSpec = $nodeSpec.input.required.$mf
                } elseif ($nodeSpec.input.optional -and $nodeSpec.input.optional.PSObject.Properties[$mf]) {
                    $fieldSpec = $nodeSpec.input.optional.$mf
                }
                $allowed = Get-IUKComfyInputOptions $fieldSpec
                if ($null -ne $allowed -and ($allowed -notcontains $sVal)) {
                    [void]$missingModels.Add($sVal)
                    if ($allowed.Count -eq 0) {
                        [void]$errors.Add("MissingModel: 节点 '$cls' 所需模型 '$sVal' 未在 ComfyUI 中找到（对应目录暂无模型，请通过「权重管理」下载后刷新/重启 ComfyUI）。")
                    } else {
                        $sample = ($allowed | Select-Object -First 5) -join ', '
                        if ($allowed.Count -gt 5) { $sample += ', ...' }
                        [void]$errors.Add("MissingModel: 节点 '$cls' 所需模型 '$sVal' 未在 ComfyUI 中找到（当前可用: $sample；请下载所需权重或在右侧「超分模型」切换已有模型）。")
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        Valid = ($errors.Count -eq 0)
        Errors = @($errors)
        Warnings = @($warnings)
        MissingNodes = @($missingNodes)
        MissingModels = @($missingModels)
    }
}

function Send-IUKComfyImage {
    param(
        [Parameter(Mandatory = $true)] [string]$ApiUrl,
        [Parameter(Mandatory = $true)] [string]$ImagePath
    )
    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "Input image not found: $ImagePath"
    }
    $base = $ApiUrl.TrimEnd('/')
    $bytes = [IO.File]::ReadAllBytes($ImagePath)
    $ext = [IO.Path]::GetExtension($ImagePath).ToLowerInvariant()
    if (-not $ext) { $ext = '.png' }
    # Use ASCII upload filename to avoid multipart header encoding issues on Chinese paths.
    $uploadName = 'iuk_' + [guid]::NewGuid().ToString('N').Substring(0, 12) + $ext

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    try {
        $mp = [System.Net.Http.MultipartFormDataContent]::new()
        $fileContent = [System.Net.Http.ByteArrayContent]::new($bytes)
        $mime = switch ($ext) {
            '.jpg' { 'image/jpeg' }
            '.jpeg' { 'image/jpeg' }
            '.webp' { 'image/webp' }
            default { 'image/png' }
        }
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($mime)
        $mp.Add($fileContent, 'image', $uploadName)
        $mp.Add([System.Net.Http.StringContent]::new('true'), 'overwrite')
        $resp = $client.PostAsync("$base/upload/image", $mp).GetAwaiter().GetResult()
        $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            throw "Failed to upload image to ComfyUI ($($resp.StatusCode)): $respBody"
        }
        return ($respBody | ConvertFrom-Json)
    } finally {
        $client.Dispose()
    }
}

function Stop-IUKComfyTask {
    param(
        [Parameter(Mandatory = $true)] [string]$ApiUrl,
        [string]$PromptId
    )
    $base = $ApiUrl.TrimEnd('/')
    try {
        Invoke-RestMethod -Uri "$base/interrupt" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 5 | Out-Null
    } catch {}
    if ($PromptId) {
        try {
            $delBody = @{ delete = @($PromptId) } | ConvertTo-Json
            Invoke-RestMethod -Uri "$base/queue" -Method Post -ContentType 'application/json' -Body $delBody -TimeoutSec 5 | Out-Null
        } catch {}
    }
}

function Wait-IUKComfyPromptCompletion {
    param(
        [Parameter(Mandatory = $true)] [string]$ApiUrl,
        [Parameter(Mandatory = $true)] [string]$PromptId,
        [Parameter(Mandatory = $true)] [string]$ClientId,
        [Parameter(Mandatory = $true)] [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$BackendFamily = 'Unknown',
        [scriptblock]$OnProgress,
        [scriptblock]$ShouldCancel,
        [int]$TimeoutSec = 1800
    )
    $base = $ApiUrl.TrimEnd('/')
    $buf = [byte[]]::new(16384)
    $seg = [ArraySegment[byte]]::new($buf)
    $ms = [IO.MemoryStream]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $lastHistoryCheck = [DateTime]::UtcNow

    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($ShouldCancel -and (& $ShouldCancel)) {
                Stop-IUKComfyTask -ApiUrl $base -PromptId $PromptId
                throw 'ComfyUI task cancelled by user.'
            }

            if ($WebSocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $cts = [System.Threading.CancellationTokenSource]::new(500)
                try {
                    $recvTask = $WebSocket.ReceiveAsync($seg, $cts.Token)
                    $res = $recvTask.GetAwaiter().GetResult()
                    if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        break
                    }
                    if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text -and $res.Count -gt 0) {
                        $ms.Write($buf, 0, $res.Count)
                        if ($res.EndOfMessage) {
                            $txt = [Text.Encoding]::UTF8.GetString($ms.ToArray())
                            $ms.SetLength(0)
                            $evt = $null
                            try { $evt = $txt | ConvertFrom-Json } catch {}
                            if ($evt) {
                                $evtPrompt = [string]($evt.data.prompt_id ?? '')
                                if ($evt.type -eq 'progress' -and $OnProgress -and ($evtPrompt -eq $PromptId -or -not $evtPrompt)) {
                                    & $OnProgress ([int]$evt.data.value) ([int]$evt.data.max)
                                } elseif ($evt.type -eq 'executing' -and $evtPrompt -eq $PromptId -and $null -eq $evt.data.node) {
                                    break
                                } elseif ($evt.type -eq 'execution_error' -and ($evtPrompt -eq $PromptId -or -not $evtPrompt)) {
                                    $errDetail = [string]($evt.data.exception_message ?? ($evt.data | ConvertTo-Json -Compress))
                                    $formatted = Format-IUKComfyError -RawError $errDetail -BackendFamily $BackendFamily
                                    throw "[$($formatted.Category)] $($formatted.Message)"
                                } elseif ($evt.type -eq 'execution_interrupted' -and ($evtPrompt -eq $PromptId -or -not $evtPrompt)) {
                                    throw 'ComfyUI execution interrupted.'
                                }
                            }
                        }
                    }
                } catch [OperationCanceledException] {
                    # Normal 500ms receive timeout for cancellation & history polling.
                } finally {
                    $cts.Dispose()
                }
            } else {
                Start-Sleep -Milliseconds 300
            }

            if (([DateTime]::UtcNow - $lastHistoryCheck).TotalSeconds -ge 1.0) {
                $lastHistoryCheck = [DateTime]::UtcNow
                try {
                    $hist = Invoke-RestMethod -Uri "$base/history/$PromptId" -Method Get -TimeoutSec 5
                    if ($hist -and $hist.PSObject.Properties[$PromptId]) {
                        $entry = $hist.$PromptId
                        if ($entry.status -and $entry.status.status_str -eq 'error') {
                            $msgText = ($entry.status.messages | ConvertTo-Json -Compress)
                            $formatted = Format-IUKComfyError -RawError $msgText -BackendFamily $BackendFamily
                            throw "[$($formatted.Category)] $($formatted.Message)"
                        }
                        if ($entry.outputs) {
                            return $entry
                        }
                    }
                } catch {
                    if ($_.Exception.Message -match '^\[(CudaNodeIncompatible|OutOfMemory|MissingModel|MissingNode|WorkflowError)\]') {
                        throw
                    }
                }
            }
        }

        $finalHist = Invoke-RestMethod -Uri "$base/history/$PromptId" -Method Get -TimeoutSec 10
        if ($finalHist -and $finalHist.PSObject.Properties[$PromptId]) {
            return $finalHist.$PromptId
        }
        throw "ComfyUI task $PromptId timed out waiting for history."
    } finally {
        $ms.Dispose()
    }
}

function Invoke-IUKComfyUIWorkflow {
    param(
        [Parameter(Mandatory = $true)] [string]$InputPath,
        [string]$OutputPath,
        [string]$ApiUrl,
        [string]$InstanceName,
        [string]$PresetName,
        [string]$WorkflowPath,
        [string]$WorkflowMapPath,
        [hashtable]$WorkflowParams = @{},
        [string]$Root = $PSScriptRoot,
        [scriptblock]$OnProgress,
        [scriptblock]$ShouldCancel
    )
    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "Input path not found: $InputPath"
    }

    # Resolve endpoint & instance configuration
    $resolvedUrl = $ApiUrl
    if (-not $resolvedUrl -and (Test-Path -LiteralPath (Join-Path $Root 'ConfigHelpers.ps1'))) {
        . (Join-Path $Root 'ConfigHelpers.ps1')
        $allCfg = Get-IUKConfig -Root $Root
        $inst = Get-IUKActiveComfyInstance -LocalCfg $allCfg.Local -InstanceName $InstanceName
        if ($inst -and $inst.api_url) { $resolvedUrl = [string]$inst.api_url }
    }
    if (-not $resolvedUrl) { $resolvedUrl = 'http://127.0.0.1:8188' }
    $resolvedUrl = $resolvedUrl.TrimEnd('/')

    # Resolve preset or explicit workflow/mapping
    $effectiveParams = @{}
    $effectiveWfPath = $WorkflowPath
    $effectiveMapPath = $WorkflowMapPath
    $presetLabel = ''

    if ($PresetName) {
        $presets = @(Get-IUKComfyPresets -Root $Root)
        $match = @($presets | Where-Object { $_.Id -eq $PresetName -or $_.Name -eq $PresetName }) | Select-Object -First 1
        if (-not $match) { throw "ComfyUI preset not found: $PresetName" }
        $presetLabel = $match.Id
        if (-not $effectiveWfPath) { $effectiveWfPath = $match.WorkflowPath }
        if (-not $effectiveMapPath) { $effectiveMapPath = $match.WorkflowMapPath }
        if ($match.Defaults) {
            foreach ($dp in $match.Defaults.PSObject.Properties) {
                $effectiveParams[$dp.Name] = $dp.Value
            }
        }
    }
    if ($WorkflowParams) {
        foreach ($k in $WorkflowParams.Keys) { $effectiveParams[$k] = $WorkflowParams[$k] }
    }
    if (-not $effectiveWfPath -or -not (Test-Path -LiteralPath $effectiveWfPath -PathType Leaf)) {
        throw "ComfyUI workflow JSON not found: $effectiveWfPath"
    }

    $wfObj = Get-Content -LiteralPath $effectiveWfPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $mapObj = if ($effectiveMapPath -and (Test-Path -LiteralPath $effectiveMapPath -PathType Leaf)) {
        Get-Content -LiteralPath $effectiveMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }

    # Connect & preflight
    $conn = Test-IUKComfyUIConnection -ApiUrl $resolvedUrl -TimeoutSec 5 -IncludeObjectInfo
    if (-not $conn.Connected) {
        throw "Cannot connect to ComfyUI at ${resolvedUrl}: $($conn.Error)"
    }
    $objInfo = if ($conn.ObjectInfo) { $conn.ObjectInfo } else { Get-IUKComfyUIObjectInfo -ApiUrl $resolvedUrl -ForceRefresh }

    # Pre-map parameters (excluding image) so preflight validates actual chosen models
    $preMapped = Apply-IUKComfyWorkflowMapping -WorkflowObj $wfObj -MappingObj $mapObj -ParamValues $effectiveParams -UploadedImageName 'placeholder.png'
    $preflight = Test-IUKComfyWorkflowPreflight -WorkflowObj $preMapped.Workflow -ObjectInfo $objInfo -SystemInfo $conn
    if (-not $preflight.Valid) {
        throw ($preflight.Errors -join "`n")
    }

    $inputFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $InputPath).Path)
    $inputItem = Get-Item -LiteralPath $inputFull
    $exts = @('.png', '.jpg', '.jpeg', '.bmp', '.webp', '.tif', '.tiff')
    $files = if ($inputItem.PSIsContainer) {
        @(Get-ChildItem -LiteralPath $inputItem.FullName -File | Where-Object { $_.Extension.ToLowerInvariant() -in $exts } | Sort-Object Name)
    } else { @($inputItem) }
    if ($files.Count -eq 0) { throw 'No supported images found for ComfyUI.' }

    if (-not $OutputPath) {
        $OutputPath = if ($inputItem.PSIsContainer) { $inputItem.FullName.TrimEnd('\') + '_comfyui' }
                      else { Join-Path $inputItem.Directory.FullName ($inputItem.BaseName + '_comfyui.png') }
    }
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    if ($inputItem.PSIsContainer -or (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    } else {
        $parentDir = Split-Path -Parent $OutputPath
        if ($parentDir) { New-Item -ItemType Directory -Force -Path $parentDir | Out-Null }
    }

    $logDir = Join-Path $Root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $logFile = Join-Path $logDir ('comfyui-run-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.log')

    $results = [System.Collections.Generic.List[object]]::new()
    $http = [System.Net.Http.HttpClient]::new()
    $http.Timeout = [TimeSpan]::FromSeconds(120)

    try {
        foreach ($file in $files) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $dest = if ($inputItem.PSIsContainer -or (Test-Path -LiteralPath $OutputPath -PathType Container)) {
                Join-Path $OutputPath ($file.BaseName + '.png')
            } else {
                $OutputPath
            }
            if ($dest -eq $file.FullName) { throw "Output must not replace input image: $dest" }

            $uploaded = Send-IUKComfyImage -ApiUrl $resolvedUrl -ImagePath $file.FullName
            $serverImgName = if ($uploaded.subfolder) { "$($uploaded.subfolder)/$($uploaded.name)" } else { [string]$uploaded.name }
            $mapped = Apply-IUKComfyWorkflowMapping -WorkflowObj $wfObj -MappingObj $mapObj -ParamValues $effectiveParams -UploadedImageName $serverImgName

            $clientId = [guid]::NewGuid().ToString('N')
            $wsUrl = (Convert-IUKHttpToWsUrl $resolvedUrl) + "/ws?client_id=$clientId"
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            $promptId = ''
            try {
                $wsCts = [System.Threading.CancellationTokenSource]::new(10000)
                try {
                    $null = $ws.ConnectAsync([Uri]$wsUrl, $wsCts.Token).GetAwaiter().GetResult()
                } finally { $wsCts.Dispose() }

                $payloadJson = ([ordered]@{
                    prompt = $mapped.Workflow
                    client_id = $clientId
                }) | ConvertTo-Json -Depth 30
                $content = [System.Net.Http.StringContent]::new($payloadJson, [Text.Encoding]::UTF8, 'application/json')
                $submitResp = $http.PostAsync("$resolvedUrl/prompt", $content).GetAwaiter().GetResult()
                $submitBody = $submitResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if (-not $submitResp.IsSuccessStatusCode) {
                    $fmt = Format-IUKComfyError -RawError $submitBody -BackendFamily $conn.BackendFamily
                    throw "[$($fmt.Category)] $($fmt.Message)"
                }
                $submitObj = $submitBody | ConvertFrom-Json
                if ($submitObj.node_errors -and @($submitObj.node_errors.PSObject.Properties).Count -gt 0) {
                    $neText = $submitObj.node_errors | ConvertTo-Json -Depth 10 -Compress
                    $fmt = Format-IUKComfyError -RawError $neText -BackendFamily $conn.BackendFamily
                    throw "[$($fmt.Category)] $($fmt.Message)"
                }
                $promptId = [string]$submitObj.prompt_id

                $histEntry = Wait-IUKComfyPromptCompletion `
                    -ApiUrl $resolvedUrl `
                    -PromptId $promptId `
                    -ClientId $clientId `
                    -WebSocket $ws `
                    -BackendFamily $conn.BackendFamily `
                    -OnProgress $OnProgress `
                    -ShouldCancel $ShouldCancel

                $outImgInfo = $null
                if ($mapped.OutputNodeId -and $histEntry.outputs.PSObject.Properties[$mapped.OutputNodeId]) {
                    $outImgInfo = @($histEntry.outputs.($mapped.OutputNodeId).images) | Select-Object -First 1
                }
                if (-not $outImgInfo) {
                    foreach ($op in $histEntry.outputs.PSObject.Properties) {
                        if ($op.Value.images -and @($op.Value.images).Count -gt 0) {
                            $outImgInfo = @($op.Value.images)[0]
                            break
                        }
                    }
                }
                if (-not $outImgInfo) { throw "ComfyUI completed prompt '$promptId' without output images." }

                $fn = [Uri]::EscapeDataString([string]$outImgInfo.filename)
                $sf = [Uri]::EscapeDataString([string]($outImgInfo.subfolder ?? ''))
                $tp = [Uri]::EscapeDataString([string]($outImgInfo.type ?? 'output'))
                $viewResp = $http.GetAsync("$resolvedUrl/view?filename=$fn&subfolder=$sf&type=$tp").GetAwaiter().GetResult()
                if (-not $viewResp.IsSuccessStatusCode) {
                    throw "Failed to download ComfyUI output ($($viewResp.StatusCode))"
                }
                $outBytes = $viewResp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                $destParent = Split-Path -Parent $dest
                if ($destParent) { New-Item -ItemType Directory -Force -Path $destParent | Out-Null }
                [IO.File]::WriteAllBytes($dest, $outBytes)
            } finally {
                try {
                    if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                        $closeCts = [System.Threading.CancellationTokenSource]::new(1500)
                        $null = $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $closeCts.Token).GetAwaiter().GetResult()
                        $closeCts.Dispose()
                    }
                } catch {}
                $ws.Dispose()
            }

            $sw.Stop()
            $postConn = Test-IUKComfyUIConnection -ApiUrl $resolvedUrl -TimeoutSec 2
            $record = [pscustomobject]@{
                InputPath = $file.FullName
                OutputPath = $dest
                PromptId = $promptId
                ApiUrl = $resolvedUrl
                BackendFamily = $conn.BackendFamily
                DeviceName = $conn.PrimaryDeviceName
                ComfyVersion = $conn.ComfyVersion
                PyTorchVersion = $conn.PyTorchVersion
                Preset = $presetLabel
                ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                VramTotalMb = $conn.VramTotalMb
                VramFreeAfterMb = if ($postConn.Connected) { $postConn.VramFreeMb } else { 0.0 }
                LogFile = $logFile
            }
            [void]$results.Add($record)
            ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $logFile -Encoding utf8
            Write-Host "ComfyUI Done [$($conn.BackendFamily) / $($conn.PrimaryDeviceName)]: $dest ($([math]::Round($sw.Elapsed.TotalSeconds, 2))s)" -ForegroundColor Green
        }
    } finally {
        $http.Dispose()
    }

    return @($results)
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $InputPath) {
        throw 'InputPath is required when executing ComfyUI.ps1 directly.'
    }
    $null = Invoke-IUKComfyUIWorkflow `
        -InputPath $InputPath `
        -OutputPath $OutputPath `
        -ApiUrl $ApiUrl `
        -InstanceName $InstanceName `
        -PresetName $PresetName `
        -WorkflowPath $WorkflowPath `
        -WorkflowMapPath $WorkflowMapPath `
        -WorkflowParams ($WorkflowParams ?? @{})
}
