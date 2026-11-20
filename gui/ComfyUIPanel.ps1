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
    $panel.Size = [System.Drawing.Size]::new(286, 368)

    $allCfg = Get-IUKConfig -Root $Root
    $presets = @(Get-IUKComfyPresets -Root $Root)

    $lblInst = [System.Windows.Forms.Label]::new(); $lblInst.Text = '实例配置:'; $lblInst.Location = [System.Drawing.Point]::new(10, 22); $lblInst.Size = [System.Drawing.Size]::new(64, 22)
    $cmbInst = [System.Windows.Forms.ComboBox]::new(); $cmbInst.DropDownStyle = 'DropDownList'; $cmbInst.Location = [System.Drawing.Point]::new(76, 18); $cmbInst.Size = [System.Drawing.Size]::new(140, 24)
    $btnSaveInst = [System.Windows.Forms.Button]::new(); $btnSaveInst.Text = '保存'; $btnSaveInst.Location = [System.Drawing.Point]::new(222, 17); $btnSaveInst.Size = [System.Drawing.Size]::new(54, 26)

    $lblUrl = [System.Windows.Forms.Label]::new(); $lblUrl.Text = 'API 地址:'; $lblUrl.Location = [System.Drawing.Point]::new(10, 52); $lblUrl.Size = [System.Drawing.Size]::new(64, 22)
    $txtUrl = [System.Windows.Forms.TextBox]::new(); $txtUrl.Location = [System.Drawing.Point]::new(76, 48); $txtUrl.Size = [System.Drawing.Size]::new(200, 24)

    $btnTestConn = [System.Windows.Forms.Button]::new(); $btnTestConn.Text = '测试连接'; $btnTestConn.Location = [System.Drawing.Point]::new(10, 78); $btnTestConn.Size = [System.Drawing.Size]::new(86, 26)
    $btnStartComfy = [System.Windows.Forms.Button]::new(); $btnStartComfy.Text = '启动本地'; $btnStartComfy.Location = [System.Drawing.Point]::new(102, 78); $btnStartComfy.Size = [System.Drawing.Size]::new(84, 26)
    $btnOpenComfyLog = [System.Windows.Forms.Button]::new(); $btnOpenComfyLog.Text = '日志'; $btnOpenComfyLog.Location = [System.Drawing.Point]::new(192, 78); $btnOpenComfyLog.Size = [System.Drawing.Size]::new(84, 26)

    $lblConnStatus = [System.Windows.Forms.Label]::new()
    $lblConnStatus.Text = '状态: 未连接（不影响传统后端使用）'
    $lblConnStatus.Location = [System.Drawing.Point]::new(10, 108)
    $lblConnStatus.Size = [System.Drawing.Size]::new(266, 36)
    $lblConnStatus.ForeColor = [System.Drawing.Color]::DimGray

    $lblDir = [System.Windows.Forms.Label]::new(); $lblDir.Text = '安装目录:'; $lblDir.Location = [System.Drawing.Point]::new(10, 148); $lblDir.Size = [System.Drawing.Size]::new(64, 22)
    $txtDir = [System.Windows.Forms.TextBox]::new(); $txtDir.Location = [System.Drawing.Point]::new(76, 144); $txtDir.Size = [System.Drawing.Size]::new(140, 24)
    $btnPickDir = [System.Windows.Forms.Button]::new(); $btnPickDir.Text = '识别'; $btnPickDir.Location = [System.Drawing.Point]::new(222, 143); $btnPickDir.Size = [System.Drawing.Size]::new(54, 26)

    $lblPy = [System.Windows.Forms.Label]::new(); $lblPy.Text = 'Python/脚本:'; $lblPy.Location = [System.Drawing.Point]::new(10, 178); $lblPy.Size = [System.Drawing.Size]::new(76, 22)
    $txtPython = [System.Windows.Forms.TextBox]::new(); $txtPython.Location = [System.Drawing.Point]::new(88, 174); $txtPython.Size = [System.Drawing.Size]::new(188, 24)

    $lblArgs = [System.Windows.Forms.Label]::new(); $lblArgs.Text = '启动参数:'; $lblArgs.Location = [System.Drawing.Point]::new(10, 208); $lblArgs.Size = [System.Drawing.Size]::new(64, 22)
    $txtArgs = [System.Windows.Forms.TextBox]::new(); $txtArgs.Location = [System.Drawing.Point]::new(76, 204); $txtArgs.Size = [System.Drawing.Size]::new(200, 24)

    $lblPreset = [System.Windows.Forms.Label]::new(); $lblPreset.Text = '预设方案:'; $lblPreset.Location = [System.Drawing.Point]::new(10, 240); $lblPreset.Size = [System.Drawing.Size]::new(64, 22)
    $cmbPreset = [System.Windows.Forms.ComboBox]::new(); $cmbPreset.DropDownStyle = 'DropDownList'; $cmbPreset.Location = [System.Drawing.Point]::new(76, 236); $cmbPreset.Size = [System.Drawing.Size]::new(200, 24)

    $lblWf = [System.Windows.Forms.Label]::new(); $lblWf.Text = '自定义JSON:'; $lblWf.Location = [System.Drawing.Point]::new(10, 272); $lblWf.Size = [System.Drawing.Size]::new(72, 22)
    $txtWf = [System.Windows.Forms.TextBox]::new(); $txtWf.Location = [System.Drawing.Point]::new(84, 268); $txtWf.Size = [System.Drawing.Size]::new(136, 24)
    $btnPickWf = [System.Windows.Forms.Button]::new(); $btnPickWf.Text = '导入'; $btnPickWf.Location = [System.Drawing.Point]::new(224, 267); $btnPickWf.Size = [System.Drawing.Size]::new(52, 26)

    $lblPresetInfo = [System.Windows.Forms.Label]::new()
    $lblPresetInfo.Location = [System.Drawing.Point]::new(10, 300)
    $lblPresetInfo.Size = [System.Drawing.Size]::new(266, 58)
    $lblPresetInfo.ForeColor = [System.Drawing.Color]::DimGray

    $panel.Controls.AddRange(@(
        $lblInst, $cmbInst, $btnSaveInst,
        $lblUrl, $txtUrl,
        $btnTestConn, $btnStartComfy, $btnOpenComfyLog,
        $lblConnStatus,
        $lblDir, $txtDir, $btnPickDir,
        $lblPy, $txtPython,
        $lblArgs, $txtArgs,
        $lblPreset, $cmbPreset,
        $lblWf, $txtWf, $btnPickWf,
        $lblPresetInfo
    ))

    $ctx = @{
        Root = $Root
        LocalCfg = $allCfg.Local
        Presets = $presets
        CmbInst = $cmbInst
        TxtUrl = $txtUrl
        LblConnStatus = $lblConnStatus
        TxtDir = $txtDir
        TxtPython = $txtPython
        TxtArgs = $txtArgs
        CmbPreset = $cmbPreset
        TxtWf = $txtWf
        LblPresetInfo = $lblPresetInfo
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

    foreach ($ctrl in @($cmbInst, $btnSaveInst, $btnTestConn, $btnStartComfy, $btnOpenComfyLog, $btnPickDir, $cmbPreset, $btnPickWf)) {
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

    $btnSaveInst.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        $name = if ($c.CmbInst.Text) { $c.CmbInst.Text } else { 'default' }
        $pyOrScript = $c.TxtPython.Text.Trim()
        $isBat = ($pyOrScript -match '\.(bat|cmd|py)$')
        $instObj = [pscustomobject]@{
            name = $name
            mode = if ($c.TxtDir.Text.Trim()) { 'managed' } else { 'connect' }
            api_url = $c.TxtUrl.Text.Trim().TrimEnd('/')
            install_dir = $c.TxtDir.Text.Trim()
            python_path = if ($isBat) { '' } else { $pyOrScript }
            startup_script = if ($isBat) { $pyOrScript } else { '' }
            startup_args = $c.TxtArgs.Text.Trim()
            gpu_hint = 'auto'
            auto_connect = $false
        }
        $c.LocalCfg = Set-IUKComfyInstance -LocalCfg $c.LocalCfg -Instance $instObj -SetActive
        $c.LocalCfg = Save-IUKLocalConfig -LocalCfg $c.LocalCfg -Root $c.Root
        $c.LblConnStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        $c.LblConnStatus.Text = "已保存本机配置 ($name -> config.local.json)"
    })

    $btnTestConn.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        $res = Test-IUKComfyUIConnection -ApiUrl $c.TxtUrl.Text.Trim() -TimeoutSec 4
        if ($res.Connected) {
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            $c.LblConnStatus.Text = "已连接 [$($res.BackendFamily)] $($res.PrimaryDeviceName)`r`nVRAM: $([math]::Round($res.VramFreeMb))/$(([math]::Round($res.VramTotalMb))) MB | 节点: $($res.NodeCount)"
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
                $c.TxtDir.Text = $d.SelectedPath
                $det = Find-IUKComfyUIInstall -InstallDir $d.SelectedPath
                if ($det.PythonPath) { $c.TxtPython.Text = $det.PythonPath }
                elseif ($det.Launchers.Count -gt 0) { $c.TxtPython.Text = $det.Launchers[0] }
                $c.LblConnStatus.ForeColor = if ($det.Found) { [System.Drawing.Color]::RoyalBlue } else { [System.Drawing.Color]::DarkOrange }
                $c.LblConnStatus.Text = $det.Message
            }
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
            $c.LblConnStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            $c.LblConnStatus.Text = "已就绪 [$($conn.BackendFamily)] $($conn.PrimaryDeviceName) | 节点: $($conn.NodeCount)"
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

    $getOptions = {
        return @{
            ComfyEndpoint = $ctx.TxtUrl.Text.Trim()
            ComfyInstance = $ctx.CmbInst.Text
            ComfyPreset = if ($ctx.TxtWf.Text.Trim()) { '' } else { $ctx.CmbPreset.Text }
            ComfyWorkflow = $ctx.TxtWf.Text.Trim()
        }
    }.GetNewClosure()

    $selectPreset = {
        param([string]$PresetId)
        if ($ctx.CmbPreset.Items.Contains($PresetId)) {
            $ctx.CmbPreset.SelectedItem = $PresetId
            $ctx.TxtWf.Clear()
        }
    }.GetNewClosure()

    return [pscustomobject]@{
        Panel = $panel
        Context = $ctx
        GetOptions = $getOptions
        SelectPreset = $selectPreset
    }
}
