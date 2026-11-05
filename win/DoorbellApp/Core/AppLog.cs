using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace DoorbellApp.Core
{
    /// <summary>
    /// Rotating on-disk log for Core's log_line callback and the shell's own diagnostics, under
    /// &lt;data&gt;\logs. Release builds have no debugger listener, so Debug.WriteLine alone lost
    /// every Core line. Files rotate at 2 MiB, keeping three generations. Thread-safe; called
    /// from Core threads, so it never throws.
    /// </summary>
    internal static class AppLog
    {
        private const long MaxBytes = 2L * 1024 * 1024;
        private const int Generations = 3;
        private static readonly object Gate = new object();
        private static string _path;
        private static StreamWriter _writer;

        public static void Init(string dataDirectory)
        {
            lock (Gate)
            {
                try
                {
                    string directory = Path.Combine(dataDirectory, "logs");
                    Directory.CreateDirectory(directory);
                    _path = Path.Combine(directory, "doorbell.log");
                    OpenLocked();
                }
                catch (IOException) { _writer = null; }
                catch (UnauthorizedAccessException) { _writer = null; }
            }
        }

        public static void Write(string source, int level, string line)
        {
            string text = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + " " +
                          LevelName(level) + " [" + source + "] " + (line ?? "");
            Debug.WriteLine(text);
            lock (Gate)
            {
                if (_writer == null) return;
                try
                {
                    _writer.WriteLine(text);
                    if (_writer.BaseStream.Length >= MaxBytes) RotateLocked();
                }
                catch (IOException) { }
                catch (ObjectDisposedException) { _writer = null; }
            }
        }

        public static void Close()
        {
            lock (Gate)
            {
                try { _writer?.Dispose(); } catch (IOException) { }
                _writer = null;
            }
        }

        private static string LevelName(int level)
        {
            switch (level)
            {
                case 0: return "D";
                case 1: return "I";
                case 2: return "W";
                default: return "E";
            }
        }

        private static void OpenLocked()
        {
            var stream = new FileStream(_path, FileMode.Append, FileAccess.Write, FileShare.Read);
            _writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true };
        }

        private static void RotateLocked()
        {
            _writer.Dispose();
            _writer = null;
            for (int i = Generations - 1; i >= 1; i--)
            {
                string from = _path + (i == 1 ? "" : "." + (i - 1));
                string to = _path + "." + i;
                try
                {
                    if (File.Exists(to)) File.Delete(to);
                    if (File.Exists(from)) File.Move(from, to);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            OpenLocked();
        }
    }
}
