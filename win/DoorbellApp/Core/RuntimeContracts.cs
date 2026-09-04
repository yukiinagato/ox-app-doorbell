using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Web.Script.Serialization;

namespace DoorbellApp.Core
{
    internal static class RuntimeContracts
    {
        private static readonly string[] StyleProperties =
        {
            "scale", "font_scale", "foreground", "background", "accent", "border", "radius"
        };

        public static Dictionary<string, object> Capabilities(string sipBackend, string role,
                                                               bool safeMode, bool micMute,
                                                               bool camera)
        {
            bool pjsip = string.Equals(sipBackend, "pjsip", StringComparison.Ordinal);
            bool uiManifest = SupportsUiManifest(role);
            bool systemNotifications = DoorbellApp.DeviceAlertNotifier.SystemNotificationAvailable();
            return new Dictionary<string, object>
            {
                { "schema_version", 2 },
                { "platform", "windows" },
                { "tls12", true },
                // A LAN route/default gateway is not a configured endpoint reachability result.
                { "wan", false },
                { "mains_power", DeviceInfoProvider.IsOnMainsPower() },
                { "mqtt_reachable", false },
                { "wall_clock_sane", DateTime.UtcNow.Year >= 2020 },
                { "cpu_score", MeasureCpuScore() },
                { "platform_v2", true },
                { "https_transport", true },
                { "secure_store", true },
                { "ui_manifest_v1", uiManifest },
                { "runtime_recovery", true },
                { "watchdog_heartbeat", true },
                { "sip", pjsip },
                { "sip_backend", sipBackend ?? "unknown" },
                { "sip_pjsip", pjsip },
                { "sip_dtmf", pjsip },
                { "system_notifications", systemNotifications },
                // Battery/mains come from GetSystemPowerStatus through db_platform_v2.power_state.
                { "power_state", true },
                // True only while this node can actually serve frames. An indoor panel hides its
                // door tile for a station that answers false, rather than showing a dead still.
                { "camera", camera },
                // True only when the loaded Core exports db_core_sip_set_mic_muted; the incoming
                // screen hides the microphone toggle rather than offering a dead control.
                { "sip_mic_mute", micMute },
                { "device_alert_channels", new[] { "in_app", "system_notification" } },
                { "device_alert_channel_support", DeviceAlertChannelSupport(systemNotifications) },
                { "mjpeg_http_preview", true },
                { "mjpeg_low_resolution", safeMode },
                // Core's own fMP4/H.264 player (Media Foundation decoder, H264LiveStreamer) is
                // used whenever the loaded Core exports it; the MediaElement fallback stays
                // guarded behind the installer's certification marker.
                { "h264_fmp4_playback", !safeMode && (NativeH264Available() || H264PlaybackCertified()) },
                { "h264_media_foundation_encode", !safeMode && H264EncodeCertified() },
                { "features", new Dictionary<string, object>
                    {
                        { "platform_v2", true },
                        { "call_flow_v2", true },
                        { "call_cancel_v2", true },
                        { "call_lifecycle_v2", pjsip },
                        { "device_alert_v1", true },
                        { "ui_manifest_v1", uiManifest },
                        { "runtime_recovery_v1", true },
                        { "helper_policy_v1", false },
                    }
                },
            };
        }

        private static Dictionary<string, object> DeviceAlertChannelSupport(
            bool systemNotifications)
        {
            return new Dictionary<string, object>
            {
                { "schema_version", 1 },
                { "channels", new Dictionary<string, object>
                    {
                        { "in_app", AlertSupport(true, true, "not_required", "") },
                        { "system_notification", AlertSupport(true, systemNotifications,
                            "not_required", systemNotifications ? "" : "windows_shell_unavailable") },
                        { "web_push", AlertSupport(false, false, "not_applicable",
                            "unsupported_on_windows_native") },
                    }
                },
            };
        }

        private static Dictionary<string, object> AlertSupport(bool supported, bool available,
                                                                string permission,
                                                                string limitation)
        {
            var value = new Dictionary<string, object>
            {
                { "supported", supported },
                { "available", available },
                { "permission", permission },
            };
            if (!string.IsNullOrEmpty(limitation)) value["limitation"] = limitation;
            return value;
        }

        public static Dictionary<string, object> Status(string role, string sipBackend, bool safeMode)
        {
            return new Dictionary<string, object>
            {
                { "windows", new Dictionary<string, object>
                    {
                        { "schema_version", 1 },
                        { "platform", "windows" },
                        { "role", role ?? "" },
                        { "os_version", Environment.OSVersion.VersionString },
                        { "process_arch", Environment.Is64BitProcess ? "x64" : "x86" },
                        { "safe_mode", safeMode },
                        { "sip_backend", sipBackend ?? "unknown" },
                        { "sip_available", string.Equals(sipBackend, "pjsip", StringComparison.Ordinal) },
                        { "h264_playback", safeMode ? "disabled_safe_mode" :
                            (NativeH264Available() ? "native_decoder" :
                             (H264PlaybackCertified() ? "certified" : "uncertified_fallback")) },
                        // Why the last MediaElement attempt did or did not open; the full
                        // history is in video.log next to the data directory.
                        { "h264_playback_diagnostics", VideoDiagnostics.Snapshot() },
                        { "mjpeg_playback", safeMode ? "low_resolution_fallback" : "available" },
                        { "audio_calling", string.Equals(sipBackend, "pjsip",
                                                         StringComparison.Ordinal) ?
                            "available" : "unavailable" },
                        { "core_abi", new Dictionary<string, object>
                            {
                                { "version", CoreInterop.DbPlatformV2Version },
                                { "struct_size", System.Runtime.InteropServices.Marshal.SizeOf(typeof(CoreInterop.DbPlatformV2)) },
                                { "https_request", true }, { "secure_get", true },
                                { "secure_put", true }, { "device_info", true },
                                { "release_buffer", true }, { "secure_delete", true },
                                { "power_state", true },
                            }
                        },
                    } },
                { "components", new Dictionary<string, object>
                    {
                        { "core", "running" },
                        { "ringer", "available" },
                        { "sos", "available" },
                        { "controls", "available" },
                        { "sip_audio", string.Equals(sipBackend, "pjsip",
                                                       StringComparison.Ordinal) ?
                            "available" : "unavailable" },
                        { "media", safeMode ? "low_resolution_mjpeg" : "available" },
                    }
                }
            };
        }

        internal static void ApplyProcessHealth(Dictionary<string, object> status,
                                                 DoorbellApp.RuntimeProcessSnapshot process,
                                                 bool safeMode, bool watchdogAvailable,
                                                 long watchdogSignalWallMs, bool uiRunning)
        {
            if (status == null || process == null) return;
            long heartbeatMs = Math.Max(0L,
                (DateTime.UtcNow.Ticks - 621355968000000000L) /
                    TimeSpan.TicksPerMillisecond);
            status["schema_version"] = 1;
            status["generation"] = process.Generation;
            status["heartbeat_ms"] = heartbeatMs;
            status["last_exit_reason"] = process.LastExitReason;
            status["safe_mode"] = safeMode;
            status["helper_mode"] = "off";
            status["helper_available"] = false;
            status["state_persisted"] = process.StatePersisted;
            status["codec_health"] = safeMode ? "safe_mode_low_resolution_mjpeg" :
                (NativeH264Available() ? "native_h264_or_mjpeg" :
                 (H264PlaybackCertified() ? "certified_h264_or_mjpeg" : "mjpeg_fallback"));
            status["process_recovery"] = new Dictionary<string, object>
            {
                { "schema_version", 1 },
                { "generation", process.Generation },
                { "heartbeat_ms", heartbeatMs },
                { "updated_at_ms", Math.Max(0L, watchdogSignalWallMs) },
                { "safe_mode", safeMode },
                { "last_exit_reason", process.LastExitReason },
                { "state_persisted", process.StatePersisted },
                { "state", watchdogAvailable ? "watchdog_connected" : "watchdog_unavailable" },
            };
            var components = status["components"] as Dictionary<string, object>;
            if (components != null) components["ui"] = uiRunning ? "running" : "starting";
        }

        public static Dictionary<string, object> UiManifest(string role)
        {
            var elements = new Dictionary<string, object>();
            if (role == "door_station")
            {
                AddElement(elements, "call.primary", false);
                AddElement(elements, "cancel.call", true);
                AddElement(elements, "call.end", true);
                AddElement(elements, "purpose.button", false);
                AddElement(elements, "sos.trigger", true);
                AddElement(elements, "sos.cancel", true);
            }
            if (role == "indoor_panel")
            {
                AddElement(elements, "call.end", true);
                AddElement(elements, "ring.title", false);
                AddElement(elements, "ring.action", false);
                AddElement(elements, "reply.button", false);
                AddElement(elements, "monitor.close", true);
                AddElement(elements, "sos.trigger", true);
                AddElement(elements, "sos.cancel", true);
            }
            return new Dictionary<string, object>
            {
                { "schema_version", 1 },
                { "units", "logical" },
                { "viewport", new Dictionary<string, object>
                    { { "minimum_touch", 44 }, { "scale_min", 0.75 }, { "scale_max", 2.0 } } },
                { "elements", elements },
            };
        }

        internal static bool SupportsUiManifest(string role)
        {
            return role == "door_station" || role == "indoor_panel";
        }

        public static string Json(Dictionary<string, object> value) =>
            new JavaScriptSerializer().Serialize(value);

        private static void AddElement(Dictionary<string, object> elements, string id, bool safety)
        {
            elements[id] = new Dictionary<string, object>
            {
                { "properties", StyleProperties },
                { "safety_critical", safety },
                { "defaults", UiDefaults(id) },
            };
        }

        internal static Dictionary<string, object> UiDefaults(string id)
        {
            string foreground = "#E8EDF2";
            string background = "#1A2027";
            string accent = "#4DA3FF";
            string border = "#4DA3FF";
            double radius = 12;
            switch (id)
            {
                case "call.primary":
                    foreground = "#04121F";
                    background = "#4DA3FF";
                    accent = "#04121F";
                    border = "#04121F";
                    radius = 24;
                    break;
                case "ring.action":
                    foreground = "#FFFFFF";
                    background = "#187A3C";
                    accent = "#FFFFFF";
                    border = "#FFFFFF";
                    break;
                case "ring.title":
                    foreground = "#FFFFFF";
                    background = "#0A0D12";
                    accent = "#4DA3FF";
                    border = "#4DA3FF";
                    break;
                case "call.end":
                case "sos.trigger":
                    foreground = "#FFFFFF";
                    background = "#C0392B";
                    accent = "#FFFFFF";
                    border = "#FFFFFF";
                    radius = 16;
                    break;
                case "sos.cancel":
                    foreground = "#FFFFFF";
                    background = "#7F1D1D";
                    accent = "#FFFFFF";
                    border = "#FFFFFF";
                    radius = 16;
                    break;
            }
            return new Dictionary<string, object>
            {
                { "scale", 1.0 },
                { "font_scale", 1.0 },
                { "foreground", foreground },
                { "background", background },
                { "accent", accent },
                { "border", border },
                { "radius", radius },
            };
        }

        private static bool NativeH264Available()
        {
            return H264LiveStreamer.Available;
        }

        private static bool H264PlaybackCertified()
        {
            return File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
                                            "h264-playback.certified"));
        }

        private static bool H264EncodeCertified()
        {
            return File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
                                            "h264-encode.certified"));
        }

        private static int MeasureCpuScore()
        {
            try
            {
                byte[] block = new byte[4096];
                var watch = Stopwatch.StartNew();
                int iterations = 0;
                using (var sha = SHA256.Create())
                    while (watch.ElapsedMilliseconds < 30)
                    { block = sha.ComputeHash(block); iterations++; }
                watch.Stop();
                return watch.ElapsedMilliseconds == 0 ? 0 :
                    checked((int)Math.Min(1000000L, iterations * 1000L / watch.ElapsedMilliseconds));
            }
            catch { return 0; }
        }
    }
}
