# 超分测试集与性能/画质评测指南

---

## 一、标准测试集（`tests/benchmark/Generate-TestSet.ps1`）

为了确保测试集可再分发、可复现，脚本自动合成 6 类标准测试图（512×512 高清参考图 `hr/` 及对应的 2×/4× 退化输入 `lr_x2/`、`lr_x4/`）：

| 编号 | 类别 | 主要检查内容 | 退化方式 |
|---|---|---|---|
| `01_anime_character` | 动漫人物 | 五官、眼睛高光、发丝、五指手部与服装边界一致性 | Bicubic 下采样 |
| `02_illustration_lineart` | 插画/线稿 | 曲线连续性、交叉排线、锯齿与色块溢色 | Bicubic 下采样 |
| `03_realistic_portrait` | 真实人像 | 皮肤光照过渡、微纹理、眉眼真实性 | Bicubic 下采样 |
| `04_nature_landscape` | 自然风景 | 树叶高频纹理、砖墙窗格几何、天空渐变 | Bicubic 下采样 |
| `05_text_screenshot` | 文字/截图 | 中英混排文字笔画清晰度、1px UI 边框 | Bicubic 下采样 |
| `06_blur_compressed` | 模糊和压缩图 | JPEG Q35 块状伪影去除、振铃消除与锐度恢复 | 模糊 + JPEG Q35 重压缩 |

> 支持把自己的公开/个人参考原图放入 `hr/` 后再次运行 `Generate-TestSet.ps1`，会自动生成对应低分辨率测试对。

---

## 二、运行基准评测（`Benchmark.ps1`）

```powershell
# 运行 2x 全量评测（自动跳过未安装或离线的后端并记录原因）
pwsh -NoProfile -File .\Benchmark.ps1 -Scale 2

# 指定部分后端运行
pwsh -NoProfile -File .\Benchmark.ps1 -Scale 2 -Backends anime4kcpp,realcugan,ncnn

# 在对比器中一键加载生成的多算法对比清单
pwsh -NoProfile -STA -File .\ImageComparator.ps1 -ManifestPath .\temp\benchmark-<timestamp>\comparison_manifest.json
```

---

## 三、指标口径与公平性说明

1. **统一色彩空间与尺寸对齐（`src/ImageMetrics.cs`）**：
   - 所有 PSNR_Y 与 Wang et al. (2004) 11×11 高斯窗 SSIM_Y 均在 **sRGB BT.601 Y 分量**上计算。
   - 若某后端输出尺寸与参考原图不完全一致（例如 Magpie 窗口截图或非整数倍率输出），先通过高精度双三次（`HighQualityBicubic`）对齐至参考原图尺寸并在报告中标记 `bicubic_aligned_to_hr`。
2. **冷启动与连续推理耗时分离**：
   - 每个可用后端先单独执行第 1 张图像作为 **`ColdStartMs`**（包含进程启动与模型首次加载），随后连续执行全部图像记录单张耗时与平均 **`WarmAvgMs`**。
3. **生成式超分（USDU / SUPIR）评价提示**：
   - PSNR / SSIM 仅衡量像素级保真度；对于具备重绘生成能力的 Ultimate SD Upscale 与 SUPIR，必须结合对比器的 **局部放大（ROI）**、**滑块对比** 与人工五官/纹理一致性检查，不能仅凭 PSNR/SSIM 数值高低评判画质优劣。
