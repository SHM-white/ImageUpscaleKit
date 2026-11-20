function Get-IUKModelRegistry {
    param(
        [string]$Root = $PSScriptRoot,
        [string]$Family
    )
    $regPath = Join-Path $Root 'models\registry.json'
    if (-not (Test-Path -LiteralPath $regPath -PathType Leaf)) {
        throw "Model registry not found: $regPath"
    }
    $reg = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $items = @($reg.models)
    if ($Family) {
        $items = @($items | Where-Object { [string]$_.family -ieq $Family })
    }
    return $items
}

function Resolve-IUKComfyModelSubdir {
    param(
        [string]$ComfyInstallDir,
        [Parameter(Mandatory = $true)] [string]$Subfolder
    )
    if ([string]::IsNullOrWhiteSpace($ComfyInstallDir) -or -not (Test-Path -LiteralPath $ComfyInstallDir -PathType Container)) {
        return ''
    }
    $nested = Join-Path $ComfyInstallDir ("ComfyUI\models\$Subfolder")
    if (Test-Path -LiteralPath (Join-Path $ComfyInstallDir 'ComfyUI') -PathType Container) {
        return $nested
    }
    return (Join-Path $ComfyInstallDir ("models\$Subfolder"))
}

function Resolve-IUKModelTargetPath {
    param(
        [Parameter(Mandatory = $true)] $Entry,
        [string]$Root = $PSScriptRoot,
        [string]$ComfyInstallDir = '',
        [string]$TargetDirOverride = ''
    )
    $fileName = [string]($Entry.check_relative_path ?? $Entry.filename)
    if ($TargetDirOverride) {
        return (Join-Path $TargetDirOverride ([IO.Path]::GetFileName($fileName)))
    }
    switch ([string]$Entry.target_dir_type) {
        'ncnn_models' { return (Join-Path (Join-Path $Root 'models') $fileName) }
        'realcugan_bin' { return (Join-Path (Join-Path $Root 'bin\realcugan') $fileName) }
        'anime4kcpp_bin' { return (Join-Path (Join-Path $Root 'bin\anime4kcpp') $fileName) }
        'comfy_upscale_models' {
            $dir = Resolve-IUKComfyModelSubdir -ComfyInstallDir $ComfyInstallDir -Subfolder 'upscale_models'
            if ($dir) { return (Join-Path $dir ([IO.Path]::GetFileName($fileName))) }
            return ''
        }
        'comfy_checkpoints' {
            $dir = Resolve-IUKComfyModelSubdir -ComfyInstallDir $ComfyInstallDir -Subfolder 'checkpoints'
            if ($dir) { return (Join-Path $dir ([IO.Path]::GetFileName($fileName))) }
            return ''
        }
        default { return (Join-Path (Join-Path $Root 'models') $fileName) }
    }
}

function Get-IUKModelStatus {
    param(
        [string]$Root = $PSScriptRoot,
        [string]$ComfyInstallDir = '',
        [string]$Family = '',
        [switch]$InstalledOnly
    )
    if (-not $ComfyInstallDir -and (Test-Path -LiteralPath (Join-Path $Root 'ConfigHelpers.ps1') -PathType Leaf)) {
        try {
            . (Join-Path $Root 'ConfigHelpers.ps1')
            $allCfg = Get-IUKConfig -Root $Root
            $inst = Get-IUKActiveComfyInstance -LocalCfg $allCfg.Local
            if ($inst -and $inst.install_dir) { $ComfyInstallDir = [string]$inst.install_dir }
        } catch {}
    }

    $entries = @(Get-IUKModelRegistry -Root $Root -Family $Family)
    $list = [System.Collections.Generic.List[object]]::new()

    foreach ($e in $entries) {
        $resolved = Resolve-IUKModelTargetPath -Entry $e -Root $Root -ComfyInstallDir $ComfyInstallDir
        $installed = $false
        $sizeBytes = 0L
        if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            $installed = $true
            $sizeBytes = (Get-Item -LiteralPath $resolved).Length
        }
        if ($InstalledOnly -and -not $installed) { continue }

        $statusLabel = if ($installed) { '已安装' }
                       elseif ($e.manual_download_required) { '需手动下载' }
                       else { '未安装' }

        [void]$list.Add([pscustomobject]@{
            Id = [string]$e.id
            Name = [string]$e.name
            Family = [string]$e.family
            Engine = [string]$e.engine
            Scale = $e.scale
            Filename = [string]$e.filename
            Version = [string]$e.version
            License = [string]$e.license
            CommercialUse = [bool]$e.commercial_use
            DownloadUrl = [string]$e.download_url
            Sha256 = [string]($e.sha256 ?? '')
            Installed = $installed
            StatusLabel = $statusLabel
            ResolvedPath = $resolved
            SizeBytes = $sizeBytes
            Notes = [string]($e.notes ?? '')
        })
    }
    return @($list)
}

function Install-IUKModel {
    param(
        [Parameter(Mandatory = $true)] [string]$ModelId,
        [string]$Root = $PSScriptRoot,
        [string]$ComfyInstallDir = '',
        [string]$TargetDir = '',
        [switch]$Force
    )
    $entries = @(Get-IUKModelRegistry -Root $Root)
    $entry = @($entries | Where-Object { $_.id -eq $ModelId }) | Select-Object -First 1
    if (-not $entry) { throw "Model ID not found in registry: $ModelId" }

    if ($entry.manual_download_required) {
        throw "Model '$ModelId' requires manual download due to size/license ($($entry.license)): $($entry.download_url)"
    }
    if (-not $entry.download_url) {
        throw "No download URL configured for model '$ModelId'."
    }

    if ([string]$entry.id -eq 'realcugan-ncnn-vulkan-pack') {
        & (Join-Path $Root 'Setup-RealCUGAN.ps1')
        return (Resolve-IUKModelTargetPath -Entry $entry -Root $Root)
    }
    if ([string]$entry.id -eq 'realesrgan-x4plus-anime') {
        & (Join-Path $Root 'Setup.ps1') -Engine ncnn
        return (Resolve-IUKModelTargetPath -Entry $entry -Root $Root)
    }

    if (-not $ComfyInstallDir -and -not $TargetDir -and (Test-Path -LiteralPath (Join-Path $Root 'ConfigHelpers.ps1') -PathType Leaf)) {
        try {
            . (Join-Path $Root 'ConfigHelpers.ps1')
            $allCfg = Get-IUKConfig -Root $Root
            $inst = Get-IUKActiveComfyInstance -LocalCfg $allCfg.Local
            if ($inst -and $inst.install_dir) { $ComfyInstallDir = [string]$inst.install_dir }
        } catch {}
    }

    $dest = Resolve-IUKModelTargetPath -Entry $entry -Root $Root -ComfyInstallDir $ComfyInstallDir -TargetDirOverride $TargetDir
    if (-not $dest) {
        throw "Target directory could not be resolved for '$ModelId'. Provide -TargetDir or -ComfyInstallDir."
    }

    if ((Test-Path -LiteralPath $dest -PathType Leaf) -and -not $Force) {
        $existingHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        if (-not $entry.sha256 -or $existingHash -ieq [string]$entry.sha256) {
            Write-Host "Model already installed and verified: $dest"
            return $dest
        }
    }

    $parent = Split-Path -Parent $dest
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $tmp = "$dest.tmp.$([guid]::NewGuid().ToString('N'))"
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $http = [System.Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromMinutes(30)
    $http.DefaultRequestHeaders.UserAgent.ParseAdd('ImageUpscaleKit/1.0')
    try {
        Write-Host "Downloading $($entry.name) from $($entry.download_url)..."
        $resp = $http.GetAsync([string]$entry.download_url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            throw "Download failed (HTTP $([int]$resp.StatusCode)): $($entry.download_url)"
        }
        $totalBytes = $resp.Content.Headers.ContentLength
        $inStream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outStream = [IO.File]::Create($tmp)
        try {
            $buf = [byte[]]::new(65536)
            $readTotal = 0L
            $lastPct = -10
            $nextUnknownMb = 5L
            while (($n = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
                $outStream.Write($buf, 0, $n)
                $readTotal += $n
                if ($totalBytes -and $totalBytes -gt 0) {
                    $pct = [int][Math]::Floor(($readTotal * 100.0) / $totalBytes)
                    if ($pct -ge ($lastPct + 10) -or $pct -eq 100) {
                        $lastPct = $pct
                        Write-Host ("Progress: {0}% ({1:F1} / {2:F1} MB)" -f $pct, ($readTotal / 1MB), ($totalBytes / 1MB))
                    }
                } elseif (($readTotal / 1MB) -ge $nextUnknownMb) {
                    Write-Host ("Progress: {0:F1} MB downloaded" -f ($readTotal / 1MB))
                    $nextUnknownMb += 5L
                }
            }
            if ($totalBytes -and $totalBytes -gt 0 -and $lastPct -lt 100) {
                Write-Host ("Progress: 100% ({0:F1} / {1:F1} MB)" -f ($readTotal / 1MB), ($totalBytes / 1MB))
            }
        } finally {
            $outStream.Dispose()
            $inStream.Dispose()
            $resp.Dispose()
        }
        if (-not (Test-Path -LiteralPath $tmp -PathType Leaf) -or (Get-Item -LiteralPath $tmp).Length -eq 0) {
            throw "Downloaded file is empty: $($entry.download_url)"
        }
        $actualHash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
        if ($entry.sha256 -and ($actualHash -ine [string]$entry.sha256)) {
            throw "SHA-256 mismatch for '$ModelId'. Expected: $($entry.sha256), Actual: $actualHash"
        }
        [IO.File]::Move($tmp, $dest, $true)
        Write-Host "Installed model: $dest (SHA256: $actualHash)" -ForegroundColor Green
        return $dest
    } finally {
        $http.Dispose()
        $handler.Dispose()
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}
