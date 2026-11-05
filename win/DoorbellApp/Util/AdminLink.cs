using System;
using System.Collections.Generic;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace DoorbellApp.Util
{
    /// <summary>
    /// Builds the address of this node's own web admin for another device to open. Since
    /// security protocol v3 Core serves Admin to the LAN only over TLS (plain HTTP answers 308),
    /// so the address is https://&lt;ip&gt;:&lt;https_port&gt;/admin/, port 47443 by default.
    /// </summary>
    internal static class AdminLink
    {
        public const int DefaultHttpsPort = 47443;

        /// <summary>The TLS listener port from boot.json (https_port), 47443 by default.</summary>
        public static int HttpsPort
        {
            get
            {
                int port = App.Boot == null ? 0 : App.Boot.HttpsPort;
                return port > 0 && port < 65536 ? port : DefaultHttpsPort;
            }
        }

        public static string Url(string host, int port)
        {
            if (string.IsNullOrEmpty(host)) return "";
            int effective = port > 0 && port < 65536 ? port : DefaultHttpsPort;
            return "https://" + host + ":" + effective + "/admin/";
        }

        /// <summary>
        /// Reachable IPv4 addresses of this machine, the interface holding the default gateway
        /// first. Loopback is never offered: the QR exists so another device can open the page.
        /// </summary>
        public static List<string> Hosts()
        {
            var gatewayHosts = new List<string>();
            var otherHosts = new List<string>();
            try
            {
                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != OperationalStatus.Up ||
                        nic.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                        nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                    IPInterfaceProperties properties = nic.GetIPProperties();
                    bool hasGateway = false;
                    foreach (GatewayIPAddressInformation gateway in properties.GatewayAddresses)
                        if (gateway.Address != null &&
                            gateway.Address.AddressFamily == AddressFamily.InterNetwork &&
                            !gateway.Address.Equals(System.Net.IPAddress.Any))
                            hasGateway = true;
                    foreach (UnicastIPAddressInformation unicast in properties.UnicastAddresses)
                    {
                        if (unicast.Address == null ||
                            unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        string text = unicast.Address.ToString();
                        if (text.StartsWith("127.", StringComparison.Ordinal) ||
                            text.StartsWith("169.254.", StringComparison.Ordinal)) continue;
                        if (hasGateway)
                        {
                            if (!gatewayHosts.Contains(text)) gatewayHosts.Add(text);
                        }
                        else if (!otherHosts.Contains(text))
                        {
                            otherHosts.Add(text);
                        }
                    }
                }
            }
            catch (NetworkInformationException) { }
            catch (PlatformNotSupportedException) { }
            foreach (string host in otherHosts)
                if (!gatewayHosts.Contains(host)) gatewayHosts.Add(host);
            return gatewayHosts;
        }

        /// <summary>The address to show by default, or an empty string when there is none.</summary>
        public static string PrimaryUrl()
        {
            return PrimaryUrl(HttpsPort);
        }

        public static string PrimaryUrl(int port)
        {
            List<string> hosts = Hosts();
            return hosts.Count == 0 ? "" : Url(hosts[0], port);
        }
    }
}
