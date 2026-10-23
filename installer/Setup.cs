using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("ScaleGuard Setup")]
[assembly: AssemblyProduct("ScaleGuard")]
[assembly: AssemblyCompany("ScaleGuard")]
[assembly: AssemblyDescription("Установщик ScaleGuard")]
[assembly: AssemblyVersion("1.1.4.0")]
[assembly: AssemblyFileVersion("1.1.4.0")]
[assembly: AssemblyInformationalVersion("1.1.4")]

namespace ScaleGuardSetup
{
    static class Const
    {
        public const string Version = "1.1.4";
        public const string AppName = "ScaleGuard";
        public const string SiteUrl = "https://scaleguard.inzeworld.com";
        public const string PayloadRes = "ScaleGuardPayload";
        public const string UninstallRes = "ScaleGuardUninstaller";

        // Экран, на котором запущен установщик: splash и основное окно
        // центрируются на нём, чтобы не «прыгать» между мониторами.
        public static Rectangle StartArea = Rectangle.Empty;

        public static void CenterIn(Form form, Rectangle area)
        {
            if (area.Width <= 0 || area.Height <= 0) area = Screen.PrimaryScreen.WorkingArea;
            form.Location = new Point(area.Left + (area.Width - form.Width) / 2,
                area.Top + (area.Height - form.Height) / 2);
        }

        public static void Log(string message)
        {
            try
            {
                File.AppendAllText(Path.Combine(Path.GetTempPath(), "scaleguard_setup.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff ") + message + "\r\n");
            }
            catch { }
        }
    }

    static class Assets
    {
        public static Bitmap Logo;
        public static Bitmap Back;

        public static Stream Res(string name)
        {
            return Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
        }

        public static Bitmap Bitmap(string name)
        {
            using (Stream s = Res(name))
            {
                if (s == null) return null;
                using (Image img = Image.FromStream(s))
                    return new Bitmap(img);
            }
        }

        public static void Load()
        {
            if (Logo == null) Logo = Bitmap("SgLogo");
            if (Back == null) Back = Bitmap("SgBack");
        }
    }

    enum Page { Welcome, Installing, Done, Error }
    enum Overlay { None, Running, Overwrite }

    class Hit
    {
        public string Id;
        public Rectangle Rect;
        public Hit(string id, Rectangle rect) { Id = id; Rect = rect; }
    }

    // Экран запуска: карточка с драконом по центру экрана. Кадр рисуется
    // один раз, а плавность даёт сама прозрачность окна — без нагрузки на CPU.
    class SplashForm : Form
    {
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly Stopwatch clock = new Stopwatch();
        Bitmap card;
        float S = 1f;

        public SplashForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            DoubleBuffered = true;
            BackColor = C.Bg;
            Opacity = 0;
            timer.Interval = 15;
            timer.Tick += OnTick;
        }

        int I(int v) { return (int)Math.Round(v * S); }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            Assets.Load();
            S = DeviceDpi / 96f;
            ClientSize = new Size(I(520), I(380));
            using (var path = Draw.Round(new Rectangle(0, 0, ClientSize.Width, ClientSize.Height), I(18)))
                Region = new Region(path);
            Const.CenterIn(this, Const.StartArea);
            card = BuildCard();
            clock.Start();
            timer.Start();
        }

        Bitmap BuildCard()
        {
            var bmp = new Bitmap(ClientSize.Width, ClientSize.Height);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;

                var full = new Rectangle(0, 0, bmp.Width, bmp.Height);
                using (var br = new LinearGradientBrush(full, Color.FromArgb(16, 10, 28), Color.FromArgb(8, 5, 15), 90f))
                    g.FillRectangle(br, full);

                Draw.Glow(g, new Point(I(260), I(152)), I(220), C.PurpleSoft, 54);
                Draw.Glow(g, new Point(I(300), I(372)), I(200), C.Orange, 22);

                if (Assets.Logo != null)
                    Draw.Logo(g, Assets.Logo, new Rectangle(I(145), I(34), I(230), I(230)), true);

                Draw.TextCenter(g, Const.AppName, F.Splash, C.Text, new Rectangle(0, I(284), bmp.Width, I(38)));
                var line = new Rectangle(I(170), I(330), I(180), I(3));
                using (var p = Draw.Round(line, I(2)))
                using (var br = new LinearGradientBrush(line, C.Purple, C.Orange, 0f))
                    g.FillPath(br, p);
                Draw.TextCenter(g, "УСТАНОВКА", F.Tiny, C.TextMuted, new Rectangle(0, I(342), bmp.Width, I(18)));

                Draw.StrokeRound(g, new Rectangle(0, 0, bmp.Width - 1, bmp.Height - 1), I(18), C.Border, 1f);
            }
            return bmp;
        }

        void OnTick(object sender, EventArgs e)
        {
            double t = clock.Elapsed.TotalMilliseconds;
            if (t < 240) Opacity = t / 240.0;
            else if (t < 1150) Opacity = 1;
            else if (t < 1450) Opacity = 1 - (t - 1150) / 300.0;
            else { timer.Stop(); Close(); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (card != null) e.Graphics.DrawImage(card, 0, 0);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                timer.Dispose();
                if (card != null) card.Dispose();
            }
            base.Dispose(disposing);
        }
    }
    class SetupForm : Form
    {
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("shell32.dll")] static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

        const int WM_NCLBUTTONDOWN = 0xA1;
        const int HTCAPTION = 2;

        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly Stopwatch fadeClock = new Stopwatch();
        readonly object sync = new object();
        readonly List<Hit> hits = new List<Hit>();
        readonly bool updateMode;

        Bitmap bg;
        float S = 1f;
        Page page = Page.Welcome;
        Overlay overlay = Overlay.None;
        string installPath = "";
        bool desktopShortcut = true;
        bool launchAfter = true;
        int autoLaunchAt;
        string errorText = "";

        float shownProgress;
        float targetProgress;
        float pageAnim = 1f;
        string hoverId = "";
        string pressedId = "";

        long bytesDone;
        long bytesTotal = 1;
        string currentFile = "";
        bool installDone;
        bool installFailed;
        string installError = "";

        public SetupForm(bool updateMode)
        {
            this.updateMode = updateMode;
            Text = updateMode ? "ScaleGuard — обновление" : "ScaleGuard — установка";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            MaximizeBox = false;
            MinimizeBox = true;
            ShowInTaskbar = true;
            DoubleBuffered = true;
            Opacity = 0;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            installPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", Const.AppName);
            timer.Interval = 16;
            timer.Tick += OnTick;
        }

        int I(int v) { return (int)Math.Round(v * S); }

        Rectangle Rect(int x, int y, int w, int h) { return new Rectangle(I(x), I(y), I(w), I(h)); }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            S = DeviceDpi / 96f;
            ClientSize = new Size(I(900), I(580));
            using (var path = Draw.Round(new Rectangle(0, 0, ClientSize.Width, ClientSize.Height), I(16)))
                Region = new Region(path);
            Const.CenterIn(this, Const.StartArea);
            Assets.Load();
            BuildBackground();
            LayoutHits();
            timer.Start();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            fadeClock.Start();
            TopMost = true;
            TopMost = false;
            Activate();
            if (updateMode)
            {
                // Started by the application itself: there is no folder to pick,
                // no shortcut to opt out of and no "already running" question -
                // the caller is the running copy and it is already closing.
                launchAfter = true;
                page = Page.Installing;
                pageAnim = 0f;
                LayoutHits();
                BeginInstall();
                Invalidate();
            }
            else if (AppRunning())
            {
                overlay = Overlay.Running;
                LayoutHits();
                Invalidate();
            }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (page == Page.Installing && !installDone && !installFailed && true)
            {
                e.Cancel = true;
                return;
            }
            base.OnFormClosing(e);
        }

        // ---------- фон ----------

        void BuildBackground()
        {
            if (bg != null) bg.Dispose();
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            bg = new Bitmap(w, h);
            using (Graphics g = Graphics.FromImage(bg))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                if (Assets.Back != null)
                    g.DrawImage(Assets.Back, new Rectangle(0, 0, w, h));
                else
                {
                    using (var br = new LinearGradientBrush(new Rectangle(0, 0, w, h), C.BgDeep, C.Bg, 90f))
                        g.FillRectangle(br, 0, 0, w, h);
                }
                using (var b = new SolidBrush(Color.FromArgb(46, 0, 0, 0)))
                    g.FillRectangle(b, 0, 0, w, h);

                if (Assets.Logo != null)
                {
                    int ds = I(278);
                    Draw.Logo(g, Assets.Logo, new Rectangle(I(38), I(110), ds, ds), true);
                }

                Draw.TextLeft(g, Const.AppName, F.Hero, C.Text, Rect(38, 408, 290, 30), false);
                Draw.TextLeft(g, "Приватный интернет", F.Small, C.TextMuted, Rect(38, 438, 290, 20), false);
                Draw.TextLeft(g, "Версия " + Const.Version + " · Windows 10/11", F.Tiny,
                    Color.FromArgb(111, 101, 136), Rect(38, 462, 290, 18), false);

                using (var br = new LinearGradientBrush(Rect(362, 92, 1, 396),
                    Color.FromArgb(0, 46, 34, 78), Color.FromArgb(80, 46, 34, 78), 90f))
                    g.FillRectangle(br, Rect(362, 92, 1, 396));
            }
        }

        // ---------- отрисовка ----------

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;

            if (bg != null) g.DrawImage(bg, 0, 0);

            int off = (int)((1 - EaseOut(pageAnim)) * I(12));
            g.TranslateTransform(0, off);
            switch (page)
            {
                case Page.Welcome: PaintWelcome(g); break;
                case Page.Installing: PaintInstalling(g); break;
                case Page.Done: PaintDone(g); break;
                case Page.Error: PaintError(g); break;
            }
            g.ResetTransform();

            PaintTitleBar(g);
            if (overlay != Overlay.None) PaintOverlay(g);

            Draw.StrokeRound(g, new Rectangle(0, 0, ClientSize.Width - 1, ClientSize.Height - 1), I(16),
                Color.FromArgb(120, 54, 40, 96), 1f);
        }

        static float EaseOut(float t)
        {
            if (t >= 1f) return 1f;
            float u = 1f - t;
            return 1f - u * u * u;
        }

        void PaintTitleBar(Graphics g)
        {
            var tile = Rect(14, 8, 28, 28);
            using (var p = Draw.Round(tile, I(8)))
            {
                using (var br = new LinearGradientBrush(tile, Color.FromArgb(38, 26, 64), Color.FromArgb(20, 14, 38), 90f))
                    g.FillPath(br, p);
                using (var pen = new Pen(Color.FromArgb(70, 96, 74, 158), 1f))
                    g.DrawPath(pen, p);
            }
            if (Assets.Logo != null)
                Draw.TitleIcon(g, Assets.Logo, Rect(18, 12, 20, 20));
            Draw.TextLeft(g, Const.AppName, F.Ui, C.Text, Rect(51, 10, 120, 24), false);
            float tw = g.MeasureString(Const.AppName, F.Ui).Width;
            Draw.TextLeft(g, updateMode ? "Обновление" : "Установка", F.UiSmall, C.TextMuted,
                new Rectangle(I(51) + (int)tw + I(8), I(12), I(120), I(20)), false);

            bool closeEnabled = page != Page.Installing || installDone || installFailed;
            PaintWindowButton(g, MinRect(), hoverId == "min", false, false);
            PaintWindowButton(g, CloseRect(), hoverId == "close" && closeEnabled, true, !closeEnabled);
        }

        void PaintWindowButton(Graphics g, Rectangle r, bool hover, bool close, bool disabled)
        {
            if (hover && !disabled)
                Draw.FillRound(g, r, I(7), close ? Color.FromArgb(58, 20, 30) : Color.FromArgb(30, 22, 52));
            Color col = disabled ? Color.FromArgb(80, 74, 96) : (close && hover ? C.Danger : C.TextDim);
            using (var pen = new Pen(col, Math.Max(1.4f, I(1))))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                int cx = r.X + r.Width / 2;
                int cy = r.Y + r.Height / 2;
                int u = I(4);
                if (close)
                {
                    g.DrawLine(pen, cx - u, cy - u, cx + u, cy + u);
                    g.DrawLine(pen, cx + u, cy - u, cx - u, cy + u);
                }
                else
                {
                    g.DrawLine(pen, cx - u - 1, cy, cx + u + 1, cy);
                }
            }
        }

        void PaintWelcome(Graphics g)
        {
            int x = I(390), w = I(470);
            Draw.TextLeft(g, "Установка ScaleGuard", F.Title, C.Text, new Rectangle(x, I(90), w, I(42)), false);
            Draw.TextLeft(g, "Быстрый и приватный интернет. Установка займёт меньше минуты — права администратора не нужны.",
                F.Sub, C.TextDim, new Rectangle(x, I(136), w, I(48)), true);

            var card = new Rectangle(x, I(196), w, I(76));
            Draw.FillRound(g, card, I(14), C.Card);
            Draw.StrokeRound(g, card, I(14), C.BorderSoft, 1f);
            Draw.TextLeft(g, "ПАПКА УСТАНОВКИ", F.Tiny, C.TextMuted, new Rectangle(x + I(18), I(208), w - I(36), I(14)), false);
            string shown = Draw.ShortPath(installPath, F.Path, w - I(148), g);
            Draw.TextLeft(g, shown, F.Path, C.Text, new Rectangle(x + I(18), I(228), w - I(148), I(22)), false);
            bool chHover = hoverId == "change";
            if (chHover)
            {
                var pill = new Rectangle(x + w - I(118), I(221), I(100), I(31));
                Draw.FillRound(g, pill, I(9), Color.FromArgb(34, 40, 29, 74));
                Draw.StrokeRound(g, pill, I(9), Color.FromArgb(60, 74, 56, 122), 1f);
            }
            Draw.TextRight(g, "Изменить", F.Small, chHover ? Color.White : C.Link,
                new Rectangle(x + w - I(110), I(228), I(93), I(20)));

            if (hoverId == "desktop") Draw.FillRound(g, Rect(380, 286, 480, 32), I(10), Color.FromArgb(22, 30, 22, 52));
            if (hoverId == "run") Draw.FillRound(g, Rect(380, 326, 480, 32), I(10), Color.FromArgb(22, 30, 22, 52));
            Draw.Check(g, Rect(390, 292, 20, 20), desktopShortcut, hoverId == "desktop",
                "Создать ярлык на рабочем столе", Rect(420, 288, 440, 28));
            Draw.Check(g, Rect(390, 332, 20, 20), launchAfter, hoverId == "run",
                "Запустить ScaleGuard после установки", Rect(420, 328, 440, 28));

            PaintFooter(g);
            Draw.Button(g, Rect(36, 508, 142, 46), "Отмена", false, hoverId == "cancel", pressedId == "cancel", true, F.Button);
            Draw.Button(g, Rect(688, 508, 176, 46), "Установить", true, hoverId == "install", pressedId == "install", true, F.Button);
        }

        void PaintInstalling(Graphics g)
        {
            int x = I(390), w = I(470);
            Draw.TextLeft(g, "Устанавливаем ScaleGuard", F.Title, C.Text, new Rectangle(x, I(90), w, I(42)), false);

            string pct = ((int)Math.Round(shownProgress * 100f)).ToString() + "%";
            Draw.TextLeft(g, "Распаковываем файлы…", F.Sub, C.TextDim, new Rectangle(x, I(148), w - I(80), I(26)), false);
            Draw.TextRight(g, pct, F.Title, C.Text, new Rectangle(x + w - I(80), I(138), I(80), I(36)));

            Draw.Progress(g, new Rectangle(x, I(190), w, I(12)), shownProgress);

            string file = currentFile == null ? "" : currentFile.Replace('/', '\\');
            if (file.Length > 64) file = "…" + file.Substring(file.Length - 63);
            Draw.TextLeft(g, file, F.Tiny, C.TextMuted, new Rectangle(x, I(212), w, I(18)), false);
            Draw.TextLeft(g, "Обычно это занимает меньше минуты.", F.Small, C.TextMuted, new Rectangle(x, I(252), w, I(20)), false);

            PaintFooter(g);
            Draw.Button(g, Rect(36, 508, 160, 46), "Свернуть", false, hoverId == "minimize-install",
                pressedId == "minimize-install", true, F.Button);
        }

        void PaintDone(Graphics g)
        {
            int x = I(390), w = I(470);
            Draw.BadgeCheck(g, Rect(390, 104, 78, 78));
            Draw.TextLeft(g, "Готово!", F.TitleBig, C.Text, new Rectangle(x, I(198), w, I(44)), false);
            Draw.TextLeft(g, "ScaleGuard установлен на этот компьютер.", F.Sub, C.TextDim,
                new Rectangle(x, I(246), w, I(26)), false);
            Draw.TextLeft(g, "Запустите его и нажмите «Подключиться».", F.Small, C.TextMuted,
                new Rectangle(x, I(272), w, I(22)), false);
            if (desktopShortcut)
                Draw.TextLeft(g, "Ярлык уже на рабочем столе.", F.Small, C.TextMuted,
                    new Rectangle(x, I(296), w, I(22)), false);

            PaintFooter(g);
            Draw.Button(g, Rect(36, 508, 142, 46), "Закрыть", false, hoverId == "finish", pressedId == "finish", true, F.Button);
            Draw.Button(g, Rect(652, 508, 212, 46), "Запустить ScaleGuard", true, hoverId == "launch", pressedId == "launch", true, F.Button);
        }

        void PaintError(Graphics g)
        {
            int x = I(390), w = I(470);
            Draw.BadgeBang(g, Rect(390, 104, 78, 78));
            Draw.TextLeft(g, "Не удалось установить", F.Title, C.Text, new Rectangle(x, I(198), w, I(42)), false);
            Draw.TextLeft(g, errorText, F.Body, C.TextDim, new Rectangle(x, I(246), w, I(120)), true);

            PaintFooter(g);
            Draw.Button(g, Rect(36, 508, 142, 46), "Закрыть", false, hoverId == "errclose", pressedId == "errclose", true, F.Button);
            Draw.Button(g, Rect(700, 508, 164, 46), "Повторить", true, hoverId == "retry", pressedId == "retry", true, F.Button);
        }

        void PaintFooter(Graphics g)
        {
            var line = Rect(36, 492, 828, 1);
            using (var br = new LinearGradientBrush(new Rectangle(line.X, line.Y, Math.Max(1, line.Width), 2),
                Color.FromArgb(0, 46, 34, 78), Color.FromArgb(70, 46, 34, 78), 0f))
            {
                g.FillRectangle(br, line);
            }
        }

        void PaintOverlay(Graphics g)
        {
            using (var b = new SolidBrush(Color.FromArgb(178, 4, 2, 10)))
                g.FillRectangle(b, 0, 0, ClientSize.Width, ClientSize.Height);

            var card = new Rectangle(ClientSize.Width / 2 - I(220), ClientSize.Height / 2 - I(112), I(440), I(224));
            Draw.FillRound(g, card, I(16), C.Card);
            Draw.StrokeRound(g, card, I(16), C.Border, 1f);

            bool run = overlay == Overlay.Running;
            Draw.TextLeft(g, run ? "ScaleGuard уже запущен" : "Папка уже существует",
                F.DialogTitle, C.Text, new Rectangle(card.X + I(24), card.Y + I(24), card.Width - I(48), I(28)), false);
            string text = run
                ? "Закройте приложение (правый клик по значку в трее → «Выход») и нажмите «Повторить»."
                : "В папке уже есть файлы. Установить ScaleGuard поверх?";
            Draw.TextLeft(g, text, F.Body, C.TextDim, new Rectangle(card.X + I(24), card.Y + I(60), card.Width - I(48), I(80)), true);

            Draw.Button(g, new Rectangle(card.X + I(24), card.Bottom - I(66), I(142), I(44)),
                "Отмена", false, hoverId == "ov-no", pressedId == "ov-no", true, F.Button);
            Draw.Button(g, new Rectangle(card.Right - I(190), card.Bottom - I(66), I(166), I(44)),
                run ? "Повторить" : "Продолжить", true, hoverId == "ov-yes", pressedId == "ov-yes", true, F.Button);
        }

        // ---------- разметка ----------

        Rectangle MinRect() { return new Rectangle(ClientSize.Width - I(84), I(8), I(32), I(28)); }
        Rectangle CloseRect() { return new Rectangle(ClientSize.Width - I(46), I(8), I(32), I(28)); }

        void LayoutHits()
        {
            hits.Clear();
            hits.Add(new Hit("min", MinRect()));
            if (page != Page.Installing || installDone || installFailed)
                hits.Add(new Hit("close", CloseRect()));

            if (overlay != Overlay.None)
            {
                var card = new Rectangle(ClientSize.Width / 2 - I(220), ClientSize.Height / 2 - I(112), I(440), I(224));
                hits.Add(new Hit("ov-no", new Rectangle(card.X + I(24), card.Bottom - I(66), I(142), I(44))));
                hits.Add(new Hit("ov-yes", new Rectangle(card.Right - I(190), card.Bottom - I(66), I(166), I(44))));
                return;
            }

            if (page == Page.Welcome)
            {
                hits.Add(new Hit("desktop", Rect(390, 286, 470, 32)));
                hits.Add(new Hit("run", Rect(390, 326, 470, 32)));
                hits.Add(new Hit("change", Rect(390 + 470 - 120, 224, 104, 32)));
                hits.Add(new Hit("cancel", Rect(36, 508, 142, 46)));
                hits.Add(new Hit("install", Rect(688, 508, 176, 46)));
            }
            else if (page == Page.Installing)
            {
                hits.Add(new Hit("minimize-install", Rect(36, 508, 160, 46)));
            }
            else if (page == Page.Done)
            {
                hits.Add(new Hit("finish", Rect(36, 508, 142, 46)));
                hits.Add(new Hit("launch", Rect(652, 508, 212, 46)));
            }
            else if (page == Page.Error)
            {
                hits.Add(new Hit("errclose", Rect(36, 508, 142, 46)));
                hits.Add(new Hit("retry", Rect(700, 508, 164, 46)));
            }
        }

        string HitAt(Point p)
        {
            for (int i = hits.Count - 1; i >= 0; i--)
            {
                var h = hits[i];
                if (h.Rect.Contains(p))
                {
                    if (h.Id == "close" && page == Page.Installing && !installDone && !installFailed)
                        return "";
                    return h.Id;
                }
            }
            return "";
        }

        // ---------- ввод ----------

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            string id = HitAt(e.Location);
            if (id != hoverId)
            {
                hoverId = id;
                Cursor = id.Length > 0 ? Cursors.Hand : Cursors.Default;
                Invalidate();
            }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (hoverId.Length > 0)
            {
                hoverId = "";
                Cursor = Cursors.Default;
                Invalidate();
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            string id = HitAt(e.Location);
            if (id.Length > 0)
            {
                pressedId = id;
                Invalidate();
                return;
            }
            if (e.Y < I(44) && !MinRect().Contains(e.Location) && !CloseRect().Contains(e.Location))
            {
                ReleaseCapture();
                SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (pressedId.Length == 0) return;
            string id = pressedId;
            pressedId = "";
            if (id == HitAt(e.Location)) DoAction(id);
            Invalidate();
        }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Enter || keyData == Keys.Escape) return true;
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Escape)
            {
                if (overlay != Overlay.None)
                {
                    overlay = Overlay.None;
                    LayoutHits();
                    Invalidate();
                }
                else if (page != Page.Installing)
                {
                    Close();
                }
            }
            else if (e.KeyCode == Keys.Enter)
            {
                if (overlay != Overlay.None) { DoAction("ov-yes"); }
                else if (page == Page.Welcome) { DoAction("install"); }
                else if (page == Page.Done) { DoAction("launch"); }
                else if (page == Page.Error) { DoAction("retry"); }
            }
        }

        void DoAction(string id)
        {
            switch (id)
            {
                case "min":
                case "minimize-install":
                    WindowState = FormWindowState.Minimized;
                    break;
                case "close":
                case "cancel":
                case "finish":
                case "errclose":
                    Close();
                    break;
                case "desktop":
                    desktopShortcut = !desktopShortcut;
                    break;
                case "run":
                    launchAfter = !launchAfter;
                    break;
                case "change":
                    BrowseFolder();
                    break;
                case "install":
                    TryInstall();
                    break;
                case "retry":
                    TryInstall();
                    break;
                case "launch":
                    LaunchApp();
                    break;
                case "ov-no":
                    overlay = Overlay.None;
                    LayoutHits();
                    break;
                case "ov-yes":
                    if (overlay == Overlay.Running)
                    {
                        if (AppRunning()) { overlay = Overlay.Running; }
                        else { overlay = Overlay.None; LayoutHits(); TryInstall(); }
                    }
                    else
                    {
                        overlay = Overlay.None;
                        LayoutHits();
                        BeginInstall();
                    }
                    break;
            }
            Invalidate();
        }

        void BrowseFolder()
        {
            using (var dlg = new FolderBrowserDialog())
            {
                dlg.Description = "Куда установить ScaleGuard";
                dlg.ShowNewFolderButton = true;
                dlg.SelectedPath = installPath;
                if (dlg.ShowDialog(this) == DialogResult.OK)
                    installPath = dlg.SelectedPath;
            }
        }

        static bool AppRunning()
        {
            try { return Process.GetProcessesByName("ScaleGuard").Length > 0; }
            catch { return false; }
        }

        /// <summary>
        /// Waits for the copy that started this updater to let go of its files.
        /// </summary>
        /// <remarks>
        /// The application launches the setup and then tears its tunnel down and
        /// exits. Extraction cannot overwrite ScaleGuard.exe or the native core
        /// while that process is alive, so the wait happens before the first
        /// byte is written. A stuck process must not hang the updater forever:
        /// after two minutes the install proceeds and, if a file really is still
        /// locked, the normal error page reports it.
        /// </remarks>
        void WaitForAppExit()
        {
            var clock = Stopwatch.StartNew();
            while (AppRunning() && clock.Elapsed.TotalSeconds < 120)
                Thread.Sleep(250);
            Const.Log("update: application exited after " +
                clock.ElapsedMilliseconds + " ms");
        }

        void TryInstall()
        {
            if (AppRunning()) { overlay = Overlay.Running; LayoutHits(); Invalidate(); return; }
            try
            {
                if (Directory.Exists(installPath) && Directory.GetFileSystemEntries(installPath).Length > 0)
                {
                    overlay = Overlay.Overwrite;
                    LayoutHits();
                    Invalidate();
                    return;
                }
            }
            catch { }
            BeginInstall();
        }

        void BeginInstall()
        {
            Const.Log("begin install: " + installPath + " desktop=" + desktopShortcut);
            page = Page.Installing;
            pageAnim = 0f;
            shownProgress = 0f;
            targetProgress = 0f;
            currentFile = "";
            installDone = false;
            installFailed = false;
            installError = "";
            LayoutHits();
            Invalidate();

            var t = new Thread(InstallThread);
            t.IsBackground = true;
            t.Start();
        }

        // ---------- установка ----------

        void InstallThread()
        {
            try
            {
                if (updateMode) WaitForAppExit();
                Directory.CreateDirectory(installPath);
                Const.Log("install dir ready: " + installPath);

                long total = 0;
                using (Stream payload = Assets.Res(Const.PayloadRes))
                using (var zip = new ZipArchive(payload, ZipArchiveMode.Read))
                {
                    foreach (var en in zip.Entries) total += en.Length;
                    long done = 0;
                    foreach (var en in zip.Entries)
                    {
                        string name = en.FullName.Replace('\\', '/');
                        bool isDir = name.EndsWith("/") || string.IsNullOrEmpty(en.Name);
                        string rel = name.TrimEnd('/').Replace('/', '\\');
                        if (rel.Length == 0) continue;
                        string dest = Path.Combine(installPath, rel);
                        if (isDir)
                        {
                            Directory.CreateDirectory(dest);
                            continue;
                        }
                        string dir = Path.GetDirectoryName(dest);
                        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                        using (Stream input = en.Open())
                        using (var output = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None))
                        {
                            var buf = new byte[131072];
                            int read;
                            while ((read = input.Read(buf, 0, buf.Length)) > 0)
                            {
                                output.Write(buf, 0, read);
                                done += read;
                                lock (sync) { bytesDone = done; bytesTotal = total; currentFile = en.FullName; }
                            }
                        }
                    }
                }

                Const.Log("payload extracted, bytes=" + total);

                // Подчищаем файлы прежнего установщика (Inno), чтобы не остались
                // два uninstall.exe и запись «ScaleGuard» в списке программ.
                // Шаблон с цифрой не трогает наш собственный uninstall.exe.
                try
                {
                    foreach (string old in Directory.GetFiles(installPath, "unins[0-9]*.*"))
                    {
                        try { File.Delete(old); } catch { }
                    }
                }
                catch { }

                using (Stream un = Assets.Res(Const.UninstallRes))
                using (var f = File.Create(Path.Combine(installPath, "uninstall.exe")))
                    un.CopyTo(f);
                Const.Log("uninstaller written");

                CreateShortcuts();
                WriteRegistry(installPath, total);
                Const.Log("shortcuts + registry done");

                lock (sync) { installDone = true; }
                Const.Log("install complete");
                SHChangeNotify(0x08000000, 0x1000, IntPtr.Zero, IntPtr.Zero);
            }
            catch (Exception ex)
            {
                Const.Log("INSTALL FAILED: " + ex);
                lock (sync)
                {
                    installFailed = true;
                    installError = ex.Message;
                }
            }
        }

        void CreateShortcuts()
        {
            string exe = Path.Combine(installPath, "ScaleGuard.exe");
            string un = Path.Combine(installPath, "uninstall.exe");
            string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);

            string oldGroup = Path.Combine(programs, "ScaleGuard");
            if (Directory.Exists(oldGroup))
            {
                try { Directory.Delete(oldGroup, true); } catch { }
            }

            MakeShortcut(Path.Combine(programs, "ScaleGuard.lnk"), exe, "", installPath, exe, "ScaleGuard");
            MakeShortcut(Path.Combine(programs, "Удалить ScaleGuard.lnk"), un, "", installPath, exe, "Удалить ScaleGuard");
            if (desktopShortcut)
                MakeShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    "ScaleGuard.lnk"), exe, "", installPath, exe, "ScaleGuard");
        }

        static void MakeShortcut(string lnk, string target, string args, string workDir, string icon, string desc)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(lnk));
                object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
                object sc = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
                Type t = sc.GetType();
                t.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { target });
                t.InvokeMember("Arguments", BindingFlags.SetProperty, null, sc, new object[] { args });
                t.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { workDir });
                t.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { icon + ",0" });
                t.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { desc });
                t.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
                Marshal.ReleaseComObject(sc);
                Marshal.ReleaseComObject(shell);
            }
            catch { }
        }

        static void WriteRegistry(string dir, long bytes)
        {
            CleanupOldUninstallEntries();
            string exe = Path.Combine(dir, "ScaleGuard.exe");
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\ScaleGuard"))
            {
                if (k != null)
                {
                    k.SetValue("DisplayName", "ScaleGuard");
                    k.SetValue("DisplayVersion", Const.Version);
                    k.SetValue("Publisher", "ScaleGuard");
                    k.SetValue("DisplayIcon", exe + ",0");
                    k.SetValue("InstallLocation", dir);
                    k.SetValue("UninstallString", "\"" + Path.Combine(dir, "uninstall.exe") + "\"");
                    k.SetValue("URLInfoAbout", Const.SiteUrl);
                    k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                    k.SetValue("EstimatedSize", (int)Math.Max(1, bytes / 1024), RegistryValueKind.DWord);
                }
            }
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\scaleguard"))
            {
                if (k != null)
                {
                    k.SetValue("", "URL:ScaleGuard Protocol");
                    k.SetValue("URL Protocol", "");
                    using (RegistryKey di = k.CreateSubKey("DefaultIcon")) di.SetValue("", exe + ",0");
                    using (RegistryKey cmd = k.CreateSubKey(@"shell\open\command"))
                        cmd.SetValue("", "\"" + exe + "\" \"%1\"");
                }
            }
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(@"Software\ScaleGuard"))
                k.SetValue("InstallDir", dir);
        }

        // Удаляет старые записи «ScaleGuard» (например, от прежнего Inno-установщика),
        // чтобы в «Приложениях» осталась одна строка.
        static void CleanupOldUninstallEntries()
        {
            try
            {
                using (RegistryKey un = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Uninstall", true))
                {
                    if (un == null) return;
                    var names = new List<string>();
                    foreach (string n in un.GetSubKeyNames())
                        if (n != "ScaleGuard") names.Add(n);
                    foreach (string n in names)
                    {
                        using (RegistryKey k = un.OpenSubKey(n))
                        {
                            if (k == null) continue;
                            object dn = k.GetValue("DisplayName");
                            if (dn != null && string.Equals(dn.ToString(), "ScaleGuard", StringComparison.OrdinalIgnoreCase))
                            {
                                try { un.DeleteSubKeyTree(n); } catch { }
                            }
                        }
                    }
                }
            }
            catch { }
        }

        void LaunchApp()
        {
            try
            {
                string exe = Path.Combine(installPath, "ScaleGuard.exe");
                if (File.Exists(exe))
                    Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = installPath, UseShellExecute = true });
            }
            catch { }
            Close();
        }

        // ---------- таймер ----------

        void OnTick(object sender, EventArgs e)
        {
            bool dirty = false;

            if (Opacity < 1)
            {
                Opacity = Math.Min(1.0, fadeClock.Elapsed.TotalMilliseconds / 220.0);
            }
            if (pageAnim < 1f)
            {
                pageAnim = Math.Min(1f, pageAnim + 0.09f);
                dirty = true;
            }

            if (page == Page.Installing)
            {
                long d, t;
                string f;
                bool done, failed;
                string err;
                lock (sync)
                {
                    d = bytesDone;
                    t = bytesTotal;
                    f = currentFile;
                    done = installDone;
                    failed = installFailed;
                    err = installError;
                }
                if (t > 0) targetProgress = (float)d / t;
                if (f != currentFile) { currentFile = f; dirty = true; }

                if (failed)
                {
                    errorText = string.IsNullOrEmpty(err) ? "Неизвестная ошибка." : err;
                    page = Page.Error;
                    pageAnim = 0f;
                    LayoutHits();
                    dirty = true;
                }
                else
                {
                    if (done) targetProgress = 1f;
                    float step = (targetProgress - shownProgress) * 0.18f;
                    if (step > 0) step = Math.Max(step, 0.0015f);
                    if (step < 0) step = Math.Min(step, -0.0015f);
                    shownProgress += step;
                    if (done && shownProgress > 0.999f) shownProgress = 1f;
                    if (Math.Abs(step) > 0.0001f) dirty = true;

                    if (done && shownProgress >= 1f)
                    {
                        page = Page.Done;
                        pageAnim = 0f;
                        // Галочка «Запустить после установки»: даём секунду
                        // посмотреть на «Готово» и открываем приложение.
                        if (launchAfter) autoLaunchAt = Environment.TickCount + (updateMode ? 700 : 1200);
                        LayoutHits();
                        dirty = true;
                    }
                }
            }

            if (autoLaunchAt != 0 && Environment.TickCount >= autoLaunchAt)
            {
                autoLaunchAt = 0;
                LaunchApp();
                return;
            }

            if (dirty) Invalidate();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                timer.Dispose();
                if (bg != null) bg.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Const.StartArea = Screen.FromPoint(Cursor.Position).WorkingArea;

            // `--update` is how the application hands the process over to a
            // newer installer: no splash, no questions, install over the current
            // copy and come back up. Everything else is the normal first-run
            // wizard.
            bool update = false;
            if (args != null)
            {
                foreach (string arg in args)
                {
                    if (string.Equals(arg, "--update", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(arg, "/update", StringComparison.OrdinalIgnoreCase))
                        update = true;
                }
            }
            Const.Log(update ? "setup started in update mode" : "setup started");

            bool created;
            using (var mutex = new Mutex(true, "ScaleGuardSetupSingleInstance", out created))
            {
                if (!created)
                    return;

                if (!update)
                {
                    try
                    {
                        using (var splash = new SplashForm())
                            splash.ShowDialog();
                    }
                    catch { }
                }

                Application.Run(new SetupForm(update));
            }
        }
    }
}
