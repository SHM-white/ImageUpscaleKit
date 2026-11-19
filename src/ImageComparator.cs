using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Forms;

namespace ImageUpscaleKit.UI
{
    public enum CompareViewMode
    {
        SideBySide = 0,
        SplitSlider = 1,
        RoiZoom = 2
    }

    public enum ImageOverrideMode
    {
        None = 0,
        OriginalOnly = 1,
        ResultOnly = 2
    }

    public sealed class ImagePyramid : IDisposable
    {
        private readonly List<Bitmap> _levels = new List<Bitmap>();
        private bool _disposed;

        public string FilePath { get; private set; }
        public int OriginalWidth { get; private set; }
        public int OriginalHeight { get; private set; }
        public long FileSizeBytes { get; private set; }
        public bool HasAlpha { get; private set; }
        public int LevelCount { get { return _levels.Count; } }

        private ImagePyramid() { }

        public static ImagePyramid Load(string filePath)
        {
            if (string.IsNullOrWhiteSpace(filePath))
                throw new ArgumentException("Image path is empty.", nameof(filePath));
            if (!File.Exists(filePath))
                throw new FileNotFoundException("Image file not found.", filePath);

            byte[] bytes = File.ReadAllBytes(filePath);
            using (var ms = new MemoryStream(bytes, false))
            using (var src = Image.FromStream(ms, false, true))
            {
                int w = src.Width;
                int h = src.Height;
                if (w <= 0 || h <= 0)
                    throw new InvalidOperationException("Invalid image dimensions.");

                var baseBmp = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
                baseBmp.SetResolution(96f, 96f);
                using (var g = Graphics.FromImage(baseBmp))
                {
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.CompositingQuality = CompositingQuality.HighSpeed;
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    g.DrawImage(src, new Rectangle(0, 0, w, h), 0, 0, w, h, GraphicsUnit.Pixel);
                }

                var pyramid = new ImagePyramid
                {
                    FilePath = Path.GetFullPath(filePath),
                    OriginalWidth = w,
                    OriginalHeight = h,
                    FileSizeBytes = bytes.LongLength,
                    HasAlpha = Image.IsAlphaPixelFormat(src.PixelFormat)
                };
                pyramid._levels.Add(baseBmp);

                // Precompute downscaled mipmap levels for large images (>2048px)
                // so zooming and panning remain responsive without re-decoding files.
                Bitmap prev = baseBmp;
                while ((prev.Width > 2048 || prev.Height > 2048) && pyramid._levels.Count < 4)
                {
                    int nw = Math.Max(1, prev.Width / 2);
                    int nh = Math.Max(1, prev.Height / 2);
                    if (nw < 256 && nh < 256)
                        break;

                    var next = new Bitmap(nw, nh, PixelFormat.Format32bppPArgb);
                    next.SetResolution(96f, 96f);
                    using (var g = Graphics.FromImage(next))
                    {
                        g.CompositingMode = CompositingMode.SourceCopy;
                        g.CompositingQuality = CompositingQuality.HighQuality;
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        g.DrawImage(prev, new Rectangle(0, 0, nw, nh));
                    }
                    pyramid._levels.Add(next);
                    prev = next;
                }

                return pyramid;
            }
        }

        public Bitmap SelectLevel(float displayedWidth)
        {
            if (_disposed || _levels.Count == 0)
                return null;
            if (displayedWidth <= 0f)
                return _levels[0];

            for (int i = _levels.Count - 1; i >= 0; i--)
            {
                if (_levels[i].Width >= displayedWidth * 0.95f)
                    return _levels[i];
            }
            return _levels[0];
        }

        public void Dispose()
        {
            if (_disposed)
                return;
            _disposed = true;
            foreach (var bmp in _levels)
            {
                bmp?.Dispose();
            }
            _levels.Clear();
        }
    }

    public sealed class ComparatorResultItem
    {
        public string Id { get; set; }
        public string Label { get; set; }
        public string Engine { get; set; }
        public string Model { get; set; }
        public string FilePath { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public long FileSizeBytes { get; set; }
        public double ElapsedMs { get; set; }
        public string Notes { get; set; }
    }

    public sealed class ViewportState
    {
        private double _zoom = 1.0;
        private double _centerU = 0.5;
        private double _centerV = 0.5;

        public double Zoom
        {
            get { return _zoom; }
            set { _zoom = Math.Max(0.02, Math.Min(64.0, value)); }
        }

        public double CenterU
        {
            get { return _centerU; }
            set { _centerU = Math.Max(-0.5, Math.Min(1.5, value)); }
        }

        public double CenterV
        {
            get { return _centerV; }
            set { _centerV = Math.Max(-0.5, Math.Min(1.5, value)); }
        }

        public ViewportState Clone()
        {
            return new ViewportState
            {
                Zoom = Zoom,
                CenterU = CenterU,
                CenterV = CenterV
            };
        }
    }

    public class ImageComparatorControl : Control
    {
        private enum DragMode
        {
            None,
            PanLeft,
            PanRight,
            SplitDivider,
            RoiMove,
            RoiCreate,
            RoiResize,
            RoiDetailPan
        }

        private enum RoiHandle
        {
            None,
            TopLeft,
            Top,
            TopRight,
            Right,
            BottomRight,
            Bottom,
            BottomLeft,
            Left
        }

        private ImagePyramid _original;
        private readonly List<ComparatorResultItem> _results = new List<ComparatorResultItem>();
        private readonly Dictionary<int, ImagePyramid> _resultCache = new Dictionary<int, ImagePyramid>();
        private int _activeResultIndex = -1;

        private CompareViewMode _viewMode = CompareViewMode.SideBySide;
        private ImageOverrideMode _overrideMode = ImageOverrideMode.None;
        private bool _syncViewports = true;
        private bool _pixelPerfectZoom = true;
        private double _splitRatio = 0.5;
        private RectangleF _roiNormalized = new RectangleF(0.35f, 0.35f, 0.30f, 0.30f);
        private double _roiZoomFactor = 1.0;

        private readonly ViewportState _leftViewport = new ViewportState();
        private readonly ViewportState _rightViewport = new ViewportState();

        private DragMode _dragMode = DragMode.None;
        private RoiHandle _activeRoiHandle = RoiHandle.None;
        private Point _dragStartPoint;
        private double _dragStartCenterU;
        private double _dragStartCenterV;
        private RectangleF _dragStartRoi;
        private PointF _dragCreateAnchorNorm;

        private Bitmap _checkerTile;
        private TextureBrush _checkerBrush;
        private Font _hudFont;
        private Font _emptyFont;
        private Brush _hudBgBrush;
        private Brush _hudTextBrush;
        private Pen _dividerPen;
        private Pen _roiPen;
        private Pen _roiShadowPen;

        public event EventHandler ViewStateChanged;
        public event EventHandler SelectedResultChanged;

        public ImageComparatorControl()
        {
            SetStyle(
                ControlStyles.AllPaintingInWmPaint |
                ControlStyles.UserPaint |
                ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.ResizeRedraw |
                ControlStyles.Selectable,
                true);
            DoubleBuffered = true;
            ResizeRedraw = true;
            TabStop = true;
            BackColor = Color.FromArgb(30, 30, 30);

            _checkerTile = BuildCheckerBitmap();
            _checkerBrush = new TextureBrush(_checkerTile, WrapMode.Tile);
            _hudFont = new Font("Segoe UI", 8.5f, FontStyle.Regular);
            _emptyFont = new Font("Segoe UI", 10.5f, FontStyle.Regular);
            _hudBgBrush = new SolidBrush(Color.FromArgb(185, 18, 18, 22));
            _hudTextBrush = new SolidBrush(Color.FromArgb(240, 245, 250));
            _dividerPen = new Pen(Color.FromArgb(230, 255, 255, 255), 2f);
            _roiPen = new Pen(Color.FromArgb(255, 0, 210, 255), 2f);
            _roiShadowPen = new Pen(Color.FromArgb(180, 0, 0, 0), 4f);
        }

        private static Bitmap BuildCheckerBitmap()
        {
            var bmp = new Bitmap(16, 16, PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(bmp))
            using (var light = new SolidBrush(Color.FromArgb(74, 74, 78)))
            using (var dark = new SolidBrush(Color.FromArgb(54, 54, 58)))
            {
                g.FillRectangle(light, 0, 0, 8, 8);
                g.FillRectangle(dark, 8, 0, 8, 8);
                g.FillRectangle(dark, 0, 8, 8, 8);
                g.FillRectangle(light, 8, 8, 8, 8);
            }
            return bmp;
        }

        public CompareViewMode ViewMode
        {
            get { return _viewMode; }
            set
            {
                if (_viewMode != value)
                {
                    _viewMode = value;
                    Invalidate();
                    OnViewStateChanged();
                }
            }
        }

        public ImageOverrideMode OverrideMode
        {
            get { return _overrideMode; }
            set
            {
                if (_overrideMode != value)
                {
                    _overrideMode = value;
                    Invalidate();
                    OnViewStateChanged();
                }
            }
        }

        public bool SyncViewports
        {
            get { return _syncViewports; }
            set
            {
                if (_syncViewports != value)
                {
                    _syncViewports = value;
                    if (_syncViewports)
                    {
                        _rightViewport.Zoom = _leftViewport.Zoom;
                        _rightViewport.CenterU = _leftViewport.CenterU;
                        _rightViewport.CenterV = _leftViewport.CenterV;
                    }
                    Invalidate();
                    OnViewStateChanged();
                }
            }
        }

        public bool PixelPerfectZoom
        {
            get { return _pixelPerfectZoom; }
            set
            {
                if (_pixelPerfectZoom != value)
                {
                    _pixelPerfectZoom = value;
                    Invalidate();
                    OnViewStateChanged();
                }
            }
        }

        public double SplitRatio
        {
            get { return _splitRatio; }
            set
            {
                double clamped = Math.Max(0.02, Math.Min(0.98, value));
                if (Math.Abs(_splitRatio - clamped) > 1e-6)
                {
                    _splitRatio = clamped;
                    Invalidate();
                    OnViewStateChanged();
                }
            }
        }

        public RectangleF RoiNormalized
        {
            get { return _roiNormalized; }
            set
            {
                _roiNormalized = ClampRoi(value);
                Invalidate();
                OnViewStateChanged();
            }
        }

        public double RoiZoomFactor
        {
            get { return _roiZoomFactor; }
            set
            {
                double clamped = Math.Max(0.25, Math.Min(16.0, value));
                if (Math.Abs(_roiZoomFactor - clamped) > 1e-6)
                {
                    _roiZoomFactor = clamped;
                    Invalidate();
                    OnViewStateChanged();
                }
            }
        }

        public ViewportState LeftViewport { get { return _leftViewport; } }
        public ViewportState RightViewport { get { return _syncViewports ? _leftViewport : _rightViewport; } }

        public ImagePyramid OriginalImage { get { return _original; } }
        public ImagePyramid ActiveResultImage { get { return GetActiveResultPyramid(); } }
        public int ResultCount { get { return _results.Count; } }
        public int ActiveResultIndex { get { return _activeResultIndex; } }
        public ComparatorResultItem ActiveResultItem
        {
            get
            {
                if (_activeResultIndex >= 0 && _activeResultIndex < _results.Count)
                    return _results[_activeResultIndex];
                return null;
            }
        }

        public IReadOnlyList<ComparatorResultItem> Results
        {
            get { return _results.AsReadOnly(); }
        }

        public int ReferenceWidth
        {
            get
            {
                var res = GetActiveResultPyramid();
                if (res != null) return res.OriginalWidth;
                if (_original != null) return _original.OriginalWidth;
                return 0;
            }
        }

        public int ReferenceHeight
        {
            get
            {
                var res = GetActiveResultPyramid();
                if (res != null) return res.OriginalHeight;
                if (_original != null) return _original.OriginalHeight;
                return 0;
            }
        }

        public Rectangle SideBySideLeftPane
        {
            get
            {
                int w = Math.Max(1, ClientSize.Width);
                int h = Math.Max(1, ClientSize.Height);
                int sep = 4;
                int leftW = Math.Max(1, (w - sep) / 2);
                return new Rectangle(0, 0, leftW, h);
            }
        }

        public Rectangle SideBySideRightPane
        {
            get
            {
                int w = Math.Max(1, ClientSize.Width);
                int h = Math.Max(1, ClientSize.Height);
                int sep = 4;
                int leftW = Math.Max(1, (w - sep) / 2);
                int rightX = leftW + sep;
                return new Rectangle(rightX, 0, Math.Max(1, w - rightX), h);
            }
        }

        public Rectangle SplitPane
        {
            get { return new Rectangle(0, 0, Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height)); }
        }

        public Rectangle RoiOverviewPane
        {
            get
            {
                int w = Math.Max(1, ClientSize.Width);
                int h = Math.Max(1, ClientSize.Height);
                int ovW = Math.Max(120, (int)Math.Round(w * 0.38));
                return new Rectangle(0, 0, Math.Min(ovW, w), h);
            }
        }

        public Rectangle RoiOriginalPane
        {
            get
            {
                var ov = RoiOverviewPane;
                int sep = 4;
                int rx = ov.Right + sep;
                int rw = Math.Max(2, ClientSize.Width - rx);
                int h = Math.Max(1, ClientSize.Height);
                int paneW = Math.Max(1, (rw - sep) / 2);
                return new Rectangle(rx, 0, paneW, h);
            }
        }

        public Rectangle RoiResultPane
        {
            get
            {
                var orig = RoiOriginalPane;
                int sep = 4;
                int rx = orig.Right + sep;
                return new Rectangle(rx, 0, Math.Max(1, ClientSize.Width - rx), Math.Max(1, ClientSize.Height));
            }
        }

        private ImagePyramid GetActiveResultPyramid()
        {
            if (_activeResultIndex < 0 || _activeResultIndex >= _results.Count)
                return null;

            ImagePyramid cached;
            if (_resultCache.TryGetValue(_activeResultIndex, out cached) && cached != null)
                return cached;

            var item = _results[_activeResultIndex];
            if (item == null || string.IsNullOrWhiteSpace(item.FilePath) || !File.Exists(item.FilePath))
                return null;

            cached = ImagePyramid.Load(item.FilePath);
            item.Width = cached.OriginalWidth;
            item.Height = cached.OriginalHeight;
            item.FileSizeBytes = cached.FileSizeBytes;
            _resultCache[_activeResultIndex] = cached;
            return cached;
        }

        public void LoadOriginal(string filePath)
        {
            bool hadAny = _original != null || GetActiveResultPyramid() != null;
            int oldRefW = ReferenceWidth;
            double oldLeftW = oldRefW * _leftViewport.Zoom;
            double oldRightW = oldRefW * _rightViewport.Zoom;

            _original?.Dispose();
            _original = null;

            if (!string.IsNullOrWhiteSpace(filePath))
            {
                _original = ImagePyramid.Load(filePath);
            }

            if (!hadAny && _original != null)
            {
                FitToWindow();
            }
            else if (oldRefW > 0 && ReferenceWidth > 0)
            {
                _leftViewport.Zoom = oldLeftW / ReferenceWidth;
                _rightViewport.Zoom = oldRightW / ReferenceWidth;
            }

            Invalidate();
            OnViewStateChanged();
        }

        public void LoadResult(string filePath, string label = null)
        {
            if (string.IsNullOrWhiteSpace(filePath))
            {
                SetResults(Array.Empty<ComparatorResultItem>(), -1);
                return;
            }

            var item = new ComparatorResultItem
            {
                Id = Guid.NewGuid().ToString("N"),
                Label = string.IsNullOrWhiteSpace(label) ? Path.GetFileName(filePath) : label,
                FilePath = Path.GetFullPath(filePath)
            };
            SetResults(new[] { item }, 0);
        }

        public void SetResults(System.Collections.IEnumerable items, int selectIndex = 0)
        {
            int oldRefW = ReferenceWidth;
            double oldLeftW = oldRefW > 0 ? oldRefW * _leftViewport.Zoom : 0.0;
            double oldRightW = oldRefW > 0 ? oldRefW * _rightViewport.Zoom : 0.0;

            DisposeResultCache();
            _results.Clear();
            if (items != null)
            {
                foreach (var obj in items)
                {
                    var it = obj as ComparatorResultItem;
                    if (it != null)
                        _results.Add(it);
                }
            }

            if (_results.Count == 0)
            {
                _activeResultIndex = -1;
            }
            else
            {
                _activeResultIndex = Math.Max(0, Math.Min(_results.Count - 1, selectIndex));
                GetActiveResultPyramid();
            }

            if (oldRefW == 0 && ReferenceWidth > 0)
            {
                FitToWindow();
            }
            else if (oldLeftW > 0 && ReferenceWidth > 0)
            {
                _leftViewport.Zoom = oldLeftW / ReferenceWidth;
                _rightViewport.Zoom = oldRightW / ReferenceWidth;
            }

            Invalidate();
            OnSelectedResultChanged();
            OnViewStateChanged();
        }

        public void AddOrUpdateResult(ComparatorResultItem item, bool select = true)
        {
            if (item == null)
                return;

            int existing = -1;
            for (int i = 0; i < _results.Count; i++)
            {
                if ((!string.IsNullOrEmpty(item.Id) && _results[i].Id == item.Id) ||
                    (!string.IsNullOrEmpty(item.FilePath) && string.Equals(_results[i].FilePath, item.FilePath, StringComparison.OrdinalIgnoreCase)))
                {
                    existing = i;
                    break;
                }
            }

            int oldRefW = ReferenceWidth;
            double oldLeftW = oldRefW > 0 ? oldRefW * _leftViewport.Zoom : 0.0;
            double oldRightW = oldRefW > 0 ? oldRefW * _rightViewport.Zoom : 0.0;

            if (existing >= 0)
            {
                if (_resultCache.TryGetValue(existing, out var oldPyr))
                {
                    oldPyr?.Dispose();
                    _resultCache.Remove(existing);
                }
                _results[existing] = item;
                if (select)
                    _activeResultIndex = existing;
            }
            else
            {
                _results.Add(item);
                if (select || _activeResultIndex < 0)
                    _activeResultIndex = _results.Count - 1;
            }

            GetActiveResultPyramid();
            if (oldRefW == 0 && ReferenceWidth > 0)
            {
                FitToWindow();
            }
            else if (oldLeftW > 0 && ReferenceWidth > 0)
            {
                _leftViewport.Zoom = oldLeftW / ReferenceWidth;
                _rightViewport.Zoom = oldRightW / ReferenceWidth;
            }

            Invalidate();
            OnSelectedResultChanged();
            OnViewStateChanged();
        }

        public void SelectResult(int index)
        {
            if (_results.Count == 0)
            {
                _activeResultIndex = -1;
                Invalidate();
                OnSelectedResultChanged();
                OnViewStateChanged();
                return;
            }

            int clamped = Math.Max(0, Math.Min(_results.Count - 1, index));
            int oldRefW = ReferenceWidth;
            double oldLeftW = oldRefW > 0 ? oldRefW * _leftViewport.Zoom : 0.0;
            double oldRightW = oldRefW > 0 ? oldRefW * _rightViewport.Zoom : 0.0;

            _activeResultIndex = clamped;
            GetActiveResultPyramid();

            if (oldLeftW > 0 && ReferenceWidth > 0)
            {
                // Preserve exact physical screen size and normalized framing across 2x/4x switching.
                _leftViewport.Zoom = oldLeftW / ReferenceWidth;
                _rightViewport.Zoom = oldRightW / ReferenceWidth;
            }

            Invalidate();
            OnSelectedResultChanged();
            OnViewStateChanged();
        }

        public void ClearAll()
        {
            _original?.Dispose();
            _original = null;
            DisposeResultCache();
            _results.Clear();
            _activeResultIndex = -1;
            _leftViewport.Zoom = 1.0;
            _leftViewport.CenterU = 0.5;
            _leftViewport.CenterV = 0.5;
            _rightViewport.Zoom = 1.0;
            _rightViewport.CenterU = 0.5;
            _rightViewport.CenterV = 0.5;
            Invalidate();
            OnSelectedResultChanged();
            OnViewStateChanged();
        }

        public void FitToWindow()
        {
            int refW = ReferenceWidth;
            int refH = ReferenceHeight;
            if (refW <= 0 || refH <= 0)
                return;

            Rectangle pane = (_viewMode == CompareViewMode.SideBySide && _overrideMode == ImageOverrideMode.None)
                ? SideBySideLeftPane
                : SplitPane;

            float availW = Math.Max(20, pane.Width - 24);
            float availH = Math.Max(20, pane.Height - 24);
            double fitZoom = Math.Min(availW / refW, availH / refH);

            _leftViewport.Zoom = fitZoom;
            _leftViewport.CenterU = 0.5;
            _leftViewport.CenterV = 0.5;
            _rightViewport.Zoom = fitZoom;
            _rightViewport.CenterU = 0.5;
            _rightViewport.CenterV = 0.5;

            Invalidate();
            OnViewStateChanged();
        }

        public void SetZoomPercent(double percent)
        {
            double z = Math.Max(2.0, Math.Min(6400.0, percent)) / 100.0;
            _leftViewport.Zoom = z;
            if (_syncViewports)
                _rightViewport.Zoom = z;
            else
                _rightViewport.Zoom = z;
            Invalidate();
            OnViewStateChanged();
        }

        public void ResetRoi()
        {
            _roiNormalized = new RectangleF(0.35f, 0.35f, 0.30f, 0.30f);
            _roiZoomFactor = 1.0;
            Invalidate();
            OnViewStateChanged();
        }

        public RectangleF ComputeImageRect(Rectangle paneRect, ViewportState vp)
        {
            int refW = ReferenceWidth;
            int refH = ReferenceHeight;
            if (refW <= 0 || refH <= 0 || paneRect.Width <= 0 || paneRect.Height <= 0 || vp == null)
                return RectangleF.Empty;

            float drawW = (float)(refW * vp.Zoom);
            float drawH = (float)(refH * vp.Zoom);
            float cx = paneRect.Left + paneRect.Width * 0.5f;
            float cy = paneRect.Top + paneRect.Height * 0.5f;
            float x = cx - (float)(vp.CenterU * drawW);
            float y = cy - (float)(vp.CenterV * drawH);
            return new RectangleF(x, y, drawW, drawH);
        }

        public PointF ScreenToNormalized(Point clientPt, Rectangle paneRect, ViewportState vp)
        {
            var rect = ComputeImageRect(paneRect, vp);
            if (rect.Width <= 0f || rect.Height <= 0f)
                return new PointF(0.5f, 0.5f);
            float u = (clientPt.X - rect.Left) / rect.Width;
            float v = (clientPt.Y - rect.Top) / rect.Height;
            return new PointF(u, v);
        }

        private RectangleF ComputeOverviewImageRect(Rectangle ovPane)
        {
            int refW = ReferenceWidth;
            int refH = ReferenceHeight;
            if (refW <= 0 || refH <= 0 || ovPane.Width <= 0 || ovPane.Height <= 0)
                return RectangleF.Empty;

            int pad = 12;
            float availW = Math.Max(16, ovPane.Width - pad * 2);
            float availH = Math.Max(16, ovPane.Height - pad * 2 - 28);
            float scale = Math.Min(availW / refW, availH / refH);
            float drawW = refW * scale;
            float drawH = refH * scale;
            float x = ovPane.Left + (ovPane.Width - drawW) * 0.5f;
            float y = ovPane.Top + 28 + (ovPane.Height - 28 - drawH) * 0.5f;
            return new RectangleF(x, y, drawW, drawH);
        }

        private RectangleF GetEffectiveDetailRoi()
        {
            var r = ClampRoi(_roiNormalized);
            if (Math.Abs(_roiZoomFactor - 1.0) < 1e-6)
                return r;
            float cx = r.X + r.Width * 0.5f;
            float cy = r.Y + r.Height * 0.5f;
            float nw = Math.Max(0.005f, Math.Min(1.0f, (float)(r.Width / _roiZoomFactor)));
            float nh = Math.Max(0.005f, Math.Min(1.0f, (float)(r.Height / _roiZoomFactor)));
            return ClampRoi(new RectangleF(cx - nw * 0.5f, cy - nh * 0.5f, nw, nh));
        }

        private static RectangleF ClampRoi(RectangleF r)
        {
            float w = Math.Max(0.01f, Math.Min(1.0f, r.Width));
            float h = Math.Max(0.01f, Math.Min(1.0f, r.Height));
            float x = Math.Max(0f, Math.Min(1.0f - w, r.X));
            float y = Math.Max(0f, Math.Min(1.0f - h, r.Y));
            return new RectangleF(x, y, w, h);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Graphics g = e.Graphics;
            g.Clear(BackColor);

            var res = GetActiveResultPyramid();
            if (_original == null && res == null)
            {
                DrawEmptyState(g);
                return;
            }

            if (_overrideMode != ImageOverrideMode.None)
            {
                PaintOverrideView(g, res);
                return;
            }

            switch (_viewMode)
            {
                case CompareViewMode.SideBySide:
                    PaintSideBySide(g, res);
                    break;
                case CompareViewMode.SplitSlider:
                    PaintSplitSlider(g, res);
                    break;
                case CompareViewMode.RoiZoom:
                    PaintRoiZoom(g, res);
                    break;
            }
        }

        private void DrawEmptyState(Graphics g)
        {
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            {
                g.DrawString(
                    "请导入或拖入图片进行预览与超分对比\r\n支持：左右并排 | 滑块分割 | 局部放大 (ROI)",
                    _emptyFont,
                    Brushes.Silver,
                    ClientRectangle,
                    sf);
            }
        }

        private void PaintOverrideView(Graphics g, ImagePyramid res)
        {
            var pane = SplitPane;
            var imgRect = ComputeImageRect(pane, _leftViewport);
            bool showOrig = _overrideMode == ImageOverrideMode.OriginalOnly || res == null;
            var target = showOrig ? (_original ?? res) : (res ?? _original);
            string tag = showOrig
                ? FormatHud("原图 [单独预览]", target, _leftViewport.Zoom, false)
                : FormatHud(GetResultDisplayTitle() + " [单独预览]", target, _leftViewport.Zoom, true);

            DrawPyramidInPane(g, pane, target, imgRect);
            DrawHudBadge(g, new Point(pane.Left + 10, pane.Top + 10), tag);
        }

        private void PaintSideBySide(Graphics g, ImagePyramid res)
        {
            var leftPane = SideBySideLeftPane;
            var rightPane = SideBySideRightPane;

            var leftRect = ComputeImageRect(leftPane, _leftViewport);
            var rightVp = RightViewport;
            var rightRect = ComputeImageRect(rightPane, rightVp);

            DrawPyramidInPane(g, leftPane, _original, leftRect);
            if (res != null)
            {
                DrawPyramidInPane(g, rightPane, res, rightRect);
            }
            else
            {
                var prevClip = g.Clip;
                g.SetClip(rightPane);
                using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString("暂无处理结果\r\n处理完成后将在此显示超分对比", _hudFont, Brushes.Gray, rightPane, sf);
                g.Clip = prevClip;
            }

            using (var sepBrush = new SolidBrush(Color.FromArgb(65, 65, 72)))
                g.FillRectangle(sepBrush, leftPane.Right, 0, rightPane.Left - leftPane.Right, ClientSize.Height);

            DrawHudBadge(g, new Point(leftPane.Left + 8, leftPane.Top + 8),
                FormatHud("原图", _original, _leftViewport.Zoom, false));
            if (res != null)
            {
                DrawHudBadge(g, new Point(rightPane.Left + 8, rightPane.Top + 8),
                    FormatHud(GetResultDisplayTitle(), res, rightVp.Zoom, true));
            }
        }

        private void PaintSplitSlider(Graphics g, ImagePyramid res)
        {
            var pane = SplitPane;
            var imgRect = ComputeImageRect(pane, _leftViewport);
            int splitX = (int)Math.Round(pane.Left + pane.Width * _splitRatio);
            splitX = Math.Max(pane.Left + 2, Math.Min(pane.Right - 2, splitX));

            var leftClip = new Rectangle(pane.Left, pane.Top, Math.Max(0, splitX - pane.Left), pane.Height);
            var rightClip = new Rectangle(splitX, pane.Top, Math.Max(0, pane.Right - splitX), pane.Height);

            DrawPyramidInPane(g, leftClip, _original ?? res, imgRect);
            if (res != null)
                DrawPyramidInPane(g, rightClip, res, imgRect);
            else
                DrawPyramidInPane(g, rightClip, _original, imgRect);

            g.DrawLine(_dividerPen, splitX, pane.Top, splitX, pane.Bottom);
            int midY = pane.Top + pane.Height / 2;
            var handleRect = new Rectangle(splitX - 13, midY - 13, 26, 26);
            using (var fill = new SolidBrush(Color.FromArgb(225, 36, 128, 235)))
            using (var border = new Pen(Color.White, 2f))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.FillEllipse(fill, handleRect);
                g.DrawEllipse(border, handleRect);
                g.DrawLine(Pens.White, splitX - 7, midY, splitX - 2, midY - 4);
                g.DrawLine(Pens.White, splitX - 7, midY, splitX - 2, midY + 4);
                g.DrawLine(Pens.White, splitX + 7, midY, splitX + 2, midY - 4);
                g.DrawLine(Pens.White, splitX + 7, midY, splitX + 2, midY + 4);
                g.SmoothingMode = SmoothingMode.Default;
            }

            DrawHudBadge(g, new Point(pane.Left + 10, pane.Top + 10),
                "◀ " + FormatHud("原图", _original, _leftViewport.Zoom, false));
            var rightBadgeText = (res != null ? FormatHud(GetResultDisplayTitle(), res, _leftViewport.Zoom, true) : "无结果") + " ▶";
            var sz = TextRenderer.MeasureText(rightBadgeText, _hudFont);
            DrawHudBadge(g, new Point(Math.Max(pane.Left + 10, pane.Right - sz.Width - 22), pane.Top + 10), rightBadgeText);
        }

        private void PaintRoiZoom(Graphics g, ImagePyramid res)
        {
            var ovPane = RoiOverviewPane;
            var origPane = RoiOriginalPane;
            var resPane = RoiResultPane;

            var ovBase = _original ?? res;
            var ovImgRect = ComputeOverviewImageRect(ovPane);
            DrawPyramidInPane(g, ovPane, ovBase, ovImgRect);

            if (!ovImgRect.IsEmpty)
            {
                var roiScreen = new RectangleF(
                    ovImgRect.Left + _roiNormalized.X * ovImgRect.Width,
                    ovImgRect.Top + _roiNormalized.Y * ovImgRect.Height,
                    _roiNormalized.Width * ovImgRect.Width,
                    _roiNormalized.Height * ovImgRect.Height);

                using (var dimBrush = new SolidBrush(Color.FromArgb(95, 0, 0, 0)))
                {
                    var prev = g.Clip;
                    using (var rgn = new Region(ovImgRect))
                    {
                        rgn.Exclude(roiScreen);
                        g.Clip = rgn;
                        g.FillRectangle(dimBrush, ovImgRect);
                    }
                    g.Clip = prev;
                }

                g.DrawRectangle(_roiShadowPen, roiScreen.X, roiScreen.Y, roiScreen.Width, roiScreen.Height);
                g.DrawRectangle(_roiPen, roiScreen.X, roiScreen.Y, roiScreen.Width, roiScreen.Height);

                foreach (var hr in GetRoiHandleRects(roiScreen))
                {
                    g.FillRectangle(Brushes.White, hr);
                    g.DrawRectangle(Pens.Black, hr.X, hr.Y, hr.Width, hr.Height);
                }
            }

            var effRoi = GetEffectiveDetailRoi();
            DrawRoiDetailPane(g, origPane, _original, effRoi, "原图局部");
            DrawRoiDetailPane(g, resPane, res, effRoi, res != null ? GetResultDisplayTitle() + " 局部" : "暂无结果");

            using (var sepBrush = new SolidBrush(Color.FromArgb(65, 65, 72)))
            {
                g.FillRectangle(sepBrush, ovPane.Right, 0, origPane.Left - ovPane.Right, ClientSize.Height);
                g.FillRectangle(sepBrush, origPane.Right, 0, resPane.Left - origPane.Right, ClientSize.Height);
            }

            DrawHudBadge(g, new Point(ovPane.Left + 8, ovPane.Top + 6), "总览 (拖动或框选局部区域)");
        }

        private void DrawRoiDetailPane(Graphics g, Rectangle pane, ImagePyramid img, RectangleF effRoi, string title)
        {
            if (img == null)
            {
                var prevClip = g.Clip;
                g.SetClip(pane);
                using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString("暂无图像", _hudFont, Brushes.Gray, pane, sf);
                g.Clip = prevClip;
                DrawHudBadge(g, new Point(pane.Left + 8, pane.Top + 6), title);
                return;
            }

            int srcX = Math.Max(0, (int)Math.Floor(effRoi.X * img.OriginalWidth));
            int srcY = Math.Max(0, (int)Math.Floor(effRoi.Y * img.OriginalHeight));
            int srcW = Math.Max(1, (int)Math.Ceiling(effRoi.Width * img.OriginalWidth));
            int srcH = Math.Max(1, (int)Math.Ceiling(effRoi.Height * img.OriginalHeight));
            if (srcX + srcW > img.OriginalWidth) srcW = Math.Max(1, img.OriginalWidth - srcX);
            if (srcY + srcH > img.OriginalHeight) srcH = Math.Max(1, img.OriginalHeight - srcY);

            int pad = 10;
            float availW = Math.Max(16, pane.Width - pad * 2);
            float availH = Math.Max(16, pane.Height - pad * 2 - 28);
            float refCropW = Math.Max(1f, effRoi.Width * ReferenceWidth);
            float refCropH = Math.Max(1f, effRoi.Height * ReferenceHeight);
            float fitScale = Math.Min(availW / refCropW, availH / refCropH);
            float drawW = refCropW * fitScale;
            float drawH = refCropH * fitScale;
            float dx = pane.Left + (pane.Width - drawW) * 0.5f;
            float dy = pane.Top + 28 + (pane.Height - 28 - drawH) * 0.5f;
            var destRect = new RectangleF(dx, dy, drawW, drawH);

            var prev = g.Clip;
            g.SetClip(pane);
            if (_checkerBrush != null)
                g.FillRectangle(_checkerBrush, destRect);

            var bmp = img.SelectLevel(img.OriginalWidth * (drawW / Math.Max(1f, srcW)));
            float scaleX = bmp.Width / (float)img.OriginalWidth;
            float scaleY = bmp.Height / (float)img.OriginalHeight;
            var mipSrc = new RectangleF(srcX * scaleX, srcY * scaleY, Math.Max(1f, srcW * scaleX), Math.Max(1f, srcH * scaleY));

            g.InterpolationMode = (_pixelPerfectZoom && drawW > srcW)
                ? InterpolationMode.NearestNeighbor
                : InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(bmp, destRect, mipSrc, GraphicsUnit.Pixel);
            g.DrawRectangle(Pens.DimGray, destRect.X, destRect.Y, destRect.Width, destRect.Height);
            g.Clip = prev;

            string hud = string.Format("{0} | [{1},{2} {3}x{4}] | {5:F0}%",
                title, srcX, srcY, srcW, srcH, (drawW / Math.Max(1f, srcW)) * 100f);
            DrawHudBadge(g, new Point(pane.Left + 8, pane.Top + 6), hud);
        }

        private void DrawPyramidInPane(Graphics g, Rectangle clipRect, ImagePyramid img, RectangleF destRect)
        {
            if (img == null || clipRect.Width <= 0 || clipRect.Height <= 0 || destRect.Width <= 0f || destRect.Height <= 0f)
                return;

            var prevClip = g.Clip;
            g.SetClip(clipRect);

            var visibleDest = RectangleF.Intersect(destRect, clipRect);
            if (!visibleDest.IsEmpty)
            {
                if (_checkerBrush != null)
                    g.FillRectangle(_checkerBrush, visibleDest);

                var bmp = img.SelectLevel(destRect.Width);
                g.InterpolationMode = (_pixelPerfectZoom && destRect.Width >= bmp.Width)
                    ? InterpolationMode.NearestNeighbor
                    : InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(bmp, destRect, new RectangleF(0, 0, bmp.Width, bmp.Height), GraphicsUnit.Pixel);
                g.DrawRectangle(Pens.DimGray, destRect.X, destRect.Y, destRect.Width, destRect.Height);
            }

            g.Clip = prevClip;
        }

        private void DrawHudBadge(Graphics g, Point location, string text)
        {
            if (string.IsNullOrEmpty(text))
                return;
            var size = TextRenderer.MeasureText(text, _hudFont);
            var box = new Rectangle(location.X, location.Y, size.Width + 10, size.Height + 6);
            g.FillRectangle(_hudBgBrush, box);
            g.DrawRectangle(Pens.DimGray, box);
            TextRenderer.DrawText(g, text, _hudFont, new Point(location.X + 5, location.Y + 3), Color.WhiteSmoke);
        }

        private string GetResultDisplayTitle()
        {
            var item = ActiveResultItem;
            if (item == null)
                return "结果";
            if (!string.IsNullOrWhiteSpace(item.Label))
                return item.Label;
            if (!string.IsNullOrWhiteSpace(item.Engine))
                return item.Engine;
            return "结果";
        }

        private string FormatHud(string prefix, ImagePyramid img, double zoom, bool isResult)
        {
            if (img == null)
                return prefix + " | 无";
            string sizeStr = FormatBytes(img.FileSizeBytes);
            double effectiveScale = zoom;
            if (!isResult && ReferenceWidth > 0 && img.OriginalWidth > 0)
            {
                effectiveScale = (ReferenceWidth * zoom) / img.OriginalWidth;
            }
            string ratioNote = "";
            if (isResult && _original != null && _original.OriginalWidth > 0)
            {
                double ups = (double)img.OriginalWidth / _original.OriginalWidth;
                ratioNote = string.Format(" ({0:0.##}x)", ups);
            }
            return string.Format("{0} | {1}x{2}{3} | {4} | {5:F0}%",
                prefix, img.OriginalWidth, img.OriginalHeight, ratioNote, sizeStr, effectiveScale * 100.0);
        }

        public static string FormatBytes(long bytes)
        {
            if (bytes < 1024) return bytes + " B";
            if (bytes < 1024 * 1024) return string.Format("{0:F1} KB", bytes / 1024.0);
            return string.Format("{0:F2} MB", bytes / (1024.0 * 1024.0));
        }

        private static RectangleF[] GetRoiHandleRects(RectangleF roiScreen)
        {
            float hs = 4f;
            float mx = roiScreen.Left + roiScreen.Width * 0.5f;
            float my = roiScreen.Top + roiScreen.Height * 0.5f;
            return new[]
            {
                new RectangleF(roiScreen.Left - hs, roiScreen.Top - hs, hs * 2, hs * 2),
                new RectangleF(mx - hs, roiScreen.Top - hs, hs * 2, hs * 2),
                new RectangleF(roiScreen.Right - hs, roiScreen.Top - hs, hs * 2, hs * 2),
                new RectangleF(roiScreen.Right - hs, my - hs, hs * 2, hs * 2),
                new RectangleF(roiScreen.Right - hs, roiScreen.Bottom - hs, hs * 2, hs * 2),
                new RectangleF(mx - hs, roiScreen.Bottom - hs, hs * 2, hs * 2),
                new RectangleF(roiScreen.Left - hs, roiScreen.Bottom - hs, hs * 2, hs * 2),
                new RectangleF(roiScreen.Left - hs, my - hs, hs * 2, hs * 2)
            };
        }

        private static RoiHandle HitTestRoiHandle(RectangleF roiScreen, Point pt)
        {
            var rects = GetRoiHandleRects(roiScreen);
            RoiHandle[] handles =
            {
                RoiHandle.TopLeft, RoiHandle.Top, RoiHandle.TopRight, RoiHandle.Right,
                RoiHandle.BottomRight, RoiHandle.Bottom, RoiHandle.BottomLeft, RoiHandle.Left
            };
            for (int i = 0; i < rects.Length; i++)
            {
                var inflated = RectangleF.Inflate(rects[i], 3f, 3f);
                if (inflated.Contains(pt))
                    return handles[i];
            }
            return RoiHandle.None;
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            Focus();
            if (e.Button != MouseButtons.Left || (_original == null && GetActiveResultPyramid() == null))
                return;

            _dragStartPoint = e.Location;
            if (_overrideMode != ImageOverrideMode.None || _viewMode == CompareViewMode.SideBySide)
            {
                if (_overrideMode == ImageOverrideMode.None && !_syncViewports && SideBySideRightPane.Contains(e.Location))
                {
                    _dragMode = DragMode.PanRight;
                    _dragStartCenterU = _rightViewport.CenterU;
                    _dragStartCenterV = _rightViewport.CenterV;
                }
                else
                {
                    _dragMode = DragMode.PanLeft;
                    _dragStartCenterU = _leftViewport.CenterU;
                    _dragStartCenterV = _leftViewport.CenterV;
                }
                return;
            }

            if (_viewMode == CompareViewMode.SplitSlider)
            {
                int splitX = (int)Math.Round(SplitPane.Left + SplitPane.Width * _splitRatio);
                if (Math.Abs(e.X - splitX) <= 12)
                {
                    _dragMode = DragMode.SplitDivider;
                }
                else
                {
                    _dragMode = DragMode.PanLeft;
                    _dragStartCenterU = _leftViewport.CenterU;
                    _dragStartCenterV = _leftViewport.CenterV;
                }
                return;
            }

            if (_viewMode == CompareViewMode.RoiZoom)
            {
                var ovPane = RoiOverviewPane;
                if (ovPane.Contains(e.Location))
                {
                    var ovImgRect = ComputeOverviewImageRect(ovPane);
                    if (ovImgRect.Width > 0 && ovImgRect.Height > 0)
                    {
                        var roiScreen = new RectangleF(
                            ovImgRect.Left + _roiNormalized.X * ovImgRect.Width,
                            ovImgRect.Top + _roiNormalized.Y * ovImgRect.Height,
                            _roiNormalized.Width * ovImgRect.Width,
                            _roiNormalized.Height * ovImgRect.Height);

                        _dragStartRoi = _roiNormalized;
                        var handle = HitTestRoiHandle(roiScreen, e.Location);
                        if (handle != RoiHandle.None)
                        {
                            _dragMode = DragMode.RoiResize;
                            _activeRoiHandle = handle;
                        }
                        else if (roiScreen.Contains(e.Location))
                        {
                            _dragMode = DragMode.RoiMove;
                        }
                        else if (ovImgRect.Contains(e.Location))
                        {
                            _dragMode = DragMode.RoiCreate;
                            _dragCreateAnchorNorm = new PointF(
                                Math.Max(0f, Math.Min(1f, (e.X - ovImgRect.Left) / ovImgRect.Width)),
                                Math.Max(0f, Math.Min(1f, (e.Y - ovImgRect.Top) / ovImgRect.Height)));
                        }
                    }
                }
                else
                {
                    _dragMode = DragMode.RoiDetailPan;
                    _dragStartRoi = _roiNormalized;
                }
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (_dragMode == DragMode.None)
            {
                UpdateCursorForPoint(e.Location);
                return;
            }

            int dx = e.X - _dragStartPoint.X;
            int dy = e.Y - _dragStartPoint.Y;

            if (_dragMode == DragMode.PanLeft || _dragMode == DragMode.PanRight)
            {
                var vp = _dragMode == DragMode.PanRight ? _rightViewport : _leftViewport;
                float drawW = (float)(ReferenceWidth * vp.Zoom);
                float drawH = (float)(ReferenceHeight * vp.Zoom);
                if (drawW > 0f && drawH > 0f)
                {
                    vp.CenterU = _dragStartCenterU - dx / drawW;
                    vp.CenterV = _dragStartCenterV - dy / drawH;
                    Invalidate();
                    OnViewStateChanged();
                }
                return;
            }

            if (_dragMode == DragMode.SplitDivider)
            {
                var pane = SplitPane;
                if (pane.Width > 0)
                    SplitRatio = (double)(e.X - pane.Left) / pane.Width;
                return;
            }

            if (_dragMode == DragMode.RoiMove)
            {
                var ovImgRect = ComputeOverviewImageRect(RoiOverviewPane);
                if (ovImgRect.Width > 0 && ovImgRect.Height > 0)
                {
                    float du = dx / ovImgRect.Width;
                    float dv = dy / ovImgRect.Height;
                    RoiNormalized = new RectangleF(_dragStartRoi.X + du, _dragStartRoi.Y + dv, _dragStartRoi.Width, _dragStartRoi.Height);
                }
                return;
            }

            if (_dragMode == DragMode.RoiCreate)
            {
                var ovImgRect = ComputeOverviewImageRect(RoiOverviewPane);
                if (ovImgRect.Width > 0 && ovImgRect.Height > 0)
                {
                    float cu = Math.Max(0f, Math.Min(1f, (e.X - ovImgRect.Left) / ovImgRect.Width));
                    float cv = Math.Max(0f, Math.Min(1f, (e.Y - ovImgRect.Top) / ovImgRect.Height));
                    float x = Math.Min(_dragCreateAnchorNorm.X, cu);
                    float y = Math.Min(_dragCreateAnchorNorm.Y, cv);
                    float w = Math.Max(0.02f, Math.Abs(cu - _dragCreateAnchorNorm.X));
                    float h = Math.Max(0.02f, Math.Abs(cv - _dragCreateAnchorNorm.Y));
                    RoiNormalized = new RectangleF(x, y, w, h);
                }
                return;
            }

            if (_dragMode == DragMode.RoiResize)
            {
                var ovImgRect = ComputeOverviewImageRect(RoiOverviewPane);
                if (ovImgRect.Width > 0 && ovImgRect.Height > 0)
                {
                    float du = dx / ovImgRect.Width;
                    float dv = dy / ovImgRect.Height;
                    float l = _dragStartRoi.Left;
                    float t = _dragStartRoi.Top;
                    float r = _dragStartRoi.Right;
                    float b = _dragStartRoi.Bottom;
                    const float minSpan = 0.02f;

                    if (_activeRoiHandle == RoiHandle.TopLeft || _activeRoiHandle == RoiHandle.Left || _activeRoiHandle == RoiHandle.BottomLeft)
                        l = Math.Max(0f, Math.Min(r - minSpan, l + du));
                    if (_activeRoiHandle == RoiHandle.TopRight || _activeRoiHandle == RoiHandle.Right || _activeRoiHandle == RoiHandle.BottomRight)
                        r = Math.Min(1f, Math.Max(l + minSpan, r + du));
                    if (_activeRoiHandle == RoiHandle.TopLeft || _activeRoiHandle == RoiHandle.Top || _activeRoiHandle == RoiHandle.TopRight)
                        t = Math.Max(0f, Math.Min(b - minSpan, t + dv));
                    if (_activeRoiHandle == RoiHandle.BottomLeft || _activeRoiHandle == RoiHandle.Bottom || _activeRoiHandle == RoiHandle.BottomRight)
                        b = Math.Min(1f, Math.Max(t + minSpan, b + dv));

                    RoiNormalized = new RectangleF(l, t, r - l, b - t);
                }
                return;
            }

            if (_dragMode == DragMode.RoiDetailPan)
            {
                var pane = RoiOriginalPane.Contains(_dragStartPoint) ? RoiOriginalPane : RoiResultPane;
                if (pane.Width > 0 && pane.Height > 0)
                {
                    float du = -(dx / (float)pane.Width) * _dragStartRoi.Width;
                    float dv = -(dy / (float)pane.Height) * _dragStartRoi.Height;
                    RoiNormalized = new RectangleF(_dragStartRoi.X + du, _dragStartRoi.Y + dv, _dragStartRoi.Width, _dragStartRoi.Height);
                }
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            _dragMode = DragMode.None;
            _activeRoiHandle = RoiHandle.None;
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            if (_original == null && GetActiveResultPyramid() == null)
                return;

            double factor = e.Delta > 0 ? 1.15 : (1.0 / 1.15);

            if (_viewMode == CompareViewMode.RoiZoom && _overrideMode == ImageOverrideMode.None)
            {
                if (!RoiOverviewPane.Contains(e.Location))
                {
                    float scale = e.Delta > 0 ? (1f / 1.15f) : 1.15f;
                    float cx = _roiNormalized.X + _roiNormalized.Width * 0.5f;
                    float cy = _roiNormalized.Y + _roiNormalized.Height * 0.5f;
                    float nw = Math.Max(0.02f, Math.Min(1.0f, _roiNormalized.Width * scale));
                    float nh = Math.Max(0.02f, Math.Min(1.0f, _roiNormalized.Height * scale));
                    RoiNormalized = new RectangleF(cx - nw * 0.5f, cy - nh * 0.5f, nw, nh);
                }
                return;
            }

            Rectangle pane;
            ViewportState vp;
            if (_viewMode == CompareViewMode.SideBySide && _overrideMode == ImageOverrideMode.None)
            {
                if (SideBySideRightPane.Contains(e.Location))
                {
                    pane = SideBySideRightPane;
                    vp = _syncViewports ? _leftViewport : _rightViewport;
                }
                else
                {
                    pane = SideBySideLeftPane;
                    vp = _leftViewport;
                }
            }
            else
            {
                pane = SplitPane;
                vp = _leftViewport;
            }

            var norm = ScreenToNormalized(e.Location, pane, vp);
            vp.Zoom = vp.Zoom * factor;
            float newDrawW = (float)(ReferenceWidth * vp.Zoom);
            float newDrawH = (float)(ReferenceHeight * vp.Zoom);
            if (newDrawW > 0f && newDrawH > 0f)
            {
                float cx = pane.Left + pane.Width * 0.5f;
                float cy = pane.Top + pane.Height * 0.5f;
                vp.CenterU = norm.X - (e.Location.X - cx) / newDrawW;
                vp.CenterV = norm.Y - (e.Location.Y - cy) / newDrawH;
            }

            Invalidate();
            OnViewStateChanged();
        }

        private void UpdateCursorForPoint(Point pt)
        {
            if (_overrideMode == ImageOverrideMode.None && _viewMode == CompareViewMode.SplitSlider)
            {
                int splitX = (int)Math.Round(SplitPane.Left + SplitPane.Width * _splitRatio);
                Cursor = Math.Abs(pt.X - splitX) <= 12 ? Cursors.VSplit : Cursors.SizeAll;
                return;
            }
            if (_overrideMode == ImageOverrideMode.None && _viewMode == CompareViewMode.RoiZoom && RoiOverviewPane.Contains(pt))
            {
                var ovImg = ComputeOverviewImageRect(RoiOverviewPane);
                var roiScreen = new RectangleF(
                    ovImg.Left + _roiNormalized.X * ovImg.Width,
                    ovImg.Top + _roiNormalized.Y * ovImg.Height,
                    _roiNormalized.Width * ovImg.Width,
                    _roiNormalized.Height * ovImg.Height);
                if (HitTestRoiHandle(roiScreen, pt) != RoiHandle.None)
                {
                    Cursor = Cursors.SizeNWSE;
                    return;
                }
                Cursor = roiScreen.Contains(pt) ? Cursors.SizeAll : Cursors.Cross;
                return;
            }
            Cursor = Cursors.SizeAll;
        }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Tab || keyData == Keys.Space)
                return true;
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Tab)
            {
                if (_overrideMode == ImageOverrideMode.None) OverrideMode = ImageOverrideMode.OriginalOnly;
                else if (_overrideMode == ImageOverrideMode.OriginalOnly) OverrideMode = ImageOverrideMode.ResultOnly;
                else OverrideMode = ImageOverrideMode.None;
                e.Handled = true;
            }
            else if (e.KeyCode == Keys.D1) { ViewMode = CompareViewMode.SideBySide; e.Handled = true; }
            else if (e.KeyCode == Keys.D2) { ViewMode = CompareViewMode.SplitSlider; e.Handled = true; }
            else if (e.KeyCode == Keys.D3) { ViewMode = CompareViewMode.RoiZoom; e.Handled = true; }
            else if (e.KeyCode == Keys.D0) { FitToWindow(); e.Handled = true; }
            else if (e.KeyCode == Keys.Oemplus || e.KeyCode == Keys.Add) { SetZoomPercent(_leftViewport.Zoom * 125.0); e.Handled = true; }
            else if (e.KeyCode == Keys.OemMinus || e.KeyCode == Keys.Subtract) { SetZoomPercent(_leftViewport.Zoom * 80.0); e.Handled = true; }
        }

        private void DisposeResultCache()
        {
            foreach (var kv in _resultCache)
            {
                kv.Value?.Dispose();
            }
            _resultCache.Clear();
        }

        private void OnViewStateChanged()
        {
            ViewStateChanged?.Invoke(this, EventArgs.Empty);
        }

        private void OnSelectedResultChanged()
        {
            SelectedResultChanged?.Invoke(this, EventArgs.Empty);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _original?.Dispose();
                _original = null;
                DisposeResultCache();
                _checkerBrush?.Dispose();
                _checkerBrush = null;
                _checkerTile?.Dispose();
                _checkerTile = null;
                _hudFont?.Dispose();
                _hudFont = null;
                _emptyFont?.Dispose();
                _emptyFont = null;
                _hudBgBrush?.Dispose();
                _hudBgBrush = null;
                _hudTextBrush?.Dispose();
                _hudTextBrush = null;
                _dividerPen?.Dispose();
                _dividerPen = null;
                _roiPen?.Dispose();
                _roiPen = null;
                _roiShadowPen?.Dispose();
                _roiShadowPen = null;
            }
            base.Dispose(disposing);
        }
    }
}
