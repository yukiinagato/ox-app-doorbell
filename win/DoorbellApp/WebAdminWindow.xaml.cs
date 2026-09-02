using System;
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

        private void OnCloseClick(object sender, RoutedEventArgs e)
        {
            Close();
        }
    }
}
