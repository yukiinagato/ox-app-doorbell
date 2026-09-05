using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// Indoor dashboard (spec 4.1, page A): door tiles with five-second stills and an
    /// announcement chip, the scrollable recent-call list, and the missed-call badge.
    /// </summary>
    public partial class MainWindow
    {
        private const int RecentCallRows = 20;

        /// <summary>Rebuilds the tile grid from the door stations core knows about.</summary>
        /// <summary>
        /// Renders the tiles from the status document the coalescer already read. It never takes
        /// its own: one refresh means one status document, shared by every consumer.
        /// </summary>
        private void RefreshDoorTiles(Dictionary<string, object> status)
        {
            if (App.Boot.Role != "indoor_panel") { _tileRefresh.Stop(); return; }
            var peers = status != null && status.ContainsKey("peers") ?
                status["peers"] as System.Collections.IEnumerable : null;
            var doors = new List<string>();
            var online = new Dictionary<string, bool>(StringComparer.Ordinal);
            var streams = new Dictionary<string, string>(StringComparer.Ordinal);
            if (peers != null)
                foreach (object raw in peers)
                {
                    var peer = raw as Dictionary<string, object>;
                    if (peer == null || DictStr(peer, "role") != "door_station") continue;
                    // A door station with no camera has nothing to watch, so it gets no tile. It
                    // stays reachable through the monitor list and still takes announcements.
                    if (!PeerHasCamera(peer)) continue;
                    string door = DictStr(peer, "door");
                    if (string.IsNullOrEmpty(door) || doors.Contains(door)) continue;
                    doors.Add(door);
                    online[door] = DictStr(peer, "status") != "dead";
                    streams[door] = DictStr(peer, "stream");
                }

            DoorsSectionTitle.Text = Texts.T("dash.doors") + " · " + doors.Count;
            bool sameDoors = doors.Count == _tileDoors.Count;
            if (sameDoors)
                for (int i = 0; i < doors.Count; i++)
                    if (doors[i] != _tileDoors[i]) { sameDoors = false; break; }
            if (!sameDoors)
            {
                _tileDoors.Clear();
                _tileDoors.AddRange(doors);
                _tileImages.Clear();
                _tileNoticeChips.Clear();
                _tileLabels.Clear();
                _tilePlaceholders.Clear();
                _tileDots.Clear();
                _tileRotations.Clear();
                DoorTileGrid.Children.Clear();
                foreach (string door in doors) DoorTileGrid.Children.Add(BuildDoorTile(door));
                if (doors.Count == 0)
                    DoorTileGrid.Children.Add(new TextBlock
                    {
                        Text = Texts.T("dash.no_doors"),
                        FontSize = 18,
                        Margin = new Thickness(10),
                        Foreground = (Brush)FindResource("Dim"),
                    });
            }

            _tileSnapshotUrls.Clear();
            foreach (string door in doors)
            {
                string stream;
                if (!streams.TryGetValue(door, out stream) || string.IsNullOrEmpty(stream))
                    continue;
                // The peer projection publishes .../stream.mjpeg on the same origin as the
                // snapshot endpoint, so the still URL is derived instead of guessed.
                int cut = stream.LastIndexOf("/stream.mjpeg", StringComparison.Ordinal);
                if (cut <= 0) continue;
                _tileSnapshotUrls[door] = stream.Substring(0, cut) + "/snapshot.jpg";
            }

            foreach (string door in doors)
            {
                bool up;
                if (!online.TryGetValue(door, out up)) up = false;
                Image image;
                // A door station that is gone keeps its last still, dimmed, and says so.
                if (_tileImages.TryGetValue(door, out image)) image.Opacity = up ? 1.0 : 0.35;
                if (!up) _tileSnapshotUrls.Remove(door);
                TilePlaceholder placeholder;
                if (_tilePlaceholders.TryGetValue(door, out placeholder))
                {
                    bool hasStill = image != null && image.Source != null;
                    placeholder.Show(!up ? "IconCameraOff" : "IconPhoto",
                                     !up ? Texts.T("dash.tile_offline") : Texts.T("dash.tile_no_still"),
                                     !up || !hasStill);
                }
                Ellipse dot;
                if (_tileDots.TryGetValue(door, out dot))
                    dot.SetResourceReference(Shape.FillProperty, up ? "Ok" : "Dim");
                RefreshTileNoticeChip(door);
            }

            // Tile captions were just created; their bounds exist only after the next layout.
            QueueInkPass();
            if (doors.Count != 0 && DashboardHome.Visibility == Visibility.Visible)
            {
                if (!_tileRefresh.IsEnabled) _tileRefresh.Start();
                RefreshDoorTileStills();
            }
            else _tileRefresh.Stop();
        }

        /// <summary>
        /// caps.camera says whether a peer can show live video. Only an explicit false hides the
        /// tile: a shell that does not advertise the capability at all still gets one.
        /// </summary>
        private static bool PeerHasCamera(Dictionary<string, object> peer)
        {
            object value = CoreClient.Dig(peer, "caps.camera");
            return !(value is bool) || (bool)value;
        }

        /// <summary>
        /// The cluster, door-station and indoor-panel counters. status.peers carries every device
        /// including this one; a mesh that has not listed us yet is counted from the boot profile
        /// so the total is never short by one.
        /// </summary>
        private void RefreshDeviceCounters()
        {
            var peers = _status != null && _status.ContainsKey("peers") ?
                _status["peers"] as System.Collections.IEnumerable : null;
            int total = 0, doorsOnline = 0, doorsTotal = 0, panelsOnline = 0, panelsTotal = 0;
            bool sawSelf = false;
            if (peers != null)
                foreach (object raw in peers)
                {
                    var peer = raw as Dictionary<string, object>;
                    if (peer == null || string.IsNullOrEmpty(DictStr(peer, "id"))) continue;
                    bool self = DictBool(peer, "self");
                    if (self) sawSelf = true;
                    // This device is plainly reachable from itself, whatever gossip says.
                    bool online = self || DictStr(peer, "status") != "dead";
                    total++;
                    CountRole(DictStr(peer, "role"), online, ref doorsOnline, ref doorsTotal,
                              ref panelsOnline, ref panelsTotal);
                }
            if (!sawSelf)
            {
                total++;
                CountRole(App.Boot.Role, true, ref doorsOnline, ref doorsTotal,
                          ref panelsOnline, ref panelsTotal);
            }

            ClusterCountText.Text = Texts.T("dash.count_devices", total);
            int onlineTotal = doorsOnline + panelsOnline + (total - doorsTotal - panelsTotal);
            int offline = total - onlineTotal;
            ClusterOnlineText.Text = Texts.T("pair.membership_connected", onlineTotal) +
                (offline > 0 ? " · " + offline + " " + Texts.T("dash.tile_offline") : "");
            ClusterOnlineText.SetResourceReference(TextBlock.ForegroundProperty,
                                                   offline > 0 ? "Warn" : "Ok");
            DoorCountText.Text = doorsOnline + "/" + doorsTotal;
            PanelCountText.Text = panelsOnline + "/" + panelsTotal;
            AutomationProperties.SetName(ClusterCounter, Texts.T("dash.count_cluster", total));
            AutomationProperties.SetName(DoorCounter,
                Texts.T("dash.count_doors", doorsOnline, doorsTotal));
            AutomationProperties.SetName(PanelCounter,
                Texts.T("dash.count_panels", panelsOnline, panelsTotal));
        }

        private static void CountRole(string role, bool online, ref int doorsOnline,
                                      ref int doorsTotal, ref int panelsOnline,
                                      ref int panelsTotal)
        {
            if (role == "door_station")
            {
                doorsTotal++;
                if (online) doorsOnline++;
            }
            else if (role == "indoor_panel")
            {
                panelsTotal++;
                if (online) panelsOnline++;
            }
        }

        /// <summary>The icon + caption shown in a tile's media area instead of a still.</summary>
        private sealed class TilePlaceholder
        {
            public StackPanel Root;
            public System.Windows.Shapes.Path Icon;
            public TextBlock Text;
            public void Show(string iconKey, string text, bool visible)
            {
                Icon.Data = (Geometry)Application.Current.FindResource(iconKey);
                Text.Text = text;
                Root.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            }
        }

        private readonly Dictionary<string, TilePlaceholder> _tilePlaceholders =
            new Dictionary<string, TilePlaceholder>(StringComparer.Ordinal);
        private readonly Dictionary<string, Ellipse> _tileDots =
            new Dictionary<string, Ellipse>(StringComparer.Ordinal);
        private readonly Dictionary<string, int> _tileRotations =
            new Dictionary<string, int>(StringComparer.Ordinal);

        private Border BuildDoorTile(string door)
        {
            var image = new Image
            {
                Stretch = Stretch.UniformToFill,
                Opacity = 1.0,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            _tileImages[door] = image;

            var placeholderIcon = new System.Windows.Shapes.Path
            {
                Data = (Geometry)FindResource("IconPhoto"),
                StrokeThickness = 1.6,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                StrokeLineJoin = PenLineJoin.Round,
            };
            placeholderIcon.SetResourceReference(Shape.StrokeProperty, "Dim");
            var placeholderText = new TextBlock
            {
                Text = Texts.T("dash.tile_no_still"),
                FontSize = 15,
                Margin = new Thickness(0, 10, 0, 0),
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            placeholderText.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
            var placeholderRoot = new StackPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            placeholderRoot.Children.Add(new Viewbox { Width = 40, Height = 40, Child = placeholderIcon });
            placeholderRoot.Children.Add(placeholderText);
            _tilePlaceholders[door] = new TilePlaceholder
            { Root = placeholderRoot, Icon = placeholderIcon, Text = placeholderText };

            var noticeChip = new Border
            {
                Background = (Brush)FindResource("Notice"),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12, 6, 12, 6),
                Margin = new Thickness(8),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Visibility = Visibility.Collapsed,
                Cursor = Cursors.Hand,
                Tag = door,
                Child = new TextBlock
                {
                    Text = Texts.T("notice.chip") + " · " + Texts.T("notice.active"),
                    FontSize = 12,
                    Foreground = Brushes.White,
                },
            };
            noticeChip.MouseLeftButtonDown += OnTileNoticeChipClick;
            _tileNoticeChips[door] = noticeChip;

            // Media area: a 16:10 window that a rotated still fills (UniformToFill), the
            // placeholder in front until a still arrives, the notice chip on top.
            var media = new Grid { ClipToBounds = true, MinHeight = 150 };
            media.SetBinding(FrameworkElement.HeightProperty, new System.Windows.Data.Binding("ActualWidth")
            {
                RelativeSource = System.Windows.Data.RelativeSource.Self,
                Converter = new ScaleConverter(0.62),
            });
            media.Children.Add(image);
            media.Children.Add(placeholderRoot);
            media.Children.Add(noticeChip);
            var mediaFrame = new Border
            {
                CornerRadius = new CornerRadius(14, 14, 0, 0),
                ClipToBounds = true,
                Child = media,
            };
            mediaFrame.SetResourceReference(Border.BackgroundProperty, "Row");

            var caption = new Grid { Margin = new Thickness(14, 10, 14, 10) };
            var labels = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var dot = new Ellipse
            {
                Width = 8, Height = 8,
                Margin = new Thickness(0, 0, 8, 0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            dot.SetResourceReference(Shape.FillProperty, "Dim");
            _tileDots[door] = dot;
            labels.Children.Add(dot);
            var title = new TextBlock
            {
                Text = DoorLabel(door),
                FontSize = 17,
                FontWeight = FontWeights.Bold,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource("Fg"),
            };
            _tileLabels.Add(title);
            labels.Children.Add(title);
            var watch = new TextBlock
            {
                Text = Texts.T("dash.tile_watch") + " ›",
                FontSize = 15,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
            };
            watch.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
            caption.Children.Add(labels);
            caption.Children.Add(watch);

            var body = new StackPanel();
            body.Children.Add(mediaFrame);
            body.Children.Add(caption);

            var plate = new Border { CornerRadius = new CornerRadius(16), Child = body };
            plate.SetResourceReference(Border.BackgroundProperty, "Plate");
            var tile = new Border
            {
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(16),
                Margin = new Thickness(4, 4, 8, 12),
                VerticalAlignment = VerticalAlignment.Top,
                ClipToBounds = true,
                Cursor = Cursors.Hand,
                Tag = door,
                Child = plate,
            };
            tile.SetResourceReference(Border.BorderBrushProperty, "PlateLine");
            Ui.Frost.SetEnabled(tile, true);
            tile.MouseLeftButtonDown += OnDoorTileClick;
            return tile;
        }

        /// <summary>Height = width × factor, for the tile's media window.</summary>
        private sealed class ScaleConverter : System.Windows.Data.IValueConverter
        {
            private readonly double _factor;
            public ScaleConverter(double factor) { _factor = factor; }
            public object Convert(object value, Type targetType, object parameter,
                                  System.Globalization.CultureInfo culture)
            {
                double width = value is double ? (double)value : 0;
                return width > 0 ? width * _factor : 150.0;
            }
            public object ConvertBack(object value, Type targetType, object parameter,
                                      System.Globalization.CultureInfo culture)
            {
                return System.Windows.Data.Binding.DoNothing;
            }
        }

        private void OnDoorTileClick(object sender, MouseButtonEventArgs e)
        {
            var tile = sender as Border;
            string door = tile == null ? null : tile.Tag as string;
            if (string.IsNullOrEmpty(door)) return;
            ShowIncoming(new UiEvent
            {
                T = "monitor",
                Data = new Dictionary<string, object> { { "door", door } },
            }, true);
        }

        /// <summary>Pulls one still per door station; the timer runs every five seconds.</summary>
        private void RefreshDoorTileStills()
        {
            if (DashboardHome.Visibility != Visibility.Visible ||
                IdleView.Visibility != Visibility.Visible || _screensaverOn) return;
            foreach (KeyValuePair<string, string> entry in _tileSnapshotUrls)
            {
                string door = entry.Key;
                string url = entry.Value;
                if (string.IsNullOrEmpty(url) || _tileFetching.Contains(door)) continue;
                _tileFetching.Add(door);
                Task.Run(() =>
                {
                    byte[] jpeg = null;
                    int rotation = -1;
                    try
                    {
                        using (var client = new System.Net.WebClient())
                        {
                            jpeg = client.DownloadData(url);
                            // The still is the raw sensor frame; the station says how it is held.
                            string meta = client.DownloadString(
                                url.Substring(0, url.Length - "/snapshot.jpg".Length) + "/video-meta");
                            var m = System.Text.RegularExpressions.Regex.Match(meta, "\"rotation\"\\s*:\\s*(-?\\d+)");
                            if (m.Success) rotation = ((int.Parse(m.Groups[1].Value) % 360) + 360) % 360;
                        }
                    }
                    catch (Exception ex)
                    {
                        System.Diagnostics.Debug.WriteLine("door still unavailable: " +
                                                           ex.Message);
                    }
                    BitmapImage bitmap = jpeg == null ? null :
                        MjpegStreamer.Decode(jpeg, App.SafeMode ? 320 : 640);
                    Dispatcher.BeginInvoke(new Action(() =>
                    {
                        _tileFetching.Remove(door);
                        Image target;
                        if (bitmap == null || !_tileImages.TryGetValue(door, out target)) return;
                        target.Source = bitmap;
                        target.Opacity = 1.0;
                        if (rotation >= 0) _tileRotations[door] = rotation;
                        int degrees;
                        if (_tileRotations.TryGetValue(door, out degrees))
                            target.LayoutTransform = degrees == 0 ? Transform.Identity
                                                                  : new RotateTransform(degrees);
                        TilePlaceholder placeholder;
                        if (_tilePlaceholders.TryGetValue(door, out placeholder))
                            placeholder.Root.Visibility = Visibility.Collapsed;
                    }));
                });
            }
        }

        private void OnMissedBadgeClick(object sender, MouseButtonEventArgs e)
        {
            OpenHistory();
        }

        private void OnOpenHistoryClick(object sender, RoutedEventArgs e)
        {
            OpenHistory();
        }

        /// <summary>
        /// Reads the newest rows for the dashboard list and the missed badge. The badge clears
        /// when the full history page is opened, which is what moves the seen watermark.
        /// </summary>
        /// <summary>
        /// Renders the dashboard list from a call log already read off the UI thread.
        /// db_core_call_log_json marshals into core's run loop, so it never runs on the
        /// dispatcher.
        /// </summary>
        private void RefreshCallHistory(Dictionary<string, object> log)
        {
            if (App.Boot.Role != "indoor_panel") return;
            RecentCallsList.Children.Clear();
            var rows = log == null ? null : Rows(log);
            if (rows == null || rows.Count == 0)
            {
                RecentCallsList.Children.Add(new TextBlock
                {
                    Text = Texts.T("history.empty"),
                    FontSize = 14,
                    Margin = new Thickness(2, 8, 2, 8),
                    Foreground = (Brush)FindResource("Dim"),
                });
            }
            else
            {
                _latestCallHlc = DictStr(rows[0], "hlc");
                string lastDay = null;
                foreach (Dictionary<string, object> row in rows)
                {
                    string day = DayLabelOf(DictLong(row, "ts", 0));
                    if (day != lastDay)
                    {
                        lastDay = day;
                        var header = new TextBlock
                        {
                            Text = day,
                            FontSize = 13,
                            Margin = new Thickness(2, 8, 2, 4),
                        };
                        header.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
                        RecentCallsList.Children.Add(header);
                    }
                    RecentCallsList.Children.Add(BuildCallRow(row, false));
                }
            }
            _unreadMissed = log == null ? 0 : DictInt(log, "unread_missed", 0);
            MissedBadgeText.Text = Texts.T("history.missed_badge", _unreadMissed);
            MissedBadge.Visibility = _unreadMissed > 0 ?
                Visibility.Visible : Visibility.Collapsed;
        }

        private static List<Dictionary<string, object>> Rows(Dictionary<string, object> log)
        {
            var result = new List<Dictionary<string, object>>();
            object raw;
            if (log == null || !log.TryGetValue("rows", out raw) ||
                !(raw is System.Collections.IEnumerable) || raw is string) return result;
            foreach (object item in (System.Collections.IEnumerable)raw)
            {
                var row = item as Dictionary<string, object>;
                if (row != null) result.Add(row);
            }
            return result;
        }

        /// <summary>One history line: time, door and purpose, then the outcome.</summary>
        /// <summary>Today / yesterday / a date, for the day headers in the call lists.</summary>
        private string DayLabelOf(long tsMs)
        {
            if (tsMs <= 0) return "";
            DateTime when = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)
                .AddMilliseconds(tsMs).ToLocalTime().Date;
            DateTime today = CorrectedNow().Date;
            if (when == today) return Texts.T("history.today");
            if (when == today.AddDays(-1)) return Texts.T("history.yesterday");
            return when.ToString("M月d日");
        }

        private Grid BuildCallRow(Dictionary<string, object> row, bool detailed)
        {
            var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
            grid.ColumnDefinitions.Add(new ColumnDefinition
            { Width = new GridLength(64) });
            grid.ColumnDefinitions.Add(new ColumnDefinition
            { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition
            { Width = GridLength.Auto });

            string outcome = DictStr(row, "outcome");
            bool missed = outcome == "missed";
            var time = new TextBlock
            {
                Text = ClockOf(DictLong(row, "ts", 0)),
                FontSize = detailed ? 16 : 14,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource(missed ? "Danger" : "Dim"),
            };
            Grid.SetColumn(time, 0);
            grid.Children.Add(time);

            // Two deliberate lines rather than an ellipsis: the door, then the purpose smaller
            // and muted underneath it when there is one.
            string door = DoorLabel(DictStr(row, "door"));
            string purpose = PurposeLabel(DictStr(row, "purpose"));
            var what = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            what.Children.Add(new TextBlock
            {
                Text = door,
                FontSize = detailed ? 16 : 14,
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)FindResource("Fg"),
            });
            if (purpose.Length != 0)
                what.Children.Add(new TextBlock
                {
                    Text = purpose,
                    FontSize = detailed ? 13 : 11,
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = (Brush)FindResource("Dim"),
                });
            Grid.SetColumn(what, 1);
            grid.Children.Add(what);

            // Outcome pill: missed calls in the danger colour, everything else on a quiet pill.
            var resultText = new TextBlock
            {
                Text = OutcomeText(row, outcome),
                FontSize = detailed ? 14 : 13,
                VerticalAlignment = VerticalAlignment.Center,
            };
            resultText.SetResourceReference(TextBlock.ForegroundProperty, missed ? "OnDanger" : "Fg");
            var result = new Border
            {
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(10, 4, 10, 4),
                Margin = new Thickness(8, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Child = resultText,
            };
            result.SetResourceReference(Border.BackgroundProperty, missed ? "Danger" : "Row");
            Grid.SetColumn(result, 2);
            grid.Children.Add(result);
            // Hairline under each row, as on the kiosk list.
            var rule = new Border { Height = 1, VerticalAlignment = VerticalAlignment.Bottom,
                                    Margin = new Thickness(0, 0, 0, -4) };
            rule.SetResourceReference(Border.BackgroundProperty, "PlateLine");
            Grid.SetColumnSpan(rule, 3);
            grid.Children.Add(rule);
            return grid;
        }

        private string OutcomeText(Dictionary<string, object> row, string outcome)
        {
            string label;
            switch (outcome)
            {
                case "answered": label = Texts.T("history.outcome_answered"); break;
                case "replied": label = Texts.T("history.outcome_replied"); break;
                case "missed": label = Texts.T("history.outcome_missed"); break;
                case "cancelled": label = Texts.T("history.outcome_cancelled"); break;
                default: label = outcome ?? ""; break;
            }
            long duration = DictLong(row, "duration_ms", 0);
            if (outcome == "answered" && duration > 0)
            {
                long totalSeconds = duration / 1000;
                label += " · " + Texts.T("history.duration",
                    (totalSeconds / 60) + ":" + (totalSeconds % 60).ToString("00"));
            }
            return label;
        }

        private string PurposeLabel(string purpose)
        {
            if (string.IsNullOrEmpty(purpose)) return "";
            var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
            var entry = purposes != null && purposes.ContainsKey(purpose)
                ? purposes[purpose] as Dictionary<string, object> : null;
            return LabelOf(entry, Texts.Lang, purpose);
        }

        /// <summary>
        /// Renders a stored wall-clock instant in the cluster time zone, from the same cached
        /// base the clock uses. A history page must not make one call into core per row.
        /// </summary>
        private string ClockOf(long wallMs)
        {
            return wallMs <= 0 ? "" : InZone(wallMs).ToString("HH:mm");
        }

        private string DayOf(long wallMs)
        {
            return wallMs <= 0 ? "" : InZone(wallMs).ToString("yyyy-MM-dd");
        }
    }
}
