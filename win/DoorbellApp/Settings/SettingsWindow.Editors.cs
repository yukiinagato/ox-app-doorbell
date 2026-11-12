using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // The native editors that replace every former "Open in Admin" row. Each is selected by
    // SettingItem.Handler on an Editor row and writes through the same Core batch path.
    internal sealed partial class SettingsWindow
    {
        private static readonly Regex DoorIdPattern = new Regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$");
        private static readonly Regex RecordIdPattern = new Regex("^[A-Za-z0-9_-]{1,64}$");
        private static readonly Regex DtmfPattern = new Regex(@"^[0-9*#]{1,8}$");
        private static readonly Regex ExtensionPattern = new Regex(@"^[A-Za-z0-9_.+-]{1,32}$");

        private FrameworkElement BuildEditor(SettingItem item)
        {
            switch (item.Handler)
            {
                case "secret": return BuildSecretRow(item);
                case "buildings": return BuildRecords(item, BuildingSpec());
                case "doors": return BuildRecords(item, DoorSpec());
                case "ui_elements": return BuildRecords(item, UiElementSpec());
                case "households": return BuildRecords(item, HouseholdSpec());
                case "media_sources": return BuildRecords(item, MediaSourceSpec());
                case "dtmf": return BuildRecords(item, DtmfSpec());
                case "rules": return BuildRecords(item, RuleSpec());
                case "quiet_hours": return BuildQuietHours(item);
                case "devices": return BuildDevices(item);
                case "secrets": return BuildSecrets(item);
                case "texts": return BuildTexts(item);
                case "assets_audio":
                case "assets_image":
                case "assets_all": return BuildAssets(item);
                case "bg_image": return BuildBackgroundImage(item);
                case "color": return BuildColor(item);
                case "video_policy": return BuildVideoPolicy(item);
                case "panels": return BuildPanels(item);
                case "backup": return BuildBackup(item);
                case "software_update": return BuildSoftwareUpdate(item);
                case "speech": return BuildSpeech(item);
                case "caps_override": return BuildCapsOverride(item);
                default: return null;
            }
        }

        /// <summary>Adds configuration-derived options (asset sounds, media sources) to a choice.</summary>
        private SettingItem WithConfiguredOptions(SettingItem item)
        {
            var copy = item.Clone();
            if (item.Handler == "sound")
            {
                foreach (var asset in AssetList("audio/"))
                    copy.Options.Add(new SettingOption("asset:" + asset.Key, null,
                        "♪ " + AssetLabel(asset.Key, asset.Value)));
            }
            else if (item.Handler == "time_zone")
            {
                foreach (string zone in TimeSettings.Zones)
                    copy.Options.Add(new SettingOption(zone, null, zone.Replace('_', ' ')));
            }
            else if (item.Handler == "media_source")
            {
                foreach (var pair in ReadRecords("media_sources"))
                    copy.Options.Add(new SettingOption(pair.Key, null, pair.Key));
            }
            return copy;
        }

        // ---- secret rows ----------------------------------------------------------------------

        /// <summary>
        /// One secret: whether it is stored on this device, a password box, Save and Clear. The
        /// value goes to DPAPI and the key receives "secret:&lt;name&gt;"; it is never shown again.
        /// </summary>
        private FrameworkElement BuildSecretRow(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            string reference = _store.Get(item.Key) as string;
            bool stored = !string.IsNullOrEmpty(reference) && App.Core != null &&
                          App.Core.HasSecret(SecretNameOf(reference));
            var status = new TextBlock
            {
                Text = Texts.T(stored ? "settings.secret_stored"
                    : string.IsNullOrEmpty(reference) ? "settings.secret_none" : "settings.secret_missing_here"),
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 6, 0, 0),
            };
            status.SetResourceReference(TextBlock.ForegroundProperty, stored ? "Ok" : "Dim");
            panel.Children.Add(status);
            var line = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal };
            var save = CommandButton(Texts.T("admin.save"));
            var clear = CommandButton(Texts.T("settings.secret_clear"));
            clear.Margin = new Thickness(6, 0, 0, 0);
            DoorbellApp.Ui.Fluent.MakeDestructive(clear);
            clear.IsEnabled = !string.IsNullOrEmpty(reference);
            save.Margin = new Thickness(8, 0, 0, 0);
            buttons.Children.Add(save);
            buttons.Children.Add(clear);
            DockPanel.SetDock(buttons, Dock.Right);
            line.Children.Add(buttons);
            var box = new PasswordBox { FontSize = 16, MinHeight = MinTouchTarget,
                                        Padding = new Thickness(10, 8, 10, 8), MaxLength = 512 };
            AutomationLabel(box, Texts.T(item.LabelKey));
            line.Children.Add(box);
            panel.Children.Add(line);
            panel.Children.Add(parts.Error);
            save.Click += (s, e) =>
            {
                string value = box.Password ?? "";
                if (value.Length == 0) return;
                string target = string.IsNullOrEmpty(reference)
                    ? "secret:" + ExpandSecretName(item.Secret) : reference;
                string failure = ProvisionSecret(target, value);
                box.Clear();
                if (failure != null)
                {
                    Report(new SettingsWriteResult { Error = failure }, parts);
                    return;
                }
                // Rewriting the reference (even unchanged) makes Core reapply the integration.
                if (Report(_store.Set(item.Key, target), parts)) Refresh();
            };
            clear.Click += (s, e) =>
            {
                if (!Confirm(Texts.T("settings.secret_clear_confirm"), true)) return;
                RemoveSecret(reference);
                if (Report(_store.Delete(item.Key), parts)) Refresh();
            };
            return panel;
        }

        /// <summary>Every secret reference in configuration, with its state on this device.</summary>
        private FrameworkElement BuildSecrets(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var found = new SortedDictionary<string, string>(StringComparer.Ordinal);
            CollectSecretRefs(App.Core == null ? null : App.Core.Config(), "", found);
            foreach (var pair in found)
            {
                string reference = pair.Key;
                bool stored = App.Core != null && App.Core.HasSecret(SecretNameOf(reference));
                var set = CommandButton(Texts.T(stored ? "settings.secret_replace" : "settings.secret_enter"));
                set.Click += (s, e) =>
                {
                    var data = new Dictionary<string, object> { { "ref", reference } };
                    var field = Fld("ref", FieldKind.Secret, "settings.secret_value");
                    field.Required = true;
                    if (ShowForm(reference, new List<Field> { field }, data))
                    {
                        ShowStatus(Texts.T("admin.saved"), false);
                        Refresh();
                    }
                };
                panel.Children.Add(ItemLine(reference,
                    pair.Value + " · " + Texts.T(stored ? "settings.secret_stored" : "settings.secret_missing_here"),
                    new[] { set }));
            }
            if (found.Count == 0) panel.Children.Add(EmptyLine("settings.secret_list_empty"));
            panel.Children.Add(parts.Error);
            return panel;
        }

        private static void CollectSecretRefs(object node, string path, IDictionary<string, string> found)
        {
            var map = node as Dictionary<string, object>;
            if (map != null)
            {
                foreach (var pair in map)
                    CollectSecretRefs(pair.Value, path.Length == 0 ? pair.Key : path + "." + pair.Key, found);
                return;
            }
            var text = node as string;
            if (text != null)
            {
                if (text.StartsWith("secret:", StringComparison.Ordinal) && !found.ContainsKey(text) &&
                    text != "secret:mesh.psk")
                    found[text] = path;
                return;
            }
            var list = node as IEnumerable;
            if (list == null) return;
            int index = 0;
            foreach (object child in list) CollectSecretRefs(child, path + "[" + index++ + "]", found);
        }

        // ---- doors, buildings, households -------------------------------------------------------

        private RecordSpec BuildingSpec()
        {
            return new RecordSpec
            {
                Key = "buildings",
                IdPrefix = "b_",
                Fields = () =>
                {
                    var label = Fld("label", FieldKind.Langs, "prefs.label");
                    label.Required = true;
                    label.MaxLength = 64;
                    return new List<Field> { label };
                },
                Title = (id, d) => LabelText(d.ContainsKey("label") ? d["label"] : null, id),
                Subtitle = (id, d) => id,
            };
        }

        private static readonly System.Text.RegularExpressions.Regex UnlockCommandPattern =
            new System.Text.RegularExpressions.Regex("^[A-Za-z0-9_-]{1,32}$");

        private RecordSpec DoorSpec()
        {
            return new RecordSpec
            {
                Key = "doors",
                IdPrefix = null,
                IdLabelKey = "settings.door_id",
                IdPattern = DoorIdPattern,
                Fields = () =>
                {
                    var label = Fld("label", FieldKind.Langs, "prefs.label");
                    label.Required = true;
                    label.MaxLength = 64;
                    var building = Fld("building", FieldKind.Choice, "admin.building_assign");
                    building.Options = BuildingOptions();
                    // doors.<id>.unlock: the command this door's lock answers to, and whether
                    // the unlock control shows (left to Core, always, or never).
                    var command = Fld("unlock.command", FieldKind.Text, "unlock.command");
                    command.HintKey = "unlock.binding_hint";
                    command.MaxLength = 32;
                    command.Store = v => string.IsNullOrWhiteSpace(v as string)
                        ? null : ((string)v).Trim();
                    var show = Fld("unlock.show_button", FieldKind.Choice, "unlock.title");
                    show.Required = true;
                    show.Options = new List<SettingOption>
                    {
                        new SettingOption("auto", "unlock.auto"),
                        new SettingOption("show", "unlock.show"),
                        new SettingOption("hide", "unlock.hide"),
                    };
                    show.Load = v => v is bool ? ((bool)v ? "show" : "hide") : "auto";
                    show.Store = v => (v as string) == "show" ? (object)true
                        : (v as string) == "hide" ? (object)false : null;
                    return new List<Field> { label, building, command, show };
                },
                Validate = (id, draft) =>
                {
                    var unlock = draft.ContainsKey("unlock")
                        ? draft["unlock"] as Dictionary<string, object> : null;
                    if (unlock == null) return null;
                    string command = Str(unlock, "command");
                    if (command.Length != 0 && !UnlockCommandPattern.IsMatch(command))
                        return Texts.T("unlock.command_invalid");
                    // Nothing left to say about unlocking: the key goes away entirely.
                    if (unlock.Count == 0) draft.Remove("unlock");
                    return null;
                },
                Title = (id, d) => LabelText(d.ContainsKey("label") ? d["label"] : null, id),
                Subtitle = (id, d) =>
                {
                    string building = Str(d, "building");
                    string name = building;
                    foreach (var option in BuildingOptions())
                        if ((string)option.Value == building) name = option.Text;
                    return id + (name.Length > 0 ? " · " + name : "");
                },
            };
        }

        private RecordSpec HouseholdSpec()
        {
            return new RecordSpec
            {
                Key = "households",
                IdPrefix = "h_",
                Fields = () =>
                {
                    var label = Fld("label", FieldKind.Langs, "prefs.label");
                    label.Required = true;
                    var chats = Fld("telegram_chat_ids", FieldKind.NumberList, "admin.tg_chat_ids");
                    var extensions = Fld("sip_extensions", FieldKind.List, "admin.sip_extensions");
                    extensions.Pattern = ExtensionPattern;
                    return new List<Field> { label, chats, extensions };
                },
                Title = (id, d) => LabelText(d.ContainsKey("label") ? d["label"] : null, id),
                Subtitle = (id, d) =>
                {
                    var bits = new List<string>();
                    int chats = StringList(d.ContainsKey("telegram_chat_ids") ? d["telegram_chat_ids"] : null).Count;
                    if (chats > 0) bits.Add(Texts.T("settings.household_chats", chats));
                    var ext = StringList(d.ContainsKey("sip_extensions") ? d["sip_extensions"] : null);
                    if (ext.Count > 0) bits.Add(string.Join(", ", ext));
                    return string.Join(" · ", bits);
                },
            };
        }

        // ---- external cameras -------------------------------------------------------------------

        private RecordSpec MediaSourceSpec()
        {
            // The binding is a write on the chosen door station, not part of the source record.
            string bindTo = null;
            return new RecordSpec
            {
                Key = "media_sources",
                IdPrefix = null,
                IdLabelKey = "settings.media_source_id",
                IdPattern = RecordIdPattern,
                Seed = () => new Dictionary<string, object> { { "schema_version", 1L }, { "kind", "ip_camera" } },
                Fields = () =>
                {
                    var mjpeg = Fld("streams.mjpeg.url", FieldKind.Text, "settings.media_mjpeg_url");
                    var snapshot = Fld("streams.snapshot.url", FieldKind.Text, "settings.media_snapshot_url");
                    var h264 = Fld("streams.h264.url", FieldKind.Text, "settings.media_h264_url");
                    var urlPattern = new Regex(@"^(https?|rtsp)://[^@\s/]+(/\S*)?$");
                    mjpeg.Pattern = snapshot.Pattern = h264.Pattern = urlPattern;
                    mjpeg.HintKey = "settings.media_url_hint";
                    var transport = Fld("streams.h264.transport", FieldKind.Choice, "admin.transport");
                    transport.Options = new List<SettingOption>
                        { O2("tcp", "settings.transport_tcp"), O2("udp", "settings.transport_udp") };
                    var secret = Fld("secret_ref", FieldKind.Secret, "settings.media_credential");
                    secret.SecretName = "media." + NewId("x").Substring(3);
                    secret.HintKey = "settings.media_credential_hint";
                    var bind = Fld("_bind", FieldKind.Choice, "settings.media_bind");
                    bind.Options = DeviceOptions("door_station");
                    return new List<Field> { mjpeg, snapshot, h264, transport, secret, bind };
                },
                Validate = (id, d) =>
                {
                    bindTo = Str(d, "_bind");
                    d.Remove("_bind");
                    if (GetPath(d, "streams.mjpeg.url") == null && GetPath(d, "streams.snapshot.url") == null &&
                        GetPath(d, "streams.h264.url") == null)
                        return Texts.T("settings.media_need_url");
                    if (GetPath(d, "streams.h264.url") == null) SetPath(d, "streams.h264.transport", null);
                    return null;
                },
                AfterSave = (id, d) =>
                {
                    if (!string.IsNullOrEmpty(bindTo))
                        Report(_store.Set("devices." + bindTo + ".local.camera.source_ref", id), null);
                },
                Title = (id, d) => id,
                Subtitle = (id, d) =>
                {
                    var kinds = new List<string>();
                    foreach (string stream in new[] { "mjpeg", "snapshot", "h264" })
                        if (GetPath(d, "streams." + stream + ".url") != null) kinds.Add(stream.ToUpperInvariant());
                    var bound = new List<string>();
                    foreach (var pair in ReadRecords("devices"))
                        if (Convert.ToString(GetPath(pair.Value, "local.camera.source_ref")) == id)
                            bound.Add(Str(pair.Value, "name").Length > 0 ? Str(pair.Value, "name") : pair.Key);
                    return string.Join(", ", kinds) + (bound.Count > 0 ? " · " + string.Join(", ", bound) : "");
                },
            };
        }

        private static SettingOption O2(object value, string labelKey)
        {
            return new SettingOption(value, labelKey);
        }

        // ---- SIP DTMF mapping -------------------------------------------------------------------

        private RecordSpec DtmfSpec()
        {
            return new RecordSpec
            {
                Key = "sip.dtmf_actions",
                IdPrefix = null,
                IdLabelKey = "settings.dtmf_code",
                IdPattern = DtmfPattern,
                WholeMap = true,
                Fields = () =>
                {
                    var type = Fld("type", FieldKind.Choice, "settings.dtmf_type");
                    type.Required = true;
                    type.Options = new List<SettingOption>
                    {
                        O2("hangup", "settings.dtmf_hangup"), O2("ha_command", "settings.dtmf_ha_command"),
                        O2("quick_reply", "settings.dtmf_quick_reply"), O2("decline", "settings.dtmf_decline"),
                    };
                    var command = Fld("command", FieldKind.Text, "settings.dtmf_command");
                    command.HintKey = "settings.dtmf_command_hint";
                    var door = Fld("door", FieldKind.Choice, "settings.door");
                    door.Options = new List<SettingOption> { new SettingOption("self", "settings.dtmf_door_self") };
                    door.Options.AddRange(DoorOptions());
                    var reply = Fld("reply_id", FieldKind.Choice, "settings.dtmf_reply");
                    reply.Options = ReplyOptions();
                    return new List<Field> { type, command, door, reply };
                },
                Validate = (id, d) =>
                {
                    string type = Str(d, "type");
                    if (type == "ha_command")
                    {
                        if (Str(d, "command").Length == 0) return Texts.T("settings.dtmf_need_command");
                        if (Str(d, "door").Length == 0) d["door"] = "self";
                    }
                    else
                    {
                        d.Remove("command");
                        d.Remove("door");
                    }
                    if (type == "quick_reply")
                    {
                        if (Str(d, "reply_id").Length == 0) return Texts.T("settings.dtmf_need_reply");
                    }
                    else d.Remove("reply_id");
                    return null;
                },
                Title = (id, d) => id,
                Subtitle = (id, d) =>
                {
                    string type = Str(d, "type");
                    string key = "settings.dtmf_" + (type.Length > 0 ? type : "hangup");
                    string text = Texts.T(key);
                    if (type == "ha_command") text += " · " + Str(d, "command") + " (" + Str(d, "door") + ")";
                    if (type == "quick_reply") text += " · " + Joined(ReplyOptions(), Str(d, "reply_id"));
                    return text;
                },
            };
        }

        // ---- rules --------------------------------------------------------------------------------

        private static readonly string[] RuleTypes =
            { "button", "purpose_selected", "motion", "call_missed", "device_offline", "device_online",
              "emergency_on", "emergency_off" };

        private static readonly string[] ActionTypes =
            { "device_alert", "sip_call", "telegram", "ha_event", "ha_command", "chime", "auto_reply" };

        private static string RuleTypeText(string type)
        {
            string key = "settings.when_" + (type.Length > 0 ? type : "button");
            return Texts.T(key);
        }

        private static string ActionTypeText(string type)
        {
            string key = "settings.act_" + type;
            return Texts.T(key);
        }

        /// <summary>"all" or an explicit list, edited as a list whose first option is "all".</summary>
        private static object AllLoad(object value)
        {
            return value is string && (string)value == "all" ? new List<object> { "all" } : value;
        }

        private static object AllStore(object value)
        {
            var list = StringList(value);
            if (list.Contains("all")) return "all";
            return list.Count == 0 ? null : value;
        }

        private static object EmptyToNull(object value)
        {
            return StringList(value).Count == 0 ? null : value;
        }

        private RecordSpec RuleSpec()
        {
            return new RecordSpec
            {
                Key = "trigger_rules",
                IdPrefix = "r_",
                Seed = () => new Dictionary<string, object>
                {
                    { "enabled", true },
                    { "when", new Dictionary<string, object> { { "type", "button" } } },
                    { "schedule", new Dictionary<string, object> { { "always", true } } },
                    { "actions", new List<object>() },
                },
                Edit = EditRule,
                Title = (id, d) => RuleTypeText(Convert.ToString(GetPath(d, "when.type") ?? "")) + " · " + id,
                Subtitle = (id, d) =>
                {
                    var bits = new List<string>();
                    if (!SettingsStore.AsBool(d.ContainsKey("enabled") ? d["enabled"] : null, true))
                        bits.Add(Texts.T("admin.disabled"));
                    var actions = d.ContainsKey("actions") ? d["actions"] as IEnumerable : null;
                    var names = new List<string>();
                    if (actions != null)
                        foreach (object action in actions)
                        {
                            var map = action as Dictionary<string, object>;
                            if (map != null) names.Add(ActionTypeText(Str(map, "type")));
                        }
                    bits.Add(names.Count == 0 ? Texts.T("settings.rule_no_actions") : string.Join(", ", names));
                    return string.Join(" · ", bits);
                },
            };
        }

        private bool EditRule(string id, Dictionary<string, object> data, bool isNew)
        {
            var type = Fld("when.type", FieldKind.Choice, "admin.rule_when");
            type.Required = true;
            type.Options = new List<SettingOption>();
            foreach (string t in RuleTypes) type.Options.Add(new SettingOption(t, "settings.when_" + t));
            var doors = Fld("when.doors", FieldKind.Multi, "admin.rule_doors");
            doors.Options = DoorOptions();
            doors.Store = EmptyToNull;
            doors.HintKey = "settings.rule_doors_hint";
            var purposes = Fld("when.purposes", FieldKind.Multi, "admin.purposes");
            purposes.Options = PurposeOptions();
            purposes.Store = EmptyToNull;
            purposes.HintKey = "settings.rule_purposes_hint";
            var devices = Fld("when.devices", FieldKind.Multi, "admin.rule_devices");
            devices.Options = new List<SettingOption> { new SettingOption("all", "admin.all") };
            devices.Options.AddRange(DeviceOptions());
            devices.Load = AllLoad;
            devices.Store = AllStore;
            devices.HintKey = "settings.rule_devices_hint";
            var always = Fld("schedule.always", FieldKind.Bool, "admin.always");
            var windows = Fld("schedule.windows", FieldKind.Windows, "admin.windows");
            windows.Store = EmptyToNull;
            var fields = new List<Field> { Fld("enabled", FieldKind.Bool, "admin.enabled"), type, doors,
                                           purposes, devices, always, windows };
            string title = Texts.T(isNew ? "admin.add_rule" : "prefs.rule_edit") + " · " + id;
            return ShowForm(title, fields, data, draft =>
            {
                if (SettingsStore.AsBool(GetPath(draft, "schedule.always"), false))
                    SetPath(draft, "schedule.windows", null);
                else
                {
                    SetPath(draft, "schedule.always", null);
                    if (GetPath(draft, "schedule.windows") == null)
                        return Texts.T("settings.rule_need_schedule");
                }
                return null;
            }, BuildActionsEditor);
        }

        /// <summary>The rule's actions as an ordered list inside the rule form.</summary>
        private Func<Dictionary<string, object>, string> BuildActionsEditor(
            StackPanel form, Dictionary<string, object> rule)
        {
            var actions = new List<Dictionary<string, object>>();
            var raw = rule.ContainsKey("actions") ? rule["actions"] as IEnumerable : null;
            if (raw != null)
                foreach (object action in raw)
                {
                    var map = action as Dictionary<string, object>;
                    if (map != null) actions.Add(DeepCopy(map));
                }
            form.Children.Add(FieldLabel(Texts.T("admin.actions")));
            var list = new StackPanel();
            form.Children.Add(list);
            Action render = null;
            render = () =>
            {
                list.Children.Clear();
                for (int i = 0; i < actions.Count; i++)
                {
                    int index = i;
                    var up = MoveButton(true);
                    var down = MoveButton(false);
                    var edit = CommandButton(Texts.T("admin.edit"));
                    var remove = CommandButton(Texts.T("admin.delete"));
                    DoorbellApp.Ui.Fluent.MakeDestructive(remove);
                    AutomationLabel(up, Texts.T("settings.move_up"));
                    AutomationLabel(down, Texts.T("settings.move_down"));
                    up.IsEnabled = index > 0;
                    down.IsEnabled = index < actions.Count - 1;
                    up.Click += (s, e) => { Swap(actions, index, index - 1); render(); };
                    down.Click += (s, e) => { Swap(actions, index, index + 1); render(); };
                    edit.Click += (s, e) => { if (EditAction(actions[index])) render(); };
                    remove.Click += (s, e) => { actions.RemoveAt(index); render(); };
                    list.Children.Add(ItemLine(ActionTypeText(Str(actions[index], "type")),
                        ActionSummary(actions[index]), new[] { up, down, edit, remove }));
                }
                if (actions.Count == 0) list.Children.Add(EmptyLine("settings.rule_no_actions"));
            };
            render();
            var add = CommandButton(Texts.T("admin.add_action"));
            add.HorizontalAlignment = HorizontalAlignment.Left;
            add.Margin = new Thickness(0, 8, 0, 0);
            add.Click += (s, e) =>
            {
                var pick = new Dictionary<string, object> { { "type", "device_alert" } };
                var type = Fld("type", FieldKind.Choice, "settings.action_type");
                type.Required = true;
                type.Options = new List<SettingOption>();
                foreach (string t in ActionTypes) type.Options.Add(new SettingOption(t, "settings.act_" + t));
                if (!ShowForm(Texts.T("admin.add_action"), new List<Field> { type }, pick)) return;
                var action = new Dictionary<string, object> { { "type", Str(pick, "type") } };
                if (Str(pick, "type") == "device_alert")
                {
                    action["targets"] = new Dictionary<string, object> { { "roles", "all" } };
                    action["channels"] = new List<object> { "in_app", "system_notification" };
                    action["presentation"] = new Dictionary<string, object> { { "visual", true } };
                }
                if (!EditAction(action)) return;
                actions.Add(action);
                render();
            };
            form.Children.Add(add);
            return draft =>
            {
                var array = new List<object>();
                foreach (var action in actions) array.Add(action);
                draft["actions"] = array;
                return null;
            };
        }

        private static void Swap<T>(List<T> list, int a, int b)
        {
            if (a < 0 || b < 0 || a >= list.Count || b >= list.Count) return;
            T first = list[a];
            list[a] = list[b];
            list[b] = first;
        }

        private string ActionSummary(Dictionary<string, object> action)
        {
            var bits = new List<string>();
            switch (Str(action, "type"))
            {
                case "sip_call": bits.Add(Str(action, "target_extension")); break;
                case "telegram":
                {
                    object households = action.ContainsKey("households") ? action["households"] : null;
                    bits.Add(households as string == "all" ? Texts.T("admin.all")
                                                           : Joined(HouseholdOptions(), households));
                    break;
                }
                case "ha_command": bits.Add(Str(action, "command")); break;
                case "chime": bits.Add(Joined(DeviceOptions(), action.ContainsKey("devices") ? action["devices"] : null)); break;
                case "auto_reply": bits.Add(Joined(ReplyOptions(), Str(action, "reply_id"))); break;
                case "device_alert":
                {
                    object roles = GetPath(action, "targets.roles");
                    bits.Add(roles as string == "all" ? Texts.T("admin.all") : string.Join(", ", StringList(roles)));
                    break;
                }
            }
            if (SettingsStore.AsBool(action.ContainsKey("never_suppress") ? action["never_suppress"] : null, false))
                bits.Add(Texts.T("admin.never_suppress"));
            bits.RemoveAll(string.IsNullOrEmpty);
            return string.Join(" · ", bits);
        }

        private bool EditAction(Dictionary<string, object> action)
        {
            string type = Str(action, "type");
            var fields = new List<Field>();
            switch (type)
            {
                case "sip_call":
                {
                    var ext = Fld("target_extension", FieldKind.Text, "admin.target_ext");
                    ext.Required = true;
                    ext.Pattern = ExtensionPattern;
                    fields.Add(ext);
                    break;
                }
                case "telegram":
                {
                    var households = Fld("households", FieldKind.Multi, "admin.households");
                    households.Options = new List<SettingOption> { new SettingOption("all", "admin.all") };
                    households.Options.AddRange(HouseholdOptions());
                    households.Load = AllLoad;
                    households.Store = AllStore;
                    households.Required = true;
                    fields.Add(households);
                    fields.Add(Fld("with_snapshot", FieldKind.Bool, "admin.with_snapshot"));
                    break;
                }
                case "ha_command":
                {
                    var command = Fld("command", FieldKind.Text, "settings.dtmf_command");
                    command.Required = true;
                    var door = Fld("door", FieldKind.Choice, "settings.door");
                    door.Options = new List<SettingOption> { new SettingOption("self", "settings.dtmf_door_self") };
                    door.Options.AddRange(DoorOptions());
                    fields.Add(command);
                    fields.Add(door);
                    break;
                }
                case "chime":
                {
                    var devices = Fld("devices", FieldKind.Multi, "admin.rule_devices");
                    devices.Options = DeviceOptions("indoor_panel");
                    devices.Required = true;
                    var sound = Fld("sound", FieldKind.Choice, "admin.sound");
                    sound.Options = SoundOptions();
                    fields.Add(devices);
                    fields.Add(sound);
                    break;
                }
                case "auto_reply":
                {
                    var reply = Fld("reply_id", FieldKind.Choice, "settings.dtmf_reply");
                    reply.Options = ReplyOptions();
                    reply.Required = true;
                    fields.Add(reply);
                    break;
                }
                case "device_alert":
                {
                    var roles = Fld("targets.roles", FieldKind.Multi, "admin.alert_target_roles");
                    roles.Options = new List<SettingOption>
                    {
                        new SettingOption("all", "admin.all"),
                        new SettingOption("indoor_panel", "admin.role_indoor"),
                        new SettingOption("door_station", "admin.role_door"),
                    };
                    roles.Load = AllLoad;
                    roles.Store = AllStore;
                    var devices = Fld("targets.devices", FieldKind.Multi, "admin.alert_target_devices");
                    devices.Options = DeviceOptions();
                    devices.Store = EmptyToNull;
                    var channels = Fld("channels", FieldKind.Multi, "admin.alert_channels");
                    channels.Options = new List<SettingOption>
                    {
                        new SettingOption("in_app", "admin.channel_in_app"),
                        new SettingOption("system_notification", "admin.channel_system_notification"),
                        new SettingOption("web_push", "admin.channel_web_push"),
                    };
                    channels.Required = true;
                    var ttl = Fld("presentation.ttl_s", FieldKind.Number, "admin.alert_ttl");
                    ttl.Min = 0;
                    ttl.Max = 86400;
                    var sound = Fld("presentation.sound", FieldKind.Choice, "admin.alert_sound");
                    sound.Options = SoundOptions();
                    var volume = Fld("presentation.volume", FieldKind.Number, "admin.alert_volume");
                    volume.Min = 0;
                    volume.Max = 100;
                    fields.AddRange(new[] { roles, devices, channels,
                        Fld("presentation.visual", FieldKind.Bool, "admin.alert_visual"),
                        Fld("presentation.sticky", FieldKind.Bool, "admin.alert_sticky"), ttl, sound, volume,
                        Fld("presentation.background", FieldKind.Color, "admin.alert_background"),
                        Fld("presentation.foreground", FieldKind.Color, "admin.alert_foreground"),
                        Fld("presentation.accent", FieldKind.Color, "admin.alert_accent") });
                    break;
                }
            }
            var bypass = Fld("never_suppress", FieldKind.Bool, "admin.never_suppress");
            bypass.HintKey = "settings.never_suppress_hint";
            fields.Add(bypass);
            return ShowForm(ActionTypeText(type), fields, action, draft =>
            {
                if (type == "device_alert" && GetPath(draft, "targets.roles") == null &&
                    GetPath(draft, "targets.devices") == null)
                    return Texts.T("settings.alert_need_target");
                return null;
            });
        }

        private List<SettingOption> SoundOptions()
        {
            var options = new List<SettingOption>
            {
                new SettingOption("school_chime", "sound.school_chime"),
                new SettingOption("ding1", "settings.sound_ding1"),
                new SettingOption("ding2", "settings.sound_ding2"),
                new SettingOption("classic", "settings.sound_classic"),
                new SettingOption("siren1", "prefs.sound_siren1"),
            };
            foreach (var asset in AssetList("audio/"))
                options.Add(new SettingOption("asset:" + asset.Key, null, "♪ " + AssetLabel(asset.Key, asset.Value)));
            return options;
        }

        // ---- quiet hours -----------------------------------------------------------------------

        private static readonly string[] QuietActionTypes =
            { "chime", "device_alert", "sip_call", "telegram", "ha_event", "ha_command", "auto_reply" };

        private FrameworkElement BuildQuietHours(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var edit = CommandButton(Texts.T("admin.edit"));
            DockPanel.SetDock(edit, Dock.Right);
            head.Children.Insert(0, edit);
            var current = _store.Get("quiet_hours.default") as Dictionary<string, object>;
            var lines = new List<string>();
            var windows = current == null ? null : current.ContainsKey("windows") ? current["windows"] as IEnumerable : null;
            if (windows != null)
                foreach (object w in windows)
                {
                    var map = w as Dictionary<string, object>;
                    if (map == null) continue;
                    var days = StringList(map.ContainsKey("days") ? map["days"] : null);
                    var dayText = new List<string>();
                    foreach (string day in days) dayText.Add(Texts.T("day." + day));
                    lines.Add(Str(map, "from") + "–" + Str(map, "to") +
                              (dayText.Count > 0 ? " (" + string.Join(" ", dayText) + ")" : ""));
                }
            var summary = new TextBlock
            {
                Text = lines.Count == 0 ? Texts.T("settings.quiet_none") : string.Join("\n", lines),
                FontSize = 15,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 8, 0, 0),
            };
            panel.Children.Add(summary);
            panel.Children.Add(parts.Error);
            edit.Click += (s, e) =>
            {
                var data = current == null ? new Dictionary<string, object>
                {
                    { "windows", new List<object> { new Dictionary<string, object> { { "from", "23:00" }, { "to", "07:00" } } } },
                    { "suppress", new List<object> { "chime" } },
                } : DeepCopy(current);
                var suppress = Fld("suppress", FieldKind.Multi, "admin.suppress");
                var never = Fld("never_suppress", FieldKind.Multi, "admin.never_suppress");
                suppress.Options = new List<SettingOption>();
                foreach (string t in QuietActionTypes) suppress.Options.Add(new SettingOption(t, "settings.act_" + t));
                never.Options = new List<SettingOption>(suppress.Options);
                never.HintKey = "settings.quiet_never_hint";
                var fields = new List<Field> { Fld("windows", FieldKind.Windows, "admin.windows"), suppress, never };
                if (!ShowForm(Texts.T("admin.quiet_hours"), fields, data)) return;
                if (Report(_store.Set("quiet_hours.default", data), parts)) Refresh();
            };
            return panel;
        }

        // ---- devices -----------------------------------------------------------------------------

        private FrameworkElement BuildDevices(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var devices = ReadRecords("devices");
            var ids = new List<string>(devices.Keys);
            ids.Sort((a, b) => string.Compare(Str(devices[a], "name"), Str(devices[b], "name"),
                                              StringComparison.CurrentCulture));
            foreach (string id in ids)
            {
                var data = devices[id];
                bool self = id == _store.Context.NodeId;
                string name = Str(data, "name");
                string role = Str(data, "role");
                var bits = new List<string>
                {
                    Texts.T(role == "door_station" ? "admin.role_door" : "admin.role_indoor"),
                };
                if (role == "door_station" && Str(data, "door").Length > 0)
                    bits.Add(Joined(DoorOptions(), Str(data, "door")));
                if (Str(data, "platform").Length > 0) bits.Add(Str(data, "platform"));
                bits.Add(id.Length > 12 ? id.Substring(0, 12) + "…" : id);
                if (self) bits.Insert(0, Texts.T("settings.this_device"));
                var buttons = new List<Button>();
                if (!self)
                {
                    var settings = CommandButton(Texts.T("settings.device_settings"));
                    AutomationId(settings, "DeviceSettings_" + id);
                    settings.Click += (s, e) => EditDeviceSettings(id, role);
                    buttons.Add(settings);
                }
                var edit = CommandButton(Texts.T("admin.edit"));
                edit.IsEnabled = !self;
                if (self) AutomationLabel(edit, Texts.T("settings.device_self_hint"));
                edit.Click += (s, e) => EditPeer(id, data, parts);
                buttons.Add(edit);
                var remove = CommandButton(Texts.T("admin.remove_device"));
                DoorbellApp.Ui.Fluent.MakeDestructive(remove);
                remove.IsEnabled = !self;
                remove.Click += (s, e) => RemovePeer(id, name.Length > 0 ? name : id, parts);
                buttons.Add(remove);
                panel.Children.Add(ItemLine(name.Length > 0 ? name : id, string.Join(" · ", bits), buttons));
            }
            if (ids.Count == 0) panel.Children.Add(EmptyLine());
            panel.Children.Add(FieldHint(Texts.T("settings.device_self_hint")));
            panel.Children.Add(parts.Error);
            return panel;
        }

        /// <summary>
        /// Another device's desired identity. The target validates it, rewrites its boot.json
        /// and restarts; until then peers keep using its live advertisement.
        /// </summary>
        private void EditPeer(string id, Dictionary<string, object> data, RowParts parts)
        {
            var draft = new Dictionary<string, object>
            {
                { "name", Str(data, "name") }, { "role", Str(data, "role") }, { "door", Str(data, "door") },
            };
            var name = Fld("name", FieldKind.Text, "admin.dev_name");
            name.Required = true;
            name.MaxLength = 64;
            var role = Fld("role", FieldKind.Choice, "admin.dev_role");
            role.Required = true;
            role.Options = new List<SettingOption>
            {
                new SettingOption("indoor_panel", "admin.role_indoor"),
                new SettingOption("door_station", "admin.role_door"),
            };
            var door = Fld("door", FieldKind.Choice, "admin.door_assign");
            door.Options = DoorOptions();
            door.HintKey = "settings.device_door_hint";
            if (!ShowForm(Str(data, "name").Length > 0 ? Str(data, "name") : id,
                          new List<Field> { name, role, door }, draft, d =>
                              Str(d, "role") == "door_station" && !DoorIdPattern.IsMatch(Str(d, "door"))
                                  ? Texts.T("admin.door_required") : null))
                return;
            bool door_station = Str(draft, "role") == "door_station";
            // A role or door edit restarts the app on that device (it applies the replicated
            // identity), so it is confirmed by name first. A rename alone is not.
            bool identityChanged = Str(draft, "role") != Str(data, "role") ||
                (door_station && Str(draft, "door") != Str(data, "door"));
            if (identityChanged && !Confirm(Texts.T("settings.peer_identity_confirm",
                    Str(draft, "name").Length > 0 ? Str(draft, "name") : id), true)) return;
            var sets = new List<KeyValuePair<string, object>>
            {
                new KeyValuePair<string, object>("devices." + id + ".name", Str(draft, "name")),
                new KeyValuePair<string, object>("devices." + id + ".role", Str(draft, "role")),
            };
            var deletes = new List<string>();
            if (door_station) sets.Add(new KeyValuePair<string, object>("devices." + id + ".door", Str(draft, "door")));
            else if (data.ContainsKey("door") && data["door"] != null) deletes.Add("devices." + id + ".door");
            if (Report(_store.Commit(sets, deletes), parts)) Refresh();
        }

        private void RemovePeer(string id, string name, RowParts parts)
        {
            if (!Confirm(Texts.T("admin.remove_device_confirm", name), true)) return;
            int rc = App.Core == null ? -4 : App.Core.RemoveDevice(id);
            string message;
            switch (rc)
            {
                case 0:
                    ShowStatus(Texts.T("admin.removed"), false);
                    _store.Reload();
                    Refresh();
                    return;
                case -1: message = Texts.T("settings.remove_invalid"); break;
                case -2: message = Texts.T("settings.remove_role"); break;
                case -3: message = Texts.T("settings.remove_persist"); break;
                case -20: message = Texts.T("settings.err_admin_required"); break;
                default: message = Texts.T("settings.err_core_unavailable"); break;
            }
            Report(new SettingsWriteResult { Error = message }, parts);
        }

        // ---- appearance colour ------------------------------------------------------------------

        private FrameworkElement BuildColor(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            string current = Convert.ToString(_store.Effective(item) ?? "");
            var line = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
            var swatch = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(8),
                                      BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 10, 0) };
            swatch.SetResourceReference(Border.BorderBrushProperty, "Line");
            Action<string> paint = text =>
            {
                try
                {
                    swatch.Background = ColorPattern.IsMatch(text ?? "")
                        ? new System.Windows.Media.SolidColorBrush(
                            (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(text))
                        : null;
                }
                catch { swatch.Background = null; }
            };
            paint(current);
            DockPanel.SetDock(swatch, Dock.Left);
            line.Children.Add(swatch);
            var pick = CommandButton(Texts.T("settings.color_pick"));
            pick.Margin = new Thickness(8, 0, 0, 0);
            DockPanel.SetDock(pick, Dock.Right);
            line.Children.Add(pick);
            var box = FormTextBox(current, 7);
            AutomationLabel(box, Texts.T(item.LabelKey));
            line.Children.Add(box);
            panel.Children.Add(line);
            panel.Children.Add(parts.Error);
            Action<string> commit = text =>
            {
                text = (text ?? "").Trim().ToUpperInvariant();
                if (text == current.ToUpperInvariant()) return;
                if (!ColorPattern.IsMatch(text))
                {
                    Report(new SettingsWriteResult { Error = Texts.T("prefs.invalid_color") }, parts);
                    box.Text = current;
                    return;
                }
                if (Write(item, text, parts))
                {
                    current = text;
                    box.Text = text;
                    paint(text);
                }
                else box.Text = current;
            };
            pick.Click += (s, e) =>
            {
                string chosen = PickColor(box.Text);
                if (chosen != null) commit(chosen);
            };
            box.LostKeyboardFocus += (s, e) => commit(box.Text);
            box.KeyDown += (s, e) => { if (e.Key == System.Windows.Input.Key.Enter) commit(box.Text); };
            return panel;
        }
    }
}
