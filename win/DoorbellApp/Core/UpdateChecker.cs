using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace DoorbellApp.Core
{
    /// <summary>
    /// In-app updater for installer-based deployments. The installer records what it installed
    /// under HKLM\Software\Doorbell; the checker asks the release feed (GitHub Releases by
    /// default, overridable through the UpdateFeed registry value) for the latest
    /// DoorbellSetup-*.exe, verifies it against the published .sha256, and runs it silently
    /// (/VERYSILENT /SUPPRESSMSGBOXES /NORESTART). The installer stops the service and the
    /// shell, replaces the files, keeps %ProgramData%\Doorbell and restarts the service.
    /// Nothing is downloaded or run without the operator pressing the update button.
    /// </summary>
    internal static class UpdateChecker
    {
        private const string RegistryKey = @"Software\Doorbell";
        private const string DefaultFeed =
            "https://api.github.com/repos/yukiinagato/ox-app-doorbell/releases/latest";
        private const string UserAgent = "DoorbellApp-Updater";

        public sealed class Release
        {
            public string Tag = "";
            public string BuildId = "";
            public string InstallerUrl = "";
            public string InstallerName = "";
            public string ChecksumUrl = "";
            public long SizeBytes;
            public bool IsNewer;
        }

        public sealed class Installed
        {
            public string BuildId = "";
            public string Version = "";
            public string InstallDir = "";
            public bool FromInstaller { get { return !string.IsNullOrEmpty(InstallDir); } }
        }

        public static Installed ReadInstalled()
        {
            var installed = new Installed();
            try
            {
                using (var key = Registry.LocalMachine.OpenSubKey(RegistryKey))
                {
                    if (key == null) return installed;
                    installed.BuildId = (key.GetValue("BuildId") as string) ?? "";
                    installed.Version = (key.GetValue("Version") as string) ?? "";
                    installed.InstallDir = (key.GetValue("InstallDir") as string) ?? "";
                }
            }
            catch { }
            return installed;
        }

        public static string FeedUrl()
        {
            try
            {
                using (var key = Registry.LocalMachine.OpenSubKey(RegistryKey))
                {
                    string custom = key?.GetValue("UpdateFeed") as string;
                    if (!string.IsNullOrEmpty(custom) &&
                        custom.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                        return custom;
                }
            }
            catch { }
            return DefaultFeed;
        }

        /// <summary>Blocking; call from a worker thread. Throws on network or feed errors.</summary>
        public static Release Check(Installed installed)
        {
            string json = DownloadString(FeedUrl());
            var doc = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
            var release = new Release
            {
                Tag = Convert.ToString(doc.ContainsKey("tag_name") ? doc["tag_name"] : "") ?? "",
            };
            var assets = doc.ContainsKey("assets") ? doc["assets"] as object[] : null;
            if (assets != null)
            {
                foreach (object entry in assets)
                {
                    var asset = entry as Dictionary<string, object>;
                    if (asset == null) continue;
                    string name = Convert.ToString(asset.ContainsKey("name") ? asset["name"] : "") ?? "";
                    string url = Convert.ToString(asset.ContainsKey("browser_download_url")
                        ? asset["browser_download_url"] : "") ?? "";
                    if (Regex.IsMatch(name, @"^DoorbellSetup-.+\.exe$", RegexOptions.IgnoreCase))
                    {
                        release.InstallerName = name;
                        release.InstallerUrl = url;
                        release.BuildId = name.Substring("DoorbellSetup-".Length,
                            name.Length - "DoorbellSetup-".Length - ".exe".Length);
                        long size;
                        if (asset.ContainsKey("size") && long.TryParse(Convert.ToString(asset["size"]),
                                                                       out size))
                            release.SizeBytes = size;
                    }
                    else if (Regex.IsMatch(name, @"^DoorbellSetup-.+\.exe\.sha256$",
                                           RegexOptions.IgnoreCase))
                    {
                        release.ChecksumUrl = url;
                    }
                }
            }
            if (string.IsNullOrEmpty(release.InstallerUrl))
                throw new InvalidOperationException("the release has no DoorbellSetup-*.exe asset");
            release.IsNewer = IsNewer(release, installed);
            return release;
        }

        /// <summary>
        /// A release is applicable when its build id differs from the installed one and its tag
        /// version is not older than the installed version. Same build id means already installed.
        /// </summary>
        internal static bool IsNewer(Release release, Installed installed)
        {
            if (string.IsNullOrEmpty(release.BuildId)) return false;
            if (string.Equals(release.BuildId, installed.BuildId, StringComparison.OrdinalIgnoreCase))
                return false;
            Version tagVersion = ParseVersion(release.Tag);
            Version installedVersion = ParseVersion(installed.Version);
            if (tagVersion != null && installedVersion != null && tagVersion < installedVersion)
                return false;
            return true;
        }

        internal static Version ParseVersion(string text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            Match m = Regex.Match(text, @"(\d+)\.(\d+)(?:\.(\d+))?");
            if (!m.Success) return null;
            int major = int.Parse(m.Groups[1].Value), minor = int.Parse(m.Groups[2].Value);
            int patch = m.Groups[3].Success ? int.Parse(m.Groups[3].Value) : 0;
            return new Version(major, minor, patch);
        }

        /// <summary>
        /// Downloads the installer into %ProgramData%\Doorbell\updates, verifies the SHA-256
        /// against the published checksum (mandatory), and starts it silently with elevation.
        /// Returns the path that was launched. Blocking; call from a worker thread.
        /// </summary>
        public static string DownloadAndApply(Release release, Action<string> progress)
        {
            if (release == null || string.IsNullOrEmpty(release.InstallerUrl))
                throw new ArgumentException("no installer in the release");
            if (string.IsNullOrEmpty(release.ChecksumUrl))
                throw new InvalidOperationException("the release publishes no .sha256 for the installer");
            string dir = Path.Combine(App.DataDir, "updates");
            Directory.CreateDirectory(dir);
            string target = Path.Combine(dir, release.InstallerName);
            string partial = target + ".part";
            progress?.Invoke("download");
            DownloadFile(release.InstallerUrl, partial);
            progress?.Invoke("verify");
            string expected = ExpectedHash(DownloadString(release.ChecksumUrl));
            string actual = Sha256Hex(partial);
            if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase))
            {
                try { File.Delete(partial); } catch { }
                throw new InvalidOperationException("installer checksum mismatch");
            }
            if (File.Exists(target)) File.Delete(target);
            File.Move(partial, target);
            progress?.Invoke("install");
            var start = new ProcessStartInfo(target,
                "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /LOG=\"" +
                Path.Combine(dir, "install.log") + "\"")
            {
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = dir,
            };
            Process.Start(start);
            return target;
        }

        internal static string ExpectedHash(string checksumText)
        {
            Match m = Regex.Match(checksumText ?? "", @"\b([0-9a-fA-F]{64})\b");
            return m.Success ? m.Groups[1].Value.ToLowerInvariant() : "";
        }

        private static string Sha256Hex(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path))
            {
                byte[] hash = sha.ComputeHash(stream);
                var sb = new StringBuilder(hash.Length * 2);
                foreach (byte b in hash) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        private static void EnsureTls12()
        {
            // Windows 7 and 8.1 do not enable TLS 1.2 for .NET clients by default.
            ServicePointManager.SecurityProtocol |= (SecurityProtocolType)0xC00;
        }

        private static string DownloadString(string url)
        {
            EnsureTls12();
            using (var client = new WebClient())
            {
                client.Headers[HttpRequestHeader.UserAgent] = UserAgent;
                client.Headers[HttpRequestHeader.Accept] = "application/vnd.github+json";
                client.Encoding = Encoding.UTF8;
                return client.DownloadString(url);
            }
        }

        private static void DownloadFile(string url, string path)
        {
            EnsureTls12();
            using (var client = new WebClient())
            {
                client.Headers[HttpRequestHeader.UserAgent] = UserAgent;
                client.DownloadFile(url, path);
            }
        }
    }
}
