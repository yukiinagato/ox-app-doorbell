using System;
using DoorbellApp.Core;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DoorbellApp.Pairing;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// Windows has no native settings screen (spec 0.1): everything else lives in the web admin,
    /// which this card opens. It shows the QR and the URL so another device can open the page too.
    /// </summary>
    public partial class WebAdminWindow : Window
    {
        private readonly int _port;
        private readonly List<string> _hosts;
        private int _selected;

        public WebAdminWindow(int port)
        {
            InitializeComponent();
            _port = port;
            _hosts = AdminLink.Hosts();
            Title = Texts.T("web_admin.title");
            TitleText.Text = Texts.T("web_admin.title");
            HintText.Text = Texts.T("web_admin.hint");
            OpenButton.Content = Texts.T("web_admin.open_browser");
            CloseButton.Content = Texts.T("monitor.close");
            InitializeUpdateCard();
            BuildAddressButtons();
            Render();
        }

        /// <summary>The address currently shown, or an empty string when there is none.</summary>
        public string CurrentUrl
        {
            get
            {
                return _selected >= 0 && _selected < _hosts.Count
                    ? AdminLink.Url(_hosts[_selected], _port) : "";
            }
        }

        private void BuildAddressButtons()
        {
            OtherAddresses.Children.Clear();
            if (_hosts.Count < 2) return;
            OtherAddresses.Children.Add(new TextBlock
            {
                Text = Texts.T("web_admin.other_address"),
                FontSize = 13,
                Margin = new Thickness(0, 0, 0, 6),
                Foreground = (Brush)FindResource("Dim"),
            });
            for (int index = 0; index < _hosts.Count; index++)
            {
                var button = new Button
                {
                    Content = _hosts[index],
                    Tag = index,
                    Style = (Style)FindResource("ChipButton"),
                    BorderBrush = (Brush)FindResource("Line"),
                    Margin = new Thickness(0, 0, 0, 5),
                    HorizontalAlignment = HorizontalAlignment.Left,
                };
                button.Click += OnAddressClick;
                OtherAddresses.Children.Add(button);
            }
        }

        private void OnAddressClick(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            if (button == null || !(button.Tag is int)) return;
            _selected = (int)button.Tag;
            Render();
        }

        private void Render()
        {
            string url = CurrentUrl;
            if (string.IsNullOrEmpty(url))
            {
                UrlText.Text = Texts.T("web_admin.none");
                QrImage.Source = null;
                OpenButton.IsEnabled = false;
                return;
            }
            UrlText.Text = url;
            OpenButton.IsEnabled = true;
            BitmapSource qr = QrCodeImage.Render(url, 200);
            QrImage.Source = qr;
        }

        private void OnOpenClick(object sender, RoutedEventArgs e)
        {
            string url = CurrentUrl;
            if (string.IsNullOrEmpty(url)) return;
            try
            {
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                Close();
            }
            catch (Exception ex)
            {
                Debug.WriteLine("could not launch the default browser: " + ex.Message);
                ErrorText.Text = Texts.T("web_admin.open_failed");
                ErrorText.Visibility = Visibility.Visible;
            }
        }

        // ---- in-app updates -------------------------------------------------------------

        private UpdateChecker.Release _pendingRelease;
        private bool _updateBusy;

        private void InitializeUpdateCard()
        {
            UpdateTitle.Text = Texts.T("web_admin.update_title");
            UpdateCheckButton.Content = Texts.T("web_admin.update_check");
            UpdateApplyButton.Content = Texts.T("web_admin.update_apply");
            var installed = UpdateChecker.ReadInstalled();
            if (!installed.FromInstaller)
            {
                UpdateStatus.Text = Texts.T("web_admin.update_not_installer");
                UpdateCheckButton.IsEnabled = false;
                return;
            }
            UpdateStatus.Text = installed.Version + " (" + installed.BuildId + ")";
        }

        private void OnUpdateCheckClick(object sender, RoutedEventArgs e)
        {
            if (_updateBusy) return;
            _updateBusy = true;
            UpdateApplyButton.Visibility = Visibility.Collapsed;
            UpdateStatus.Text = Texts.T("web_admin.update_checking");
            var installed = UpdateChecker.ReadInstalled();
            System.Threading.ThreadPool.QueueUserWorkItem(_ =>
            {
                UpdateChecker.Release release = null;
                string error = null;
                try { release = UpdateChecker.Check(installed); }
                catch (Exception ex) { error = ex.Message; }
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    _updateBusy = false;
                    if (error != null)
                    {
                        UpdateStatus.Text = Texts.T("web_admin.update_failed", error);
                        return;
                    }
                    _pendingRelease = release.IsNewer ? release : null;
                    if (release.IsNewer)
                    {
                        UpdateStatus.Text = Texts.T("web_admin.update_available", release.Tag,
                                                    installed.BuildId);
                        UpdateApplyButton.Visibility = Visibility.Visible;
                    }
                    else
                    {
                        UpdateStatus.Text = Texts.T("web_admin.update_latest", installed.BuildId);
                    }
                }));
            });
        }

        private void OnUpdateApplyClick(object sender, RoutedEventArgs e)
        {
            var release = _pendingRelease;
            if (_updateBusy || release == null) return;
            _updateBusy = true;
            UpdateApplyButton.IsEnabled = false;
            UpdateCheckButton.IsEnabled = false;
            System.Threading.ThreadPool.QueueUserWorkItem(_ =>
            {
                string error = null;
                try
                {
                    UpdateChecker.DownloadAndApply(release, stage =>
                        Dispatcher.BeginInvoke(new Action(() =>
                        {
                            UpdateStatus.Text = Texts.T(stage == "download"
                                ? "web_admin.update_downloading"
                                : stage == "verify" ? "web_admin.update_verifying"
                                                    : "web_admin.update_installing");
                        })));
                }
                catch (Exception ex) { error = ex.Message; }
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    _updateBusy = false;
                    UpdateApplyButton.IsEnabled = true;
                    UpdateCheckButton.IsEnabled = true;
                    if (error != null)
                        UpdateStatus.Text = Texts.T("web_admin.update_failed", error);
                }));
            });
        }

        private void OnCloseClick(object sender, RoutedEventArgs e)
        {
            Close();
        }
    }
}
