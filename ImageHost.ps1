param(
    [Parameter(Mandatory=$true)] [string]$ImagePath,
    [Parameter(Mandatory=$true)] [string]$WindowTitle
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try { [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) | Out-Null } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

$imgPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ImagePath).Path)
$img = [System.Drawing.Image]::FromFile($imgPath)

$form = [System.Windows.Forms.Form]::new()
$form.Text = $WindowTitle
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = [System.Drawing.Point]::new(0, 0)
$form.ClientSize = [System.Drawing.Size]::new($img.Width, $img.Height)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.BackColor = [System.Drawing.Color]::Black
$form.ShowInTaskbar = $true
$form.KeyPreview = $true

$box = [System.Windows.Forms.PictureBox]::new()
$box.Dock = [System.Windows.Forms.DockStyle]::Fill
$box.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
$box.Image = $img
$form.Controls.Add($box)

$form.Add_FormClosed({
    $box.Image = $null
    $img.Dispose()
})

$form.Add_Shown({
    $form.Activate()
    $form.Focus()
})

[void]$form.ShowDialog()
