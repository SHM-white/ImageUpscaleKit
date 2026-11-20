param(
    [string]$TestSetDir = (Join-Path $PSScriptRoot 'tests\benchmark\dataset'),
    [string]$OutputDir = (Join-Path $PSScriptRoot ('temp\benchmark-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [ValidateSet(2, 4)] [int]$Scale = 2,
    [string[]]$Backends = @('anime4kcpp', 'ncnn', 'realcugan', 'magpie', 'comfyui_swinir', 'comfyui_hat', 'comfyui_usdu', 'comfyui_supir'),
    [ValidateSet('auto', 'cpu', 'opencl', 'cuda')] [string]$AcProcessor = 'auto',
    [switch]$IncludeMagpie,
    [string]$ComfyEndpoint = 'http://127.0.0.1:8188',
    [switch]$EnableLpips
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Initialize-IUKMetricsTypes {
    if ('ImageUpscaleKit.Metrics.ImageMetricsCalculator' -as [type]) {
        return
    }
    Add-Type -AssemblyName System.Drawing
    $null = [System.Drawing.Bitmap]
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
    $csPath = Join-Path $root 'src\ImageMetrics.cs'
    if (-not (Test-Path -LiteralPath $csPath -PathType Leaf)) {
        throw "ImageMetrics.cs not found: $csPath"
    }
    $source = Get-Content -LiteralPath $csPath -Raw -Encoding UTF8
    Add-Type -ReferencedAssemblies @($refMap.Values) -TypeDefinition $source -Language CSharp
}

Initialize-IUKMetricsTypes
Add-Type -AssemblyName System.Drawing

function Get-IUKImageSize([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $ms = [IO.MemoryStream]::new($bytes, $false)
    $img = [System.Drawing.Image]::FromStream($ms, $false, $true)
    try {
        return "$($img.Width)x$($img.Height)"
    } finally { $img.Dispose(); $ms.Dispose() }
}

function Invoke-IUKStandaloneRealCugan([string]$ExePath, [string]$InputFile, [string]$OutputFile, [int]$ScaleRatio, [string]$WorkDir, [string]$LogDir) {
    $rcRoot = Split-Path -Parent $ExePath
    $modelPack = 'models-se'
    if (-not (Test-Path -LiteralPath (Join-Path $rcRoot $modelPack) -PathType Container)) {
        throw "Real-CUGAN model folder missing: $rcRoot\$modelPack"
    }
    $stageInName = 'rc_in_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.png'
    $stageOutName = 'rc_out_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.png'
    $stageIn = Join-Path $WorkDir $stageInName
    $stageOut = Join-Path $WorkDir $stageOutName
    Copy-Item -LiteralPath $InputFile -Destination $stageIn -Force

    $logFile = Join-Path $LogDir ('bench-realcugan-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.log')
    try {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $ExePath
        $psi.WorkingDirectory = $rcRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($a in @('-i', $stageIn, '-o', $stageOut, '-m', $modelPack, '-s', [string]$ScaleRatio, '-n', '-1', '-f', 'png')) {
            [void]$psi.ArgumentList.Add($a)
        }
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        $txt = ($out.GetAwaiter().GetResult() + "`n" + $err.GetAwaiter().GetResult()).Trim()
        if ($txt) { $txt | Set-Content -LiteralPath $logFile -Encoding utf8 }
        if ($p.ExitCode -ne 0) { throw "Real-CUGAN failed (exit $($p.ExitCode)): $txt" }
        if (-not (Test-Path -LiteralPath $stageOut) -or (Get-Item -LiteralPath $stageOut).Length -eq 0) {
            throw 'Real-CUGAN produced no output.'
        }
        $parent = Split-Path -Parent $OutputFile
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        [IO.File]::Move($stageOut, $OutputFile, $true)
        return $logFile
    } finally {
        Remove-Item -LiteralPath $stageIn, $stageOut -Force -ErrorAction SilentlyContinue
    }
}

# Ensure test dataset exists
$manifestPath = Join-Path $TestSetDir 'dataset_manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $null = & (Join-Path $root 'tests\benchmark\Generate-TestSet.ps1') -OutputDir $TestSetDir
}
$dataset = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($dataset.items)
if ($items.Count -eq 0) { throw "Benchmark dataset has no items: $manifestPath" }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$cfg = Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# Hardware probe
$gpus = @()
try {
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
        "$($_.Name) (Driver $($_.DriverVersion))"
    })
} catch {}
$gpuSummary = if ($gpus.Count -gt 0) { $gpus -join '; ' } else { 'Unknown GPU' }

# Optional ComfyUI probe
$hasComfyModule = Test-Path -LiteralPath (Join-Path $root 'ComfyUI.ps1') -PathType Leaf
$comfyConn = $null
if ($hasComfyModule -and @($Backends | Where-Object { $_ -like 'comfyui_*' }).Count -gt 0) {
    . (Join-Path $root 'ComfyUI.ps1')
    $comfyConn = Test-IUKComfyUIConnection -ApiUrl $ComfyEndpoint -TimeoutSec 2 -IncludeObjectInfo
}

# Optional LPIPS probe (never blocks if absent)
$lpipsAvailable = $false
if ($EnableLpips) {
    try {
        $pyCheck = & python -c "import lpips; print('OK')" 2>$null
        if ($LASTEXITCODE -eq 0 -and "$pyCheck" -match 'OK') { $lpipsAvailable = $true }
    } catch {}
}

$records = [System.Collections.Generic.List[object]]::new()
$backendSummaries = [System.Collections.Generic.List[object]]::new()
$comparisonMap = [ordered]@{}
foreach ($it in $items) {
    $lrPath = if ($Scale -eq 4) { [string]$it.lr_x4_path } else { [string]$it.lr_x2_path }
    $comparisonMap[$it.file] = [ordered]@{
        name = "$($it.category) ($($it.file))"
        category = [string]$it.category
        focus = [string]$it.focus
        hr_path = [string]$it.hr_path
        lr_path = $lrPath
        results = [System.Collections.Generic.List[object]]::new()
    }
}

$workStage = Join-Path $root ('temp\bench-stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $workStage | Out-Null

try {
    foreach ($backend in $Backends) {
        $available = $true
        $skipReason = ''
        $modelLabel = ''
        $workflowVersion = 'N/A'
        $deviceLabel = $gpuSummary
        $vramPeak = 'N/A'
        $comfyPresetId = ''

        switch ($backend) {
            'anime4kcpp' {
                $acExe = Join-Path $root ([string]$cfg.anime4kcpp.backend_path)
                $modelLabel = [string]$cfg.anime4kcpp.model
                $deviceLabel = "$AcProcessor / Device $([int]$cfg.anime4kcpp.device) ($gpuSummary)"
                if ($Scale -ne 2) {
                    $available = $false; $skipReason = "Anime4KCPP 仅支持 2x 输出，当前评测倍率为 ${Scale}x。"
                } elseif (-not (Test-Path -LiteralPath $acExe -PathType Leaf)) {
                    $available = $false; $skipReason = "Anime4KCPP 未安装 ($acExe)。"
                }
            }
            'ncnn' {
                $nExe = Join-Path $root ([string]$cfg.ncnn.backend_path)
                $modelLabel = [string]$cfg.ncnn.model
                $mDir = Join-Path $root ([string]$cfg.ncnn.model_dir)
                $deviceLabel = "Vulkan ($gpuSummary)"
                if (-not (Test-Path -LiteralPath $nExe -PathType Leaf)) {
                    $available = $false; $skipReason = "Real-ESRGAN NCNN 未安装 ($nExe)。"
                } elseif (-not (Test-Path -LiteralPath (Join-Path $mDir "$modelLabel.param")) -or -not (Test-Path -LiteralPath (Join-Path $mDir "$modelLabel.bin"))) {
                    $available = $false; $skipReason = "NCNN 模型缺失: $modelLabel"
                }
            }
            'realcugan' {
                $rcExe = Join-Path $root 'bin\realcugan\realcugan-ncnn-vulkan.exe'
                $modelLabel = 'models-se (no-denoise)'
                $deviceLabel = "Vulkan ($gpuSummary)"
                if (-not (Test-Path -LiteralPath $rcExe -PathType Leaf)) {
                    $available = $false; $skipReason = "Real-CUGAN 未安装 ($rcExe)。"
                }
            }
            'magpie' {
                $mExe = Join-Path $root ([string]$cfg.magpie.exe_path)
                $modelLabel = "Magpie $($cfg.magpie.family)/$($cfg.magpie.mode)"
                if (-not $IncludeMagpie) {
                    $available = $false; $skipReason = '未传入 -IncludeMagpie（无人值守模式默认跳过需桌面捕获的 Magpie）。'
                } elseif (-not (Test-Path -LiteralPath $mExe -PathType Leaf)) {
                    $available = $false; $skipReason = "Magpie 未安装 ($mExe)。"
                }
            }
            { $_ -like 'comfyui_*' } {
                $comfyPresetId = switch ($backend) {
                    'comfyui_swinir' { if ($Scale -eq 4) { 'swinir_real_x4' } else { 'swinir_classical_x2' } }
                    'comfyui_hat' { 'hat_sr_x4' }
                    'comfyui_usdu' { 'usdu_fidelity' }
                    'comfyui_supir' { 'supir_lowvram_12gb' }
                }
                $modelLabel = $comfyPresetId
                $workflowVersion = 'API-v1'
                if (-not $hasComfyModule) {
                    $available = $false; $skipReason = 'ComfyUI 适配模块 (ComfyUI.ps1) 未安装于当前分支。'
                } elseif (-not $comfyConn -or -not $comfyConn.Connected) {
                    $available = $false; $skipReason = "ComfyUI 服务未运行 ($ComfyEndpoint)。"
                } else {
                    $deviceLabel = "$($comfyConn.BackendFamily) / $($comfyConn.PrimaryDeviceName)"
                    $presets = @(Get-IUKComfyPresets -Root $root)
                    $pMatch = @($presets | Where-Object { $_.Id -eq $comfyPresetId }) | Select-Object -First 1
                    if (-not $pMatch) {
                        $available = $false; $skipReason = "未找到工作流预设: $comfyPresetId"
                    } else {
                        $wfObj = Get-Content -LiteralPath $pMatch.WorkflowPath -Raw | ConvertFrom-Json
                        $mapObj = Get-Content -LiteralPath $pMatch.WorkflowMapPath -Raw | ConvertFrom-Json
                        $defParams = @{}
                        if ($pMatch.Defaults) {
                            foreach ($dp in $pMatch.Defaults.PSObject.Properties) { $defParams[$dp.Name] = $dp.Value }
                        }
                        $pre = Apply-IUKComfyWorkflowMapping -WorkflowObj $wfObj -MappingObj $mapObj -ParamValues $defParams -UploadedImageName 'probe.png'
                        $pf = Test-IUKComfyWorkflowPreflight -WorkflowObj $pre.Workflow -ObjectInfo $comfyConn.ObjectInfo -SystemInfo $comfyConn
                        if (-not $pf.Valid) {
                            $available = $false; $skipReason = ($pf.Errors -join '; ')
                        }
                    }
                }
            }
        }

        if (-not $available) {
            Write-Host "SKIP [$backend]: $skipReason" -ForegroundColor Yellow
            [void]$backendSummaries.Add([pscustomobject]@{
                Backend = $backend; Model = $modelLabel; Status = 'Skipped'; SkipReason = $skipReason
                Device = $deviceLabel; ColdStartMs = 'N/A'; WarmAvgMs = 'N/A'
                AvgPsnrY = 'N/A'; AvgPsnrRgb = 'N/A'; AvgSsimY = 'N/A'
            })
            [void]$records.Add([pscustomobject]@{
                Backend = $backend; Model = $modelLabel; WorkflowVersion = $workflowVersion; Device = $deviceLabel
                Category = 'ALL'; ImageFile = ''; InputResolution = ''; OutputResolution = ''
                ColdStartMs = ''; ElapsedMs = ''; VramPeakMb = 'N/A'; AlignmentPolicy = ''; ExactSizeMatch = ''
                PsnrY = ''; PsnrRgb = ''; SsimY = ''; Lpips = 'N/A'; Status = 'Skipped'; Error = $skipReason; LogFile = ''
            })
            continue
        }

        $backendOutDir = Join-Path $OutputDir $backend
        New-Item -ItemType Directory -Force -Path $backendOutDir | Out-Null
        $entryScript = Join-Path $root 'Upscale.ps1'
        $hasRealCuganScript = Test-Path -LiteralPath (Join-Path $root 'RealCUGAN.ps1') -PathType Leaf

        $runSingleItem = {
            param($ItemObj, [string]$OutFilePath)
            $lrPath = if ($Scale -eq 4) { [string]$ItemObj.lr_x4_path } else { [string]$ItemObj.lr_x2_path }
            $usedLog = ''
            if ($backend -eq 'anime4kcpp') {
                & $entryScript -Engine anime4kcpp -InputPath $lrPath -OutputPath $OutFilePath -Scale 2 -AcProcessor $AcProcessor -ExistingOutput overwrite | Out-Null
                $latest = Get-ChildItem -LiteralPath $logDir -Filter 'acnet-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latest) { $usedLog = $latest.FullName }
            } elseif ($backend -eq 'ncnn') {
                & $entryScript -Engine ncnn -InputPath $lrPath -OutputPath $OutFilePath -Scale ([string]$Scale) | Out-Null
                $latest = Get-ChildItem -LiteralPath $logDir -Filter 'ncnn-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latest) { $usedLog = $latest.FullName }
            } elseif ($backend -eq 'realcugan') {
                if ($hasRealCuganScript) {
                    & (Join-Path $root 'RealCUGAN.ps1') -InputPath $lrPath -OutputPath $OutFilePath -Model 'models-se' -Scale ([string]$Scale) -NoiseLevel -1 | Out-Null
                    $latest = Get-ChildItem -LiteralPath $logDir -Filter 'realcugan-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($latest) { $usedLog = $latest.FullName }
                } else {
                    $usedLog = Invoke-IUKStandaloneRealCugan -ExePath (Join-Path $root 'bin\realcugan\realcugan-ncnn-vulkan.exe') -InputFile $lrPath -OutputFile $OutFilePath -ScaleRatio $Scale -WorkDir $workStage -LogDir $logDir
                }
            } elseif ($backend -eq 'magpie') {
                & $entryScript -Engine magpie -InputPath $lrPath -OutputPath $OutFilePath | Out-Null
            } else {
                $r = Invoke-IUKComfyUIWorkflow -InputPath $lrPath -OutputPath $OutFilePath -ApiUrl $ComfyEndpoint -PresetName $comfyPresetId -Root $root
                if ($r -and $r[0]) { $usedLog = [string]$r[0].LogFile }
            }
            return $usedLog
        }

        # Explicit Cold-Start run on item 0
        $coldOut = Join-Path $workStage "${backend}_cold.png"
        $coldMs = 0.0
        $coldSw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $null = & $runSingleItem $items[0] $coldOut
            $coldSw.Stop()
            $coldMs = [math]::Round($coldSw.Elapsed.TotalMilliseconds, 1)
        } catch {
            $coldSw.Stop()
            $coldMs = [math]::Round($coldSw.Elapsed.TotalMilliseconds, 1)
        } finally {
            Remove-Item -LiteralPath $coldOut -Force -ErrorAction SilentlyContinue
        }

        $warmTimes = [System.Collections.Generic.List[double]]::new()
        $psnrYs = [System.Collections.Generic.List[double]]::new()
        $psnrRgbs = [System.Collections.Generic.List[double]]::new()
        $ssimYs = [System.Collections.Generic.List[double]]::new()

        foreach ($it in $items) {
            $lrPath = if ($Scale -eq 4) { [string]$it.lr_x4_path } else { [string]$it.lr_x2_path }
            $inRes = Get-IUKImageSize $lrPath
            $destOut = Join-Path $backendOutDir $it.file
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                $itemLog = & $runSingleItem $it $destOut
                $sw.Stop()
                $elapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                $outRes = Get-IUKImageSize $destOut
                $m = [ImageUpscaleKit.Metrics.ImageMetricsCalculator]::CompareFiles([string]$it.hr_path, $destOut)

                $pyVal = if ([double]::IsInfinity($m.PsnrY)) { 99.99 } else { [math]::Round($m.PsnrY, 3) }
                $prVal = if ([double]::IsInfinity($m.PsnrRgb)) { 99.99 } else { [math]::Round($m.PsnrRgb, 3) }
                $ssVal = [math]::Round($m.SsimY, 4)

                [void]$warmTimes.Add($elapsedMs)
                [void]$psnrYs.Add($pyVal)
                [void]$psnrRgbs.Add($prVal)
                [void]$ssimYs.Add($ssVal)

                [void]$records.Add([pscustomobject]@{
                    Backend = $backend; Model = $modelLabel; WorkflowVersion = $workflowVersion; Device = $deviceLabel
                    Category = [string]$it.category; ImageFile = [string]$it.file
                    InputResolution = $inRes; OutputResolution = $outRes
                    ColdStartMs = $coldMs; ElapsedMs = $elapsedMs; VramPeakMb = $vramPeak
                    AlignmentPolicy = $m.AlignmentPolicy; ExactSizeMatch = $m.ExactSizeMatch
                    PsnrY = $pyVal; PsnrRgb = $prVal; SsimY = $ssVal
                    Lpips = $(if ($lpipsAvailable) { 'enabled_pending' } else { 'N/A' })
                    Status = 'Success'; Error = ''; LogFile = $itemLog
                })

                [void]$comparisonMap[$it.file].results.Add([pscustomobject]@{
                    backend = $backend
                    label = "$backend ($modelLabel)"
                    model = $modelLabel
                    file_path = $destOut
                    elapsed_ms = $elapsedMs
                    psnr_y = $pyVal
                    ssim_y = $ssVal
                })
            } catch {
                $sw.Stop()
                $errMsg = $_.Exception.Message
                [void]$records.Add([pscustomobject]@{
                    Backend = $backend; Model = $modelLabel; WorkflowVersion = $workflowVersion; Device = $deviceLabel
                    Category = [string]$it.category; ImageFile = [string]$it.file
                    InputResolution = $inRes; OutputResolution = ''
                    ColdStartMs = $coldMs; ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); VramPeakMb = $vramPeak
                    AlignmentPolicy = ''; ExactSizeMatch = ''
                    PsnrY = ''; PsnrRgb = ''; SsimY = ''; Lpips = 'N/A'
                    Status = 'Failed'; Error = $errMsg; LogFile = ''
                })
            }
        }

        if ($warmTimes.Count -gt 0) {
            [void]$backendSummaries.Add([pscustomobject]@{
                Backend = $backend; Model = $modelLabel; Status = "Success ($($warmTimes.Count)/$($items.Count))"
                SkipReason = ''; Device = $deviceLabel
                ColdStartMs = $coldMs
                WarmAvgMs = [math]::Round(($warmTimes | Measure-Object -Average).Average, 1)
                AvgPsnrY = [math]::Round(($psnrYs | Measure-Object -Average).Average, 3)
                AvgPsnrRgb = [math]::Round(($psnrRgbs | Measure-Object -Average).Average, 3)
                AvgSsimY = [math]::Round(($ssimYs | Measure-Object -Average).Average, 4)
            })
        } else {
            [void]$backendSummaries.Add([pscustomobject]@{
                Backend = $backend; Model = $modelLabel; Status = 'Failed'; SkipReason = '全部测试图均执行失败'
                Device = $deviceLabel; ColdStartMs = $coldMs; WarmAvgMs = 'N/A'
                AvgPsnrY = 'N/A'; AvgPsnrRgb = 'N/A'; AvgSsimY = 'N/A'
            })
        }
    }
} finally {
    Remove-Item -LiteralPath $workStage -Recurse -Force -ErrorAction SilentlyContinue
}

# Export CSV
$csvPath = Join-Path $OutputDir 'benchmark_results.csv'
$records | Export-Csv -LiteralPath $csvPath -Encoding utf8BOM

# Export comparison_manifest.json for ImageComparator.ps1
$compManifestPath = Join-Path $OutputDir 'comparison_manifest.json'
([pscustomobject]@{
    generated_at = (Get-Date).ToString('o')
    scale = $Scale
    gpu = $gpuSummary
    items = @($comparisonMap.Values)
}) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $compManifestPath -Encoding utf8NoBOM

# Export Markdown Report
$mdPath = Join-Path $OutputDir 'benchmark_report.md'
$md = [System.Collections.Generic.List[string]]::new()
[void]$md.Add("# ImageUpscaleKit 超分性能与画质基准评测报告")
[void]$md.Add("")
[void]$md.Add("- **评测时间**：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$md.Add("- **目标倍率**：${Scale}x")
[void]$md.Add("- **本机 GPU**：$gpuSummary")
[void]$md.Add('- **色彩空间与对齐策略**：`sRGB_BT601_Y`；尺寸精确匹配时直接计算，否则先 `HighQualityBicubic` 对齐至参考原图 (`bicubic_aligned_to_hr`)。')
[void]$md.Add("")
[void]$md.Add("## 一、后端总览（冷启动与连续推理分离）")
[void]$md.Add("")
[void]$md.Add("| 后端 | 模型/预设 | 状态 | 冷启动 (ms) | 连续均值 (ms) | 平均 PSNR_Y (dB) | 平均 PSNR_RGB (dB) | 平均 SSIM_Y | 设备 / 跳过原因 |")
[void]$md.Add("|---|---|---|---:|---:|---:|---:|---:|---|")
foreach ($s in $backendSummaries) {
    $note = if ($s.SkipReason) { $s.SkipReason } else { $s.Device }
    [void]$md.Add("| $($s.Backend) | $($s.Model) | $($s.Status) | $($s.ColdStartMs) | $($s.WarmAvgMs) | $($s.AvgPsnrY) | $($s.AvgPsnrRgb) | $($s.AvgSsimY) | $note |")
}
[void]$md.Add("")
[void]$md.Add("## 二、各类别画质与耗时明细")
[void]$md.Add("")
[void]$md.Add("| 类别 | 图片 | 后端 | 输入->输出 | 耗时 (ms) | PSNR_Y | SSIM_Y | 对齐策略 | 状态 |")
[void]$md.Add("|---|---|---|---|---:|---:|---:|---|---|")
foreach ($r in ($records | Where-Object { $_.Status -ne 'Skipped' })) {
    [void]$md.Add("| $($r.Category) | $($r.ImageFile) | $($r.Backend) | $($r.InputResolution)->$($r.OutputResolution) | $($r.ElapsedMs) | $($r.PsnrY) | $($r.SsimY) | $($r.AlignmentPolicy) | $($r.Status) |")
}
[void]$md.Add("")
[void]$md.Add("> **评测提示**：PSNR / SSIM 仅反映像素级保真，对于具备重绘生成能力的方案（如 Ultimate SD Upscale、SUPIR），请使用 `ImageComparator.ps1 -ManifestPath `"$compManifestPath`"` 结合局部放大（ROI）与人工五官/纹理检查共同评估。")
$md | Set-Content -LiteralPath $mdPath -Encoding utf8NoBOM

Write-Host "Benchmark finished. Report: $mdPath" -ForegroundColor Green
return [pscustomobject]@{
    OutputDir = $OutputDir
    CsvPath = $csvPath
    ReportPath = $mdPath
    ComparisonManifestPath = $compManifestPath
    BackendSummaries = @($backendSummaries)
    Records = @($records)
}
