using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace DoorbellApp.Core
{
    /// <summary>
    /// Persists why the H.264 (MediaElement fMP4) path did or did not come up, so a panel that
    /// "stays on MJPEG" leaves evidence. MediaElement.MediaFailed used to go to Debug.WriteLine
    /// only, which is lost on a kiosk. Lines go to video.log in the data directory (bounded), and
    /// the last outcome is published through the runtime status for remote inspection.
    /// </summary>
    internal static class VideoDiagnostics
    {
        private const string LogName = "video.log";
        private const long MaxLogBytes = 512 * 1024;
        private const int MaxReasonChars = 512;

        private static readonly object Gate = new object();
        private static int _attempts;
        private static int _failures;
        private static int _successes;
        private static string _lastOutcome = "";
        private static string _lastReason = "";
        private static string _lastUrl = "";
        private static long _lastAtMs;

        public static string LogPath
        {
            get
            {
                string dir = App.DataDir;
                return string.IsNullOrEmpty(dir) ? "" : Path.Combine(dir, LogName);
            }
        }

        public static void RecordAttempt(string surface, string url)
        {
            lock (Gate)
            {
                _attempts++;
                _lastUrl = url ?? "";
            }
            Append("attempt", surface, url, "");
        }

        public static void RecordSuccess(string surface, string url)
        {
            lock (Gate)
            {
                _successes++;
                _lastOutcome = "opened";
                _lastReason = "";
                _lastUrl = url ?? "";
                _lastAtMs = NowMs();
            }
            Append("opened", surface, url, "");
        }

        public static void RecordFailure(string surface, string url, string reason, Exception error)
        {
            string detail = Describe(reason, error);
            lock (Gate)
            {
                _failures++;
                _lastOutcome = "failed";
                _lastReason = detail;
                _lastUrl = url ?? "";
                _lastAtMs = NowMs();
            }
            Append("failed", surface, url, detail);
        }

        /// <summary>Goes into runtime status under windows.h264_playback_diagnostics.</summary>
        public static Dictionary<string, object> Snapshot()
        {
            lock (Gate)
            {
                return new Dictionary<string, object>
                {
                    { "schema_version", 1 },
                    { "attempts", _attempts },
                    { "failures", _failures },
                    { "successes", _successes },
                    { "last_outcome", _lastOutcome },
                    { "last_reason", _lastReason },
                    { "last_url", _lastUrl },
                    { "last_at_ms", _lastAtMs },
                    { "log", LogPath },
                };
            }
        }

        internal static string Describe(string reason, Exception error)
        {
            var text = new StringBuilder(reason ?? "unknown");
            for (Exception e = error; e != null; e = e.InnerException)
            {
                text.Append(" | ").Append(e.GetType().Name);
                if (e.HResult != 0) text.Append(" 0x").Append(e.HResult.ToString("X8"));
                if (!string.IsNullOrEmpty(e.Message))
                    text.Append(' ').Append(e.Message.Replace('\r', ' ').Replace('\n', ' '));
            }
            string value = text.ToString();
            return value.Length > MaxReasonChars ? value.Substring(0, MaxReasonChars) : value;
        }

        private static long NowMs()
        {
            return (DateTime.UtcNow.Ticks - 621355968000000000L) / TimeSpan.TicksPerMillisecond;
        }

        private static void Append(string outcome, string surface, string url, string detail)
        {
            string path = LogPath;
            if (string.IsNullOrEmpty(path)) return;
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " h264 " + outcome +
                " surface=" + (surface ?? "") + " url=" + (url ?? "") +
                (string.IsNullOrEmpty(detail) ? "" : " reason=" + detail) + Environment.NewLine;
            try
            {
                lock (Gate)
                {
                    var info = new FileInfo(path);
                    if (info.Exists && info.Length > MaxLogBytes)
                    {
                        // Keep the newest half so the file stays bounded on a long-lived kiosk.
                        string tail = File.ReadAllText(path);
                        tail = tail.Substring(tail.Length / 2);
                        int cut = tail.IndexOf('\n');
                        if (cut >= 0) tail = tail.Substring(cut + 1);
                        File.WriteAllText(path, tail);
                    }
                    File.AppendAllText(path, line);
                }
            }
            catch
            {
                // Diagnostics must never take the panel down.
            }
        }
    }
}
