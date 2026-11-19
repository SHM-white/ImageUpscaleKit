param(
    [string]$OriginalPath,
    [string[]]$ResultPaths,
    [string]$ManifestPath,
    [switch]$TestMode
)

function Initialize-IUKComparatorTypes {
    if ('ImageUpscaleKit.UI.ImageComparatorControl' -as [type]) {
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $null = [System.Drawing.Bitmap]
    $null = [System.Windows.Forms.Control]
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
    $refs = @($refMap.Values)

    $csPath = Join-Path $PSScriptRoot 'src\ImageComparator.cs'
    if (-not (Test-Path -LiteralPath $csPath -PathType Leaf)) {
        throw "Comparator C# source not found: $csPath"
    }
    $source = Get-Content -LiteralPath $csPath -Raw -Encoding UTF8
    Add-Type -ReferencedAssemblies $refs -TypeDefinition $source -Language CSharp
}

function New-IUKComparatorPanel {
    param(
        [switch]$ShowFileButtons
    )

    Initialize-IUKComparatorTypes

    $rootPanel = [System.Windows.Forms.Panel]::new()
    $rootPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $toolbar = [System.Windows.Forms.FlowLayoutPanel]::new()
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Top
    $toolbar.AutoSize = $true
    $toolbar.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $toolbar.WrapContents = $true
    $toolbar.Padding = [System.Windows.Forms.Padding]::new(6, 4, 6, 4)
    $toolbar.BackColor = [System.Drawing.Color]::FromArgb(242, 244, 248)

    $ctrl = [ImageUpscaleKit.UI.ImageComparatorControl]::new()
    $ctrl.Dock = [System.Windows.Forms.DockStyle]::Fill

    $statusStrip = [System.Windows.Forms.Panel]::new()
    $statusStrip.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $statusStrip.Height = 26
    $statusStrip.BackColor = [System.Drawing.Color]::FromArgb(236, 239, 245)

    $lblMeta = [System.Windows.Forms.Label]::new()
    $lblMeta.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lblMeta.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblMeta.Padding = [System.Windows.Forms.Padding]::new(8, 0, 8, 0)
    $lblMeta.Text = '就绪：支持鼠标滚轮缩放、左键拖动、数字键 1/2/3 切换对比模式、空格键快速切换原图/结果。'
    $statusStrip.Controls.Add($lblMeta)

    function New-ToolBtn([string]$Text, [int]$Width = 76) {
        $b = [System.Windows.Forms.Button]::new()
        $b.Text = $Text
        $b.Size = [System.Drawing.Size]::new($Width, 26)
        $b.Margin = [System.Windows.Forms.Padding]::new(2, 2, 2, 2)
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
        return $b
    }

    $btnSide = New-ToolBtn '并排对比' 78
    $btnSplit = New-ToolBtn '滑块对比' 78
    $btnRoi = New-ToolBtn '局部放大' 78

    $chkSync = [System.Windows.Forms.CheckBox]::new()
    $chkSync.Text = '同步视图'
    $chkSync.Checked = $true
    $chkSync.AutoSize = $true
    $chkSync.Margin = [System.Windows.Forms.Padding]::new(8, 6, 6, 2)

    $btnFit = New-ToolBtn '适应' 50
    $btn100 = New-ToolBtn '100%' 50
    $btn200 = New-ToolBtn '200%' 50
    $btn400 = New-ToolBtn '400%' 50

    $btnToggle = New-ToolBtn '切换: 对比中' 106

    $chkSharp = [System.Windows.Forms.CheckBox]::new()
    $chkSharp.Text = '像素锐利'
    $chkSharp.Checked = $true
    $chkSharp.AutoSize = $true
    $chkSharp.Margin = [System.Windows.Forms.Padding]::new(6, 6, 6, 2)

    $lblRes = [System.Windows.Forms.Label]::new()
    $lblRes.Text = '结果:'
    $lblRes.AutoSize = $true
    $lblRes.Margin = [System.Windows.Forms.Padding]::new(8, 7, 2, 2)

    $cmbResults = [System.Windows.Forms.ComboBox]::new()
    $cmbResults.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbResults.Width = 175
    $cmbResults.Margin = [System.Windows.Forms.Padding]::new(2, 3, 4, 2)

    $btnLoadOrig = $null
    $btnAddRes = $null
    if ($ShowFileButtons) {
        $btnLoadOrig = New-ToolBtn '导入原图' 78
        $btnAddRes = New-ToolBtn '添加对比图' 86
        $toolbar.Controls.AddRange(@($btnLoadOrig, $btnAddRes))
    }

    $toolbar.Controls.AddRange(@(
        $btnSide, $btnSplit, $btnRoi, $chkSync,
        $btnFit, $btn100, $btn200, $btn400,
        $btnToggle, $chkSharp, $lblRes, $cmbResults
    ))

    # WinForms Z-order: Dock=Fill must be added before Top/Bottom or BringToFront.
    $rootPanel.Controls.Add($ctrl)
    $rootPanel.Controls.Add($toolbar)
    $rootPanel.Controls.Add($statusStrip)

    $state = @{ Syncing = $false }

    $refreshToolbar = {
        $mode = $ctrl.ViewMode
        $activeBg = [System.Drawing.Color]::FromArgb(208, 228, 252)
        $normalBg = [System.Drawing.SystemColors]::Control
        $btnSide.BackColor = if ($mode -eq [ImageUpscaleKit.UI.CompareViewMode]::SideBySide) { $activeBg } else { $normalBg }
        $btnSplit.BackColor = if ($mode -eq [ImageUpscaleKit.UI.CompareViewMode]::SplitSlider) { $activeBg } else { $normalBg }
        $btnRoi.BackColor = if ($mode -eq [ImageUpscaleKit.UI.CompareViewMode]::RoiZoom) { $activeBg } else { $normalBg }

        $chkSync.Checked = $ctrl.SyncViewports
        $chkSync.Enabled = ($mode -eq [ImageUpscaleKit.UI.CompareViewMode]::SideBySide)
        $chkSharp.Checked = $ctrl.PixelPerfectZoom

        switch ($ctrl.OverrideMode) {
            ([ImageUpscaleKit.UI.ImageOverrideMode]::OriginalOnly) { $btnToggle.Text = '仅原图' }
            ([ImageUpscaleKit.UI.ImageOverrideMode]::ResultOnly) { $btnToggle.Text = '仅结果' }
            default { $btnToggle.Text = '对比中' }
        }

        $origText = if ($ctrl.OriginalImage) {
            '原图: {0}x{1} ({2})' -f $ctrl.OriginalImage.OriginalWidth, $ctrl.OriginalImage.OriginalHeight, [ImageUpscaleKit.UI.ImageComparatorControl]::FormatBytes($ctrl.OriginalImage.FileSizeBytes)
        } else { '原图: 未加载' }

        $resImg = $ctrl.ActiveResultImage
        $resText = if ($resImg) {
            $ratio = if ($ctrl.OriginalImage -and $ctrl.OriginalImage.OriginalWidth -gt 0) {
                ' | {0:0.##}x' -f ($resImg.OriginalWidth / [double]$ctrl.OriginalImage.OriginalWidth)
            } else { '' }
            '结果[{0}/{1}]: {2}x{3} ({4}{5})' -f ($ctrl.ActiveResultIndex + 1), $ctrl.ResultCount, $resImg.OriginalWidth, $resImg.OriginalHeight, [ImageUpscaleKit.UI.ImageComparatorControl]::FormatBytes($resImg.FileSizeBytes), $ratio
        } else { '结果: 无' }

        $zoomText = '缩放: {0:F0}%' -f ($ctrl.LeftViewport.Zoom * 100.0)
        $extra = if ($mode -eq [ImageUpscaleKit.UI.CompareViewMode]::SplitSlider) {
            ' | 分割线: {0:F0}%' -f ($ctrl.SplitRatio * 100.0)
        } elseif ($mode -eq [ImageUpscaleKit.UI.CompareViewMode]::RoiZoom) {
            $r = $ctrl.RoiNormalized
            ' | ROI: ({0:F2},{1:F2} {2:F2}x{3:F2})' -f $r.X, $r.Y, $r.Width, $r.Height
        } else { '' }

        $lblMeta.Text = "$origText    |    $resText    |    $zoomText$extra"
    }.GetNewClosure()

    $refreshResultsCombo = {
        $state.Syncing = $true
        try {
            $cmbResults.Items.Clear()
            foreach ($r in $ctrl.Results) {
                $label = if ($r.Label) { $r.Label } else { [IO.Path]::GetFileName($r.FilePath) }
                [void]$cmbResults.Items.Add($label)
            }
            if ($ctrl.ActiveResultIndex -ge 0 -and $ctrl.ActiveResultIndex -lt $cmbResults.Items.Count) {
                $cmbResults.SelectedIndex = $ctrl.ActiveResultIndex
            }
            $cmbResults.Enabled = ($cmbResults.Items.Count -gt 0)
        } finally {
            $state.Syncing = $false
        }
    }.GetNewClosure()

    $btnSide.Add_Click({ $ctrl.OverrideMode = [ImageUpscaleKit.UI.ImageOverrideMode]::None; $ctrl.ViewMode = [ImageUpscaleKit.UI.CompareViewMode]::SideBySide }.GetNewClosure())
    $btnSplit.Add_Click({ $ctrl.OverrideMode = [ImageUpscaleKit.UI.ImageOverrideMode]::None; $ctrl.ViewMode = [ImageUpscaleKit.UI.CompareViewMode]::SplitSlider }.GetNewClosure())
    $btnRoi.Add_Click({ $ctrl.OverrideMode = [ImageUpscaleKit.UI.ImageOverrideMode]::None; $ctrl.ViewMode = [ImageUpscaleKit.UI.CompareViewMode]::RoiZoom }.GetNewClosure())
    $chkSync.Add_CheckedChanged({ $ctrl.SyncViewports = $chkSync.Checked }.GetNewClosure())
    $chkSharp.Add_CheckedChanged({ $ctrl.PixelPerfectZoom = $chkSharp.Checked }.GetNewClosure())
    $btnFit.Add_Click({ $ctrl.FitToWindow() }.GetNewClosure())
    $btn100.Add_Click({ $ctrl.SetZoomPercent(100.0) }.GetNewClosure())
    $btn200.Add_Click({ $ctrl.SetZoomPercent(200.0) }.GetNewClosure())
    $btn400.Add_Click({ $ctrl.SetZoomPercent(400.0) }.GetNewClosure())
    $btnToggle.Add_Click({
        if ($ctrl.OverrideMode -eq [ImageUpscaleKit.UI.ImageOverrideMode]::None) {
            $ctrl.OverrideMode = [ImageUpscaleKit.UI.ImageOverrideMode]::OriginalOnly
        } elseif ($ctrl.OverrideMode -eq [ImageUpscaleKit.UI.ImageOverrideMode]::OriginalOnly) {
            $ctrl.OverrideMode = [ImageUpscaleKit.UI.ImageOverrideMode]::ResultOnly
        } else {
            $ctrl.OverrideMode = [ImageUpscaleKit.UI.ImageOverrideMode]::None
        }
    }.GetNewClosure())
    $cmbResults.Add_SelectedIndexChanged({
        if (-not $state.Syncing -and $cmbResults.SelectedIndex -ge 0) {
            $ctrl.SelectResult($cmbResults.SelectedIndex)
        }
    }.GetNewClosure())

    if ($btnLoadOrig) {
        $btnLoadOrig.Add_Click({
            $dlg = [System.Windows.Forms.OpenFileDialog]::new()
            $dlg.Filter = 'Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp;*.tif;*.tiff|All files|*.*'
            try {
                if ($dlg.ShowDialog($rootPanel.FindForm()) -eq [System.Windows.Forms.DialogResult]::OK) {
                    $ctrl.LoadOriginal($dlg.FileName)
                }
            } finally { $dlg.Dispose() }
        }.GetNewClosure())
    }
    if ($btnAddRes) {
        $btnAddRes.Add_Click({
            $dlg = [System.Windows.Forms.OpenFileDialog]::new()
            $dlg.Filter = 'Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp;*.tif;*.tiff|All files|*.*'
            $dlg.Multiselect = $true
            try {
                if ($dlg.ShowDialog($rootPanel.FindForm()) -eq [System.Windows.Forms.DialogResult]::OK) {
                    foreach ($f in $dlg.FileNames) {
                        $item = [ImageUpscaleKit.UI.ComparatorResultItem]@{
                            Id = [guid]::NewGuid().ToString('N')
                            Label = [IO.Path]::GetFileName($f)
                            FilePath = $f
                        }
                        $ctrl.AddOrUpdateResult($item, $true)
                    }
                }
            } finally { $dlg.Dispose() }
        }.GetNewClosure())
    }

    $ctrl.Add_ViewStateChanged($refreshToolbar)
    $ctrl.Add_SelectedResultChanged($refreshResultsCombo)

    & $refreshResultsCombo
    & $refreshToolbar

    $wrapper = [pscustomobject]@{
        Panel = $rootPanel
        Control = $ctrl
        Toolbar = $toolbar
        StatusLabel = $lblMeta
        ResultSelector = $cmbResults
        ModeButtons = @{ SideBySide = $btnSide; SplitSlider = $btnSplit; RoiZoom = $btnRoi }
        RefreshMetadata = $refreshToolbar
        RefreshResults = $refreshResultsCombo
    }
    $rootPanel.Tag = $wrapper
    return $wrapper
}

function Import-IUKComparisonManifest {
    param(
        [Parameter(Mandatory = $true)] [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Comparison manifest not found: $Path"
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Show-IUKComparatorWindow {
    param(
        [string]$OriginalPath,
        [string[]]$ResultPaths,
        [string]$ManifestPath,
        [switch]$TestMode
    )

    Initialize-IUKComparatorTypes
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'ImageUpscaleKit - 高性能超分图片对比器'
    $form.Size = [System.Drawing.Size]::new(1240, 800)
    $form.MinimumSize = [System.Drawing.Size]::new(760, 500)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 9)

    $comp = New-IUKComparatorPanel -ShowFileButtons
    $form.Controls.Add($comp.Panel)

    $manifestEntries = @()
    if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        $manifest = Import-IUKComparisonManifest -Path $ManifestPath
        $manifestEntries = @($manifest.items)
        if ($manifestEntries.Count -gt 0) {
            $topBar = [System.Windows.Forms.Panel]::new()
            $topBar.Dock = [System.Windows.Forms.DockStyle]::Top
            $topBar.Height = 32
            $topBar.BackColor = [System.Drawing.Color]::FromArgb(228, 232, 240)
            $lbl = [System.Windows.Forms.Label]::new()
            $lbl.Text = '评测样本:'
            $lbl.Location = [System.Drawing.Point]::new(8, 7)
            $lbl.AutoSize = $true
            $cmbEntry = [System.Windows.Forms.ComboBox]::new()
            $cmbEntry.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
            $cmbEntry.Location = [System.Drawing.Point]::new(80, 4)
            $cmbEntry.Width = 420
            foreach ($entry in $manifestEntries) {
                [void]$cmbEntry.Items.Add([string]$entry.name)
            }
            $loadEntry = {
                param($entry)
                if (-not $entry) { return }
                $orig = if ($entry.lr_path -and (Test-Path -LiteralPath $entry.lr_path)) { [string]$entry.lr_path } elseif ($entry.hr_path) { [string]$entry.hr_path } else { '' }
                if ($orig -and (Test-Path -LiteralPath $orig)) {
                    $comp.Control.LoadOriginal($orig)
                }
                $list = [System.Collections.Generic.List[ImageUpscaleKit.UI.ComparatorResultItem]]::new()
                if ($entry.hr_path -and (Test-Path -LiteralPath $entry.hr_path) -and $orig -ne $entry.hr_path) {
                    $hrItem = [ImageUpscaleKit.UI.ComparatorResultItem]@{
                        Id = 'hr_ref'
                        Label = 'HR 参考原图'
                        Engine = 'reference'
                        FilePath = [string]$entry.hr_path
                    }
                    $list.Add($hrItem)
                }
                foreach ($res in @($entry.results)) {
                    if ($res.file_path -and (Test-Path -LiteralPath $res.file_path)) {
                        $item = [ImageUpscaleKit.UI.ComparatorResultItem]@{
                            Id = [string]$res.backend
                            Label = [string]$res.label
                            Engine = [string]$res.backend
                            Model = [string]$res.model
                            FilePath = [string]$res.file_path
                            ElapsedMs = [double]($res.elapsed_ms ?? 0)
                        }
                        $list.Add($item)
                    }
                }
                $comp.Control.SetResults($list, [Math]::Max(0, $list.Count - 1))
                $comp.Control.FitToWindow()
            }.GetNewClosure()
            $cmbEntry.Add_SelectedIndexChanged({
                if ($cmbEntry.SelectedIndex -ge 0 -and $cmbEntry.SelectedIndex -lt $manifestEntries.Count) {
                    & $loadEntry $manifestEntries[$cmbEntry.SelectedIndex]
                }
            }.GetNewClosure())
            $topBar.Controls.Add($lbl)
            $topBar.Controls.Add($cmbEntry)
            $form.Controls.Add($topBar)
            if ($cmbEntry.Items.Count -gt 0) {
                $cmbEntry.SelectedIndex = 0
            }
        }
    } else {
        if ($OriginalPath -and (Test-Path -LiteralPath $OriginalPath -PathType Leaf)) {
            $comp.Control.LoadOriginal($OriginalPath)
        }
        $items = [System.Collections.Generic.List[ImageUpscaleKit.UI.ComparatorResultItem]]::new()
        foreach ($rp in @($ResultPaths)) {
            if ($rp -and (Test-Path -LiteralPath $rp -PathType Leaf)) {
                $items.Add([ImageUpscaleKit.UI.ComparatorResultItem]@{
                    Id = [guid]::NewGuid().ToString('N')
                    Label = [IO.Path]::GetFileName($rp)
                    FilePath = $rp
                })
            }
        }
        if ($items.Count -gt 0) {
            $comp.Control.SetResults($items, 0)
        }
        $comp.Control.FitToWindow()
    }

    if ($TestMode) {
        return [pscustomobject]@{
            Form = $form
            Comparator = $comp
        }
    }

    [void]$form.ShowDialog()
    $form.Dispose()
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($TestMode) {
        $null = Show-IUKComparatorWindow -OriginalPath $OriginalPath -ResultPaths $ResultPaths -ManifestPath $ManifestPath -TestMode
    } else {
        Show-IUKComparatorWindow -OriginalPath $OriginalPath -ResultPaths $ResultPaths -ManifestPath $ManifestPath
    }
}
