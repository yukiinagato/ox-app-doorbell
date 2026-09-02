using System;
using System.Collections.Generic;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;

namespace DoorbellApp.Core
{
    internal static class DeviceInfoProvider
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SystemPowerStatus
        {
            public byte ACLineStatus;
            public byte BatteryFlag;
            public byte BatteryLifePercent;
            public byte Reserved;
            public uint BatteryLifeTime;
            public uint BatteryFullLifeTime;
        }

        [DllImport("kernel32.dll")]
        private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

        public static Dictionary<string, object> Snapshot()
        {
            var root = new Dictionary<string, object>
            {
                { "schema_version", 1 },
                { "platform", "windows" },
                { "machine", Environment.MachineName },
            };
            NetworkInterface selected = null;
            try
            {
                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != OperationalStatus.Up ||
                        nic.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                        nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                    var properties = nic.GetIPProperties();
                    string gateway = null;
                    foreach (var candidate in properties.GatewayAddresses)
                        if (candidate.Address != null && candidate.Address.AddressFamily == AddressFamily.InterNetwork)
                        { gateway = candidate.Address.ToString(); break; }
                    if (selected == null) selected = nic;
                    if (!string.IsNullOrEmpty(gateway))
                    {
                        selected = nic;
                        root["gateway"] = gateway;
                        break;
                    }
                }
                if (selected != null)
                {
                    root["network"] = new Dictionary<string, object>
                    {
                        { "interface", selected.Name },
                        { "description", selected.Description },
                        { "type", selected.NetworkInterfaceType.ToString().ToLowerInvariant() },
                        { "speed_bps", selected.Speed },
                    };
                    if (selected.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
                        root["wifi"] = new Dictionary<string, object> { { "interface", selected.Name } };
                }
            }
            catch (NetworkInformationException) { }
            catch (PlatformNotSupportedException) { }

            SystemPowerStatus power;
            if (GetSystemPowerStatus(out power))
            {
                string state = power.ACLineStatus == 1 ?
                    (power.BatteryLifePercent >= 100 ? "full" : "charging") : "unplugged";
                var battery = new Dictionary<string, object> { { "state", state } };
                if (power.BatteryLifePercent <= 100)
                    battery["level"] = power.BatteryLifePercent / 100.0;
                root["battery"] = battery;
                root["mains_power"] = power.ACLineStatus == 1;
            }
            return root;
        }

        public static string SnapshotJson() =>
            new JavaScriptSerializer().Serialize(Snapshot());

        public static bool IsOnMainsPower()
        {
            SystemPowerStatus status;
            return GetSystemPowerStatus(out status) && status.ACLineStatus == 1;
        }
    }
}
