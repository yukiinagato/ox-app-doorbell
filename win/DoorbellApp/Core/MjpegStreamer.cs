// MJPEG (multipart/x-mixed-replace) の自前デコーダ — Android 版 MjpegStreamer.kt の C# 移植。
// 子機 httpd の /stream.mjpeg はパート毎に Content-Length を必ず付ける (httpd.cpp) ので
// ヘッダの Content-Length を読んで本文をそのまま切り出す。
// 接続断は 2 秒後に自動再接続 (Stop まで)。コールバックは読取スレッドから呼ばれる —
// BitmapImage は Freeze 済みなので受け側は Dispatcher へ渡すだけでよい。
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Windows.Media.Imaging;

namespace DoorbellApp.Core
{
    public sealed class MjpegStreamer
    {
        private const int MaxFrame = 4 * 1024 * 1024;  // JPEG 1 枚の上限 (安全弁)

        private readonly string _url;
        private readonly Action<BitmapImage> _onFrame;
        private volatile bool _running;
        private Thread _thread;

        public MjpegStreamer(string url, Action<BitmapImage> onFrame)
        {
            _url = url;
            _onFrame = onFrame;
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
                    req.Timeout = 4000;           // 接続
                    req.ReadWriteTimeout = 10000; // フレーム間
                    using (var resp = req.GetResponse())
                    using (var raw = resp.GetResponseStream())
                    using (var ins = new BufferedStream(raw, 64 * 1024))
                    {
                        while (_running)
                        {
                            byte[] frame = ReadPart(ins);
                            if (frame == null) break;
                            var bmp = Decode(frame);
                            if (bmp != null && _running) _onFrame(bmp);
                        }
                    }
                }
                catch { /* 接続断/デコード失敗 → 下で再接続 */ }
                if (!_running) break;
                try { Thread.Sleep(2000); } catch (ThreadInterruptedException) { }
            }
        }

        /// <summary>JPEG bytes → Freeze 済み BitmapImage (別スレッド → UI スレッド渡し可)。</summary>
        public static BitmapImage Decode(byte[] jpeg)
        {
            try
            {
                var bmp = new BitmapImage();
                using (var ms = new MemoryStream(jpeg))
                {
                    bmp.BeginInit();
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.StreamSource = ms;
                    bmp.EndInit();
                }
                bmp.Freeze();
                return bmp;
            }
            catch { return null; }
        }

        /// <summary>1 パート読む: 境界/ヘッダ行 → Content-Length → JPEG 本文。終端は null。</summary>
        private static byte[] ReadPart(Stream ins)
        {
            int contentLength = -1;
            for (;;)
            {
                string line = ReadLine(ins);
                if (line == null) return null;
                if (line.Length == 0)
                {
                    if (contentLength > 0) break;
                    continue;  // 境界直後の余分な空行は読み飛ばす
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

        /// <summary>\r\n 終端の 1 行 (ASCII)。終端到達は null。</summary>
        private static string ReadLine(Stream ins)
        {
            var sb = new StringBuilder(64);
            for (;;)
            {
                int ch = ins.ReadByte();
                if (ch < 0) return null;
                if (ch == '\n') return sb.ToString().TrimEnd('\r');
                sb.Append((char)ch);
                if (sb.Length > 512) return null;  // 異常なヘッダ行
            }
        }
    }
}
