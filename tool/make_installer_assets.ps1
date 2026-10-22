# Готовит картинки для установщика: иконку приложения (много размеров),
# фиолетового дракона, hero-панель и фон окна установки.
#
# Запуск: powershell -ExecutionPolicy Bypass -File tool\make_installer_assets.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logo = Join-Path $root 'assets\scaleguard-logo.png'
$out  = Join-Path $root 'installer\assets'
New-Item -ItemType Directory -Force -Path $out | Out-Null

Add-Type -AssemblyName System.Drawing

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

public static class SgAssets
{
    public static Bitmap Crop(Bitmap src, int alphaMin, float margin)
    {
        var rect = new Rectangle(0, 0, src.Width, src.Height);
        var data = src.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int stride = data.Stride;
        byte[] buf = new byte[stride * src.Height];
        System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, buf.Length);
        src.UnlockBits(data);

        int minX = src.Width, minY = src.Height, maxX = -1, maxY = -1;
        for (int y = 0; y < src.Height; y++)
        {
            int row = y * stride;
            for (int x = 0; x < src.Width; x++)
            {
                if (buf[row + x * 4 + 3] >= alphaMin)
                {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }
        if (maxX < 0) { minX = 0; minY = 0; maxX = src.Width - 1; maxY = src.Height - 1; }

        int w = maxX - minX + 1, h = maxY - minY + 1;
        int side = (int)(Math.Max(w, h) * (1 + margin * 2));
        var dst = new Bitmap(side, side, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(dst))
        {
            g.Clear(Color.Transparent);
            g.CompositingQuality = CompositingQuality.HighQuality;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            int ox = (side - w) / 2, oy = (side - h) / 2;
            g.DrawImage(src, new Rectangle(ox, oy, w, h),
                new Rectangle(minX, minY, w, h), GraphicsUnit.Pixel);
        }
        return dst;
    }

    public static Bitmap Resize(Bitmap src, int size)
    {
        var dst = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(dst))
        {
            g.Clear(Color.Transparent);
            g.CompositingQuality = CompositingQuality.HighQuality;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.DrawImage(src, 0, 0, size, size);
        }
        return dst;
    }

    public static Bitmap Purple(Bitmap src)
    {
        var dst = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
        var rect = new Rectangle(0, 0, src.Width, src.Height);
        var data = src.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int stride = data.Stride;
        byte[] buf = new byte[stride * src.Height];
        System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, buf.Length);
        src.UnlockBits(data);

        for (int y = 0; y < src.Height; y++)
        {
            int row = y * stride;
            for (int x = 0; x < src.Width; x++)
            {
                int i = row + x * 4;
                byte a = buf[i + 3];
                if (a == 0) continue;
                int r = buf[i + 2], g = buf[i + 1], b = buf[i];
                bool eye = g > r + 22 && g > b + 22;
                double lum = 0.299 * r + 0.587 * g + 0.114 * b;
                double t = Math.Max(0, Math.Min(1, (lum - 16) / 66.0));
                if (eye)
                {
                    double e = Math.Max(0, Math.Min(1, (lum - 100) / 150.0));
                    buf[i + 2] = (byte)(170 + 85 * e);
                    buf[i + 1] = (byte)(24 + 82 * e);
                    buf[i]     = (byte)(20 + 46 * e);
                }
                else
                {
                    buf[i + 2] = (byte)(44 + 72 * t);
                    buf[i + 1] = (byte)(28 + 64 * t);
                    buf[i]     = (byte)(80 + 112 * t);
                }
            }
        }

        var outData = dst.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        System.Runtime.InteropServices.Marshal.Copy(buf, 0, outData.Scan0, buf.Length);
        dst.UnlockBits(outData);
        return dst;
    }

    // Плавные градиенты считаются по пикселям: GDI+ на радиальных кистях
    // даёт заметные кольца, а интерполяция с шумом их убирает.
    static byte Clamp(double v) { return (byte)Math.Max(0, Math.Min(255, v)); }

    public static Bitmap Hero(Bitmap dragon, int w, int h)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        var rect = new Rectangle(0, 0, w, h);
        var data = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        int stride = data.Stride;
        byte[] buf = new byte[stride * h];
        var rnd = new Random(7);

        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                double r = 11, g = 7, b = 20;

                double dx = (x - w * 0.45) / (w * 0.90);
                double dy = (y - h * 0.38) / (w * 0.90);
                double k = Math.Max(0, 1 - Math.Sqrt(dx * dx + dy * dy));
                k *= k * 0.50;
                r += 108 * k; g += 59 * k; b += 232 * k;

                dx = (x - w * 0.50) / (w * 1.05);
                dy = (y - h * 1.06) / (w * 1.05);
                k = Math.Max(0, 1 - Math.Sqrt(dx * dx + dy * dy));
                k *= k * 0.30;
                r += 255 * k; g += 122 * k; b += 47 * k;

                int n = rnd.Next(-2, 3);
                int i = y * stride + x * 4;
                buf[i]     = Clamp(b + n);
                buf[i + 1] = Clamp(g + n);
                buf[i + 2] = Clamp(r + n);
                buf[i + 3] = 255;
            }
        }
        System.Runtime.InteropServices.Marshal.Copy(buf, 0, data.Scan0, buf.Length);
        bmp.UnlockBits(data);

        using (var g = Graphics.FromImage(bmp))
        {
            g.CompositingQuality = CompositingQuality.HighQuality;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            int ds = (int)(w * 0.74);
            g.DrawImage(dragon, new RectangleF((w - ds) / 2f, h * 0.40f - ds / 2f, ds, ds));
        }
        return bmp;
    }

    public static Bitmap Back(int w, int h)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        var rect = new Rectangle(0, 0, w, h);
        var data = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        int stride = data.Stride;
        byte[] buf = new byte[stride * h];
        var rnd = new Random(11);

        for (int y = 0; y < h; y++)
        {
            double t = (double)y / h;
            for (int x = 0; x < w; x++)
            {
                double r = 9 + 9 * t, g = 5 + 5 * t, b = 18 + 14 * t;

                double dx = (x - w * 0.86) / (w * 0.80);
                double dy = (y - h * 0.08) / (w * 0.80);
                double k = Math.Max(0, 1 - Math.Sqrt(dx * dx + dy * dy));
                k *= k * 0.38;
                r += 108 * k; g += 59 * k; b += 232 * k;

                dx = (x - w * 1.02) / (w * 0.62);
                dy = (y - h * 0.98) / (w * 0.62);
                k = Math.Max(0, 1 - Math.Sqrt(dx * dx + dy * dy));
                k *= k * 0.26;
                r += 255 * k; g += 122 * k; b += 47 * k;

                int n = rnd.Next(-2, 3);
                int i = y * stride + x * 4;
                buf[i]     = Clamp(b + n);
                buf[i + 1] = Clamp(g + n);
                buf[i + 2] = Clamp(r + n);
                buf[i + 3] = 255;
            }
        }
        System.Runtime.InteropServices.Marshal.Copy(buf, 0, data.Scan0, buf.Length);
        bmp.UnlockBits(data);
        return bmp;
    }

    static GraphicsPath RoundRect(Rectangle r, int radius)
    {
        var path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static Bitmap BarTrack(int w, int h)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var r = new Rectangle(0, 0, w - 1, h - 1);
            using (var path = RoundRect(r, h / 2))
            {
                using (var br = new LinearGradientBrush(r, Color.FromArgb(255, 28, 19, 50), Color.FromArgb(255, 40, 28, 72), 90f))
                    g.FillPath(br, path);
                using (var pen = new Pen(Color.FromArgb(90, 122, 92, 214), 1f))
                    g.DrawPath(pen, path);
            }
        }
        return bmp;
    }

    public static Bitmap BarFill(int w, int h)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var r = new Rectangle(0, 0, w - 1, h - 1);
            using (var path = RoundRect(r, h / 2))
            {
                using (var br = new LinearGradientBrush(r, Color.FromArgb(255, 122, 75, 232), Color.FromArgb(255, 255, 138, 60), 0f))
                {
                    br.InterpolationColors = new ColorBlend
                    {
                        Colors = new Color[] {
                            Color.FromArgb(255, 122, 75, 232),
                            Color.FromArgb(255, 158, 85, 224),
                            Color.FromArgb(255, 212, 101, 160),
                            Color.FromArgb(255, 255, 138, 60)
                        },
                        Positions = new float[] { 0f, 0.38f, 0.68f, 1f }
                    };
                    g.FillPath(br, path);
                }
                using (var hl = new LinearGradientBrush(r, Color.FromArgb(70, 255, 255, 255), Color.FromArgb(0, 255, 255, 255), 90f))
                    g.FillPath(hl, path);
            }
        }
        return bmp;
    }

    public static void SaveIco(Bitmap src, string path, int[] sizes)
    {
        var pngs = new byte[sizes.Length][];
        for (int i = 0; i < sizes.Length; i++)
        {
            using (var b = Resize(src, sizes[i]))
            using (var ms = new MemoryStream())
            {
                b.Save(ms, ImageFormat.Png);
                pngs[i] = ms.ToArray();
            }
        }
        using (var fs = new FileStream(path, FileMode.Create))
        using (var bw = new BinaryWriter(fs))
        {
            bw.Write((ushort)0); bw.Write((ushort)1); bw.Write((ushort)sizes.Length);
            int offset = 6 + 16 * sizes.Length;
            for (int i = 0; i < sizes.Length; i++)
            {
                byte dim = (byte)(sizes[i] >= 256 ? 0 : sizes[i]);
                bw.Write(dim); bw.Write(dim); bw.Write((byte)0); bw.Write((byte)0);
                bw.Write((ushort)1); bw.Write((ushort)32);
                bw.Write(pngs[i].Length); bw.Write(offset);
                offset += pngs[i].Length;
            }
            foreach (var p in pngs) bw.Write(p);
        }
    }
}
'@

Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing

$src = [System.Drawing.Image]::FromFile($logo)
$big = New-Object System.Drawing.Bitmap $src
$src.Dispose()

$cropped = [SgAssets]::Crop($big, 100, 0.055)
$green = [SgAssets]::Resize($cropped, 1024)
$green.Save((Join-Path $out 'logo-green.png'), [System.Drawing.Imaging.ImageFormat]::Png)

$purple = [SgAssets]::Purple($green)
$purple.Save((Join-Path $out 'logo-purple.png'), [System.Drawing.Imaging.ImageFormat]::Png)

$hero = [SgAssets]::Hero($purple, 660, 1260)
$hero.Save((Join-Path $out 'hero.png'), [System.Drawing.Imaging.ImageFormat]::Png)

$back = [SgAssets]::Back(1192, 864)
$back.Save((Join-Path $out 'back.png'), [System.Drawing.Imaging.ImageFormat]::Png)

$small = [SgAssets]::Resize($green, 174)
$small.Save((Join-Path $out 'small.png'), [System.Drawing.Imaging.ImageFormat]::Png)

[SgAssets]::SaveIco($cropped, (Join-Path $out 'icon.ico'), @(16, 20, 24, 32, 40, 48, 64, 96, 128, 256))

$bt = [SgAssets]::BarTrack(1200, 22)
$bt.Save((Join-Path $out 'bar-track.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bf = [SgAssets]::BarFill(1200, 22)
$bf.Save((Join-Path $out 'bar-fill.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bt.Dispose(); $bf.Dispose()
Copy-Item (Join-Path $out 'icon.ico') (Join-Path $root 'windows\runner\resources\app_icon.ico') -Force

$green.Dispose(); $purple.Dispose(); $hero.Dispose(); $back.Dispose(); $small.Dispose(); $cropped.Dispose()
Get-ChildItem $out | Select-Object Name, Length | Format-Table -AutoSize
