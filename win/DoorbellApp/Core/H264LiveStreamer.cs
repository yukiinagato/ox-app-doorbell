using System;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace DoorbellApp.Core
{
    /// <summary>
    /// Live fMP4/H.264 player that does not go through MediaElement. The shell downloads
    /// /stream.mp4 itself and hands the bytes to Core (db_h264_player_*), which demuxes them and
    /// decodes with the Media Foundation H.264 decoder in low-latency mode; decoded BGRA frames
    /// come back on a Core thread and are written into a WriteableBitmap on the dispatcher.
    /// MediaElement needed about 4.5 s to open the same stream on the Toughpad (WMP buffers a
    /// live progressive download before it reports MediaOpened); this path shows the first frame
    /// as soon as the first keyframe has been decoded.
    /// </summary>
    public sealed class H264LiveStreamer
    {
        private const int ReadChunk = 32 * 1024;
        private const int MaxReconnects = 3;

        private readonly string _url;
        private readonly string _metaUrl;
        private readonly Dispatcher _dispatcher;
        private readonly Action<WriteableBitmap, int> _onFrame;
        private readonly Action<string> _onFailed;
        private readonly object _gate = new object();
        private volatile bool _running;
        private Thread _thread;
        private IntPtr _player;
        private CoreInterop.H264FrameCb _frameCb;
        private CoreInterop.H264StateCb _stateCb;
        private WriteableBitmap _bitmap;
        private byte[] _pending;
        private int _pendingWidth, _pendingHeight, _pendingStride;
        private bool _blitScheduled;
        private volatile int _rotation;
        private long _serverOffsetMs;
        private string _decoderLabel = "";
        private string _lastState = "";

        private readonly object _statsLock = new object();
        private readonly double[] _intervals = new double[16];
        private int _intervalCount, _intervalNext;
        private long _decoded, _dropped;
        private int _latencyMs = -1;
        private int _firstFrameMs = -1;
        private DateTime _lastFrameAt = DateTime.MinValue;
        private DateTime _startedAt;

        /// <summary>True when the loaded Core exports the player (2026-09 or newer).</summary>
        public static bool Available
        {
            get
            {
                return CoreInterop.OptionalExport<CoreInterop.H264PlayerCreateFn>(
                           "db_h264_player_create") != null;
            }
        }

        public H264LiveStreamer(string url, Dispatcher dispatcher,
                                Action<WriteableBitmap, int> onFrame, Action<string> onFailed)
        {
            _url = url;
            _dispatcher = dispatcher;
            _onFrame = onFrame;
            _onFailed = onFailed;
            _metaUrl = MetaUrl(url);
        }

        public bool HasFrames { get { lock (_statsLock) { return _decoded > 0; } } }
        public string DecoderLabel { get { return _decoderLabel; } }
        public int FirstFrameMs { get { lock (_statsLock) { return _firstFrameMs; } } }

        public void Start()
        {
            if (_running) return;
            _running = true;
            _startedAt = DateTime.UtcNow;
            _thread = new Thread(Loop) { IsBackground = true, Name = "h264-live" };
            _thread.Start();
        }

        public void Stop()
        {
            _running = false;
            try { _thread?.Interrupt(); } catch { }
            _thread = null;
            DestroyPlayer();
        }

        public VideoStats Stats()
        {
            var stats = new VideoStats { Codec = "h264" };
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

        /// <summary>Core's own counters as JSON, for video.log; empty when unavailable.</summary>
        public string CoreStatsJson()
        {
            var fn = CoreInterop.OptionalExport<CoreInterop.H264PlayerStatsJsonFn>(
                "db_h264_player_stats_json");
            lock (_gate)
            {
                if (fn == null || _player == IntPtr.Zero) return "";
                return CoreInterop.TakeUtf8(fn(_player)) ?? "";
            }
        }

        private static string MetaUrl(string url)
        {
            try
            {
                var u = new Uri(url);
                return new UriBuilder(u) { Path = "/video-meta", Query = "" }.Uri.ToString();
            }
            catch { return null; }
        }

        private bool CreatePlayer()
        {
            var create = CoreInterop.OptionalExport<CoreInterop.H264PlayerCreateFn>(
                "db_h264_player_create");
            if (create == null) return false;
            // Keep the delegates referenced for as long as Core may call them.
            _frameCb = OnNativeFrame;
            _stateCb = OnNativeState;
            IntPtr player = create(_frameCb, _stateCb, IntPtr.Zero);
            if (player == IntPtr.Zero) return false;
            lock (_gate) { _player = player; }
            return true;
        }

        private void DestroyPlayer()
        {
            IntPtr player;
            lock (_gate)
            {
                player = _player;
                _player = IntPtr.Zero;
            }
            if (player == IntPtr.Zero) return;
            var destroy = CoreInterop.OptionalExport<CoreInterop.H264PlayerDestroyFn>(
                "db_h264_player_destroy");
            try { destroy?.Invoke(player); } catch { }
        }

        private void Loop()
        {
            int reconnects = 0;
            string lastError = "";
            while (_running)
            {
                if (!CreatePlayer())
                {
                    Fail("core has no h264 player");
                    return;
                }
                var feed = CoreInterop.OptionalExport<CoreInterop.H264PlayerFeedFn>(
                    "db_h264_player_feed");
                bool parseError = false;
                try
                {
                    var req = (HttpWebRequest)WebRequest.Create(_url);
                    req.Timeout = 4000;
                    req.ReadWriteTimeout = 10000;
                    using (var resp = req.GetResponse())
                    using (var stream = resp.GetResponseStream())
                    {
                        _serverOffsetMs = ServerOffsetMs(resp);
                        var buffer = new byte[ReadChunk];
                        DateTime nextMeta = DateTime.MinValue;
                        while (_running)
                        {
                            int n = stream.Read(buffer, 0, buffer.Length);
                            if (n <= 0) break;
                            int rc;
                            lock (_gate)
                            {
                                if (_player == IntPtr.Zero) break;
                                rc = feed(_player, buffer, (UIntPtr)n);
                            }
                            if (rc != 0)
                            {
                                parseError = true;
                                lastError = "feed rejected: " + _lastState;
                                break;
                            }
                            if (DateTime.UtcNow >= nextMeta)
                            {
                                // Off the feed thread: a slow /video-meta answer must not stall
                                // the bytes going into the decoder.
                                nextMeta = DateTime.UtcNow.AddMilliseconds(500);
                                ThreadPool.QueueUserWorkItem(_ => PollRotation());
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    lastError = ex.GetType().Name + " " + ex.Message;
                }
                DestroyPlayer();
                if (!_running) return;
                if (_lastState.StartsWith("error", StringComparison.Ordinal))
                {
                    Fail(_lastState);
                    return;
                }
                if (++reconnects > MaxReconnects)
                {
                    Fail(parseError ? "parse_error: " + lastError : "stream lost: " + lastError);
                    return;
                }
                try { Thread.Sleep(1000); } catch (ThreadInterruptedException) { }
            }
        }

        private void Fail(string reason)
        {
            _running = false;
            var onFailed = _onFailed;
            if (onFailed != null) _dispatcher.BeginInvoke(new Action(() => onFailed(reason)));
        }

        private void PollRotation()
        {
            if (string.IsNullOrEmpty(_metaUrl)) return;
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(_metaUrl);
                req.Timeout = 1500;
                using (var resp = req.GetResponse())
                using (var reader = new StreamReader(resp.GetResponseStream()))
                {
                    string text = reader.ReadToEnd();
                    int at = text.IndexOf("\"rotation\"", StringComparison.Ordinal);
                    if (at < 0) return;
                    int colon = text.IndexOf(':', at);
                    if (colon < 0) return;
                    int end = colon + 1;
                    while (end < text.Length && (char.IsDigit(text[end]) || text[end] == '-' ||
                                                 text[end] == ' ')) end++;
                    int degrees;
                    if (int.TryParse(text.Substring(colon + 1, end - colon - 1).Trim(),
                                     out degrees))
                        _rotation = ((degrees % 360) + 360) % 360;
                }
            }
            catch { }
        }

        private void OnNativeState(IntPtr user, IntPtr stateJsonUtf8)
        {
            string json = CoreInterop.ReadUtf8(stateJsonUtf8) ?? "";
            if (json.Contains("\"configured\""))
            {
                int at = json.IndexOf("\"decoder\":\"", StringComparison.Ordinal);
                if (at >= 0)
                {
                    int start = at + "\"decoder\":\"".Length;
                    int end = json.IndexOf('"', start);
                    if (end > start) _decoderLabel = json.Substring(start, end - start);
                }
                _lastState = "configured";
            }
            else if (json.Contains("\"first_frame\""))
            {
                _lastState = "first_frame";
            }
            else if (json.Contains("\"parse_error\""))
            {
                _lastState = "parse_error " + json;
            }
            else if (json.Contains("\"error\""))
            {
                _lastState = "error " + json;
            }
        }

        private void OnNativeFrame(IntPtr user, IntPtr bgra, int width, int height, int stride,
                                   long captureMs)
        {
            if (!_running || width <= 0 || height <= 0 || bgra == IntPtr.Zero) return;
            RecordFrame(captureMs);
            bool schedule;
            lock (_gate)
            {
                int bytes = stride * height;
                if (_pending == null || _pending.Length != bytes) _pending = new byte[bytes];
                Marshal.Copy(bgra, _pending, 0, bytes);
                _pendingWidth = width;
                _pendingHeight = height;
                _pendingStride = stride;
                schedule = !_blitScheduled;
                _blitScheduled = true;
            }
            // One blit per dispatcher turn: a frame that arrives while the previous one is still
            // queued simply replaces it, which keeps the picture live instead of building a
            // backlog on a slow panel.
            if (schedule) _dispatcher.BeginInvoke(new Action(Blit), DispatcherPriority.Render);
        }

        private void Blit()
        {
            byte[] pixels;
            int width, height, stride;
            lock (_gate)
            {
                _blitScheduled = false;
                if (_pending == null) return;
                pixels = _pending;
                width = _pendingWidth;
                height = _pendingHeight;
                stride = _pendingStride;
                // Swap to a fresh buffer so the decoder thread never writes into what WritePixels
                // reads from.
                _pending = new byte[pixels.Length];
            }
            if (!_running) return;
            if (_bitmap == null || _bitmap.PixelWidth != width || _bitmap.PixelHeight != height)
                _bitmap = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgra32, null);
            _bitmap.WritePixels(new Int32Rect(0, 0, width, height), pixels, stride, 0);
            _onFrame(_bitmap, _rotation);
        }

        private void RecordFrame(long captureMs)
        {
            var now = DateTime.UtcNow;
            lock (_statsLock)
            {
                _decoded++;
                if (_firstFrameMs < 0)
                    _firstFrameMs = (int)Math.Min(600000, (now - _startedAt).TotalMilliseconds);
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
                    long latency = nowMs + _serverOffsetMs - captureMs;
                    _latencyMs = latency < 0 ? 0 : (int)Math.Min(60000, latency);
                }
            }
        }

        private static long ServerOffsetMs(WebResponse response)
        {
            try
            {
                string raw = response.Headers == null ? null :
                    response.Headers["X-Doorbell-Server-Time-Ms"];
                long serverMs;
                if (string.IsNullOrEmpty(raw) || !long.TryParse(raw.Trim(), out serverMs)) return 0;
                long nowMs = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0,
                                                                   DateTimeKind.Utc)).TotalMilliseconds;
                long offset = serverMs - nowMs;
                return Math.Abs(offset) > 86400000L ? 0 : offset;
            }
            catch { return 0; }
        }
    }
}
