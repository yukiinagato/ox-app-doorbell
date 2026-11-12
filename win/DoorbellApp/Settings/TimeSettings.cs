using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace DoorbellApp.Settings
{
    /// <summary>
    /// Time settings that need no window: the zones Core can resolve and the NTP server list
    /// rule. It has no WPF dependency so both are tested on the build host.
    /// </summary>
    internal static class TimeSettings
    {
        /// <summary>
        /// Core's bundled zone table (core/src/util/tz.cpp), in table order. Core rejects any
        /// other value for time.zone, so a zone offered here that Core does not know would be a
        /// choice that cannot be saved; a contract test keeps the two lists identical.
        /// </summary>
        public static readonly string[] Zones =
        {
            "UTC", "Asia/Tokyo", "Asia/Seoul", "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Macau",
            "Asia/Taipei", "Asia/Manila", "Asia/Singapore", "Asia/Kuala_Lumpur",
            "Asia/Vladivostok", "Asia/Bangkok", "Asia/Jakarta", "Asia/Ho_Chi_Minh", "Asia/Yangon",
            "Asia/Dhaka", "Asia/Kathmandu", "Asia/Kolkata", "Asia/Colombo", "Asia/Karachi",
            "Asia/Tashkent", "Asia/Almaty", "Asia/Dubai", "Asia/Baku", "Asia/Tehran",
            "Asia/Baghdad", "Asia/Qatar", "Asia/Riyadh", "Asia/Jerusalem", "Europe/London",
            "Europe/Dublin", "Europe/Lisbon", "Europe/Madrid", "Europe/Paris", "Europe/Brussels",
            "Europe/Amsterdam", "Europe/Berlin", "Europe/Zurich", "Europe/Vienna", "Europe/Rome",
            "Europe/Prague", "Europe/Warsaw", "Europe/Budapest", "Europe/Stockholm", "Europe/Oslo",
            "Europe/Copenhagen", "Europe/Helsinki", "Europe/Athens", "Europe/Bucharest",
            "Europe/Sofia", "Europe/Kyiv", "Europe/Riga", "Europe/Tallinn", "Europe/Vilnius",
            "Europe/Istanbul", "Europe/Minsk", "Europe/Moscow", "America/St_Johns",
            "America/Halifax", "America/New_York", "America/Toronto", "America/Panama",
            "America/Bogota", "America/Lima", "America/Chicago", "America/Winnipeg",
            "America/Mexico_City", "America/Denver", "America/Edmonton", "America/Phoenix",
            "America/Los_Angeles", "America/Vancouver", "America/Anchorage", "America/Caracas",
            "America/Santiago", "America/Sao_Paulo", "America/Montevideo",
            "America/Argentina/Buenos_Aires", "Australia/Perth", "Australia/Darwin",
            "Australia/Adelaide", "Australia/Brisbane", "Australia/Sydney", "Australia/Melbourne",
            "Australia/Hobart", "Pacific/Port_Moresby", "Pacific/Guam", "Pacific/Auckland",
            "Pacific/Fiji", "Pacific/Honolulu", "Africa/Accra", "Africa/Casablanca",
            "Africa/Lagos", "Africa/Johannesburg", "Africa/Nairobi", "Atlantic/Reykjavik",
            "Atlantic/Azores",
        };

        public const int MaxServers = 4;
        private static readonly Regex ServerPattern = new Regex("^[A-Za-z0-9._:-]+$");
        private static readonly Regex PortPattern = new Regex("^[0-9]{1,5}$");
        private static readonly Regex BracketedPattern =
            new Regex(@"^\[[0-9a-fA-F:]+\](:[0-9]{1,5})?$");

        /// <summary>
        /// Splits a comma- or whitespace-separated list of NTP servers and validates each entry
        /// the way the web Admin does: a host name or address, optionally with a port from 1 to
        /// 65535, or a bracketed IPv6 literal; one to four entries. Returns null when the list
        /// is empty, too long, or any entry is not acceptable.
        /// </summary>
        public static List<string> ParseNtpServers(string text)
        {
            var servers = new List<string>();
            foreach (string raw in (text ?? "").Split(
                         new[] { ',', ' ', '\t', '\r', '\n' },
                         System.StringSplitOptions.RemoveEmptyEntries))
            {
                string entry = raw.Trim();
                if (entry.Length == 0) continue;
                bool bracketed = BracketedPattern.IsMatch(entry);
                if (entry.Length > 253 || (!bracketed && !ServerPattern.IsMatch(entry))) return null;
                int colon = entry.LastIndexOf(':');
                // One colon separates a port; several mean an IPv6 literal, taken as it is.
                if (!bracketed && colon > 0 && entry.IndexOf(':') == colon)
                {
                    string port = entry.Substring(colon + 1);
                    int number;
                    if (!PortPattern.IsMatch(port) || !int.TryParse(port, out number) ||
                        number < 1 || number > 65535) return null;
                }
                if (!servers.Contains(entry)) servers.Add(entry);
            }
            return servers.Count == 0 || servers.Count > MaxServers ? null : servers;
        }
    }
}
