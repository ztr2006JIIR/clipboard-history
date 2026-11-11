using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Launcher
{
    private const string MutexName = @"Local\ClipboardHistory.Launcher.6C606680-5314-4CD8-B52B-E6698920F45D";

    [STAThread]
    private static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        bool checkOnly = args.Length == 1 && args[0] == "--check";
        try
        {
            foreach (string name in new[] { "clipboard-history.ps1", "app-icon.png", "app-bubble.png" })
            {
                if (!File.Exists(Path.Combine(root, name)))
                    throw new FileNotFoundException("安装文件不完整，请重新安装：" + name);
            }

            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
                throw new FileNotFoundException("未找到 Windows PowerShell，请检查 Windows 系统组件。");
            if (checkOnly)
                return 0;

            bool created;
            using (Mutex mutex = new Mutex(true, MutexName, out created))
            {
                if (!created)
                {
                    MessageBox.Show("工具已经在后台运行。快速单独按两次 Ctrl 可打开历史。",
                        "历史粘贴板", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
                }

                try
                {
                    string data = Path.Combine(root, "data");
                    Directory.CreateDirectory(data);
                    string logPath = Path.Combine(data, "launch.log");
                    object logLock = new object();
                    using (StreamWriter log = new StreamWriter(logPath, false, new UTF8Encoding(false)))
                    using (Process child = new Process())
                    {
                        log.AutoFlush = true;
                        log.WriteLine(DateTime.Now.ToString("o") + " launcher start");
                        child.StartInfo = new ProcessStartInfo
                        {
                            FileName = powershell,
                            Arguments = "-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden " +
                                "-ExecutionPolicy Bypass -File \"" + Path.Combine(root, "clipboard-history.ps1") + "\"",
                            WorkingDirectory = root,
                            UseShellExecute = false,
                            CreateNoWindow = true,
                            RedirectStandardOutput = true,
                            RedirectStandardError = true
                        };
                        DataReceivedEventHandler write = delegate(object sender, DataReceivedEventArgs e)
                        {
                            if (e.Data != null)
                                lock (logLock) log.WriteLine(e.Data);
                        };
                        child.OutputDataReceived += write;
                        child.ErrorDataReceived += write;
                        child.Start();
                        child.BeginOutputReadLine();
                        child.BeginErrorReadLine();
                        child.WaitForExit();
                        if (child.ExitCode != 0)
                        {
                            MessageBox.Show("工具启动或运行失败。请查看日志：\n" + logPath,
                                "历史粘贴板", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                        return child.ExitCode;
                    }
                }
                finally
                {
                    mutex.ReleaseMutex();
                }
            }
        }
        catch (Exception error)
        {
            if (!checkOnly)
                MessageBox.Show(error.Message, "历史粘贴板", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
