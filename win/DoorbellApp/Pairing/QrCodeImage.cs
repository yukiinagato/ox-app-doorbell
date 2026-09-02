using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DoorbellApp.Core;

namespace DoorbellApp.Pairing
{
    /// <summary>Renders the core QR bitmap (db_core_qr_encode) into a frozen WriteableBitmap.</summary>
    public static class QrCodeImage
    {
        private const int QuietZoneModules = 4;

        /// <summary>
        /// Returns a black-on-white QR image at least <paramref name="minimumPixels"/> wide, or
        /// null when core cannot encode the payload. The result is frozen and cross-thread safe.
        /// </summary>
        public static BitmapSource Render(string text, int minimumPixels)
        {
            int modulesPerSide;
            byte[] modules = CoreClient.QrEncode(text, out modulesPerSide);
            if (modules == null || modulesPerSide <= 0) return null;
            if (modules.Length < modulesPerSide * modulesPerSide) return null;

            int side = modulesPerSide + QuietZoneModules * 2;
            int scale = Math.Max(1, minimumPixels / side);
            int pixels = side * scale;
            int stride = pixels * 4;
            var buffer = new byte[stride * pixels];
            for (int i = 0; i < buffer.Length; i++) buffer[i] = 0xFF;  // opaque white

            for (int row = 0; row < modulesPerSide; row++)
            {
                for (int column = 0; column < modulesPerSide; column++)
                {
                    if (modules[row * modulesPerSide + column] == 0) continue;
                    int left = (column + QuietZoneModules) * scale;
                    int top = (row + QuietZoneModules) * scale;
                    for (int y = 0; y < scale; y++)
                    {
                        int offset = (top + y) * stride + left * 4;
                        for (int x = 0; x < scale; x++)
                        {
                            buffer[offset] = 0x00;
                            buffer[offset + 1] = 0x00;
                            buffer[offset + 2] = 0x00;
                            buffer[offset + 3] = 0xFF;
                            offset += 4;
                        }
                    }
                }
            }

            var bitmap = new WriteableBitmap(pixels, pixels, 96, 96, PixelFormats.Bgra32, null);
            bitmap.WritePixels(new Int32Rect(0, 0, pixels, pixels), buffer, stride, 0);
            bitmap.Freeze();
            return bitmap;
        }
    }
}
