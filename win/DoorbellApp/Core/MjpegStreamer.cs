using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Windows.Media.Imaging;

namespace DoorbellApp.Core
{
    /// <summary>
    /// A read-only sample of the player's own counters. Latency uses the per-part
    /// X-Doorbell-Capture-Time-Ms header corrected by the response's X-Doorbell-Server-Time-Ms,
    /// so it does not depend on the two devices agreeing about the wall clock.
    /// </summary>
    public sealed class VideoStats
    {
        public string Codec = "";
        public int LatencyMs = -1;
        public int JitterMs = -1;
        public double Fps;
        public long Dropped;
        public bool HasFrames;
    }

    // Bounds on frame and header sizes limit untrusted multipart input. Frozen BitmapImage values
    // may be handed safely from the reader thread to the WPF dispatcher.
    public sealed class MjpegStreamer
    {
        private const int MaxFrame = 4 * 1024 * 1024;

        private readonly string _url;
        private readonly Action<BitmapImage, int> _onFrame;
        private readonly bool _lowResource;
        private volatile bool _running;
        private Thread _thread;
        private readonly object _statsLock = new object();
        private readonly double[] _intervals = new double[16];
        private int _intervalCount;
        private int _intervalNext;
        private long _decoded;
        private long _dropped;
        private int _latencyMs = -1;
        private DateTime _lastFrameAt = DateTime.MinValue;

        /// <summary>Human-facing label for the debug line: the strategy actually in use.</summary>
        public string Codec { get; set; }

        public MjpegStreamer(string url, Action<BitmapImage, int> onFrame,
                             bool lowResource = false)
        {
            _url = url;
            _onFrame = onFrame;
            _lowResource = lowResource;
        }

        public void Start()
        {
            if (_running) return;
            _running = true;
            _thread = new Thread(Loop) { IsBackground = true, Name = "mjpeg" };
            _thread.Start();
        }

        public void Stop()
        {
            _running = false;
            try { _thread?.Interrupt(); } catch { }
            _thread = null;
        }

        /// <summary>Snapshot of the counters. Safe to call from the dispatcher thread.</summary>
        public VideoStats Stats()
        {
            var stats = new VideoStats { Codec = Codec ?? "mjpeg" };
            lock (_statsLock)
            {
                stats.Dropped = _dropped;
                stats.LatencyMs = _latencyMs;
                stats.HasFrames = _decoded > 0;
                if (_intervalCount > 0)
                {
                    double sum = 0;
                    for (int i = 0; i < _intervalCount; i++) sum += _intervals[i];
                    double mean = sum / _intervalCount;
                    double deviation = 0;
                    for (int i = 0; i < _intervalCount; i++)
                        deviation += Math.Abs(_intervals[i] - mean);
                    stats.Fps = mean > 0.5 ? 1000.0 / mean : 0;
                    stats.JitterMs = (int)Math.Round(deviation / _intervalCount);
                }
            }
            return stats;
        }

        private void RecordFrame(long captureMs, long serverOffsetMs)
        {
            var now = DateTime.UtcNow;
            lock (_statsLock)
            {
                _decoded++;
                if (_lastFrameAt != DateTime.MinValue)
                {
                    double gap = (now - _lastFrameAt).TotalMilliseconds;
                    if (gap > 0 && gap < 10000)
                    {
                        _intervals[_intervalNext] = gap;
                        _intervalNext = (_intervalNext + 1) % _intervals.Length;
                        if (_intervalCount < _intervals.Length) _intervalCount++;
                    }
                }
                _lastFrameAt = now;
                if (captureMs > 0)
                {
                    long nowMs = (long)(now - new DateTime(1970, 1, 1, 0, 0, 0,
                                                            DateTimeKind.Utc)).TotalMilliseconds;
                    long latency = nowMs + serverOffsetMs - captureMs;
                    _latencyMs = latency < 0 ? 0 : (int)Math.Min(60000, latency);
                }
            }
        }

        private void RecordDrop()
        {
            lock (_statsLock) { _dropped++; }
        }

        private void Loop()
        {
            while (_running)
            {
                try
                {
                    var req = (HttpWebRequest)WebRequest.Create(_url);
                    req.Timeout = 4000;
                    req.ReadWriteTimeout = 10000;
                    using (var resp = req.GetResponse())
                    using (var raw = resp.GetResponseStream())
                    using (var ins = new BufferedStream(raw, 64 * 1024))
                    {
                        long serverOffsetMs = ServerOffsetMs(resp);
                        DateTime nextDecode = DateTime.MinValue;
                        while (_running)
                        {
                            int rotation;
                            long captureMs;
                            byte[] frame = ReadPart(ins, out rotation, out captureMs);
                            if (frame == null) break;
                            if (_lowResource && DateTime.UtcNow < nextDecode)
                            {
                                RecordDrop();
                                continue;
                            }
                            if (_lowResource)
                                nextDecode = DateTime.UtcNow.AddMilliseconds(250);
                            var bmp = Decode(frame, _lowResource ? 640 : 0);
                            if (bmp == null) { RecordDrop(); continue; }
                            RecordFrame(captureMs, serverOffsetMs);
                            if (_running) _onFrame(bmp, rotation);
                        }
                    }
                }
                catch {  }
                if (!_running) break;
                try { Thread.Sleep(2000); } catch (ThreadInterruptedException) { }
            }
        }

        public static BitmapImage Decode(byte[] jpeg)
        {
            return Decode(jpeg, 0);
        }

        public static BitmapImage Decode(byte[] jpeg, int maximumPixelWidth)
        {
            try
            {
                var bmp = new BitmapImage();
                using (var ms = new MemoryStream(jpeg))
                {
                    bmp.BeginInit();
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    if (maximumPixelWidth > 0) bmp.DecodePixelWidth = maximumPixelWidth;
                    bmp.StreamSource = ms;
                    bmp.EndInit();
                }
                bmp.Freeze();
                return bmp;
            }
            catch { return null; }
        }

        /// <summary>
        /// Difference between the door station's clock and this one, measured once per connection
        /// from the response header, so a per-frame capture timestamp becomes a local latency.
        /// </summary>
        private static long ServerOffsetMs(WebResponse response)
        {
            try
            {
                string raw = response.Headers == null ? null :
                    response.Headers["X-Doorbell-Server-Time-Ms"];
                long serverMs;
                if (string.IsNullOrEmpty(raw) || !long.TryParse(raw, out serverMs)) return 0;
                long nowMs = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0,
                                                                    DateTimeKind.Utc))
                    .TotalMilliseconds;
                long offset = serverMs - nowMs;
                return Math.Abs(offset) > 86400000L ? 0 : offset;
            }
            catch { return 0; }
        }

        private static byte[] ReadPart(Stream ins, out int rotation, out long captureMs)
        {
            int contentLength = -1;
            rotation = 0;
            captureMs = 0;
            for (;;)
            {
                string line = ReadLine(ins);
                if (line == null) return null;
                if (line.Length == 0)
                {
                    if (contentLength > 0) break;
                    continue;
                }
                int c = line.IndexOf(':');
                if (c > 0 && line.Substring(0, c).Trim()
                        .Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                {
                    int v;
                    if (!int.TryParse(line.Substring(c + 1).Trim(), out v) ||
                        v <= 0 || v > MaxFrame)
                        return null;
                    contentLength = v;
                }
                else if (c > 0 && line.Substring(0, c).Trim()
                         .Equals("X-Doorbell-Video-Rotation", StringComparison.OrdinalIgnoreCase))
                {
                    int.TryParse(line.Substring(c + 1).Trim(), out rotation);
                    rotation = ((rotation % 360) + 360) % 360;
                }
                else if (c > 0 && line.Substring(0, c).Trim()
                         .Equals("X-Doorbell-Capture-Time-Ms", StringComparison.OrdinalIgnoreCase))
                {
                    long value;
                    if (long.TryParse(line.Substring(c + 1).Trim(), out value) && value > 0)
                        captureMs = value;
                }
            }
            var buf = new byte[contentLength];
            int off = 0;
            while (off < contentLength)
            {
                int n = ins.Read(buf, off, contentLength - off);
                if (n <= 0) return null;
                off += n;
            }
            return buf;
        }

        private static string ReadLine(Stream ins)
        {
            var sb = new StringBuilder(64);
            for (;;)
            {
                int ch = ins.ReadByte();
                if (ch < 0) return null;
                if (ch == '\n') return sb.ToString().TrimEnd('\r');
                sb.Append((char)ch);
                if (sb.Length > 512) return null;
            }
        }
    }
}
