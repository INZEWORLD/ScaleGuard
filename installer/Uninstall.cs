using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("ScaleGuard Uninstall")]
[assembly: AssemblyProduct("ScaleGuard")]
[assembly: AssemblyCompany("ScaleGuard")]
[assembly: AssemblyDescription("Удаление ScaleGuard")]
[assembly: AssemblyVersion("1.1.2.0")]
[assembly: AssemblyFileVersion("1.1.2.0")]

namespace ScaleGuardSetup
{
    enum State { Confirm, Working, Done, Error }

    class UninstallForm : Form
    {
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("shell32.dll")] static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

        const int WM_NCLBUTTONDOWN = 0xA1;
        const int HTCAPTION = 2;

        readonly Timer timer = new Timer();
        Bitmap logo;
        float S = 1f;
        State state = State.Confirm;
        string error = "";
        string hover = "";
        string pressed = "";
        string dir = "";

        public UninstallForm()
        {
            Text = "Удаление ScaleGuard";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = true;
            DoubleBuffered = true;
            BackColor = C.Bg;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            timer.Interval = 60;
            timer.Tick += OnTimer;
        }

        int I(int v) { return (int)Math.Round(v * S); }
        Rectangle Rect(int x, int y, int w, int h) { return new Rectangle(I(x), I(y), I(w), I(h)); }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            S = DeviceDpi / 96f;
            ClientSize = new Size(I(600), I(370));
            using (var p = Draw.Round(new Rectangle(0, 0, ClientSize.Width, ClientSize.Height), I(16)))
                Region = new Region(p);
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + (area.Height - Height) / 2);
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("SgLogo"))
            {
                if (s != null) using (var img = Image.FromStream(s)) logo = new Bitmap(img);
            }
            dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

            var full = new Rectangle(0, 0, ClientSize.Width, ClientSize.Height);
            using (var br = new LinearGradientBrush(full, Color.FromArgb(15, 10, 26), Color.FromArgb(8, 5, 15), 90f))
                g.FillRectangle(br, full);
            Draw.Glow(g, new Point(I(110), I(110)), I(190), C.PurpleSoft, 58);
            Draw.Glow(g, new Point(I(520), I(360)), I(180), C.Orange, 24);
            if (logo != null) Draw.Logo(g, logo, Rect(46, 42, 112, 112), true);

            Draw.TextLeft(g, "ScaleGuard · удаление", F.UiSmall, C.TextMuted, Rect(16, 10, 200, 20), false);

            if (state == State.Done)
            {
                Draw.BadgeCheck(g, Rect(46, 42, 96, 96));
                Draw.TextLeft(g, "ScaleGuard удалён", F.Title, C.Text, Rect(180, 56, 380, 42), false);
                Draw.TextLeft(g, "Ярлыки и записи установщика удалены. Настройки входа сохранены.",
                    F.Sub, C.TextDim, Rect(180, 104, 380, 50), true);
            }
            else if (state == State.Error)
            {
                Draw.BadgeBang(g, Rect(46, 42, 96, 96));
                Draw.TextLeft(g, "Не удалось удалить", F.Title, C.Text, Rect(180, 56, 380, 42), false);
                Draw.TextLeft(g, error, F.Sub, C.TextDim, Rect(180, 104, 380, 110), true);
            }
            else
            {
                Draw.TextLeft(g, "Удалить ScaleGuard?", F.Title, C.Text, Rect(180, 52, 380, 42), false);
                Draw.TextLeft(g, "Приложение, ярлыки и записи установщика будут удалены. Настройки входа и подписка сохранятся.",
                    F.Sub, C.TextDim, Rect(180, 102, 380, 70), true);
                if (state == State.Working)
                    Draw.TextLeft(g, "Удаляем…", F.Small, C.TextMuted, Rect(180, 186, 380, 22), false);
            }

            var line = Rect(46, 298, 508, 1);
            using (var br = new LinearGradientBrush(new Rectangle(line.X, line.Y, line.Width, 2),
                Color.FromArgb(0, 46, 34, 78), Color.FromArgb(70, 46, 34, 78), 0f))
                g.FillRectangle(br, line);

            if (state == State.Confirm || state == State.Error)
            {
                Draw.Button(g, Rect(46, 318, 150, 44), state == State.Error ? "Закрыть" : "Отмена", false,
                    hover == "no", pressed == "no", true, F.Button);
                if (state == State.Confirm)
                    DangerButton(g, Rect(396, 318, 158, 44), "Удалить", hover == "yes", pressed == "yes");
            }

            bool canClose = state != State.Working;
            var cr = CloseRect();
            if (hover == "close" && canClose)
                Draw.FillRound(g, cr, I(7), Color.FromArgb(58, 20, 30));
            Color xcol = !canClose ? Color.FromArgb(80, 74, 96) : (hover == "close" ? C.Danger : C.TextDim);
            using (var pen = new Pen(xcol, Math.Max(1.4f, I(1))))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                int cx = cr.X + cr.Width / 2;
                int cy = cr.Y + cr.Height / 2;
                int u = I(4);
                g.DrawLine(pen, cx - u, cy - u, cx + u, cy + u);
                g.DrawLine(pen, cx + u, cy - u, cx - u, cy + u);
            }

            Draw.StrokeRound(g, new Rectangle(0, 0, ClientSize.Width - 1, ClientSize.Height - 1), I(16),
                Color.FromArgb(120, 54, 40, 96), 1f);
        }

        void DangerButton(Graphics g, Rectangle r, string text, bool hover, bool pressed)
        {
            using (var p = Draw.Round(r, I(9)))
            {
                using (var br = new LinearGradientBrush(r, Color.FromArgb(214, 69, 80), C.Orange, 0f))
                    g.FillPath(br, p);
                if (hover) using (var b = new SolidBrush(Color.FromArgb(30, 255, 255, 255))) g.FillPath(b, p);
                if (pressed) using (var b = new SolidBrush(Color.FromArgb(40, 0, 0, 0))) g.FillPath(b, p);
            }
            Draw.TextCenter(g, text, F.Button, Color.White, r);
        }

        Rectangle YesRect() { return Rect(396, 318, 158, 44); }
        Rectangle NoRect() { return Rect(46, 318, 150, 44); }
        Rectangle CloseRect() { return new Rectangle(ClientSize.Width - I(46), I(8), I(32), I(28)); }

        string HitAt(Point p)
        {
            if (state != State.Working && CloseRect().Contains(p)) return "close";
            if (state == State.Confirm && YesRect().Contains(p)) return "yes";
            if ((state == State.Confirm || state == State.Error) && NoRect().Contains(p)) return "no";
            return "";
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (state == State.Working)
            {
                e.Cancel = true;
                return;
            }
            base.OnFormClosing(e);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            string h = HitAt(e.Location);
            if (h != hover) { hover = h; Cursor = h.Length > 0 ? Cursors.Hand : Cursors.Default; Invalidate(); }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (hover.Length > 0) { hover = ""; Cursor = Cursors.Default; Invalidate(); }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            string h = HitAt(e.Location);
            if (h.Length > 0) { pressed = h; Invalidate(); return; }
            if (e.Y < I(40))
            {
                ReleaseCapture();
                SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (pressed.Length == 0) return;
            string id = pressed;
            pressed = "";
            if (id == HitAt(e.Location))
            {
                if (id == "no" || id == "close") Close();
                else if (id == "yes") StartWork();
            }
            Invalidate();
        }

        void StartWork()
        {
            state = State.Working;
            Invalidate();
            timer.Start();
        }

        void OnTimer(object sender, EventArgs e)
        {
            timer.Stop();
            string err = Worker.Run(dir);
            if (err == null)
            {
                state = State.Done;
                Invalidate();
                var t2 = new Timer();
                t2.Interval = 900;
                t2.Tick += delegate { t2.Stop(); t2.Dispose(); Close(); };
                t2.Start();
            }
            else
            {
                error = err;
                state = State.Error;
                Invalidate();
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) timer.Dispose();
            base.Dispose(disposing);
        }
    }

    static class Worker
    {
        public static string Run(string dir)
        {
            try
            {
                Kill("ScaleGuard");
                KillInDir("mihomo", dir);

                string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                SafeFile(Path.Combine(programs, "ScaleGuard.lnk"));
                SafeFile(Path.Combine(programs, "Удалить ScaleGuard.lnk"));
                SafeDir(Path.Combine(programs, "ScaleGuard"));
                SafeFile(Path.Combine(desktop, "ScaleGuard.lnk"));

                CleanupUninstallKeys();
                SafeKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\ScaleGuard");
                SafeKey(@"Software\Classes\scaleguard");
                SafeKey(@"Software\ScaleGuard");

                ScheduleDelete(dir);
                SHChangeNotify(0x08000000, 0x1000, IntPtr.Zero, IntPtr.Zero);
                return null;
            }
            catch (Exception ex)
            {
                return ex.Message;
            }
        }

        static void Kill(string name)
        {
            try
            {
                foreach (Process p in Process.GetProcessesByName(name))
                {
                    try { p.Kill(); p.WaitForExit(4000); } catch { }
                }
            }
            catch { }
        }

        static void KillInDir(string name, string dir)
        {
            try
            {
                foreach (Process p in Process.GetProcessesByName(name))
                {
                    string path = null;
                    try { path = p.MainModule.FileName; } catch { }
                    if (path != null && path.StartsWith(dir, StringComparison.OrdinalIgnoreCase))
                    {
                        try { p.Kill(); p.WaitForExit(4000); } catch { }
                    }
                }
            }
            catch { }
        }

        static void CleanupUninstallKeys()
        {
            try
            {
                using (RegistryKey un = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Uninstall", true))
                {
                    if (un == null) return;
                    foreach (string n in un.GetSubKeyNames())
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

        static void SafeFile(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }

        static void SafeDir(string path)
        {
            try { if (Directory.Exists(path)) Directory.Delete(path, true); } catch { }
        }

        static void SafeKey(string path)
        {
            try { Registry.CurrentUser.DeleteSubKeyTree(path, false); } catch { }
        }

        static void ScheduleDelete(string dir)
        {
            try
            {
                var psi = new ProcessStartInfo("cmd.exe", "/c ping 127.0.0.1 -n 3 >nul & rd /s /q \"" + dir + "\"");
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                // Важно: cmd не должен работать из удаляемой папки, иначе rd
                // не сможет удалить её (папка — текущий каталог процесса).
                psi.WorkingDirectory = Path.GetTempPath();
                Process.Start(psi);
            }
            catch { }
        }

        [DllImport("shell32.dll")] static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
    }

    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            bool silent = false;
            foreach (string a in args)
            {
                if (a == "/S" || a == "--silent" || a == "/silent") silent = true;
            }
            if (silent)
            {
                Worker.Run(dir);
                return;
            }
            Application.Run(new UninstallForm());
        }
    }
}
