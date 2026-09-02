using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
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
        private void RefreshDoorTiles()
        {
            if (App.Boot.Role != "indoor_panel") { _tileRefresh.Stop(); return; }
            var status = App.Core.Status();
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
                    string door = DictStr(peer, "door");
                    if (string.IsNullOrEmpty(door) || doors.Contains(door)) continue;
                    doors.Add(door);
                    online[door] = DictStr(peer, "status") != "dead";
                    streams[door] = DictStr(peer, "stream");
                }

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
                // A door station that is gone keeps its last still, dimmed.
                if (_tileImages.TryGetValue(door, out image)) image.Opacity = up ? 1.0 : 0.35;
                if (!up) _tileSnapshotUrls.Remove(door);
                RefreshTileNoticeChip(door);
            }

            if (doors.Count != 0 && DashboardHome.Visibility == Visibility.Visible)
            {
                if (!_tileRefresh.IsEnabled) _tileRefresh.Start();
                RefreshDoorTileStills();
            }
            else _tileRefresh.Stop();
        }

        private Border BuildDoorTile(string door)
        {
            var image = new Image
            {
                Stretch = Stretch.UniformToFill,
                MinHeight = 120,
                Opacity = 1.0,
            };
            _tileImages[door] = image;

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

            var media = new Grid { MinHeight = 120 };
            media.Children.Add(image);
            media.Children.Add(noticeChip);

            var caption = new Grid { Margin = new Thickness(10, 8, 10, 8) };
            var labels = new StackPanel { HorizontalAlignment = HorizontalAlignment.Left };
            labels.Children.Add(new TextBlock
            {
                Text = DoorLabel(door),
                FontSize = 17,
                FontWeight = FontWeights.Bold,
                Foreground = (Brush)FindResource("Fg"),
            });
            var watch = new TextBlock
            {
                Text = Texts.T("dash.tile_watch") + " ›",
                FontSize = 14,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource("Accent"),
            };
            caption.Children.Add(labels);
            caption.Children.Add(watch);

            var body = new StackPanel();
            body.Children.Add(media);
            body.Children.Add(caption);

            var tile = new Border
            {
                Background = (Brush)FindResource("Card"),
                BorderBrush = (Brush)FindResource("Line"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(12),
                Margin = new Thickness(5),
                Cursor = Cursors.Hand,
                Tag = door,
                Child = body,
            };
            tile.MouseLeftButtonDown += OnDoorTileClick;
            return tile;
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
                    try
                    {
                        using (var client = new System.Net.WebClient())
                            jpeg = client.DownloadData(url);
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
        private void RefreshCallHistory()
        {
            if (App.Boot.Role != "indoor_panel") return;
            var log = App.Core.CallLog(0, RecentCallRows);
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
                foreach (Dictionary<string, object> row in rows)
                    RecentCallsList.Children.Add(BuildCallRow(row, false));
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
        private Grid BuildCallRow(Dictionary<string, object> row, bool detailed)
        {
            var grid = new Grid { Margin = new Thickness(0, 5, 0, 5) };
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
                Foreground = (Brush)FindResource(missed ? "Danger" : "Dim"),
            };
            Grid.SetColumn(time, 0);
            grid.Children.Add(time);

            string door = DoorLabel(DictStr(row, "door"));
            string purpose = PurposeLabel(DictStr(row, "purpose"));
            var what = new TextBlock
            {
                Text = purpose.Length == 0 ? door : door + " · " + purpose,
                FontSize = detailed ? 16 : 14,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = (Brush)FindResource("Fg"),
            };
            Grid.SetColumn(what, 1);
            grid.Children.Add(what);

            var result = new TextBlock
            {
                Text = OutcomeText(row, outcome),
                FontSize = detailed ? 15 : 13,
                Margin = new Thickness(8, 0, 0, 0),
                Foreground = (Brush)FindResource(missed ? "Danger" : "Dim"),
            };
            Grid.SetColumn(result, 2);
            grid.Children.Add(result);
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

        /// <summary>Renders a stored wall-clock instant with the cluster's own clock.</summary>
        private string ClockOf(long wallMs)
        {
            if (wallMs <= 0) return "";
            var local = App.Core.LocalTime(wallMs);
            if (local != null)
            {
                int hour = DictInt(local, "hh", -1);
                int minute = DictInt(local, "mm", -1);
                if (hour >= 0 && minute >= 0)
                    return hour.ToString("00") + ":" + minute.ToString("00");
            }
            return new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(wallMs)
                .ToLocalTime().ToString("HH:mm");
        }

        private string DayOf(long wallMs)
        {
            if (wallMs <= 0) return "";
            var local = App.Core.LocalTime(wallMs);
            string date = local == null ? "" : DictStr(local, "date");
            if (!string.IsNullOrEmpty(date)) return date;
            return new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(wallMs)
                .ToLocalTime().ToString("yyyy-MM-dd");
        }
    }
}
