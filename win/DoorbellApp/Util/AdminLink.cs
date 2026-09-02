using System;
using System.Collections.Generic;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace DoorbellApp.Util
{
    /// <summary>
    /// Builds the address of this node's own web admin. Windows has no native settings screen
    /// (spec 0.1), so this URL plus its QR is the whole entry point.
    /// </summary>
    internal static class AdminLink
    {
        public static string Url(string host, int port)
        {
            if (string.IsNullOrEmpty(host)) return "";
            int effective = port > 0 && port < 65536 ? port : 47180;
            return "http://" + host + ":" + effective + "/admin/";
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
        public static string PrimaryUrl(int port)
        {
            List<string> hosts = Hosts();
            return hosts.Count == 0 ? "" : Url(hosts[0], port);
        }
    }
}
