function New-IUKRealCUGANPanel {
    param(
        [Parameter(Mandatory = $true)] [string]$Root
    )

    $panel = [System.Windows.Forms.GroupBox]::new()
    $panel.Text = 'Real-CUGAN / NCNN Vulkan'
    $panel.Size = [System.Drawing.Size]::new(334, 178)

    $lblM = [System.Windows.Forms.Label]::new(); $lblM.Text = '模型族:'; $lblM.Location = [System.Drawing.Point]::new(10, 26); $lblM.Size = [System.Drawing.Size]::new(60, 22)
    $cmbModel = [System.Windows.Forms.ComboBox]::new(); $cmbModel.DropDownStyle = 'DropDownList'; $cmbModel.Items.AddRange(@('models-se', 'models-pro', 'models-nose')); $cmbModel.Location = [System.Drawing.Point]::new(74, 22); $cmbModel.Size = [System.Drawing.Size]::new(250, 24)
    $cmbModel.SelectedIndex = 0

    $lblS = [System.Windows.Forms.Label]::new(); $lblS.Text = '倍率:'; $lblS.Location = [System.Drawing.Point]::new(10, 58); $lblS.Size = [System.Drawing.Size]::new(60, 22)
    $cmbScale = [System.Windows.Forms.ComboBox]::new(); $cmbScale.DropDownStyle = 'DropDownList'; $cmbScale.Items.AddRange(@('2', '3', '4')); $cmbScale.Location = [System.Drawing.Point]::new(74, 54); $cmbScale.Size = [System.Drawing.Size]::new(80, 24)
    $cmbScale.SelectedIndex = 0

    $lblN = [System.Windows.Forms.Label]::new(); $lblN.Text = '降噪:'; $lblN.Location = [System.Drawing.Point]::new(172, 58); $lblN.Size = [System.Drawing.Size]::new(48, 22)
    $cmbNoise = [System.Windows.Forms.ComboBox]::new(); $cmbNoise.DropDownStyle = 'DropDownList'; $cmbNoise.Items.AddRange(@('-1', '0', '1', '2', '3')); $cmbNoise.Location = [System.Drawing.Point]::new(224, 54); $cmbNoise.Size = [System.Drawing.Size]::new(100, 24)
    $cmbNoise.SelectedIndex = 0

    $lblT = [System.Windows.Forms.Label]::new(); $lblT.Text = 'Tile:'; $lblT.Location = [System.Drawing.Point]::new(10, 90); $lblT.Size = [System.Drawing.Size]::new(60, 22)
    $txtTile = [System.Windows.Forms.TextBox]::new(); $txtTile.Text = '0'; $txtTile.Location = [System.Drawing.Point]::new(74, 86); $txtTile.Size = [System.Drawing.Size]::new(80, 24)

    $lblG = [System.Windows.Forms.Label]::new(); $lblG.Text = 'GPU:'; $lblG.Location = [System.Drawing.Point]::new(172, 90); $lblG.Size = [System.Drawing.Size]::new(48, 22)
    $txtGpu = [System.Windows.Forms.TextBox]::new(); $txtGpu.Text = 'auto'; $txtGpu.Location = [System.Drawing.Point]::new(224, 86); $txtGpu.Size = [System.Drawing.Size]::new(100, 24)

    $chkTta = [System.Windows.Forms.CheckBox]::new(); $chkTta.Text = 'TTA 模式'; $chkTta.Location = [System.Drawing.Point]::new(10, 122); $chkTta.AutoSize = $true
    $lblNote = [System.Windows.Forms.Label]::new(); $lblNote.Text = '支持 Intel / AMD / NVIDIA Vulkan（无需 Python）'; $lblNote.Location = [System.Drawing.Point]::new(10, 148); $lblNote.Size = [System.Drawing.Size]::new(314, 22); $lblNote.ForeColor = [System.Drawing.Color]::DimGray

    $panel.Controls.AddRange(@($lblM, $cmbModel, $lblS, $cmbScale, $lblN, $cmbNoise, $lblT, $txtTile, $lblG, $txtGpu, $chkTta, $lblNote))

    $ctx = @{
        CmbModel = $cmbModel
        CmbScale = $cmbScale
        CmbNoise = $cmbNoise
        TxtTile = $txtTile
        TxtGpu = $txtGpu
        ChkTta = $chkTta
    }

    $getOptions = {
        return @{
            RealCuganModel = $ctx.CmbModel.Text
            RealCuganScale = $ctx.CmbScale.Text
            RealCuganNoiseLevel = [int]$ctx.CmbNoise.Text
            RealCuganSyncGap = 3
            RealCuganTile = if ($ctx.TxtTile.Text -match '^\d+$') { [int]$ctx.TxtTile.Text } else { 0 }
            RealCuganGpu = $ctx.TxtGpu.Text.Trim()
            RealCuganTta = $ctx.ChkTta.Checked
        }
    }.GetNewClosure()

    return [pscustomobject]@{
        Panel = $panel
        Context = $ctx
        GetOptions = $getOptions
    }
}
