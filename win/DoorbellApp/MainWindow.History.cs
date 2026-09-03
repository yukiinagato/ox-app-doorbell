using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading.Tasks;
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

        private readonly List<Dictionary<string, object>> _historyRows =
            new List<Dictionary<string, object>>();
        private string _historyFilter = "all";
        private string _historyDoorFilter = "";
        private int _historyLimit = HistoryPageRows;
        private long _historyBeforeMs;
        private bool _historyExhausted;
        private bool _historyLoading;

        /// <summary>Opens the page and moves the seen watermark, which clears the badge.</summary>
        private void OpenHistory()
        {
            _historyFilter = "all";
            _historyDoorFilter = "";
            BuildHistoryDoorFilters();
            HistoryView.Visibility = Visibility.Visible;
            LoadHistoryPage(true, true);
            RenderHistory();
        }

        /// <summary>
        /// One page of 50, read off the UI thread: db_core_call_log_json and its paging variant
        /// are parameterized queries that marshal into core's run loop, so the dispatcher must
        /// never wait on one. With before_ms the next page has an exclusive upper bound; an older
        /// core has none, so the single request grows instead and stops at the 500 rows core
        /// clamps to. markSeen rides along on the same worker so the watermark moves in one hop.
        /// </summary>
        private void LoadHistoryPage(bool reset, bool markSeen = false)
        {
            if (_historyLoading) return;
            _historyLoading = true;
            if (reset)
            {
                _historyRows.Clear();
                _historyBeforeMs = 0;
                _historyExhausted = false;
                _historyLimit = HistoryPageRows;
            }
            bool paging = App.Core.CallLogPagingAvailable;
            long before = _historyBeforeMs;
            int limit = _historyLimit;
            string seenUpTo = _latestCallHlc;
            Task.Run(() =>
            {
                Dictionary<string, object> log = null;
                bool seenMoved = false;
                try
                {
                    if (markSeen) seenMoved = App.Core.CallLogMarkSeen(seenUpTo);
                    log = paging ? App.Core.CallLogPage(0, before, HistoryPageRows)
                                 : App.Core.CallLog(0, limit);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine("call history read failed: " + ex.Message);
                }
                Dictionary<string, object> result = log;
                bool moved = seenMoved;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    _historyLoading = false;
                    ApplyHistoryPage(result, paging, markSeen, moved);
                }));
            });
        }

        private void ApplyHistoryPage(Dictionary<string, object> log, bool paging, bool markSeen,
                                      bool seenMoved)
        {
            var page = Rows(log);
            if (paging)
            {
                _historyRows.AddRange(page);
                long oldest = page.Count == 0 ? 0 : DictLong(page[page.Count - 1], "ts", 0);
                if (page.Count < HistoryPageRows || oldest <= 0) _historyExhausted = true;
                else _historyBeforeMs = oldest;
            }
            else
            {
                _historyRows.Clear();
                _historyRows.AddRange(page);
                _historyExhausted = page.Count < _historyLimit ||
                                    _historyLimit >= HistoryMaxRows;
            }
            if (_historyRows.Count != 0) _latestCallHlc = DictStr(_historyRows[0], "hlc");
            if (markSeen)
            {
                if (!seenMoved) Debug.WriteLine("call-log seen watermark was not moved");
                _unreadMissed = 0;
                MissedBadge.Visibility = Visibility.Collapsed;
            }
            RenderHistory();
        }

        private void OnHistoryCloseClick(object sender, RoutedEventArgs e)
        {
            HistoryView.Visibility = Visibility.Collapsed;
            RequestHomeRefresh(HomeRefresh.History);
        }

        private void OnHistoryMarkSeenClick(object sender, RoutedEventArgs e)
        {
            LoadHistoryPage(true, true);
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
            // Filtering is applied to the pages already loaded; 「さらに読み込む」 fetches more.
            RenderHistory();
        }

        private void OnHistoryMoreClick(object sender, RoutedEventArgs e)
        {
            if (_historyExhausted) return;
            if (!App.Core.CallLogPagingAvailable)
            {
                if (_historyLimit >= HistoryMaxRows) return;
                _historyLimit = Math.Min(HistoryMaxRows, _historyLimit + HistoryPageRows);
            }
            LoadHistoryPage(false);
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
            List<Dictionary<string, object>> rows = _historyRows;
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

            HistoryMoreButton.Visibility = _historyExhausted ?
                Visibility.Collapsed : Visibility.Visible;
            // Only a core without before_ms paging runs into the 500-row ceiling.
            HistoryNote.Visibility = !App.Core.CallLogPagingAvailable && _historyExhausted &&
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
