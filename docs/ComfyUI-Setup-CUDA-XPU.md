# ComfyUI 安装与 CUDA / Intel Arc XPU 多机适配说明

ImageUpscaleKit **不会**在程序内部重复打包 PyTorch、CUDA 或 Intel XPU 运行环境，而是通过官方 HTTP / WebSocket API 对接独立安装的 ComfyUI。未安装或未连接 ComfyUI 时，Real-ESRGAN NCNN、Anime4KCPP、Real-CUGAN 与 MagpieFX 均可正常独立运行。

---

## 一、独立安装 ComfyUI（按 GPU 选择）

### 1. NVIDIA GPU（CUDA）
- 官方便携版或标准源码 + 虚拟环境安装：https://github.com/comfyanonymous/ComfyUI
- 便携版典型目录结构：
  ```text
  ComfyUI_windows_portable\
  ├─ python_embeded\python.exe
  ├─ ComfyUI\main.py
  └─ run_nvidia_gpu.bat
  ```

### 2. Intel Arc B580 等 Intel GPU（XPU）
- 推荐 Windows 便携包：https://github.com/YanWenKun/ComfyUI-WinPortable-XPU
- 典型目录结构：
  ```text
  ComfyUI_Windows_portable_xpu\
  ├─ python_embeded\python.exe
  ├─ ComfyUI\main.py
  └─ RUN_Launcher.bat
  ```
- 安装前请确保已安装最新 **Intel Arc 显卡驱动** 与 **Microsoft Visual C++ Redistributable x64**，并尽量解压到较浅目录（如 `D:\AI\ComfyUI_XPU`）以避免 Windows `MAX_PATH` 限制。

---

## 二、在 ImageUpscaleKit 中连接 ComfyUI

支持两种模式：

### 模式一：连接已运行的 ComfyUI
1. 启动您的 ComfyUI（默认地址 `http://127.0.0.1:8188`）。
2. 在 GUI 切换到 `comfyui` 引擎（或单独运行 `pwsh -NoProfile -STA -File .\ComfyUI-Manager.ps1`）。
3. 填写 API 地址并点击 **测试连接**，即可自动读取 GPU 后端类型（`CUDA` / `XPU` / `CPU`）、设备名称、显存大小及已安装节点数。

### 模式二：指定本地 ComfyUI 安装目录
1. 点击 **识别** 选择本机 ComfyUI 根目录。
2. 工具会**只读**探测 `python_embeded\python.exe`、`.venv\Scripts\python.exe`、`ComfyUI\main.py` 与常见 `.bat` 启动脚本（**绝不**自动覆盖或升级您的 ComfyUI 环境）。
3. 若目录结构非标准，可在「Python/脚本」框中手动填入您的启动脚本（`.bat`/`.py`）或 Python 可执行文件路径。
4. 点击 **启动本地**，日志会输出至 `logs/comfyui-*.log`。

---

## 三、多电脑与多实例配置（`config.local.json`）

- 共享预设与通用 UI 配置保存在 `config.json` 中（可随仓库/便携包跨机携带）。
- **本机路径与多实例配置**保存在 `config.local.json`（已被 `.gitignore` 忽略；参考模板 [config.local.example.json](../config.local.example.json)）。
- 可同时保存多个实例（例如 `local-xpu-b580`、`local-cuda-rtx`、`remote-lan`），在不同机器间切换无需修改共享配置；新机器缺失 `config.local.json` 时程序仍可正常启动。

---

## 四、CUDA 专用节点在 XPU 下的提示说明

部分第三方节点硬编码依赖 NVIDIA CUDA（例如 `xformers`、`triton`、`bitsandbytes`、`flash_attn` 或 `Torch not compiled with CUDA`）。  
当在 Intel XPU 下运行此类节点报错时，ImageUpscaleKit 会明确归类为 **`CudaNodeIncompatible`（检测到 CUDA 专用节点或依赖不兼容，非模型文件损坏）**，避免误判为模型损坏。
