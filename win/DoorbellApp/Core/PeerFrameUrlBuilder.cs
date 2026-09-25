using System;

namespace DoorbellApp.Core
{
    public static class PeerFrameUrlBuilder
    {
        public static bool TryBuild(int httpPort, string identityQuery, out string url)
        {
            url = null;
            if (httpPort == 0) return false;
            if (httpPort < 1 || httpPort > 65535)
                throw new ArgumentOutOfRangeException("httpPort");
            string query = identityQuery ?? "";
            if (query.Length != 0 && query[0] != '?')
                throw new ArgumentException("Identity query must begin with ?", "identityQuery");
            url = "http://127.0.0.1:" + httpPort + "/peer-frame.jpg" + query;
            return true;
        }
    }
}
