using System;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DoorbellApp.Core;

namespace DoorbellApp.Pairing
{
    /// <summary>
    /// Camera source for the QR scanner. Core owns the Media Foundation capture on Windows
    /// (core/src/media/camera_win.cpp) and republishes it as the local MJPEG stream, so the shell
    /// reuses that stream instead of opening the device a second time: every frame is shown as the
    /// scanner preview and pushed back through db_core_on_camera_frame, which is the pipeline the
    /// core QR scanner reads. Frames are pushed at a low rate because core decodes at 10 fps.
    /// </summary>
    public sealed class PairingCameraFeed
    {
        private const int PushIntervalMs = 250;
        private const int PreviewWidth = 640;

        private readonly Dispatcher _dispatcher;
        private readonly Action<BitmapSource> _onPreview;
        private readonly Action<string> _onLocalDecode;
        private MjpegStreamer _streamer;
        private volatile bool _running;
        private long _nextPushMs;
        private long _frames;

        /// <param name="onLocalDecode">
        /// Optional redundant decode of the same frame through db_core_qr_decode, marshalled to
        /// the dispatcher. It is a backstop for a scan mode that never sees the frames; the caller
        /// suppresses it whenever core reports the same payload through qr_scanned first.
        /// </param>
        public PairingCameraFeed(Dispatcher dispatcher, Action<BitmapSource> onPreview,
                                 Action<string> onLocalDecode)
        {
            _dispatcher = dispatcher;
            _onPreview = onPreview;
            _onLocalDecode = onLocalDecode;
        }

        /// <summary>Number of frames seen so far; zero means no local camera is publishing.</summary>
        public long FrameCount { get { return System.Threading.Interlocked.Read(ref _frames); } }

        public static string LocalStreamUrl()
        {
            return "http://127.0.0.1:" + App.Boot.HttpPort + "/stream.mjpeg";
        }

        public void Start()
        {
            if (_running) return;
            _running = true;
            _nextPushMs = 0;
            _streamer = new MjpegStreamer(LocalStreamUrl(), OnFrame, true);
            _streamer.Start();
        }

        public void Stop()
        {
            _running = false;
            var streamer = _streamer;
            _streamer = null;
            if (streamer != null) streamer.Stop();
        }

        // Runs on the MJPEG reader thread. The frame is frozen, so it may be converted here and
        // handed to the dispatcher without copying again.
        private void OnFrame(BitmapImage frame, int rotation)
        {
            if (!_running || frame == null) return;
            System.Threading.Interlocked.Increment(ref _frames);
            var dispatcher = _dispatcher;
            if (dispatcher != null && _onPreview != null)
                dispatcher.BeginInvoke(DispatcherPriority.Background,
                    new Action(() => { if (_running) _onPreview(frame); }));

            long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            if (now < _nextPushMs) return;
            _nextPushMs = now + PushIntervalMs;
            try
            {
                int width, height;
                byte[] bgra = ToBgra(frame, out width, out height);
                if (bgra == null) return;
                App.Core.PushCameraFrame(bgra, 3, width, height, width * 4, now);
                if (_onLocalDecode == null || dispatcher == null) return;
                string text = CoreClient.QrDecodeGray(ToLuma(bgra, width, height), width, height);
                if (string.IsNullOrEmpty(text)) return;
                dispatcher.BeginInvoke(DispatcherPriority.Background,
                    new Action(() => { if (_running) _onLocalDecode(text); }));
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("qr frame conversion failed: " + ex.Message);
            }
        }

        /// <summary>Converts a decoded MJPEG frame into the BGRA layout core expects.</summary>
        public static byte[] ToBgra(BitmapSource source, out int width, out int height)
        {
            width = 0;
            height = 0;
            if (source == null) return null;
            BitmapSource frame = source;
            if (frame.PixelWidth > PreviewWidth)
            {
                double factor = (double)PreviewWidth / frame.PixelWidth;
                var scaled = new TransformedBitmap(frame, new ScaleTransform(factor, factor));
                scaled.Freeze();
                frame = scaled;
            }
            if (frame.Format != PixelFormats.Bgra32)
            {
                var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
                converted.Freeze();
                frame = converted;
            }
            width = frame.PixelWidth;
            height = frame.PixelHeight;
            if (width <= 0 || height <= 0) return null;
            int stride = width * 4;
            var buffer = new byte[stride * height];
            frame.CopyPixels(buffer, stride, 0);
            return buffer;
        }

        /// <summary>BGRA to 8-bit luma, for the synchronous db_core_qr_decode fallback.</summary>
        public static byte[] ToLuma(byte[] bgra, int width, int height)
        {
            if (bgra == null || width <= 0 || height <= 0 ||
                bgra.Length < width * height * 4) return null;
            var gray = new byte[width * height];
            for (int i = 0, j = 0; i < gray.Length; i++, j += 4)
                gray[i] = (byte)((bgra[j] * 29 + bgra[j + 1] * 150 + bgra[j + 2] * 77) >> 8);
            return gray;
        }
    }
}
