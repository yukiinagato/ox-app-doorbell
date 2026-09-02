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

        /// <summary>
        /// db_platform_v2.power_state payload: {"battery_pct":-1..100,"charging":bool,
        /// "mains":bool}. A desktop without a battery reports -1 and shells hide the indicator.
        /// </summary>
        public static Dictionary<string, object> PowerState()
        {
            int percent = -1;
            bool charging = false;
            bool mains = false;
            SystemPowerStatus status;
            if (GetSystemPowerStatus(out status))
            {
                mains = status.ACLineStatus == 1;
                // BatteryFlag bit 7 (128) means "no system battery"; 255 means unknown.
                bool hasBattery = status.BatteryFlag != 255 && (status.BatteryFlag & 128) == 0;
                if (hasBattery && status.BatteryLifePercent <= 100)
                    percent = status.BatteryLifePercent;
                // Bit 3 (8) is the charging flag; only a real battery can be charging.
                charging = hasBattery && (status.BatteryFlag & 8) != 0;
            }
            return new Dictionary<string, object>
            {
                { "battery_pct", percent },
                { "charging", charging },
                { "mains", mains },
            };
        }

        public static string PowerStateJson() =>
            new JavaScriptSerializer().Serialize(PowerState());
    }
}
