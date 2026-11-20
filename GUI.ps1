param(
    [switch]$TestMode
)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$guiModule = New-Module -ArgumentList @($Root) -ScriptBlock {
    param($Root)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $ConfigPath = Join-Path $Root 'config.json'

    . (Join-Path $Root 'MagpieHelpers.ps1')
    . (Join-Path $Root 'ImageComparator.ps1')
    . (Join-Path $Root 'src\BatchQueue.ps1')

    Initialize-IUKComparatorTypes
    Initialize-IUKAsyncRunnerTypes

    $Script:IUKHasComfy = Test-Path -LiteralPath (Join-Path $Root 'ComfyUI.ps1') -PathType Leaf
    $Script:IUKHasRealCugan = Test-Path -LiteralPath (Join-Path $Root 'RealCUGAN.ps1') -PathType Leaf
    $Script:IUKHasModelManager = (Test-Path -LiteralPath (Join-Path $Root 'ModelManager.ps1') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $Root 'gui\ModelManagerDialog.ps1') -PathType Leaf)

function Resolve-IUKPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Load-IUKGuiConfig {
    $loaded = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $loaded.anime4kcpp) {
        $loaded | Add-Member -NotePropertyName anime4kcpp -NotePropertyValue ([pscustomobject]@{
            backend_path = 'bin\anime4kcpp\ac_cli.exe'
            model = 'acnet-legacy-gan'
            processor = 'auto'
            device = 0
        })
    }
    if (-not $loaded.anime4kcpp.PSObject.Properties['existing_output']) {
        $loaded.anime4kcpp | Add-Member -NotePropertyName existing_output -NotePropertyValue 'rename'
    }
    if (-not $loaded.anime4kcpp.PSObject.Properties['batch_size']) {
        $loaded.anime4kcpp | Add-Member -NotePropertyName batch_size -NotePropertyValue 16
    }
    if (-not $loaded.PSObject.Properties['ui']) {
        $loaded | Add-Member -NotePropertyName ui -NotePropertyValue ([pscustomobject]@{
            window_width = 1380
            window_height = 840
            fail_policy = 'continue'
            auto_output = $true
            output_dir = ''
        })
    } else {
        if (-not $loaded.ui.PSObject.Properties['window_width']) { $loaded.ui | Add-Member window_width 1380 }
        if (-not $loaded.ui.PSObject.Properties['window_height']) { $loaded.ui | Add-Member window_height 840 }
        if (-not $loaded.ui.PSObject.Properties['fail_policy']) { $loaded.ui | Add-Member fail_policy 'continue' }
        if (-not $loaded.ui.PSObject.Properties['auto_output']) { $loaded.ui | Add-Member auto_output $true }
        if (-not $loaded.ui.PSObject.Properties['output_dir']) { $loaded.ui | Add-Member output_dir '' }
    }
    return $loaded
}

function Save-IUKGuiConfig($Cfg) {
    $Cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ConfigPath -Encoding utf8NoBOM
}

function Get-IUKNcnnModels([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $Dir -Filter '*.param' -File |
        Where-Object { Test-Path -LiteralPath (Join-Path $Dir ($_.BaseName + '.bin')) } |
        ForEach-Object BaseName | Sort-Object -Unique)
}

function Select-IUKImagesDialog([System.Windows.Forms.IWin32Window]$Owner, [string]$Initial = '') {
    $d = [System.Windows.Forms.OpenFileDialog]::new()
    $d.Filter = 'Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp|All files|*.*'
    $d.Multiselect = $true
    if ($Initial -and (Test-Path -LiteralPath $Initial)) {
        $d.InitialDirectory = if (Test-Path -LiteralPath $Initial -PathType Container) { $Initial } else { Split-Path -Parent $Initial }
    }
    try {
        if ($d.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) { return @($d.FileNames) }
    } finally { $d.Dispose() }
    return @()
}

function Select-IUKFolderDialog([System.Windows.Forms.IWin32Window]$Owner, [string]$Initial = '') {
    $d = [System.Windows.Forms.FolderBrowserDialog]::new()
    $d.ShowNewFolderButton = $true
    if ($Initial -and (Test-Path -LiteralPath $Initial -PathType Container)) {
        $d.SelectedPath = [IO.Path]::GetFullPath($Initial)
    }
    try {
        if ($d.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    } finally { $d.Dispose() }
    return $null
}

function Get-IUKQuickPresets([string]$KitRoot) {
    $presets = [System.Collections.Generic.List[pscustomobject]]::new()
    [void]$presets.Add([pscustomobject]@{ Label = '动漫 2x 快速 (ACNet GAN)'; Engine = 'anime4kcpp'; Model = 'acnet-legacy-gan'; Scale = '2' })
    [void]$presets.Add([pscustomobject]@{ Label = '动漫 2x 降噪 (ACNet HDN1)'; Engine = 'anime4kcpp'; Model = 'acnet-legacy-hdn1'; Scale = '2' })
    [void]$presets.Add([pscustomobject]@{ Label = '动漫 4x 锐利 (Real-ESRGAN Anime)'; Engine = 'ncnn'; Model = 'realesrgan-x4plus-anime'; Scale = '4' })
    [void]$presets.Add([pscustomobject]@{ Label = '通用 4x 超分 (Real-ESRGAN)'; Engine = 'ncnn'; Model = 'realesrgan-x4plus'; Scale = '4' })
    if ($Script:IUKHasRealCugan) {
        [void]$presets.Add([pscustomobject]@{ Label = 'Real-CUGAN 动漫 2x'; Engine = 'realcugan'; Model = 'models-se'; Scale = '2'; NoiseLevel = '-1' })
        [void]$presets.Add([pscustomobject]@{ Label = 'Real-CUGAN 动漫 4x'; Engine = 'realcugan'; Model = 'models-se'; Scale = '4'; NoiseLevel = '-1' })
    }
    [void]$presets.Add([pscustomobject]@{ Label = 'MagpieFX ACNet HLSL'; Engine = 'magpie'; SelectionType = 'family'; Family = 'ACNet'; Tier = 'Default' })
    [void]$presets.Add([pscustomobject]@{ Label = 'MagpieFX Lanczos x2'; Engine = 'magpie'; SelectionType = 'mode'; Mode = 'Lanczos'; Tier = '2x' })
    [void]$presets.Add([pscustomobject]@{ Label = 'MagpieFX ArtCNN 动漫 2x'; Engine = 'magpie'; SelectionType = 'mode'; Mode = 'ArtCNN'; Scale = '2' })
    [void]$presets.Add([pscustomobject]@{ Label = 'MagpieFX Anime4K 动漫 2x'; Engine = 'magpie'; SelectionType = 'family'; Family = 'Anime4K\Anime4K_Upscale'; Tier = 'VL'; Scale = '2' })

    $comfyPresetsDir = Join-Path $KitRoot 'workflows\presets'
    if ($Script:IUKHasComfy -and (Test-Path -LiteralPath $comfyPresetsDir -PathType Container)) {
        foreach ($pf in Get-ChildItem -LiteralPath $comfyPresetsDir -Filter '*.json' -File | Sort-Object Name) {
            try {
                $pObj = Get-Content -LiteralPath $pf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                [void]$presets.Add([pscustomobject]@{
                    Label = "ComfyUI: $($pObj.name ?? $pf.BaseName)"
                    Engine = 'comfyui'
                    ComfyPreset = $pf.BaseName
                })
            } catch {}
        }
    }
    return @($presets)
}

    $cfg = Load-IUKGuiConfig

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'ImageUpscaleKit - 本地多引擎超分辨率与画质对比工具'
    $initW = [Math]::Max(1080, [int]$cfg.ui.window_width)
    $initH = [Math]::Max(680, [int]$cfg.ui.window_height)
    $form.Size = [System.Drawing.Size]::new($initW, $initH)
    $form.MinimumSize = [System.Drawing.Size]::new(1080, 680)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.MaximizeBox = $true
    $form.AllowDrop = $true

    $state = @{
        Config = $cfg
        Queue = [System.Collections.Generic.List[object]]::new()
        IsRunning = $false
        CurrentRunner = $null
        CurrentItem = $null
        CurrentRunLog = [System.Collections.Generic.List[string]]::new()
        StopRequested = $false
        AdvancedExpanded = $false
        PluginPanels = @{}
        Presets = @(Get-IUKQuickPresets $Root)
        Syncing = $false
        UsedOutputPaths = @{}
        LastResultPath = ''
        LastOutputDir = ''
    }

    # --- Top Bar ---
    $topBar = [System.Windows.Forms.FlowLayoutPanel]::new()
    $topBar.Dock = [System.Windows.Forms.DockStyle]::Top
    $topBar.Height = 46
    $topBar.AutoSize = $true
    $topBar.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $topBar.WrapContents = $true
    $topBar.Padding = [System.Windows.Forms.Padding]::new(8, 6, 8, 6)
    $topBar.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    function New-TopBtn([string]$Text, [int]$W = 86) {
        $b = [System.Windows.Forms.Button]::new()
        $b.Text = $Text
        $b.Size = [System.Drawing.Size]::new($W, 30)
        $b.Margin = [System.Windows.Forms.Padding]::new(2, 2, 4, 2)
        return $b
    }

    $btnImportFiles = New-TopBtn '导入图片' 84
    $btnImportDir = New-TopBtn '导入文件夹' 92
    $btnClearQueue = New-TopBtn '清空列表' 80

    $lblEngine = [System.Windows.Forms.Label]::new()
    $lblEngine.Text = '处理引擎:'
    $lblEngine.AutoSize = $true
    $lblEngine.Margin = [System.Windows.Forms.Padding]::new(10, 8, 3, 2)

    $cmbEngine = [System.Windows.Forms.ComboBox]::new()
    $cmbEngine.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbEngine.Width = 128
    $cmbEngine.Margin = [System.Windows.Forms.Padding]::new(2, 5, 8, 2)
    $engines = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @('anime4kcpp', 'ncnn', 'magpie')) { [void]$engines.Add($e) }
    if ($Script:IUKHasRealCugan) { [void]$engines.Add('realcugan') }
    if ($Script:IUKHasComfy) { [void]$engines.Add('comfyui') }
    $cmbEngine.Items.AddRange($engines.ToArray())
    if ($cmbEngine.Items.Contains([string]$cfg.engine)) { $cmbEngine.SelectedItem = [string]$cfg.engine }
    else { $cmbEngine.SelectedIndex = 0 }

    $lblPreset = [System.Windows.Forms.Label]::new()
    $lblPreset.Text = '快捷方案:'
    $lblPreset.AutoSize = $true
    $lblPreset.Margin = [System.Windows.Forms.Padding]::new(4, 8, 3, 2)

    $cmbPreset = [System.Windows.Forms.ComboBox]::new()
    $cmbPreset.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbPreset.Width = 235
    $cmbPreset.Margin = [System.Windows.Forms.Padding]::new(2, 5, 8, 2)
    foreach ($p in $state.Presets) { [void]$cmbPreset.Items.Add($p.Label) }
    if ($cmbPreset.Items.Count -gt 0) { $cmbPreset.SelectedIndex = 0 }

    $btnApplyPreset = New-TopBtn '应用方案' 78
    $btnStart = New-TopBtn '开始处理' 106
    $btnStart.BackColor = [System.Drawing.Color]::FromArgb(30, 120, 215)
    $btnStart.ForeColor = [System.Drawing.Color]::White
    $btnStart.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnStart.Font = [System.Drawing.Font]::new('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

    $btnSetup = New-TopBtn '安装/修复后端' 110
    $btnModelMgr = New-TopBtn '权重/模型管理' 112
    $btnModelMgr.Visible = $Script:IUKHasModelManager

    $topBar.Controls.AddRange(@(
        $btnImportFiles, $btnImportDir, $btnClearQueue,
        $lblEngine, $cmbEngine,
        $lblPreset, $cmbPreset, $btnApplyPreset,
        $btnStart, $btnSetup, $btnModelMgr
    ))

    # --- Bottom Bar (TableLayoutPanel prevents off-screen overflow at any window width/DPI) ---
    $bottomBar = [System.Windows.Forms.Panel]::new()
    $bottomBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottomBar.Height = 90
    $bottomBar.Padding = [System.Windows.Forms.Padding]::new(10, 4, 10, 4)
    $bottomBar.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    $bottomGrid = [System.Windows.Forms.TableLayoutPanel]::new()
    $bottomGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bottomGrid.ColumnCount = 2
    $bottomGrid.RowCount = 2
    [void]$bottomGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 46))
    [void]$bottomGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 54))
    [void]$bottomGrid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 26))
    [void]$bottomGrid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $progress = [System.Windows.Forms.ProgressBar]::new()
    $progress.Dock = [System.Windows.Forms.DockStyle]::Fill
    $progress.Margin = [System.Windows.Forms.Padding]::new(0, 3, 10, 3)

    $lblSummary = [System.Windows.Forms.Label]::new()
    $lblSummary.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lblSummary.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $lblSummary.AutoEllipsis = $true
    $lblSummary.Text = '已完成: 0 | 失败: 0 | 待处理: 0 | 就绪'

    $lblBackendStatus = [System.Windows.Forms.Label]::new()
    $lblBackendStatus.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lblBackendStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblBackendStatus.AutoEllipsis = $true
    $lblBackendStatus.Margin = [System.Windows.Forms.Padding]::new(0, 2, 10, 0)

    $bottomBtnPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
    $bottomBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bottomBtnPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $bottomBtnPanel.WrapContents = $false
    $bottomBtnPanel.Padding = [System.Windows.Forms.Padding]::new(0, 8, 0, 0)

    function New-BottomBtn([string]$Text, [int]$W = 94) {
        $b = [System.Windows.Forms.Button]::new()
        $b.Text = $Text
        $b.Size = [System.Drawing.Size]::new($W, 30)
        $b.Margin = [System.Windows.Forms.Padding]::new(4, 2, 0, 2)
        return $b
    }

    $btnOpenLogs = New-BottomBtn '打开日志' 86
    $btnOpenOutDir = New-BottomBtn '打开输出目录' 106
    $btnOpenResult = New-BottomBtn '打开结果图' 96
    $btnAbort = New-BottomBtn '中止当前' 86
    $btnCancelPending = New-BottomBtn '取消待处理' 96
    $btnAbort.Enabled = $false
    $btnCancelPending.Enabled = $false

    $bottomBtnPanel.Controls.AddRange(@($btnOpenLogs, $btnOpenOutDir, $btnOpenResult, $btnAbort, $btnCancelPending))
    $bottomGrid.Controls.Add($progress, 0, 0)
    $bottomGrid.Controls.Add($lblSummary, 1, 0)
    $bottomGrid.Controls.Add($lblBackendStatus, 0, 1)
    $bottomGrid.Controls.Add($bottomBtnPanel, 1, 1)
    $bottomBar.Controls.Add($bottomGrid)

    # --- Main Split Containers (Left Queue | Center Comparator | Right Config) ---
    $outerSplit = [System.Windows.Forms.SplitContainer]::new()
    $outerSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
    $outerSplit.Orientation = [System.Windows.Forms.Orientation]::Vertical
    $outerSplit.Size = [System.Drawing.Size]::new($initW - 20, $initH - 166)
    $outerSplit.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel1
    $outerSplit.Panel1MinSize = 220
    $outerSplit.Panel2MinSize = 660
    $outerSplit.SplitterDistance = 280

    $innerSplit = [System.Windows.Forms.SplitContainer]::new()
    $innerSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
    $innerSplit.Orientation = [System.Windows.Forms.Orientation]::Vertical
    $innerSplit.Size = [System.Drawing.Size]::new($initW - 305, $initH - 166)
    $innerSplit.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel2
    $innerSplit.Panel1MinSize = 320
    $innerSplit.Panel2MinSize = 350
    $innerSplit.SplitterDistance = [Math]::Max(320, ($initW - 305) - 368)

    $outerSplit.Panel2.Controls.Add($innerSplit)

    # --- Left Pane: Queue + Status/Error Details ---
    $leftToolbar = [System.Windows.Forms.FlowLayoutPanel]::new()
    $leftToolbar.Dock = [System.Windows.Forms.DockStyle]::Top
    $leftToolbar.Height = 65
    $leftToolbar.Padding = [System.Windows.Forms.Padding]::new(4, 3, 4, 2)

    $btnRemoveSel = [System.Windows.Forms.Button]::new(); $btnRemoveSel.Text = '移除选中'; $btnRemoveSel.Size = [System.Drawing.Size]::new(76, 24)
    $btnClearDone = [System.Windows.Forms.Button]::new(); $btnClearDone.Text = '清已完成'; $btnClearDone.Size = [System.Drawing.Size]::new(76, 24)
    $btnRetryFail = [System.Windows.Forms.Button]::new(); $btnRetryFail.Text = '重试失败'; $btnRetryFail.Size = [System.Drawing.Size]::new(76, 24)
    $btnRequeueAll = [System.Windows.Forms.Button]::new(); $btnRequeueAll.Text = '全部重新排队'; $btnRequeueAll.Size = [System.Drawing.Size]::new(110, 24)
    $leftToolbar.Controls.AddRange(@($btnRemoveSel, $btnClearDone, $btnRetryFail, $btnRequeueAll))
    $leftToolbar.SetFlowBreak($btnClearDone, $true)

    $queueList = [System.Windows.Forms.ListView]::new()
    $queueList.Dock = [System.Windows.Forms.DockStyle]::Fill
    $queueList.View = [System.Windows.Forms.View]::Details
    $queueList.FullRowSelect = $true
    $queueList.MultiSelect = $true
    $queueList.GridLines = $true
    $queueList.HideSelection = $false
    $queueList.AllowDrop = $true
    [void]$queueList.Columns.Add('文件', 124)
    [void]$queueList.Columns.Add('状态', 62)
    [void]$queueList.Columns.Add('耗时', 50)
    [void]$queueList.Columns.Add('结果', 36)

    $errPanel = [System.Windows.Forms.Panel]::new()
    $errPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $errPanel.Height = 136
    $errPanel.Padding = [System.Windows.Forms.Padding]::new(4, 3, 4, 3)
    $errPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    $errHeader = [System.Windows.Forms.Panel]::new()
    $errHeader.Dock = [System.Windows.Forms.DockStyle]::Top
    $errHeader.Height = 24

    $lblErrTitle = [System.Windows.Forms.Label]::new()
    $lblErrTitle.Text = '运行状态 / 错误详情'
    $lblErrTitle.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lblErrTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblErrTitle.Font = [System.Drawing.Font]::new('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $lblErrTitle.ForeColor = [System.Drawing.Color]::FromArgb(40, 48, 60)

    $btnCopyErr = [System.Windows.Forms.Button]::new()
    $btnCopyErr.Text = '复制'
    $btnCopyErr.Dock = [System.Windows.Forms.DockStyle]::Right
    $btnCopyErr.Width = 48

    $txtErrLog = [System.Windows.Forms.TextBox]::new()
    $txtErrLog.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtErrLog.Multiline = $true
    $txtErrLog.ReadOnly = $true
    $txtErrLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtErrLog.WordWrap = $true
    $txtErrLog.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 254)
    $txtErrLog.ForeColor = [System.Drawing.Color]::FromArgb(30, 36, 44)
    $txtErrLog.Text = '就绪：队列执行日志与失败原因将显示在此处。'

    $errHeader.Controls.Add($lblErrTitle)
    $errHeader.Controls.Add($btnCopyErr)
    $errPanel.Controls.Add($txtErrLog)
    $errPanel.Controls.Add($errHeader)

    $lblDropHint = [System.Windows.Forms.Label]::new()
    $lblDropHint.Text = '拖入图片/文件夹，或点击顶部「导入图片」'
    $lblDropHint.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $lblDropHint.Height = 32
    $lblDropHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblDropHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblDropHint.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 252)

    $queueCtx = [System.Windows.Forms.ContextMenuStrip]::new()
    $miOpenSrcDir = $queueCtx.Items.Add('打开原图目录')
    $miOpenResFile = $queueCtx.Items.Add('打开最新结果图')
    $miOpenResDir = $queueCtx.Items.Add('打开结果目录')
    $miShowErr = $queueCtx.Items.Add('查看错误详情')
    $miRequeue = $queueCtx.Items.Add('重新排队')
    $miRequeueAll = $queueCtx.Items.Add('全部重新排队')
    $miRemove = $queueCtx.Items.Add('从列表移除')
    $queueList.ContextMenuStrip = $queueCtx

    $outerSplit.Panel1.Controls.Add($queueList)
    $outerSplit.Panel1.Controls.Add($leftToolbar)
    $outerSplit.Panel1.Controls.Add($errPanel)
    $outerSplit.Panel1.Controls.Add($lblDropHint)

    # --- Center Pane: Image Comparator ---
    $compWrap = New-IUKComparatorPanel -ShowFileButtons
    $compWrap.Control.AllowDrop = $true
    $compWrap.Panel.AllowDrop = $true
    $innerSplit.Panel1.Controls.Add($compWrap.Panel)

    # --- Right Pane: Engine Parameters + Output + Collapsible Advanced ---
    $cardW = 334
    $rightScroll = [System.Windows.Forms.Panel]::new()
    $rightScroll.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rightScroll.AutoScroll = $true
    $rightScroll.Padding = [System.Windows.Forms.Padding]::new(6)
    $innerSplit.Panel2.Controls.Add($rightScroll)

    $rightStack = [System.Windows.Forms.FlowLayoutPanel]::new()
    $rightStack.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $rightStack.WrapContents = $false
    $rightStack.AutoSize = $true
    $rightStack.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $rightStack.Width = $cardW + 8
    $rightScroll.Controls.Add($rightStack)

    # Output group
    $grpOut = [System.Windows.Forms.GroupBox]::new()
    $grpOut.Text = '输出与队列策略'
    $grpOut.Size = [System.Drawing.Size]::new($cardW, 152)
    $rightStack.Controls.Add($grpOut)

    $chkAutoOut = [System.Windows.Forms.CheckBox]::new()
    $chkAutoOut.Text = '自动输出到原图所在目录'
    $chkAutoOut.Location = [System.Drawing.Point]::new(10, 22)
    $chkAutoOut.AutoSize = $true
    $chkAutoOut.Checked = [bool]$cfg.ui.auto_output

    $txtOutDir = [System.Windows.Forms.TextBox]::new()
    $txtOutDir.Location = [System.Drawing.Point]::new(10, 48)
    $txtOutDir.Size = [System.Drawing.Size]::new(242, 24)
    $txtOutDir.Text = [string]$cfg.ui.output_dir

    $btnBrowseOut = [System.Windows.Forms.Button]::new()
    $btnBrowseOut.Text = '选目录'
    $btnBrowseOut.Location = [System.Drawing.Point]::new(258, 46)
    $btnBrowseOut.Size = [System.Drawing.Size]::new(66, 26)

    $lblExist = [System.Windows.Forms.Label]::new(); $lblExist.Text = '已有文件:'; $lblExist.Location = [System.Drawing.Point]::new(10, 84); $lblExist.Size = [System.Drawing.Size]::new(76, 22)
    $cmbExist = [System.Windows.Forms.ComboBox]::new(); $cmbExist.DropDownStyle = 'DropDownList'; $cmbExist.Location = [System.Drawing.Point]::new(90, 80); $cmbExist.Size = [System.Drawing.Size]::new(234, 24)
    $cmbExist.Items.AddRange(@('自动加序号 (_1, _2)', '覆盖已有文件', '停止并提示错误'))
    $existKeys = @('rename', 'overwrite', 'error')
    $ei = [Array]::IndexOf($existKeys, [string]$cfg.anime4kcpp.existing_output)
    $cmbExist.SelectedIndex = if ($ei -ge 0) { $ei } else { 0 }

    $lblFail = [System.Windows.Forms.Label]::new(); $lblFail.Text = '单张失败:'; $lblFail.Location = [System.Drawing.Point]::new(10, 116); $lblFail.Size = [System.Drawing.Size]::new(76, 22)
    $cmbFail = [System.Windows.Forms.ComboBox]::new(); $cmbFail.DropDownStyle = 'DropDownList'; $cmbFail.Location = [System.Drawing.Point]::new(90, 112); $cmbFail.Size = [System.Drawing.Size]::new(234, 24)
    $cmbFail.Items.AddRange(@('继续处理下一张', '立即停止队列'))
    $cmbFail.SelectedIndex = if ([string]$cfg.ui.fail_policy -eq 'stop') { 1 } else { 0 }

    $grpOut.Controls.AddRange(@($chkAutoOut, $txtOutDir, $btnBrowseOut, $lblExist, $cmbExist, $lblFail, $cmbFail))

    # Anime4KCPP basic group
    $grpAcBasic = [System.Windows.Forms.GroupBox]::new()
    $grpAcBasic.Text = 'Anime4KCPP / ACNet (2x PNG)'
    $grpAcBasic.Size = [System.Drawing.Size]::new($cardW, 98)
    $rightStack.Controls.Add($grpAcBasic)

    $lblAcM = [System.Windows.Forms.Label]::new(); $lblAcM.Text = '模型:'; $lblAcM.Location = [System.Drawing.Point]::new(10, 26); $lblAcM.Size = [System.Drawing.Size]::new(48, 22)
    $cmbAcModel = [System.Windows.Forms.ComboBox]::new(); $cmbAcModel.DropDownStyle = 'DropDownList'; $cmbAcModel.Location = [System.Drawing.Point]::new(62, 22); $cmbAcModel.Size = [System.Drawing.Size]::new(196, 24)
    $btnAcRefresh = [System.Windows.Forms.Button]::new(); $btnAcRefresh.Text = '刷新'; $btnAcRefresh.Location = [System.Drawing.Point]::new(264, 21); $btnAcRefresh.Size = [System.Drawing.Size]::new(60, 26)
    $lblAcNote = [System.Windows.Forms.Label]::new(); $lblAcNote.Text = '直接放大 2 倍输出 PNG（支持中文路径）'; $lblAcNote.Location = [System.Drawing.Point]::new(10, 58); $lblAcNote.Size = [System.Drawing.Size]::new(314, 28); $lblAcNote.ForeColor = [System.Drawing.Color]::DimGray
    $grpAcBasic.Controls.AddRange(@($lblAcM, $cmbAcModel, $btnAcRefresh, $lblAcNote))

    # NCNN basic group
    $grpNcnnBasic = [System.Windows.Forms.GroupBox]::new()
    $grpNcnnBasic.Text = 'Real-ESRGAN / NCNN Vulkan'
    $grpNcnnBasic.Size = [System.Drawing.Size]::new($cardW, 102)
    $rightStack.Controls.Add($grpNcnnBasic)

    $lblNM = [System.Windows.Forms.Label]::new(); $lblNM.Text = '模型:'; $lblNM.Location = [System.Drawing.Point]::new(10, 26); $lblNM.Size = [System.Drawing.Size]::new(48, 22)
    $cmbNcnnModel = [System.Windows.Forms.ComboBox]::new(); $cmbNcnnModel.DropDownStyle = 'DropDownList'; $cmbNcnnModel.Location = [System.Drawing.Point]::new(62, 22); $cmbNcnnModel.Size = [System.Drawing.Size]::new(196, 24)
    $btnNcnnRefresh = [System.Windows.Forms.Button]::new(); $btnNcnnRefresh.Text = '刷新'; $btnNcnnRefresh.Location = [System.Drawing.Point]::new(264, 21); $btnNcnnRefresh.Size = [System.Drawing.Size]::new(60, 26)
    $lblNS = [System.Windows.Forms.Label]::new(); $lblNS.Text = '倍率:'; $lblNS.Location = [System.Drawing.Point]::new(10, 62); $lblNS.Size = [System.Drawing.Size]::new(48, 22)
    $cmbNcnnScale = [System.Windows.Forms.ComboBox]::new(); $cmbNcnnScale.DropDownStyle = 'DropDownList'; $cmbNcnnScale.Items.AddRange(@('auto', '2', '3', '4')); $cmbNcnnScale.Location = [System.Drawing.Point]::new(62, 58); $cmbNcnnScale.Size = [System.Drawing.Size]::new(100, 24)
    $grpNcnnBasic.Controls.AddRange(@($lblNM, $cmbNcnnModel, $btnNcnnRefresh, $lblNS, $cmbNcnnScale))

    # Magpie basic group
    $grpMagpieBasic = [System.Windows.Forms.GroupBox]::new()
    $grpMagpieBasic.Text = 'MagpieFX / HLSL'
    $grpMagpieBasic.Size = [System.Drawing.Size]::new($cardW, 214)
    $rightStack.Controls.Add($grpMagpieBasic)

    $lblMST = [System.Windows.Forms.Label]::new(); $lblMST.Text = '方式:'; $lblMST.Location = [System.Drawing.Point]::new(10, 24); $lblMST.Size = [System.Drawing.Size]::new(48, 22)
    $cmbMagType = [System.Windows.Forms.ComboBox]::new(); $cmbMagType.DropDownStyle = 'DropDownList'; $cmbMagType.Items.AddRange(@('mode', 'family', 'effect')); $cmbMagType.Location = [System.Drawing.Point]::new(62, 20); $cmbMagType.Size = [System.Drawing.Size]::new(136, 24)
    $btnMagRefresh = [System.Windows.Forms.Button]::new(); $btnMagRefresh.Text = '刷新'; $btnMagRefresh.Location = [System.Drawing.Point]::new(206, 19); $btnMagRefresh.Size = [System.Drawing.Size]::new(118, 26)
    $lblMM = [System.Windows.Forms.Label]::new(); $lblMM.Text = '方案:'; $lblMM.Location = [System.Drawing.Point]::new(10, 56); $lblMM.Size = [System.Drawing.Size]::new(48, 22)
    $cmbMagMode = [System.Windows.Forms.ComboBox]::new(); $cmbMagMode.DropDownStyle = 'DropDownList'; $cmbMagMode.Location = [System.Drawing.Point]::new(62, 52); $cmbMagMode.Size = [System.Drawing.Size]::new(262, 24)
    $lblMT = [System.Windows.Forms.Label]::new(); $lblMT.Text = '档位:'; $lblMT.Location = [System.Drawing.Point]::new(10, 88); $lblMT.Size = [System.Drawing.Size]::new(48, 22)
    $cmbMagTier = [System.Windows.Forms.ComboBox]::new(); $cmbMagTier.DropDownStyle = 'DropDownList'; $cmbMagTier.Location = [System.Drawing.Point]::new(62, 84); $cmbMagTier.Size = [System.Drawing.Size]::new(262, 24)
    $lblMagScale = [System.Windows.Forms.Label]::new(); $lblMagScale.Text = '目标倍率:'; $lblMagScale.Location = [System.Drawing.Point]::new(10, 120); $lblMagScale.AutoSize = $true
    $cmbMagScale = [System.Windows.Forms.ComboBox]::new(); $cmbMagScale.DropDownStyle = 'DropDownList'; $cmbMagScale.Items.AddRange(@('auto', '2', '3', '4')); $cmbMagScale.Location = [System.Drawing.Point]::new(72, 116); $cmbMagScale.Size = [System.Drawing.Size]::new(100, 24)
    $txtMagPreview = [System.Windows.Forms.TextBox]::new(); $txtMagPreview.Location = [System.Drawing.Point]::new(10, 148); $txtMagPreview.Size = [System.Drawing.Size]::new(314, 56); $txtMagPreview.Multiline = $true; $txtMagPreview.ReadOnly = $true; $txtMagPreview.ScrollBars = 'Vertical'
    $grpMagpieBasic.Controls.AddRange(@($lblMST, $cmbMagType, $btnMagRefresh, $lblMM, $cmbMagMode, $lblMT, $cmbMagTier, $lblMagScale, $cmbMagScale, $txtMagPreview))

    # Dynamic plugin panel slot (gui\*Panel.ps1 from PR 3 / PR 5)
    $pluginHost = [System.Windows.Forms.Panel]::new()
    $pluginHost.AutoSize = $true
    $pluginHost.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $pluginHost.Width = $cardW
    $pluginHost.MinimumSize = [System.Drawing.Size]::new($cardW, 0)
    $rightStack.Controls.Add($pluginHost)

    $guiPluginDir = Join-Path $Root 'gui'
    if (Test-Path -LiteralPath $guiPluginDir -PathType Container) {
        $mmDialogScript = Join-Path $guiPluginDir 'ModelManagerDialog.ps1'
        if (Test-Path -LiteralPath $mmDialogScript -PathType Leaf) {
            try { . $mmDialogScript } catch {}
        }
        foreach ($ps in Get-ChildItem -LiteralPath $guiPluginDir -Filter '*Panel.ps1' -File | Sort-Object Name) {
            try {
                . $ps.FullName
            } catch {}
        }
        if ((Get-Command 'New-IUKComfyUIPanel' -ErrorAction SilentlyContinue) -and $Script:IUKHasComfy) {
            try {
                $cp = New-IUKComfyUIPanel -Root $Root
                $cp.Panel.Width = $cardW
                $cp.Panel.Visible = $false
                $pluginHost.Controls.Add($cp.Panel)
                $state.PluginPanels['comfyui'] = $cp
            } catch {}
        }
        if ((Get-Command 'New-IUKRealCUGANPanel' -ErrorAction SilentlyContinue) -and $Script:IUKHasRealCugan) {
            try {
                $rp = New-IUKRealCUGANPanel -Root $Root
                $rp.Panel.Width = $cardW
                $rp.Panel.Visible = $false
                $pluginHost.Controls.Add($rp.Panel)
                $state.PluginPanels['realcugan'] = $rp
            } catch {}
        }
    }

    # Collapsible Advanced Toggle & Group (Collapsed by default)
    $btnAdvToggle = [System.Windows.Forms.Button]::new()
    $btnAdvToggle.Text = '▶ 高级参数（默认折叠）'
    $btnAdvToggle.Size = [System.Drawing.Size]::new($cardW, 28)
    $btnAdvToggle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $rightStack.Controls.Add($btnAdvToggle)

    $grpAdv = [System.Windows.Forms.GroupBox]::new()
    $grpAdv.Text = '高级选项'
    $grpAdv.Size = [System.Drawing.Size]::new($cardW, 232)
    $grpAdv.Visible = $false
    $rightStack.Controls.Add($grpAdv)

    $lblAcP = [System.Windows.Forms.Label]::new(); $lblAcP.Text = 'AC 处理器:'; $lblAcP.Location = [System.Drawing.Point]::new(10, 24); $lblAcP.Size = [System.Drawing.Size]::new(82, 22)
    $cmbAcProc = [System.Windows.Forms.ComboBox]::new(); $cmbAcProc.DropDownStyle = 'DropDownList'; $cmbAcProc.Items.AddRange(@('auto', 'cuda', 'opencl', 'cpu')); $cmbAcProc.Location = [System.Drawing.Point]::new(96, 20); $cmbAcProc.Size = [System.Drawing.Size]::new(108, 24)
    $lblAcDev = [System.Windows.Forms.Label]::new(); $lblAcDev.Text = '设备:'; $lblAcDev.Location = [System.Drawing.Point]::new(212, 24); $lblAcDev.Size = [System.Drawing.Size]::new(44, 22)
    $numAcDev = [System.Windows.Forms.NumericUpDown]::new(); $numAcDev.Location = [System.Drawing.Point]::new(260, 20); $numAcDev.Width = 64; $numAcDev.Maximum = 65535
    $lblAcBatch = [System.Windows.Forms.Label]::new(); $lblAcBatch.Text = 'AC 批大小:'; $lblAcBatch.Location = [System.Drawing.Point]::new(10, 56); $lblAcBatch.Size = [System.Drawing.Size]::new(82, 22)
    $numAcBatch = [System.Windows.Forms.NumericUpDown]::new(); $numAcBatch.Location = [System.Drawing.Point]::new(96, 52); $numAcBatch.Width = 76; $numAcBatch.Minimum = 1; $numAcBatch.Maximum = 256

    $lblNT = [System.Windows.Forms.Label]::new(); $lblNT.Text = 'NCNN Tile:'; $lblNT.Location = [System.Drawing.Point]::new(10, 90); $lblNT.Size = [System.Drawing.Size]::new(82, 22)
    $txtNcnnTile = [System.Windows.Forms.TextBox]::new(); $txtNcnnTile.Location = [System.Drawing.Point]::new(96, 86); $txtNcnnTile.Size = [System.Drawing.Size]::new(76, 24)
    $lblNG = [System.Windows.Forms.Label]::new(); $lblNG.Text = 'GPU:'; $lblNG.Location = [System.Drawing.Point]::new(186, 90); $lblNG.Size = [System.Drawing.Size]::new(40, 22)
    $txtNcnnGpu = [System.Windows.Forms.TextBox]::new(); $txtNcnnGpu.Location = [System.Drawing.Point]::new(230, 86); $txtNcnnGpu.Size = [System.Drawing.Size]::new(94, 24)
    $lblNJ = [System.Windows.Forms.Label]::new(); $lblNJ.Text = '线程:'; $lblNJ.Location = [System.Drawing.Point]::new(10, 122); $lblNJ.Size = [System.Drawing.Size]::new(82, 22)
    $txtNcnnThreads = [System.Windows.Forms.TextBox]::new(); $txtNcnnThreads.Location = [System.Drawing.Point]::new(96, 118); $txtNcnnThreads.Size = [System.Drawing.Size]::new(120, 24)
    $chkNcnnTta = [System.Windows.Forms.CheckBox]::new(); $chkNcnnTta.Text = 'TTA'; $chkNcnnTta.Location = [System.Drawing.Point]::new(230, 120); $chkNcnnTta.AutoSize = $true

    $lblMRaw = [System.Windows.Forms.Label]::new(); $lblMRaw.Text = 'HLSL 文件:'; $lblMRaw.Location = [System.Drawing.Point]::new(10, 156); $lblMRaw.Size = [System.Drawing.Size]::new(82, 22)
    $cmbMagRaw = [System.Windows.Forms.ComboBox]::new(); $cmbMagRaw.DropDownStyle = 'DropDownList'; $cmbMagRaw.Location = [System.Drawing.Point]::new(96, 152); $cmbMagRaw.Size = [System.Drawing.Size]::new(228, 24)
    $btnOpenMagCfg = [System.Windows.Forms.Button]::new(); $btnOpenMagCfg.Text = 'Magpie 配置'; $btnOpenMagCfg.Location = [System.Drawing.Point]::new(10, 188); $btnOpenMagCfg.Size = [System.Drawing.Size]::new(152, 28)
    $btnOpenHlslDir = [System.Windows.Forms.Button]::new(); $btnOpenHlslDir.Text = 'HLSL 目录'; $btnOpenHlslDir.Location = [System.Drawing.Point]::new(172, 188); $btnOpenHlslDir.Size = [System.Drawing.Size]::new(152, 28)

    $grpAdv.Controls.AddRange(@(
        $lblAcP, $cmbAcProc, $lblAcDev, $numAcDev, $lblAcBatch, $numAcBatch,
        $lblNT, $txtNcnnTile, $lblNG, $txtNcnnGpu, $lblNJ, $txtNcnnThreads, $chkNcnnTta,
        $lblMRaw, $cmbMagRaw, $btnOpenMagCfg, $btnOpenHlslDir
    ))

    $btnSaveCfg = [System.Windows.Forms.Button]::new()
    $btnSaveCfg.Text = '保存设置'
    $btnSaveCfg.Size = [System.Drawing.Size]::new($cardW, 30)
    $rightStack.Controls.Add($btnSaveCfg)

    # Assemble Form in WinForms reverse-Z docking order
    $form.Controls.Add($outerSplit)
    $form.Controls.Add($topBar)
    $form.Controls.Add($bottomBar)

    # --- Helper Closures ---
    $modeFile = { Resolve-IUKPath ([string]$state.Config.magpie.mode_file) }
    $magConfigFile = {
        if ($state.Config.magpie.config_file) { Resolve-IUKPath ([string]$state.Config.magpie.config_file) }
        else { Join-Path (Split-Path -Parent (Resolve-IUKPath ([string]$state.Config.magpie.exe_path))) 'config\config.json' }
    }
    $effectsDir = { Resolve-IUKPath ([string]$state.Config.magpie.effects_dir) }

    $refreshAcModels = {
        $wanted = if ($cmbAcModel.Text) { $cmbAcModel.Text } else { [string]$state.Config.anime4kcpp.model }
        $cmbAcModel.Items.Clear()
        $backend = Resolve-IUKPath $state.Config.anime4kcpp.backend_path
        if ($backend -and (Test-Path -LiteralPath $backend -PathType Leaf)) {
            try {
                $listing = & $backend --lm 2>&1
                if ($LASTEXITCODE -eq 0) {
                    foreach ($line in $listing) {
                        if ([string]$line -match '^  ([\w-]+):\s*$') { [void]$cmbAcModel.Items.Add($Matches[1]) }
                    }
                }
            } catch {}
        }
        if ($cmbAcModel.Items.Count -eq 0) {
            $cmbAcModel.Items.AddRange(@('acnet-legacy-gan', 'acnet-legacy-hdn0', 'acnet-legacy-hdn1', 'acnet-legacy-hdn2', 'acnet-legacy-hdn3', 'acnet-f8b4', 'acnet-f8b8', 'arnet-f8b16', 'artcnn-c4f16', 'fsrcnnx-f8b4'))
        }
        if ($cmbAcModel.Items.Contains($wanted)) { $cmbAcModel.SelectedItem = $wanted }
        elseif ($cmbAcModel.Items.Count -gt 0) { $cmbAcModel.SelectedIndex = 0 }
    }

    $refreshNcnnModels = {
        $wanted = if ($cmbNcnnModel.Text) { $cmbNcnnModel.Text } else { [string]$state.Config.ncnn.model }
        $cmbNcnnModel.Items.Clear()
        foreach ($m in Get-IUKNcnnModels (Resolve-IUKPath $state.Config.ncnn.model_dir)) { [void]$cmbNcnnModel.Items.Add($m) }
        if ($cmbNcnnModel.Items.Count -eq 0) {
            $cmbNcnnModel.Items.AddRange(@('realesrgan-x4plus-anime', 'realesrgan-x4plus'))
        }
        if ($cmbNcnnModel.Items.Contains($wanted)) { $cmbNcnnModel.SelectedItem = $wanted }
        elseif ($cmbNcnnModel.Items.Count -gt 0) { $cmbNcnnModel.SelectedIndex = 0 }
    }

    $updateMagpiePreview = {
        try {
            if ($cmbMagType.Text -eq 'effect') {
                $txtMagPreview.Text = "单个 HLSL（原生执行）`r`n$($cmbMagRaw.Text)"
                return
            }
            if (-not $cmbMagMode.Text) { $txtMagPreview.Text = ''; return }
            $ed = & $effectsDir
            $cf = & $magConfigFile
            $mf = & $modeFile
            if ($cmbMagType.Text -eq 'family') {
                $fx = @(Resolve-IUKFamilyEffect $cmbMagMode.Text $cmbMagTier.Text $ed)
                $txtMagPreview.Text = "模型族: $($cmbMagMode.Text) | 档位: $($cmbMagTier.Text)`r`nEffect: $($fx[0].name)"
                return
            }
            $src = Get-IUKModeSourceLabel $cf $mf $cmbMagMode.Text
            $fx = @(Resolve-IUKUnifiedModeEffects $cf $mf $cmbMagMode.Text $cmbMagTier.Text $ed)
            $lines = @("来源: $src | 档位: $($cmbMagTier.Text)")
            foreach ($e in $fx) { $lines += "  $($e.name)" }
            $txtMagPreview.Text = $lines -join "`r`n"
        } catch {
            $txtMagPreview.Text = $_.Exception.Message
        }
    }

    $refreshMagpieTiers = {
        $cmbMagTier.Items.Clear()
        if (-not $cmbMagMode.Text -or $cmbMagType.Text -eq 'effect') { return }
        $ed = & $effectsDir; $cf = & $magConfigFile; $mf = & $modeFile
        $ts = if ($cmbMagType.Text -eq 'family') { @(Get-IUKFamilyTiers $cmbMagMode.Text $ed) } else { @(Get-IUKUnifiedModeTiers $cf $mf $cmbMagMode.Text $ed) }
        foreach ($t in $ts) { [void]$cmbMagTier.Items.Add($t) }
        $want = [string]$state.Config.magpie.tier
        if ($cmbMagTier.Items.Contains($want)) { $cmbMagTier.SelectedItem = $want }
        elseif ($cmbMagTier.Items.Count -gt 0) { $cmbMagTier.SelectedIndex = 0 }
    }

    $refreshMagpie = {
        $ed = & $effectsDir; $cf = & $magConfigFile; $mf = & $modeFile
        $cmbMagMode.Items.Clear()
        if ($cmbMagType.Text -eq 'family') {
            foreach ($f in @(Get-IUKMagpieFamilies $ed)) { [void]$cmbMagMode.Items.Add([string]$f.Family) }
            $want = [string]$state.Config.magpie.family
        } else {
            foreach ($m in @(Get-IUKUnifiedModeNames $cf $mf)) { [void]$cmbMagMode.Items.Add($m) }
            $want = [string]$state.Config.magpie.mode
        }
        if ($cmbMagMode.Items.Contains($want)) { $cmbMagMode.SelectedItem = $want }
        elseif ($cmbMagMode.Items.Count -gt 0) { $cmbMagMode.SelectedIndex = 0 }

        $cmbMagRaw.Items.Clear()
        foreach ($e in Get-IUKMagpieEffects $ed) { [void]$cmbMagRaw.Items.Add($e) }
        if ($cmbMagRaw.Items.Contains([string]$state.Config.magpie.raw_effect)) { $cmbMagRaw.SelectedItem = [string]$state.Config.magpie.raw_effect }
        elseif ($cmbMagRaw.Items.Count -gt 0) { $cmbMagRaw.SelectedIndex = 0 }

        $cmbMagRaw.Enabled = ($cmbMagType.Text -eq 'effect')
        $cmbMagMode.Enabled = ($cmbMagType.Text -ne 'effect')
        $cmbMagTier.Enabled = ($cmbMagType.Text -ne 'effect')
        & $refreshMagpieTiers
        & $updateMagpiePreview
    }

    $refreshBackendStatus = {
        $ac = Test-Path -LiteralPath (Resolve-IUKPath $state.Config.anime4kcpp.backend_path)
        $nc = Test-Path -LiteralPath (Resolve-IUKPath $state.Config.ncnn.backend_path)
        $mp = Test-Path -LiteralPath (Resolve-IUKPath $state.Config.magpie.exe_path)
        $parts = @(
            "ACNet: $(if ($ac) { '已安装' } else { '未安装' })",
            "NCNN: $(if ($nc) { '已安装' } else { '未安装' })",
            "Magpie: $(if ($mp) { '已安装' } else { '未安装' })"
        )
        if ($Script:IUKHasRealCugan) {
            $rc = Test-Path -LiteralPath (Resolve-IUKPath 'bin\realcugan\realcugan-ncnn-vulkan.exe')
            $parts += "Real-CUGAN: $(if ($rc) { '已安装' } else { '未安装' })"
        }
        if ($Script:IUKHasComfy) {
            $parts += 'ComfyUI: 已接入'
        }
        $lblBackendStatus.Text = ($parts -join '   |   ') + "`r`n提示：可将图片或文件夹直接拖入窗口，处理完在中央区域即刻对比。"
    }

    $updateEnginePanels = {
        $eng = $cmbEngine.Text
        $grpAcBasic.Visible = ($eng -eq 'anime4kcpp')
        $grpNcnnBasic.Visible = ($eng -eq 'ncnn')
        $grpMagpieBasic.Visible = ($eng -eq 'magpie')
        foreach ($key in $state.PluginPanels.Keys) {
            $state.PluginPanels[$key].Panel.Visible = ($eng -eq $key)
        }
        $txtOutDir.Enabled = -not $chkAutoOut.Checked
        $btnBrowseOut.Enabled = -not $chkAutoOut.Checked
    }

    $showStatusLog = {
        param([string]$Title, [string]$Body, [switch]$IsError, [string]$PreviewError)
        $lblErrTitle.Text = if ($Title) { $Title } else { '运行状态 / 错误详情' }
        $txtErrLog.Text = if ($PreviewError) {
            (@($Body, $PreviewError) | Where-Object { $_ }) -join "`r`n`r`n"
        } else {
            $Body
        }
        if ($IsError -or $PreviewError) {
            $lblErrTitle.ForeColor = [System.Drawing.Color]::Firebrick
            $txtErrLog.BackColor = [System.Drawing.Color]::FromArgb(255, 242, 242)
            $txtErrLog.ForeColor = [System.Drawing.Color]::DarkRed
        } else {
            $lblErrTitle.ForeColor = [System.Drawing.Color]::FromArgb(40, 48, 60)
            $txtErrLog.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 254)
            $txtErrLog.ForeColor = [System.Drawing.Color]::FromArgb(30, 36, 44)
        }
    }

    $refreshQueueUI = {
        $state.Syncing = $true
        try {
            $selectedIds = @{}
            foreach ($row in $queueList.SelectedItems) {
                $selectedIds[$row.Tag.Id] = $true
            }

            $queueList.BeginUpdate()
            try {
                $queueList.Items.Clear()
                for ($i = 0; $i -lt $state.Queue.Count; $i++) {
                    $q = $state.Queue[$i]
                    $lvi = [System.Windows.Forms.ListViewItem]::new($q.FileName)
                    $lvi.Tag = $q
                    $timeStr = if ($q.ElapsedMs -gt 0) { '{0:F1}s' -f ($q.ElapsedMs / 1000.0) } else { '-' }
                    [void]$lvi.SubItems.Add($q.Status)
                    [void]$lvi.SubItems.Add($timeStr)
                    [void]$lvi.SubItems.Add([string]$q.Results.Count)
                    switch ($q.Status) {
                        '已完成' { $lvi.ForeColor = [System.Drawing.Color]::DarkGreen }
                        '失败' { $lvi.ForeColor = [System.Drawing.Color]::Firebrick }
                        '处理中' { $lvi.ForeColor = [System.Drawing.Color]::RoyalBlue }
                        '已取消' { $lvi.ForeColor = [System.Drawing.Color]::Gray }
                    }
                    [void]$queueList.Items.Add($lvi)
                    if ($selectedIds.ContainsKey($q.Id)) {
                        $lvi.Selected = $true
                    }
                }
            } finally {
                $queueList.EndUpdate()
            }

            $lblDropHint.Visible = ($state.Queue.Count -eq 0)
            $sum = Get-IUKQueueSummary $state.Queue
            $doneCount = $sum.Completed + $sum.Failed + $sum.Cancelled
            $progress.Maximum = [Math]::Max(1, $sum.Total)
            $progress.Value = [Math]::Min($progress.Maximum, $doneCount)
            $curText = if ($state.CurrentItem) { "当前: $($state.CurrentItem.FileName)" } elseif ($state.IsRunning) { '运行中' } else { '就绪' }
            $lblSummary.Text = "已完成: $($sum.Completed) | 失败: $($sum.Failed) | 待处理: $($sum.Pending) | $curText"
            $lblSummary.ForeColor = if ($sum.Failed -gt 0) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.SystemColors]::ControlText }
            $btnCancelPending.Enabled = ($sum.Pending -gt 0)
            $btnAbort.Enabled = $state.IsRunning
            $btnStart.Enabled = (-not $state.IsRunning -and $sum.Pending -gt 0)
        } finally {
            $state.Syncing = $false
        }
    }

    $loadQueueItemToComparator = {
        param($Item)
        if (-not $Item) { return }
        $previewErrors = [System.Collections.Generic.List[string]]::new()
        try {
            $compWrap.Control.LoadOriginal($Item.InputPath)
        } catch {
            $compWrap.Control.ClearAll()
            $previewErrors.Add("原图预览失败：$($Item.InputPath)`r`n$($_.Exception.GetBaseException().Message)")
        }
        $typedList = [System.Collections.Generic.List[ImageUpscaleKit.UI.ComparatorResultItem]]::new()
        foreach ($r in $Item.Results) {
            if ($r -is [ImageUpscaleKit.UI.ComparatorResultItem]) {
                [void]$typedList.Add($r)
            } else {
                [void]$typedList.Add([ImageUpscaleKit.UI.ComparatorResultItem]@{
                    Id = [string]$r.Id
                    Label = [string]$r.Label
                    Engine = [string]$r.Engine
                    Model = [string]$r.Model
                    FilePath = [string]$r.FilePath
                    ElapsedMs = [double]($r.ElapsedMs ?? 0)
                })
            }
        }
        $selIdx = if ($typedList.Count -gt 0) { $typedList.Count - 1 } else { -1 }
        try {
            $compWrap.Control.SetResults($typedList, $selIdx)
            $compWrap.Control.FitToWindow()
        } catch {
            $compWrap.Control.ClearAll()
            $resultPath = if ($selIdx -ge 0) { $typedList[$selIdx].FilePath }
            $previewErrors.Add("结果预览失败：$resultPath`r`n$($_.Exception.GetBaseException().Message)")
        }
        if ($previewErrors.Count -gt 0) { return ($previewErrors -join "`r`n`r`n") }
    }

    $enqueuePaths = {
        param([string[]]$Paths)
        $files = @(Expand-IUKDroppedPaths $Paths)
        if ($files.Count -eq 0) { return 0 }
        $existingSet = @{}
        foreach ($q in $state.Queue) { $existingSet[$q.InputPath] = $true }
        $added = 0
        $firstNewIdx = -1
        foreach ($f in $files) {
            if (-not $existingSet.ContainsKey($f)) {
                $item = New-IUKQueueItem -InputPath $f -Engine $cmbEngine.Text -PresetLabel $cmbPreset.Text
                [void]$state.Queue.Add($item)
                if ($firstNewIdx -lt 0) { $firstNewIdx = $state.Queue.Count - 1 }
                $added++
            }
        }
        & $refreshQueueUI
        if ($firstNewIdx -ge 0 -and $queueList.SelectedIndices.Count -eq 0) {
            $queueList.Items[$firstNewIdx].Selected = $true
        }
        return $added
    }

    $applyPreset = {
        $idx = $cmbPreset.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $state.Presets.Count) { return }
        $p = $state.Presets[$idx]
        if ($cmbEngine.Items.Contains($p.Engine)) {
            $cmbEngine.SelectedItem = $p.Engine
        }
        if ($p.Engine -eq 'anime4kcpp' -and $p.Model -and $cmbAcModel.Items.Contains($p.Model)) {
            $cmbAcModel.SelectedItem = $p.Model
        } elseif ($p.Engine -eq 'ncnn') {
            if ($p.Model -and $cmbNcnnModel.Items.Contains($p.Model)) { $cmbNcnnModel.SelectedItem = $p.Model }
            if ($p.Scale -and $cmbNcnnScale.Items.Contains($p.Scale)) { $cmbNcnnScale.SelectedItem = $p.Scale }
        } elseif ($p.Engine -eq 'realcugan' -and $state.PluginPanels.ContainsKey('realcugan')) {
            $panel = $state.PluginPanels['realcugan'].Context
            $panel.CmbModel.SelectedItem = $p.Model
            $panel.CmbScale.SelectedItem = $p.Scale
            $panel.CmbNoise.SelectedItem = $p.NoiseLevel
        } elseif ($p.Engine -eq 'magpie') {
            if ($p.SelectionType) { $cmbMagType.SelectedItem = $p.SelectionType }
            & $refreshMagpie
            $target = if ($p.SelectionType -eq 'family') { $p.Family } else { $p.Mode }
            if ($target -and $cmbMagMode.Items.Contains($target)) { $cmbMagMode.SelectedItem = $target }
            & $refreshMagpieTiers
            if ($p.Tier -and $cmbMagTier.Items.Contains($p.Tier)) { $cmbMagTier.SelectedItem = $p.Tier }
            $cmbMagScale.SelectedItem = $p.Scale ?? 'auto'
            & $updateMagpiePreview
        } elseif ($p.Engine -eq 'comfyui' -and $state.PluginPanels.ContainsKey('comfyui')) {
            if ($p.ComfyPreset -and $state.PluginPanels['comfyui'].SelectPreset) {
                & $state.PluginPanels['comfyui'].SelectPreset $p.ComfyPreset
            }
        }
        & $updateEnginePanels
    }

    $collectOptions = {
        $existPolicy = $existKeys[[Math]::Max(0, $cmbExist.SelectedIndex)]
        $opts = @{
            Engine = $cmbEngine.Text
            AcModel = $cmbAcModel.Text
            AcProcessor = $cmbAcProc.Text
            AcDevice = [int]$numAcDev.Value
            AcBatchSize = [int]$numAcBatch.Value
            ExistingOutput = $existPolicy
            NcnnModel = $cmbNcnnModel.Text
            NcnnScale = $cmbNcnnScale.Text
            NcnnTile = $(if ($txtNcnnTile.Text -match '^\d+$') { [int]$txtNcnnTile.Text } else { 0 })
            NcnnGpu = $txtNcnnGpu.Text
            NcnnThreads = $txtNcnnThreads.Text
            NcnnTta = $chkNcnnTta.Checked
            MagpieSelectionType = $cmbMagType.Text
            MagpieMode = $cmbMagMode.Text
            MagpieFamily = $cmbMagMode.Text
            MagpieTier = $cmbMagTier.Text
            MagpieEffect = $cmbMagRaw.Text
            MagpieScale = $cmbMagScale.Text
        }
        foreach ($key in $state.PluginPanels.Keys) {
            if ($state.PluginPanels[$key].GetOptions) {
                $extra = & $state.PluginPanels[$key].GetOptions
                foreach ($ek in $extra.Keys) { $opts[$ek] = $extra[$ek] }
            }
        }
        return $opts
    }

    $saveCurrentConfig = {
        try {
            $c = Load-IUKGuiConfig
            $c.engine = $cmbEngine.Text
            $c.anime4kcpp.model = $cmbAcModel.Text
            $c.anime4kcpp.processor = $cmbAcProc.Text
            $c.anime4kcpp.device = [int]$numAcDev.Value
            $c.anime4kcpp.batch_size = [int]$numAcBatch.Value
            $c.anime4kcpp.existing_output = $existKeys[[Math]::Max(0, $cmbExist.SelectedIndex)]
            if ($cmbNcnnModel.Text) { $c.ncnn.model = $cmbNcnnModel.Text }
            $c.ncnn.scale = $cmbNcnnScale.Text
            $c.ncnn.tile = if ($txtNcnnTile.Text -match '^\d+$') { [int]$txtNcnnTile.Text } else { 0 }
            $c.ncnn.gpu = $txtNcnnGpu.Text
            $c.ncnn.threads = $txtNcnnThreads.Text
            $c.ncnn.tta = $chkNcnnTta.Checked
            $c.magpie.selection_type = $cmbMagType.Text
            if ($cmbMagType.Text -eq 'family') { if ($cmbMagMode.Text) { $c.magpie.family = $cmbMagMode.Text } }
            else { if ($cmbMagMode.Text) { $c.magpie.mode = $cmbMagMode.Text } }
            if ($cmbMagTier.Text) { $c.magpie.tier = $cmbMagTier.Text }
            if ($cmbMagRaw.Text) { $c.magpie.raw_effect = $cmbMagRaw.Text }
            $c.magpie | Add-Member -NotePropertyName target_scale -NotePropertyValue $cmbMagScale.Text -Force
            $c.ui.window_width = $form.Width
            $c.ui.window_height = $form.Height
            $c.ui.fail_policy = if ($cmbFail.SelectedIndex -eq 1) { 'stop' } else { 'continue' }
            $c.ui.auto_output = $chkAutoOut.Checked
            $c.ui.output_dir = $txtOutDir.Text
            Save-IUKGuiConfig $c
            $state.Config = $c
            return $true
        } catch {
            [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '保存配置失败') | Out-Null
            return $false
        }
    }

    $pollTimer = [System.Windows.Forms.Timer]::new()
    $pollTimer.Interval = 100

    $startNextPending = {
        if ($state.StopRequested) {
            $state.IsRunning = $false
            $state.CurrentItem = $null
            $pollTimer.Stop()
            & $refreshQueueUI
            return
        }
        $next = $null
        foreach ($q in $state.Queue) {
            if ($q.Status -eq '待处理') { $next = $q; break }
        }
        if (-not $next) {
            $state.IsRunning = $false
            $state.CurrentItem = $null
            $pollTimer.Stop()
            & $refreshQueueUI
            return
        }

        $opts = & $collectOptions
        $outDir = if ($chkAutoOut.Checked) { '' } else { $txtOutDir.Text.Trim() }
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        }
        $next.Engine = $opts.Engine
        $next.OutputPath = Resolve-IUKItemOutputPath `
            -InputPath $next.InputPath `
            -OutputDir $outDir `
            -Engine $opts.Engine `
            -Suffix ([string]$state.Config.output_suffix) `
            -Format ([string]$state.Config.ncnn.format) `
            -ExistingPolicy $opts.ExistingOutput `
            -UsedPaths $state.UsedOutputPaths

        $upscaleArgs = Build-IUKUpscaleArguments -UpscaleScriptPath (Join-Path $Root 'Upscale.ps1') -Item $next -Options $opts
        $next.Status = '处理中'
        $next.ErrorMessage = ''
        $state.CurrentItem = $next
        $state.CurrentRunLog.Clear()
        & $showStatusLog "运行中 - $($next.FileName)" "引擎: $($opts.Engine)`r`n输入: $($next.InputPath)`r`n输出: $($next.OutputPath)"
        $state.CurrentRunner = [ImageUpscaleKit.Execution.IukAsyncProcessRunner]::new('pwsh.exe', $upscaleArgs, $Root)
        & $refreshQueueUI
        $pollTimer.Start()
    }

    $pollTimer.Add_Tick({
        $runner = $state.CurrentRunner
        $item = $state.CurrentItem
        if (-not $runner -or -not $item) {
            $pollTimer.Stop()
            return
        }
        $gotLines = $false
        foreach ($line in $runner.DrainOutput()) {
            [void]$state.CurrentRunLog.Add($line)
            $gotLines = $true
        }
        if ($gotLines -and -not $runner.HasExited) {
            & $showStatusLog "运行中 - $($item.FileName)" (($state.CurrentRunLog | Select-Object -Last 12) -join "`r`n")
        }
        if (-not $runner.HasExited) { return }

        foreach ($line in $runner.DrainOutput()) {
            [void]$state.CurrentRunLog.Add($line)
        }
        $exitCode = $runner.ExitCode
        $elapsed = [double]$runner.ElapsedMilliseconds
        $wasKilled = $runner.WasKilled
        $runner.Dispose()
        $state.CurrentRunner = $null
        $item.ElapsedMs = $elapsed

        if ($wasKilled) {
            $item.Status = '已取消'
            $item.ErrorMessage = '用户中止'
            $state.StopRequested = $true
            & $showStatusLog "已取消 - $($item.FileName)" '用户中止了当前任务。'
        } elseif ($exitCode -eq 0 -and (Test-Path -LiteralPath $item.OutputPath -PathType Leaf)) {
            $item.Status = '已完成'
            $state.LastResultPath = $item.OutputPath
            $state.LastOutputDir = Split-Path -Parent $item.OutputPath
            $resObj = [ImageUpscaleKit.UI.ComparatorResultItem]@{
                Id = [guid]::NewGuid().ToString('N')
                Label = '{0} ({1:F1}s)' -f $item.Engine, ($elapsed / 1000.0)
                Engine = $item.Engine
                FilePath = $item.OutputPath
                ElapsedMs = $elapsed
            }
            [void]$item.Results.Add($resObj)
            # Load completed result immediately if item is selected or comparator is showing it
            $previewError = if ($queueList.SelectedIndices.Count -eq 0 -or $state.Queue[$queueList.SelectedIndices[0]].Id -eq $item.Id) {
                & $loadQueueItemToComparator $item
            }
            & $showStatusLog "已完成 - $($item.FileName)" ("输出: {0}`r`n耗时: {1:F2}s" -f $item.OutputPath, ($elapsed / 1000.0)) -PreviewError $previewError
        } else {
            $item.Status = '失败'
            $nonEmpty = @($state.CurrentRunLog | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 20)
            $item.ErrorMessage = if ($nonEmpty.Count -gt 0) { $nonEmpty -join "`r`n" } else { "退出码: $exitCode（未捕获输出详情，请打开日志目录排查）" }
            & $showStatusLog "失败 - $($item.FileName)" $item.ErrorMessage -IsError
            if ($cmbFail.SelectedIndex -eq 1) {
                $state.StopRequested = $true
            }
        }

        $state.CurrentItem = $null
        & $refreshQueueUI
        & $startNextPending
    })

    # Initialize field values
    & $refreshAcModels
    & $refreshNcnnModels
    $cmbAcProc.SelectedItem = [string]$cfg.anime4kcpp.processor
    if ($cmbAcProc.SelectedIndex -lt 0) { $cmbAcProc.SelectedItem = 'auto' }
    $numAcDev.Value = [Math]::Max(0, [int]$cfg.anime4kcpp.device)
    $numAcBatch.Value = [Math]::Clamp([int]$cfg.anime4kcpp.batch_size, 1, 256)
    $cmbNcnnScale.SelectedItem = [string]$cfg.ncnn.scale
    if ($cmbNcnnScale.SelectedIndex -lt 0) { $cmbNcnnScale.SelectedItem = 'auto' }
    $txtNcnnTile.Text = [string]$cfg.ncnn.tile
    $txtNcnnGpu.Text = [string]$cfg.ncnn.gpu
    $txtNcnnThreads.Text = [string]$cfg.ncnn.threads
    $chkNcnnTta.Checked = [bool]$cfg.ncnn.tta
    $cmbMagType.SelectedItem = [string]$cfg.magpie.selection_type
    if ($cmbMagType.SelectedIndex -lt 0) { $cmbMagType.SelectedItem = 'mode' }
    $cmbMagScale.SelectedItem = [string]$cfg.magpie.target_scale
    if ($cmbMagScale.SelectedIndex -lt 0) { $cmbMagScale.SelectedItem = 'auto' }
    & $refreshMagpie
    & $refreshBackendStatus
    & $updateEnginePanels
    & $refreshQueueUI

    # Wire Events (all closures bound safely)
    $dragEnterHandler = {
        param($sender, $e)
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        } else {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    }
    $dragDropHandler = {
        param($sender, $e)
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $dropped = [string[]]$e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            & $enqueuePaths $dropped | Out-Null
        }
    }

    foreach ($dropCtrl in @($form, $queueList, $compWrap.Panel, $compWrap.Control)) {
        $dropCtrl.Add_DragEnter($dragEnterHandler)
        $dropCtrl.Add_DragDrop($dragDropHandler)
    }

    $btnImportFiles.Add_Click({
        $picked = Select-IUKImagesDialog $form $txtOutDir.Text
        if ($picked.Count -gt 0) { & $enqueuePaths $picked | Out-Null }
    })

    $btnImportDir.Add_Click({
        $dir = Select-IUKFolderDialog $form $txtOutDir.Text
        if ($dir) { & $enqueuePaths @($dir) | Out-Null }
    })

    $btnClearQueue.Add_Click({
        if ($state.IsRunning) { return }
        $state.Queue.Clear()
        $compWrap.Control.ClearAll()
        & $refreshQueueUI
    })

    $removeSelected = {
        foreach ($idx in @($queueList.SelectedIndices | Sort-Object -Descending)) {
            if ($state.Queue[$idx].Status -ne '处理中') { $state.Queue.RemoveAt($idx) }
        }
        & $refreshQueueUI
    }
    $btnRemoveSel.Add_Click($removeSelected)
    $miRemove.Add_Click($removeSelected)

    $btnClearDone.Add_Click({
        for ($i = $state.Queue.Count - 1; $i -ge 0; $i--) {
            if ($state.Queue[$i].Status -in @('已完成', '已取消')) {
                $state.Queue.RemoveAt($i)
            }
        }
        & $refreshQueueUI
    })

    $btnRetryFail.Add_Click({
        foreach ($q in $state.Queue) {
            if ($q.Status -in @('失败', '已取消')) {
                $q.Status = '待处理'
                $q.ErrorMessage = ''
            }
        }
        & $refreshQueueUI
    })

    $showQueueSelection = {
        if ($state.Syncing -or $queueList.SelectedIndices.Count -eq 0) { return }
        $idx = $queueList.SelectedIndices[0]
        if ($idx -ge 0 -and $idx -lt $state.Queue.Count) {
            $selItem = $state.Queue[$idx]
            $previewError = & $loadQueueItemToComparator $selItem
            if ($selItem.Status -eq '失败' -and $selItem.ErrorMessage) {
                & $showStatusLog "失败 - $($selItem.FileName)" $selItem.ErrorMessage -IsError -PreviewError $previewError
            } elseif ($selItem.Status -eq '已完成' -and $selItem.OutputPath) {
                & $showStatusLog "已完成 - $($selItem.FileName)" ("输出: {0}`r`n耗时: {1:F2}s" -f $selItem.OutputPath, ($selItem.ElapsedMs / 1000.0)) -PreviewError $previewError
            } elseif (-not $state.IsRunning -or $previewError) {
                & $showStatusLog "状态 - $($selItem.FileName)" ("当前状态: {0}`r`n输入: {1}" -f $selItem.Status, $selItem.InputPath) -PreviewError $previewError
            }
        }
    }
    $queueList.Add_SelectedIndexChanged($showQueueSelection)

    $btnCopyErr.Add_Click({
        if (-not [string]::IsNullOrEmpty($txtErrLog.Text)) {
            [System.Windows.Forms.Clipboard]::SetText($txtErrLog.Text)
        }
    })

    $miShowErr.Add_Click({
        if ($queueList.SelectedIndices.Count -gt 0) {
            $q = $state.Queue[$queueList.SelectedIndices[0]]
            $detail = if ($q.ErrorMessage) { $q.ErrorMessage } elseif ($q.OutputPath) { "输出路径: $($q.OutputPath)" } else { "当前状态: $($q.Status)" }
            [System.Windows.Forms.MessageBox]::Show($form, $detail, "任务详情 - $($q.FileName)") | Out-Null
        }
    })

    $miOpenSrcDir.Add_Click({
        if ($queueList.SelectedIndices.Count -gt 0) {
            $q = $state.Queue[$queueList.SelectedIndices[0]]
            if (Test-Path -LiteralPath $q.InputPath) { Start-Process explorer.exe "/select,`"$($q.InputPath)`"" }
        }
    })

    $miOpenResFile.Add_Click({
        if ($queueList.SelectedIndices.Count -gt 0) {
            $q = $state.Queue[$queueList.SelectedIndices[0]]
            $resPath = if ($q.Results.Count -gt 0) { $q.Results[$q.Results.Count - 1].FilePath } else { $q.OutputPath }
            if ($resPath -and (Test-Path -LiteralPath $resPath)) { Start-Process $resPath }
        }
    })

    $miOpenResDir.Add_Click({
        if ($queueList.SelectedIndices.Count -gt 0) {
            $q = $state.Queue[$queueList.SelectedIndices[0]]
            $resPath = if ($q.Results.Count -gt 0) { $q.Results[$q.Results.Count - 1].FilePath } else { $q.OutputPath }
            if ($resPath -and (Test-Path -LiteralPath $resPath)) { Start-Process explorer.exe "/select,`"$resPath`"" }
        }
    })

    $requeueItems = {
        param($Items)
        foreach ($q in $Items) {
            if ($q.Status -eq '处理中') { continue }
            $q.Status = '待处理'
            $q.ErrorMessage = ''
        }
        & $refreshQueueUI
        if (-not $state.IsRunning) { & $showQueueSelection }
    }

    $miRequeue.Add_Click({
        & $requeueItems @($queueList.SelectedItems | ForEach-Object { $_.Tag })
    })
    $requeueAll = { & $requeueItems $state.Queue }
    $btnRequeueAll.Add_Click($requeueAll)
    $miRequeueAll.Add_Click($requeueAll)

    $cmbEngine.Add_SelectedIndexChanged({ & $updateEnginePanels })
    $btnApplyPreset.Add_Click($applyPreset)
    $chkAutoOut.Add_CheckedChanged({ & $updateEnginePanels })
    $btnBrowseOut.Add_Click({
        $d = Select-IUKFolderDialog $form $txtOutDir.Text
        if ($d) { $txtOutDir.Text = $d; $chkAutoOut.Checked = $false; & $updateEnginePanels }
    })

    $btnAcRefresh.Add_Click({ & $refreshAcModels; & $refreshBackendStatus })
    $btnNcnnRefresh.Add_Click({ & $refreshNcnnModels; & $refreshBackendStatus })
    $btnMagRefresh.Add_Click({ $state.Config = Load-IUKGuiConfig; & $refreshMagpie; & $refreshBackendStatus })
    $cmbMagType.Add_SelectedIndexChanged({ & $refreshMagpie })
    $cmbMagMode.Add_SelectedIndexChanged({ & $refreshMagpieTiers; & $updateMagpiePreview })
    $cmbMagTier.Add_SelectedIndexChanged({ & $updateMagpiePreview })
    $cmbMagRaw.Add_SelectedIndexChanged({ & $updateMagpiePreview })

    $btnOpenMagCfg.Add_Click({
        $cf = & $magConfigFile; $mf = & $modeFile
        if (Test-Path -LiteralPath $cf) { Start-Process notepad.exe $cf }
        elseif (Test-Path -LiteralPath $mf) { Start-Process notepad.exe $mf }
        else { [System.Windows.Forms.MessageBox]::Show($form, '未找到 Magpie 配置文件。') | Out-Null }
    })

    $btnOpenHlslDir.Add_Click({
        $ed = & $effectsDir
        if (Test-Path -LiteralPath $ed) { Start-Process explorer.exe $ed }
        else { [System.Windows.Forms.MessageBox]::Show($form, '请先安装 Magpie 后端。') | Out-Null }
    })

    $btnAdvToggle.Add_Click({
        $state.AdvancedExpanded = -not $state.AdvancedExpanded
        $grpAdv.Visible = $state.AdvancedExpanded
        $btnAdvToggle.Text = if ($state.AdvancedExpanded) { '▼ 高级参数' } else { '▶ 高级参数（默认折叠）' }
    })

    $btnSaveCfg.Add_Click({
        if (& $saveCurrentConfig) {
            [System.Windows.Forms.MessageBox]::Show($form, '设置已保存。') | Out-Null
        }
    })

    $btnSetup.Add_Click({
        $scriptName = switch ($cmbEngine.Text) {
            'anime4kcpp' { 'Setup-Anime4KCPP.ps1' }
            'realcugan' { 'Setup-RealCUGAN.ps1' }
            default { 'Setup.ps1' }
        }
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'pwsh.exe'
        $psi.UseShellExecute = $true
        [void]$psi.ArgumentList.Add('-NoProfile')
        [void]$psi.ArgumentList.Add('-File')
        [void]$psi.ArgumentList.Add((Join-Path $Root $scriptName))
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        $state.Config = Load-IUKGuiConfig
        & $refreshAcModels; & $refreshNcnnModels; & $refreshMagpie; & $refreshBackendStatus
    })

    $btnModelMgr.Add_Click({
        if (-not (Get-Command 'Show-IUKModelManagerDialog' -ErrorAction SilentlyContinue)) {
            [System.Windows.Forms.MessageBox]::Show($form, '未找到 ModelManagerDialog 模块，请确保已安装 PR #5 权重管理脚本。') | Out-Null
            return
        }
        $comfyDir = ''
        if ($state.PluginPanels.ContainsKey('comfyui') -and $state.PluginPanels['comfyui'].Context.TxtDir) {
            $comfyDir = [string]$state.PluginPanels['comfyui'].Context.TxtDir.Text.Trim()
        }
        Show-IUKModelManagerDialog -Root $Root -ComfyInstallDir $comfyDir -OwnerForm $form
        & $refreshAcModels; & $refreshNcnnModels; & $refreshBackendStatus
        if ($state.PluginPanels.ContainsKey('comfyui') -and $state.PluginPanels['comfyui'].RefreshModels) {
            try { & $state.PluginPanels['comfyui'].RefreshModels } catch {}
        }
    })

    $startQueueAction = {
        if ($state.IsRunning) { return }
        if (-not (& $saveCurrentConfig)) { return }
        $sum = Get-IUKQueueSummary $state.Queue
        if ($sum.Pending -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($form, '请先导入待处理的图片或文件夹。') | Out-Null
            return
        }
        $state.IsRunning = $true
        $state.StopRequested = $false
        $state.UsedOutputPaths = @{}
        & $startNextPending
    }

    $cancelPendingAction = {
        foreach ($q in $state.Queue) {
            if ($q.Status -eq '待处理') { $q.Status = '已取消' }
        }
        & $refreshQueueUI
    }

    $abortCurrentAction = {
        $state.StopRequested = $true
        if ($state.CurrentRunner) { $state.CurrentRunner.KillTree() }
    }

    $btnStart.Add_Click($startQueueAction)
    $btnCancelPending.Add_Click($cancelPendingAction)
    $btnAbort.Add_Click($abortCurrentAction)

    $btnOpenResult.Add_Click({
        $target = $state.LastResultPath
        if ($queueList.SelectedIndices.Count -gt 0) {
            $q = $state.Queue[$queueList.SelectedIndices[0]]
            if ($q.Results.Count -gt 0) { $target = $q.Results[$q.Results.Count - 1].FilePath }
        }
        if ($target -and (Test-Path -LiteralPath $target)) { Start-Process $target }
        else { [System.Windows.Forms.MessageBox]::Show($form, '当前暂无可打开的结果图片。') | Out-Null }
    })

    $btnOpenOutDir.Add_Click({
        $dir = if ($txtOutDir.Text -and -not $chkAutoOut.Checked) { $txtOutDir.Text } elseif ($state.LastOutputDir) { $state.LastOutputDir } else { Join-Path $Root 'output' }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Start-Process explorer.exe $dir
    })

    $btnOpenLogs.Add_Click({
        $p = Join-Path $Root 'logs'
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        Start-Process explorer.exe $p
    })

    $form.Add_FormClosing({
        $pollTimer.Stop()
        if ($state.CurrentRunner) {
            $state.CurrentRunner.KillTree()
            $state.CurrentRunner.Dispose()
            $state.CurrentRunner = $null
        }
        $pollTimer.Dispose()
    })

    $mainWin = [pscustomobject]@{
        Form = $form
        State = $state
        Controls = @{
            TopBar = $topBar
            BottomBar = $bottomBar
            OuterSplit = $outerSplit
            InnerSplit = $innerSplit
            QueueList = $queueList
            Comparator = $compWrap
            EngineCombo = $cmbEngine
            PresetCombo = $cmbPreset
            AdvancedButton = $btnAdvToggle
            AdvancedGroup = $grpAdv
            FailPolicyCombo = $cmbFail
            AutoOutputCheck = $chkAutoOut
            OutputDirText = $txtOutDir
            SummaryLabel = $lblSummary
            ProgressBar = $progress
            ErrorLogText = $txtErrLog
            BottomBarTable = $bottomGrid
            BottomButtonPanel = $bottomBtnPanel
            ModelManagerButton = $btnModelMgr
        }
        Actions = @{
            EnqueuePaths = $enqueuePaths
            ApplyPreset = $applyPreset
            RefreshQueue = $refreshQueueUI
            LoadItemToComparator = $loadQueueItemToComparator
            CancelPending = $cancelPendingAction
            AbortCurrent = $abortCurrentAction
            SaveConfig = $saveCurrentConfig
            ShowStatusLog = $showStatusLog
        }
    }

    function Get-IUKMainWindowResult { return $mainWin }
    Export-ModuleMember -Function Get-IUKMainWindowResult
}

$mainWin = & $guiModule { Get-IUKMainWindowResult }
if ($TestMode) {
    return $mainWin
}
try {
    [void]$mainWin.Form.ShowDialog()
} finally {
    $mainWin.Form.Dispose()
    Remove-Module $guiModule -Force -ErrorAction SilentlyContinue
}
