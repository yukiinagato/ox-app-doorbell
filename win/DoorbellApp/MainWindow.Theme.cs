using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Media;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Kiosk;
using DoorbellApp.Pairing;
using DoorbellApp.Util;


namespace DoorbellApp
{
    // Theme, semantic styles and background images.
    public partial class MainWindow
    {
        private void ApplySemanticStyles()
        {
            if (_semanticStyles == null) return;
            _semanticApplier.Apply(CallButton, _semanticStyles.Get("call.primary"), false);
            _semanticApplier.Apply(CancelButton, _semanticStyles.Get("cancel.call"), true);
            _semanticApplier.Apply(EndCallButton, _semanticStyles.Get("call.end"), true);
            _semanticApplier.Apply(SosButton, _semanticStyles.Get("sos.trigger"), true);
            _semanticApplier.Apply(EmergencyCancelButton, _semanticStyles.Get("sos.cancel"), true);
            foreach (FrameworkElement child in PurposeGrid.Children)
                _semanticApplier.Apply(child, _semanticStyles.Get("purpose.button"), false);
            foreach (FrameworkElement child in CallingPurposeGrid.Children)
                _semanticApplier.Apply(child, _semanticStyles.Get("purpose.button"), false);
            foreach (FrameworkElement child in QuickReplyPanel.Children)
                _semanticApplier.Apply(child, _semanticStyles.Get("reply.button"), false);
            foreach (FrameworkElement child in new FrameworkElement[]
                     { AnswerButton, MonitorButton, OpenDoorButton, IgnoreButton })
                _semanticApplier.Apply(child, _semanticStyles.Get("ring.action"), false);
            _semanticApplier.Apply(IncomingTitle, _semanticStyles.Get("ring.title"), false);
            _semanticApplier.Apply(MonitorPickerClose, _semanticStyles.Get("monitor.close"), true);
        }

        private string ThemeValue(string leaf)
        {
            object v = null;
            if (!string.IsNullOrEmpty(_nodeId))
                v = CoreClient.Dig(_cfg, "devices." + _nodeId + ".local.theme." + leaf);
            if (v == null) v = CoreClient.Dig(_cfg, "display.theme." + leaf);
            return v != null ? v.ToString() : null;
        }

        private void ApplyTheme()
        {
            if (App.SafeMode)
            {
                _themeColor = null;
                _themeHash = null;
                Background = (Brush)FindResource("Bg");
                ThemeBgImage.Source = null;
                ThemeBgImage.Visibility = Visibility.Collapsed;
                ApplyThemeBackdrop();
                return;
            }
            string color = ThemeValue("bg_color");
            if (color != _themeColor)
            {
                _themeColor = color;
                if (!string.IsNullOrEmpty(color))
                {
                    try
                    {
                        var c = (Color)ColorConverter.ConvertFromString(color);
                        Background = Frozen(new SolidColorBrush(c));
                    }
                    catch (Exception ex)
                    {
                        Debug.WriteLine("Ignoring invalid theme background color: " + color + " " + ex.Message);
                    }
                }
                else
                {
                    Background = (Brush)FindResource("Bg");
                }
            }

            string hash = ThemeValue("bg_image");
            if (string.IsNullOrEmpty(hash))
            {
                _themeHash = null;
                ThemeBgImage.Source = null;
                ThemeBgImage.Visibility = Visibility.Collapsed;
                ApplyThemeBackdrop();
                return;
            }
            if (hash == _themeHash && ThemeBgImage.Source != null) return;
            _themeHash = hash;
            LoadThemeImage(hash);
        }

        private void LoadThemeImage(string hash)
        {
            string url = "http://127.0.0.1:" + App.Boot.HttpPort + "/asset/" + hash;
            Task.Run(() =>
            {
                byte[] data = null;
                try
                {
                    using (var wc = new System.Net.WebClient())
                        data = wc.DownloadData(url);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine("Theme image fetch failed; waiting for asset_ready: " + ex.Message);
                }
                if (data == null) return;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (_themeHash != hash) return;
                    try
                    {
                        var bmp = new BitmapImage();
                        bmp.BeginInit();
                        bmp.CacheOption = BitmapCacheOption.OnLoad;
                        bmp.StreamSource = new MemoryStream(data);
                        bmp.EndInit();
                        bmp.Freeze();
                        ThemeBgImage.Source = bmp;
                        ThemeBgImage.Visibility = SaverHidesImage ? Visibility.Collapsed : Visibility.Visible;
                        ApplyThemeBackdrop();
                        QueueInkPass();
                    }
                    catch (Exception ex)
                    {
                        Debug.WriteLine("Ignoring invalid theme image: " + ex.Message);
                    }
                }));
            });
        }
    }
}
