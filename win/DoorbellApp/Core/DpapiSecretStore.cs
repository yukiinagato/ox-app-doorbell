using System;
using System.IO;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace DoorbellApp.Core
{
    /// <summary>Machine-scoped DPAPI store used by core secret:* references.</summary>
    internal sealed class DpapiSecretStore
    {
        private const int MaxValueBytes = 1024 * 1024;
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("DoorbellApp/db_platform_v2/1");
        private readonly string _directory;

        public DpapiSecretStore(string dataDirectory)
        {
            _directory = Path.Combine(dataDirectory, "secure");
        }

        private string PathFor(string key)
        {
            if (string.IsNullOrEmpty(key) || key.Length > 512) throw new ArgumentException("invalid key");
            byte[] digest;
            using (var sha = SHA256.Create()) digest = sha.ComputeHash(Encoding.UTF8.GetBytes(key));
            var name = new StringBuilder(digest.Length * 2);
            foreach (byte b in digest) name.Append(b.ToString("x2"));
            return Path.Combine(_directory, name + ".dpapi");
        }

        public string Get(string key)
        {
            try
            {
                string path = PathFor(key);
                if (!File.Exists(path)) return null;
                byte[] protectedBytes = File.ReadAllBytes(path);
                if (protectedBytes.Length == 0 || protectedBytes.Length > MaxValueBytes + 4096) return null;
                byte[] clear = ProtectedData.Unprotect(protectedBytes, Entropy,
                    DataProtectionScope.LocalMachine);
                if (clear.Length > MaxValueBytes) return null;
                return Encoding.UTF8.GetString(clear);
            }
            catch (CryptographicException) { return null; }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
            catch (ArgumentException) { return null; }
        }

        public bool Put(string key, string value)
        {
            string temporary = null;
            try
            {
                byte[] clear = Encoding.UTF8.GetBytes(value ?? "");
                if (clear.Length > MaxValueBytes) return false;
                byte[] protectedBytes = ProtectedData.Protect(clear, Entropy,
                    DataProtectionScope.LocalMachine);
                Directory.CreateDirectory(_directory);
                HardenDirectory();
                string target = PathFor(key);
                temporary = Path.Combine(_directory, Path.GetRandomFileName());
                using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                                                   FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    output.Write(protectedBytes, 0, protectedBytes.Length);
                    output.Flush(true);
                }
                if (File.Exists(target)) File.Replace(temporary, target, null, true);
                else File.Move(temporary, target);
                temporary = null;
                return true;
            }
            catch (CryptographicException) { return false; }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (ArgumentException) { return false; }
            finally
            {
                if (temporary != null) try { File.Delete(temporary); } catch { }
            }
        }

        private void HardenDirectory()
        {
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            var inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            var propagation = PropagationFlags.None;
            var current = WindowsIdentity.GetCurrent().User;
            if (current == null) throw new UnauthorizedAccessException("Windows identity has no SID");
            security.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl,
                inheritance, propagation, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                FileSystemRights.FullControl, inheritance, propagation, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
                FileSystemRights.FullControl, inheritance, propagation, AccessControlType.Allow));
            Directory.SetAccessControl(_directory, security);
        }
    }
}
