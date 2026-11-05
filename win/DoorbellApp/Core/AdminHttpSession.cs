using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace DoorbellApp.Core
{
    /// <summary>
    /// The administrator session that a few Core services require in addition to the native
    /// admin window: configuration import, panel identities, secret provisioning and cluster
    /// rebuild. The shell logs in to its own Core over loopback HTTP (Core never redirects
    /// loopback to HTTPS) with the password the operator typed, keeps only the session cookie and
    /// CSRF value in memory, and drops them when settings close. The password is never stored.
    /// </summary>
    internal static class AdminHttpSession
    {
        public sealed class Tokens
        {
            public string Session;
            public string Csrf;
        }

        private static readonly object Gate = new object();
        private static Tokens _tokens;
        private static ManualResetEvent _pending;

        /// <summary>Asks the operator for the administrator password; null when cancelled.</summary>
        public static Func<string> PasswordPrompt;

        public static bool HasSession
        {
            get { lock (Gate) return _tokens != null; }
        }

        public static int Port
        {
            get { return App.Boot != null && App.Boot.HttpPort > 0 ? App.Boot.HttpPort : 47180; }
        }

        /// <summary>
        /// Starts a background login with a password that was just verified natively, so the
        /// first session-bound action does not ask again.
        /// </summary>
        public static void BeginLogin(string password)
        {
            if (string.IsNullOrEmpty(password)) return;
            var done = new ManualResetEvent(false);
            lock (Gate) _pending = done;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                string error;
                try { Login(password, out error); }
                finally { done.Set(); }
            });
        }

        /// <summary>The current session, logging in (with one password prompt) when needed.</summary>
        public static Tokens Ensure()
        {
            ManualResetEvent pending;
            lock (Gate)
            {
                if (_tokens != null) return _tokens;
                pending = _pending;
            }
            if (pending != null) pending.WaitOne(TimeSpan.FromSeconds(15));
            lock (Gate) if (_tokens != null) return _tokens;
            Func<string> prompt = PasswordPrompt;
            string password = prompt == null ? null : prompt();
            if (string.IsNullOrEmpty(password)) return null;
            string ignored;
            return Login(password, out ignored) ? _tokens : null;
        }

        public static void Clear()
        {
            lock (Gate)
            {
                _tokens = null;
                _pending = null;
            }
        }

        public static bool Login(string password, out string error)
        {
            error = null;
            int status;
            string setCookie;
            string body = new JavaScriptSerializer().Serialize(
                new Dictionary<string, object> { { "password", password } });
            string text = Send("POST", "/api/login", body, null, out status, out setCookie);
            if (status != 200 || text == null)
            {
                error = status == 429 ? "locked" : status == 0 ? "core_unavailable" : "rejected";
                return false;
            }
            string csrf = null;
            try
            {
                var doc = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(text);
                object value;
                if (doc != null && doc.TryGetValue("csrf_token", out value) && value != null)
                    csrf = value.ToString();
            }
            catch { }
            string session = CookieValue(setCookie, "dbsess");
            if (string.IsNullOrEmpty(csrf) || string.IsNullOrEmpty(session))
            {
                error = "rejected";
                return false;
            }
            lock (Gate) _tokens = new Tokens { Session = session, Csrf = csrf };
            return true;
        }

        /// <summary>
        /// An authenticated loopback request. Returns the body (or null) and the HTTP status; a
        /// 401/403 drops the session and is retried once after logging in again.
        /// </summary>
        public static string Request(string method, string path, string body, out int status)
        {
            status = 0;
            for (int attempt = 0; attempt < 2; attempt++)
            {
                Tokens tokens = Ensure();
                if (tokens == null) return null;
                string ignored;
                string text = Send(method, path, body, tokens, out status, out ignored);
                if (status != 401 && status != 403) return text;
                Clear();
            }
            return null;
        }

        private static string Send(string method, string path, string body, Tokens tokens,
                                   out int status, out string setCookie)
        {
            status = 0;
            setCookie = null;
            try
            {
                string origin = "http://127.0.0.1:" + Port;
                // Same loopback request rules as media: no redirects, local token attached.
                HttpWebRequest request = LocalMedia.Create(origin + path, 20000, 20000);
                request.Method = method;
                request.Proxy = null;
                request.Accept = "application/json";
                request.Headers["Origin"] = origin;
                if (tokens != null)
                {
                    request.Headers["Cookie"] = "dbsess=" + tokens.Session;
                    request.Headers["X-Doorbell-CSRF"] = tokens.Csrf;
                }
                if (body != null)
                {
                    byte[] bytes = Encoding.UTF8.GetBytes(body);
                    request.ContentType = "application/json";
                    request.ContentLength = bytes.Length;
                    using (Stream stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
                }
                HttpWebResponse response;
                try { response = (HttpWebResponse)request.GetResponse(); }
                catch (WebException ex)
                {
                    response = ex.Response as HttpWebResponse;
                    if (response == null) return null;
                }
                using (response)
                {
                    status = (int)response.StatusCode;
                    setCookie = response.Headers["Set-Cookie"];
                    using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                        return reader.ReadToEnd();
                }
            }
            catch (Exception ex)
            {
                AppLog.Write("admin", 2, "loopback admin request failed: " + ex.GetType().Name);
                return null;
            }
        }

        private static string CookieValue(string header, string name)
        {
            if (string.IsNullOrEmpty(header)) return null;
            foreach (string part in header.Split(';', ','))
            {
                string item = part.Trim();
                if (item.StartsWith(name + "=", StringComparison.Ordinal))
                    return item.Substring(name.Length + 1);
            }
            return null;
        }
    }
}
