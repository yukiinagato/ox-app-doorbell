using System;
using System.Diagnostics;
using System.Net;
using System.Threading;

namespace DoorbellApp.Core
{
    /// <summary>
    /// Watches whether this node can actually serve camera frames, which is what caps.camera
    /// advertises to the rest of the cluster.
    ///
    /// Core owns the Media Foundation capture on Windows (core/src/media/camera_win.cpp) and
    /// republishes it on the local HTTP server, so the shell never opens the device a second time
    /// to find out. It asks the very endpoint an indoor panel's door tile fetches: /snapshot.jpg
    /// answers 200 with a JPEG once a device is bound and producing, and 503 "no frame" otherwise.
    /// Anything that would leave a panel showing a dead still therefore reads as no camera.
    ///
    /// The poll continues for the life of the process, so a device plugged in or pulled out at
    /// runtime flips the capability rather than stranding a tile that can never fill.
    /// </summary>
    internal sealed class CameraProbe : IDisposable
    {
        private const int IntervalMs = 15000;
        private const int RequestTimeoutMs = 2000;
        private const int Unknown = -1;
        private const int Absent = 0;
        private const int Present = 1;

        private readonly string _url;
        private readonly Action<bool> _onChanged;
        private readonly Timer _timer;
        private int _state = Unknown;
        private int _busy;

        public CameraProbe(int httpPort, Action<bool> onChanged)
        {
            int port = httpPort > 0 && httpPort < 65536 ? httpPort : 47180;
            _url = "http://127.0.0.1:" + port + "/snapshot.jpg";
            _onChanged = onChanged;
            _timer = new Timer(Poll, null, TimeSpan.Zero,
                               TimeSpan.FromMilliseconds(IntervalMs));
        }

        /// <summary>False until the first probe answers, so nothing is advertised on a guess.</summary>
        public bool Available { get { return Volatile.Read(ref _state) == Present; } }

        private void Poll(object state)
        {
            // A slow answer must not queue another probe behind it.
            if (Interlocked.Exchange(ref _busy, 1) == 1) return;
            try
            {
                int next = Probe() ? Present : Absent;
                if (Interlocked.Exchange(ref _state, next) == next) return;
                Action<bool> handler = _onChanged;
                if (handler != null) handler(next == Present);
            }
            catch (Exception ex)
            {
                Debug.WriteLine("camera probe failed: " + ex.Message);
            }
            finally
            {
                Volatile.Write(ref _busy, 0);
            }
        }

        private bool Probe()
        {
            try
            {
                var request = (HttpWebRequest)WebRequest.Create(_url);
                request.Method = "GET";
                request.Timeout = RequestTimeoutMs;
                request.ReadWriteTimeout = RequestTimeoutMs;
                request.AllowAutoRedirect = false;
                using (var response = (HttpWebResponse)request.GetResponse())
                    return response.StatusCode == HttpStatusCode.OK &&
                           response.ContentLength != 0;
            }
            catch (WebException ex)
            {
                // 503 "no frame" is core's answer while no capture device is producing; a refused
                // connection means the local server is not up yet. Both mean "cannot serve".
                var response = ex.Response as HttpWebResponse;
                if (response != null) response.Close();
                return false;
            }
            catch (NotSupportedException) { return false; }
            catch (UriFormatException) { return false; }
        }

        public void Dispose()
        {
            _timer.Dispose();
        }
    }
}
