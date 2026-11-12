using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using DoorbellApp.Ui;
using DoorbellApp.Util;
using NavigationView = ModernWpf.Controls.NavigationView;
using NavigationViewItem = ModernWpf.Controls.NavigationViewItem;
using NavigationViewItemInvokedEventArgs = ModernWpf.Controls.NavigationViewItemInvokedEventArgs;

namespace DoorbellApp
{
    /// <summary>
    /// The indoor panel's NavigationView: Home and History are pages, Monitor and Settings are
    /// commands that open their own surface and leave the page selection where it was. Settings
    /// always goes through the admin password (OnAdminEntryClick).
    /// </summary>
    public partial class MainWindow
    {
        private void ApplyNavigationStrings()
        {
            SetNavigationItem(NavHome, "IconHome", Texts.T("nav.home"));
            // History keeps its own content (label plus unread badge), so only the icon is set.
            NavHistoryLabel.Text = Texts.T("nav.history");
            if (NavHistory.Icon == null) NavHistory.Icon = Fluent.Icon("IconCalendarTime");
            ApplyMissedBadge();
            SetNavigationItem(OpenMonitorButton, "IconEye", Texts.T("nav.monitor"));
            SetNavigationItem(AdminEntryButton, "IconSettings", Texts.T("nav.settings"));
            MissedBadgeAction.Content = Texts.T("dash.see_all");
            SyncHomeNavigation();
        }

        private static void SetNavigationItem(NavigationViewItem item, string iconKey, string label)
        {
            item.Content = label;
            if (item.Icon == null) item.Icon = Fluent.Icon(iconKey);
            System.Windows.Automation.AutomationProperties.SetName(item, label ?? "");
        }

        private void OnHomeNavInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
        {
            object item = args.InvokedItemContainer;
            if (ReferenceEquals(item, NavHistory))
            {
                if (HistoryView.Visibility != Visibility.Visible) OpenHistory();
            }
            else if (ReferenceEquals(item, NavHome))
            {
                if (HistoryView.Visibility == Visibility.Visible)
                    OnHistoryCloseClick(this, new RoutedEventArgs());
            }
            else if (ReferenceEquals(item, OpenMonitorButton))
            {
                OnOpenMonitorClick(this, new RoutedEventArgs());
            }
            else if (ReferenceEquals(item, AdminEntryButton))
            {
                OnAdminEntryClick(this, new RoutedEventArgs());
            }
            SyncHomeNavigation();
        }

        /// <summary>
        /// Puts the selection back on the page that is showing. It runs after the NavigationView
        /// has finished its own selection change, so a command item never stays selected.
        /// </summary>
        private void SyncHomeNavigation()
        {
            Dispatcher.BeginInvoke(new Action(() =>
            {
                object page = HistoryView.Visibility == Visibility.Visible
                    ? (object)NavHistory : NavHome;
                if (!ReferenceEquals(HomeNav.SelectedItem, page)) HomeNav.SelectedItem = page;
            }), DispatcherPriority.Input);
        }

        /// <summary>
        /// Counts taps in the hidden corner while they tunnel, so the gesture works whatever is
        /// drawn over the corner and never takes a tap away from it.
        /// </summary>
        private void OnIdlePreviewDown(object sender, MouseButtonEventArgs e)
        {
            if (SecretCorner.Visibility != Visibility.Visible) return;
            Point at = e.GetPosition(IdleView);
            if (at.X >= IdleView.ActualWidth - SecretCorner.Width && at.Y <= SecretCorner.Height)
                OnSecretCorner(sender, e);
        }
    }
}
