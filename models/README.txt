把 NCNN 模型放到这个目录。
每个模型必须至少有一对同名文件，例如：

  4x_MyModel.param
  4x_MyModel.bin

GUI 会自动扫描并显示模型名 4x_MyModel。

建议模型名中包含倍率：2x / x2 / 3x / x3 / 4x / x4。
这样“倍率=auto”时可以自动判断。

注意：本工具核心是 Real-ESRGAN NCNN Vulkan，因此并非所有 NCNN 网络架构都兼容。
最稳妥的是 Real-ESRGAN / ESRGAN 系列的 NCNN 模型。
