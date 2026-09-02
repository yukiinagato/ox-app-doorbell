using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// Full-screen call history (spec 5.1): 50 rows per page behind 「さらに読み込む」, filters for
    /// all / missed / one door, grouped by day, and mark-seen on open.
    /// </summary>
    public partial class MainWindow
    {
        private const int HistoryPageRows = 50;
        // db_core_call_log_json clamps limit to 500; paging deeper is a web-admin job.
        private const int HistoryMaxRows = 500;

        private string _historyFilter = "all";
        private string _historyDoorFilter = "";
        private int _historyLimit = HistoryPageRows;

        /// <summary>Opens the page and moves the seen watermark, which clears the badge.</summary>
        private void OpenHistory()
        {
            _historyFilter = "all";
            _historyDoorFilter = "";
            _historyLimit = HistoryPageRows;
            BuildHistoryDoorFilters();
            HistoryView.Visibility = Visibility.Visible;
            MarkHistorySeen();
            RenderHistory();
        }

        private void OnHistoryCloseClick(object sender, RoutedEventArgs e)
        {
            HistoryView.Visibility = Visibility.Collapsed;
            RefreshCallHistory();
        }

        private void OnHistoryMarkSeenClick(object sender, RoutedEventArgs e)
        {
            MarkHistorySeen();
            RenderHistory();
        }

        private void MarkHistorySeen()
        {
            if (!App.Core.CallLogMarkSeen(_latestCallHlc))
                System.Diagnostics.Debug.WriteLine("call-log seen watermark was not moved");
            _unreadMissed = 0;
            MissedBadge.Visibility = Visibility.Collapsed;
        }

        private void OnHistoryFilterClick(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            string tag = button == null ? null : button.Tag as string;
            if (tag == null) return;
            if (tag == "all" || tag == "missed")
            {
                _historyFilter = tag;
                _historyDoorFilter = "";
            }
            else
            {
                _historyFilter = "door";
                _historyDoorFilter = tag;
            }
            _historyLimit = HistoryPageRows;
            RenderHistory();
        }

        private void OnHistoryMoreClick(object sender, RoutedEventArgs e)
        {
            if (_historyLimit >= HistoryMaxRows) return;
            _historyLimit = Math.Min(HistoryMaxRows, _historyLimit + HistoryPageRows);
            RenderHistory();
        }

        private void BuildHistoryDoorFilters()
        {
            HistoryDoorFilters.Children.Clear();
            foreach (string door in AllDoorIds())
            {
                var button = new Button
                {
                    Content = DoorLabel(door),
                    Tag = door,
                    Style = (Style)FindResource("ChipButton"),
                    BorderBrush = (Brush)FindResource("Line"),
                };
                button.Click += OnHistoryFilterClick;
                HistoryDoorFilters.Children.Add(button);
            }
        }

        private void RenderHistory()
        {
            HistoryList.Children.Clear();
            var log = App.Core.CallLog(0, _historyLimit);
            var rows = Rows(log);
            if (rows.Count != 0) _latestCallHlc = DictStr(rows[0], "hlc");

            HighlightHistoryFilters();

            string day = null;
            int shown = 0;
            foreach (Dictionary<string, object> row in rows)
            {
                string outcome = DictStr(row, "outcome");
                if (_historyFilter == "missed" && outcome != "missed") continue;
                if (_historyFilter == "door" &&
                    DictStr(row, "door") != _historyDoorFilter) continue;
                string rowDay = DayOf(DictLong(row, "ts", 0));
                if (rowDay != day)
                {
                    day = rowDay;
                    HistoryList.Children.Add(new TextBlock
                    {
                        Text = rowDay,
                        FontSize = 14,
                        FontWeight = FontWeights.Bold,
                        Margin = new Thickness(0, 14, 0, 4),
                        Foreground = (Brush)FindResource("Dim"),
                    });
                }
                HistoryList.Children.Add(BuildCallRow(row, true));
                shown++;
            }
            if (shown == 0)
                HistoryList.Children.Add(new TextBlock
                {
                    Text = Texts.T("history.empty"),
                    FontSize = 16,
                    Margin = new Thickness(0, 16, 0, 0),
                    Foreground = (Brush)FindResource("Dim"),
                });

            bool exhausted = rows.Count < _historyLimit || _historyLimit >= HistoryMaxRows;
            HistoryMoreButton.Visibility = exhausted ?
                Visibility.Collapsed : Visibility.Visible;
            HistoryNote.Visibility = _historyLimit >= HistoryMaxRows &&
                rows.Count >= HistoryMaxRows ? Visibility.Visible : Visibility.Collapsed;
        }

        private void HighlightHistoryFilters()
        {
            SetFilterSelected(HistoryFilterAll, _historyFilter == "all");
            SetFilterSelected(HistoryFilterMissed, _historyFilter == "missed");
            foreach (object child in HistoryDoorFilters.Children)
            {
                var button = child as Button;
                if (button == null) continue;
                SetFilterSelected(button, _historyFilter == "door" &&
                                          (button.Tag as string) == _historyDoorFilter);
            }
        }

        private void SetFilterSelected(Button button, bool selected)
        {
            button.Background = selected ?
                (Brush)FindResource("Accent") : (Brush)FindResource("Card");
            button.Foreground = selected ?
                (Brush)FindResource("OnAccent") : (Brush)FindResource("Fg");
        }
    }
}
