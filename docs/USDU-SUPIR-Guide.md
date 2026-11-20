# Ultimate SD Upscale (USDU) 与 SUPIR 使用及兼容性说明

---

## 一、Ultimate SD Upscale（分块扩散精修）

### 1. 节点来源与安装
- 仓库：https://github.com/ssitu/ComfyUI_UltimateSDUpscale
- 将仓库克隆至 ComfyUI 的 `custom_nodes\ComfyUI_UltimateSDUpscale` 并重启 ComfyUI（或通过 ComfyUI-Manager 安装）。
- 所需基础模型（放入 ComfyUI 对应目录）：
  - `models\checkpoints\`：SD1.5 或 SDXL 底模（如 `v1-5-pruned-emaonly.safetensors`）。
  - `models\upscale_models\`：预放大模型（如 `4x-UltraSharp.pth` 或 `RealESRGAN_x4plus.pth`）。

### 2. 内置预设
- **`usdu_fidelity`（USDU 保真优先）**：`denoise=0.20`、`cfg=5.5`、`steps=20`、`tile=512x512`、`mode_type=Chess`、`seam_fix_mode=Half Tile`、`tiled_decode=true`。优先保证人物五官、服装、构图不跑偏。
- **`usdu_detail`（USDU 细节增强）**：`denoise=0.35`、`cfg=6.5`、`steps=24`、`tile=768x768`，在保持原主体前提下增强发丝、布料纹理。

---

## 二、SUPIR（图像修复与超分辨率）

### 1. 模型授权与下载来源（重要）
- **原始项目**：https://github.com/Fanghua-Yu/SUPIR
  - **授权提示**：SUPIR 原始代码与官方权重采用 **非商业授权（Non-Commercial Research / Personal Use Only）**，商业用途前请务必自行核实原仓库最新许可条款。
- **ComfyUI 节点实现**：https://github.com/kijai/ComfyUI-SUPIR
  - 放入 `ComfyUI\custom_nodes\ComfyUI-SUPIR` 并按其 `requirements.txt` 安装依赖。
- **推荐权重来源**：
  - 精简安全张量权重（`SUPIR-v0Q_fp16.safetensors` / `SUPIR-v0F_fp16.safetensors`）：https://huggingface.co/Kijai/SUPIR_pruned
  - SDXL 基础模型（放入 `models\checkpoints\`）：`sd_xl_base_1.0.safetensors`

### 2. 12GB 显存优化策略（适用于 Intel Arc B580 12GB / RTX 12GB）
内置预设 **`supir_lowvram_12gb`** 与 **`supir_fidelity_12gb`** 默认开启：
- `use_tiled_vae = true`（`encoder_tile_size = 512`，`decoder_tile_size = 512`）
- `sampler = "TiledRestoreEDMSampler"`（`sampler_tile_size = 768`，`sampler_tile_stride = 384`）
- `fp8_unet = false`、`diffusion_dtype = "bf16"`（避免部分非 CUDA 设备对 fp8 支持不佳）
- `high_vram = false`、`keep_model_loaded = false`（推理后及时释放显存）

### 3. Intel Arc XPU 兼容性说明与 NVIDIA 路径
- **实情说明**：`ComfyUI-SUPIR` 上游主要在 NVIDIA CUDA 上测试；部分依赖包（或若额外启用 `xformers` / CUDA 扩展）在 Intel XPU 下可能无法执行或显存溢出回退系统内存。
- ImageUpscaleKit **不破坏**其他原生 ComfyUI 工作流（如 `spandrel` SwinIR/HAT 与 USDU）来强行给 SUPIR 打补丁：
  - 若在 XPU 上触发 CUDA 依赖报错，工具会明确提示 `CudaNodeIncompatible`。
  - 如需稳定运行 SUPIR，建议通过 `config.local.json` 配置一台 NVIDIA CUDA ComfyUI 实例，或在同一台配备 NVIDIA 显卡的设备上直接切换实例执行。
- 可通过 `-ComfyParams` 覆盖任何映射参数，例如：
  ```powershell
  .\Upscale.ps1 -Engine comfyui -InputPath .\input\test.png -ComfyPreset usdu_fidelity -ComfyParams @{ denoise = 0.25; checkpoint = 'your_model.safetensors'; upscale_model = '4x-UltraSharp.pth' }
  ```
