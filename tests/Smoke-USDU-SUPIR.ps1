$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

. (Join-Path $root 'ComfyUI.ps1')

function Assert($Cond, [string]$Msg) {
    if (-not $Cond) { throw "Assertion failed: $Msg" }
}

$mockUsduSupirCode = @'
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
    public sealed class MockUsduSupirServer : IDisposable
    {
        private readonly HttpListener _listener = new HttpListener();
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private readonly ConcurrentDictionary<string, WebSocket> _sockets = new ConcurrentDictionary<string, WebSocket>();
        private readonly ConcurrentDictionary<string, string> _histories = new ConcurrentDictionary<string, string>();

        public int Port { get; private set; }
        public string BaseUrl { get { return "http://127.0.0.1:" + Port; } }
        public string Mode { get; set; } = "CUDA";
        public bool IncludeCustomNodes { get; set; } = true;
        public string SimulateError { get; set; } = "";
        public byte[] OutputPngBytes { get; set; }
        public string LastPromptJson { get; private set; }

        public MockUsduSupirServer(byte[] outputPngBytes)
        {
            OutputPngBytes = outputPngBytes;
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

                if (path == "/system_stats")
                {
                    string json = Mode == "XPU"
                        ? "{\"system\":{\"comfyui_version\":\"0.3.20\",\"pytorch_version\":\"2.7.0+xpu\",\"os\":\"nt\"},\"devices\":[{\"name\":\"xpu:0 Intel(R) Arc(TM) B580 Graphics\",\"type\":\"xpu\",\"vram_total\":12884901888,\"vram_free\":11800000000}]}"
                        : "{\"system\":{\"comfyui_version\":\"0.3.20\",\"pytorch_version\":\"2.5.1+cu124\",\"os\":\"nt\"},\"devices\":[{\"name\":\"cuda:0 NVIDIA GeForce RTX 4070\",\"type\":\"cuda\",\"vram_total\":12884901888,\"vram_free\":11500000000}]}";
                    await WriteJson(ctx, json);
                    return;
                }

                if (path == "/object_info")
                {
                    var sb = new StringBuilder();
                    sb.Append("{");
                    sb.Append("\"LoadImage\":{\"input\":{\"required\":{\"image\":[[\"example.png\"]]}}},");
                    sb.Append("\"ImageScaleBy\":{\"input\":{\"required\":{}}},");
                    sb.Append("\"CheckpointLoaderSimple\":{\"input\":{\"required\":{\"ckpt_name\":[[\"v1-5-pruned-emaonly.safetensors\",\"sd_xl_base_1.0.safetensors\"]]}}},");
                    sb.Append("\"CLIPTextEncode\":{\"input\":{\"required\":{\"text\":[\"STRING\"]}}},");
                    sb.Append("\"UpscaleModelLoader\":{\"input\":{\"required\":{\"model_name\":[[\"4x-UltraSharp.pth\"]]}}},");
                    sb.Append("\"SaveImage\":{\"input\":{\"required\":{\"filename_prefix\":[\"STRING\"]}}}");
                    if (IncludeCustomNodes)
                    {
                        sb.Append(",\"UltimateSDUpscale\":{\"input\":{\"required\":{\"upscale_by\":[\"FLOAT\"]}}}");
                        sb.Append(",\"SUPIR_model_loader_v2\":{\"input\":{\"required\":{\"supir_model\":[[\"SUPIR-v0Q_fp16.safetensors\",\"SUPIR-v0F_fp16.safetensors\"]]}}}");
                        sb.Append(",\"SUPIR_first_stage\":{\"input\":{\"required\":{}}}");
                        sb.Append(",\"SUPIR_conditioner\":{\"input\":{\"required\":{}}}");
                        sb.Append(",\"SUPIR_sample\":{\"input\":{\"required\":{}}}");
                        sb.Append(",\"SUPIR_decode\":{\"input\":{\"required\":{}}}");
                    }
                    sb.Append("}");
                    await WriteJson(ctx, sb.ToString());
                    return;
                }

                if (path == "/upload/image")
                {
                    using (var ms = new MemoryStream()) await ctx.Request.InputStream.CopyToAsync(ms);
                    await WriteJson(ctx, "{\"name\":\"uploaded.png\",\"subfolder\":\"\",\"type\":\"input\"}");
                    return;
                }

                if (path == "/prompt")
                {
                    using (var r = new StreamReader(ctx.Request.InputStream, Encoding.UTF8))
                        LastPromptJson = await r.ReadToEndAsync();
                    var cm = Regex.Match(LastPromptJson, "\"client_id\"\\s*:\\s*\"([^\"]+)\"");
                    string cid = cm.Success ? cm.Groups[1].Value : "";
                    string pid = Guid.NewGuid().ToString("N");
                    string outId = "7";
                    var sm = Regex.Match(LastPromptJson, "\"([^\"]+)\"\\s*:\\s*\\{[^\\{\\}]*\"class_type\"\\s*:\\s*\"SaveImage\"");
                    if (sm.Success) outId = sm.Groups[1].Value;

                    if (SimulateError == "cuda_only")
                    {
                        _histories[pid] = "{\"" + pid + "\":{\"status\":{\"status_str\":\"error\",\"messages\":[[\"execution_error\",{\"exception_message\":\"RuntimeError: No CUDA GPUs are available for xformers\"}]]},\"outputs\":{}}}";
                        _ = Task.Run(async () =>
                        {
                            await Task.Delay(50);
                            await SendWs(cid, "{\"type\":\"execution_error\",\"data\":{\"prompt_id\":\"" + pid + "\",\"exception_message\":\"RuntimeError: No CUDA GPUs are available for xformers\"}}");
                        });
                    }
                    else
                    {
                        _histories[pid] = "{\"" + pid + "\":{\"status\":{\"status_str\":\"success\"},\"outputs\":{\"" + outId + "\":{\"images\":[{\"filename\":\"out.png\",\"subfolder\":\"\",\"type\":\"output\"}]}}}}";
                        _ = Task.Run(async () =>
                        {
                            await Task.Delay(40);
                            await SendWs(cid, "{\"type\":\"executing\",\"data\":{\"prompt_id\":\"" + pid + "\",\"node\":null}}");
                        });
                    }
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

        private async Task SendWs(string cid, string json)
        {
            WebSocket ws;
            if (_sockets.TryGetValue(cid, out ws) && ws.State == WebSocketState.Open)
            {
                var bytes = Encoding.UTF8.GetBytes(json);
                await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None);
            }
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

if (-not ('ImageUpscaleKit.Tests.MockUsduSupirServer' -as [type])) {
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
    Add-Type -ReferencedAssemblies @($refMap.Values) -TypeDefinition $mockUsduSupirCode -Language CSharp
}

# 1. Validate preset discovery and schema links
$presets = @(Get-IUKComfyPresets -Root $root)
$expectedIds = @('usdu_fidelity', 'usdu_detail', 'supir_lowvram_12gb', 'supir_fidelity_12gb')
foreach ($eid in $expectedIds) {
    $p = @($presets | Where-Object { $_.Id -eq $eid }) | Select-Object -First 1
    Assert ($null -ne $p) "Missing preset: $eid"
    Assert (Test-Path -LiteralPath $p.WorkflowPath -PathType Leaf) "Missing workflow for $eid"
    Assert (Test-Path -LiteralPath $p.WorkflowMapPath -PathType Leaf) "Missing map for $eid"
}

$usduWf = Get-Content -LiteralPath (Join-Path $root 'workflows\usdu\usdu_api_template.json') -Raw | ConvertFrom-Json
Assert ($usduWf.'6'.class_type -eq 'UltimateSDUpscale') 'USDU template class_type mismatch'
Assert ($usduWf.'6'.inputs.tiled_decode -eq $true -and $usduWf.'6'.inputs.batch_size -eq 1) 'USDU template memory defaults mismatch'

$supirWf = Get-Content -LiteralPath (Join-Path $root 'workflows\supir\supir_v2_api_template.json') -Raw | ConvertFrom-Json
Assert ($supirWf.'5'.class_type -eq 'SUPIR_first_stage') 'SUPIR first stage missing'
Assert ($supirWf.'6'.inputs.latents[1] -eq 2) 'SUPIR_conditioner must connect to SUPIR_first_stage slot 2 (denoised_latents)'
Assert ($supirWf.'7'.inputs.latents[1] -eq 2) 'SUPIR_sample must connect to SUPIR_first_stage slot 2 (denoised_latents)'
Assert ($supirWf.'8'.inputs.SUPIR_VAE[1] -eq 0) 'SUPIR_decode must connect to SUPIR_first_stage slot 0 (SUPIR_VAE)'
Assert ($supirWf.'7'.inputs.sampler -eq 'TiledRestoreEDMSampler') 'SUPIR 12GB template should default to TiledRestoreEDMSampler'

$work = Join-Path $root ('temp/usdu-supir-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    Add-Type -AssemblyName System.Drawing
    $inImg = Join-Path $work '中文 测试图.png'
    $outSample = Join-Path $work 'sample.png'
    $b = [System.Drawing.Bitmap]::new(24, 16)
    try { $b.Save($inImg, [System.Drawing.Imaging.ImageFormat]::Png); $b.Save($outSample, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $b.Dispose() }
    $pngBytes = [IO.File]::ReadAllBytes($outSample)

    $srv = [ImageUpscaleKit.Tests.MockUsduSupirServer]::new($pngBytes)
    try {
        # 2. USDU fidelity preset end-to-end with parameter override
        $usduOut = Join-Path $work '输出 usdu.png'
        & (Join-Path $root 'Upscale.ps1') -Engine comfyui -InputPath $inImg -OutputPath $usduOut -ComfyEndpoint $srv.BaseUrl -ComfyPreset 'usdu_fidelity' -ComfyParams @{ denoise = 0.25; tile_width = 640 }
        Assert (Test-Path -LiteralPath $usduOut -PathType Leaf) 'USDU output not created'
        Assert ($srv.LastPromptJson -match '"denoise"\s*:\s*0\.25') 'USDU denoise override not applied'
        Assert ($srv.LastPromptJson -match '"tile_width"\s*:\s*640') 'USDU tile_width override not applied'

        # 3. SUPIR 12GB low-VRAM preset end-to-end
        $supirOut = Join-Path $work '输出 supir.png'
        & (Join-Path $root 'Upscale.ps1') -Engine comfyui -InputPath $inImg -OutputPath $supirOut -ComfyEndpoint $srv.BaseUrl -ComfyPreset 'supir_lowvram_12gb'
        Assert (Test-Path -LiteralPath $supirOut -PathType Leaf) 'SUPIR output not created'
        Assert ($srv.LastPromptJson -match '"TiledRestoreEDMSampler"' -and $srv.LastPromptJson -match '"use_tiled_vae"\s*:\s*true') 'SUPIR 12GB low-VRAM flags missing'

        # 4. Simulated XPU with CUDA-only node error -> CudaNodeIncompatible
        $srv.Mode = 'XPU'
        $srv.SimulateError = 'cuda_only'
        $caughtCuda = $false
        try {
            & (Join-Path $root 'Upscale.ps1') -Engine comfyui -InputPath $inImg -OutputPath (Join-Path $work 'fail.png') -ComfyEndpoint $srv.BaseUrl -ComfyPreset 'supir_lowvram_12gb'
        } catch {
            if ($_.Exception.Message -match 'CudaNodeIncompatible') { $caughtCuda = $true } else { throw }
        }
        Assert $caughtCuda 'Expected CudaNodeIncompatible on XPU CUDA-only node failure'
        $srv.SimulateError = ''

        # 5. Missing custom nodes guidance
        $srv.IncludeCustomNodes = $false
        $Script:IUKComfyObjectInfoCache.Clear()
        $caughtMissing = $false
        try {
            Invoke-IUKComfyUIWorkflow -InputPath $inImg -OutputPath (Join-Path $work 'fail2.png') -ApiUrl $srv.BaseUrl -PresetName 'supir_lowvram_12gb' -Root $root
        } catch {
            if ($_.Exception.Message -match 'MissingNode.*SUPIR_model_loader_v2.*kijai/ComfyUI-SUPIR') { $caughtMissing = $true } else { throw }
        }
        Assert $caughtMissing 'Expected actionable SUPIR custom node install hint'
    } finally {
        $srv.Dispose()
    }

    Write-Host 'PASS: USDU & SUPIR template schemas, node slot indices, 12GB presets, parameter overrides, XPU error classification & missing node hints.'
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'usdu-supir-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
