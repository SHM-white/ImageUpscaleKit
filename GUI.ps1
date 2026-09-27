Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath=Join-Path $Root 'config.json'
. (Join-Path $Root 'MagpieHelpers.ps1')
function Load-Cfg {
    $loaded = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $loaded.anime4kcpp) {
        $loaded | Add-Member -NotePropertyName anime4kcpp -NotePropertyValue ([pscustomobject]@{backend_path='bin\anime4kcpp\ac_cli.exe';model='acnet-legacy-gan';processor='auto';device=0})
    }
    if (-not $loaded.anime4kcpp.PSObject.Properties['existing_output']) { $loaded.anime4kcpp | Add-Member -NotePropertyName existing_output -NotePropertyValue 'error' }
    if (-not $loaded.anime4kcpp.PSObject.Properties['batch_size']) { $loaded.anime4kcpp | Add-Member -NotePropertyName batch_size -NotePropertyValue 16 }
    return $loaded
}
function Save-Cfg($c) { $c | ConvertTo-Json -Depth 12 | Set-Content $ConfigPath -Encoding utf8NoBOM }
function RPath($p) { if ([IO.Path]::IsPathRooted($p)) { return [IO.Path]::GetFullPath($p) }; [IO.Path]::GetFullPath((Join-Path $Root $p)) }
function Models($dir) { if (!(Test-Path $dir)){return @()}; @(Get-ChildItem $dir -Filter '*.param' -File | Where-Object { Test-Path (Join-Path $dir ($_.BaseName+'.bin')) } | ForEach-Object BaseName | Sort-Object -Unique) }
function Select-Folder([string]$Initial='') {
    $d=[Windows.Forms.FolderBrowserDialog]::new(); $d.ShowNewFolderButton=$true
    if($Initial -and (Test-Path -LiteralPath $Initial -PathType Container)){$d.SelectedPath=[IO.Path]::GetFullPath($Initial)}
    try { if($d.ShowDialog($form)-eq [Windows.Forms.DialogResult]::OK){ return $d.SelectedPath } } finally { $d.Dispose() }
    return $null
}
function Select-Image([string]$Initial='') {
    $d=[Windows.Forms.OpenFileDialog]::new();$d.Filter='Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|All files|*.*';$d.Multiselect=$false
    if($Initial){$dir=if(Test-Path -LiteralPath $Initial -PathType Container){$Initial}else{Split-Path -Parent $Initial};if($dir -and (Test-Path -LiteralPath $dir)){$d.InitialDirectory=$dir}}
    try { if($d.ShowDialog($form)-eq [Windows.Forms.DialogResult]::OK){ return $d.FileName } } finally { $d.Dispose() }
    return $null
}
function Select-OutputFile([string]$Initial='') {
    $d=[Windows.Forms.SaveFileDialog]::new();$d.Filter='PNG image|*.png|JPEG image|*.jpg;*.jpeg|WebP image|*.webp|All files|*.*';$d.DefaultExt='png';$d.AddExtension=$true
    if($engine.Text -eq 'anime4kcpp'){$d.Filter='PNG image|*.png'}
    if($Initial){$dir=Split-Path -Parent $Initial;if($dir -and (Test-Path -LiteralPath $dir)){$d.InitialDirectory=$dir};$d.FileName=Split-Path -Leaf $Initial}
    try { if($d.ShowDialog($form)-eq [Windows.Forms.DialogResult]::OK){ return $d.FileName } } finally { $d.Dispose() }
    return $null
}
function Default-Output([string]$p){if(-not $p -or -not(Test-Path -LiteralPath $p)){return ''};$i=Get-Item -LiteralPath $p;$s=if($engine.Text -eq 'anime4kcpp'){'_acnet_x2'}else{[string]$cfg.output_suffix};if($i.PSIsContainer){return Join-Path $i.Parent.FullName ($i.Name+$s)};return Join-Path $i.Directory.FullName ($i.BaseName+$s+'.png')}
function Start-Pwsh([object[]]$ArgumentList,[switch]$Wait) {
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName='pwsh.exe';$psi.UseShellExecute=$true
    foreach($a in $ArgumentList){[void]$psi.ArgumentList.Add([string]$a)}
    $pr=[Diagnostics.Process]::Start($psi);if($Wait){$pr.WaitForExit()};return $pr
}

$cfg=Load-Cfg
$form=[Windows.Forms.Form]::new(); $form.Text='Image Upscale Kit - ACNet / NCNN / MagpieFX'; $form.Size=[Drawing.Size]::new(930,740); $form.StartPosition='CenterScreen'; $form.Font=[Drawing.Font]::new('Segoe UI',9); $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false
function Label($t,$x,$y,$w=120){$c=[Windows.Forms.Label]::new();$c.Text=$t;$c.Location=[Drawing.Point]::new($x,$y);$c.Size=[Drawing.Size]::new($w,24);$form.Controls.Add($c);$c}
function Text($x,$y,$w){$c=[Windows.Forms.TextBox]::new();$c.Location=[Drawing.Point]::new($x,$y);$c.Size=[Drawing.Size]::new($w,24);$form.Controls.Add($c);$c}
function Button($t,$x,$y,$w=90){$c=[Windows.Forms.Button]::new();$c.Text=$t;$c.Location=[Drawing.Point]::new($x,$y);$c.Size=[Drawing.Size]::new($w,28);$form.Controls.Add($c);$c}

Label '处理引擎' 20 22|Out-Null
$engine=[Windows.Forms.ComboBox]::new();$engine.DropDownStyle='DropDownList';$engine.Items.AddRange(@('ncnn','magpie','anime4kcpp'));$engine.Location=[Drawing.Point]::new(145,18);$engine.Size=[Drawing.Size]::new(180,25);$form.Controls.Add($engine);$engine.SelectedItem=[string]$cfg.engine
Label '输入图片/文件夹' 20 64|Out-Null;$inputBox=Text 145 60 515;$bi=Button '选图片' 670 58 75;$bif=Button '选文件夹' 750 58 80;$clearIn=Button '清空' 835 58 65
Label '输出文件/文件夹' 20 104|Out-Null;$outputBox=Text 145 100 515;$bof=Button '选文件' 670 98 75;$bod=Button '选文件夹' 750 98 80;$autoOut=Button '自动' 835 98 65

$grpN=[Windows.Forms.GroupBox]::new();$grpN.Text='NCNN / Real-ESRGAN';$grpN.Location=[Drawing.Point]::new(20,145);$grpN.Size=[Drawing.Size]::new(880,150);$form.Controls.Add($grpN)
function NLabel($t,$x,$y,$w=100){$c=[Windows.Forms.Label]::new();$c.Text=$t;$c.Location=[Drawing.Point]::new($x,$y);$c.Size=[Drawing.Size]::new($w,22);$grpN.Controls.Add($c);$c}
$model=[Windows.Forms.ComboBox]::new();$model.DropDownStyle='DropDownList';$model.Location=[Drawing.Point]::new(120,28);$model.Size=[Drawing.Size]::new(350,25);$grpN.Controls.Add($model);NLabel '模型' 15 32|Out-Null
$refreshN=[Windows.Forms.Button]::new();$refreshN.Text='刷新';$refreshN.Location=[Drawing.Point]::new(480,26);$refreshN.Size=[Drawing.Size]::new(70,28);$grpN.Controls.Add($refreshN)
NLabel '倍率' 15 72|Out-Null;$scale=[Windows.Forms.ComboBox]::new();$scale.DropDownStyle='DropDownList';$scale.Items.AddRange(@('auto','2','3','4'));$scale.Location=[Drawing.Point]::new(120,68);$scale.Size=[Drawing.Size]::new(80,25);$grpN.Controls.Add($scale)
NLabel 'Tile' 225 72 45|Out-Null;$tile=[Windows.Forms.TextBox]::new();$tile.Location=[Drawing.Point]::new(270,68);$tile.Size=[Drawing.Size]::new(70,24);$grpN.Controls.Add($tile)
NLabel 'GPU' 365 72 45|Out-Null;$gpu=[Windows.Forms.TextBox]::new();$gpu.Location=[Drawing.Point]::new(410,68);$gpu.Size=[Drawing.Size]::new(90,24);$grpN.Controls.Add($gpu)
NLabel '线程' 525 72 45|Out-Null;$threads=[Windows.Forms.TextBox]::new();$threads.Location=[Drawing.Point]::new(570,68);$threads.Size=[Drawing.Size]::new(100,24);$grpN.Controls.Add($threads)
$tta=[Windows.Forms.CheckBox]::new();$tta.Text='TTA';$tta.Location=[Drawing.Point]::new(700,68);$grpN.Controls.Add($tta)

$grpM=[Windows.Forms.GroupBox]::new();$grpM.Text='MagpieFX / HLSL';$grpM.Location=[Drawing.Point]::new(20,305);$grpM.Size=[Drawing.Size]::new(880,265);$form.Controls.Add($grpM)
function MLabel($t,$x,$y,$w=100){$c=[Windows.Forms.Label]::new();$c.Text=$t;$c.Location=[Drawing.Point]::new($x,$y);$c.Size=[Drawing.Size]::new($w,22);$grpM.Controls.Add($c);$c}
MLabel '选择方式' 15 32|Out-Null;$selType=[Windows.Forms.ComboBox]::new();$selType.DropDownStyle='DropDownList';$selType.Items.AddRange(@('mode','family','effect'));$selType.Location=[Drawing.Point]::new(120,28);$selType.Size=[Drawing.Size]::new(120,25);$grpM.Controls.Add($selType)
MLabel '方案 / 模型族' 15 72|Out-Null;$mode=[Windows.Forms.ComboBox]::new();$mode.DropDownStyle='DropDownList';$mode.Location=[Drawing.Point]::new(120,68);$mode.Size=[Drawing.Size]::new(350,25);$grpM.Controls.Add($mode)
MLabel '档位' 490 72 50|Out-Null;$tier=[Windows.Forms.ComboBox]::new();$tier.DropDownStyle='DropDownList';$tier.Location=[Drawing.Point]::new(545,68);$tier.Size=[Drawing.Size]::new(100,25);$grpM.Controls.Add($tier)
MLabel '全部 HLSL' 15 112|Out-Null;$raw=[Windows.Forms.ComboBox]::new();$raw.DropDownStyle='DropDownList';$raw.Location=[Drawing.Point]::new(120,108);$raw.Size=[Drawing.Size]::new(525,25);$grpM.Controls.Add($raw)
$refreshM=[Windows.Forms.Button]::new();$refreshM.Text='刷新 HLSL';$refreshM.Location=[Drawing.Point]::new(665,28);$refreshM.Size=[Drawing.Size]::new(90,28);$grpM.Controls.Add($refreshM)
$openModes=[Windows.Forms.Button]::new();$openModes.Text='打开 Magpie 配置';$openModes.Location=[Drawing.Point]::new(765,28);$openModes.Size=[Drawing.Size]::new(100,28);$grpM.Controls.Add($openModes)
$openE=[Windows.Forms.Button]::new();$openE.Text='打开 HLSL 目录';$openE.Location=[Drawing.Point]::new(665,68);$openE.Size=[Drawing.Size]::new(200,28);$grpM.Controls.Add($openE)
$preview=[Windows.Forms.TextBox]::new();$preview.Location=[Drawing.Point]::new(15,148);$preview.Size=[Drawing.Size]::new(850,95);$preview.Multiline=$true;$preview.ReadOnly=$true;$preview.ScrollBars='Vertical';$grpM.Controls.Add($preview)

$grpA=[Windows.Forms.GroupBox]::new();$grpA.Text='Anime4KCPP - 全部模型 / 2x PNG';$grpA.Location=[Drawing.Point]::new(20,145);$grpA.Size=[Drawing.Size]::new(880,240);$form.Controls.Add($grpA)
function ALabel($text,$x,$y,$width=100){$label=[Windows.Forms.Label]::new();$label.Text=$text;$label.Location=[Drawing.Point]::new($x,$y);$label.Size=[Drawing.Size]::new($width,24);$grpA.Controls.Add($label)}
ALabel '模型' 15 32
$acModel=[Windows.Forms.ComboBox]::new();$acModel.DropDownStyle='DropDownList';$acModel.Location=[Drawing.Point]::new(120,28);$acModel.Size=[Drawing.Size]::new(420,25);$grpA.Controls.Add($acModel)
$acRefresh=[Windows.Forms.Button]::new();$acRefresh.Text='刷新模型';$acRefresh.Location=[Drawing.Point]::new(565,26);$acRefresh.Size=[Drawing.Size]::new(100,28);$grpA.Controls.Add($acRefresh)
ALabel '处理器' 15 76
$acProcessor=[Windows.Forms.ComboBox]::new();$acProcessor.DropDownStyle='DropDownList';$acProcessor.Items.AddRange(@('auto','cuda','opencl','cpu'));$acProcessor.Location=[Drawing.Point]::new(120,72);$acProcessor.Size=[Drawing.Size]::new(150,25);$grpA.Controls.Add($acProcessor)
$acProcessor.SelectedItem=[string]$cfg.anime4kcpp.processor
if($acProcessor.SelectedIndex -lt 0){$acProcessor.SelectedItem='auto'}
ALabel '设备编号' 310 76
$acDevice=[Windows.Forms.NumericUpDown]::new();$acDevice.Location=[Drawing.Point]::new(415,72);$acDevice.Maximum=65535;$acDevice.Value=[decimal]$cfg.anime4kcpp.device;$grpA.Controls.Add($acDevice)
ALabel '直接放大 2 倍，无需预放大或窗口截图。输出为 PNG。' 15 118 830
ALabel 'ACNet / ARNet / ArtCNN / FSRCNNX 全系列；具体模型以已安装后端为准。' 15 150 830
ALabel '每批最多图片' 400 186 110
$acBatchSize=[Windows.Forms.NumericUpDown]::new();$acBatchSize.Location=[Drawing.Point]::new(520,182);$acBatchSize.Minimum=1;$acBatchSize.Maximum=256;$acBatchSize.Value=[Math]::Clamp([int]$cfg.anime4kcpp.batch_size,1,256);$grpA.Controls.Add($acBatchSize)
ALabel '已有文件' 15 186
$acExisting=[Windows.Forms.ComboBox]::new();$acExisting.DropDownStyle='DropDownList';$acExisting.Location=[Drawing.Point]::new(120,182);$acExisting.Size=[Drawing.Size]::new(235,25);$grpA.Controls.Add($acExisting)
$acExisting.Items.AddRange(@('停止并提示','覆盖已有文件','自动加序号（_1、_2…）'))
$acOutputPolicies=@('error','overwrite','rename')
$acExisting.SelectedIndex=[Array]::IndexOf($acOutputPolicies,[string]$cfg.anime4kcpp.existing_output)
if($acExisting.SelectedIndex -lt 0){$acExisting.SelectedIndex=0}
function RefreshA {
    $wanted=if($acModel.Text){$acModel.Text}else{[string]$cfg.anime4kcpp.model}
    $acModel.Items.Clear()
    $backend=RPath $cfg.anime4kcpp.backend_path
    if(Test-Path -LiteralPath $backend){
        $listing=& $backend --lm 2>&1
        if($LASTEXITCODE -eq 0){foreach($line in $listing){if([string]$line -match '^  ([\w-]+):\s*$'){[void]$acModel.Items.Add($Matches[1])}}}
    }
    if($acModel.Items.Count -eq 0){$acModel.Items.AddRange(@('acnet-legacy-gan','acnet-legacy-hdn0','acnet-legacy-hdn1','acnet-legacy-hdn2','acnet-legacy-hdn3','acnet-f8b4','acnet-f8b4-hdn','acnet-f8b4-box','acnet-f8b4-box-hdn','acnet-f8b8','acnet-f8b8-hdn','acnet-f8b8-box','acnet-f8b8-box-hdn','acnet-f8b18','acnet-f8b18-hdn','acnet-f8b18-box','acnet-f8b18-box-hdn','arnet-f8b8','arnet-f8b8-hdn','arnet-f8b8-box','arnet-f8b8-box-hdn','arnet-f8b16','arnet-f8b16-hdn','arnet-f8b16-box','arnet-f8b16-box-hdn','arnet-f8b32','arnet-f8b32-hdn','arnet-f8b32-box','arnet-f8b32-box-hdn','arnet-f8b64','arnet-f8b64-hdn','arnet-f8b64-box','arnet-f8b64-box-hdn','artcnn-c4f16','artcnn-c4f16-dn','artcnn-c4f16-ds','artcnn-c4f32','artcnn-c4f32-dn','artcnn-c4f32-ds','fsrcnnx-f8b4','fsrcnnx-f8b4-distort-plus','fsrcnnx-f16b4','fsrcnnx-f16b4-distort-plus'))}
    if($acModel.Items.Contains($wanted)){$acModel.SelectedItem=$wanted}else{$acModel.SelectedIndex=0}
}
function UpdateEngineState {
    $grpA.Visible=$engine.Text -eq 'anime4kcpp'
    $grpN.Visible=$engine.Text -ne 'anime4kcpp';$grpN.Enabled=$engine.Text -eq 'ncnn'
    $grpM.Visible=$engine.Text -ne 'anime4kcpp';$grpM.Enabled=$engine.Text -eq 'magpie'
    if($grpA.Visible){$grpA.BringToFront()}
}
$acRefresh.Add_Click({RefreshA;Status})
$engine.Add_SelectedIndexChanged({UpdateEngineState;if($inputBox.Text){$outputBox.Text=Default-Output $inputBox.Text}})
RefreshA;UpdateEngineState
$status=[Windows.Forms.Label]::new();$status.Location=[Drawing.Point]::new(20,585);$status.Size=[Drawing.Size]::new(620,60);$form.Controls.Add($status)
$setup=Button '安装/修复后端' 690 585 210
$save=Button '保存设置' 575 655 100;$run=Button '开始处理' 685 655 100;$logs=Button '打开日志' 795 655 105

function ModeFile(){RPath ([string]$cfg.magpie.mode_file)}
function ConfigFile(){ if($cfg.magpie.config_file){RPath ([string]$cfg.magpie.config_file)} else { Join-Path (Split-Path -Parent (RPath ([string]$cfg.magpie.exe_path))) 'config\config.json' } }
function EffectsDir(){RPath ([string]$cfg.magpie.effects_dir)}
function RefreshN { $model.Items.Clear(); foreach($m in Models (RPath $cfg.ncnn.model_dir)){[void]$model.Items.Add($m)}; if($model.Items.Contains([string]$cfg.ncnn.model)){$model.SelectedItem=[string]$cfg.ncnn.model}elseif($model.Items.Count){$model.SelectedIndex=0} }
function FillPrimary {
    $mode.Items.Clear()
    if($selType.Text -eq 'family'){
        foreach($f in @(Get-IUKMagpieFamilies (EffectsDir))){[void]$mode.Items.Add([string]$f.Family)}
        $want=[string]$cfg.magpie.family
    } else {
        foreach($m in @(Get-IUKUnifiedModeNames (ConfigFile) (ModeFile))){[void]$mode.Items.Add($m)}
        $want=[string]$cfg.magpie.mode
    }
    if($mode.Items.Contains($want)){$mode.SelectedItem=$want}elseif($mode.Items.Count){$mode.SelectedIndex=0}
}
function RefreshTiers {
    $tier.Items.Clear(); if(!$mode.Text -or $selType.Text -eq 'effect'){return}
    if($selType.Text -eq 'family'){$ts=@(Get-IUKFamilyTiers $mode.Text (EffectsDir))}else{$ts=@(Get-IUKUnifiedModeTiers (ConfigFile) (ModeFile) $mode.Text (EffectsDir))}
    foreach($t in $ts){[void]$tier.Items.Add($t)}
    $want=[string]$cfg.magpie.tier
    if($tier.Items.Contains($want)){$tier.SelectedItem=$want}elseif($tier.Items.Count){$tier.SelectedIndex=0}
}
function RefreshM {
    FillPrimary
    $raw.Items.Clear(); foreach($e in Get-IUKMagpieEffects (EffectsDir)){[void]$raw.Items.Add($e)}
    if($raw.Items.Contains([string]$cfg.magpie.raw_effect)){$raw.SelectedItem=[string]$cfg.magpie.raw_effect}elseif($raw.Items.Count){$raw.SelectedIndex=0}
    RefreshTiers; UpdatePreview; UpdateMagpieState
}
function UpdateMagpieState {$raw.Enabled=$selType.Text -eq 'effect';$mode.Enabled=$selType.Text -ne 'effect';$tier.Enabled=$selType.Text -ne 'effect'}
function UpdatePreview {
    try {
      if($selType.Text -eq 'effect'){$preview.Text="单个 HLSL（官方 Magpie 原生执行）`r`n$($raw.Text)";return}
      if(!$mode.Text){$preview.Text='';return}
      if($selType.Text -eq 'family'){$fx=@(Resolve-IUKFamilyEffect $mode.Text $tier.Text (EffectsDir));$preview.Text=("自动模型族`r`nFamily: {0}`r`n档位: {1}`r`nEffect: {2}" -f $mode.Text,$tier.Text,$fx[0].name);return}
      $src=Get-IUKModeSourceLabel (ConfigFile) (ModeFile) $mode.Text
      if((Get-IUKPreferredModeSource (ConfigFile) (ModeFile) $mode.Text) -eq 'config'){
        $mo=Get-IUKMagpieConfigMode (ConfigFile) $mode.Text
        $fx=@($mo.effects)
        $lines=@("来源: $src",'',"模式: $($mode.Text)",'档位: Default','Effects:')
      } else {
        $mf=Read-IUKModeFile (ModeFile);$mo=@($mf.scalingModes|Where-Object name -eq $mode.Text)|Select-Object -First 1
        $fx=@(Resolve-IUKModeEffects (ModeFile) $mode.Text $tier.Text (EffectsDir));$lines=@("来源: $src",[string]$mo.description,'',"档位: $($tier.Text)",'Effects:')
      }
      foreach($e in $fx){$ss='  '+$e.name;if($e.scale){$ss+="  scale=$($e.scale.x)x$($e.scale.y)"};$lines+=$ss}
      $preview.Text=$lines -join "`r`n"
    } catch {$preview.Text=$_.Exception.Message}
}
function Status {
    $acInstalled=Test-Path (RPath $cfg.anime4kcpp.backend_path)
    $n=Test-Path (RPath $cfg.ncnn.backend_path)
    $m=Test-Path (RPath $cfg.magpie.exe_path)
    $count=@(Get-IUKMagpieEffects (EffectsDir)).Count
    $source=Get-IUKModeSourceLabel (ConfigFile) (ModeFile)
    $status.Text="ACNet: $(if($acInstalled){'已安装'}else{'未安装'})    NCNN: $(if($n){'已安装'}else{'未安装'})    Magpie: $(if($m){'已安装'}else{'未安装'})    HLSL: $count`r`n方案来源: $source    GUI 使用 STA；输入/输出文件夹选择已修复。"
}

RefreshN
$selType.SelectedItem=[string]$cfg.magpie.selection_type;if($selType.SelectedIndex-lt0){$selType.SelectedItem='mode'}
RefreshM;Status
$scale.SelectedItem=[string]$cfg.ncnn.scale;if($scale.SelectedIndex-lt0){$scale.SelectedItem='auto'};$tile.Text=[string]$cfg.ncnn.tile;$gpu.Text=[string]$cfg.ncnn.gpu;$threads.Text=[string]$cfg.ncnn.threads;$tta.Checked=[bool]$cfg.ncnn.tta

$bi.Add_Click({$p=Select-Image $inputBox.Text;if($p){$inputBox.Text=$p;$outputBox.Text=Default-Output $p}})
$bif.Add_Click({$p=Select-Folder $inputBox.Text;if($p){$inputBox.Text=$p;$outputBox.Text=Default-Output $p}})
$clearIn.Add_Click({$inputBox.Clear();$outputBox.Clear()})
$bof.Add_Click({$p=Select-OutputFile $outputBox.Text;if($p){$outputBox.Text=$p}})
$bod.Add_Click({$initial=$outputBox.Text;if($initial -and -not(Test-Path -LiteralPath $initial -PathType Container)){$initial=Split-Path -Parent $initial};$p=Select-Folder $initial;if($p){$outputBox.Text=$p}})
$autoOut.Add_Click({$outputBox.Text=Default-Output $inputBox.Text})
$refreshN.Add_Click({RefreshN})
$refreshM.Add_Click({$cfg=Load-Cfg;RefreshM;Status})
$mode.Add_SelectedIndexChanged({RefreshTiers;UpdatePreview})
$tier.Add_SelectedIndexChanged({UpdatePreview})
$raw.Add_SelectedIndexChanged({UpdatePreview})
$selType.Add_SelectedIndexChanged({FillPrimary;RefreshTiers;UpdateMagpieState;UpdatePreview})
$openModes.Add_Click({
    $pc=ConfigFile; $pm=ModeFile
    if(Test-Path $pc){Start-Process notepad.exe $pc}
    elseif(Test-Path $pm){Start-Process notepad.exe $pm}
    else {[Windows.Forms.MessageBox]::Show('未找到 Magpie 配置文件，也未找到备用 magpie_modes.json。')|Out-Null}
})
$openE.Add_Click({$p=EffectsDir;if(Test-Path $p){Start-Process explorer.exe $p}else{[Windows.Forms.MessageBox]::Show('请先运行安装/修复后端。')|Out-Null}})
$logs.Add_Click({$p=Join-Path $Root 'logs';New-Item -ItemType Directory -Force -Path $p|Out-Null;Start-Process explorer.exe $p})
$setup.Add_Click({$scriptName=if($engine.Text -eq 'anime4kcpp'){'Setup-Anime4KCPP.ps1'}else{'Setup.ps1'};Start-Pwsh @('-NoProfile','-File',(Join-Path $Root $scriptName)) -Wait|Out-Null;$cfg=Load-Cfg;RefreshN;RefreshM;RefreshA;Status})
$saveAction={
    try {
        $cfg=Load-Cfg
        $cfg.engine=$engine.Text
        $cfg.anime4kcpp.model=$acModel.Text
        $cfg.anime4kcpp.processor=$acProcessor.Text
        $cfg.anime4kcpp.device=[int]$acDevice.Value
        $cfg.anime4kcpp.batch_size=[int]$acBatchSize.Value
        $cfg.anime4kcpp.existing_output=$acOutputPolicies[$acExisting.SelectedIndex]
        if($model.Text){$cfg.ncnn.model=$model.Text}
        $cfg.ncnn.scale=$scale.Text
        $cfg.ncnn.tile=[int]$tile.Text
        $cfg.ncnn.gpu=$gpu.Text
        $cfg.ncnn.threads=$threads.Text
        $cfg.ncnn.tta=$tta.Checked
        $cfg.magpie.selection_type=$selType.Text
        if($selType.Text-eq'family'){if($mode.Text){$cfg.magpie.family=$mode.Text}}else{if($mode.Text){$cfg.magpie.mode=$mode.Text}}
        if($tier.Text){$cfg.magpie.tier=$tier.Text}
        if($raw.Text){$cfg.magpie.raw_effect=$raw.Text}
        Save-Cfg $cfg
        return $true
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,'设置错误')|Out-Null
        return $false
    }
}
$save.Add_Click({if(&$saveAction){[Windows.Forms.MessageBox]::Show('设置已保存。')|Out-Null}})
$run.Add_Click({
    if(-not(&$saveAction)){return}
    if(-not(Test-Path -LiteralPath $inputBox.Text)){[Windows.Forms.MessageBox]::Show('请选择有效输入。')|Out-Null;return}
    $a=@('-NoProfile','-File',(Join-Path $Root 'Upscale.ps1'),'-InputPath',$inputBox.Text,'-Engine',$engine.Text)
    if($outputBox.Text){$a+=@('-OutputPath',$outputBox.Text)}
    if($engine.Text -eq 'anime4kcpp'){
        $a+=@('-Model',$acModel.Text,'-Scale','2','-AcProcessor',$acProcessor.Text,'-AcDevice',[string]$acDevice.Value,'-AcBatchSize',[string]$acBatchSize.Value,'-ExistingOutput',$acOutputPolicies[$acExisting.SelectedIndex])
    } elseif($engine.Text-eq'ncnn'){
        $a+=@('-Model',$model.Text,'-Scale',$scale.Text,'-Tile',$tile.Text,'-Gpu',$gpu.Text,'-Threads',$threads.Text)
        if($tta.Checked){$a+='-Tta'}else{$a+='-NoTta'}
    } else {
        $a+=@('-MagpieSelectionType',$selType.Text)
        if($selType.Text-eq'effect'){$a+=@('-MagpieEffect',$raw.Text)}
        elseif($selType.Text-eq'family'){$a+=@('-MagpieFamily',$mode.Text,'-MagpieTier',$tier.Text)}
        else{$a+=@('-MagpieMode',$mode.Text,'-MagpieTier',$tier.Text)}
    }
    Start-Pwsh $a|Out-Null
})
[void]$form.ShowDialog()
