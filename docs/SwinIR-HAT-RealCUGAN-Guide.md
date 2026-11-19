# SwinIR / HAT / Real-CUGAN 接入与模型管理指南

---

## 一、推理后端选型说明

1. **Real-CUGAN（独立 NCNN Vulkan 二进制）**
   - 来源：https://github.com/nihui/realcugan-ncnn-vulkan （发布版本 `20220728`，MIT 许可）
   - 运行在 Vulkan API 上，**Intel Arc B580、AMD、NVIDIA 均可开箱即用，无需 CUDA/PyTorch/ComfyUI**。
   - 一键安装：`Setup.cmd -Engine realcugan` 或 `pwsh -NoProfile -File .\Setup-RealCUGAN.ps1`（自动校验安装包 SHA-256）。
   - 支持模型族：`models-se`（标准）、`models-pro`（进阶降噪/画质）、`models-nose`（无降噪保守锐利），支持 2×/3×/4× 与降噪等级 `-1/0/1/2/3`。
   - 为避免原生命令行在含中文/空格路径下读取失败，脚本自动通过 `temp/realcugan-job-*` 英文临时文件桥接，并支持 `.bmp`/`.tif` 输入自动转码。

2. **SwinIR 与 HAT（复用 ComfyUI 原生 `spandrel` 节点）**
   - 来源项目：
     - SwinIR：https://github.com/JingyunLiang/SwinIR （Apache-2.0）
     - HAT：https://github.com/XPixelGroup/HAT （Apache-2.0，Hugging Face 镜像：https://huggingface.co/Acly/hat ）
   - ComfyUI 自带基于 `spandrel` 的 **`UpscaleModelLoader` + `ImageUpscaleWithModel`** 核心节点，无需安装额外自定义节点即可在 **NVIDIA CUDA** 与 **Intel Arc XPU** 上直接推理 SwinIR 与 HAT。
   - **架构说明**：`neosr-project/neosr` 属于训练框架，不直接作为稳定统一推理运行时引入；直接采用 NCNN Vulkan 与 ComfyUI 原生 `spandrel` 加载器更易维护。

---

## 二、按需模型管理（`ModelManager.ps1` & `models/registry.json`）

所有模型源、版本、许可证、商业使用说明及校验信息记录在 [models/registry.json](../models/registry.json) 中。未安装的模型不会影响已有后端或 GUI 启动。

```powershell
# 查看模型安装状态（可选指定本机 ComfyUI 目录）
. .\ModelManager.ps1
Get-IUKModelStatus

# 仅显示已安装模型
Get-IUKModelStatus -InstalledOnly

# 按需下载 SwinIR 或 HAT 模型到 ComfyUI\models\upscale_models（自动校验 SHA-256）
Install-IUKModel -ModelId swinir-realsr-x4-gan -ComfyInstallDir D:\AI\ComfyUI_Windows_portable_xpu
Install-IUKModel -ModelId hat-sr-x4 -ComfyInstallDir D:\AI\ComfyUI_Windows_portable_xpu
```
