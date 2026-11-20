$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

. (Join-Path $root 'ConfigHelpers.ps1')
. (Join-Path $root 'ComfyUI.ps1')

function Assert($Cond, [string]$Msg) {
    if (-not $Cond) { throw "Assertion failed: $Msg" }
}

$mockServerCode = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
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
    public sealed class MockComfyServer : IDisposable
    {
        private readonly HttpListener _listener = new HttpListener();
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private readonly ConcurrentDictionary<string, WebSocket> _sockets = new ConcurrentDictionary<string, WebSocket>();
        private readonly ConcurrentDictionary<string, string> _histories = new ConcurrentDictionary<string, string>();
        private Task _loop;

        public int Port { get; private set; }
        public string BaseUrl { get { return "http://127.0.0.1:" + Port; } }
        public string Mode { get; set; } = "XPU";
        public string SimulateError { get; set; } = "";
        public int InterruptCount { get; private set; }
        public int UploadCount { get; private set; }
        public byte[] OutputPngBytes { get; set; }
        public string LastSubmittedPromptJson { get; private set; }

        public MockComfyServer(byte[] outputPngBytes)
        {
            OutputPngBytes = outputPngBytes;
            var tcp = new TcpListener(IPAddress.Loopback, 0);
            tcp.Start();
            Port = ((IPEndPoint)tcp.LocalEndpoint).Port;
            tcp.Stop();

            _listener.Prefixes.Add("http://127.0.0.1:" + Port + "/");
            _listener.Start();
            _loop = Task.Run(AcceptLoop);
        }

        private async Task AcceptLoop()
        {
            while (!_cts.IsCancellationRequested)
            {
                HttpListenerContext ctx = null;
                try
                {
                    ctx = await _listener.GetContextAsync();
                }
                catch
                {
                    if (_cts.IsCancellationRequested) break;
                    continue;
                }
                _ = Task.Run(() => HandleContext(ctx));
            }
        }

        private async Task HandleContext(HttpListenerContext ctx)
        {
            try
            {
                string path = ctx.Request.Url.AbsolutePath;
                if (path == "/ws" && ctx.Request.IsWebSocketRequest)
                {
                    string clientId = ctx.Request.QueryString["client_id"] ?? Guid.NewGuid().ToString("N");
                    var wsCtx = await ctx.AcceptWebSocketAsync(null);
                    _sockets[clientId] = wsCtx.WebSocket;
                    var buf = new byte[1024];
                    while (wsCtx.WebSocket.State == WebSocketState.Open && !_cts.IsCancellationRequested)
                    {
                        try
                        {
                            var res = await wsCtx.WebSocket.ReceiveAsync(new ArraySegment<byte>(buf), _cts.Token);
                            if (res.MessageType == WebSocketMessageType.Close) break;
                        }
                        catch { break; }
                    }
                    WebSocket removed;
                    _sockets.TryRemove(clientId, out removed);
                    return;
                }

                if (path == "/system_stats")
                {
                    string json = Mode == "CUDA"
                        ? "{\"system\":{\"comfyui_version\":\"0.3.20\",\"pytorch_version\":\"2.5.1+cu124\",\"os\":\"nt\"},\"devices\":[{\"name\":\"cuda:0 NVIDIA GeForce RTX 4070\",\"type\":\"cuda\",\"vram_total\":12884901888,\"vram_free\":11500000000}]}"
                        : "{\"system\":{\"comfyui_version\":\"0.3.20\",\"pytorch_version\":\"2.7.0+xpu\",\"os\":\"nt\"},\"devices\":[{\"name\":\"xpu:0 Intel(R) Arc(TM) B580 Graphics\",\"type\":\"xpu\",\"vram_total\":12884901888,\"vram_free\":12000000000}]}";
                    await WriteJson(ctx, 200, json);
                    return;
                }

                if (path == "/object_info")
                {
                    string json = "{"
                        + "\"LoadImage\":{\"input\":{\"required\":{\"image\":[[\"example.png\"]]}}},"
                        + "\"SaveImage\":{\"input\":{\"required\":{\"filename_prefix\":[\"STRING\"]}}},"
                        + "\"PreviewImage\":{\"input\":{\"required\":{}}},"
                        + "\"UpscaleModelLoader\":{\"input\":{\"required\":{\"model_name\":[[\"003_realSR_BSRGAN_DFO_s64w8_SwinIR-M_x4_GAN.pth\",\"HAT_SRx4_ImageNet-pretrain.pth\"]]}}},"
                        + "\"ImageUpscaleWithModel\":{\"input\":{\"required\":{\"upscale_model\":[\"UPSCALE_MODEL\"],\"image\":[\"IMAGE\"]}}}"
                        + "}";
                    await WriteJson(ctx, 200, json);
                    return;
                }

                if (path == "/upload/image" && ctx.Request.HttpMethod == "POST")
                {
                    using (var ms = new MemoryStream())
                    {
                        await ctx.Request.InputStream.CopyToAsync(ms);
                    }
                    UploadCount++;
                    await WriteJson(ctx, 200, "{\"name\":\"mock_uploaded.png\",\"subfolder\":\"\",\"type\":\"input\"}");
                    return;
                }

                if (path == "/prompt" && ctx.Request.HttpMethod == "POST")
                {
                    string body;
                    using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8))
                        body = await reader.ReadToEndAsync();

                    LastSubmittedPromptJson = body;
                    string clientId = "";
                    var cm = Regex.Match(body, "\"client_id\"\\s*:\\s*\"([^\"]+)\"");
                    if (cm.Success) clientId = cm.Groups[1].Value;

                    string promptId = Guid.NewGuid().ToString("N");
                    string outputNodeId = "node_save_xyz";
                    var sm = Regex.Match(body, "\"([^\"]+)\"\\s*:\\s*\\{[^\\{\\}]*\"class_type\"\\s*:\\s*\"SaveImage\"");
                    if (sm.Success) outputNodeId = sm.Groups[1].Value;

                    if (SimulateError == "cuda_on_xpu")
                    {
                        _histories[promptId] = "{\"" + promptId + "\":{\"status\":{\"status_str\":\"error\",\"messages\":[[\"execution_error\",{\"exception_message\":\"AssertionError: Torch not compiled with CUDA enabled\"}]]},\"outputs\":{}}}";
                        _ = Task.Run(async () =>
                        {
                            await Task.Delay(80);
                            await SendWsJson(clientId, "{\"type\":\"execution_error\",\"data\":{\"prompt_id\":\"" + promptId + "\",\"exception_message\":\"AssertionError: Torch not compiled with CUDA enabled\"}}");
                        });
                    }
                    else
                    {
                        _histories[promptId] = "{\"" + promptId + "\":{\"status\":{\"status_str\":\"success\",\"completed\":true},\"outputs\":{\"" + outputNodeId + "\":{\"images\":[{\"filename\":\"mock_out.png\",\"subfolder\":\"\",\"type\":\"output\"}]}}}}";
                        _ = Task.Run(async () =>
                        {
                            await Task.Delay(50);
                            await SendWsJson(clientId, "{\"type\":\"progress\",\"data\":{\"prompt_id\":\"" + promptId + "\",\"value\":1,\"max\":2}}");
                            await Task.Delay(40);
                            await SendWsJson(clientId, "{\"type\":\"progress\",\"data\":{\"prompt_id\":\"" + promptId + "\",\"value\":2,\"max\":2}}");
                            await Task.Delay(40);
                            await SendWsJson(clientId, "{\"type\":\"executing\",\"data\":{\"prompt_id\":\"" + promptId + "\",\"node\":null}}");
                        });
                    }

                    await WriteJson(ctx, 200, "{\"prompt_id\":\"" + promptId + "\",\"number\":1,\"node_errors\":{}}");
                    return;
                }

                if (path.StartsWith("/history/"))
                {
                    string pid = path.Substring("/history/".Length);
                    string hJson;
                    if (_histories.TryGetValue(pid, out hJson))
                        await WriteJson(ctx, 200, hJson);
                    else
                        await WriteJson(ctx, 200, "{}");
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

                if (path == "/interrupt")
                {
                    InterruptCount++;
                    await WriteJson(ctx, 200, "{\"ok\":true}");
                    return;
                }

                if (path == "/queue")
                {
                    await WriteJson(ctx, 200, "{\"ok\":true}");
                    return;
                }

                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
            }
            catch
            {
                try { ctx.Response.Close(); } catch {}
            }
        }

        private async Task SendWsJson(string clientId, string json)
        {
            WebSocket ws;
            if (!string.IsNullOrEmpty(clientId) && _sockets.TryGetValue(clientId, out ws) && ws.State == WebSocketState.Open)
            {
                var bytes = Encoding.UTF8.GetBytes(json);
                await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None);
            }
        }

        private static async Task WriteJson(HttpListenerContext ctx, int status, string json)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(json);
            ctx.Response.StatusCode = status;
            ctx.Response.ContentType = "application/json; charset=utf-8";
            ctx.Response.ContentLength64 = bytes.Length;
            await ctx.Response.OutputStream.WriteAsync(bytes, 0, bytes.Length);
            ctx.Response.Close();
        }

        public void Dispose()
        {
            _cts.Cancel();
            try { _listener.Stop(); } catch {}
            try { _listener.Close(); } catch {}
            foreach (var kv in _sockets)
            {
                try { kv.Value.Dispose(); } catch {}
            }
            _cts.Dispose();
        }
    }
}
'@

if (-not ('ImageUpscaleKit.Tests.MockComfyServer' -as [type])) {
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
    Add-Type -ReferencedAssemblies @($refMap.Values) -TypeDefinition $mockServerCode -Language CSharp
}

$work = Join-Path $root ('temp/comfy-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    Add-Type -AssemblyName System.Drawing
    $inDir = Join-Path $work '中文 输入'
    $outDir = Join-Path $work '中文 输出'
    New-Item -ItemType Directory -Force -Path $inDir, $outDir | Out-Null
    $img1 = Join-Path $inDir '测试 图一.png'
    $img2 = Join-Path $inDir '测试 图二.png'
    $outPngSample = Join-Path $work 'sample_out.png'

    $b = [System.Drawing.Bitmap]::new(24, 16)
    try { $b.Save($img1, [System.Drawing.Imaging.ImageFormat]::Png); $b.Save($img2, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $b.Dispose() }
    $b2 = [System.Drawing.Bitmap]::new(48, 32)
    try { $b2.Save($outPngSample, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $b2.Dispose() }
    $outBytes = [IO.File]::ReadAllBytes($outPngSample)

    $server = [ImageUpscaleKit.Tests.MockComfyServer]::new($outBytes)
    try {
        # 1. XPU & CUDA /system_stats parsing
        $server.Mode = 'XPU'
        $connXpu = Test-IUKComfyUIConnection -ApiUrl $server.BaseUrl
        Assert $connXpu.Connected 'Expected XPU mock server connected'
        Assert ($connXpu.BackendFamily -eq 'XPU') "Expected XPU backend family, got $($connXpu.BackendFamily)"
        Assert ($connXpu.PrimaryDeviceName -match 'Arc.*B580') "Unexpected XPU device name: $($connXpu.PrimaryDeviceName)"
        Assert ($connXpu.VramTotalMb -gt 12000) 'Expected 12GB VRAM reported'

        $server.Mode = 'CUDA'
        $connCuda = Test-IUKComfyUIConnection -ApiUrl $server.BaseUrl
        Assert ($connCuda.BackendFamily -eq 'CUDA') "Expected CUDA backend family, got $($connCuda.BackendFamily)"
        $server.Mode = 'XPU'

        # 2. Dynamic non-standard node ID workflow & mapping
        $wfPath = Join-Path $work 'dynamic_wf.json'
        $mapPath = Join-Path $work 'dynamic_wf.map.json'
        @{
            node_load_abc = @{ class_type = 'LoadImage'; inputs = @{ image = 'placeholder.png' }; _meta = @{ title = 'Custom Input' } }
            node_loader_99 = @{ class_type = 'UpscaleModelLoader'; inputs = @{ model_name = '003_realSR_BSRGAN_DFO_s64w8_SwinIR-M_x4_GAN.pth' } }
            node_up_mid = @{ class_type = 'ImageUpscaleWithModel'; inputs = @{ upscale_model = @('node_loader_99', 0); image = @('node_load_abc', 0) } }
            node_save_xyz = @{ class_type = 'SaveImage'; inputs = @{ filename_prefix = 'iuk'; images = @('node_up_mid', 0) } }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $wfPath -Encoding utf8NoBOM

        @{
            input_image = @{ class_type = 'LoadImage'; input = 'image' }
            output_node = @{ class_type = 'SaveImage' }
            parameters = @{
                upscale_model = @{ class_type = 'UpscaleModelLoader'; input = 'model_name'; type = 'string' }
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mapPath -Encoding utf8NoBOM

        # 3. Missing custom node preflight check
        $badWf = Join-Path $work 'missing_node_wf.json'
        @{
            n1 = @{ class_type = 'LoadImage'; inputs = @{ image = 'a.png' } }
            n2 = @{ class_type = 'UltimateSDUpscale'; inputs = @{ image = @('n1', 0) } }
            n3 = @{ class_type = 'SaveImage'; inputs = @{ images = @('n2', 0) } }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badWf -Encoding utf8NoBOM

        $threwMissing = $false
        try {
            Invoke-IUKComfyUIWorkflow -InputPath $img1 -OutputPath (Join-Path $outDir 'should_not_exist.png') -ApiUrl $server.BaseUrl -WorkflowPath $badWf -Root $root
        } catch {
            if ($_.Exception.Message -match 'MissingNode.*UltimateSDUpscale.*github\.com/ssitu/ComfyUI_UltimateSDUpscale') {
                $threwMissing = $true
            } else { throw }
        }
        Assert $threwMissing 'Preflight did not report missing custom node with install URL'

        # 4. CUDA-only execution error on XPU -> CudaNodeIncompatible (NOT corrupt model)
        $server.SimulateError = 'cuda_on_xpu'
        $threwCuda = $false
        try {
            Invoke-IUKComfyUIWorkflow -InputPath $img1 -OutputPath (Join-Path $outDir 'cuda_err.png') -ApiUrl $server.BaseUrl -WorkflowPath $wfPath -WorkflowMapPath $mapPath -Root $root
        } catch {
            if ($_.Exception.Message -match 'CudaNodeIncompatible' -and $_.Exception.Message -match '非模型文件损坏') {
                $threwCuda = $true
            } else { throw }
        }
        Assert $threwCuda 'Expected CudaNodeIncompatible error classification'
        $server.SimulateError = ''

        # 5. End-to-end Upscale.ps1 -Engine comfyui single + batch with Chinese paths & progress callbacks
        $singleOut = Join-Path $outDir '结果 图一.png'
        & (Join-Path $root 'Upscale.ps1') -Engine comfyui -InputPath $img1 -OutputPath $singleOut -ComfyEndpoint $server.BaseUrl -ComfyWorkflow $wfPath -ComfyWorkflowMap $mapPath -ComfyParamsJson '{"upscale_model":"HAT_SRx4_ImageNet-pretrain.pth"}'
        Assert (Test-Path -LiteralPath $singleOut -PathType Leaf) 'Single ComfyUI output missing'
        Assert ($server.LastSubmittedPromptJson -match 'HAT_SRx4_ImageNet-pretrain\.pth') 'Dynamic parameter mapping did not apply ComfyParamsJson'

        $batchOut = Join-Path $outDir '批量结果'
        & (Join-Path $root 'Upscale.ps1') -Engine comfyui -InputPath $inDir -OutputPath $batchOut -ComfyEndpoint $server.BaseUrl -ComfyWorkflow $wfPath -ComfyWorkflowMap $mapPath
        Assert (Test-Path -LiteralPath (Join-Path $batchOut '测试 图一.png')) 'Batch output 1 missing'
        Assert (Test-Path -LiteralPath (Join-Path $batchOut '测试 图二.png')) 'Batch output 2 missing'

        # 6. Task interrupt endpoint check
        Stop-IUKComfyTask -ApiUrl $server.BaseUrl -PromptId 'test-id-123'
        Assert ($server.InterruptCount -eq 1) "Expected 1 interrupt call, got $($server.InterruptCount)"
    } finally {
        $server.Dispose()
    }

    # 7. Local ComfyUI auto-detection tests (XPU portable, Venv, Unknown)
    $xpuDir = Join-Path $work 'ComfyUI_Windows_portable_xpu'
    New-Item -ItemType Directory -Force -Path (Join-Path $xpuDir 'python_embeded'), (Join-Path $xpuDir 'ComfyUI') | Out-Null
    'dummy' | Set-Content (Join-Path $xpuDir 'python_embeded\python.exe')
    'print("main")' | Set-Content (Join-Path $xpuDir 'ComfyUI\main.py')
    '@echo off`n.\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build' | Set-Content (Join-Path $xpuDir 'RUN_Launcher.bat')
    $detXpu = Find-IUKComfyUIInstall -InstallDir $xpuDir
    Assert ($detXpu.Found -and $detXpu.DetectedFlavor -eq 'XPU' -and -not $detXpu.NeedsManualOverride) "XPU portable detection failed: $($detXpu.Message)"

    $venvDir = Join-Path $work 'ComfyUI_venv'
    New-Item -ItemType Directory -Force -Path (Join-Path $venvDir 'venv\Scripts') | Out-Null
    'dummy' | Set-Content (Join-Path $venvDir 'venv\Scripts\python.exe')
    'print("main")' | Set-Content (Join-Path $venvDir 'main.py')
    $detVenv = Find-IUKComfyUIInstall -InstallDir $venvDir
    Assert ($detVenv.Found -and $detVenv.DetectedFlavor -eq 'Venv') "Venv detection failed: $($detVenv.Message)"

    $emptyDir = Join-Path $work 'EmptyDir'
    New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
    $detEmpty = Find-IUKComfyUIInstall -InstallDir $emptyDir
    Assert (-not $detEmpty.Found -and $detEmpty.NeedsManualOverride) 'Empty dir should require manual override'

    # 8. Cross-PC portability: missing config.local.json + no path leakage to config.json
    $fakeRoot = Join-Path $work 'FakeRepo'
    New-Item -ItemType Directory -Force -Path $fakeRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config.json') -Destination (Join-Path $fakeRoot 'config.json')
    $cfgNoLocal = Get-IUKConfig -Root $fakeRoot
    Assert (-not $cfgNoLocal.LocalExists -and $cfgNoLocal.Local.instances.Count -ge 1) 'Missing config.local.json should still load defaults cleanly'

    $customLocal = Set-IUKComfyInstance -LocalCfg $cfgNoLocal.Local -Instance ([pscustomobject]@{
        name = 'my-pc-xpu'; mode = 'managed'; api_url = 'http://127.0.0.1:8188'; install_dir = $xpuDir
    }) -SetActive
    $null = Save-IUKLocalConfig -LocalCfg $customLocal -Root $fakeRoot
    Save-IUKSharedConfig -SharedCfg $cfgNoLocal.Shared -Root $fakeRoot
    $sharedText = Get-Content -LiteralPath (Join-Path $fakeRoot 'config.json') -Raw
    Assert ($sharedText -notmatch 'my-pc-xpu' -and $sharedText -notmatch 'ComfyUI_Windows_portable_xpu') 'Local ComfyUI path leaked into shared config.json'

        # 9. Standalone ComfyUI Manager UI test + ComfyUI v3 COMBO preflight + CmbUpscaleModel override
    $v3ObjInfo = [pscustomobject]@{
        LoadImage = [pscustomobject]@{ input = [pscustomobject]@{ required = [pscustomobject]@{ image = @(@('a.png')) } } }
        UpscaleModelLoader = [pscustomobject]@{ input = [pscustomobject]@{ required = [pscustomobject]@{ model_name = @('COMBO', [pscustomobject]@{ options = @('4xUltrasharp_4xUltrasharpV10.pt') }) } } }
        ImageUpscaleWithModel = [pscustomobject]@{ input = [pscustomobject]@{} }
        SaveImage = [pscustomobject]@{ input = [pscustomobject]@{} }
    }
    $availV3 = Get-IUKComfyAvailableModels -ObjectInfo $v3ObjInfo
    Assert ($availV3.UpscaleModels -contains '4xUltrasharp_4xUltrasharpV10.pt') 'v3 COMBO UpscaleModels extraction failed'

    $v3WfMissing = [pscustomobject]@{
        '1' = [pscustomobject]@{ class_type = 'UpscaleModelLoader'; inputs = [pscustomobject]@{ model_name = 'Real_HAT_GAN_sharper.pth' } }
    }
    $pfV3Fail = Test-IUKComfyWorkflowPreflight -WorkflowObj $v3WfMissing -ObjectInfo $v3ObjInfo
    Assert (-not $pfV3Fail.Valid -and ($pfV3Fail.Errors -join "`n") -match 'MissingModel.*Real_HAT_GAN_sharper\.pth.*4xUltrasharp_4xUltrasharpV10\.pt') "v3 COMBO preflight failed to catch missing model: $($pfV3Fail.Errors -join '; ')"

    $v3WfOk = [pscustomobject]@{
        '1' = [pscustomobject]@{ class_type = 'UpscaleModelLoader'; inputs = [pscustomobject]@{ model_name = '4xUltrasharp_4xUltrasharpV10.pt' } }
    }
    $pfV3Ok = Test-IUKComfyWorkflowPreflight -WorkflowObj $v3WfOk -ObjectInfo $v3ObjInfo
    Assert $pfV3Ok.Valid "v3 COMBO preflight rejected valid installed model: $($pfV3Ok.Errors -join '; ')"

    Add-Type -AssemblyName System.Windows.Forms
    $mgr = & (Join-Path $root 'ComfyUI-Manager.ps1') -TestMode
    try {
        Assert ($null -ne $mgr.Form -and $null -ne $mgr.Panel) 'ComfyUI-Manager failed to initialize'
        $cnt = & $mgr.Panel.Context.PopulateAvailableModels $mgr.Panel.Context $v3ObjInfo
        Assert ($cnt -eq 1 -and $mgr.Panel.Context.CmbUpscaleModel.Items.Contains('4xUltrasharp_4xUltrasharpV10.pt')) 'ComfyUIPanel did not populate v3 UpscaleModelLoader models'
        $mgr.Panel.Context.CmbUpscaleModel.SelectedItem = '4xUltrasharp_4xUltrasharpV10.pt'
        $panelOpts = & $mgr.Panel.GetOptions
        Assert ($panelOpts.ComfyParams.upscale_model -eq '4xUltrasharp_4xUltrasharpV10.pt') "ComfyUIPanel GetOptions missing upscale_model override"
    } finally { $mgr.Form.Dispose() }

    Write-Host 'PASS: ComfyUI CUDA/XPU stats, dynamic node mapping, preflight missing-node, CUDA-on-XPU error classification, Chinese WS/HTTP execution, interrupt, portable/venv detection, and config separation.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath((Join-Path $root 'temp')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'comfy-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
