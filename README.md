# Image Upscale Kit

Windows 便携图片超分工具，支持三个后端：

- **Anime4KCPP / ACNet**：直接读取图片并输出 2× PNG，支持单图、批处理、CPU / CUDA / OpenCL。
- **NCNN / Real-ESRGAN**：`.param + .bin` 模型。
- **MagpieFX**：直接调用官方 Magpie v0.12.1，动态扫描 `effects\` 下全部 `.hlsl`，并且**优先直接兼容 Magpie 自己的 `config.json`**。


## ACNet 2×（新增，当前默认）

双击 `Run-GUI.cmd`，引擎选择 `anime4kcpp`。默认模型 `acnet-legacy-gan`、处理器 `auto`、设备 `0`；模型下拉框从已安装 CLI 扫描全部内置模型，包括 ACNet、ARNet、ArtCNN、FSRCNNX；刷新时保留当前选择。

- `acnet-legacy-gan`：细节增强，先用它比较线条表现。
- `acnet-legacy-hdn0`：中等降噪；HDN1～3 降噪逐步增强。
- 新版 `acnet-f8b*` 也可选择。它们与 Magpie 的 ACNet shader 不保证逐像素一致。
- 直接 2× 输出，无需先做邻近采样放大，也无需窗口捕获/截图。
- 输入支持 PNG/JPEG/BMP/WebP/TIFF 静态图片；目录只处理第一层，TIFF 按默认帧处理。输出固定 PNG。
- 自动输出为 `原文件名_acnet_x2.png` 或 `原目录_acnet_x2`。GUI 的“已有文件”可选：停止并提示（默认）、覆盖已有文件、自动加序号（如 image_1.png、image_2.png）。自动编号也解决批内同名冲突；覆盖模式在成功生成新图后才替换旧结果，仍禁止覆盖输入原图。

仅安装 ACNet（不重新安装或修改 Magpie）：

```powershell
pwsh -NoProfile -File .\Setup-Anime4KCPP.ps1
# 或：Setup.cmd -Engine anime4kcpp
```

`Setup.cmd` 不带参数时安装全部三个后端。安装器固定官方 v3.2.0 Windows x64 CLI，并校验 SHA-256；模型内置，无需 NCNN .param/.bin。

```powershell
pwsh -NoProfile -File .\Upscale.ps1 -Engine anime4kcpp -InputPath .\input -Model acnet-legacy-gan -Scale 2 -AcProcessor auto -AcDevice 0
```

运行日志在 `logs/acnet-*.log`。为绕过官方图片加载器的中文路径问题，脚本在独立临时目录中使用英文文件名，成功后再移动到目标路径；检查退出码及输出存在性，因为部分原生加载错误仍返回 0。

回归测试：`pwsh -NoProfile -File .\tests\Smoke-Anime4KCPP.ps1`。

参考：[官方发布包](https://github.com/TianZerL/Anime4KCPP/releases/tag/v3.2.0)、[CLI 文档](https://github.com/TianZerL/Anime4KCPP/wiki/CLI)、[模型说明](https://github.com/TianZerL/Anime4KCPP/wiki/Model)。
## 首次使用

1. 安装 PowerShell 7。
2. 双击 `Setup.cmd`，下载 Anime4KCPP、Real-ESRGAN NCNN 与官方 Magpie。
3. 双击 `Run-GUI.cmd`。

> GUI 使用 `pwsh -STA`，输入/输出文件夹选择器已修复。

---

## v4 重点：直接兼容 Magpie 配置

MagpieFX 的 **mode** 选择现在优先读取：

```text
bin\magpie\config\config.json
```

也就是官方 Magpie 自己的配置文件。只要你在 Magpie 里：

- 新建 / 修改缩放方案
- 调整 effect chain
- 修改参数

本工具刷新后就会直接读到这些 `scalingModes`，不需要再维护第二套重复配置。

### 读取优先级

1. `bin\magpie\config\config.json`（官方 Magpie 配置）
2. `magpie_modes.json`（备用/兼容方案）

也就是说：

- **mode**：优先走 Magpie 原生 `config.json`
- **family**：自动扫描全部 HLSL，按 `_US/_S/_M/_L/_VL/_UL` 归族
- **effect**：直接选择任意单个 HLSL

### 重要说明

处理时，工具会：

1. 读取你的 Magpie `config.json`
2. 临时写入一份运行时配置（只改截图目录、快捷键、当前选中的 mode）
3. 处理完后**恢复原来的 `config.json`**

所以不会把你的 Magpie 配置永久改坏。

---

## MagpieFX：全部 HLSL

安装完成后，GUI 的 **全部 HLSL** 下拉框会递归扫描：

```text
bin\magpie\effects\**\*.hlsl
```

因此官方 Magpie 内带的 HLSL 都可以直接选；以后你自己往 `effects` 里增加 `.hlsl`，点击“刷新 HLSL”即可出现。

---

## Magpie 的 `config.json` 结构

本工具主要读取其中的：

```json
{
  "scalingModes": [
    {
      "name": "FSR",
      "effects": [
        {
          "name": "FSR\\FSR_EASU",
          "scalingType": 1
        },
        {
          "name": "FSR\\FSR_RCAS",
          "parameters": {
            "sharpness": 0.87
          }
        }
      ]
    }
  ]
}
```

如果你本来就在 Magpie 里维护这些方案，这版就能直接复用。

---

## 备用：magpie_modes.json

如果官方 `config.json` 还不存在，或者你想保留一套仅供本工具使用的模式，也可以继续用：

```text
magpie_modes.json
```

它支持：

- `scalingModes -> effects`
- `tiers`
- `autoFamily`

这套是备用机制，**不是默认首选**。

---

## 文件夹批量处理

点击“选文件夹”作为输入，再点击输出侧的“选文件夹”。如果不手动选输出，点“自动”会生成：

```text
输入目录: D:\Pictures\input
输出目录: D:\Pictures\input_upscaled
```

当前批量模式处理输入目录第一层中的 PNG/JPG/JPEG/BMP/GIF/TIF/TIFF。

---

## 目录说明

```text
ImageUpscaleKit-v4
├─ Run-GUI.cmd
├─ Setup.cmd
├─ Upscale.cmd
├─ GUI.ps1
├─ Upscale.ps1
├─ MagpieBridge.ps1
├─ MagpieHelpers.ps1
├─ config.json
├─ magpie_modes.json          # 备用 mode 配置
├─ models\
└─ bin\magpie\config\config.json   # Setup 后生成，优先读取
```

---

## 注意

- MagpieFX 后端目前通过 **官方 Magpie 的窗口捕获 + 原生 Effect 渲染 + 原生截图** 完成，所以 HLSL 兼容性尽量与官方保持一致。
- 处理期间不要主动操作 Magpie 缩放窗口。
- 如果截图按钮位置因 Magpie 版本变化而失效，可在 `config.json` 调整：

```json
"toolbar_x_offset_dip": -106,
"toolbar_y_dip": 15
```

ACNet 命令行输出策略：`-ExistingOutput error|overwrite|rename`；省略时读取 `config.json` 的 `anime4kcpp.existing_output`。此选项仅用于 Anime4KCPP。
