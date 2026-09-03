using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;

namespace DoorbellApp.Core
{
    internal enum FirewallStatus { Allowed, RulesMissing, Unavailable }

    internal sealed class FirewallPorts
    {
        public readonly int MeshTcp;
        public readonly int AdminTcp;
        public readonly int DiscoveryUdp;
        public readonly int SipUdp;

        public FirewallPorts(int meshTcp, int adminTcp, int discoveryUdp, int sipUdp)
        {
            MeshTcp = Valid(meshTcp, 47172);
            AdminTcp = Valid(adminTcp, 47180);
            DiscoveryUdp = Valid(discoveryUdp, 47171);
            SipUdp = sipUdp == 0 ? 0 : Valid(sipUdp, 47190);
        }

        private static int Valid(int value, int fallback)
        {
            return value > 0 && value < 65536 ? value : fallback;
        }
    }

    /// <summary>
    /// Checks only inbound rules for this executable. Rule creation happens in a separately
    /// elevated instance, and only after the normal UI has obtained the operator's consent.
    /// </summary>
    internal static class WindowsFirewall
    {
        private const int DirectionIn = 1;
        private const int ActionAllow = 1;
        private const int ProtocolTcp = 6;
        private const int ProtocolUdp = 17;
        private const int ProtocolAny = 256;
        private const int AllProfiles = 0x7fffffff;
        private const string TcpRuleName = "Doorbell Cluster TCP";
        private const string UdpRuleName = "Doorbell Cluster UDP";

        public static bool IsRepairRequest(string[] args)
        {
            if (args == null) return false;
            foreach (string arg in args)
                if (arg == "--configure-firewall") return true;
            return false;
        }

        public static FirewallPorts PortsFromArguments(string[] args)
        {
            return new FirewallPorts(ArgumentPort(args, "--firewall-mesh=", 47172),
                ArgumentPort(args, "--firewall-admin=", 47180),
                ArgumentPort(args, "--firewall-discovery=", 47171),
                ArgumentPort(args, "--firewall-sip=", 0));
        }

        public static FirewallStatus Check(FirewallPorts ports)
        {
            string application = ExecutablePath();
            if (ports == null || string.IsNullOrEmpty(application)) return FirewallStatus.Unavailable;
            try
            {
                dynamic policy = CreatePolicy();
                if (policy == null) return FirewallStatus.Unavailable;
                int activeProfiles = ActiveFirewallProfiles(policy);
                // A disabled firewall cannot block the app, so no rule is needed for that profile.
                if (activeProfiles == 0) return FirewallStatus.Allowed;
                dynamic rules = policy.Rules;
                bool allowed = Allows(rules, application, ProtocolTcp, ports.MeshTcp, activeProfiles) &&
                    Allows(rules, application, ProtocolTcp, ports.AdminTcp, activeProfiles) &&
                    Allows(rules, application, ProtocolUdp, ports.DiscoveryUdp, activeProfiles) &&
                    (ports.SipUdp == 0 ||
                     Allows(rules, application, ProtocolUdp, ports.SipUdp, activeProfiles));
                return allowed ? FirewallStatus.Allowed : FirewallStatus.RulesMissing;
            }
            catch { return FirewallStatus.Unavailable; }
        }

        /// <summary>Runs in the short-lived child process launched with the UAC verb.</summary>
        public static bool Configure(FirewallPorts ports)
        {
            if (ports == null || !IsAdministrator()) return false;
            string application = ExecutablePath();
            if (string.IsNullOrEmpty(application)) return false;
            try
            {
                dynamic policy = CreatePolicy();
                if (policy == null) return false;
                int activeProfiles = ActiveFirewallProfiles(policy);
                if (activeProfiles == 0) return true;
                dynamic rules = policy.Rules;
                if (!Allows(rules, application, ProtocolTcp, ports.MeshTcp, activeProfiles) ||
                    !Allows(rules, application, ProtocolTcp, ports.AdminTcp, activeProfiles))
                    AddRule(rules, TcpRuleName, application, ProtocolTcp,
                        ports.MeshTcp + "," + ports.AdminTcp);
                if (!Allows(rules, application, ProtocolUdp, ports.DiscoveryUdp, activeProfiles) ||
                    (ports.SipUdp != 0 &&
                     !Allows(rules, application, ProtocolUdp, ports.SipUdp, activeProfiles)))
                    AddRule(rules, UdpRuleName, application, ProtocolUdp,
                        ports.SipUdp == 0 ? ports.DiscoveryUdp.ToString() :
                                            ports.DiscoveryUdp + "," + ports.SipUdp);
                return Check(ports) == FirewallStatus.Allowed;
            }
            catch { return false; }
        }

        /// <summary>
        /// Starts the elevated helper only after the caller's confirmation dialog returned Yes.
        /// Cancelling UAC is a normal false result and leaves firewall state untouched.
        /// </summary>
        public static bool RequestRepair(FirewallPorts ports)
        {
            string application = ExecutablePath();
            if (ports == null || string.IsNullOrEmpty(application)) return false;
            try
            {
                var start = new ProcessStartInfo(application,
                    "--configure-firewall --firewall-mesh=" + ports.MeshTcp +
                    " --firewall-admin=" + ports.AdminTcp +
                    " --firewall-discovery=" + ports.DiscoveryUdp +
                    " --firewall-sip=" + ports.SipUdp)
                {
                    UseShellExecute = true,
                    Verb = "runas",
                    WorkingDirectory = Path.GetDirectoryName(application),
                };
                using (Process helper = Process.Start(start))
                {
                    if (helper == null) return false;
                    helper.WaitForExit();
                    return helper.ExitCode == 0 && Check(ports) == FirewallStatus.Allowed;
                }
            }
            catch { return false; }
        }

        private static dynamic CreatePolicy()
        {
            Type type = Type.GetTypeFromProgID("HNetCfg.FwPolicy2");
            return type == null ? null : Activator.CreateInstance(type);
        }

        private static int ActiveFirewallProfiles(dynamic policy)
        {
            int active = Convert.ToInt32(policy.CurrentProfileTypes);
            int enabled = 0;
            for (int profile = 1; profile <= 4; profile <<= 1)
                if ((active & profile) != 0 && Convert.ToBoolean(policy.FirewallEnabled[profile]))
                    enabled |= profile;
            return enabled;
        }

        private static bool Allows(dynamic rules, string application, int protocol, int port,
                                   int requiredProfiles)
        {
            int covered = 0;
            foreach (dynamic rule in rules)
            {
                if (!Convert.ToBoolean(rule.Enabled) || Convert.ToInt32(rule.Direction) != DirectionIn ||
                    Convert.ToInt32(rule.Action) != ActionAllow) continue;
                string program = rule.ApplicationName as string;
                if (string.IsNullOrEmpty(program) || !string.Equals(program, application,
                    StringComparison.OrdinalIgnoreCase)) continue;
                int ruleProtocol = Convert.ToInt32(rule.Protocol);
                if (ruleProtocol != protocol && ruleProtocol != ProtocolAny) continue;
                if (!ContainsPort(rule.LocalPorts as string, port)) continue;
                int profiles = Convert.ToInt32(rule.Profiles);
                covered |= (profiles == -1 || profiles == AllProfiles) ? requiredProfiles :
                    profiles & requiredProfiles;
                if ((covered & requiredProfiles) == requiredProfiles) return true;
            }
            return false;
        }

        private static void AddRule(dynamic rules, string name, string application, int protocol,
                                    string ports)
        {
            Type type = Type.GetTypeFromProgID("HNetCfg.FWRule");
            if (type == null) throw new InvalidOperationException("Windows Firewall rule API missing");
            dynamic rule = Activator.CreateInstance(type);
            rule.Name = name;
            rule.Description = "Doorbell local cluster communication";
            rule.ApplicationName = application;
            rule.Protocol = protocol;
            rule.LocalPorts = ports;
            rule.Direction = DirectionIn;
            rule.Action = ActionAllow;
            rule.Profiles = AllProfiles;
            rule.Enabled = true;
            rules.Add(rule);
        }

        private static bool ContainsPort(string values, int port)
        {
            if (string.IsNullOrWhiteSpace(values)) return false;
            foreach (string raw in values.Split(','))
            {
                string value = raw.Trim();
                if (value == "*") return true;
                int dash = value.IndexOf('-');
                int first;
                if (dash >= 0 && int.TryParse(value.Substring(0, dash), out first))
                {
                    int last;
                    if (int.TryParse(value.Substring(dash + 1), out last) && port >= first && port <= last)
                        return true;
                }
                else if (int.TryParse(value, out first) && first == port) return true;
            }
            return false;
        }

        private static int ArgumentPort(string[] args, string prefix, int fallback)
        {
            if (args != null) foreach (string arg in args)
                if (arg != null && arg.StartsWith(prefix, StringComparison.Ordinal))
                {
                    int value;
                    if (int.TryParse(arg.Substring(prefix.Length), out value) && value >= 0 && value < 65536)
                        return value;
                }
            return fallback;
        }

        private static string ExecutablePath()
        {
            try
            {
                string path = Assembly.GetEntryAssembly() == null ? null :
                    Assembly.GetEntryAssembly().Location;
                return string.IsNullOrEmpty(path) ? null : Path.GetFullPath(path);
            }
            catch { return null; }
        }

        private static bool IsAdministrator()
        {
            try
            {
                var identity = WindowsIdentity.GetCurrent();
                return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }
    }
}
