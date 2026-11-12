using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Ui;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// Size-class driven placement of the call screens, quick-reply sheet, live-view overlay and
    /// history list/detail (docs/en/ui-guidelines.md sections 2–4).
    /// </summary>
    public partial class MainWindow
    {
        private SizeClass _sizeClass = SizeClass.Expanded;
        private DispatcherTimer _liveOverlayTimer;
        private bool _liveOverlayMode;
        private Dictionary<string, object> _historySelected;

        // ---- Incoming / in-call action zones -------------------------------------------------

        /// <summary>
        /// Portrait and narrow windows keep the action zone at the bottom; expanded landscape puts
        /// it in a fixed right column so the video keeps at least 60% of the width.
        /// </summary>
        private void ApplyCallLayout(double width, double height)
        {
            bool side = LayoutMetrics.SideActionZone(width, height);
            double zoneWidth = Math.Max(300, Math.Min(420, width * 0.32));

            IncomingActionColumn.Width = new GridLength(side ? zoneWidth : 0);
            InCallActionColumn.Width = new GridLength(side ? zoneWidth : 0);

            PlaceZone(IncomingActionZone, side);
            PlaceZone(InCallActionZone, side);
            // Side column: Answer, Reply, Ignore stack vertically, largest first.
            IncomingPrimaryRow.Rows = side ? 0 : 1;
            IncomingPrimaryRow.Columns = side ? 1 : 0;
            IncomingSecondaryRow.HorizontalAlignment = side ?
                HorizontalAlignment.Stretch : HorizontalAlignment.Center;
            IncomingActionZone.VerticalAlignment = side ? VerticalAlignment.Center : VerticalAlignment.Stretch;
            InCallActionZone.VerticalAlignment = side ? VerticalAlignment.Center : VerticalAlignment.Stretch;

            double primary = _sizeClass == SizeClass.Compact ? 72 : 88;
            AnswerButton.MinHeight = primary;
            foreach (var b in new[] { QuickReplyToggle, IgnoreButton })
                b.MinHeight = Math.Max(LayoutMetrics.TouchMin, primary - 16);
            foreach (var b in new[] { AnswerButton, QuickReplyToggle, IgnoreButton })
            {
                b.MinWidth = _sizeClass == SizeClass.Compact ? 0 : 120;
                b.Margin = side ? new Thickness(0, 0, 0, LayoutMetrics.S2)
                                : new Thickness(LayoutMetrics.S1, 0, LayoutMetrics.S1, 0);
            }
            foreach (var b in new[] { MonitorButton, OpenDoorButton, MicButton,
                                      InCallMicButton, InCallOpenDoorButton })
            {
                b.MinWidth = _sizeClass == SizeClass.Compact ? 0 : 120;
                b.MinHeight = 56;
            }

            LayOutQuickReplySheet(width);
            ApplyLiveOverlayMode();
        }

        private static void PlaceZone(FrameworkElement zone, bool side)
        {
            Grid.SetRow(zone, side ? 1 : 2);
            Grid.SetColumn(zone, side ? 1 : 0);
            Grid.SetColumnSpan(zone, side ? 1 : 2);
        }

        /// <summary>End sits where Answer was; the slot repaints in the negative role.</summary>
        private void PaintAnswerSlot(bool end)
        {
            AnswerButton.SetResourceReference(Control.BackgroundProperty, end ? "Negative" : "Positive");
            AnswerButton.SetResourceReference(Control.BorderBrushProperty, end ? "Negative" : "Positive");
            AnswerButton.SetResourceReference(Control.ForegroundProperty, end ? "OnNegative" : "OnPositive");
        }

        // ---- Quick-reply sheet ----------------------------------------------------------------

        private void LayOutQuickReplySheet(double width)
        {
            if (_sizeClass == SizeClass.Expanded)
            {
                QuickReplySheet.HorizontalAlignment = HorizontalAlignment.Right;
                QuickReplySheet.VerticalAlignment = VerticalAlignment.Stretch;
                QuickReplySheet.Width = Math.Min(440, Math.Max(340, width * 0.34));
                QuickReplySheet.MaxHeight = double.PositiveInfinity;
                QuickReplySheet.CornerRadius = new CornerRadius(LayoutMetrics.SheetRadius, 0, 0,
                                                                LayoutMetrics.SheetRadius);
            }
            else
            {
                double height = ActualHeight > 0 ? ActualHeight : SystemParameters.PrimaryScreenHeight;
                QuickReplySheet.HorizontalAlignment = HorizontalAlignment.Stretch;
                QuickReplySheet.VerticalAlignment = VerticalAlignment.Bottom;
                QuickReplySheet.Width = double.NaN;
                QuickReplySheet.MaxHeight = Math.Max(240, height * 0.6);
                QuickReplySheet.CornerRadius = new CornerRadius(LayoutMetrics.SheetRadius,
                                                                LayoutMetrics.SheetRadius, 0, 0);
            }
            double scale = LayoutMetrics.TextScale();
            foreach (var child in QuickReplyPanel.Children)
            {
                var button = child as Button;
                if (button == null) continue;
                button.MinHeight = 56;
                button.FontSize = 20 * scale;
                // Sheet rows: full width in the side sheet and on compact, chips on medium.
                button.HorizontalAlignment = HorizontalAlignment.Stretch;
                button.HorizontalContentAlignment = HorizontalAlignment.Left;
                button.Width = _sizeClass == SizeClass.Medium ? double.NaN
                    : Math.Max(160, QuickReplySheetInnerWidth(width));
                var label = button.Content as string;
                if (label != null)
                    button.Content = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap };
            }
        }

        private double QuickReplySheetInnerWidth(double width)
        {
            double sheet = _sizeClass == SizeClass.Expanded
                ? QuickReplySheet.Width : width;
            return sheet - 2 * LayoutMetrics.S4 - 2 * LayoutMetrics.S2 - 4;
        }

        private void UpdateQuickReplySheet()
        {
            QuickReplySheet.Visibility = QuickReplyPanel.Visibility;
            if (QuickReplySheet.Visibility == Visibility.Visible)
            {
                LayOutQuickReplySheet(ActualWidth > 0 ? ActualWidth : SystemParameters.PrimaryScreenWidth);
                ShowLiveControls();
            }
        }

        private void OnQuickReplySheetClose(object sender, RoutedEventArgs e)
        {
            _quickRepliesOpen = false;
            ApplyQuickReplyVisibility();
        }

        private void ApplyLayoutStrings()
        {
            QuickReplySheetTitle.Text = Texts.T("ring.quick_replies");
            QuickReplySheetClose.Content = Texts.T("ui.close");
            AutomationText(QuickReplySheetClose, Texts.T("ui.close"));
            HistoryDetailBack.Content = Texts.T("ui.back");
        }

        private static void AutomationText(FrameworkElement element, string text)
        {
            System.Windows.Automation.AutomationProperties.SetName(element, text ?? "");
        }

        // ---- Live view overlay ------------------------------------------------------------------

        /// <summary>
        /// Monitor-only (live view): the video takes the whole stage and the action zone floats on
        /// a plate over it, hiding after 4 s without input. A ringing call never auto-hides.
        /// </summary>
        private void ApplyLiveOverlayMode()
        {
            bool live = _monitorOnly && IncomingView.Visibility == Visibility.Visible &&
                        !_quickRepliesOpen;
            bool side = IncomingActionColumn.Width.Value > 0;
            _liveOverlayMode = live && !side;
            Grid.SetRowSpan(IncomingStage, _liveOverlayMode ? 2 : 1);
            if (_liveOverlayMode)
            {
                IncomingActionZone.SetResourceReference(Border.BackgroundProperty, "Plate");
                IncomingActionZone.VerticalAlignment = VerticalAlignment.Bottom;
            }
            else
            {
                IncomingActionZone.Background = Brushes.Transparent;
            }
            if (live) ArmLiveOverlayHide();
            else
            {
                if (_liveOverlayTimer != null) _liveOverlayTimer.Stop();
                IncomingActionZone.Visibility = Visibility.Visible;
            }
        }

        private void ArmLiveOverlayHide()
        {
            if (_liveOverlayTimer == null)
            {
                _liveOverlayTimer = new DispatcherTimer { Interval = LayoutMetrics.OverlayAutoHide };
                _liveOverlayTimer.Tick += (s, e) =>
                {
                    _liveOverlayTimer.Stop();
                    if (_monitorOnly && !_quickRepliesOpen &&
                        IncomingView.Visibility == Visibility.Visible)
                        IncomingActionZone.Visibility = Visibility.Hidden;
                };
            }
            IncomingActionZone.Visibility = Visibility.Visible;
            _liveOverlayTimer.Stop();
            _liveOverlayTimer.Start();
        }

        private void ShowLiveControls()
        {
            if (_liveOverlayTimer != null) _liveOverlayTimer.Stop();
            IncomingActionZone.Visibility = Visibility.Visible;
            if (_monitorOnly && !_quickRepliesOpen && IncomingView.Visibility == Visibility.Visible)
                ArmLiveOverlayHide();
        }

        /// <summary>
        /// Any tap on the live view shows the controls again. The tap that reveals hidden
        /// controls is consumed so it cannot land on a button the user has not seen.
        /// </summary>
        private void OnLiveViewInput(object sender, InputEventArgs e)
        {
            if (!_monitorOnly) return;
            bool wasHidden = IncomingActionZone.Visibility != Visibility.Visible;
            ShowLiveControls();
            if (wasHidden) e.Handled = true;
        }

        // ---- History list / detail ---------------------------------------------------------------

        private void ApplyHistoryLayout(SizeClass size)
        {
            bool expanded = size == SizeClass.Expanded;
            if (expanded)
            {
                HistoryListColumn.Width = new GridLength(1, GridUnitType.Star);
                HistoryDetailColumn.Width = new GridLength(1.2, GridUnitType.Star);
                HistoryList.Visibility = Visibility.Visible;
                HistoryDetailPane.Visibility = Visibility.Visible;
                HistoryDetailPane.Margin = new Thickness(LayoutMetrics.S4, LayoutMetrics.S2, 0, LayoutMetrics.S2);
                Grid.SetColumn(HistoryDetailPane, 1);
                HistoryDetailBack.Visibility = Visibility.Collapsed;
            }
            else
            {
                bool detail = _historySelected != null;
                HistoryListColumn.Width = new GridLength(1, GridUnitType.Star);
                HistoryDetailColumn.Width = new GridLength(0);
                Grid.SetColumn(HistoryDetailPane, 0);
                HistoryDetailPane.Margin = new Thickness(0, LayoutMetrics.S2, 0, LayoutMetrics.S2);
                HistoryList.Visibility = detail ? Visibility.Collapsed : Visibility.Visible;
                HistoryDetailPane.Visibility = detail ? Visibility.Visible : Visibility.Collapsed;
                HistoryDetailBack.Visibility = Visibility.Visible;
            }
            RenderHistoryDetail();
        }

        /// <summary>A history row: selectable, ≥ 44 px, unread missed calls marked.</summary>
        private UIElement HistoryRow(Dictionary<string, object> row)
        {
            var grid = BuildCallRow(row, true);
            grid.MinHeight = LayoutMetrics.TouchMin;
            grid.Background = Brushes.Transparent;
            grid.Cursor = Cursors.Hand;
            bool unread = DictStr(row, "outcome") == "missed" && row.ContainsKey("seen") &&
                          row["seen"] is bool && !(bool)row["seen"];
            if (unread)
            {
                var dot = new System.Windows.Shapes.Ellipse
                {
                    Width = 10, Height = 10,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(-14, 6, 0, 0),
                };
                dot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Negative");
                System.Windows.Automation.AutomationProperties.SetName(dot, Texts.T("history.unread"));
                grid.Children.Add(dot);
            }
            grid.MouseLeftButtonUp += (s, e) => SelectHistoryRow(row);
            // The list item is the selection visual; it follows the row whose detail is shown.
            return new ListViewItem
            {
                Content = grid,
                IsSelected = _historySelected != null &&
                             DictStr(_historySelected, "id") == DictStr(row, "id"),
            };
        }

        private void SelectHistoryRow(Dictionary<string, object> row)
        {
            _historySelected = row;
            RenderHistory();
            ApplyHistoryLayout(_sizeClass);
        }

        private void OnHistoryDetailBackClick(object sender, RoutedEventArgs e)
        {
            _historySelected = null;
            ApplyHistoryLayout(_sizeClass);
        }

        private void RenderHistoryDetail()
        {
            HistoryDetail.Children.Clear();
            var row = _historySelected;
            if (row == null)
            {
                HistoryDetail.Children.Add(DetailText(Texts.T("history.detail_empty"), 16, "Muted"));
                return;
            }
            long ts = DictLong(row, "ts", 0);
            HistoryDetail.Children.Add(DetailText(DayOf(ts) + "  " + ClockOf(ts), 26, "OnSurface"));
            HistoryDetail.Children.Add(DetailField(Texts.T("history.detail_door"), DoorLabel(DictStr(row, "door"))));
            string purpose = PurposeLabel(DictStr(row, "purpose"));
            if (purpose.Length != 0)
                HistoryDetail.Children.Add(DetailField(Texts.T("history.detail_purpose"), purpose));
            HistoryDetail.Children.Add(DetailField(Texts.T("history.detail_outcome"),
                                                   OutcomeText(row, DictStr(row, "outcome"))));
            string by = DictStr(row, "answered_by");
            if (by.Length != 0)
                HistoryDetail.Children.Add(DetailField(Texts.T("history.detail_answered_by"), PeerLabel(by)));
            string snapshot = DictStr(row, "snapshot");
            if (snapshot.Length == 64) LoadHistorySnapshot(snapshot);
        }

        private string PeerLabel(string id)
        {
            var name = CoreClient.Dig(_cfg, "devices." + id + ".name");
            return name == null ? id : name.ToString();
        }

        private TextBlock DetailText(string text, double size, string role)
        {
            var block = new TextBlock
            {
                Text = text ?? "",
                FontSize = size * LayoutMetrics.TextScale(),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, LayoutMetrics.S3),
            };
            block.SetResourceReference(TextBlock.ForegroundProperty, role);
            return block;
        }

        private UIElement DetailField(string label, string value)
        {
            var panel = new StackPanel { Margin = new Thickness(0, 0, 0, LayoutMetrics.S3) };
            panel.Children.Add(DetailText(label, 13, "Muted"));
            ((TextBlock)panel.Children[0]).Margin = new Thickness(0);
            panel.Children.Add(DetailText(value, 18, "OnSurface"));
            ((TextBlock)panel.Children[1]).Margin = new Thickness(0, 2, 0, 0);
            return panel;
        }

        /// <summary>The call's snapshot is a Core asset addressed by its SHA-256.</summary>
        private void LoadHistorySnapshot(string hash)
        {
            var row = _historySelected;
            string url = "http://127.0.0.1:" + App.Boot.HttpPort + "/asset/" + hash;
            Task.Run(() =>
            {
                byte[] data = LocalMedia.Download(url, 8000, 8 * 1024 * 1024);
                if (data == null) return;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (!ReferenceEquals(row, _historySelected)) return;
                    try
                    {
                        var bmp = new BitmapImage();
                        bmp.BeginInit();
                        bmp.CacheOption = BitmapCacheOption.OnLoad;
                        bmp.DecodePixelWidth = 960;
                        bmp.StreamSource = new MemoryStream(data);
                        bmp.EndInit();
                        bmp.Freeze();
                        var frame = new Border
                        {
                            CornerRadius = new CornerRadius(LayoutMetrics.CardRadius),
                            ClipToBounds = true,
                            Background = Brushes.Black,
                            Child = new Image { Source = bmp, Stretch = Stretch.Uniform },
                        };
                        HistoryDetail.Children.Insert(1, frame);
                    }
                    catch (Exception) { }
                }));
            });
        }
    }
}
