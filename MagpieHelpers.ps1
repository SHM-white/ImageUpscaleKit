$Script:IUKTierOrder = @('US','S','M','L','VL','UL','2x','3x','4x','Default')

function Get-IUKMagpieEffects([string]$EffectsDir) {
    if (-not (Test-Path -LiteralPath $EffectsDir -PathType Container)) { return @() }
    $base = [System.IO.Path]::GetFullPath($EffectsDir).TrimEnd([char]'\')
    @(
        Get-ChildItem -LiteralPath $base -Recurse -Filter '*.hlsl' -File |
        ForEach-Object {
            $full = [System.IO.Path]::GetFullPath($_.FullName)
            $rel = $full.Substring($base.Length).TrimStart([char]'\',[char]'/')
            [System.IO.Path]::ChangeExtension($rel,$null).TrimEnd('.') -replace '/','\'
        } | Sort-Object -Unique
    )
}

function Get-IUKEffectFamily([string]$EffectName) {
    $leaf = ($EffectName -split '\\')[-1]
    $prefix = $EffectName.Substring(0,$EffectName.Length-$leaf.Length)
    $tier = 'Default'
    $familyLeaf = $leaf
    if ($leaf -match '^(.*?)(?:_|-)(US|UL|VL|S|M|L)$') {
        $familyLeaf = $Matches[1]
        $tier = $Matches[2]
    }
    [pscustomobject]@{ Effect=$EffectName; Family=($prefix+$familyLeaf); Tier=$tier }
}

function Get-IUKMagpieFamilies([string]$EffectsDir) {
    $effects = @(Get-IUKMagpieEffects $EffectsDir)
    $items = foreach ($e in $effects) { Get-IUKEffectFamily $e }
    $groups = $items | Group-Object Family
    $result = @()
    foreach ($g in $groups) {
        $tiers = @($g.Group.Tier | Sort-Object -Unique)
        $ordered = @()
        foreach ($t in $Script:IUKTierOrder) { if ($tiers -contains $t) { $ordered += $t } }
        foreach ($t in $tiers) { if ($ordered -notcontains $t) { $ordered += $t } }
        $map = [ordered]@{}
        foreach ($t in $ordered) { $map[$t] = @($g.Group | Where-Object Tier -eq $t | Select-Object -First 1).Effect }
        $result += [pscustomobject]@{ Family=$g.Name; Tiers=$ordered; Effects=$map }
    }
    @($result | Sort-Object Family)
}

function Read-IUKJsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "JSON file not found: $Path" }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Read-IUKModeFile([string]$ModeFile) {
    if (-not (Test-Path -LiteralPath $ModeFile)) { throw "Magpie mode file not found: $ModeFile" }
    Read-IUKJsonFile $ModeFile
}

function Read-IUKMagpieConfig([string]$ConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Magpie config not found: $ConfigFile" }
    Read-IUKJsonFile $ConfigFile
}

function Get-IUKMagpieConfigModeNames([string]$ConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return @() }
    try {
        $cfg = Read-IUKMagpieConfig $ConfigFile
        return @($cfg.scalingModes | ForEach-Object { [string]$_.name } | Where-Object { $_ } )
    } catch { return @() }
}

function Get-IUKMagpieConfigMode([string]$ConfigFile,[string]$ModeName) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return $null }
    try {
        $cfg = Read-IUKMagpieConfig $ConfigFile
        return @($cfg.scalingModes | Where-Object { [string]$_.name -eq $ModeName }) | Select-Object -First 1
    } catch { return $null }
}

function Get-IUKModeNames([string]$ModeFile) {
    $m = Read-IUKModeFile $ModeFile
    @($m.scalingModes | ForEach-Object { [string]$_.name })
}

function Get-IUKPreferredModeSource([string]$ConfigFile,[string]$ModeFile,[string]$PreferredModeName='') {
    $cfgNames = @(Get-IUKMagpieConfigModeNames $ConfigFile)
    if ($cfgNames.Count -gt 0) {
        if (-not $PreferredModeName -or $cfgNames -contains $PreferredModeName) {
            return 'config'
        }
    }
    if (Test-Path -LiteralPath $ModeFile) {
        return 'kit'
    }
    if ($cfgNames.Count -gt 0) { return 'config' }
    return 'none'
}

function Get-IUKUnifiedModeNames([string]$ConfigFile,[string]$ModeFile) {
    $source = Get-IUKPreferredModeSource $ConfigFile $ModeFile
    switch ($source) {
        'config' { return @(Get-IUKMagpieConfigModeNames $ConfigFile) }
        'kit' { return @(Get-IUKModeNames $ModeFile) }
        default { return @() }
    }
}

function Get-IUKModeSourceLabel([string]$ConfigFile,[string]$ModeFile,[string]$PreferredModeName='') {
    switch (Get-IUKPreferredModeSource $ConfigFile $ModeFile $PreferredModeName) {
        'config' { return 'Magpie config.json' }
        'kit' { return 'magpie_modes.json' }
        default { return '无可用方案源' }
    }
}

function Get-IUKModeTiers([string]$ModeFile,[string]$ModeName,[string]$EffectsDir) {
    $m = Read-IUKModeFile $ModeFile
    $mode = @($m.scalingModes | Where-Object { [string]$_.name -eq $ModeName }) | Select-Object -First 1
    if (-not $mode) { return @() }
    if ($mode.tiers) {
        $names = @($mode.tiers.PSObject.Properties.Name)
        $ordered=@(); foreach($t in $Script:IUKTierOrder){if($names -contains $t){$ordered+=$t}}; foreach($t in $names){if($ordered -notcontains $t){$ordered+=$t}}
        return $ordered
    }
    if ($mode.autoFamily) {
        $fam = @(Get-IUKMagpieFamilies $EffectsDir | Where-Object Family -eq ([string]$mode.autoFamily)) | Select-Object -First 1
        if ($fam) { return @($fam.Tiers) }
        return @()
    }
    return @('Default')
}

function Get-IUKUnifiedModeTiers([string]$ConfigFile,[string]$ModeFile,[string]$ModeName,[string]$EffectsDir) {
    $source = Get-IUKPreferredModeSource $ConfigFile $ModeFile $ModeName
    if ($source -eq 'config') {
        $mode = Get-IUKMagpieConfigMode $ConfigFile $ModeName
        if ($mode) { return @('Default') }
        return @()
    }
    return @(Get-IUKModeTiers $ModeFile $ModeName $EffectsDir)
}

function Resolve-IUKModeEffects([string]$ModeFile,[string]$ModeName,[string]$Tier,[string]$EffectsDir) {
    $m = Read-IUKModeFile $ModeFile
    $mode = @($m.scalingModes | Where-Object { [string]$_.name -eq $ModeName }) | Select-Object -First 1
    if (-not $mode) { throw "Magpie scaling mode not found: $ModeName" }
    if ($mode.tiers) {
        if (-not $Tier) { $Tier = [string]$mode.defaultTier }
        $p = $mode.tiers.PSObject.Properties[$Tier]
        if (-not $p) { throw "Tier '$Tier' is not defined for mode '$ModeName'." }
        return @($p.Value.effects)
    }
    if ($mode.autoFamily) {
        $family=[string]$mode.autoFamily
        $fam = @(Get-IUKMagpieFamilies $EffectsDir | Where-Object Family -eq $family) | Select-Object -First 1
        if (-not $fam) { throw "No installed HLSL variants found for family: $family" }
        if (-not $Tier) { $Tier=[string]$mode.defaultTier }
        if (-not $Tier -or $fam.Tiers -notcontains $Tier) { $Tier=@($fam.Tiers)[0] }
        $effect=[string]$fam.Effects[$Tier]
        if (-not $effect) { throw "Tier '$Tier' is not available for family '$family'." }
        return @([pscustomobject]@{name=$effect})
    }
    return @($mode.effects)
}

function Resolve-IUKUnifiedModeEffects([string]$ConfigFile,[string]$ModeFile,[string]$ModeName,[string]$Tier,[string]$EffectsDir) {
    $source = Get-IUKPreferredModeSource $ConfigFile $ModeFile $ModeName
    if ($source -eq 'config') {
        $mode = Get-IUKMagpieConfigMode $ConfigFile $ModeName
        if (-not $mode) { throw "Magpie config mode not found: $ModeName" }
        return @($mode.effects)
    }
    return @(Resolve-IUKModeEffects $ModeFile $ModeName $Tier $EffectsDir)
}

function Get-IUKFamilyTiers([string]$Family,[string]$EffectsDir) {
    $fam = @(Get-IUKMagpieFamilies $EffectsDir | Where-Object Family -eq $Family) | Select-Object -First 1
    if (-not $fam) { return @() }
    return @($fam.Tiers)
}

function Resolve-IUKFamilyEffect([string]$Family,[string]$Tier,[string]$EffectsDir) {
    $fam = @(Get-IUKMagpieFamilies $EffectsDir | Where-Object Family -eq $Family) | Select-Object -First 1
    if (-not $fam) { throw "Magpie HLSL family not found: $Family" }
    if (-not $Tier -or $fam.Tiers -notcontains $Tier) { $Tier=@($fam.Tiers)[0] }
    $effect=[string]$fam.Effects[$Tier]
    if (-not $effect) { throw "Tier '$Tier' is not available for family '$Family'." }
    return [pscustomobject]@{name=$effect}
}

function Test-IUKEffectsExist($Effects,[string]$EffectsDir) {
    $installed = @(Get-IUKMagpieEffects $EffectsDir)
    foreach($e in @($Effects)) {
        if ($installed -notcontains [string]$e.name) { throw "Magpie HLSL effect is not installed: $($e.name)" }
    }
}
