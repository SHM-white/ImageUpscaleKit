$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

. (Join-Path $root 'ComfyUI.ps1')
. (Join-Path $root 'ModelManager.ps1')

function Assert($Cond, [string]$Msg) {
    if (-not $Cond) { throw "Assertion failed: $Msg" }
}

function Assert-ImageSize([string]$Path, [int]$W, [int]$H) {
    Assert (Test-Path -LiteralPath $Path -PathType Leaf) "Image does not exist: $Path"
    $img = [System.Drawing.Image]::FromFile($Path)
    try {
        Assert ($img.Width -eq $W -and $img.Height -eq $H) "Wrong dimensions for ${Path}: expected ${W}x${H}, got $($img.Width)x$($img.Height)"
    } finally { $img.Dispose() }
}

function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    $caught = $false
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error '$($_.Exception.Message)' (expected /$Pattern/)" }
        $caught = $true
    }
    Assert $caught "Expected failure matching: $Pattern"
}

$mockCode = @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ImageUpscaleKit.Tests
{
    public sealed class MockSpandrelAndModelServer : IDisposable
    {
        private readonly HttpListener _listener = new HttpListener();
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private readonly ConcurrentDictionary<string, WebSocket> _sockets = new ConcurrentDictionary<string, WebSocket>();
        private readonly ConcurrentDictionary<string, string> _histories = new ConcurrentDictionary<string, string>();

        public int Port { get; private set; }
        public string BaseUrl { get { return "http://127.0.0.1:" + Port; } }
        public byte[] OutputPngBytes { get; set; }
        public byte[] ModelPayloadBytes { get; set; }
        public string LastPromptJson { get; private set; }

        public MockSpandrelAndModelServer(byte[] outputPngBytes, byte[] modelPayloadBytes)
        {
            OutputPngBytes = outputPngBytes;
            ModelPayloadBytes = modelPayloadBytes;
            var tcp = new TcpListener(IPAddress.Loopback, 0);
            tcp.Start();
            Port = ((IPEndPoint)tcp.LocalEndpoint).Port;
            tcp.Stop();
            _listener.Prefixes.Add("http://127.0.0.1:" + Port + "/");
            _listener.Start();
            Task.Run(AcceptLoop);
        }

        private async Task AcceptLoop()
        {
            while (!_cts.IsCancellationRequested)
            {
                try
                {
                    var ctx = await _listener.GetContextAsync();
                    _ = Task.Run(() => HandleContext(ctx));
                }
                catch { if (_cts.IsCancellationRequested) break; }
            }
        }

        private async Task HandleContext(HttpListenerContext ctx)
        {
            try
            {
                string path = ctx.Request.Url.AbsolutePath;
                if (path == "/ws" && ctx.Request.IsWebSocketRequest)
                {
                    string cid = ctx.Request.QueryString["client_id"] ?? "";
                    var wsCtx = await ctx.AcceptWebSocketAsync(null);
                    _sockets[cid] = wsCtx.WebSocket;
                    var buf = new byte[512];
                    while (wsCtx.WebSocket.State == WebSocketState.Open && !_cts.IsCancellationRequested)
                    {
                        var r = await wsCtx.WebSocket.ReceiveAsync(new ArraySegment<byte>(buf), _cts.Token);
                        if (r.MessageType == WebSocketMessageType.Close) break;
                    }
                    return;
                }
                if (path == "/mock_model.pth")
                {
                    ctx.Response.StatusCode = 200;
                    ctx.Response.ContentType = "application/octet-stream";
                    ctx.Response.ContentLength64 = ModelPayloadBytes.Length;
                    await ctx.Response.OutputStream.WriteAsync(ModelPayloadBytes, 0, ModelPayloadBytes.Length);
                    ctx.Response.Close();
                    return;
                }
                if (path == "/system_stats")
                {
                    await WriteJson(ctx, "{\"system\":{\"comfyui_version\":\"0.3.20\",\"pytorch_version\":\"2.7.0+xpu\",\"os\":\"nt\"},\"devices\":[{\"name\":\"xpu:0 Intel(R) Arc(TM) B580 Graphics\",\"type\":\"xpu\",\"vram_total\":12884901888,\"vram_free\":12000000000}]}");
                    return;
                }
                if (path == "/object_info")
                {
                    await WriteJson(ctx, "{"
                        + "\"LoadImage\":{\"input\":{\"required\":{\"image\":[[\"example.png\"]]}}},"
                        + "\"UpscaleModelLoader\":{\"input\":{\"required\":{\"model_name\":[[\"003_realSR_BSRGAN_DFO_s64w8_SwinIR-M_x4_GAN.pth\",\"001_classicalSR_DF2K_s64w8_SwinIR-M_x2.pth\",\"HAT_SRx4_ImageNet-pretrain.pth\",\"Real_HAT_GAN_sharper.pth\"]]}}},"
                        + "\"ImageUpscaleWithModel\":{\"input\":{\"required\":{\"upscale_model\":[\"UPSCALE_MODEL\"],\"image\":[\"IMAGE\"]}}},"
                        + "\"SaveImage\":{\"input\":{\"required\":{\"filename_prefix\":[\"STRING\"]}}}"
                        + "}");
                    return;
                }
                if (path == "/upload/image")
                {
                    using (var ms = new MemoryStream()) await ctx.Request.InputStream.CopyToAsync(ms);
                    await WriteJson(ctx, "{\"name\":\"up.png\",\"subfolder\":\"\",\"type\":\"input\"}");
                    return;
                }
                if (path == "/prompt")
                {
                    using (var r = new StreamReader(ctx.Request.InputStream, Encoding.UTF8))
                        LastPromptJson = await r.ReadToEndAsync();
                    var cm = Regex.Match(LastPromptJson, "\"client_id\"\\s*:\\s*\"([^\"]+)\"");
                    string cid = cm.Success ? cm.Groups[1].Value : "";
                    string pid = Guid.NewGuid().ToString("N");
                    _histories[pid] = "{\"" + pid + "\":{\"status\":{\"status_str\":\"success\"},\"outputs\":{\"4\":{\"images\":[{\"filename\":\"out.png\",\"subfolder\":\"\",\"type\":\"output\"}]}}}}";
                    _ = Task.Run(async () =>
                    {
                        await Task.Delay(35);
                        WebSocket ws;
                        if (_sockets.TryGetValue(cid, out ws) && ws.State == WebSocketState.Open)
                        {
                            var b = Encoding.UTF8.GetBytes("{\"type\":\"executing\",\"data\":{\"prompt_id\":\"" + pid + "\",\"node\":null}}");
                            await ws.SendAsync(new ArraySegment<byte>(b), WebSocketMessageType.Text, true, CancellationToken.None);
                        }
                    });
                    await WriteJson(ctx, "{\"prompt_id\":\"" + pid + "\",\"node_errors\":{}}");
                    return;
                }
                if (path.StartsWith("/history/"))
                {
                    string pid = path.Substring("/history/".Length);
                    string hj;
                    await WriteJson(ctx, _histories.TryGetValue(pid, out hj) ? hj : "{}");
                    return;
                }
                if (path == "/view")
                {
                    ctx.Response.StatusCode = 200;
                    ctx.Response.ContentType = "image/png";
                    ctx.Response.ContentLength64 = OutputPngBytes.Length;
                    await ctx.Response.OutputStream.WriteAsync(OutputPngBytes, 0, OutputPngBytes.Length);
                    ctx.Response.Close();
                    return;
                }
                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
            }
            catch { try { ctx.Response.Close(); } catch {} }
        }

        private static async Task WriteJson(HttpListenerContext ctx, string json)
        {
            var bytes = Encoding.UTF8.GetBytes(json);
            ctx.Response.StatusCode = 200;
            ctx.Response.ContentType = "application/json; charset=utf-8";
            ctx.Response.ContentLength64 = bytes.Length;
            await ctx.Response.OutputStream.WriteAsync(bytes, 0, bytes.Length);
            ctx.Response.Close();
        }

        public void Dispose()
        {
            _cts.Cancel();
            try { _listener.Stop(); _listener.Close(); } catch {}
            _cts.Dispose();
        }
    }
}
'@

if (-not ('ImageUpscaleKit.Tests.MockSpandrelAndModelServer' -as [type])) {
    $refMap = @{}
    $psRefDir = Join-Path $PSHOME 'ref'
    if (Test-Path -LiteralPath $psRefDir -PathType Container) {
        foreach ($f in Get-ChildItem -LiteralPath $psRefDir -Filter '*.dll' -File) { $refMap[$f.Name] = $f.FullName }
    }
    foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
        if ($asm.IsDynamic -or [string]::IsNullOrEmpty($asm.Location)) { continue }
        $name = [IO.Path]::GetFileName($asm.Location)
        if (-not $refMap.ContainsKey($name)) { $refMap[$name] = $asm.Location }
    }
    Add-Type -ReferencedAssemblies @($refMap.Values) -TypeDefinition $mockCode -Language CSharp
}

Add-Type -AssemblyName System.Drawing

$work = Join-Path $root ('temp/swinir-rc-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $inDir = Join-Path $work '中文 输入'
    $outDir = Join-Path $work '中文 输出'
    New-Item -ItemType Directory -Force -Path $inDir, $outDir | Out-Null

    $imgPng = Join-Path $inDir '测试 图一.png'
    $imgBmp = Join-Path $inDir '测试 图二.bmp'
    $sampleOut = Join-Path $work 'sample_out.png'

    $b = [System.Drawing.Bitmap]::new(24, 16)
    $g = [System.Drawing.Graphics]::FromImage($b)
    try {
        $g.Clear([System.Drawing.Color]::White)
        $g.DrawLine([System.Drawing.Pens]::Black, 1, 1, 22, 14)
        $b.Save($imgPng, [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Save($imgBmp, [System.Drawing.Imaging.ImageFormat]::Bmp)
    } finally { $g.Dispose(); $b.Dispose() }

    $b2 = [System.Drawing.Bitmap]::new(96, 64)
    try { $b2.Save($sampleOut, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $b2.Dispose() }

    $entry = Join-Path $root 'Upscale.ps1'

    # 1. REAL Vulkan inference with Real-CUGAN (when installed in bin\realcugan)
    $rcExe = Join-Path $root 'bin\realcugan\realcugan-ncnn-vulkan.exe'
    if (Test-Path -LiteralPath $rcExe -PathType Leaf) {
        $rcOut2x = Join-Path $outDir '真实_rc_2x.png'
        & $entry -Engine realcugan -InputPath $imgPng -OutputPath $rcOut2x -Model models-se -Scale 2 -NoiseLevel -1
        Assert-ImageSize $rcOut2x 48 32

        $rcOut4x = Join-Path $outDir '真实_rc_4x.png'
        & $entry -Engine realcugan -InputPath $imgPng -OutputPath $rcOut4x -Model models-se -Scale 4 -NoiseLevel 0
        Assert-ImageSize $rcOut4x 96 64

        $rcBatchOut = Join-Path $outDir '批量 2x'
        & $entry -Engine realcugan -InputPath $inDir -OutputPath $rcBatchOut -Model models-pro -Scale 2 -NoiseLevel 3
        Assert-ImageSize (Join-Path $rcBatchOut '测试 图一.png') 48 32
        Assert-ImageSize (Join-Path $rcBatchOut '测试 图二.png') 48 32
        Write-Host 'PASS [REAL HARDWARE]: Real-CUGAN NCNN Vulkan single 2x/4x & folder batch (PNG+BMP) on Chinese/space paths.'
    } else {
        Write-Host 'SKIP Real-CUGAN hardware run: bin\realcugan\realcugan-ncnn-vulkan.exe not installed.'
    }

    # 2. Invalid option / parameter guard checks
    Assert-Fails { & $entry -Engine realcugan -InputPath $imgPng -Model models-nose -Scale 4 } 'Scale=2'
    Assert-Fails { & $entry -Engine realcugan -InputPath $imgPng -Model models-pro -Scale 4 } 'Scale 2/3'
    Assert-Fails { & $entry -Engine realcugan -InputPath $imgPng -Model models-se -Scale 4 -NoiseLevel 1 } 'NoiseLevel -1, 0, or 3'
    Assert-Fails { & $entry -Engine ncnn -InputPath $imgPng -NoiseLevel 0 } 'Real-CUGAN'

    # 3. ModelManager registry, missing-ComfyUI safety, SHA-256 verification, manual-download refusal
    $regAll = @(Get-IUKModelRegistry -Root $root)
    Assert ($regAll.Count -ge 7) "Expected >= 7 registry entries, got $($regAll.Count)"
    $statusMissingComfy = @(Get-IUKModelStatus -Root $root -ComfyInstallDir 'Z:\NonExistent\ComfyUI_Dir')
    Assert ($statusMissingComfy.Count -ge 7) 'Model status failed when ComfyUI missing'
    $installedOnly = @(Get-IUKModelStatus -Root $root -InstalledOnly)
    if (Test-Path -LiteralPath $rcExe -PathType Leaf) {
        Assert (@($installedOnly | Where-Object { $_.Id -eq 'realcugan-ncnn-vulkan-pack' }).Count -eq 1) 'Real-CUGAN pack should show installed'
    }
    Assert-Fails { Install-IUKModel -ModelId 'supir-v0q-fp16' -Root $root } 'manual download'

    # Local loopback HTTP model download + SHA-256 verification test
    $mockModelBytes = [Text.Encoding]::UTF8.GetBytes('MOCK_PTH_WEIGHT_BYTES_FOR_SHA256_CHECK')
    $expectedSha = ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($mockModelBytes))).ToLowerInvariant()
    $outBytes = [IO.File]::ReadAllBytes($sampleOut)
    $srv = [ImageUpscaleKit.Tests.MockSpandrelAndModelServer]::new($outBytes, $mockModelBytes)
    try {
        # Temp repo root copy to test Install-IUKModel safely with local server
        $fakeKit = Join-Path $work 'FakeKit'
        New-Item -ItemType Directory -Force -Path (Join-Path $fakeKit 'models') | Out-Null
        @{
            models = @(
                @{
                    id = 'test-good'
                    name = 'Test Good Model'
                    family = 'swinir'
                    engine = 'comfyui'
                    scale = 4
                    filename = 'test_good.pth'
                    target_dir_type = 'comfy_upscale_models'
                    version = '1.0'
                    source_repo = 'local'
                    download_url = "$($srv.BaseUrl)/mock_model.pth"
                    license = 'Apache-2.0'
                    commercial_use = $true
                    sha256 = $expectedSha
                },
                @{
                    id = 'test-bad-hash'
                    name = 'Test Bad Hash Model'
                    family = 'swinir'
                    engine = 'comfyui'
                    scale = 4
                    filename = 'test_bad.pth'
                    target_dir_type = 'comfy_upscale_models'
                    version = '1.0'
                    source_repo = 'local'
                    download_url = "$($srv.BaseUrl)/mock_model.pth"
                    license = 'Apache-2.0'
                    commercial_use = $true
                    sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
                }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fakeKit 'models\registry.json') -Encoding utf8NoBOM

        $targetModelsDir = Join-Path $work 'ComfyUI\models\upscale_models'
        $installedPath = Install-IUKModel -ModelId 'test-good' -Root $fakeKit -TargetDir $targetModelsDir
        Assert (Test-Path -LiteralPath $installedPath -PathType Leaf) 'Good SHA-256 model install missing'
        Assert-Fails { Install-IUKModel -ModelId 'test-bad-hash' -Root $fakeKit -TargetDir $targetModelsDir } 'SHA-256 mismatch'
        Assert (-not (Test-Path -LiteralPath (Join-Path $targetModelsDir 'test_bad.pth'))) 'Corrupt SHA-256 model was left behind'

        # 4. SwinIR & HAT presets via ComfyUI native spandrel workflow
        $presetChecks = @(
            @{ Preset = 'swinir_real_x4'; Model = '003_realSR_BSRGAN_DFO_s64w8_SwinIR-M_x4_GAN\.pth' },
            @{ Preset = 'swinir_classical_x2'; Model = '001_classicalSR_DF2K_s64w8_SwinIR-M_x2\.pth' },
            @{ Preset = 'hat_sr_x4'; Model = 'HAT_SRx4_ImageNet-pretrain\.pth' },
            @{ Preset = 'hat_real_x4'; Model = 'Real_HAT_GAN_sharper\.pth' }
        )
        foreach ($pc in $presetChecks) {
            $outP = Join-Path $outDir "$($pc.Preset).png"
            & $entry -Engine comfyui -InputPath $imgPng -OutputPath $outP -ComfyEndpoint $srv.BaseUrl -ComfyPreset $pc.Preset
            Assert (Test-Path -LiteralPath $outP -PathType Leaf) "Missing output for preset $($pc.Preset)"
            Assert ($srv.LastPromptJson -match $pc.Model) "Submitted prompt did not select model $($pc.Model)"
        }
    } finally {
        $srv.Dispose()
    }

    Write-Host 'PASS: Real-CUGAN validation/execution, ModelManager SHA-256 & ComfyUI spandrel SwinIR/HAT presets.'
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'swinir-rc-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
