using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Windows.Forms;

namespace ScaleGuardSetup
{
    // Палитра и общие приёмы отрисовки. Тёмное стекло, фиолетово-оранжевый
    // градиент, крупный дракон — всё рисуется вручную, без системных контролов,
    // чтобы окно выглядело цельным.
    static class C
    {
        public static readonly Color Bg = Color.FromArgb(11, 7, 20);
        public static readonly Color BgDeep = Color.FromArgb(8, 5, 15);
        public static readonly Color Card = Color.FromArgb(20, 14, 38);
        public static readonly Color CardHover = Color.FromArgb(28, 20, 50);
        public static readonly Color Border = Color.FromArgb(46, 34, 78);
        public static readonly Color BorderSoft = Color.FromArgb(36, 26, 64);
        public static readonly Color Text = Color.FromArgb(244, 240, 252);
        public static readonly Color TextDim = Color.FromArgb(185, 175, 212);
        public static readonly Color TextMuted = Color.FromArgb(138, 128, 166);
        public static readonly Color Purple = Color.FromArgb(122, 75, 232);
        public static readonly Color PurpleSoft = Color.FromArgb(108, 59, 232);
        public static readonly Color Orange = Color.FromArgb(255, 138, 60);
        public static readonly Color Link = Color.FromArgb(183, 156, 255);
        public static readonly Color Danger = Color.FromArgb(255, 96, 96);
        public static readonly Color Ok = Color.FromArgb(88, 214, 141);
    }

    static class F
    {
        static Font Make(string family, float size, FontStyle style)
        {
            try { return new Font(family, size, style, GraphicsUnit.Point); }
            catch { return new Font("Segoe UI", size, style, GraphicsUnit.Point); }
        }

        public static readonly Font Hero = Make("Segoe UI Semibold", 20f, FontStyle.Regular);
        public static readonly Font Title = Make("Segoe UI Semibold", 23f, FontStyle.Regular);
        public static readonly Font TitleBig = Make("Segoe UI Semibold", 27f, FontStyle.Regular);
        public static readonly Font Sub = Make("Segoe UI", 10.5f, FontStyle.Regular);
        public static readonly Font Body = Make("Segoe UI", 10f, FontStyle.Regular);
        public static readonly Font Small = Make("Segoe UI", 9f, FontStyle.Regular);
        public static readonly Font Tiny = Make("Segoe UI", 8f, FontStyle.Regular);
        public static readonly Font Ui = Make("Segoe UI Semibold", 10f, FontStyle.Regular);
        public static readonly Font UiSmall = Make("Segoe UI", 9f, FontStyle.Regular);
        public static readonly Font Button = Make("Segoe UI Semibold", 10.5f, FontStyle.Regular);
        public static readonly Font ButtonSmall = Make("Segoe UI Semibold", 9.5f, FontStyle.Regular);
        public static readonly Font Path = Make("Segoe UI", 9.25f, FontStyle.Regular);
        public static readonly Font Splash = Make("Segoe UI Semibold", 23f, FontStyle.Regular);
        public static readonly Font DialogTitle = Make("Segoe UI Semibold", 15f, FontStyle.Regular);
    }

    static class Draw
    {
        public static GraphicsPath Round(Rectangle r, int radius)
        {
            var p = new GraphicsPath();
            int d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            if (d <= 1) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        public static void FillRound(Graphics g, Rectangle r, int radius, Color color)
        {
            using (var p = Round(r, radius))
            using (var b = new SolidBrush(color))
                g.FillPath(b, p);
        }

        public static void StrokeRound(Graphics g, Rectangle r, int radius, Color color, float width)
        {
            using (var p = Round(r, radius))
            using (var pen = new Pen(color, width))
                g.DrawPath(pen, p);
        }

        public static void Text(Graphics g, string text, Font font, Color color, Rectangle rect,
            StringAlignment align, StringAlignment line, bool wrap, bool ellipsis)
        {
            using (var sf = new StringFormat())
            {
                sf.Alignment = align;
                sf.LineAlignment = line;
                sf.Trimming = ellipsis ? StringTrimming.EllipsisCharacter : StringTrimming.None;
                if (!wrap) sf.FormatFlags |= StringFormatFlags.NoWrap;
                using (var b = new SolidBrush(color))
                    g.DrawString(text, font, b, new RectangleF(rect.X, rect.Y, rect.Width, rect.Height), sf);
            }
        }

        public static void TextLeft(Graphics g, string text, Font font, Color color, Rectangle r, bool wrap)
        {
            Text(g, text, font, color, r, StringAlignment.Near, StringAlignment.Near, wrap, true);
        }

        public static void TextCenter(Graphics g, string text, Font font, Color color, Rectangle r)
        {
            Text(g, text, font, color, r, StringAlignment.Center, StringAlignment.Center, false, true);
        }

        public static void TextRight(Graphics g, string text, Font font, Color color, Rectangle r)
        {
            Text(g, text, font, color, r, StringAlignment.Far, StringAlignment.Center, false, true);
        }

        public static void Button(Graphics g, Rectangle r, string caption, bool primary,
            bool hover, bool pressed, bool enabled, Font font)
        {
            int radius = Math.Max(7, r.Height / 5);
            if (primary && enabled)
            {
                using (var p = Round(r, radius))
                {
                    using (var br = new LinearGradientBrush(r, C.Purple, C.Orange, 0f))
                        g.FillPath(br, p);
                    if (hover) using (var b = new SolidBrush(Color.FromArgb(26, 255, 255, 255))) g.FillPath(b, p);
                    if (pressed) using (var b = new SolidBrush(Color.FromArgb(46, 0, 0, 0))) g.FillPath(b, p);
                    using (var pen = new Pen(Color.FromArgb(90, 255, 210, 180), 1f)) g.DrawPath(pen, p);
                }
                TextCenter(g, caption, font, Color.White, r);
            }
            else
            {
                using (var p = Round(r, radius))
                {
                    Color fill = !enabled ? Color.FromArgb(21, 16, 34)
                        : (hover ? C.CardHover : C.Card);
                    using (var b = new SolidBrush(fill)) g.FillPath(b, p);
                    using (var pen = new Pen(enabled ? C.Border : Color.FromArgb(28, 21, 48), 1f)) g.DrawPath(pen, p);
                }
                Color col = enabled ? C.TextDim : Color.FromArgb(92, 84, 112);
                TextCenter(g, caption, font, col, r);
            }
        }

        public static void Check(Graphics g, Rectangle box, bool on, bool hover, string label, Rectangle labelRect)
        {
            int radius = Math.Max(4, box.Height / 4);
            if (on)
            {
                using (var p = Round(box, radius))
                {
                    using (var br = new LinearGradientBrush(box, C.Purple, Color.FromArgb(168, 92, 205), 35f))
                        g.FillPath(br, p);
                    using (var pen = new Pen(Color.FromArgb(80, 255, 255, 255), 1f)) g.DrawPath(pen, p);
                }
                int cx = box.X + box.Width / 2;
                int cy = box.Y + box.Height / 2;
                int u = Math.Max(2, box.Width / 8);
                using (var pen = new Pen(Color.White, Math.Max(1.8f, box.Width / 10f)))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    pen.LineJoin = LineJoin.Round;
                    g.DrawLines(pen, new Point[] {
                        new Point(cx - u * 2, cy),
                        new Point(cx - u / 2, cy + u * 2),
                        new Point(cx + u * 2, cy - u * 2)
                    });
                }
            }
            else
            {
                using (var p = Round(box, radius))
                {
                    using (var b = new SolidBrush(hover ? C.CardHover : C.Card)) g.FillPath(b, p);
                    using (var pen = new Pen(C.Border, 1f)) g.DrawPath(pen, p);
                }
            }
            Text(g, label, F.Body, on ? C.Text : C.TextDim, labelRect,
                StringAlignment.Near, StringAlignment.Center, false, true);
        }

        public static void Progress(Graphics g, Rectangle r, float value)
        {
            int radius = r.Height / 2;
            using (var p = Round(r, radius))
            {
                using (var b = new SolidBrush(Color.FromArgb(27, 18, 48))) g.FillPath(b, p);
                using (var pen = new Pen(Color.FromArgb(44, 32, 72), 1f)) g.DrawPath(pen, p);
            }
            if (value <= 0f) return;
            if (value > 1f) value = 1f;
            int w = (int)Math.Round(r.Width * value);
            if (w < r.Height) w = r.Height;
            var fill = new Rectangle(r.X, r.Y, w, r.Height);
            using (var p = Round(fill, radius))
            {
                using (var br = new LinearGradientBrush(r, C.Purple, C.Orange, 0f))
                    g.FillPath(br, p);
                using (var hl = new LinearGradientBrush(fill, Color.FromArgb(60, 255, 255, 255), Color.FromArgb(0, 255, 255, 255), 90f))
                    g.FillPath(hl, p);
            }
        }

        public static void Glow(Graphics g, Point center, int radius, Color color, int alpha)
        {
            int r = radius;
            using (var path = new GraphicsPath())
            {
                path.AddEllipse(center.X - r, center.Y - r, r * 2, r * 2);
                using (var pgb = new PathGradientBrush(path))
                {
                    pgb.CenterColor = Color.FromArgb(alpha, color);
                    pgb.SurroundColors = new Color[] { Color.FromArgb(0, color) };
                    pgb.CenterPoint = center;
                    pgb.FocusScales = new PointF(0.55f, 0.55f);
                    g.FillEllipse(pgb, center.X - r, center.Y - r, r * 2, r * 2);
                }
            }
        }

        // Тонированный силуэт логотипа: даёт светлый контур вокруг тёмного
        // дракона, чтобы он читался на почти чёрном фоне.
        static void Tint(Graphics g, Bitmap logo, Rectangle rect, Color color, float scale, int alpha)
        {
            int w = (int)Math.Round(rect.Width * scale);
            int h = (int)Math.Round(rect.Height * scale);
            var dest = new Rectangle(rect.X + (rect.Width - w) / 2, rect.Y + (rect.Height - h) / 2, w, h);
            var cm = new ColorMatrix(new float[][]
            {
                new float[] { 0, 0, 0, 0, color.R / 255f },
                new float[] { 0, 0, 0, 0, color.G / 255f },
                new float[] { 0, 0, 0, 0, color.B / 255f },
                new float[] { 0, 0, 0, alpha / 255f, 0 },
                new float[] { 0, 0, 0, 0, 1 }
            });
            using (var attrs = new ImageAttributes())
            {
                attrs.SetColorMatrix(cm);
                g.DrawImage(logo, dest, 0, 0, logo.Width, logo.Height, GraphicsUnit.Pixel, attrs);
            }
        }

        public static void Logo(Graphics g, Bitmap logo, Rectangle rect, bool glow)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            if (glow)
            {
                var center = new Point(rect.X + rect.Width / 2, rect.Y + rect.Height / 2);
                Glow(g, center, (int)(rect.Width * 0.86), C.PurpleSoft, 58);
                Glow(g, center, (int)(rect.Width * 0.58), C.Purple, 64);
                Tint(g, logo, rect, C.Link, 1.05f, 52);
                Tint(g, logo, rect, C.Link, 1.10f, 20);
            }
            g.DrawImage(logo, rect);
        }

        public static void BadgeCheck(Graphics g, Rectangle r)
        {
            using (var br = new LinearGradientBrush(r, C.Purple, C.Orange, 35f))
                g.FillEllipse(br, r);
            int cx = r.X + r.Width / 2;
            int cy = r.Y + r.Height / 2;
            int u = r.Width / 7;
            using (var pen = new Pen(Color.White, Math.Max(3f, r.Width / 14f)))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                pen.LineJoin = LineJoin.Round;
                g.DrawLines(pen, new Point[] {
                    new Point(cx - u * 2, cy),
                    new Point(cx - u / 2, cy + u * 2),
                    new Point(cx + u * 2, cy - u * 2)
                });
            }
        }

        public static void BadgeBang(Graphics g, Rectangle r)
        {
            using (var br = new LinearGradientBrush(r, Color.FromArgb(200, 62, 74), C.Orange, 35f))
                g.FillEllipse(br, r);
            int cx = r.X + r.Width / 2;
            int top = r.Y + r.Height / 4;
            int bottom = r.Y + r.Height / 2 + r.Height / 8;
            using (var pen = new Pen(Color.White, Math.Max(3f, r.Width / 14f)))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                g.DrawLine(pen, cx, top, cx, bottom);
            }
            using (var b = new SolidBrush(Color.White))
            {
                int d = Math.Max(3, r.Width / 12);
                g.FillEllipse(b, cx - d / 2, r.Y + r.Height * 3 / 4, d, d);
            }
        }

        public static void TitleIcon(Graphics g, Bitmap logo, Rectangle r)
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(logo, r);
        }

        public static string ShortPath(string path, Font font, int maxWidth, Graphics g)
        {
            if (string.IsNullOrEmpty(path)) return "";
            if (g.MeasureString(path, font).Width <= maxWidth) return path;
            string p = path;
            while (p.Length > 8)
            {
                p = p.Substring(0, p.Length - 2);
                string s = p + "…";
                if (g.MeasureString(s, font).Width <= maxWidth) return s;
            }
            return path;
        }
    }
}
