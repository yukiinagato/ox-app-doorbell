using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

namespace DoorbellApp.Core
{
    /// <summary>Synchronous HTTPS transport for db_platform_v2, pinned to TLS 1.2.</summary>
    internal static class WinHttpTransport
    {
        private const uint AccessDefaultProxy = 0;
        private const uint FlagSecure = 0x00800000;
        private const uint OptionSecureProtocols = 84;
        private const uint OptionRedirectPolicy = 88;
        private const uint RedirectNever = 0;
        private const uint SecureProtocolTls12 = 0x00000800;
        private const uint QueryStatusCode = 19;
        private const uint QueryFlagNumber = 0x20000000;
        private const int MaxResponseBytes = 16 * 1024 * 1024;

        [DllImport("winhttp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr WinHttpOpen(string userAgent, uint accessType,
            string proxyName, string proxyBypass, uint flags);

        [DllImport("winhttp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr WinHttpConnect(IntPtr session, string serverName,
            ushort serverPort, uint reserved);

        [DllImport("winhttp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr WinHttpOpenRequest(IntPtr connect, string verb,
            string objectName, string version, string referrer, IntPtr acceptTypes, uint flags);

        [DllImport("winhttp.dll", SetLastError = true)]
        private static extern bool WinHttpSetTimeouts(IntPtr handle, int resolveTimeout,
            int connectTimeout, int sendTimeout, int receiveTimeout);

        [DllImport("winhttp.dll", SetLastError = true)]
        private static extern bool WinHttpSetOption(IntPtr handle, uint option,
            ref uint buffer, uint bufferLength);

        [DllImport("winhttp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WinHttpAddRequestHeaders(IntPtr request, string headers,
            uint headersLength, uint modifiers);

        [DllImport("winhttp.dll", SetLastError = true)]
        private static extern bool WinHttpSendRequest(IntPtr request, IntPtr headers,
            uint headersLength, IntPtr optional, uint optionalLength, uint totalLength,
            IntPtr context);

        [DllImport("winhttp.dll", SetLastError = true)]
        private static extern bool WinHttpReceiveResponse(IntPtr request, IntPtr reserved);

        [DllImport("winhttp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WinHttpQueryHeaders(IntPtr request, uint infoLevel,
            string name, IntPtr buffer, ref uint bufferLength, IntPtr index);

        [DllImport("winhttp.dll", SetLastError = true)]
        private static extern bool WinHttpQueryDataAvailable(IntPtr request, out uint available);

        [DllImport("winhttp.dll", SetLastError = true)]
        private static extern bool WinHttpReadData(IntPtr request, byte[] buffer,
            uint bytesToRead, out uint bytesRead);

        [DllImport("winhttp.dll", SetLastError = true)]
        private static extern bool WinHttpCloseHandle(IntPtr handle);

        public static int Request(string method, string url, string headersJson, IntPtr body,
                                  UIntPtr bodyLength, out byte[] response, out int status)
        {
            response = null;
            status = 0;
            IntPtr session = IntPtr.Zero, connect = IntPtr.Zero, request = IntPtr.Zero;
            try
            {
                Uri uri;
                if (!Uri.TryCreate(url, UriKind.Absolute, out uri) ||
                    !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                    string.IsNullOrEmpty(uri.Host)) return -1;
                method = (method ?? "GET").ToUpperInvariant();
                if (!IsToken(method)) return -1;
                ulong bodySize64 = bodyLength.ToUInt64();
                if (bodySize64 > uint.MaxValue || (bodySize64 != 0 && body == IntPtr.Zero)) return -1;
                uint bodySize = (uint)bodySize64;

                session = WinHttpOpen("DoorbellApp/1 db-platform-v2", AccessDefaultProxy,
                                      null, null, 0);
                if (session == IntPtr.Zero) return -1;
                uint tls = SecureProtocolTls12;
                if (!WinHttpSetOption(session, OptionSecureProtocols, ref tls, sizeof(uint))) return -1;
                WinHttpSetTimeouts(session, 10000, 10000, 30000, 45000);

                connect = WinHttpConnect(session, uri.IdnHost, checked((ushort)uri.Port), 0);
                if (connect == IntPtr.Zero) return -1;
                string resource = string.IsNullOrEmpty(uri.PathAndQuery) ? "/" : uri.PathAndQuery;
                request = WinHttpOpenRequest(connect, method, resource, null, null,
                                             IntPtr.Zero, FlagSecure);
                if (request == IntPtr.Zero) return -1;
                uint redirect = RedirectNever; // never allow an HTTPS request to downgrade on redirect
                if (!WinHttpSetOption(request, OptionRedirectPolicy, ref redirect, sizeof(uint)))
                    return -1;
                if (!AddHeaders(request, headersJson)) return -1;
                if (!WinHttpSendRequest(request, IntPtr.Zero, 0, body, bodySize, bodySize,
                                        IntPtr.Zero)) return -1;
                if (!WinHttpReceiveResponse(request, IntPtr.Zero)) return -1;

                uint statusValue = 0, statusSize = sizeof(uint);
                IntPtr statusBuffer = Marshal.AllocHGlobal(sizeof(uint));
                try
                {
                    if (!WinHttpQueryHeaders(request, QueryStatusCode | QueryFlagNumber, null,
                                             statusBuffer, ref statusSize, IntPtr.Zero)) return -1;
                    statusValue = unchecked((uint)Marshal.ReadInt32(statusBuffer));
                }
                finally { Marshal.FreeHGlobal(statusBuffer); }
                status = unchecked((int)statusValue);

                using (var output = new MemoryStream())
                {
                    for (;;)
                    {
                        uint available;
                        if (!WinHttpQueryDataAvailable(request, out available)) return -1;
                        if (available == 0) break;
                        if (available > MaxResponseBytes || output.Length + available > MaxResponseBytes)
                            return -1;
                        byte[] chunk = new byte[available];
                        uint read;
                        if (!WinHttpReadData(request, chunk, available, out read)) return -1;
                        if (read == 0) break;
                        output.Write(chunk, 0, checked((int)read));
                    }
                    response = output.ToArray();
                }
                return 0; // HTTP 4xx/5xx are valid transport responses
            }
            catch (Exception ex) when (ex is ArgumentException || ex is OverflowException ||
                                       ex is IOException || ex is OutOfMemoryException)
            {
                response = null;
                status = 0;
                return -1;
            }
            finally
            {
                if (request != IntPtr.Zero) WinHttpCloseHandle(request);
                if (connect != IntPtr.Zero) WinHttpCloseHandle(connect);
                if (session != IntPtr.Zero) WinHttpCloseHandle(session);
            }
        }

        private static bool AddHeaders(IntPtr request, string headersJson)
        {
            if (string.IsNullOrWhiteSpace(headersJson)) return true;
            Dictionary<string, object> headers;
            try { headers = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(headersJson); }
            catch { return false; }
            if (headers == null) return false;
            foreach (var pair in headers)
            {
                string value = pair.Value == null ? "" : pair.Value.ToString();
                if (!IsHeaderName(pair.Key) || value.IndexOfAny(new[] { '\r', '\n' }) >= 0)
                    return false;
                string line = pair.Key + ": " + value + "\r\n";
                if (!WinHttpAddRequestHeaders(request, line, checked((uint)line.Length), 0x20000000))
                    return false; // WINHTTP_ADDREQ_FLAG_ADD
            }
            return true;
        }

        private static bool IsToken(string value)
        {
            if (string.IsNullOrEmpty(value)) return false;
            foreach (char c in value)
                if (!(c >= 'A' && c <= 'Z')) return false;
            return true;
        }

        private static bool IsHeaderName(string value)
        {
            if (string.IsNullOrEmpty(value)) return false;
            foreach (char c in value)
            {
                bool ok = char.IsLetterOrDigit(c) || c == '-' || c == '_';
                if (!ok) return false;
            }
            return true;
        }
    }
}
