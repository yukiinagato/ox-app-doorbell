using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Windows.Media.Imaging;

namespace DoorbellApp.Core
{
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
                        DateTime nextDecode = DateTime.MinValue;
                        while (_running)
                        {
                            int rotation;
                            byte[] frame = ReadPart(ins, out rotation);
                            if (frame == null) break;
                            if (_lowResource && DateTime.UtcNow < nextDecode) continue;
                            if (_lowResource)
                                nextDecode = DateTime.UtcNow.AddMilliseconds(250);
                            var bmp = Decode(frame, _lowResource ? 640 : 0);
                            if (bmp != null && _running) _onFrame(bmp, rotation);
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

        private static byte[] ReadPart(Stream ins, out int rotation)
        {
            int contentLength = -1;
            rotation = 0;
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
