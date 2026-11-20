function Get-IUKDefaultLocalConfig {
    return [pscustomobject]@{
        active_instance = 'default'
        instances = @(
            [pscustomobject]@{
                name = 'default'
                mode = 'connect'
                api_url = 'http://127.0.0.1:8188'
                install_dir = ''
                python_path = ''
                startup_script = ''
                startup_args = ''
                gpu_hint = 'auto'
                auto_connect = $false
            }
        )
    }
}

function Normalize-IUKLocalConfig($Obj) {
    $def = Get-IUKDefaultLocalConfig
    if ($null -eq $Obj) { return $def }
    if (-not $Obj.PSObject.Properties['instances'] -or @($Obj.instances).Count -eq 0) {
        return $def
    }
    $clean = [System.Collections.Generic.List[object]]::new()
    foreach ($inst in @($Obj.instances)) {
        if (-not $inst -or [string]::IsNullOrWhiteSpace([string]$inst.name)) { continue }
        [void]$clean.Add([pscustomobject]@{
            name = [string]$inst.name
            mode = if ($inst.mode -in @('connect', 'managed')) { [string]$inst.mode } else { 'connect' }
            api_url = if ($inst.api_url) { ([string]$inst.api_url).TrimEnd('/') } else { 'http://127.0.0.1:8188' }
            install_dir = [string]($inst.install_dir ?? '')
            python_path = [string]($inst.python_path ?? '')
            startup_script = [string]($inst.startup_script ?? '')
            startup_args = [string]($inst.startup_args ?? '')
            gpu_hint = if ($inst.gpu_hint) { [string]$inst.gpu_hint } else { 'auto' }
            auto_connect = [bool]$inst.auto_connect
        })
    }
    if ($clean.Count -eq 0) { return $def }
    $active = if ($Obj.active_instance) { [string]$Obj.active_instance } else { [string]$clean[0].name }
    return [pscustomobject]@{
        active_instance = $active
        instances = @($clean)
    }
}

function Get-IUKConfig {
    param(
        [string]$Root = $PSScriptRoot
    )
    $sharedPath = Join-Path $Root 'config.json'
    if (-not (Test-Path -LiteralPath $sharedPath -PathType Leaf)) {
        throw "Shared config not found: $sharedPath"
    }
    $shared = Get-Content -LiteralPath $sharedPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $localPath = Join-Path $Root 'config.local.json'
    $localExists = Test-Path -LiteralPath $localPath -PathType Leaf
    $local = $null
    if ($localExists) {
        try {
            $rawLocal = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $local = Normalize-IUKLocalConfig $rawLocal
        } catch {
            $local = Get-IUKDefaultLocalConfig
        }
    } else {
        $local = Get-IUKDefaultLocalConfig
    }

    return [pscustomobject]@{
        Shared = $shared
        Local = $local
        SharedPath = $sharedPath
        LocalPath = $localPath
        LocalExists = $localExists
    }
}

function Save-IUKSharedConfig {
    param(
        [Parameter(Mandatory = $true)] $SharedCfg,
        [string]$Root = $PSScriptRoot
    )
    # Strip any accidental local instance paths so shared config stays portable across PCs.
    $clone = ($SharedCfg | ConvertTo-Json -Depth 12) | ConvertFrom-Json
    foreach ($forbidden in @('local_comfyui', 'comfyui_local_dir', 'instances')) {
        if ($clone.PSObject.Properties[$forbidden]) {
            $clone.PSObject.Properties.Remove($forbidden)
        }
    }
    $sharedPath = Join-Path $Root 'config.json'
    $clone | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $sharedPath -Encoding utf8NoBOM
}

function Save-IUKLocalConfig {
    param(
        [Parameter(Mandatory = $true)] $LocalCfg,
        [string]$Root = $PSScriptRoot
    )
    $norm = Normalize-IUKLocalConfig $LocalCfg
    $localPath = Join-Path $Root 'config.local.json'
    $norm | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $localPath -Encoding utf8NoBOM
    return $norm
}

function Get-IUKActiveComfyInstance {
    param(
        [Parameter(Mandatory = $true)] $LocalCfg,
        [string]$InstanceName
    )
    $norm = Normalize-IUKLocalConfig $LocalCfg
    $targetName = if ($InstanceName) { $InstanceName } else { [string]$norm.active_instance }
    $match = @($norm.instances | Where-Object { $_.name -eq $targetName }) | Select-Object -First 1
    if ($match) { return $match }
    return @($norm.instances)[0]
}

function Set-IUKComfyInstance {
    param(
        [Parameter(Mandatory = $true)] $LocalCfg,
        [Parameter(Mandatory = $true)] $Instance,
        [switch]$SetActive
    )
    $norm = Normalize-IUKLocalConfig $LocalCfg
    $list = [System.Collections.Generic.List[object]]::new()
    $replaced = $false
    foreach ($existing in @($norm.instances)) {
        if ($existing.name -eq [string]$Instance.name) {
            [void]$list.Add($Instance)
            $replaced = $true
        } else {
            [void]$list.Add($existing)
        }
    }
    if (-not $replaced) { [void]$list.Add($Instance) }
    $active = if ($SetActive) { [string]$Instance.name } else { [string]$norm.active_instance }
    return Normalize-IUKLocalConfig ([pscustomobject]@{
        active_instance = $active
        instances = @($list)
    })
}
