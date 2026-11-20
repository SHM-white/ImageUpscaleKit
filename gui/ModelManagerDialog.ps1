$_iukMmRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command 'Get-IUKModelStatus' -ErrorAction SilentlyContinue)) {
    . (Join-Path $_iukMmRoot 'ModelManager.ps1')
}
$_iukMmCfgHelpers = Join-Path $_iukMmRoot 'ConfigHelpers.ps1'
if ((Test-Path -LiteralPath $_iukMmCfgHelpers -PathType Leaf) -and -not (Get-Command 'Get-IUKConfig' -ErrorAction SilentlyContinue)) {
    . $_iukMmCfgHelpers
}
$_iukMmQueueHelper = Join-Path $_iukMmRoot 'src\BatchQueue.ps1'
if ((Test-Path -LiteralPath $_iukMmQueueHelper -PathType Leaf) -and -not ('ImageUpscaleKit.Execution.IukAsyncProcessRunner' -as [type])) {
    try {
        . $_iukMmQueueHelper
        Initialize-IUKAsyncRunnerTypes
    } catch {}
}

function Show-IUKModelManagerDialog {
    param(
        [Parameter(Mandatory = $true)] [string]$Root,
        [string]$ComfyInstallDir = '',
        $OwnerForm = $null,
        [switch]$TestMode
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if (-not $ComfyInstallDir -and (Get-Command 'Get-IUKConfig' -ErrorAction SilentlyContinue)) {
        try {
            $allCfg = Get-IUKConfig -Root $Root
            $inst = Get-IUKActiveComfyInstance -LocalCfg $allCfg.Local
            if ($inst -and $inst.install_dir) { $ComfyInstallDir = [string]$inst.install_dir }
        } catch {}
    }

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'ImageUpscaleKit - 权重 / 模型按需下载与校验'
    $form.Size = [System.Drawing.Size]::new(960, 580)
    $form.MinimumSize = [System.Drawing.Size]::new(760, 480)
    $form.StartPosition = if ($null -ne $OwnerForm) { [System.Windows.Forms.FormStartPosition]::CenterParent } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 9)

    # Top bar: ComfyUI directory & actions
    $topBar = [System.Windows.Forms.Panel]::new()
    $topBar.Dock = [System.Windows.Forms.DockStyle]::Top
    $topBar.Height = 44
    $topBar.Padding = [System.Windows.Forms.Padding]::new(10, 8, 10, 6)
    $topBar.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    $lblComfyDir = [System.Windows.Forms.Label]::new()
    $lblComfyDir.Text = 'ComfyUI 目录:'
    $lblComfyDir.Location = [System.Drawing.Point]::new(10, 11)
    $lblComfyDir.Size = [System.Drawing.Size]::new(86, 22)

    $txtComfyDir = [System.Windows.Forms.TextBox]::new()
    $txtComfyDir.Location = [System.Drawing.Point]::new(100, 9)
    $txtComfyDir.Size = [System.Drawing.Size]::new(520, 24)
    $txtComfyDir.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $txtComfyDir.Text = [string]$ComfyInstallDir

    $btnBrowseComfy = [System.Windows.Forms.Button]::new()
    $btnBrowseComfy.Text = '浏览...'
    $btnBrowseComfy.Location = [System.Drawing.Point]::new(628, 8)
    $btnBrowseComfy.Size = [System.Drawing.Size]::new(70, 26)
    $btnBrowseComfy.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $btnRefresh = [System.Windows.Forms.Button]::new()
    $btnRefresh.Text = '刷新状态'
    $btnRefresh.Location = [System.Drawing.Point]::new(704, 8)
    $btnRefresh.Size = [System.Drawing.Size]::new(78, 26)
    $btnRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $btnOpenFolder = [System.Windows.Forms.Button]::new()
    $btnOpenFolder.Text = '打开模型目录'
    $btnOpenFolder.Location = [System.Drawing.Point]::new(788, 8)
    $btnOpenFolder.Size = [System.Drawing.Size]::new(96, 26)
    $btnOpenFolder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $topBar.Controls.AddRange(@($lblComfyDir, $txtComfyDir, $btnBrowseComfy, $btnRefresh, $btnOpenFolder))

    # Center ListView
    $lv = [System.Windows.Forms.ListView]::new()
    $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.GridLines = $true
    $lv.HideSelection = $false
    [void]$lv.Columns.Add('模型名称', 220)
    [void]$lv.Columns.Add('系列', 76)
    [void]$lv.Columns.Add('倍率', 56)
    [void]$lv.Columns.Add('状态', 86)
    [void]$lv.Columns.Add('大小', 76)
    [void]$lv.Columns.Add('开源/使用许可', 148)
    [void]$lv.Columns.Add('文件名', 250)

    # Bottom panel: Details + Buttons + Progress + Log
    $bottomPanel = [System.Windows.Forms.Panel]::new()
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottomPanel.Height = 204
    $bottomPanel.Padding = [System.Windows.Forms.Padding]::new(10, 6, 10, 8)
    $bottomPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    $lblDetail = [System.Windows.Forms.Label]::new()
    $lblDetail.Location = [System.Drawing.Point]::new(10, 6)
    $lblDetail.Size = [System.Drawing.Size]::new(922, 42)
    $lblDetail.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $lblDetail.Text = '请在列表中选择一个模型或工具包查看下载来源、校验哈希及授权说明。'

    $btnRow = [System.Windows.Forms.FlowLayoutPanel]::new()
    $btnRow.Location = [System.Drawing.Point]::new(10, 52)
    $btnRow.Size = [System.Drawing.Size]::new(922, 34)
    $btnRow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnRow.WrapContents = $false

    $btnDownload = [System.Windows.Forms.Button]::new()
    $btnDownload.Text = '下载并安装选中模型'
    $btnDownload.Size = [System.Drawing.Size]::new(150, 28)
    $btnDownload.BackColor = [System.Drawing.Color]::FromArgb(30, 120, 215)
    $btnDownload.ForeColor = [System.Drawing.Color]::White
    $btnDownload.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    $btnOpenUrl = [System.Windows.Forms.Button]::new()
    $btnOpenUrl.Text = '打开下载页 (浏览器)'
    $btnOpenUrl.Size = [System.Drawing.Size]::new(138, 28)

    $btnCancelDl = [System.Windows.Forms.Button]::new()
    $btnCancelDl.Text = '取消下载'
    $btnCancelDl.Size = [System.Drawing.Size]::new(86, 28)
    $btnCancelDl.Enabled = $false

    $btnClose = [System.Windows.Forms.Button]::new()
    $btnClose.Text = '关闭'
    $btnClose.Size = [System.Drawing.Size]::new(76, 28)

    $btnRow.Controls.AddRange(@($btnDownload, $btnOpenUrl, $btnCancelDl, $btnClose))

    $pbDownload = [System.Windows.Forms.ProgressBar]::new()
    $pbDownload.Location = [System.Drawing.Point]::new(10, 90)
    $pbDownload.Size = [System.Drawing.Size]::new(922, 18)
    $pbDownload.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pbDownload.Minimum = 0
    $pbDownload.Maximum = 100

    $txtLog = [System.Windows.Forms.TextBox]::new()
    $txtLog.Location = [System.Drawing.Point]::new(10, 114)
    $txtLog.Size = [System.Drawing.Size]::new(922, 80)
    $txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtLog.WordWrap = $true
    $txtLog.BackColor = [System.Drawing.Color]::White
    $txtLog.Text = '就绪：支持后台流式下载、自动 SHA-256 校验，以及一键打开非商用权重官方页面。'

    $bottomPanel.Controls.AddRange(@($lblDetail, $btnRow, $pbDownload, $txtLog))

    # Reverse-Z dock order
    $form.Controls.Add($lv)
    $form.Controls.Add($topBar)
    $form.Controls.Add($bottomPanel)

    $pollTimer = [System.Windows.Forms.Timer]::new()
    $pollTimer.Interval = 100

    $ctx = @{
        Root = $Root
        Form = $form
        ListView = $lv
        TxtComfyDir = $txtComfyDir
        LblDetail = $lblDetail
        BtnDownload = $btnDownload
        BtnOpenUrl = $btnOpenUrl
        BtnCancelDl = $btnCancelDl
        BtnRefresh = $btnRefresh
        PbDownload = $pbDownload
        TxtLog = $txtLog
        PollTimer = $pollTimer
        RegRawMap = @{}
        Statuses = @()
        IsDownloading = $false
        ActiveRunner = $null
        FallbackProc = $null
        FallbackLog = ''
        FallbackReadIdx = 0
        CancelRequested = $false
    }

    $rawEntries = @(Get-IUKModelRegistry -Root $Root)
    foreach ($re in $rawEntries) {
        $ctx.RegRawMap[[string]$re.id] = $re
    }

    $appendLog = {
        param($c, [string]$Line)
        if ([string]::IsNullOrWhiteSpace($Line)) { return }
        if ($Line -match 'Progress:\s*(\d+)%') {
            $pct = [Math]::Clamp([int]$Matches[1], 0, 100)
            $c.PbDownload.Value = $pct
        }
        $c.TxtLog.AppendText($Line + "`r`n")
    }
    $ctx.AppendLog = $appendLog

    $updateSelectionDetail = {
        param($c)
        if ($c.ListView.SelectedIndices.Count -eq 0) {
            $c.BtnDownload.Enabled = $false
            $c.BtnOpenUrl.Enabled = $false
            return
        }
        $m = $c.ListView.SelectedItems[0].Tag
        $raw = $c.RegRawMap[$m.Id]
        $targetStr = if ($m.ResolvedPath) { $m.ResolvedPath } else { '未指定 ComfyUI 目录（请在上方选择安装目录）' }
        $shaShort = if ($m.Sha256) { $m.Sha256.Substring(0, [Math]::Min(16, $m.Sha256.Length)) + '...' } else { '无固定哈希 / 由官方安装脚本验证' }
        $c.LblDetail.Text = ("[{0}] 状态: {1} | 校验: {2}`r`n目标位置: {3} | 说明: {4}" -f $m.Name, $m.StatusLabel, $shaShort, $targetStr, $m.Notes)

        $isManual = ($raw -and [bool]$raw.manual_download_required)
        $c.BtnOpenUrl.Enabled = (-not [string]::IsNullOrWhiteSpace($m.DownloadUrl))
        $c.BtnDownload.Enabled = (-not $c.IsDownloading) -and (-not $isManual)
        if ($isManual) {
            $c.BtnDownload.Text = '需手动下载 (非商用)'
        } elseif ($m.Installed) {
            $c.BtnDownload.Text = '已安装 (重新校验/覆盖)'
        } else {
            $c.BtnDownload.Text = '下载并安装选中模型'
        }
    }
    $ctx.UpdateSelectionDetail = $updateSelectionDetail

    $refreshStatuses = {
        param($c)
        $selId = if ($c.ListView.SelectedIndices.Count -gt 0) { $c.ListView.SelectedItems[0].Tag.Id } else { $null }
        $statuses = @(Get-IUKModelStatus -Root $c.Root -ComfyInstallDir $c.TxtComfyDir.Text.Trim())
        $c.Statuses = $statuses

        $c.ListView.BeginUpdate()
        try {
            $c.ListView.Items.Clear()
            foreach ($s in $statuses) {
                $raw = $c.RegRawMap[$s.Id]
                $scaleStr = (@($s.Scale) | ForEach-Object { "${_}x" }) -join '/'
                $sizeStr = if ($s.SizeBytes -gt 0) {
                    '{0:F1} MB' -f ($s.SizeBytes / 1MB)
                } elseif ($raw -and $raw.size_mb) {
                    '~{0:F1} MB' -f [double]$raw.size_mb
                } else { '-' }

                $lvi = [System.Windows.Forms.ListViewItem]::new($s.Name)
                $lvi.Tag = $s
                [void]$lvi.SubItems.Add($s.Family)
                [void]$lvi.SubItems.Add($scaleStr)
                [void]$lvi.SubItems.Add($s.StatusLabel)
                [void]$lvi.SubItems.Add($sizeStr)
                [void]$lvi.SubItems.Add($s.License)
                [void]$lvi.SubItems.Add($s.Filename)
                switch ($s.StatusLabel) {
                    '已安装' { $lvi.ForeColor = [System.Drawing.Color]::DarkGreen }
                    '需手动下载' { $lvi.ForeColor = [System.Drawing.Color]::DarkOrange }
                    default { $lvi.ForeColor = [System.Drawing.Color]::DimGray }
                }
                [void]$c.ListView.Items.Add($lvi)
                if ($selId -and $s.Id -eq $selId) {
                    $lvi.Selected = $true
                }
            }
            if ($c.ListView.SelectedIndices.Count -eq 0 -and $c.ListView.Items.Count -gt 0) {
                $c.ListView.Items[0].Selected = $true
            }
        } finally {
            $c.ListView.EndUpdate()
        }
        & $c.UpdateSelectionDetail $c
    }
    $ctx.RefreshStatuses = $refreshStatuses

    foreach ($ctrl in @($form, $lv, $btnBrowseComfy, $btnRefresh, $btnOpenFolder, $btnDownload, $btnOpenUrl, $btnCancelDl, $btnClose, $pollTimer)) {
        $ctrl.Tag = $ctx
    }

    & $refreshStatuses $ctx

    $lv.Add_SelectedIndexChanged({
        param($sender, $e)
        $c = $sender.Tag
        & $c.UpdateSelectionDetail $c
    })

    $btnBrowseComfy.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        $d = [System.Windows.Forms.FolderBrowserDialog]::new()
        try {
            if ($c.TxtComfyDir.Text -and (Test-Path -LiteralPath $c.TxtComfyDir.Text -PathType Container)) {
                $d.SelectedPath = $c.TxtComfyDir.Text
            }
            if ($d.ShowDialog($c.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $c.TxtComfyDir.Text = $d.SelectedPath
                & $c.RefreshStatuses $c
            }
        } finally { $d.Dispose() }
    })

    $btnRefresh.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        & $c.RefreshStatuses $c
    })

    $btnOpenFolder.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        if ($c.ListView.SelectedIndices.Count -gt 0) {
            $m = $c.ListView.SelectedItems[0].Tag
            if ($m.ResolvedPath) {
                $dir = Split-Path -Parent $m.ResolvedPath
                if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                    New-Item -ItemType Directory -Force -Path $dir | Out-Null
                }
                Start-Process explorer.exe $dir
                return
            }
        }
        $comfyRoot = $c.TxtComfyDir.Text.Trim()
        if ($comfyRoot -and (Test-Path -LiteralPath $comfyRoot -PathType Container)) {
            Start-Process explorer.exe $comfyRoot
        } else {
            [System.Windows.Forms.MessageBox]::Show($c.Form, '请先指定 ComfyUI 安装目录，或在列表中选择本地模型。', '权重管理') | Out-Null
        }
    })

    $btnOpenUrl.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        if ($c.ListView.SelectedIndices.Count -eq 0) { return }
        $m = $c.ListView.SelectedItems[0].Tag
        if ($m.DownloadUrl) {
            Start-Process $m.DownloadUrl
        }
    })

    $btnDownload.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        if ($c.IsDownloading -or $c.ListView.SelectedIndices.Count -eq 0) { return }
        $m = $c.ListView.SelectedItems[0].Tag
        $raw = $c.RegRawMap[$m.Id]
        $comfyDir = $c.TxtComfyDir.Text.Trim()
        if ($raw -and ([string]$raw.target_dir_type -like 'comfy_*') -and (-not $comfyDir -or -not (Test-Path -LiteralPath $comfyDir -PathType Container))) {
            [System.Windows.Forms.MessageBox]::Show($c.Form, '请先在顶部选择有效的 ComfyUI 安装根目录（例如 E:\ComfyUI_windows_portable），然后再下载权重。', '需要 ComfyUI 目录') | Out-Null
            return
        }

        $c.IsDownloading = $true
        $c.CancelRequested = $false
        $c.BtnDownload.Enabled = $false
        $c.BtnRefresh.Enabled = $false
        $c.BtnCancelDl.Enabled = $true
        $c.PbDownload.Value = 0
        $c.TxtLog.Clear()
        & $c.AppendLog $c "开始下载并安装: $($m.Name)"

        $mmEsc = (Join-Path $c.Root 'ModelManager.ps1') -replace "'", "''"
        $idEsc = $m.Id -replace "'", "''"
        $rootEsc = $c.Root -replace "'", "''"
        $comfyEsc = $comfyDir -replace "'", "''"
        $forceFlag = if ($m.Installed) { ' -Force' } else { '' }
        $cmdText = "`$ErrorActionPreference='Stop'; . '$mmEsc'; Install-IUKModel -ModelId '$idEsc' -Root '$rootEsc' -ComfyInstallDir '$comfyEsc'$forceFlag"

        if ('ImageUpscaleKit.Execution.IukAsyncProcessRunner' -as [type]) {
            $c.ActiveRunner = [ImageUpscaleKit.Execution.IukAsyncProcessRunner]::new('pwsh.exe', @('-NoProfile', '-Command', $cmdText), $c.Root)
        } else {
            $tempLog = Join-Path $c.Root ('temp\mm-dl-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tempLog) | Out-Null
            $c.FallbackLog = $tempLog
            $c.FallbackReadIdx = 0
            $wrappedCmd = "& { $cmdText } *>&1 | Out-File -FilePath '$($tempLog -replace "'", "''")' -Encoding utf8; exit `$LASTEXITCODE"
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = 'pwsh.exe'
            $psi.WorkingDirectory = $c.Root
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            [void]$psi.ArgumentList.Add('-NoProfile')
            [void]$psi.ArgumentList.Add('-Command')
            [void]$psi.ArgumentList.Add($wrappedCmd)
            $c.FallbackProc = [System.Diagnostics.Process]::Start($psi)
        }
        $c.PollTimer.Start()
    })

    $btnCancelDl.Add_Click({
        param($sender, $e)
        $c = $sender.Tag
        $c.CancelRequested = $true
        if ($c.ActiveRunner) {
            try { $c.ActiveRunner.KillTree() } catch {}
        }
        if ($c.FallbackProc -and -not $c.FallbackProc.HasExited) {
            try { $c.FallbackProc.Kill($true) } catch {}
        }
    })

    $pollTimer.Add_Tick({
        param($sender, $e)
        $c = $sender.Tag
        $done = $false
        $exitCode = 0
        $wasKilled = $false

        if ($c.ActiveRunner) {
            foreach ($line in $c.ActiveRunner.DrainOutput()) { & $c.AppendLog $c $line }
            if ($c.ActiveRunner.HasExited) {
                foreach ($line in $c.ActiveRunner.DrainOutput()) { & $c.AppendLog $c $line }
                $exitCode = $c.ActiveRunner.ExitCode
                $wasKilled = $c.ActiveRunner.WasKilled
                $c.ActiveRunner.Dispose()
                $c.ActiveRunner = $null
                $done = $true
            }
        } elseif ($c.FallbackProc) {
            if (Test-Path -LiteralPath $c.FallbackLog -PathType Leaf) {
                $lines = @(Get-Content -LiteralPath $c.FallbackLog -Encoding utf8 -ErrorAction SilentlyContinue)
                while ($c.FallbackReadIdx -lt $lines.Count) {
                    & $c.AppendLog $c $lines[$c.FallbackReadIdx]
                    $c.FallbackReadIdx++
                }
            }
            if ($c.FallbackProc.HasExited) {
                $exitCode = $c.FallbackProc.ExitCode
                $c.FallbackProc.Dispose()
                $c.FallbackProc = $null
                Remove-Item -LiteralPath $c.FallbackLog -Force -ErrorAction SilentlyContinue
                $c.FallbackLog = ''
                $done = $true
            }
        } else {
            $c.PollTimer.Stop()
            return
        }

        if (-not $done) { return }

        $c.PollTimer.Stop()
        $c.IsDownloading = $false
        $c.BtnCancelDl.Enabled = $false
        $c.BtnRefresh.Enabled = $true
        if ($wasKilled -or $c.CancelRequested) {
            & $c.AppendLog $c '已取消下载。'
        } elseif ($exitCode -eq 0) {
            $c.PbDownload.Value = 100
            & $c.AppendLog $c '下载与校验成功！若安装了 ComfyUI 权重，请重启 ComfyUI 或在右侧面板重新点击「测试连接」刷新模型列表。'
        } else {
            & $c.AppendLog $c "安装失败 (退出码: $exitCode)，请检查网络、代理或 ComfyUI 目录权限。"
        }
        & $c.RefreshStatuses $c
    })

    $btnClose.Add_Click({
        param($sender, $e)
        $sender.Tag.Form.Close()
    })

    $form.Add_FormClosing({
        param($sender, $e)
        $c = $sender.Tag
        $c.PollTimer.Stop()
        if ($c.ActiveRunner) {
            try { $c.ActiveRunner.KillTree(); $c.ActiveRunner.Dispose() } catch {}
            $c.ActiveRunner = $null
        }
        if ($c.FallbackProc) {
            try { if (-not $c.FallbackProc.HasExited) { $c.FallbackProc.Kill($true) }; $c.FallbackProc.Dispose() } catch {}
            $c.FallbackProc = $null
        }
        if ($c.FallbackLog) {
            Remove-Item -LiteralPath $c.FallbackLog -Force -ErrorAction SilentlyContinue
        }
        $c.PollTimer.Dispose()
    })

    if ($TestMode) {
        return [pscustomobject]@{
            Form = $form
            ListView = $lv
            Context = $ctx
        }
    }

    try {
        if ($null -ne $OwnerForm) {
            [void]$form.ShowDialog($OwnerForm)
        } else {
            [void]$form.ShowDialog()
        }
    } finally {
        $form.Dispose()
    }
}
