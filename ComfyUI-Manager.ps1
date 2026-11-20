param(
    [switch]$TestMode
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root = $PSScriptRoot
. (Join-Path $Root 'gui\ComfyUIPanel.ps1')

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'ImageUpscaleKit - ComfyUI 连接与实例管理'
$form.Size = [System.Drawing.Size]::new(380, 520)
$form.MinimumSize = [System.Drawing.Size]::new(360, 490)
$form.StartPosition = 'CenterScreen'
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9)

$cp = New-IUKComfyUIPanel -Root $Root
$cp.Panel.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($cp.Panel)

if ($TestMode) {
    return [pscustomobject]@{ Form = $form; Panel = $cp }
}
try {
    [void]$form.ShowDialog()
} finally {
    $form.Dispose()
}
