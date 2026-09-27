# Image Upscale Kit v4

Windows 便携图片超分工具，支持两个后端：

- **NCNN / Real-ESRGAN**：`.param + .bin` 模型。
- **MagpieFX**：直接调用官方 Magpie v0.12.1，动态扫描 `effects\` 下全部 `.hlsl`，并且**优先直接兼容 Magpie 自己的 `config.json`**。

## 首次使用

1. 安装 PowerShell 7。
2. 双击 `Setup.cmd`，下载 Real-ESRGAN NCNN 与官方 Magpie。
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
