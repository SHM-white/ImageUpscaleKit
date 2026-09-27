# ImageUpscaleKit 交接文档

## 补充修复（2026-09-28）

- 修复 Magpie 启动时报 `SelectionType` 收到 `-OutputPath` 的参数校验错误。
- 原因：`Upscale.ps1` 调用 `MagpieBridge.ps1` 时用字符串数组展开参数，PowerShell 将数组元素按位置绑定，而不把其中的 `-名称` 解析为命名参数。
- 改为哈希表命名参数展开，保留未指定参数时读取配置、预设优先的行为。
- 已通过 10 组隔离转发验证：使用真实桥接脚本的参数声明替代后端执行，覆盖 mode/family/effect、preset、默认配置，有/无输出路径，以及中文和空格。`Upscale.ps1` 语法检查通过。
- 本次未运行真实 Magpie 窗口捕获和截图，完整超分链路仍需实机验证。

## 1. 项目目标

做一个 Windows 本地静态图片超分工具，重点服务二次元/AI CG 图片，要求：

- GUI 操作简单。
- 支持单图与文件夹批量处理。
- 参数、模型、效果链能通过 GUI 或配置文件快速调整。
- 同时支持两类后端：
  - Real-ESRGAN / NCNN Vulkan 神经网络模型。
  - MagpieFX / HLSL 效果。
- 尽量复用 Magpie 自己的 HLSL、效果链和配置格式，而不是重新实现一套 shader 解释器。

当前最新版本：**v4.1**。

---

## 2. 当前总体架构

```text
ImageUpscaleKit
│
├─ GUI.ps1                  # WinForms GUI
├─ Upscale.ps1              # 统一 CLI 入口 / 后端分发
├─ Upscale.cmd              # 拖拽/命令行入口
├─ Run-GUI.cmd              # 使用 pwsh -STA 启动 GUI
│
├─ Setup.ps1 / Setup.cmd    # 下载两个后端
│
├─ config.json              # 工具自身配置
│
├─ models\                  # NCNN .param + .bin
│
├─ MagpieBridge.ps1         # MagpieFX 静态图片桥接
├─ MagpieHelpers.ps1        # 扫描 HLSL / 解析 mode / family / tier
├─ ImageHost.ps1            # 把静态图片以 1:1 无边框窗口提供给 Magpie 捕获
│
├─ magpie_modes.json        # 工具自己的备用 Magpie mode 配置
├─ magpie_presets\          # v2 遗留预设，兼容保留
│
└─ bin\
   ├─ realesrgan-ncnn-vulkan.exe
   └─ magpie\
      ├─ Magpie.exe
      ├─ effects\            # 官方全部 HLSL
      └─ config\config.json  # 官方 Magpie 配置，v4 开始优先读取
```

统一入口是：

```text
GUI / Upscale.cmd
      ↓
Upscale.ps1
      ├─ ncnn   → realesrgan-ncnn-vulkan.exe
      └─ magpie → MagpieBridge.ps1
```

---

## 3. NCNN / Real-ESRGAN 当前状态

### 已实现

- 官方 `realesrgan-ncnn-vulkan` Windows 便携版自动下载。
- 自定义模型目录：`models\`。
- 模型格式：同名：

```text
xxx.param
xxx.bin
```

- GUI 可调：
  - model
  - scale: auto / 2 / 3 / 4
  - tile
  - GPU
  - threads
  - TTA
- 支持单图和目录输入。
- 输出可自动生成，也可指定文件/文件夹。
- 默认推荐模型：

```text
realesrgan-x4plus-anime
```

### 当前 `config.json` 默认值

```json
"ncnn": {
  "backend_path": "bin\\realesrgan-ncnn-vulkan.exe",
  "model_dir": "models",
  "model": "realesrgan-x4plus-anime",
  "scale": "auto",
  "tile": 0,
  "gpu": "auto",
  "threads": "1:2:2",
  "format": "png",
  "tta": false,
  "verbose": true
}
```

### 已遇到过的问题

早期 Windows PowerShell 5.1 会把 Real-ESRGAN 正常写入 stderr 的 GPU 信息包装成 `NativeCommandError`，配合 `$ErrorActionPreference='Stop'` 导致脚本中断。

后来明确改成 **PowerShell 7 (`pwsh`)** 为默认环境，不再以 5.1 为兼容目标。

当前仍建议在真实 Windows 环境继续验证 `2>&1 | Tee-Object` 的行为。

---

## 4. MagpieFX 当前设计

### 为什么没有自己重写 HLSL runner

MagpieFX 不只是普通 HLSL 文件，内部可能包含：

- 多 Pass
- FP16
- 中间纹理
- 特殊尺寸表达式
- effect 参数
- include

为了避免“只兼容一部分 MagpieFX”，当前方案直接让 **官方 Magpie 本体执行效果**。

### 当前静态图片处理链

```text
input.png
   ↓
ImageHost.ps1
   ↓
1:1 无边框 WinForms 图片窗口
   ↓ HWND
官方 Magpie
   ↓
MagpieFX / HLSL / effect chain
   ↓
Magpie 原生截图
   ↓
output.png
```

这不是理想的最终后端，但优点是 HLSL 解析和渲染与官方 Magpie 尽可能一致。

---

## 5. Magpie HLSL 支持

### 全量扫描

`MagpieHelpers.ps1` 会递归扫描：

```text
bin\magpie\effects\**\*.hlsl
```

并转换成 Magpie effect name，例如：

```text
bin\magpie\effects\Anime4K\Anime4K_Restore_L.hlsl
```

变成：

```text
Anime4K\Anime4K_Restore_L
```

所以理论上安装包中所有 Magpie 官方 HLSL 都能出现在 GUI 中。

### 三种选择模式

#### `mode`

缩放方案 / effect chain。

v4 开始优先读取官方：

```text
bin\magpie\config\config.json
```

里的：

```text
scalingModes
```

如果官方 config 不存在，则回退到：

```text
magpie_modes.json
```

#### `family`

自动把带档位后缀的 HLSL 归成模型族。

目前识别：

```text
_US
_S
_M
_L
_VL
_UL
```

例如：

```text
Anime4K_Restore_S
Anime4K_Restore_M
Anime4K_Restore_L
```

会归为：

```text
Anime4K_Restore
```

GUI 再单独选择档位。

#### `effect`

直接运行任意一个扫描到的 HLSL。

---

## 6. Magpie 原生 config.json 兼容

这是 v4 的核心改动。

### 当前行为

优先读取：

```text
bin\magpie\config\config.json
```

`config.json` 中对应设置：

```json
"magpie": {
  "exe_path": "bin\\magpie\\Magpie.exe",
  "effects_dir": "bin\\magpie\\effects",
  "config_file": "bin\\magpie\\config\\config.json",
  "mode_file": "magpie_modes.json"
}
```

如果你希望读取另一份 Magpie 配置，可以直接把 `config_file` 改成绝对路径。

### 处理时的逻辑

选择官方 config 中的 mode 时：

1. 读取整个官方 Magpie `config.json`。
2. 找到指定 `scalingModes[index]`。
3. 临时把默认 profile 的 `scalingMode` 指向该 index。
4. 临时修改：
   - 快捷键
   - screenshot directory
   - toolbar state
5. 启动 Magpie 处理。
6. `finally` 中恢复原来的 config 文件。

因此设计目标是：**最大程度保留 Magpie 原有 effect chain 和参数**。

### 注意

当前兼容重点是 `scalingModes`，并不是承诺 Magpie 每个 UI/全局选项都对静态图片有完全相同语义。

尤其：

```text
ScalingType::Fit
```

在 Magpie 中是“相对当前目标窗口/屏幕拟合”，对静态文件而言输出尺寸仍受临时窗口和 Magpie 窗口模式影响。这部分建议后续重点重构。

---

## 7. `magpie_modes.json` 的定位

v3 曾经把它作为主要配置。

v4 后定位改为：

> **备用 / 工具独立模式配置。**

支持额外便捷字段：

- `tiers`
- `autoFamily`

例如：

```json
{
  "name": "Anime4K Restore",
  "autoFamily": "Anime4K\\Anime4K_Restore",
  "defaultTier": "L"
}
```

以及固定倍率：

```json
{
  "name": "Lanczos",
  "tiers": {
    "2x": {
      "effects": [
        {
          "name": "Lanczos",
          "scalingType": 0,
          "scale": { "x": 2.0, "y": 2.0 }
        }
      ]
    }
  }
}
```

---

## 8. GUI 当前状态

技术栈：

```text
PowerShell 7
WinForms
STA thread
```

启动方式：

```bat
pwsh.exe -NoProfile -STA -File GUI.ps1
```

### 已实现

- Engine：NCNN / Magpie
- 输入：
  - 选图片
  - 选文件夹
- 输出：
  - 选文件
  - 选文件夹
  - 自动
- NCNN 参数区域
- MagpieFX 参数区域
- HLSL 刷新
- mode / family / effect
- 档位选择
- 效果链预览
- 打开 Magpie 配置
- 打开 HLSL 目录
- 日志入口

### 最近修复的重要 bug

原 GUI 把输入 TextBox 命名成：

```powershell
$input
```

但 `$input` 是 PowerShell 自动变量。

事件回调执行时 `$input` 被解释成自动变量而不是 TextBox，导致：

```text
The property 'Text' cannot be found on this object.
```

错误位置类似：

```text
GUI.ps1:120
```

v4.1 已改名为：

```text
$inputBox
$outputBox
```

后续开发应避免使用 PowerShell 自动变量名作为控件变量。

---

## 9. 文件夹选择问题

曾经两次出现“选择文件夹坏了”。

确认过的两个原因：

### 原因 1：STA

WinForms 对话框应运行在 STA。

已修复：

```bat
pwsh.exe -NoProfile -STA -File GUI.ps1
```

### 原因 2：`$input` 自动变量冲突

这是最近一次实际报错的根因。

v4.1 已修复。

### 后续建议

本地继续验证四个入口：

```text
选图片
选输入文件夹
选输出文件
选输出文件夹
```

重点测试：

- 路径带空格
- 中文路径
- 网络盘
- 不存在的输出目录
- 输入目录和输出目录相同

---

## 10. MagpieBridge 当前脆弱点

这是目前最值得继续改的部分。

### 10.1 截图按钮使用坐标点击

Magpie v0.12.1 没有适合当前脚本直接调用的“静态图片 CLI 截图接口”，当前通过定位缩放窗口后点击工具栏相机按钮。

配置：

```json
"toolbar_x_offset_dip": -106,
"toolbar_y_dip": 15
```

如果 Magpie UI 布局、DPI 或版本变化，可能失效。

### 10.2 依赖真实前台窗口

处理期间需要：

- ImageHost 成为前台
- 触发 Magpie 快捷键
- Magpie 缩放窗口正常出现

用户操作鼠标/切换窗口可能干扰。

### 10.3 Magpie 单实例

当前脚本会检查 `Magpie.exe`。

如果检测到其他路径下的 Magpie 正在运行，会拒绝继续，避免劫持用户已有实例。

### 10.4 输出尺寸语义

`ImageHost.ps1` 创建的是：

```powershell
$form.ClientSize = image.Width x image.Height
```

即源窗口 1:1。

但最终输出大小由 Magpie scaling mode 决定。

对于固定 x2/x4 shader 比较明确；对于 `Fit` 类型仍需继续确认静态文件的目标尺寸逻辑。

---

## 11. 长期更理想的架构

最终建议还是做一个真正的：

```text
MagpieFXCLI.exe
```

而不是长期依赖窗口捕获。

目标：

```text
input image
   ↓ WIC
ID3D11Texture2D
   ↓
Magpie EffectCompiler
   ↓
EffectDrawer
   ↓
MagpieFX effect chain
   ↓
ID3D11Texture2D
   ↓ WIC
output image
```

CLI 形式可设计为：

```bat
MagpieFXCLI.exe ^
  -i input.png ^
  -o output.png ^
  --config Magpie\config\config.json ^
  --mode Anime4K
```

或者：

```bat
MagpieFXCLI.exe ^
  -i input.png ^
  -o output.png ^
  -e Anime4K\Anime4K_Restore_L
```

这样可以彻底解决：

- 窗口前台依赖
- 工具栏坐标点击
- 截图 hack
- 批量处理速度
- 输出尺寸控制
- 用户操作干扰

Magpie 源码中真正有价值的部分是：

```text
Magpie.Core
EffectCompiler
EffectDrawer
EffectDesc
DeviceResources
TextureHelper
```

`Magpie.Core` 官方目前是静态库，不是现成 CLI，因此需要自己做一个薄 executable wrapper。

---

## 12. PowerShell / 编码约定

用户本地有 PowerShell 7，因此当前约定：

```text
最低运行环境：PowerShell 7
```

不再为 Windows PowerShell 5.1 做特殊兼容。

`.ps1` 建议统一：

```text
UTF-8 without BOM
```

之前用户提到 ANSI 是因为 PowerShell 5.1 编码问题；切到 pwsh 7 后不必坚持 ANSI。

---

## 13. Setup 当前行为

`Setup.ps1` 自动下载：

### Real-ESRGAN

```text
realesrgan-ncnn-vulkan-20220424-windows.zip
```

来源：官方 Real-ESRGAN release。

### Magpie

当前固定：

```text
Magpie v0.12.1 x64 portable
```

下载后放到：

```text
bin\magpie
```

并检查：

```text
bin\magpie\effects\*.hlsl
```

是否存在。

### 后续建议

Setup 不要永久写死版本，改成：

```json
"magpie_version": "v0.12.1"
```

或增加：

```text
latest stable
fixed version
```

两种策略。

---

## 14. 当前已知风险 / 未充分验证项

以下项目需要在真实 Windows 环境继续验证：

1. **v4.1 文件夹选择**

   - 已修复 `$input` 自动变量冲突，但应本地实际点一遍全部按钮。
2. **Magpie config 原生兼容**

   - 目前主要验证的是数据结构兼容思路。
   - 不同 Magpie 配置版本可能存在 schema 差异。
3. **Magpie config 恢复**

   - 已放在 `finally` 中恢复。
   - 建议进一步改成独立临时 portable 目录，完全避免动原 config。
4. **截图坐标 hack**

   - DPI、Magpie 版本、工具栏布局变化都可能影响。
5. **Magpie 批量速度**

   - 每张图片都创建 ImageHost / 开关缩放窗口，开销较大。
6. **超大图片**

   - ImageHost 直接按原图尺寸创建窗口。
   - 超过屏幕或 Windows 最大窗口尺寸时可能影响 Magpie 捕获。
   - 这是当前桥接架构的重要限制。
7. **透明 PNG**

   - WinForms PictureBox + Magpie 捕获不一定能保持 alpha。
   - 当前输出统一更偏向 RGB PNG。
8. **GIF / TIFF**

   - 当前扩展名允许输入，但实际只会按 `System.Drawing.Image` 的默认帧处理，不等价于完整多帧支持。
9. **NCNN 自定义模型兼容**

   - 只适用于 Real-ESRGAN NCNN 后端能识别的模型架构。
   - 不能把任意 OpenModelDB 模型直接丢进去。

---

## 15. 推荐的下一步开发顺序

### P0：先把当前 GUI 跑稳

1. 验证 v4.1 四个文件/文件夹选择按钮。
2. 验证单图 NCNN。
3. 验证目录 NCNN。
4. 验证 Magpie `effect`。
5. 验证 Magpie `mode` 读取官方 config。

### P1：Magpie bridge 去 hack

优先解决：

```text
工具栏坐标截图
前台窗口依赖
超大图窗口问题
```

### P2：开发 MagpieFXCLI

从 Magpie.Core 抽最小渲染链，真正实现：

```text
image file → DirectX texture → MagpieFX → image file
```

### P3：GUI 改进

如果 PowerShell GUI 越来越复杂，建议直接换：

```text
C# WinForms / WPF
```

因为当前已经涉及：

- 子进程
- 配置管理
- HLSL 元数据
- 批量任务
- Magpie profile
- 日志

继续用大型 `GUI.ps1` 可维护性会迅速下降。

---

## 16. 本地调试建议

建议先初始化 Git：

```bash
git init
git add .
git commit -m "baseline ImageUpscaleKit v4.1"
```

每修一个功能单独提交：

```text
fix: repair folder picker
feat: load native Magpie config
refactor: isolate Magpie config parser
feat: add MagpieFX native image runner
```

### 调试 GUI

不要双击后直接看闪退，优先从终端运行：

```powershell
cd D:\Desktop\ImageUpscaleKit
pwsh -NoProfile -STA -File .\GUI.ps1
```

### 调试统一 CLI

NCNN：

```powershell
pwsh .\Upscale.ps1 `
  -InputPath .\input `
  -Engine ncnn
```

Magpie：

```powershell
pwsh .\Upscale.ps1 `
  -InputPath .\input `
  -Engine magpie `
  -MagpieSelectionType mode `
  -MagpieMode Anime4K
```

先 CLI 跑通，再回 GUI 调试，定位会简单很多。

---

## 17. 当前版本文件

本轮最终交付版本：

```text
ImageUpscaleKit-v4.1-Windows.zip
```

v4.1 相比 v4 的关键修复：

```text
GUI 控件变量 $input/$output
→ $inputBox/$outputBox
```

这是当前继续开发时应作为 baseline 的版本。

---

## 18. 一句话总结

当前项目已经完成一个**可继续迭代的双后端原型**：NCNN 部分比较直接；MagpieFX 部分已经实现“全量 HLSL 扫描 + Magpie config 方案复用 + 静态图片桥接”，但真正需要继续投入的是把 Magpie 的“窗口捕获桥接”替换成独立的 DirectX 静态图片 runner。

## 补充修复：Magpie Host 变量冲突（2026-09-28）

- MagpieBridge.ps1 的图片宿主进程变量由 `$host` 改为 `$imageHostProcess`，启动与 finally 清理引用同步更新。PowerShell 变量名不区分大小写，原名称与只读自动变量 Host 冲突。
- 已通过脚本语法检查，并确认项目脚本无残留 Host 变量引用；未运行真实 Magpie 渲染截图。
