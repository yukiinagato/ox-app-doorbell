using System;
using System.IO;
using System.Net;

namespace DoorbellApp.Core
{
    /// <summary>
    /// HTTP requests to this device's own Core for media (security protocol v3, section 8). The
    /// shell never fetches another node directly: Core publishes peer media as loopback proxy
    /// URLs (/media/peer/&lt;id&gt;/...), and every loopback media request carries
    /// X-Doorbell-Local with the token from db_core_local_token. A URL that is not loopback (an
    /// explicitly configured external camera) is fetched without the token.
    /// </summary>
    internal static class LocalMedia
    {
        public const string TokenHeader = "X-Doorbell-Local";

        public static HttpWebRequest Create(string url, int timeoutMs, int readWriteTimeoutMs)
        {
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Timeout = timeoutMs;
            request.ReadWriteTimeout = readWriteTimeoutMs;
            // A redirect would carry the token to wherever it points.
            request.AllowAutoRedirect = false;
            request.KeepAlive = true;
            if (request.RequestUri.IsLoopback)
            {
                string token = App.Core == null ? null : App.Core.LocalToken;
                if (!string.IsNullOrEmpty(token)) request.Headers[TokenHeader] = token;
            }
            return request;
        }

        /// <summary>
        /// The same media source's sibling endpoint: .../stream.mp4 -> .../video-meta. Peer media
        /// lives below /media/peer/&lt;id&gt;/, so only the last path segment is replaced.
        /// </summary>
        public static string Sibling(string url, string leaf)
        {
            Uri uri;
            if (string.IsNullOrEmpty(url) || !Uri.TryCreate(url, UriKind.Absolute, out uri))
                return null;
            string path = uri.AbsolutePath;
            int slash = path.LastIndexOf('/');
            if (slash < 0) return null;
            return new UriBuilder(uri) { Path = path.Substring(0, slash + 1) + leaf, Query = "" }
                .Uri.ToString();
        }

        /// <summary>One bounded GET. Returns null on any transport or HTTP failure.</summary>
        public static byte[] Download(string url, int timeoutMs, int maxBytes)
        {
            try
            {
                var request = Create(url, timeoutMs, timeoutMs);
                using (var response = (HttpWebResponse)request.GetResponse())
                using (var stream = response.GetResponseStream())
                using (var buffer = new MemoryStream())
                {
                    if (response.StatusCode != HttpStatusCode.OK || stream == null) return null;
                    var chunk = new byte[8192];
                    int read;
                    while ((read = stream.Read(chunk, 0, chunk.Length)) > 0)
                    {
                        if (buffer.Length + read > maxBytes) return null;
                        buffer.Write(chunk, 0, read);
                    }
                    return buffer.ToArray();
                }
            }
            catch (WebException ex)
            {
                (ex.Response as HttpWebResponse)?.Close();
                return null;
            }
            catch (IOException) { return null; }
            catch (NotSupportedException) { return null; }
            catch (UriFormatException) { return null; }
        }
    }
}
