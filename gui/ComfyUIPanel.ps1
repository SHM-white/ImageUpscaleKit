$_iukPanelRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command 'Get-IUKConfig' -ErrorAction SilentlyContinue)) {
    . (Join-Path $_iukPanelRoot 'ConfigHelpers.ps1')
}
if (-not (Get-Command 'Test-IUKComfyUIConnection' -ErrorAction SilentlyContinue)) {
    . (Join-Path $_iukPanelRoot 'ComfyUI.ps1')
}

function New-IUKComfyUIPanel {
    param(
        [Parameter(Mandatory = $true)] [string]$Root
    )

    if (-not (Get-Command 'Get-IUKConfig' -ErrorAction SilentlyContinue)) {
        . (Join-Path $Root 'ConfigHelpers.ps1')
    }
    if (-not (Get-Command 'Test-IUKComfyUIConnection' -ErrorAction SilentlyContinue)) {
        . (Join-Path $Root 'ComfyUI.ps1')
    }

    $panel = [System.Windows.Forms.GroupBox]::new()
    $panel.Text = 'ComfyUI 推理后端 (CUDA / Intel XPU)'
    $panel.AutoSize = $false
    $panel.Size = [System.Drawing.Size]::new(334, 472)
    $panel.MinimumSize = [System.Drawing.Size]::new(334, 472)
    $panel.Padding = [System.Windows.Forms.Padding]::new(8, 6, 8, 8)

    $allCfg = Get-IUKConfig -Root $Root
    $presets = @(Get-IUKComfyPresets -Root $Root)

    $grid = [System.Windows.Forms.TableLayoutPanel]::new()
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AutoSize = $false
    $grid.ColumnCount = 3
    $grid.RowCount = 11
    [void]$grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 86))
    [void]$grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 74))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 32))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 30))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 34))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 56))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 32))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 30))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 30))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 32))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 32))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 32))
    [void]$grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    function New-GridLbl([string]$Text) {
        $l = [System.Windows.Forms.Label]::new()
        $l.Text = $Text
        $l.Dock = [System.Windows.Forms.DockStyle]::Fill
        $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $l.Margin = [System.Windows.Forms.Padding]::new(0, 2, 2, 2)
        return $l
    }

    function New-GridBtn([string]$Text, [int]$Height = 25) {
        $b = [System.Windows.Forms.Button]::new()
        $b.Text = $Text
        $b.Dock = [System.Windows.Forms.DockStyle]::Fill
        $b.Height = $Height
        $b.Margin = [System.Windows.Forms.Padding]::new(4, 2, 0, 2)
        return $b
    }

    # Row 0: Instance
    $cmbInst = [System.Windows.Forms.ComboBox]::new()
    $cmbInst.DropDownStyle = 'DropDownList'
    $cmbInst.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cmbInst.Margin = [System.Windows.Forms.Padding]::new(0, 3, 2, 3)
    $btnSaveInst = New-GridBtn '保存'
    $grid.Controls.Add((New-GridLbl '实例配置:'), 0, 0)
    $grid.Controls.Add($cmbInst, 1, 0)
    $grid.Controls.Add($btnSaveInst, 2, 0)

    # Row 1: API URL
    $txtUrl = [System.Windows.Forms.TextBox]::new()
    $txtUrl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtUrl.Margin = [System.Windows.Forms.Padding]::new(0, 3, 0, 3)
    $grid.Controls.Add((New-GridLbl 'API 地址:'), 0, 1)
    $grid.Controls.Add($txtUrl, 1, 1)
    $grid.SetColumnSpan($txtUrl, 2)

    # Row 2: Action buttons strip (Test, Start, Logs)
    $actionFlow = [System.Windows.Forms.TableLayoutPanel]::new()
    $actionFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionFlow.Height = 30
    $actionFlow.ColumnCount = 3
    $actionFlow.RowCount = 1
    $actionFlow.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 2)
    [void]$actionFlow.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 36))
    [void]$actionFlow.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 36))
    [void]$actionFlow.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 28))
    $btnTestConn = [System.Windows.Forms.Button]::new(); $btnTestConn.Text = '测试连接'; $btnTestConn.Dock = 'Fill'; $btnTestConn.Margin = [System.Windows.Forms.Padding]::new(0, 1, 3, 1)
    $btnStartComfy = [System.Windows.Forms.Button]::new(); $btnStartComfy.Text = '启动本地'; $btnStartComfy.Dock = 'Fill'; $btnStartComfy.Margin = [System.Windows.Forms.Padding]::new(2, 1, 3, 1)
    $btnOpenComfyLog = [System.Windows.Forms.Button]::new(); $btnOpenComfyLog.Text = '日志'; $btnOpenComfyLog.Dock = 'Fill'; $btnOpenComfyLog.Margin = [System.Windows.Forms.Padding]::new(2, 1, 0, 1)
    $actionFlow.Controls.Add($btnTestConn, 0, 0)
    $actionFlow.Controls.Add($btnStartComfy, 1, 0)
    $actionFlow.Controls.Add($btnOpenComfyLog, 2, 0)
    $grid.Controls.Add($actionFlow, 0, 2)
    $grid.SetColumnSpan($actionFlow, 3)

    # Row 3: Connection status multiline readout (never clips lines)
    $txtConnStatus = [System.Windows.Forms.TextBox]::new()
    $txtConnStatus.Multiline = $true
    $txtConnStatus.ReadOnly = $true
    $txtConnStatus.WordWrap = $true
    $txtConnStatus.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtConnStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtConnStatus.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 253)
    $txtConnStatus.ForeColor = [System.Drawing.Color]::DimGray
    $txtConnStatus.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtConnStatus.Height = 46
    $txtConnStatus.TabStop = $false
    $txtConnStatus.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 4)
    $txtConnStatus.Text = '状态: 未连接（不影响传统后端使用）'
    $grid.Controls.Add($txtConnStatus, 0, 3)
    $grid.SetColumnSpan($txtConnStatus, 3)

    # Row 4: Install dir
    $txtDir = [System.Windows.Forms.TextBox]::new()
    $txtDir.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtDir.Margin = [System.Windows.Forms.Padding]::new(0, 3, 2, 3)
    $btnPickDir = New-GridBtn '识别'
    $grid.Controls.Add((New-GridLbl '安装目录:'), 0, 4)
    $grid.Controls.Add($txtDir, 1, 4)
    $grid.Controls.Add($btnPickDir, 2, 4)

    # Row 5: Python / script
    $txtPython = [System.Windows.Forms.TextBox]::new()
    $txtPython.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtPython.Margin = [System.Windows.Forms.Padding]::new(0, 3, 0, 3)
    $grid.Controls.Add((New-GridLbl 'Python/脚本:'), 0, 5)
    $grid.Controls.Add($txtPython, 1, 5)
    $grid.SetColumnSpan($txtPython, 2)

    # Row 6: Startup args
    $txtArgs = [System.Windows.Forms.TextBox]::new()
    $txtArgs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtArgs.Margin = [System.Windows.Forms.Padding]::new(0, 3, 0, 3)
    $grid.Controls.Add((New-GridLbl '启动参数:'), 0, 6)
    $grid.Controls.Add($txtArgs, 1, 6)
    $grid.SetColumnSpan($txtArgs, 2)

    # Row 7: Preset
    $cmbPreset = [System.Windows.Forms.ComboBox]::new()
    $cmbPreset.DropDownStyle = 'DropDownList'
    $cmbPreset.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cmbPreset.Margin = [System.Windows.Forms.Padding]::new(0, 3, 0, 3)
    $grid.Controls.Add((New-GridLbl '预设方案:'), 0, 7)
    $grid.Controls.Add($cmbPreset, 1, 7)
    $grid.SetColumnSpan($cmbPreset, 2)

    # Row 8: Live Upscale Model override + Weight Manager button
    $cmbUpscaleModel = [System.Windows.Forms.ComboBox]::new()
    $cmbUpscaleModel.DropDownStyle = 'DropDownList'
    $cmbUpscaleModel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cmbUpscaleModel.Margin = [System.Windows.Forms.Padding]::new(0, 3, 2, 3)
    [void]$cmbUpscaleModel.Items.Add('(使用预设默认)')
    $cmbUpscaleModel.SelectedIndex = 0
    $btnModelMgr = New-GridBtn '权重管理'
    $grid.Controls.Add((New-GridLbl '超分模型:'), 0, 8)
    $grid.Controls.Add($cmbUpscaleModel, 1, 8)
    $grid.Controls.Add($btnModelMgr, 2, 8)

    # Row 9: Custom workflow JSON
    $txtWf = [System.Windows.Forms.TextBox]::new()
    $txtWf.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtWf.Margin = [System.Windows.Forms.Padding]::new(0, 3, 2, 3)
    $btnPickWf = New-GridBtn '导入'
    $grid.Controls.Add((New-GridLbl '自定义JSON:'), 0, 9)
    $grid.Controls.Add($txtWf, 1, 9)
    $grid.Controls.Add($btnPickWf, 2, 9)

    # Row 10: Preset description multiline readout (never clips)
    $txtPresetInfo = [System.Windows.Forms.TextBox]::new()
    $txtPresetInfo.Multiline = $true
    $txtPresetInfo.ReadOnly = $true
    $txtPresetInfo.WordWrap = $true
    $txtPresetInfo.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtPresetInfo.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtPresetInfo.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 253)
    $txtPresetInfo.ForeColor = [System.Drawing.Color]::FromArgb(65, 74, 88)
    $txtPresetInfo.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtPresetInfo.Height = 68
    $txtPresetInfo.TabStop = $false
    $txtPresetInfo.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 2)
    $grid.Controls.Add($txtPresetInfo, 0, 10)
    $grid.SetColumnSpan($txtPresetInfo, 3)

    $panel.Controls.Add($grid)

    $ctx = @{
        Root = $Root
        LocalCfg = $allCfg.Local
        Presets = $presets
        CmbInst = $cmbInst
        TxtUrl = $txtUrl
        LblConnStatus = $txtConnStatus
        TxtDir = $txtDir
        TxtPython = $txtPython
        TxtArgs = $txtArgs
        CmbPreset = $cmbPreset
        CmbUpscaleModel = $cmbUpscaleModel
        TxtWf = $txtWf
        LblPresetInfo = $txtPresetInfo
        LastLogFile = ''
    }

    foreach ($inst in @($ctx.LocalCfg.instances)) {
        [void]$cmbInst.Items.Add([string]$inst.name)
    }
    if ($cmbInst.Items.Contains([string]$ctx.LocalCfg.active_instance)) {
        $cmbInst.SelectedItem = [string]$ctx.LocalCfg.active_instance
    } elseif ($cmbInst.Items.Count -gt 0) {
        $cmbInst.SelectedIndex = 0
    }

    foreach ($p in $presets) {
        [void]$cmbPreset.Items.Add($p.Id)
    }
    if ($cmbPreset.Items.Count -gt 0) {
        $cmbPreset.SelectedIndex = 0
    }

    $populateAvailableModels = {
        param($c, $ObjectInfo)
        $prev = [string]$c.CmbUpscaleModel.Text
        $c.CmbUpscaleModel.BeginUpdate()
        try {
            $c.CmbUpscaleModel.Items.Clear()
            [void]$c.CmbUpscaleModel.Items.Add('(使用预设默认)')
            $avail = Get-IUKComfyAvailableModels -ObjectInfo $ObjectInfo
            foreach ($m in @($avail.UpscaleModels)) {
                [void]$c.CmbUpscaleModel.Items.Add([string]$m)
            }
            if ($prev -and $c.CmbUpscaleModel.Items.Contains($prev)) {
                $c.CmbUpscaleModel.SelectedItem = $prev
            } else {
                $c.CmbUpscaleModel.SelectedIndex = 0
            }
            return @($avail.UpscaleModels).Count
        } finally {
            $c.CmbUpscaleModel.EndUpdate()
        }
    }
    $ctx.PopulateAvailableModels = $populateAvailableModels

    $syncInstToUi = {
        param($c)
        $inst = Get-IUKActiveComfyInstance -LocalCfg $c.LocalCfg -InstanceName $c.CmbInst.Text
        if ($inst) {
            $c.TxtUrl.Text = [string]$inst.api_url
            $c.TxtDir.Text = [string]$inst.install_dir
            $c.TxtPython.Text = if ($inst.startup_script) { [string]$inst.startup_script } else { [string]$inst.python_path }
            $c.TxtArgs.Text = [string]$inst.startup_args
        }
    }
    $updatePresetInfo = {
        param($c)
        $selId = $c.CmbPreset.Text
        $p = @($c.Presets | Where-Object { $_.Id -eq $selId }) | Select-Object -First 1
        if ($p) {
            $c.LblPresetInfo.Text = "$($p.Name)`r`n$($p.Description)"
        } else {
            $c.LblPresetInfo.Text = '可选择内置工作流预设，或导入自定义 ComfyUI API JSON。'
        }
    }
    & $syncInstToUi $ctx
    & $updatePresetInfo $ctx

    foreach ($ctrl in @($cmbInst, $btnSaveInst, $btnTestConn, $btnStartComfy, $btnOpenComfyLog, $btnPickDir, $cmbPreset, $btnModelMgr, $btnPickWf)) {
        $ctrl.Tag = $ctx
    }

    $cmbInst.Add_SelectedIndexChanged({
        param($sender, $e)
        $c = $sender.Tag
        $inst = Get-IUKActiveComfyInstance -LocalCfg $c.LocalCfg -InstanceName $c.CmbInst.Text
        if ($inst) {
            $c.TxtUrl.Text = [string]$inst.api_url
            $c.TxtDir.Text = [string]$inst.install_dir
            $c.TxtPython.Text = if ($inst.startup_script) { [string]$inst.startup_script } else { [string]$inst.python_path }
            $c.TxtArgs.Text = [string]$inst.startup_args
        }
    })

    $ctx.SaveInstance = {
        param($c, [switch]$InstallOnly)
        $name = if ($c.CmbInst.Text) { $c.CmbInst.Text } else { 'default' }
        $localCfg = (Get-IUKConfig -Root $c.Root).Local
        $inst = Get-IUKActiveComfyInstance -LocalCfg $localCfg -InstanceName $name
        $inst.name = $name
        $inst.install_dir = $c.TxtDir.Text.Trim()
        $inst.mode = if ($inst.install_dir) { 'managed' } else { 'connect' }
        $pyOrScript = $c.TxtPython.Text.Trim()
        $isBat = ($pyOrScript -match '\.(bat|cmd|py)$')
        $inst.python_path = if ($isBat) { '' } else { $pyOrScript }
        $inst.startup_script = if ($isBat) { $pyOrScript } else { '' }
        if (-not $InstallOnly) {
            $inst.api_url = $c.TxtUrl.Text.Trim().TrimEnd('/')
            $inst.startup_args = $c.TxtArgs.Text.Trim()
        }
        $updated = Set-IUKComfyInstance -LocalCfg $localCfg -Instance $inst -SetActive
        $c.LocalCfg = Save-IUKLocalConfig -LocalCfg $updated -Root $c.Root -ErrorAction Stop
    }

    $btnSaveInst.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        try {
            & $c.SaveInstance $c
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            $c.LblConnStatus.Text = "已保存本机配置 ($($c.LocalCfg.active_instance) -> config.local.json)"
        } catch {
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $c.LblConnStatus.Text = "保存本机配置失败：$($_.Exception.Message)"
        }
    })

    $btnTestConn.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        $res = Test-IUKComfyUIConnection -ApiUrl $c.TxtUrl.Text.Trim() -TimeoutSec 4 -IncludeObjectInfo
        if ($res.Connected) {
            $umCount = & $c.PopulateAvailableModels $c $res.ObjectInfo
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            $c.LblConnStatus.Text = "已连接 [$($res.BackendFamily)] $($res.PrimaryDeviceName)`r`nVRAM: $([math]::Round($res.VramFreeMb))/$(([math]::Round($res.VramTotalMb))) MB | 节点: $($res.NodeCount) | 超分模型: $umCount 个"
        } else {
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $c.LblConnStatus.Text = "未连接: $($res.Error)"
        }
    })

    $btnPickDir.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        $d = [System.Windows.Forms.FolderBrowserDialog]::new()
        try {
            if ($c.TxtDir.Text -and (Test-Path -LiteralPath $c.TxtDir.Text -PathType Container)) { $d.SelectedPath = $c.TxtDir.Text }
            if ($d.ShowDialog($sender.FindForm()) -eq [System.Windows.Forms.DialogResult]::OK) {
                $previousDir = $c.TxtDir.Text.Trim()
                $c.TxtDir.Text = $d.SelectedPath
                $det = Find-IUKComfyUIInstall -InstallDir $d.SelectedPath
                if ($det.PythonPath) { $c.TxtPython.Text = $det.PythonPath }
                elseif ($det.Launchers.Count -gt 0) { $c.TxtPython.Text = $det.Launchers[0] }
                elseif ($c.TxtDir.Text -ne $previousDir) { $c.TxtPython.Clear() }
                & $c.SaveInstance $c -InstallOnly
                $c.LblConnStatus.ForeColor = if ($det.Found) { [System.Drawing.Color]::RoyalBlue } else { [System.Drawing.Color]::DarkOrange }
                $c.LblConnStatus.Text = "已保存安装目录`r`n$($det.Message)"
            }
        } catch {
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $c.LblConnStatus.Text = "识别或保存安装目录失败：$($_.Exception.Message)"
        } finally { $d.Dispose() }
    })

    $btnStartComfy.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        try {
            $pyOrScript = $c.TxtPython.Text.Trim()
            $isBat = ($pyOrScript -match '\.(bat|cmd|py)$')
            $instObj = [pscustomobject]@{
                name = if ($c.CmbInst.Text) { $c.CmbInst.Text } else { 'default' }
                mode = 'managed'
                api_url = $c.TxtUrl.Text.Trim().TrimEnd('/')
                install_dir = $c.TxtDir.Text.Trim()
                python_path = if ($isBat) { '' } else { $pyOrScript }
                startup_script = if ($isBat) { $pyOrScript } else { '' }
                startup_args = $c.TxtArgs.Text.Trim()
            }
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::RoyalBlue
            $c.LblConnStatus.Text = '正在启动并等待 ComfyUI API 就绪...'
            $sender.FindForm().Update()
            $started = Start-IUKComfyUIInstance -Instance $instObj -WaitReadySec 45 -Root $c.Root
            $c.LastLogFile = $started.LogFile
            $conn = $started.ConnectionInfo
            $objInfo = $conn.ObjectInfo
            if (-not $objInfo) {
                try { $objInfo = Get-IUKComfyUIObjectInfo -ApiUrl $c.TxtUrl.Text.Trim() -ForceRefresh } catch {}
            }
            $umCount = & $c.PopulateAvailableModels $c $objInfo
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            $c.LblConnStatus.Text = "已就绪 [$($conn.BackendFamily)] $($conn.PrimaryDeviceName)`r`n节点: $($conn.NodeCount) | 超分模型: $umCount 个"
        } catch {
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $c.LblConnStatus.Text = $_.Exception.Message
        }
    })

    $btnOpenComfyLog.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        $logDir = Join-Path $c.Root 'logs'
        if ($c.LastLogFile -and (Test-Path -LiteralPath $c.LastLogFile)) {
            Start-Process notepad.exe $c.LastLogFile
        } else {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Start-Process explorer.exe $logDir
        }
    })

    $cmbPreset.Add_SelectedIndexChanged({
        param($sender, $e)
        $c = $sender.Tag
        $p = @($c.Presets | Where-Object { $_.Id -eq $c.CmbPreset.Text }) | Select-Object -First 1
        if ($p) { $c.LblPresetInfo.Text = "$($p.Name)`r`n$($p.Description)" }
    })

    $btnModelMgr.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        if (-not (Get-Command 'Show-IUKModelManagerDialog' -ErrorAction SilentlyContinue)) {
            $dlgPath = Join-Path $c.Root 'gui\ModelManagerDialog.ps1'
            if (Test-Path -LiteralPath $dlgPath -PathType Leaf) {
                . $dlgPath
            }
        }
        if (Get-Command 'Show-IUKModelManagerDialog' -ErrorAction SilentlyContinue) {
            Show-IUKModelManagerDialog -Root $c.Root -ComfyInstallDir $c.TxtDir.Text.Trim() -OwnerForm $sender.FindForm()
            $probe = Test-IUKComfyUIConnection -ApiUrl $c.TxtUrl.Text.Trim() -TimeoutSec 3 -IncludeObjectInfo
            if ($probe.Connected) {
                $umCount = & $c.PopulateAvailableModels $c $probe.ObjectInfo
                $c.LblConnStatus.ForeColor = [System.Drawing.Color]::DarkGreen
                $c.LblConnStatus.Text = "已连接 [$($probe.BackendFamily)] $($probe.PrimaryDeviceName)`r`n节点: $($probe.NodeCount) | 超分模型: $umCount 个"
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show($sender.FindForm(), '当前分支未包含 ModelManagerDialog.ps1，请使用 ModelManager.ps1 或合并 PR #5。', '权重管理') | Out-Null
        }
    })

    $btnPickWf.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        $d = [System.Windows.Forms.OpenFileDialog]::new()
        $d.Filter = 'ComfyUI API Workflow JSON|*.json|All files|*.*'
        try {
            if ($d.ShowDialog($sender.FindForm()) -eq [System.Windows.Forms.DialogResult]::OK) {
                $c.TxtWf.Text = $d.FileName
            }
        } finally { $d.Dispose() }
    })

    $refreshModels = {
        $probe = Test-IUKComfyUIConnection -ApiUrl $ctx.TxtUrl.Text.Trim() -TimeoutSec 3 -IncludeObjectInfo
        if ($probe.Connected) {
            return (& $ctx.PopulateAvailableModels $ctx $probe.ObjectInfo)
        }
        return 0
    }.GetNewClosure()

    $getOptions = {
        $opts = @{
            ComfyEndpoint = $ctx.TxtUrl.Text.Trim()
            ComfyInstance = $ctx.CmbInst.Text
            ComfyPreset = if ($ctx.TxtWf.Text.Trim()) { '' } else { $ctx.CmbPreset.Text }
            ComfyWorkflow = $ctx.TxtWf.Text.Trim()
        }
        $selModel = $ctx.CmbUpscaleModel.Text.Trim()
        if ($selModel -and $selModel -ne '(使用预设默认)') {
            $opts.ComfyParams = @{ upscale_model = $selModel }
        }
        return $opts
    }.GetNewClosure()

    $selectPreset = {
        param([string]$PresetId)
        if ($ctx.CmbPreset.Items.Contains($PresetId)) {
            $ctx.CmbPreset.SelectedItem = $PresetId
            $ctx.TxtWf.Clear()
            $ctx.CmbUpscaleModel.SelectedIndex = 0
        }
    }.GetNewClosure()

    return [pscustomobject]@{
        Panel = $panel
        Context = $ctx
        GetOptions = $getOptions
        SelectPreset = $selectPreset
        RefreshModels = $refreshModels
    }
}
