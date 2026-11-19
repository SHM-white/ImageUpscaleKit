$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\BatchQueue.ps1')

Initialize-IUKAsyncRunnerTypes

function Assert($Cond, [string]$Msg) {
    if (-not $Cond) { throw "Assertion failed: $Msg" }
}

$work = Join-Path $root ('temp/gui-test-' + [guid]::NewGuid().ToString('N'))
$dir = Join-Path $work '中文 队列目录'
$subDir = Join-Path $dir '子目录 不应递归'
New-Item -ItemType Directory -Force -Path $dir, $subDir | Out-Null

$cfgPath = Join-Path $root 'config.json'
$origCfgBytes = [IO.File]::ReadAllBytes($cfgPath)

try {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms

    $img1 = Join-Path $dir '图 一.png'
    $img2 = Join-Path $dir '图 二.jpg'
    $txt1 = Join-Path $dir '说明.txt'
    $subImg = Join-Path $subDir 'nested.png'
    $resA = Join-Path $work '结果 A x2.png'
    $resB = Join-Path $work '结果 B x4.png'

    foreach ($p in @($img1, $img2, $subImg, $resA, $resB)) {
        $w = if ($p -eq $resA) { 48 } elseif ($p -eq $resB) { 96 } else { 24 }
        $h = if ($p -eq $resA) { 32 } elseif ($p -eq $resB) { 64 } else { 16 }
        $b = [System.Drawing.Bitmap]::new($w, $h)
        try {
            if ($p -like '*.jpg') { $b.Save($p, [System.Drawing.Imaging.ImageFormat]::Jpeg) }
            else { $b.Save($p, [System.Drawing.Imaging.ImageFormat]::Png) }
        } finally { $b.Dispose() }
    }
    'ignore me' | Set-Content -LiteralPath $txt1 -Encoding utf8

    # 1. Expand-IUKDroppedPaths (first-level only, deduplicated, Chinese/space safe)
    $expanded = @(Expand-IUKDroppedPaths @($dir, $img1, $txt1))
    Assert ($expanded.Count -eq 2) "Expected 2 unique top-level images, got $($expanded.Count): $($expanded -join ',')"
    Assert ($expanded -contains $img1 -and $expanded -contains $img2) 'Missing expected Chinese-named images'

    # 2. Output resolution & argument builder across engines
    $used = @{}
    $qItem = New-IUKQueueItem -InputPath $img1 -Engine 'anime4kcpp'
    $qItem.OutputPath = Resolve-IUKItemOutputPath -InputPath $img1 -OutputDir $work -Engine 'anime4kcpp' -ExistingPolicy 'rename' -UsedPaths $used
    Assert ($qItem.OutputPath -like '*_acnet_x2.png') "Unexpected anime4kcpp output path: $($qItem.OutputPath)"

    $acArgs = Build-IUKUpscaleArguments -UpscaleScriptPath (Join-Path $root 'Upscale.ps1') -Item $qItem -Options @{
        Engine = 'anime4kcpp'; AcModel = 'acnet-legacy-gan'; AcProcessor = 'cpu'; AcDevice = 0; AcBatchSize = 8; ExistingOutput = 'rename'
    }
    Assert (($acArgs -join ' ') -match '-Engine anime4kcpp.*-AcProcessor cpu') "Invalid anime4kcpp args: $($acArgs -join ' ')"

    $ncnnArgs = Build-IUKUpscaleArguments -UpscaleScriptPath (Join-Path $root 'Upscale.ps1') -Item $qItem -Options @{
        Engine = 'ncnn'; NcnnModel = 'realesrgan-x4plus-anime'; NcnnScale = '4'; NcnnTile = 0; NcnnGpu = 'auto'; NcnnThreads = '1:2:2'; NcnnTta = $true
    }
    Assert (($ncnnArgs -join ' ') -match '-Engine ncnn.*-Tta') "Invalid ncnn args: $($ncnnArgs -join ' ')"

    $magArgs = Build-IUKUpscaleArguments -UpscaleScriptPath (Join-Path $root 'Upscale.ps1') -Item $qItem -Options @{
        Engine = 'magpie'; MagpieSelectionType = 'family'; MagpieFamily = 'ACNet'; MagpieTier = 'Default'
    }
    Assert (($magArgs -join ' ') -match '-Engine magpie.*-MagpieFamily ACNet') "Invalid magpie args: $($magArgs -join ' ')"

    # 3. IukAsyncProcessRunner output & KillTree verification
    $runner = [ImageUpscaleKit.Execution.IukAsyncProcessRunner]::new(
        'pwsh.exe',
        @('-NoProfile', '-Command', '[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output "测试 输出 中文"; exit 0'),
        $root
    )
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not $runner.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 30 }
        Assert $runner.HasExited 'Runner did not exit in time'
        Assert ($runner.ExitCode -eq 0) "Unexpected exit code: $($runner.ExitCode)"
        $outLines = @($runner.DrainOutput()) -join "`n"
        Assert ($outLines -match '测试 输出 中文') "Runner missed UTF-8 Chinese output: $outLines"
    } finally { $runner.Dispose() }

    $longRunner = [ImageUpscaleKit.Execution.IukAsyncProcessRunner]::new(
        'pwsh.exe',
        @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30'),
        $root
    )
    try {
        Start-Sleep -Milliseconds 150
        $longRunner.KillTree()
        Assert $longRunner.WasKilled 'Expected WasKilled = true'
        Assert $longRunner.HasExited 'Expected killed process to exit'
    } finally { $longRunner.Dispose() }

    # 4. Headless GUI.ps1 -TestMode verification
    $win = & (Join-Path $root 'GUI.ps1') -TestMode
    try {
        $form = $win.Form
        Assert ($form.FormBorderStyle -eq [System.Windows.Forms.FormBorderStyle]::Sizable) 'Form must be Sizable'
        Assert $form.MaximizeBox 'Form MaximizeBox must be enabled'
        $form.ShowInTaskbar = $false
        $form.Opacity = 0
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()

        # Resize test: 1080x680 -> 1920x1080
        $form.Size = [System.Drawing.Size]::new(1080, 680)
        $form.PerformLayout()
        [System.Windows.Forms.Application]::DoEvents()
        Assert ($win.Controls.Comparator.Control.Width -gt 200 -and $win.Controls.Comparator.Control.Height -gt 200) 'Comparator too small at 1080x680'
        $form.Size = [System.Drawing.Size]::new(1920, 1080)
        $form.PerformLayout()
        [System.Windows.Forms.Application]::DoEvents()
        Assert ($win.Controls.Comparator.Control.Width -gt 1000 -and $win.Controls.Comparator.Control.Height -gt 650) 'Comparator did not expand at 1920x1080'

        # Advanced panel collapsed by default and toggles open
        Assert (-not $win.Controls.AdvancedGroup.Visible) 'Advanced panel should start collapsed'
        $win.Controls.AdvancedButton.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        Assert $win.State.AdvancedExpanded 'AdvancedExpanded state should be true after click'
        Assert $win.Controls.AdvancedGroup.Visible 'Advanced panel should expand on click'

        # Enqueue Chinese paths & check Comparator loads Original
        $added = & $win.Actions.EnqueuePaths @($dir)
        Assert ($added -eq 2) "Expected 2 enqueued items, got $added"
        Assert ($win.Controls.QueueList.Items.Count -eq 2) 'Queue ListView item count mismatch'
        Assert ($win.Controls.Comparator.Control.OriginalImage.OriginalWidth -eq 24) 'Comparator did not load first queued original'

        # Multi-result accumulation on same input item
        $firstItem = $win.State.Queue[0]
        $firstItem.Status = '已完成'
        [void]$firstItem.Results.Add([ImageUpscaleKit.UI.ComparatorResultItem]@{ Id = 'a'; Label = 'ACNet x2'; Engine = 'anime4kcpp'; FilePath = $resA })
        [void]$firstItem.Results.Add([ImageUpscaleKit.UI.ComparatorResultItem]@{ Id = 'b'; Label = 'RealESRGAN x4'; Engine = 'ncnn'; FilePath = $resB })
        & $win.Actions.LoadItemToComparator $firstItem
        Assert ($win.Controls.Comparator.Control.ResultCount -eq 2) 'Expected 2 results bound to comparator'
        Assert ($win.Controls.Comparator.ResultSelector.Items.Count -eq 2) 'ResultSelector dropdown mismatch'

        # Cancel pending leaves completed items untouched
        & $win.Actions.CancelPending
        Assert ($win.State.Queue[0].Status -eq '已完成') 'Completed item status changed by CancelPending'
        Assert ($win.State.Queue[1].Status -eq '已取消') 'Pending item was not marked Cancelled'

        # Preset application switches engine & model cleanly
        $win.Controls.PresetCombo.SelectedIndex = 2 # Real-ESRGAN Anime
        & $win.Actions.ApplyPreset
        Assert ($win.Controls.EngineCombo.Text -eq 'ncnn') "Preset did not switch engine to ncnn: $($win.Controls.EngineCombo.Text)"

        # Config save preserves backward compatibility
        $savedOk = & $win.Actions.SaveConfig
        Assert $savedOk 'SaveConfig returned false'
        $reloaded = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($null -ne $reloaded.anime4kcpp -and $null -ne $reloaded.ncnn -and $null -ne $reloaded.magpie -and $null -ne $reloaded.ui) 'Saved config missing expected sections'
    } finally {
        $win.Form.Dispose()
    }

    Write-Host 'PASS: BatchQueue expansion/args, AsyncProcessRunner UTF-8/KillTree, 5-zone GUI resize/drop/multi-result/cancel/presets/config compat.'
}
finally {
    [IO.File]::WriteAllBytes($cfgPath, $origCfgBytes)
    $resolved = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'gui-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
