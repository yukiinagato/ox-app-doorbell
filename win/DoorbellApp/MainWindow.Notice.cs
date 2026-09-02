using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// Announcements (spec 4.3 and 5.2). A door-specific notice wins over the global one; the
    /// three entry points are the dashboard button, the door tile chip, and the chip on the
    /// incoming/monitor screen.
    /// </summary>
    public partial class MainWindow
    {
        /// <summary>Effective notice for one door: door-specific first, then notice.global.</summary>
        private Dictionary<string, object> EffectiveNotice(string door)
        {
            if (!string.IsNullOrEmpty(door))
            {
                var specific = CoreClient.Dig(_cfg, "doors." + door + ".notice")
                    as Dictionary<string, object>;
                if (NoticeText(specific).Length != 0) return specific;
            }
            var global = CoreClient.Dig(_cfg, "notice.global") as Dictionary<string, object>;
            return NoticeText(global).Length == 0 ? null : global;
        }

        private static string NoticeText(Dictionary<string, object> notice)
        {
            return notice == null ? "" : DictStr(notice, "text");
        }

        private bool DoorHasOwnNotice(string door)
        {
            if (string.IsNullOrEmpty(door)) return false;
            return NoticeText(CoreClient.Dig(_cfg, "doors." + door + ".notice")
                as Dictionary<string, object>).Length != 0;
        }

        /// <summary>Repaints the visitor card, the call-screen chip and the tile chips.</summary>
        private void RefreshNoticeSurfaces()
        {
            if (App.Boot.Role == "door_station")
            {
                // The visitor sees the text only: no source line and no expiry (spec 5.1).
                string text = NoticeText(EffectiveNotice(App.Boot.Door));
                VisitorNoticeText.Text = text;
                VisitorNoticeCard.Visibility = text.Length == 0 ?
                    Visibility.Collapsed : Visibility.Visible;
            }
            else
            {
                VisitorNoticeCard.Visibility = Visibility.Collapsed;
            }
            foreach (string door in _tileDoors) RefreshTileNoticeChip(door);
            RefreshCallNoticeChip();
        }

        private void RefreshTileNoticeChip(string door)
        {
            Border chip;
            if (!_tileNoticeChips.TryGetValue(door, out chip)) return;
            chip.Visibility = NoticeText(EffectiveNotice(door)).Length == 0 ?
                Visibility.Collapsed : Visibility.Visible;
        }

        private void RefreshCallNoticeChip()
        {
            if (CallOverlay.Visibility != Visibility.Visible) return;
            bool active = NoticeText(EffectiveNotice(_noticeChipDoor)).Length != 0;
            NoticeChipDot.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
            if (NoticePopover.Visibility == Visibility.Visible) RenderNoticePopover();
        }

        private void OnTileNoticeChipClick(object sender, MouseButtonEventArgs e)
        {
            var chip = sender as Border;
            string door = chip == null ? null : chip.Tag as string;
            if (string.IsNullOrEmpty(door)) return;
            e.Handled = true;  // Do not also open the monitor view behind the chip.
            OpenNoticeDialog(door);
        }

        private void OnGlobalNoticeClick(object sender, RoutedEventArgs e)
        {
            OpenNoticeDialog("");
        }

        private void OnNoticeChipClick(object sender, MouseButtonEventArgs e)
        {
            if (NoticePopover.Visibility == Visibility.Visible)
            {
                NoticePopover.Visibility = Visibility.Collapsed;
                return;
            }
            RenderNoticePopover();
            NoticePopover.Visibility = Visibility.Visible;
        }

        private void RenderNoticePopover()
        {
            var notice = EffectiveNotice(_noticeChipDoor);
            string text = NoticeText(notice);
            NoticePopoverText.Text = text.Length == 0 ? Texts.T("notice.none") : text;
            bool doorSpecific = DoorHasOwnNotice(_noticeChipDoor);
            NoticePopoverTarget.Text = Texts.T("notice.target") + ": " +
                (doorSpecific ? Texts.T("notice.target_door", DoorLabel(_noticeChipDoor))
                              : Texts.T("notice.target_global"));
            NoticeClearButton.Visibility = text.Length == 0 ?
                Visibility.Collapsed : Visibility.Visible;
        }

        private void OnNoticePopoverCloseClick(object sender, RoutedEventArgs e)
        {
            NoticePopover.Visibility = Visibility.Collapsed;
        }

        private void OnNoticeEditClick(object sender, RoutedEventArgs e)
        {
            NoticePopover.Visibility = Visibility.Collapsed;
            OpenNoticeDialog(_noticeChipDoor);
        }

        private void OnNoticeClearClick(object sender, RoutedEventArgs e)
        {
            NoticePopover.Visibility = Visibility.Collapsed;
            ClearNotice(_noticeChipDoor);
        }

        /// <summary>
        /// Clearing a door that only shows the global announcement clears the global one, which is
        /// what the operator sees on screen.
        /// </summary>
        private void ClearNotice(string door)
        {
            bool ok = DoorHasOwnNotice(door)
                ? App.Core.ClearDoorNotice(door)
                : ClearGlobalNotice();
            ShowCallMessage(Texts.T(ok ? "notice.cleared" : "notice.failed"));
            RefreshConfigCache();
            RefreshNoticeSurfaces();
        }

        private bool ClearGlobalNotice()
        {
            bool ok = false;
            foreach (string door in AllDoorIds()) ok |= App.Core.ClearDoorNotice(door);
            return ok;
        }

        private List<string> AllDoorIds()
        {
            var doors = CoreClient.Dig(_cfg, "doors") as Dictionary<string, object>;
            var ids = new List<string>();
            if (doors != null) ids.AddRange(doors.Keys);
            foreach (string door in _tileDoors) if (!ids.Contains(door)) ids.Add(door);
            if (!string.IsNullOrEmpty(App.Boot.Door) && !ids.Contains(App.Boot.Door))
                ids.Add(App.Boot.Door);
            return ids;
        }

        /// <summary>Opens the announcement dialog with the given door preselected.</summary>
        private void OpenNoticeDialog(string door)
        {
            var doors = new List<KeyValuePair<string, string>>();
            foreach (string id in AllDoorIds())
                doors.Add(new KeyValuePair<string, string>(id, DoorLabel(id)));
            var existing = EffectiveNotice(string.IsNullOrEmpty(door) ? _noticeChipDoor : door);
            var dialog = new NoticeDialog(doors, door, NoticeText(existing), NoticePresets())
            {
                Owner = this,
                Topmost = Topmost,
            };
            if (dialog.ShowDialog() != true) return;

            bool ok;
            if (dialog.ClearRequested)
            {
                ok = string.IsNullOrEmpty(dialog.TargetDoor)
                    ? ClearGlobalNotice() : App.Core.ClearDoorNotice(dialog.TargetDoor);
            }
            else if (string.IsNullOrEmpty(dialog.TargetDoor))
            {
                // "Everywhere" writes the same announcement to every door; a door-specific value
                // still wins wherever an operator sets one later.
                ok = false;
                foreach (string id in AllDoorIds())
                    ok |= App.Core.SetDoorNotice(id, dialog.NoticeBody, dialog.ExpiresMs);
            }
            else
            {
                ok = App.Core.SetDoorNotice(dialog.TargetDoor, dialog.NoticeBody,
                                            dialog.ExpiresMs);
            }
            RefreshConfigCache();
            RefreshNoticeSurfaces();
            RefreshDoorTiles();
            if (!ok) MessageBox.Show(this, Texts.T("notice.failed"), Texts.T("notice.title"),
                                     MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        /// <summary>Administrator-editable preset texts (notice.presets), at most eight.</summary>
        private List<string> NoticePresets()
        {
            var presets = new List<string>();
            var raw = CoreClient.Dig(_cfg, "notice.presets") as System.Collections.IEnumerable;
            if (raw != null && !(raw is string))
                foreach (object item in raw)
                {
                    var entry = item as Dictionary<string, object>;
                    string text = entry != null ? DictStr(entry, "text") :
                        (item == null ? "" : item.ToString());
                    if (!string.IsNullOrEmpty(text) && presets.Count < 8) presets.Add(text);
                }
            if (presets.Count == 0)
            {
                presets.Add(Texts.T("notice.preset_absent"));
                presets.Add(Texts.T("notice.preset_delivery"));
                presets.Add(Texts.T("notice.preset_construction"));
            }
            return presets;
        }
    }
}
