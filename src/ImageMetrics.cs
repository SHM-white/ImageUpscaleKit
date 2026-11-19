using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace ImageUpscaleKit.Metrics
{
    public sealed class ImageMetricResult
    {
        public double PsnrRgb { get; set; }
        public double PsnrY { get; set; }
        public double SsimY { get; set; }
        public int RefWidth { get; set; }
        public int RefHeight { get; set; }
        public int TestWidth { get; set; }
        public int TestHeight { get; set; }
        public bool ExactSizeMatch { get; set; }
        public string AlignmentPolicy { get; set; }
        public string ColorSpace { get; set; }
    }

    public static class ImageMetricsCalculator
    {
        private static Bitmap LoadArgbLockFree(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
                throw new FileNotFoundException("Image file not found.", path);

            byte[] bytes = File.ReadAllBytes(path);
            using (var ms = new MemoryStream(bytes, false))
            using (var src = Image.FromStream(ms, false, true))
            {
                var bmp = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
                bmp.SetResolution(96f, 96f);
                using (var g = Graphics.FromImage(bmp))
                {
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.DrawImage(src, new Rectangle(0, 0, src.Width, src.Height), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel);
                }
                return bmp;
            }
        }

        private static Bitmap ResizeToMatch(Bitmap src, int targetW, int targetH)
        {
            var dst = new Bitmap(targetW, targetH, PixelFormat.Format32bppArgb);
            dst.SetResolution(96f, 96f);
            using (var g = Graphics.FromImage(dst))
            {
                g.CompositingMode = CompositingMode.SourceCopy;
                g.CompositingQuality = CompositingQuality.HighQuality;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(src, new Rectangle(0, 0, targetW, targetH));
            }
            return dst;
        }

        private static byte[] ExtractBgraBytes(Bitmap bmp)
        {
            var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
            var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                int stride = Math.Abs(data.Stride);
                int rowBytes = bmp.Width * 4;
                byte[] buffer = new byte[bmp.Width * bmp.Height * 4];
                for (int y = 0; y < bmp.Height; y++)
                {
                    IntPtr rowPtr = IntPtr.Add(data.Scan0, y * data.Stride);
                    Marshal.Copy(rowPtr, buffer, y * rowBytes, rowBytes);
                }
                return buffer;
            }
            finally
            {
                bmp.UnlockBits(data);
            }
        }

        private static double[] BuildGaussianKernel1D(int radius, double sigma)
        {
            int size = radius * 2 + 1;
            double[] k = new double[size];
            double sum = 0.0;
            double denom = 2.0 * sigma * sigma;
            for (int i = -radius; i <= radius; i++)
            {
                double v = Math.Exp(-(i * i) / denom);
                k[i + radius] = v;
                sum += v;
            }
            for (int i = 0; i < size; i++)
                k[i] /= sum;
            return k;
        }

        private static double[] ConvolveSeparable(double[] src, int w, int h, double[] k, int radius)
        {
            double[] temp = new double[w * h];
            double[] dst = new double[w * h];

            for (int y = 0; y < h; y++)
            {
                int rowOff = y * w;
                for (int x = 0; x < w; x++)
                {
                    double acc = 0.0;
                    for (int i = -radius; i <= radius; i++)
                    {
                        int sx = Math.Max(0, Math.Min(w - 1, x + i));
                        acc += src[rowOff + sx] * k[i + radius];
                    }
                    temp[rowOff + x] = acc;
                }
            }

            for (int y = 0; y < h; y++)
            {
                int rowOff = y * w;
                for (int x = 0; x < w; x++)
                {
                    double acc = 0.0;
                    for (int j = -radius; j <= radius; j++)
                    {
                        int sy = Math.Max(0, Math.Min(h - 1, y + j));
                        acc += temp[sy * w + x] * k[j + radius];
                    }
                    dst[rowOff + x] = acc;
                }
            }

            return dst;
        }

        public static ImageMetricResult CompareFiles(string referencePath, string testPath)
        {
            using (var refBmp = LoadArgbLockFree(referencePath))
            using (var rawTestBmp = LoadArgbLockFree(testPath))
            {
                int refW = refBmp.Width;
                int refH = refBmp.Height;
                int testW = rawTestBmp.Width;
                int testH = rawTestBmp.Height;
                bool exact = (refW == testW && refH == testH);

                Bitmap alignedTest = exact ? rawTestBmp : ResizeToMatch(rawTestBmp, refW, refH);
                try
                {
                    byte[] refBytes = ExtractBgraBytes(refBmp);
                    byte[] testBytes = ExtractBgraBytes(alignedTest);
                    int n = refW * refH;

                    double[] yRef = new double[n];
                    double[] yTest = new double[n];
                    double[] yRefSq = new double[n];
                    double[] yTestSq = new double[n];
                    double[] yProd = new double[n];

                    double sumSqRgb = 0.0;
                    double sumSqY = 0.0;

                    for (int i = 0; i < n; i++)
                    {
                        int idx = i * 4;
                        double b1 = refBytes[idx];
                        double g1 = refBytes[idx + 1];
                        double r1 = refBytes[idx + 2];

                        double b2 = testBytes[idx];
                        double g2 = testBytes[idx + 1];
                        double r2 = testBytes[idx + 2];

                        double db = b1 - b2;
                        double dg = g1 - g2;
                        double dr = r1 - r2;
                        sumSqRgb += db * db + dg * dg + dr * dr;

                        double l1 = 0.299 * r1 + 0.587 * g1 + 0.114 * b1;
                        double l2 = 0.299 * r2 + 0.587 * g2 + 0.114 * b2;
                        double dl = l1 - l2;
                        sumSqY += dl * dl;

                        yRef[i] = l1;
                        yTest[i] = l2;
                        yRefSq[i] = l1 * l1;
                        yTestSq[i] = l2 * l2;
                        yProd[i] = l1 * l2;
                    }

                    double mseRgb = sumSqRgb / (3.0 * n);
                    double mseY = sumSqY / n;
                    double psnrRgb = mseRgb <= 1e-12 ? double.PositiveInfinity : 10.0 * Math.Log10((255.0 * 255.0) / mseRgb);
                    double psnrY = mseY <= 1e-12 ? double.PositiveInfinity : 10.0 * Math.Log10((255.0 * 255.0) / mseY);

                    // Wang et al. (2004) 11x11 Gaussian SSIM on BT.601 Y channel
                    const int radius = 5;
                    double[] kernel = BuildGaussianKernel1D(radius, 1.5);
                    double[] mu1 = ConvolveSeparable(yRef, refW, refH, kernel, radius);
                    double[] mu2 = ConvolveSeparable(yTest, refW, refH, kernel, radius);
                    double[] g1Sq = ConvolveSeparable(yRefSq, refW, refH, kernel, radius);
                    double[] g2Sq = ConvolveSeparable(yTestSq, refW, refH, kernel, radius);
                    double[] g12 = ConvolveSeparable(yProd, refW, refH, kernel, radius);

                    const double c1 = 6.5025;   // (0.01 * 255)^2
                    const double c2 = 58.5225;  // (0.03 * 255)^2

                    int xStart = refW > 12 ? radius : 0;
                    int xEnd = refW > 12 ? refW - radius : refW;
                    int yStart = refH > 12 ? radius : 0;
                    int yEnd = refH > 12 ? refH - radius : refH;

                    double ssimSum = 0.0;
                    long ssimCount = 0;
                    for (int y = yStart; y < yEnd; y++)
                    {
                        int row = y * refW;
                        for (int x = xStart; x < xEnd; x++)
                        {
                            int p = row + x;
                            double m1 = mu1[p];
                            double m2 = mu2[p];
                            double m1Sq = m1 * m1;
                            double m2Sq = m2 * m2;
                            double m12 = m1 * m2;

                            double s1Sq = Math.Max(0.0, g1Sq[p] - m1Sq);
                            double s2Sq = Math.Max(0.0, g2Sq[p] - m2Sq);
                            double s12 = g12[p] - m12;

                            double num = (2.0 * m12 + c1) * (2.0 * s12 + c2);
                            double den = (m1Sq + m2Sq + c1) * (s1Sq + s2Sq + c2);
                            ssimSum += num / den;
                            ssimCount++;
                        }
                    }

                    double ssimY = ssimCount > 0 ? (ssimSum / ssimCount) : 1.0;
                    if (mseY <= 1e-12) ssimY = 1.0;

                    return new ImageMetricResult
                    {
                        PsnrRgb = psnrRgb,
                        PsnrY = psnrY,
                        SsimY = ssimY,
                        RefWidth = refW,
                        RefHeight = refH,
                        TestWidth = testW,
                        TestHeight = testH,
                        ExactSizeMatch = exact,
                        AlignmentPolicy = exact ? "exact" : "bicubic_aligned_to_hr",
                        ColorSpace = "sRGB_BT601_Y"
                    };
                }
                finally
                {
                    if (!exact && alignedTest != null)
                        alignedTest.Dispose();
                }
            }
        }
    }
}
