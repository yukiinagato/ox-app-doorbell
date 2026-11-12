using System;

namespace DoorbellApp.Util
{
    /// <summary>
    /// Automated UI test mode (win/scripts/ui_smoke.ps1). It exists so a test run can drive every
    /// screen of an isolated instance; it must never be reachable by accident on a household
    /// device. All three conditions are required, and a release shortcut or service never sets
    /// them: the <c>--ui-test</c> switch, a <c>--data-dir</c> naming a throwaway directory (the
    /// installed data directory is refused), and DOORBELL_UI_TEST=1 in the process environment.
    /// This class has no WPF dependency so the rule is tested on the build host.
    /// </summary>
    internal static class UiTestMode
    {
        public const string Switch = "--ui-test";
        public const string DataDirSwitch = "--data-dir";
        public const string EnvironmentFlag = "DOORBELL_UI_TEST";
        public const string CommandFile = "ui-test-command.txt";
        public const string AckFile = "ui-test-ack.txt";

        /// <summary>
        /// The throwaway data directory when test mode is fully and explicitly requested,
        /// otherwise null. <paramref name="installedDataDir"/> is where a real installation
        /// keeps its data; a test run may not point at it or inside it.
        /// </summary>
        public static string ResolveDataDir(string[] args, string environmentFlag,
                                            string installedDataDir)
        {
            if (args == null || environmentFlag != "1") return null;
            bool requested = false;
            string dataDir = null;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == Switch) requested = true;
                if (args[i] == DataDirSwitch && i + 1 < args.Length) dataDir = args[i + 1];
            }
            if (!requested || string.IsNullOrEmpty(dataDir)) return null;
            string wanted = Normalize(dataDir);
            if (wanted.Length == 0) return null;
            string installed = Normalize(installedDataDir ?? "");
            if (installed.Length != 0)
            {
                string root = Normalize(ParentOf(installed));
                if (SameOrInside(wanted, installed) || (root.Length != 0 && SameOrInside(wanted, root)))
                    return null;
            }
            return dataDir;
        }

        /// <summary>One command line split into its verb and optional argument.</summary>
        public static bool ParseCommand(string line, out string verb, out string argument)
        {
            verb = "";
            argument = "";
            string text = (line ?? "").Trim();
            if (text.Length == 0) return false;
            int space = text.IndexOf(' ');
            verb = (space < 0 ? text : text.Substring(0, space)).ToLowerInvariant();
            argument = space < 0 ? "" : text.Substring(space + 1).Trim();
            return true;
        }

        private static string Normalize(string path)
        {
            return (path ?? "").Trim().Replace('/', '\\').TrimEnd('\\').ToLowerInvariant();
        }

        private static string ParentOf(string path)
        {
            int cut = path.LastIndexOf('\\');
            return cut <= 0 ? "" : path.Substring(0, cut);
        }

        private static bool SameOrInside(string path, string root)
        {
            return path == root || path.StartsWith(root + "\\", StringComparison.Ordinal);
        }
    }
}
