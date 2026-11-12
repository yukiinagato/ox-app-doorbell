using System.Collections.Generic;

namespace DoorbellApp.Settings
{
    /// <summary>
    /// The Windows settings inventory. Every setting an administrator can change is a native
    /// control here (docs: native-settings spec, zero web-only rows): file uploads use the
    /// Windows file dialog and the Core asset ledger, secrets go to DPAPI with "secret:" config
    /// references, and rules, devices, doors, panels and imports have structured editors.
    /// </summary>
    internal static class SettingsCatalog
    {
        private const string Self = "devices.{self}";
        private const string Local = "devices.{self}.local";

        public static List<SettingCategory> Build()
        {
            var all = new List<SettingCategory>
            {
                Device(), Sound(), Display(), Calls(), Replies(), Purposes(), Notices(),
                Emergency(), Rules(), Camera(), Sip(), Integrations(), Time(), Pairing(),
                Places(), Wording(), Backup(), Kiosk(), About(),
            };
            return all;
        }

        // ---- builders -----------------------------------------------------------------------

        private static SettingCategory Category(string id, string icon)
        {
            return new SettingCategory { Id = id, TitleKey = "settings.cat_" + id, IconKey = icon };
        }

        private static SettingGroup Group(SettingCategory category, string titleKey)
        {
            var group = new SettingGroup { TitleKey = titleKey };
            category.Groups.Add(group);
            return group;
        }

        private static SettingItem Add(SettingGroup group, SettingItem item)
        {
            // Destructive actions stay at the bottom of their section whatever the call order.
            int at = group.Items.Count;
            if (!item.Destructive)
                while (at > 0 && group.Items[at - 1].Destructive) at--;
            group.Items.Insert(at, item);
            return item;
        }

        private static SettingItem Destructive(SettingItem item)
        {
            item.Destructive = true;
            return item;
        }

        private static SettingItem Toggle(string id, string key, bool def, SettingScope scope)
        {
            var item = SettingItem.Make(id, SettingKind.Toggle, key);
            item.Default = def;
            item.Scope = scope;
            return item;
        }

        private static SettingItem Slider(string id, string key, double min, double max,
                                          double step, double def, SettingScope scope,
                                          string unit = null)
        {
            var item = SettingItem.Make(id, SettingKind.Slider, key);
            item.Min = min;
            item.Max = max;
            item.Step = step;
            item.Default = def;
            item.Scope = scope;
            item.UnitKey = unit;
            return item;
        }

        private static SettingItem Stepper(string id, string key, double min, double max,
                                           double step, double def, SettingScope scope,
                                           string unit = null)
        {
            var item = Slider(id, key, min, max, step, def, scope, unit);
            item.Kind = SettingKind.Stepper;
            return item;
        }

        private static SettingItem Choice(string id, string key, object def, SettingScope scope,
                                          params SettingOption[] options)
        {
            var item = SettingItem.Make(id, SettingKind.Choice, key);
            item.Default = def;
            item.Scope = scope;
            item.Options = new List<SettingOption>(options);
            return item;
        }

        private static SettingItem Multi(string id, string key, SettingScope scope,
                                         params SettingOption[] options)
        {
            var item = Choice(id, key, null, scope, options);
            item.Kind = SettingKind.MultiChoice;
            return item;
        }

        private static SettingItem Text(string id, string key, string def, SettingScope scope)
        {
            var item = SettingItem.Make(id, SettingKind.Text, key);
            item.Default = def;
            item.Scope = scope;
            return item;
        }

        private static SettingItem TimeOfDay(string id, string key, string def, SettingScope scope)
        {
            var item = Text(id, key, def, scope);
            item.Kind = SettingKind.Time;
            return item;
        }

        private static SettingItem Action(string id, string handler)
        {
            var item = SettingItem.Make(id, SettingKind.Action, null);
            item.Handler = handler;
            item.Scope = SettingScope.Local;
            return item;
        }

        private static SettingItem Info(string id, string handler)
        {
            var item = SettingItem.Make(id, SettingKind.Info, null);
            item.Handler = handler;
            item.Scope = SettingScope.Local;
            return item;
        }

        /// <summary>A full-width native editor; its description is settings.&lt;id&gt;_native.</summary>
        private static SettingItem Editor(string id, string handler, string key = null)
        {
            var item = SettingItem.Make(id, SettingKind.Editor, key);
            item.Handler = handler;
            item.DescriptionKey = "settings." + id + "_native";
            return item;
        }

        private static SettingItem Secret(string id, string key, string secretName, SettingScope scope)
        {
            var item = Editor(id, "secret", key);
            item.Secret = secretName;
            item.Scope = scope;
            return item;
        }

        private static SettingItem SoundChoice(SettingItem item)
        {
            item.Handler = "sound";
            return item;
        }

        private static SettingItem ListEditor(string id, string key, string editor)
        {
            var item = SettingItem.Make(id, SettingKind.ListEditor, key);
            item.Handler = editor;
            return item;
        }

        private static SettingOption O(object value, string labelKey)
        {
            return new SettingOption(value, labelKey);
        }

        private static SettingItem Describe(SettingItem item)
        {
            item.DescriptionKey = item.LabelKey + "_desc";
            return item;
        }

        private static SettingOption[] Sounds(string bundled)
        {
            return new[] { O(bundled, "sound." + bundled), O("", "sound.none") };
        }

        // ---- categories ---------------------------------------------------------------------

        private static SettingCategory Device()
        {
            var c = Category("device", "IconDeviceTablet");
            var g = Group(c, "settings.grp_identity");
            var name = Add(g, Text("device_name", Self + ".name", "doorbell", SettingScope.ThisDevice));
            name.Handler = "identity";
            name.RequiresRestart = true;
            // Role and door change together in one form (SettingsWindow.Role.cs): nothing is
            // written until it is confirmed, and the app restarts.
            Add(g, Info("device_role", "role"));
            var door = Add(g, Info("device_door", "door"));
            door.Visible = ctx => ctx.IsDoorStation;
            var change = Add(g, Action("change_role", "change_role"));
            change.Key = Self + ".role";
            change.AlsoCovers = new[] { Self + ".door" };
            change.RequiresRestart = true;
            var lang = Add(g, Choice("ui_lang", Local + ".ui_lang", "ja", SettingScope.ThisDevice,
                O("ja", "language.name_ja"), O("en", "language.name_en"),
                O("zh", "language.name_zh")));
            lang.Handler = "ui_lang";
            var info = Group(c, "settings.grp_this_device");
            Add(info, Info("node_id", "node_id"));
            Add(info, Info("pairing_state", "pairing_state"));
            return c;
        }

        private static SettingCategory Sound()
        {
            var c = Category("sound", "IconVolume");
            var here = Group(c, "settings.grp_this_device");
            Add(here, Slider("volume_call", Local + ".audio.volume.call", 0, 100, 1, 80,
                SettingScope.ThisDevice, "settings.unit_percent"));
            Add(here, Slider("volume_sos", Local + ".audio.volume.sos", 0, 100, 1, 100,
                SettingScope.ThisDevice, "settings.unit_percent"));
            Add(here, Slider("volume_idle", Local + ".audio.volume.idle", 0, 100, 1, 60,
                SettingScope.ThisDevice, "settings.unit_percent"));
            var reset = Add(here, Describe(Action("volume_reset", "volume_reset")));
            reset.Key = Local + ".audio.volume";
            var fleet = Group(c, "settings.grp_all_devices");
            Add(fleet, Slider("volume_call_default", "audio.volume.call", 0, 100, 1, 80,
                SettingScope.AllDevices, "settings.unit_percent"));
            Add(fleet, Slider("volume_sos_default", "audio.volume.sos", 0, 100, 1, 100,
                SettingScope.AllDevices, "settings.unit_percent"));
            Add(fleet, Slider("volume_idle_default", "audio.volume.idle", 0, 100, 1, 60,
                SettingScope.AllDevices, "settings.unit_percent"));
            var sounds = Group(c, "settings.grp_sounds");
            Add(sounds, SoundChoice(Choice("ringtone", "ui.ringtone", "school_chime", SettingScope.AllDevices,
                O("school_chime", "sound.school_chime"), O("ding1", "settings.sound_ding1"),
                O("ding2", "settings.sound_ding2"), O("classic", "settings.sound_classic"))));
            Add(sounds, SoundChoice(Choice("call_sound", "ui.call_sound", "outdoor_call_alert",
                SettingScope.AllDevices, Sounds("outdoor_call_alert"))));
            Add(sounds, Describe(Toggle("call_sound_loop", "ui.call_sound_loop", false,
                SettingScope.AllDevices)));
            Add(sounds, SoundChoice(Choice("button_sound", "ui.button_sound", "button_click",
                SettingScope.AllDevices, Sounds("button_click"))));
            Add(sounds, SoundChoice(Choice("update_sound", "ui.update_sound", "indoor_update",
                SettingScope.AllDevices, Sounds("indoor_update"))));
            Add(sounds, SoundChoice(Choice("launch_sound", "ui.launch_sound", "title_display",
                SettingScope.AllDevices, Sounds("title_display"))));
            Add(sounds, Editor("custom_sounds", "assets_audio")).Scope = SettingScope.AllDevices;
            return c;
        }

        private static SettingCategory Display()
        {
            var c = Category("display", "IconBrush");
            var here = Group(c, "settings.grp_this_device");
            // Core reads the per-device display override from devices.<self>.local.display.*.
            Add(here, Slider("brightness_here", Local + ".display.brightness", 0, 100, 1, 70,
                SettingScope.ThisDevice, "settings.unit_percent"));
            // This device's own idle delay: a leaf of its display.screensaver override.
            Add(here, Choice("screensaver", Local + ".display.screensaver.after_s", 120,
                SettingScope.ThisDevice, O(0, "settings.off"), O(60, "settings.min_1"),
                O(120, "settings.min_2"), O(300, "settings.min_5"), O(600, "settings.min_10"),
                O(1800, "settings.min_30")));
            Add(here, Describe(Toggle("video_stats", "local:video_stats", true, SettingScope.Local)));
            // display.screensaver: the idle screen every device follows unless it overrides a
            // leaf under devices.<id>.local.display.screensaver.
            var idle = Group(c, "settings.grp_idle_screen");
            Add(idle, Toggle("saver_enabled", "display.screensaver.enabled", true,
                SettingScope.AllDevices));
            Add(idle, Choice("saver_mode", "display.screensaver.mode", "dim", SettingScope.AllDevices,
                O("dim", "display.saver_mode_dim"), O("minimal", "display.saver_mode_minimal"),
                O("clock", "display.saver_mode_clock")));
            Add(idle, Choice("saver_schedule", "display.screensaver.schedule", "always",
                SettingScope.AllDevices, O("always", "display.saver_schedule_always"),
                O("daily", "display.saver_schedule_daily")));
            Add(idle, TimeOfDay("saver_from", "display.screensaver.from", "22:00",
                SettingScope.AllDevices));
            Add(idle, TimeOfDay("saver_to", "display.screensaver.to", "06:00",
                SettingScope.AllDevices));
            Add(idle, Stepper("saver_after", "display.screensaver.after_s", 5, 86400, 5, 120,
                SettingScope.AllDevices, "settings.unit_seconds"));
            Add(idle, Slider("saver_brightness", "display.screensaver.brightness", 1, 100, 1, 10,
                SettingScope.AllDevices, "settings.unit_percent"));
            var look = Group(c, "settings.grp_appearance");
            Add(look, Choice("appearance", "display.appearance", "dark", SettingScope.AllDevices,
                O("auto_system", "settings.appearance_system"),
                O("auto_schedule", "settings.appearance_schedule"),
                O("light", "settings.appearance_light"), O("dark", "settings.appearance_dark")));
            Add(look, TimeOfDay("dark_from", "display.appearance_schedule.dark_from", "18:00",
                SettingScope.AllDevices));
            Add(look, TimeOfDay("light_from", "display.appearance_schedule.light_from", "06:00",
                SettingScope.AllDevices));
            Add(look, Slider("brightness_default", "display.brightness", 0, 100, 1, 70,
                SettingScope.AllDevices, "settings.unit_percent"));
            Add(look, Choice("pixel_shift", "display.pixel_shift_s", 300, SettingScope.AllDevices,
                O(0, "settings.off"), O(60, "settings.min_1"), O(300, "settings.min_5"),
                O(900, "settings.min_15")));
            var night = Group(c, "settings.grp_night");
            Add(night, Describe(Toggle("night_enabled", "display.night.enabled", true,
                SettingScope.AllDevices)));
            Add(night, TimeOfDay("night_from", "display.night.from", "22:00", SettingScope.AllDevices));
            Add(night, TimeOfDay("night_to", "display.night.to", "06:00", SettingScope.AllDevices));
            Add(night, Slider("night_brightness", "display.night.brightness", 0, 100, 1, 15,
                SettingScope.AllDevices, "settings.unit_percent"));
            Add(night, Toggle("night_red_tint", "display.night.red_tint", true, SettingScope.AllDevices));
            var theme = Group(c, "settings.grp_theme");
            var color = Add(theme, Editor("bg_color", "color", "display.theme.bg_color"));
            color.Default = "#101418";
            color.Scope = SettingScope.AllDevices;
            Add(theme, Toggle("backdrop", "display.theme.backdrop.enabled", true,
                SettingScope.AllDevices));
            Add(theme, Slider("backdrop_opacity", "display.theme.backdrop.opacity", 0, 100, 1, 62,
                SettingScope.AllDevices, "settings.unit_percent"));
            Add(theme, Slider("glass_blur", "display.theme.glass.blur_radius", 0, 40, 1, 32,
                SettingScope.AllDevices));
            Add(theme, Editor("bg_image", "bg_image", "display.theme.bg_image")).Scope = SettingScope.AllDevices;
            return c;
        }

        private static SettingCategory Calls()
        {
            var c = Category("calls", "IconPhone");
            // How long the incoming page stays before returning home: the cluster default and
            // this device's own value (Core reads devices.<self>.local.call.return_s first).
            var back = Group(c, "settings.grp_call_return");
            Add(back, Stepper("call_return", "call.indoor.return_s", 5, 600, 5, 60,
                SettingScope.AllDevices, "settings.unit_seconds"));
            Add(back, Stepper("call_return_here", Local + ".call.return_s", 5, 600, 5, 60,
                SettingScope.ThisDevice, "settings.unit_seconds"));
            var g = Group(c, "settings.grp_visitor");
            Add(g, Choice("call_flow", "ui.call_flow", "purpose_first", SettingScope.AllDevices,
                O("purpose_first", "admin.call_flow_purpose_first_label"),
                O("ring_then_purpose", "admin.call_flow_ring_then_purpose_label")));
            Add(g, Describe(Multi("languages", "ui.languages", SettingScope.AllDevices,
                O("ja", "language.name_ja"), O("en", "language.name_en"),
                O("zh", "language.name_zh"), O("ko", "language.name_ko"),
                O("pt", "language.name_pt"), O("es", "language.name_es"),
                O("vi", "language.name_vi"))));
            Add(g, Choice("lang_revert", "ui.visitor_lang_revert_s", 60, SettingScope.AllDevices,
                O(30, "settings.sec_30"), O(60, "settings.min_1"), O(120, "settings.min_2"),
                O(300, "settings.min_5")));
            Add(g, Describe(Stepper("reply_ttl", "reply.display_ttl_s", 5, 300, 5, 30,
                SettingScope.AllDevices, "settings.unit_seconds")));
            return c;
        }

        private static SettingCategory Replies()
        {
            var c = Category("replies", "IconMessageReply");
            Add(Group(c, "admin.quick_replies"),
                Describe(ListEditor("quick_replies", "quick_replies", "quick_replies")));
            return c;
        }

        private static SettingCategory Purposes()
        {
            var c = Category("purposes", "IconList");
            Add(Group(c, "admin.purposes"),
                Describe(ListEditor("visit_purposes", "visit_purposes", "visit_purposes")));
            return c;
        }

        private static SettingCategory Notices()
        {
            var c = Category("notices", "IconNote");
            var g = Group(c, "notice.title");
            Add(g, Describe(Action("notice_edit", "notice_edit")));
            Add(g, Describe(ListEditor("notice_presets", "notice.presets", "notice_presets")));
            return c;
        }

        private static SettingCategory Emergency()
        {
            var c = Category("sos", "IconShieldLock");
            var g = Group(c, "settings.grp_sos_trigger");
            Add(g, Choice("sos_mode", "emergency.trigger.mode", "slide", SettingScope.AllDevices,
                O("slide", "settings.sos_slide"), O("hold", "settings.sos_hold")));
            Add(g, Describe(Stepper("sos_countdown", "emergency.trigger.countdown_s", 0, 10, 1, 3,
                SettingScope.AllDevices, "settings.unit_seconds")));
            Add(g, Multi("sos_roles", "emergency.button_on_roles", SettingScope.AllDevices,
                O("indoor_panel", "admin.role_indoor"), O("door_station", "admin.role_door")));
            Add(g, Describe(Toggle("sos_cancel_pin", "emergency.cancel_requires_pin", true,
                SettingScope.AllDevices)));
            var alarm = Group(c, "settings.grp_sos_alarm");
            Add(alarm, SoundChoice(Choice("sos_sound", "emergency.alarm_sound", "siren1",
                SettingScope.AllDevices, O("siren1", "prefs.sound_siren1"))));
            Add(alarm, Slider("sos_volume", "emergency.alarm_volume", 0, 100, 1, 100,
                SettingScope.AllDevices, "settings.unit_percent"));
            Add(alarm, Describe(Toggle("sos_web", "emergency.web_active_page_alerts", true,
                SettingScope.AllDevices)));
            Add(alarm, Toggle("sos_sip", "emergency.sip_call.enabled", false, SettingScope.AllDevices));
            Add(alarm, Text("sos_sip_target", "emergency.sip_call.target_extension", "",
                SettingScope.AllDevices));
            var rules = Add(alarm, Action("sos_rules", "goto_rules"));
            rules.DescriptionKey = "settings.sos_rules_native";
            return c;
        }

        private static SettingCategory Camera()
        {
            var c = Category("camera", "IconPhoto");
            var cam = Group(c, "admin.camera");
            System.Func<SettingsContext, bool> door = ctx => ctx.IsDoorStation;
            Add(cam, Choice("cam_codec", Local + ".camera.codec", "auto", SettingScope.ThisDevice,
                O("auto", "admin.codec_auto"), O("mjpeg", "settings.codec_mjpeg"),
                O("h264", "settings.codec_h264"))).Visible = door;
            Add(cam, Choice("cam_resolution", Local + ".camera.resolution", "640x480",
                SettingScope.ThisDevice, O("320x240", "settings.res_320x240"),
                O("640x480", "settings.res_640x480"), O("1280x720", "settings.res_1280x720")))
                .Visible = door;
            Add(cam, Slider("cam_fps", Local + ".camera.mjpeg_fps", 1, 15, 1, 8,
                SettingScope.ThisDevice, "settings.unit_fps")).Visible = door;
            Add(cam, Slider("cam_quality", Local + ".camera.mjpeg_quality", 30, 95, 5, 60,
                SettingScope.ThisDevice)).Visible = door;
            Add(cam, Choice("cam_h264_resolution", Local + ".camera.h264_resolution", "640x360",
                SettingScope.ThisDevice, O("640x360", "settings.res_640x360"),
                O("1280x720", "settings.res_1280x720"))).Visible = door;
            Add(cam, Choice("cam_h264_fps", Local + ".camera.h264_fps", 30, SettingScope.ThisDevice,
                O(15, "settings.fps_15"), O(24, "settings.fps_24"), O(30, "settings.fps_30")))
                .Visible = door;
            Add(cam, Stepper("cam_h264_bitrate", Local + ".camera.h264_bitrate_kbps", 200, 4000, 100,
                700, SettingScope.ThisDevice, "settings.unit_kbps")).Visible = door;
            Add(cam, Text("cam_hint", Local + ".camera.device_hint", "", SettingScope.ThisDevice))
                .Visible = door;
            var source = Add(cam, Describe(Choice("cam_source", Local + ".camera.source_ref", "",
                SettingScope.ThisDevice, O("", "settings.cam_source_builtin"))));
            source.Handler = "media_source";
            source.Visible = door;
            var video = Group(c, "settings.grp_video");
            Add(video, Choice("video_rotation", Local + ".video.rotation", "auto",
                SettingScope.ThisDevice, O("auto", "admin.rotation_auto"), O("0", "settings.deg_0"),
                O("90", "settings.deg_90"), O("180", "settings.deg_180"),
                O("270", "settings.deg_270")));
            Add(video, Choice("video_playback", Local + ".video.playback", "low_latency",
                SettingScope.ThisDevice, O("low_latency", "admin.video_low_latency"),
                O("hls", "admin.video_hls"), O("mjpeg", "settings.codec_mjpeg")));
            Add(video, Editor("video_policy", "video_policy")).Scope = SettingScope.AllDevices;
            var motion = Group(c, "admin.motion");
            Add(motion, Toggle("motion_enabled", Local + ".motion.enabled", true,
                SettingScope.ThisDevice)).Visible = door;
            Add(motion, Slider("motion_sensitivity", Local + ".motion.sensitivity", 1, 100, 1, 40,
                SettingScope.ThisDevice)).Visible = door;
            Add(motion, Stepper("motion_interval", Local + ".motion.min_interval_s", 5, 600, 5, 30,
                SettingScope.ThisDevice, "settings.unit_seconds")).Visible = door;
            return c;
        }

        private static SettingCategory Sip()
        {
            var c = Category("sip", "IconMicrophone");
            var server = Group(c, "settings.grp_sip_server");
            Add(server, Describe(Text("sip_server", "sip.server", "", SettingScope.AllDevices)));
            Add(server, Stepper("sip_port", "sip.port", 1, 65535, 1, 5060, SettingScope.AllDevices));
            Add(server, Choice("sip_transport", "sip.transport", "udp", SettingScope.AllDevices,
                O("udp", "settings.transport_udp"), O("tcp", "settings.transport_tcp"),
                O("tls", "settings.transport_tls")));
            Add(server, Describe(Stepper("sip_direct_port", "sip.direct_port", 1024, 65535, 1, 47190,
                SettingScope.AllDevices)));
            Add(server, Describe(Choice("sip_srtp", "sip.srtp", "optional", SettingScope.AllDevices,
                O("optional", "settings.srtp_optional"), O("mandatory", "settings.srtp_mandatory"))));
            var account = Group(c, "settings.grp_sip_account");
            Add(account, Text("sip_user", "sip.accounts.{self}.user", "", SettingScope.ThisDevice));
            // Core knows "auto" and "ring"; unset follows the role (a door station answers
            // automatically, an indoor panel rings), so there is no default to show.
            Add(account, Choice("sip_answer_mode", "sip.accounts.{self}.answer_mode", null,
                SettingScope.ThisDevice, O("auto", "settings.answer_mode_auto"),
                O("ring", "settings.answer_mode_ring")));
            Add(account, Secret("sip_password", "sip.accounts.{self}.pass_ref", "sip.{self}",
                SettingScope.ThisDevice));
            Add(Group(c, "settings.sip_dtmf"), Editor("sip_dtmf", "dtmf")).Scope = SettingScope.AllDevices;
            return c;
        }

        private static SettingCategory Time()
        {
            var c = Category("time", "IconClock");
            var g = Group(c, "settings.grp_time");
            Add(g, Choice("time_zone", "time.zone", "Asia/Tokyo", SettingScope.AllDevices,
                O("Asia/Tokyo", "settings.tz_tokyo"), O("Asia/Shanghai", "settings.tz_shanghai"),
                O("Asia/Seoul", "settings.tz_seoul"), O("Asia/Singapore", "settings.tz_singapore"),
                O("Europe/London", "settings.tz_london"), O("Europe/Berlin", "settings.tz_berlin"),
                O("America/New_York", "settings.tz_new_york"),
                O("America/Los_Angeles", "settings.tz_los_angeles"), O("UTC", "settings.tz_utc")));
            Add(g, Describe(Toggle("ntp_enabled", "time.ntp.enabled", false, SettingScope.AllDevices)));
            Add(g, Describe(Text("ntp_servers", "time.ntp.servers", "", SettingScope.AllDevices)))
                .Handler = "string_list";
            Add(g, Choice("ntp_interval", "time.ntp.interval_s", 86400, SettingScope.AllDevices,
                O(3600, "settings.hour_1"), O(21600, "settings.hour_6"),
                O(86400, "settings.day_1"), O(604800, "settings.week_1")));
            Add(g, Action("time_sync", "time_sync"));
            return c;
        }

        private static SettingCategory Pairing()
        {
            var c = Category("pairing", "IconTopologyStar3");
            var g = Group(c, "settings.grp_cluster");
            Add(g, Info("pairing_state_cluster", "pairing_state"));
            Add(g, Describe(Action("add_device", "add_device")));
            var security = Group(c, "settings.grp_security");
            Add(security, Info("cluster_key", "cluster_key"));
            Add(security, Describe(Info("peer_alerts", "peer_alerts")));
            Add(security, Describe(Action("change_password", "change_password")));
            Add(security, Destructive(Describe(Action("rotate_cluster_key", "rotate_cluster_key"))));
            Add(security, Destructive(Describe(Action("rebuild_cluster", "rebuild_cluster"))));
            Add(Group(c, "admin.devices"), Editor("devices_manage", "devices"));
            Add(Group(c, "panels.title"), Editor("panels_manage", "panels"));
            return c;
        }

        private static SettingCategory Kiosk()
        {
            var c = Category("kiosk", "IconAdjustments");
            var g = Group(c, "settings.grp_kiosk");
            var kiosk = Add(g, Describe(Toggle("kiosk_mode", "boot:kiosk", true, SettingScope.Local)));
            kiosk.RequiresRestart = true;
            Add(g, Describe(Action("kiosk_unlock", "kiosk_unlock")));
            Add(g, Action("kiosk_lock", "kiosk_lock"));
            var health = Group(c, "admin.runtime_health");
            Add(health, Info("watchdog_state", "watchdog_state"));
            Add(health, Info("safe_mode", "safe_mode"));
            Add(health, Destructive(Describe(Action("restart_app", "restart_app"))));
            return c;
        }

        private static SettingCategory About()
        {
            var c = Category("about", "IconInfoCircle");
            var g = Group(c, "settings.grp_about");
            Add(g, Info("app_version", "app_version"));
            Add(g, Info("core_version", "core_version"));
            Add(g, Info("sip_backend", "sip_backend"));
            Add(g, Info("addresses", "addresses"));
            Add(g, Info("tls_fingerprint", "tls_fingerprint"));
            var tools = Group(c, "settings.grp_maintenance");
            Add(g, Describe(Info("web_admin_link", "admin_urls")));
            Add(tools, Editor("software_update", "software_update"));
            Add(tools, Action("open_logs", "open_logs"));
            return c;
        }

        private static SettingCategory Rules()
        {
            var c = Category("rules", "IconBell");
            Add(Group(c, "admin.rules"), Editor("rules", "rules"));
            Add(Group(c, "admin.quiet_hours"), Editor("quiet_hours", "quiet_hours"));
            Add(Group(c, "admin.households"), Editor("households", "households"));
            return c;
        }

        private static SettingCategory Integrations()
        {
            var c = Category("integrations", "IconLink");
            var mqtt = Group(c, "settings.grp_mqtt");
            Add(mqtt, Describe(Text("mqtt_host", "integrations.mqtt.host", "", SettingScope.AllDevices)));
            Add(mqtt, Stepper("mqtt_port", "integrations.mqtt.port", 1, 65535, 1, 1883, SettingScope.AllDevices));
            Add(mqtt, Text("mqtt_user", "integrations.mqtt.user", "", SettingScope.AllDevices));
            Add(mqtt, Secret("mqtt_password", "integrations.mqtt.pass_ref", "mqtt", SettingScope.AllDevices));
            Add(mqtt, Text("mqtt_base_topic", "integrations.mqtt.base_topic", "doorbell", SettingScope.AllDevices));
            Add(mqtt, Text("mqtt_discovery", "integrations.mqtt.discovery_prefix", "homeassistant",
                SettingScope.AllDevices));
            Add(mqtt, Describe(Toggle("mqtt_tls", "integrations.mqtt.tls", false, SettingScope.AllDevices)));
            Add(mqtt, Describe(Text("mqtt_tls_sha256", "integrations.mqtt.tls_sha256", "", SettingScope.AllDevices)));
            var ha = Group(c, "settings.grp_ha");
            Add(ha, Choice("ha_language", "integrations.ha.language", "ja", SettingScope.AllDevices,
                O("ja", "language.name_ja"), O("en", "language.name_en"), O("zh", "language.name_zh")));
            Add(ha, Describe(Toggle("ha_allow_sos", "integrations.ha.allow_sos_control", false,
                SettingScope.AllDevices)));
            Add(ha, Describe(Toggle("ha_allow_notice", "integrations.ha.allow_notice_control", false,
                SettingScope.AllDevices)));
            var tg = Group(c, "settings.grp_telegram");
            Add(tg, Secret("telegram_token", "integrations.telegram.bot_token_ref", "tg_bot",
                SettingScope.AllDevices));
            Add(tg, Describe(Toggle("telegram_poll", "integrations.telegram.poll_updates", true,
                SettingScope.AllDevices)));
            Add(tg, Describe(Text("telegram_template", "integrations.telegram.text_template.ja", "",
                SettingScope.AllDevices)));
            Add(tg, Describe(Action("telegram_test", "telegram_test")));
            // Web Push: the non-secret fields replicate; each key stays in a device's own
            // secure store and configuration carries only the secret:<name> reference.
            var push = Group(c, "settings.web_push");
            Add(push, Text("web_push_sender_url", "integrations.web_push.sender_url", "",
                SettingScope.AllDevices));
            Add(push, Text("web_push_public_key", "integrations.web_push.vapid_public_key", "",
                SettingScope.AllDevices));
            Add(push, Text("web_push_subject", "integrations.web_push.vapid_subject", "",
                SettingScope.AllDevices));
            Add(push, Secret("web_push_private_key", "integrations.web_push.vapid_private_key_ref",
                "webpush.vapid_private", SettingScope.AllDevices));
            Add(push, Secret("web_push_sender_bearer", "integrations.web_push.sender_secret_ref",
                "webpush.sender", SettingScope.AllDevices));
            return c;
        }

        private static SettingCategory Places()
        {
            var c = Category("places", "IconBuildingCommunity");
            Add(Group(c, "admin.door_list"), Editor("doors_manage", "doors"));
            Add(Group(c, "admin.buildings"), Editor("buildings_manage", "buildings"));
            Add(Group(c, "settings.media_sources"), Editor("media_sources", "media_sources"));
            return c;
        }

        private static SettingCategory Wording()
        {
            var c = Category("wording", "IconWorld");
            Add(Group(c, "admin.texts"), Editor("texts", "texts"));
            Add(Group(c, "admin.assets"), Editor("assets", "assets_all"));
            return c;
        }

        private static SettingCategory Backup()
        {
            var c = Category("backup", "IconDownload");
            Add(Group(c, "settings.import_export"), Editor("import_export", "backup"));
            Add(Group(c, "settings.secrets"), Editor("secrets", "secrets"));
            return c;
        }
    }
}
