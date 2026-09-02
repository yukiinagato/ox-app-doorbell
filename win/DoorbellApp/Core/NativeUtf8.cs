using System;
using System.Runtime.InteropServices;
using System.Text;

namespace DoorbellApp.Core
{
    internal static class NativeUtf8
    {
        public static IntPtr Alloc(string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value ?? "");
            IntPtr p = Marshal.AllocHGlobal(bytes.Length + 1);
            if (bytes.Length != 0) Marshal.Copy(bytes, 0, p, bytes.Length);
            Marshal.WriteByte(p, bytes.Length, 0);
            return p;
        }

        public static IntPtr Alloc(byte[] value)
        {
            byte[] bytes = value ?? new byte[0];
            IntPtr p = Marshal.AllocHGlobal(bytes.Length + 1);
            if (bytes.Length != 0) Marshal.Copy(bytes, 0, p, bytes.Length);
            Marshal.WriteByte(p, bytes.Length, 0);
            return p;
        }
    }
}
