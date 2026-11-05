using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace DoorbellApp.Core
{
    /// <summary>An update was refused because its origin could not be established.</summary>
    internal sealed class UpdateTrustException : Exception
    {
        public UpdateTrustException(string message) : base(message) { }
    }

    /// <summary>
    /// In-app updater for installer-based deployments. The installer records what it installed
    /// under HKLM\Software\Doorbell, including UpdatePublisher, the certificate subject that
    /// release installers are Authenticode-signed with. The checker asks the release feed
    /// (GitHub Releases by default, overridable through the UpdateFeed registry value) for the
    /// latest DoorbellSetup-*.exe and only offers a strictly newer version.
    ///
    /// Applying an update: the installer is downloaded into a directory only this user, SYSTEM
    /// and Administrators can write; it is then opened with write and delete sharing denied,
    /// and while that handle is held its SHA-256 is checked against the published .sha256, its
    /// Authenticode signature is verified with WinVerifyTrust, and the signer must match
    /// UpdatePublisher. Only then is it started with elevation. The .sha256 alone comes from the
    /// same place as the installer and proves integrity, not origin; the signature proves origin.
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
            public string Publisher = "";
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
                    installed.Publisher = (key.GetValue("UpdatePublisher") as string) ?? "";
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
                    if (Regex.IsMatch(name, @"^DoorbellSetup-[A-Za-z0-9._-]+\.exe$"))
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
                    else if (Regex.IsMatch(name, @"^DoorbellSetup-[A-Za-z0-9._-]+\.exe\.sha256$"))
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
        /// A release applies only when both its tag and the installed version parse and the tag
        /// is strictly newer. A different build id with the same or an unknown version is never
        /// offered, so an update can never be a downgrade.
        /// </summary>
        internal static bool IsNewer(Release release, Installed installed)
        {
            if (string.IsNullOrEmpty(release.BuildId)) return false;
            if (string.Equals(release.BuildId, installed.BuildId, StringComparison.OrdinalIgnoreCase))
                return false;
            Version tagVersion = ParseVersion(release.Tag);
            Version installedVersion = ParseVersion(installed.Version);
            return tagVersion != null && installedVersion != null && tagVersion > installedVersion;
        }

        internal static Version ParseVersion(string text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            Match m = Regex.Match(text, @"(\d+)\.(\d+)(?:\.(\d+))?");
            if (!m.Success) return null;
            int major, minor, patch = 0;
            if (!int.TryParse(m.Groups[1].Value, out major) ||
                !int.TryParse(m.Groups[2].Value, out minor) ||
                (m.Groups[3].Success && !int.TryParse(m.Groups[3].Value, out patch)))
                return null;
            return new Version(major, minor, patch);
        }

        /// <summary>
        /// Downloads, verifies and starts the installer with elevation. Returns the path that was
        /// launched. Blocking; call from a worker thread. Throws UpdateTrustException when the
        /// signature or publisher does not check out.
        /// </summary>
        public static string DownloadAndApply(Release release, Action<string> progress)
        {
            if (release == null || string.IsNullOrEmpty(release.InstallerUrl))
                throw new ArgumentException("no installer in the release");
            if (string.IsNullOrEmpty(release.ChecksumUrl))
                throw new InvalidOperationException("the release publishes no .sha256 for the installer");
            Installed installed = ReadInstalled();
            if (string.IsNullOrEmpty(installed.Publisher))
                throw new UpdateTrustException("no trusted update publisher is configured");
            if (!IsNewer(release, installed))
                throw new InvalidOperationException("the release is not newer than this installation");

            string dir = PrivateUpdateDirectory();
            string target = Path.Combine(dir, release.InstallerName);
            string partial = target + ".part";
            progress?.Invoke("download");
            if (File.Exists(partial)) File.Delete(partial);
            DownloadFile(release.InstallerUrl, partial);
            if (File.Exists(target)) File.Delete(target);
            File.Move(partial, target);
            string expected = ExpectedHash(DownloadString(release.ChecksumUrl));
            if (expected.Length == 0)
                throw new InvalidOperationException("the published checksum is unreadable");

            progress?.Invoke("verify");
            // Held until the installer has started: with write and delete sharing denied, the
            // file that is verified below is the file that runs.
            using (var pinned = new FileStream(target, FileMode.Open, FileAccess.Read,
                                               FileShare.Read))
            {
                string actual = Sha256Hex(pinned);
                if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("installer checksum mismatch");
                VerifySignature(target, installed.Publisher);

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
            }
            return target;
        }

        /// <summary>
        /// %LOCALAPPDATA%\Doorbell\updates with a protected DACL: this user, SYSTEM and
        /// Administrators. The shared %ProgramData% tree is writable by other users and must
        /// never hold a file that is about to run elevated.
        /// </summary>
        private static string PrivateUpdateDirectory()
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Doorbell", "updates");
            Directory.CreateDirectory(dir);
            var attributes = File.GetAttributes(dir);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new UpdateTrustException("the update directory is a reparse point");
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            var inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            var current = WindowsIdentity.GetCurrent().User;
            if (current == null) throw new UnauthorizedAccessException("Windows identity has no SID");
            security.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl,
                inheritance, PropagationFlags.None, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                FileSystemRights.FullControl, inheritance, PropagationFlags.None,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
                FileSystemRights.FullControl, inheritance, PropagationFlags.None,
                AccessControlType.Allow));
            Directory.SetAccessControl(dir, security);
            return dir;
        }

        internal static string ExpectedHash(string checksumText)
        {
            Match m = Regex.Match(checksumText ?? "", @"\b([0-9a-fA-F]{64})\b");
            return m.Success ? m.Groups[1].Value.ToLowerInvariant() : "";
        }

        private static string Sha256Hex(Stream stream)
        {
            using (var sha = SHA256.Create())
            {
                stream.Position = 0;
                byte[] hash = sha.ComputeHash(stream);
                var sb = new StringBuilder(hash.Length * 2);
                foreach (byte b in hash) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        // ---- Authenticode ------------------------------------------------------------------

        private static readonly Guid GenericVerifyV2 =
            new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private sealed class WinTrustFileInfo
        {
            public uint cbStruct = (uint)Marshal.SizeOf(typeof(WinTrustFileInfo));
            public string pcwszFilePath;
            public IntPtr hFile = IntPtr.Zero;
            public IntPtr pgKnownSubject = IntPtr.Zero;
        }

        [StructLayout(LayoutKind.Sequential)]
        private sealed class WinTrustData
        {
            public uint cbStruct = (uint)Marshal.SizeOf(typeof(WinTrustData));
            public IntPtr pPolicyCallbackData = IntPtr.Zero;
            public IntPtr pSIPClientData = IntPtr.Zero;
            public uint dwUIChoice = 2;           // WTD_UI_NONE
            public uint fdwRevocationChecks = 1;  // WTD_REVOKE_WHOLECHAIN
            public uint dwUnionChoice = 1;        // WTD_CHOICE_FILE
            public IntPtr pFile;
            public uint dwStateAction = 1;        // WTD_STATEACTION_VERIFY
            public IntPtr hWVTStateData = IntPtr.Zero;
            public IntPtr pwszURLReference = IntPtr.Zero;
            public uint dwProvFlags = 0x00000080; // WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT
            public uint dwUIContext = 0;
            public IntPtr pSignatureSettings = IntPtr.Zero;
        }

        [DllImport("wintrust.dll", ExactSpelling = true, SetLastError = false,
                   CharSet = CharSet.Unicode)]
        private static extern int WinVerifyTrust(IntPtr hwnd,
            [MarshalAs(UnmanagedType.LPStruct)] Guid pgActionID, WinTrustData pWVTData);

        private static void VerifySignature(string path, string expectedPublisher)
        {
            var file = new WinTrustFileInfo { pcwszFilePath = path };
            IntPtr filePtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WinTrustFileInfo)));
            var data = new WinTrustData();
            try
            {
                Marshal.StructureToPtr(file, filePtr, false);
                data.pFile = filePtr;
                int result = WinVerifyTrust(IntPtr.Zero, GenericVerifyV2, data);
                data.dwStateAction = 2; // WTD_STATEACTION_CLOSE
                WinVerifyTrust(IntPtr.Zero, GenericVerifyV2, data);
                if (result != 0)
                    throw new UpdateTrustException(
                        "the installer signature is not valid (0x" + result.ToString("x8") + ")");
            }
            finally
            {
                Marshal.DestroyStructure(filePtr, typeof(WinTrustFileInfo));
                Marshal.FreeHGlobal(filePtr);
            }

            X509Certificate2 signer;
            try { signer = new X509Certificate2(X509Certificate.CreateFromSignedFile(path)); }
            catch (CryptographicException)
            {
                throw new UpdateTrustException("the installer carries no signer certificate");
            }
            string commonName = signer.GetNameInfo(X509NameType.SimpleName, false) ?? "";
            if (!string.Equals(commonName, expectedPublisher, StringComparison.Ordinal) &&
                !string.Equals(signer.Subject, expectedPublisher, StringComparison.Ordinal))
                throw new UpdateTrustException("the installer is signed by \"" + commonName +
                                               "\", not by the trusted publisher");
        }

        // ---- Transport ---------------------------------------------------------------------

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
