#!/usr/bin/env python3
"""Host-runnable contract checks for the Windows client (no Windows SDK needed)."""

from pathlib import Path
import math
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
WIN = ROOT / "win"


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def required_probe_exports(probe: str) -> set:
    """Every export the ABI probe fails on, across all of its required lists."""
    required = set()
    for name in ("kPairingExports", "kShellExports"):
        match = re.search(name + r"\[\] = \{(.*?)\};", probe, re.S)
        if match:
            required |= set(re.findall(r'"([a-z_0-9]+)"', match.group(1)))
    return required


class WindowsContracts(unittest.TestCase):
    def test_operational_capabilities_do_not_infer_wan_from_a_default_gateway(self):
        contracts = read("win/DoorbellApp/Core/RuntimeContracts.cs")
        capabilities = contracts[
            contracts.index("public static Dictionary<string, object> Capabilities"):
            contracts.index("private static Dictionary<string, object> DeviceAlertChannelSupport")
        ]
        device_info = read("win/DoorbellApp/Core/DeviceInfoProvider.cs")

        self.assertIn('{ "wan", false }', capabilities)
        self.assertNotIn("HasWanInterface", capabilities)
        self.assertNotIn("HasWanInterface", device_info)
        self.assertIn('{ "mains_power", DeviceInfoProvider.IsOnMainsPower() }',
                      capabilities)
        self.assertIn("status.ACLineStatus == 1", device_info)

    def test_xaml_and_resources_are_well_formed(self):
        for path in [WIN / "DoorbellApp" / "MainWindow.xaml",
                     WIN / "DoorbellApp" / "App.xaml",
                     WIN / "DoorbellApp" / "AdminDialog.xaml",
                     WIN / "DoorbellApp" / "NoticeDialog.xaml",
                     WIN / "DoorbellApp" / "WebAdminWindow.xaml",
                     *sorted((WIN / "DoorbellApp" / "Pairing").glob("*.xaml")),
                     *sorted((WIN / "DoorbellApp" / "Resources").glob("*.resx"))]:
            with self.subTest(path=path.name):
                ET.parse(path)

    def test_platform_v2_layout_and_owned_buffers(self):
        source = read("win/DoorbellApp/Core/CoreInterop.cs")
        fields = re.findall(r"public (?:uint|IntPtr) (\w+);",
                            source[source.index("struct DbPlatformV2"):source.index(
                                "delegate void LogLineCb")])
        # Fields are only appended; secure_delete is the newest and must stay last.
        self.assertEqual(fields, ["struct_size", "version", "user", "https_request",
                                 "secure_get", "secure_put", "log_line", "tts_speak",
                                 "device_info", "release_buffer", "secure_delete",
                                 "power_state"])
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        self.assertIn("Marshal.SizeOf(typeof(CoreInterop.DbPlatformV2))", client)
        self.assertIn("Marshal.FreeHGlobal(buffer)", client)
        self.assertIn("db_core_create_v2", client)
        self.assertIn("secure_delete = Marshal.GetFunctionPointerForDelegate(_secureDeleteCb)",
                      client)
        self.assertRegex(client, r"_secureDeleteCb = [\s\S]*?_secretStore\.Delete\("
                                 r"[\s\S]*?\? 0 : -1")
        self.assertIn("public bool Delete(string key)",
                      read("win/DoorbellApp/Core/DpapiSecretStore.cs"))
        self.assertIn("power_state = Marshal.GetFunctionPointerForDelegate(_powerStateCb)",
                      client)
        probe = read("win/abi-probe/main.cpp")
        self.assertIn("10 * sizeof(void*)", probe)
        self.assertIn("offsetof(db_platform_v2, power_state)", probe)

    def test_native_zero_success_is_not_inverted(self):
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        for call in ["db_core_select_purpose_v2", "db_core_cancel_call_v2",
                     "db_core_sip_send_dtmf"]:
            self.assertRegex(client, call + r"[\s\S]{0,150}== 0")
        self.assertRegex(client, r"db_core_emergency_v2[\s\S]{0,150}!= 0")

    def test_sos_mutation_failure_keeps_visible_state(self):
        interop = read("win/DoorbellApp/Core/CoreInterop.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        android_core = read(
            "android/app/src/main/java/jp/ox/doorbell/DoorbellCore.kt")
        android_jni = read("android/app/src/main/cpp/jni_bridge.cpp")
        android_app = read("android/app/src/main/java/jp/ox/doorbell/App.kt")
        self.assertIn("db_core_emergency_v2", interop)
        self.assertIn("public bool Emergency(bool active)", client)
        cancel = window[window.index("private void OnEmergencyCancelClick"):
                        window.index("private void StartSiren")]
        self.assertIn("if (App.Core.Emergency(false)) HideEmergency()", cancel)
        self.assertIn("nativeEmergencyV2(handle, active)", android_core)
        self.assertIn("db_core_emergency_v2", android_jni)
        self.assertIn("internal fun commitEmergency(active: Boolean): Boolean", android_app)

    def test_https_and_dpapi_fail_closed(self):
        transport = read("win/DoorbellApp/Core/WinHttpTransport.cs")
        self.assertIn("Uri.UriSchemeHttps", transport)
        self.assertIn("SecureProtocolTls12", transport)
        self.assertIn("RedirectNever", transport)
        self.assertIn("MaxResponseBytes", transport)
        self.assertNotIn("SecurityFlagIgnore", transport)
        secrets = read("win/DoorbellApp/Core/DpapiSecretStore.cs")
        self.assertIn("ProtectedData.Protect", secrets)
        self.assertIn("ProtectedData.Unprotect", secrets)
        self.assertIn("DataProtectionScope.LocalMachine", secrets)
        self.assertIn("FileOptions.WriteThrough", secrets)

    def test_pairing_boot_uses_secret_reference(self):
        boot = read("win/DoorbellApp/BootConfig.cs")
        app = read("win/DoorbellApp/App.xaml.cs")
        core = read("win/DoorbellApp/Core/CoreClient.cs")
        self.assertIn('data.Remove("psk_hex")', boot)
        self.assertIn('data["psk_ref"] = "secret:mesh.psk"', boot)
        self.assertIn("return WritePairingGenerations(path, output) ? output : null", boot)
        pairing_writer = boot[boot.index("private static bool WritePairingGenerations"):
                              boot.index("private static void WriteGeneration")]
        self.assertIn('WriteGeneration(path + ".bak", value)', pairing_writer)
        self.assertIn("WriteGeneration(path, value)", pairing_writer)
        self.assertNotIn("preserveCurrent", pairing_writer)
        self.assertIn("FileOptions.WriteThrough", boot)
        self.assertIn("output.Flush(true)", boot)
        self.assertIn("File.Replace(temporary, target", boot)
        self.assertIn("File.Move(temporary, target)", boot)
        self.assertRegex(core, r"_securePutCb = [\s\S]*?_secretStore\.Put\([\s\S]*?\? 0 : -1")
        self.assertIn('secretRef != "secret:mesh.psk"', app)
        paired = app[app.index("private void OnCoreLifecycleEvent"):
                     app.index("private void ReportPairingPersistenceFailure")]
        self.assertNotIn("psk_hex", paired)
        self.assertLess(paired.index('secretRef != "secret:mesh.psk"'),
                        paired.index("PersistPairingReference"))
        self.assertIn("if (updated != null)", paired)
        self.assertIn("Boot = BootConfig.Load(Boot.FilePath)", paired)
        self.assertIn('ReportPairingPersistenceFailure("boot.json secure-reference '
                      'persistence failed")', paired)
        self.assertIn('ev.T == "pairing_persistence_error"', app)

    def test_first_run_requires_an_explicit_valid_role_and_random_door_id(self):
        boot = read("win/DoorbellApp/BootConfig.cs")
        app = read("win/DoorbellApp/App.xaml.cs")
        setup = read("win/DoorbellApp/BootstrapSetupWindow.cs")

        self.assertIn(r'\"setup_complete\": false', boot)
        self.assertIn("bool setupComplete = false;", boot)
        self.assertNotIn("bool setupComplete = hadStoredProfile;", boot)
        self.assertIn("RandomNumberGenerator.Create()", boot)
        self.assertIn('new StringBuilder("door-")', boot)
        self.assertIn('value == "door_station" || value == "indoor_panel"', boot)
        self.assertIn('char first = value[0]', boot)
        self.assertIn('role == "door_station" && !ValidDoor(door)', boot)
        self.assertIn('data["setup_complete"] = true', boot)
        self.assertIn('data["door"] = role == "door_station" ? door : ""', boot)
        self.assertIn("if (Boot.SetupRequired)", app)
        self.assertLess(app.index("if (Boot.SetupRequired)"),
                        app.index("Core = new CoreClient()"))
        self.assertIn('Tag = "door_station"', setup)
        self.assertIn('Tag = "indoor_panel"', setup)
        self.assertIn("BootConfig.PersistSetup", setup)
        self.assertIn("ResultConfig == null", setup)

    def test_supported_shells_never_parse_paired_plaintext(self):
        windows_app = read("win/DoorbellApp/App.xaml.cs")
        windows_paired = windows_app[windows_app.index("private void OnCoreLifecycleEvent"):
                                     windows_app.index(
                                         "private void ReportPairingPersistenceFailure")]
        android_app = read("android/app/src/main/java/jp/ox/doorbell/App.kt")
        android_paired = android_app[android_app.index("private fun onPaired"):
                                     android_app.index(
                                         "private fun migrateLegacyPairingSecret")]
        self.assertNotIn("psk_hex", windows_paired)
        self.assertNotIn("psk_hex", android_paired)
        self.assertNotIn("_secretStore", windows_paired)
        self.assertNotIn("putPlatformSecret", android_paired)
        self.assertIn("PairingPersistenceGate.MESH_PSK_REFERENCE", android_paired)
        self.assertIn("pairingPersistence.recordPaired", android_paired)
        self.assertIn('eventType == "pairing_persistence_error"', android_app)
        self.assertIn("pairingPersistence.recordFailure()", android_app)
        android_boot = read(
            "android/app/src/main/java/jp/ox/doorbell/BootConfig.kt")
        self.assertIn('d.remove("psk_hex")', android_boot)
        self.assertIn('d.put("psk_ref", "secret:mesh.psk")', android_boot)
        self.assertIn("writeAndRename(backup, js)", android_boot)
        self.assertIn("writeAndRename(file, js)", android_boot)
        android_core = read(
            "android/app/src/main/java/jp/ox/doorbell/DoorbellCore.kt")
        secure_put = android_core[android_core.index("private fun onSecurePutFromNative"):
                                  android_core.index("private fun onDeviceInfoFromNative")]
        self.assertIn("secureStore.put(key, value)", secure_put)
        # The onboarding screen decides "ready" only through App.pairingReady(), which is the
        # single caller of the persistence gate; the screen itself never inspects the plaintext.
        pairing_ui = read(
            "android/app/src/main/java/jp/ox/doorbell/PairingActivity.kt")
        self.assertIn("app.pairingReady()", pairing_ui)
        self.assertNotIn("psk_hex", pairing_ui)
        android_app = read("android/app/src/main/java/jp/ox/doorbell/App.kt")
        ready = android_app[android_app.index("fun pairingReady()"):]
        ready = ready[:ready.index("\n    }\n")]
        self.assertIn("pairingPersistence.canMarkReady", ready)

    def test_android_helper_policy_uses_only_the_fixed_local_protocol(self):
        client = read(
            "android/app/src/main/java/jp/ox/doorbell/RootKeepaliveClient.kt")
        supervisor = read(
            "android/app/src/main/java/jp/ox/doorbell/RuntimeSupervisor.kt")
        controller = read(
            "android/app/src/main/java/jp/ox/doorbell/KioskController.kt")
        self.assertIn('const val SOCKET_NAME = "doorbell_keeper"', client)
        for command in ["STATUS", "MODE (off|auto|on)", "ENABLE", "DISABLE",
                        "KICK [1-9][0-9]*", "PAUSE_LEASE"]:
            self.assertIn(command, client)
        self.assertNotIn("ProcessBuilder", client)
        self.assertNotIn("Runtime.getRuntime", client)
        self.assertIn('"devices.$nodeId.local.recovery.helper_mode"', supervisor)
        config_changed = supervisor[supervisor.index("fun onConfigChanged"):
                                    supervisor.index("fun frameRotationForDeviceRotation")]
        self.assertIn("applyHelperConfiguration()", config_changed)
        self.assertIn('statusStore.update("recovery_helper"', controller)
        self.assertIn('.put("configured", decision.configured)', controller)
        self.assertIn('.put("effective",', controller)
        self.assertIn('.put("measured", JSONObject()', controller)

    def test_call_flow_and_targeted_chime(self):
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        self.assertIn('CoreClient.Dig(_cfg, "call_flow")', window)
        event_block = window[window.index('case "event":'):window.index('case "chime":')]
        press_block = event_block[event_block.index('eventType == "press"'):]
        self.assertNotIn("ShowIncoming(ev)", press_block)
        chime_block = window[window.index('case "chime":'):window.index(
            'case "call_recovery_required":')]
        self.assertIn("ShowIncoming(ev)", chime_block)
        self.assertIn("_incomingCallId", window)
        # Unlock goes through core's own action, which works from the monitor page too.
        self.assertIn("App.Core.OpenDoor(CurrentCallDoor())", window)
        self.assertIn("db_core_open_door", read("win/DoorbellApp/Core/CoreInterop.cs"))

    def test_originated_call_timeout_uses_core_expiry(self):
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        show = window[window.index("private long ResolveActiveCallExpiryMs"):
                      window.index("private void OnUiEvent")]
        self.assertIn('status["active_calls"]', show)
        self.assertIn('DictLong(call, "expires_at_ms", 0)', show)
        self.assertIn("_activeCallExpiresAtMs = ResolveActiveCallExpiryMs()", window)
        self.assertIn("_activeCallExpiresAtMs -", show)
        self.assertIn("Math.Max(1, remainingMs)", show)
        self.assertNotIn("30000", show)
        self.assertNotIn("TimeSpan.FromSeconds(30)", show)

    def test_established_audio_calls_do_not_wait_for_video(self):
        ios = read("ios/Doorbell/MainViewController.swift")
        ios_dispatch = ios[ios.index('case "state":'):ios.index('case "chime":')]
        self.assertIn('st == "in_call" || st == "answered"', ios_dispatch)
        ios_established = ios[ios.index("private func onSipInCall"):
                              ios.index("private func onSipIdle")]
        self.assertLess(ios_established.index("showInCall(streamUrl:"),
                        ios_established.index("if stream.isEmpty"))
        ios_show = ios[ios.index("private func showInCall"):
                       ios.index("private func closeInCall")]
        self.assertIn("callingView.isHidden = true", ios_show)
        ios_end = ios[ios.index("@objc private func onEndCallClick"):
                      ios.index("private func pollPeerFrame")]
        self.assertIn("core.sipHangup()", ios_end)
        self.assertIn("onSipIdle()", ios_end)

        windows = read("win/DoorbellApp/MainWindow.xaml.cs")
        win_dispatch = windows[windows.index('case "state":'):
                               windows.index('case "event":')]
        self.assertIn('stv == "in_call" || stv == "answered"', win_dispatch)
        win_established = windows[windows.index("private void OnSipInCall"):
                                  windows.index("private void OnSipIdle")]
        self.assertLess(win_established.index("ShowInCall(stream);"),
                        win_established.index("if (string.IsNullOrEmpty(stream))"))
        win_show = windows[windows.index("private void ShowInCall"):
                           windows.index("private void CloseInCall")]
        self.assertIn("CallingView.Visibility = Visibility.Collapsed", win_show)
        win_end = windows[windows.index("private void OnEndCallClick"):
                          windows.index("private void OnSipInCall")]
        self.assertIn("App.Core.SipHangup();", win_end)
        self.assertIn("OnSipIdle();", win_end)

    def test_semantic_ui_schema_is_narrow_and_lkg_is_atomic(self):
        contracts = read("win/DoorbellApp/Core/RuntimeContracts.cs")
        feature_block = contracts[contracts.index('{ "features",'):contracts.index(
            "public static Dictionary<string, object> Status")]
        for feature in ("platform_v2", "call_flow_v2", "call_cancel_v2",
                        "device_alert_v1", "ui_manifest_v1", "runtime_recovery_v1",
                        "helper_policy_v1"):
            self.assertIn(f'{{ "{feature}",', feature_block)

        semantic = read("win/DoorbellApp/Util/SemanticUiOverrides.cs")
        allowed_match = re.search(r"Allowed = .*?\{([^}]+)\}", semantic, re.S)
        self.assertIsNotNone(allowed_match)
        allowed = set(re.findall(r'"([a-z_]+)"', allowed_match.group(1)))
        self.assertEqual(allowed, {"scale", "font_scale", "foreground", "background",
                                   "accent", "border", "radius"})
        self.assertNotIn('"visible"', allowed_match.group(1))
        self.assertIn("File.Replace(temporary, path", semantic)
        self.assertIn("ui-overrides.lkg.json", semantic)
        self.assertIn('devices." + deviceId + ".local.ui.elements', semantic)
        self.assertIn("44 / scale", semantic)
        self.assertIn("style.Scale.Value < 1.0", semantic)
        self.assertIn("style.FontScale.Value < 1.0", semantic)
        self.assertIn('RuntimeContracts.UiDefaults(semanticId)', semantic)
        self.assertIn("SemanticColorSafety.HasContrast(foreground, background, 4.5)",
                      semantic)
        self.assertIn("SemanticColorSafety.HasContrast(outline, background, 3.0)", semantic)
        self.assertIn("color.A != 255", semantic)
        self.assertNotIn("color.A < 0x40", semantic)
        self.assertIn('"schema_version", 1', semantic)
        self.assertIn('"last_known_good"', semantic)
        self.assertIn('"last_error"', semantic)
        self.assertIn('"updated_at_ms"', semantic)
        self.assertIn("bool requiresHitTarget = c != null || safetyCritical", semantic)
        self.assertIn("scale < 1.0 ? 44 / scale : 44", semantic)
        self.assertIn("Math.Max(baseline.MinWidth, minimumHitTarget)", semantic)
        self.assertIn("Math.Max(baseline.MinHeight, minimumHitTarget)", semantic)

        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        self.assertIn('_semanticApplier.Apply(IncomingTitle,', window)
        # Publishing moved next to the contrast advisories it now carries.
        self.assertIn('PublishUiStyleWithAdvisories();', window)
        self.assertIn('App.Core.PublishUiStyleStatus(App.Boot.Role, App.SafeMode, report);',
                      read("win/DoorbellApp/MainWindow.Shell.cs"))
        manifest = contracts[contracts.index("public static Dictionary<string, object> UiManifest"):
                             contracts.index("public static string Json")]
        self.assertIn('AddElement(elements, "ring.title", false)', manifest)
        self.assertIn('SupportsUiManifest(string role)', contracts)
        self.assertIn('if (RuntimeContracts.SupportsUiManifest(role))',
                      read("win/DoorbellApp/Core/CoreClient.cs"))

    def test_sos_channels_are_rule_driven(self):
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        status = window[window.index("private void ApplyDisplayFromStatus"):
                        window.index("private void ApplyDisplay()")]
        emergency = window[window.index("private void ShowEmergency"):
                           window.index("private void OnEmergencyCancelClick")]
        dispatch = window[window.index('case "emergency":'):
                          window.index('case "peers_changed":')]
        notifier = read("win/DoorbellApp/DeviceAlertNotifier.cs")

        self.assertNotIn("ShowEmergency", status)
        self.assertIn('EventHasChannel(ev, "in_app")', emergency)
        self.assertIn('EventHasChannel(ev, "system_notification")', emergency)
        self.assertIn("bool hasSound", emergency)
        self.assertIn("volume > 0", emergency)
        self.assertIn("_emergencyPresentationTimeout", emergency)
        self.assertIn("bool sticky", emergency)
        self.assertIn("ExpireEmergencyPresentation", emergency)
        self.assertIn("PublishEmergencyReport", emergency)
        self.assertIn("ShowEmergency(ev)", dispatch)
        self.assertIn("public void Clear()", notifier)
        self.assertIn("NiifNoSound", notifier)
        self.assertIn("Shell_NotifyIcon", notifier)
        self.assertNotIn("Math.Min(30000", notifier)

        core_client = read("win/DoorbellApp/Core/CoreClient.cs")
        self.assertIn("PublishDeviceAlertStatus", core_client)
        self.assertIn('status["device_alert"] = _deviceAlertStatus', core_client)
        self.assertIn('status["ui_style"] = _uiStyleStatus', core_client)

        contracts = read("win/DoorbellApp/Core/RuntimeContracts.cs")
        self.assertIn('{ "device_alert_channels", new[] { "in_app", "system_notification" } }',
                      contracts)
        self.assertIn('"device_alert_channel_support"', contracts)
        self.assertIn('"permission", permission', contracts)
        self.assertIn("SystemNotificationAvailable()", contracts)
        self.assertIn("GetShellWindow()", notifier)

    def test_sos_presentation_colors_fall_back_when_contrast_is_unsafe(self):
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        palette = window[window.index("private string ApplyEmergencyPresentationColors"):
                         window.index("private static bool IsExactHexColor")]
        self.assertIn("SemanticColorSafety.HasContrast(foreground, background, 4.5)",
                      palette)
        self.assertIn("SemanticColorSafety.HasContrast(accent, background, 3.0)", palette)
        self.assertIn("EmergencyView.Background", palette)
        self.assertIn("EmergencyCancelButton.Background", palette)
        self.assertIn('"invalid_emergency_presentation_colors"', palette)
        emergency = window[window.index("private void ShowEmergency"):
                           window.index("private void HideEmergency")]
        self.assertIn("ApplyEmergencyPresentationColors(ev)", emergency)
        self.assertIn("colorLimitation", emergency)

    def test_safe_mode_retains_audio_controls_and_uses_low_resource_mjpeg(self):
        contracts = read("win/DoorbellApp/Core/RuntimeContracts.cs")
        capabilities = contracts[contracts.index("public static Dictionary<string, object> Capabilities"):
                                 contracts.index("public static Dictionary<string, object> Status")]
        status = contracts[contracts.index("public static Dictionary<string, object> Status"):
                           contracts.index("public static Dictionary<string, object> UiManifest")]
        self.assertIn('{ "mjpeg_http_preview", true }', capabilities)
        self.assertIn('{ "mjpeg_low_resolution", safeMode }', capabilities)
        self.assertIn('!safeMode && H264PlaybackCertified()', capabilities)
        self.assertIn('!safeMode && H264EncodeCertified()', capabilities)
        for retained in ('{ "core", "running" }', '{ "ringer", "available" }',
                         '{ "sos", "available" }', '{ "controls", "available" }'):
            self.assertIn(retained, status)
        self.assertIn('{ "media", safeMode ? "low_resolution_mjpeg"', status)
        self.assertIn('{ "sip_audio", string.Equals(sipBackend, "pjsip"', status)

    def test_runtime_health_is_persisted_measured_and_periodic(self):
        state = read("win/DoorbellApp/RuntimeProcessState.cs")
        app = read("win/DoorbellApp/App.xaml.cs")
        heartbeat = read("win/DoorbellApp/WatchdogHeartbeat.cs")
        contracts = read("win/DoorbellApp/Core/RuntimeContracts.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        for token in ('"generation"', '"last_exit_reason"', '"session_open"',
                      "FileOptions.WriteThrough", "output.Flush(true)",
                      "File.Replace(temporary, _path"):
            self.assertIn(token, state)
        self.assertIn('previousOpen ? "unexpected_termination"', state)
        self.assertIn("output.Length < 128", state)
        self.assertIn("RuntimeProcessState.Begin", app)
        self.assertIn("TimeSpan.FromSeconds(10)", app)
        self.assertIn("PublishRuntimeHealth", app)
        self.assertIn("public bool Available", heartbeat)
        self.assertIn("LastSignalWallMs", heartbeat)
        for field in ('status["generation"]', 'status["heartbeat_ms"]',
                      'status["last_exit_reason"]', 'status["safe_mode"]',
                      'status["helper_mode"]', 'status["components"]'):
            self.assertIn(field, contracts)
        self.assertIn("RuntimeContracts.ApplyProcessHealth", client)

        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        answer = window[window.index("private void OnAnswerClick"):
                        window.index("private void PlaceAnswerCall")]
        monitor = window[window.index("private void OnMonitorClick"):
                         window.index("private void OnIgnoreClick")]
        self.assertNotIn("App.SafeMode", answer)
        self.assertNotIn("App.SafeMode", monitor)
        # Safe mode never starts H.264; the guard moved into StartIncomingH264.
        self.assertIn("if (App.SafeMode || string.IsNullOrEmpty(_incomingStreamMp4Url)) return;",
                      window)
        self.assertIn("})), App.SafeMode);", window)
        self.assertIn("MjpegStreamer.Decode(jpg, App.SafeMode ? 640 : 0)", window)
        mjpeg = read("win/DoorbellApp/Core/MjpegStreamer.cs")
        self.assertIn("DateTime.UtcNow.AddMilliseconds(250)", mjpeg)
        self.assertIn("Decode(frame, _lowResource ? 640 : 0)", mjpeg)

    def test_manual_call_lifecycle_is_owned_and_monitor_never_claims_it(self):
        interop = read("win/DoorbellApp/Core/CoreInterop.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        contracts = read("win/DoorbellApp/Core/RuntimeContracts.cs")
        self.assertIn("db_core_report_call_answered_v2", interop)
        self.assertIn("db_core_report_call_ended_v2", interop)
        self.assertIn("public bool ReportCallAnswered", client)
        self.assertIn("public bool ReportCallEnded", client)
        self.assertIn('{ "call_lifecycle_v2", pjsip }', contracts)
        established = window[window.index("private void OnSipInCall"):
                             window.index("private void OnSipIdle")]
        monitor = window[window.index("private void OnMonitorClick"):
                         window.index("private void OnIgnoreClick")]
        self.assertIn('_sipMode == "answer"', established)
        self.assertIn("ReportCallAnswered", established)
        self.assertNotIn("ReportCallAnswered", monitor)
        self.assertIn('ev.Str("dialog_owner")', window)
        self.assertIn("owner != _nodeId", window)
        self.assertIn("_lifecycleEnded = true", window)
        recovery = window[window.index("private void RecoverCall"):
                          window.index("private static Dictionary<string, object> FindDoorPeer")]
        startup_recovery = window[window.index("private void RecoverActiveCall"):
                                  window.index("private void RecoverCall")]
        self.assertIn('status["active_calls"]', startup_recovery)
        self.assertIn('state == "ringing"', startup_recovery)
        self.assertIn('state == "in_call"', startup_recovery)
        self.assertIn("owner != _nodeId", recovery)
        self.assertIn('persistedState == "in_call" || eventState == "in_call"', recovery)
        self.assertIn("ReportRecoveryOnce(callId, false)", recovery)
        self.assertIn('persistedState == "ringing"', recovery)
        self.assertIn("expiry <= DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()", recovery)
        self.assertIn("ShowCalling(null, expiry)", recovery)
        self.assertIn("ReportRecoveryOnce(callId, true)", recovery)

    def test_higher_purpose_revision_demotes_losing_answer_and_keeps_ringing(self):
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        purpose = window[window.index("private bool HandlePurposeSelected"):
                         window.index("private void UpdateIncomingCallData")]
        self.assertIn("revision <= currentRevision", purpose)
        self.assertIn("!_monitorOnly", purpose)
        self.assertIn('_sipMode == "answer"', purpose)
        self.assertIn("_answerDelay.IsEnabled", purpose)
        self.assertIn("_lifecycleCallId = \"\"", purpose)
        self.assertIn("_suppressLosingSipIdle = true", purpose)
        self.assertIn("sip && !_suppressLosingSipIdle", window)
        self.assertLess(purpose.index("ShowIncoming(ev)"),
                        purpose.index("App.Core.SipHangup()"))

        idle = window[window.index("private void OnSipIdle"):
                      window.index("private void ReportLifecycleEndedIfNeeded")]
        losing_idle = idle[:idle.index("bool wasInCall")]
        self.assertIn("if (_suppressLosingSipIdle)", losing_idle)
        self.assertIn("IncomingView.Visibility == Visibility.Visible", losing_idle)
        self.assertIn("_incomingTimeout.Start()", losing_idle)
        self.assertIn("return;", losing_idle)
        self.assertNotIn("ReportLifecycleEndedIfNeeded", losing_idle)
        self.assertNotIn("CloseIncoming", losing_idle)

        chime_gate = window[window.index("private bool AcceptChimeRevision"):
                            window.index("private bool HandlePurposeSelected")]
        self.assertIn("revision <= accepted", chime_gate)
        chime_dispatch = window[window.index('case "chime":'):
                                window.index('case "call_recovery_required":')]
        self.assertLess(chime_dispatch.index("AcceptChimeRevision(ev)"),
                        chime_dispatch.index("ShowIncoming(ev)"))

    def test_release_build_requires_real_pjsip_for_both_arches(self):
        build = read("win/build.cmd")
        self.assertIn("DB_PJSIP_ROOT_X64", build)
        self.assertIn("DB_PJSIP_ROOT_X86", build)
        self.assertIn("DB_REQUIRE_PJSIP=ON", build)
        self.assertIn("DB_ALLOW_SIP_STUB", build)
        self.assertIn("doorbell-abi-probe.exe", build)
        self.assertIn("build-win-abi-x86", build)
        self.assertIn("DB_SIGN_CERT_SHA1", build)
        self.assertIn("sign-bundle.ps1", build)
        signing = read("win/tools/sign-bundle.ps1")
        self.assertIn("signtool sign", signing)
        self.assertIn("signtool verify", signing)
        self.assertIn("authenticode-sha256", build)
        self.assertIn("SHA256SUMS", read("win/tools/write-manifest.ps1"))

    def test_watchdog_restarts_app_not_windows(self):
        watchdog = read("win/watchdog/main.cpp")
        self.assertNotIn("ExitWindowsEx", watchdog)
        self.assertNotIn("EWX_REBOOT", watchdog)
        self.assertIn("kHeartbeatTimeoutMs", watchdog)
        self.assertIn("--safe-mode", watchdog)
        self.assertIn("CreateProcessAsUserW", watchdog)
        policy = read("win/watchdog/recovery_policy.h")
        self.assertIn("5ULL * 60ULL * 1000ULL", policy)
        self.assertIn("{{2, 5, 10, 30, 60}}", policy)
        self.assertIn("kSafeModeThreshold = 3", policy)

    def test_pairing_surfaces_bind_the_core_contract(self):
        interop = read("win/DoorbellApp/Core/CoreInterop.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        for symbol in ["db_core_start_pairing_json", "db_core_invite_direct",
                       "db_core_deny_device", "db_core_retry_pairing_persistence",
                       "db_core_unpair", "db_core_qr_encode", "db_core_qr_decode",
                       "db_core_qr_scan_start", "db_core_qr_scan_stop",
                       "db_core_on_camera_frame"]:
            with self.subTest(symbol=symbol):
                self.assertIn(symbol, interop)
                self.assertIn(symbol, client)
        for wrapper in ["public Dictionary<string, object> StartPairing(int seconds)",
                        "public void InviteDirect(string addr, string nodeId, "
                        "string publicKeyHex)",
                        "public void DenyDevice(string nodeId)",
                        "public bool RetryPairingPersistence()",
                        "public void Unpair()",
                        "public static byte[] QrEncode(string text, out int size)",
                        "public static string QrDecodeGray(byte[] gray, int width, int height)",
                        "public void QrScanStart()", "public void QrScanStop()"]:
            with self.subTest(wrapper=wrapper):
                self.assertIn(wrapper, client)
        # The probe proves the same exports exist in both architectures of the shipped DLL.
        probe = read("win/abi-probe/main.cpp")
        self.assertIn("9 * sizeof(void*)", probe)
        self.assertIn("db_core_qr_scan_start", probe)

    def test_onboarding_renders_core_state_and_never_infers_it(self):
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        view = read("win/DoorbellApp/Pairing/PairingOnboardingView.xaml.cs")
        snapshot = read("win/DoorbellApp/Pairing/PairingSnapshot.cs")
        # An empty snapshot is "unknown", never "unpaired".
        self.assertIn("if (!snapshot.Known) return;", window)
        self.assertIn("if (!snapshot.Known) return;", view)
        self.assertIn('root.ContainsKey("state")', snapshot)
        self.assertIn("bool ready = _pairing.IsReady;", window)
        self.assertIn("if (!ready && !_pairingSkipped && !PairingOverlay.IsActive) "
                      "ShowPairingOverlay();", window)
        self.assertIn("PairBanner.Visibility", window)
        self.assertIn("OpenAddDevicePanel", window)
        gate = window[window.index("private void OpenAddDevicePanel"):
                      window.index("private void OnSecretCorner")]
        self.assertIn("if (App.Boot.Kiosk && !_adminUnlocked)", gate)
        self.assertIn("new AdminDialog { Owner = this }", gate)
        # persist_error is only cleared by a successful retry, never by another button.
        self.assertIn("bool secondaryAllowed = !persistError && !ready && !joiningState;", view)
        self.assertIn("App.Core.RetryPairingPersistence()", view)
        self.assertIn("App.Core.FoundCluster()", view)
        self.assertIn("Mode.CreateConfirm", view)
        keypad = read("win/DoorbellApp/Pairing/PairingKeypad.xaml")
        for digit in "0123456789":
            self.assertIn('Content="%s" Tag="%s"' % (digit, digit), keypad)

    def test_add_device_panel_confirms_with_device_joined(self):
        panel = read("win/DoorbellApp/Pairing/AddDeviceWindow.xaml.cs")
        row = read("win/DoorbellApp/Pairing/PendingDeviceRow.cs")
        invite = panel[panel.index('case "invite_result":'):panel.index('case "device_joined":')]
        # invite_result only reports failures; success still shows "adding".
        self.assertIn("if (row != null && !EventBool(ev, \"ok\")) row.MarkFailed", invite)
        self.assertNotIn("MarkAdded", invite)
        joined = panel[panel.index('case "device_joined":'):panel.index('case "pending_changed":')]
        self.assertIn("row.MarkAdded();", joined)
        self.assertIn("App.Core.DenyDevice(id)", panel)
        self.assertIn("App.Core.Unpair()", panel)
        self.assertIn("ClearConfirmPanel", panel)
        self.assertIn("PairingText.AddAllOn", panel)
        self.assertIn('Texts.T("pair.add_all_stop")', panel)
        self.assertIn('Texts.T("pair.add_all_warning")', panel)
        self.assertIn('Texts.T("pair.adding")', row)
        self.assertIn('Texts.T("pair.added")', row)
        self.assertIn('Texts.T("pair.add_failed")', row)

    def test_qr_scanner_uses_the_core_decoder_and_reports_no_camera(self):
        scanner = read("win/DoorbellApp/Pairing/QrScanWindow.xaml.cs")
        feed = read("win/DoorbellApp/Pairing/PairingCameraFeed.cs")
        self.assertIn("App.Core.QrScanStart();", scanner)
        self.assertIn("App.Core.QrScanStop();", scanner)
        self.assertIn('case "qr_scanned":', scanner)
        self.assertIn('Texts.T("pair.scan_hint")', scanner)
        self.assertIn('Texts.T("pair.scan_no_camera")', scanner)
        self.assertIn("ShowCameraUnavailable();", scanner)
        self.assertIn("Viewfinder", read("win/DoorbellApp/Pairing/QrScanWindow.xaml"))
        # Frames reach the core decoder through the documented camera entry point.
        self.assertIn("App.Core.PushCameraFrame(bgra, 3, width, height, width * 4, now)", feed)
        self.assertIn("/stream.mjpeg", feed)

    def test_every_windows_string_key_is_generated_from_the_catalog(self):
        resources = read("win/DoorbellApp/Resources/Strings.resx")
        available = set(re.findall(r'<data name="([^"]+)"', resources))
        for path in sorted((WIN / "DoorbellApp").rglob("*.cs")):
            text = path.read_text(encoding="utf-8")
            for key in re.findall(r'(?:Texts|L10n)\.T\("([A-Za-z0-9_.]+)"', text):
                # "pair.err." is completed at runtime from the core error code.
                if key.endswith("."):
                    continue
                with self.subTest(path=path.name, key=key):
                    self.assertIn(key.replace(".", "_"), available)
        # No user-facing text is hardcoded in the new surfaces.
        for name in ("MainWindow.Shell.cs", "MainWindow.Dashboard.cs", "MainWindow.Notice.cs",
                     "MainWindow.History.cs", "MainWindow.CallScreen.cs",
                     "NoticeDialog.xaml.cs", "WebAdminWindow.xaml.cs"):
            text = (WIN / "DoorbellApp" / name).read_text(encoding="utf-8")
            for literal in re.findall(r'(?:Text|Content) = "([^"]+)"', text):
                if re.fullmatch(r"[0-9.:\-]*", literal):
                    continue  # numeric defaults are not prose
                with self.subTest(name=name, literal=literal):
                    self.fail("hardcoded user-facing text: " + literal)

    def test_pairing_surfaces_use_only_generated_resource_keys(self):
        resources = read("win/DoorbellApp/Resources/Strings.resx")
        available = set(re.findall(r'<data name="([^"]+)"', resources))
        sources = sorted((WIN / "DoorbellApp" / "Pairing").glob("*.cs"))
        sources.append(WIN / "DoorbellApp" / "MainWindow.xaml.cs")
        for path in sources:
            text = path.read_text(encoding="utf-8")
            for key in re.findall(r'Texts\.T\("(pair\.[a-z0-9_.]+)"', text):
                # "pair.err." is completed at runtime from the core error code.
                if key.endswith("."):
                    continue
                with self.subTest(path=path.name, key=key):
                    self.assertIn(key.replace(".", "_"), available)


    # ---- batch 2 (WP-N-win) ----------------------------------------------------------

    def test_power_state_spi_reports_battery_charging_and_mains(self):
        interop = read("win/DoorbellApp/Core/CoreInterop.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        device = read("win/DoorbellApp/Core/DeviceInfoProvider.cs")
        contracts = read("win/DoorbellApp/Core/RuntimeContracts.cs")

        self.assertIn("public delegate int PowerStateCb(IntPtr user, IntPtr jsonOut);", interop)
        # The same owned-buffer contract as device_info: core releases it with release_buffer.
        self.assertRegex(client, r"_powerStateCb = [\s\S]{0,400}"
                                 r"NativeUtf8\.Alloc\(DeviceInfoProvider\.PowerStateJson\(\)\)")
        for key in ('{ "battery_pct", percent }', '{ "charging", charging }',
                    '{ "mains", mains }'):
            self.assertIn(key, device)
        # A machine with no battery must report -1 rather than a fabricated level.
        self.assertIn("int percent = -1;", device)
        self.assertIn("status.BatteryFlag & 128", device)
        self.assertIn('{ "power_state", true }', contracts)

    def test_windows_has_no_native_settings_only_the_web_admin_entry(self):
        shell = read("win/DoorbellApp/MainWindow.Shell.cs")
        window = read("win/DoorbellApp/WebAdminWindow.xaml.cs")
        link = read("win/DoorbellApp/Util/AdminLink.cs")
        # The admin entry always asks for the admin password and then opens the web admin.
        entry = shell[shell.index("private void OnAdminEntryClick"):
                      shell.index("private void OpenWebAdmin")]
        self.assertIn("new AdminDialog { Owner = this }", entry)
        self.assertIn("OpenWebAdmin();", entry)
        self.assertIn("new WebAdminWindow(App.Boot.HttpPort)", shell)
        # QR, URL and an open button; the URL never points at loopback.
        self.assertIn("QrCodeImage.Render(url, 200)", window)
        self.assertIn('Texts.T("web_admin.open_browser")', window)
        self.assertIn("UseShellExecute = true", window)
        self.assertIn('"/admin/"', link)
        self.assertIn('text.StartsWith("127.", StringComparison.Ordinal)', link)
        # A door station shows no administration entry at all (spec 0.2).
        self.assertIn("AdminEntryButton.Visibility = door ? Visibility.Collapsed", shell)
        self.assertIn("AdminLinkCard.Visibility = door ? Visibility.Collapsed", shell)
        # No native settings screen was added.
        self.assertFalse((WIN / "DoorbellApp" / "SettingsWindow.xaml").exists())

    def test_sos_slides_then_counts_down_before_core_is_told(self):
        slider = read("win/DoorbellApp/Ui/SosSlider.cs")
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        self.assertIn("public class SosSlider : Slider", slider)
        self.assertIn("public const double ArmThreshold = 90.0;", slider)
        self.assertIn("bool armed = Value >= ArmThreshold;", slider)
        # Core learns about the emergency only when the countdown reaches zero.
        armed = window[window.index("private void OnSosArmed"):
                       window.index("private void OnSosCountdownTick")]
        self.assertNotIn("App.Core.Emergency(true)", armed)
        self.assertIn("SosCountdownView.Visibility = Visibility.Visible", armed)
        tick = window[window.index("private void OnSosCountdownTick"):
                      window.index("private void OnSosCountdownCancel")]
        self.assertIn("CommitEmergency();", tick)
        cancel = window[window.index("private void OnSosCountdownCancel"):
                        window.index("private void ShowEmergency")]
        self.assertNotIn("App.Core.Emergency", cancel)
        self.assertIn('CoreClient.Dig(cfg, "emergency.trigger.countdown_s")', window)
        self.assertNotIn('CoreClient.Dig(cfg, "emergency.hold_to_trigger_s")', window)
        # The two-part label breaks where the catalog says, and the second line is smaller.
        self.assertIn("sos.slide_label", window)
        xaml = read("win/DoorbellApp/MainWindow.xaml")
        self.assertIn('x:Name="SosSlide"', xaml)
        self.assertIn('x:Name="SosCountdownCancel"', xaml)

    def test_every_clock_is_rendered_with_the_cluster_clock(self):
        interop = read("win/DoorbellApp/Core/CoreInterop.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        dashboard = read("win/DoorbellApp/MainWindow.Dashboard.cs")
        self.assertIn("db_core_local_time_json", interop)
        self.assertIn("db_core_time_sync_now", interop)
        self.assertIn("public Dictionary<string, object> LocalTime(long wallMs)", client)
        clock = window[window.index("private void UpdateClock"):
                       window.index("private static string Weekday")]
        self.assertIn("CoreLocalTime(out time, out date)", clock)
        self.assertIn("DashClock.Text = time;", clock)
        # Call-history timestamps use the same corrected clock.
        self.assertIn("App.Core.LocalTime(wallMs)", dashboard)

    def test_dashboard_shows_tiles_history_versions_and_battery(self):
        xaml = read("win/DoorbellApp/MainWindow.xaml")
        shell = read("win/DoorbellApp/MainWindow.Shell.cs")
        dashboard = read("win/DoorbellApp/MainWindow.Dashboard.cs")
        history = read("win/DoorbellApp/MainWindow.History.cs")
        for name in ('DashboardHome', 'DoorTileGrid', 'RecentCallsList', 'MissedBadge',
                     'AdminQrImage', 'AdminUrlText', 'NoticeGlobalButton', 'HistoryView'):
            self.assertIn('x:Name="%s"' % name, xaml)
        # Five-second stills come from the door station's own snapshot endpoint.
        self.assertIn("TimeSpan.FromSeconds(5)", read("win/DoorbellApp/MainWindow.xaml.cs"))
        self.assertIn('"/snapshot.jpg"', dashboard)
        # Core version and app version are both shown, with the battery in the same line.
        self.assertIn('Texts.T("version.line", label, _coreVersion, _appVersion)', shell)
        self.assertIn('line += " · " + _batteryPct + "%"', shell)
        self.assertIn("if (_batteryPct >= 0)", shell)
        # History: 50 rows a page, day groups, filters and mark-seen on open.
        self.assertIn("private const int HistoryPageRows = 50;", history)
        self.assertIn("App.Core.CallLogMarkSeen(_latestCallHlc)", history)
        opened = history[history.index("private void OpenHistory"):
                         history.index("private void OnHistoryCloseClick")]
        self.assertIn("MarkHistorySeen();", opened)
        self.assertIn('_historyFilter == "missed"', history)

    def test_incoming_screen_controls_notice_chip_and_debug_line(self):
        xaml = read("win/DoorbellApp/MainWindow.xaml")
        call = read("win/DoorbellApp/MainWindow.CallScreen.cs")
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        streamer = read("win/DoorbellApp/Core/MjpegStreamer.cs")
        # One control row: monitor on/off, answer or end call, mic, unlock, quick replies.
        for name in ('MonitorButton', 'AnswerButton', 'MicButton', 'OpenDoorButton',
                     'QuickReplyToggle', 'EndCallButton', 'InCallMicButton',
                     'NoticeChip', 'CallAdminQrImage', 'VideoStatsText', 'PurposeSlot'):
            self.assertIn('x:Name="%s"' % name, xaml)
        # The purpose slot keeps its height so a later purpose never moves the controls.
        self.assertIn('x:Name="PurposeSlot" Height="36"', xaml)
        # Portrait door cameras are letterboxed, never cropped or stretched.
        self.assertNotIn('x:Name="IncomingLive" Stretch="UniformToFill"', xaml)
        self.assertIn('x:Name="IncomingLive" Stretch="Uniform"', xaml)
        self.assertIn('x:Name="PeerVideo" Stretch="Uniform"', xaml)
        # The debug line reads the player's own counters and is remembered per device.
        self.assertIn("public sealed class VideoStats", streamer)
        self.assertIn("X-Doorbell-Capture-Time-Ms", streamer)
        self.assertIn("X-Doorbell-Server-Time-Ms", streamer)
        self.assertIn('Texts.T("video.stats", codec, latency, jitter, fps, dropped)', call)
        self.assertIn("SaveVideoStatsPreference();", call)
        # The microphone toggle only exists when core can honour it.
        self.assertIn("if (!App.Core.SipMicMuteAvailable) return;", call)
        self.assertIn("db_core_sip_set_mic_muted", read("win/DoorbellApp/Core/CoreClient.cs"))
        # Unlock stays, gated by the admin setting, and explains itself when unconfigured.
        self.assertIn('"doors." + (door ?? "") + ".unlock.show_button"', window)
        self.assertIn('Texts.T("unlock.not_configured")', window)

    def test_announcements_have_three_entry_points_and_editable_presets(self):
        notice = read("win/DoorbellApp/MainWindow.Notice.cs")
        dialog = read("win/DoorbellApp/NoticeDialog.xaml.cs")
        # Door-specific wins over the global announcement.
        effective = notice[notice.index("private Dictionary<string, object> EffectiveNotice"):
                           notice.index("private static string NoticeText")]
        self.assertLess(effective.index('".notice"'), effective.index('"notice.global"'))
        # Entry points: dashboard button, door tile chip, chip on the monitor screen.
        self.assertIn("private void OnGlobalNoticeClick", notice)
        self.assertIn("private void OnTileNoticeChipClick", notice)
        self.assertIn("private void OnNoticeChipClick", read(
            "win/DoorbellApp/MainWindow.Notice.cs"))
        self.assertIn('CoreClient.Dig(_cfg, "notice.presets")', notice)
        # The visitor screen shows the text only, with no source or expiry line.
        visitor = notice[notice.index("private void RefreshNoticeSurfaces"):
                         notice.index("private void RefreshTileNoticeChip")]
        self.assertNotIn("from_device", visitor)
        self.assertNotIn("expires_ms", visitor)
        # 200 characters, expiry presets and a target selector.
        self.assertIn("private const int MaxCharacters = 200;", dialog)
        for preset in ('"1h"', '"today"', '"until_cleared"', '"custom"'):
            self.assertIn(preset, dialog)
        self.assertIn('Texts.T("notice.target_global")', dialog)

    def test_appearance_and_automatic_contrast_follow_the_shared_decision(self):
        appearance = read("win/DoorbellApp/Util/Appearance.cs")
        contrast = read("win/DoorbellApp/Util/ThemeContrast.cs")
        shell = read("win/DoorbellApp/MainWindow.Shell.cs")
        app_xaml = read("win/DoorbellApp/App.xaml")
        # Windows releases without a system light/dark setting fall back to the schedule.
        self.assertIn("AppsUseLightTheme", appearance)
        self.assertIn("return ScheduleAppearance(config, localTime);", appearance)
        self.assertIn('"display.appearance_schedule.dark_from"', appearance)
        self.assertIn('"devices." + nodeId + ".local.display.appearance"', appearance)
        # An admin override wins over everything, then core's published decision, then the
        # local rule, which picks whichever ink actually reads better.
        decide = contrast[contrast.index("public static InkDecision Decide("):
                          contrast.index("public static bool CoreSampledBackground")]
        self.assertLess(decide.index("ink_override"), decide.index("auto_ink"))
        self.assertIn("decision.Ink = BetterInk(background);", decide)
        self.assertNotIn("Luminance(background) >= 0.5", contrast)
        button = contrast[contrast.index("public static Color CallButton("):
                          contrast.index("public static Color LocalAccent")]
        self.assertLess(button.index("call_button_bg"), button.index("auto_accent"))
        self.assertIn("h = (h + 180.0) % 360.0;", contrast)
        self.assertIn("onBackground >= 3.0 && onText >= 4.5", contrast)
        # A colour that misses its target is still applied and only warned about.
        self.assertIn("if (ratio >= minimum) return null;", contrast)
        self.assertIn('report["contrast_advisories"] = advisories;', shell)
        # Palette swaps only reach the UI when every consumer uses DynamicResource.
        self.assertNotIn("{StaticResource Bg}", read("win/DoorbellApp/MainWindow.xaml"))
        self.assertIn('<SolidColorBrush x:Key="Line"', app_xaml)

    def test_ink_is_refined_per_region_over_a_background_image(self):
        contrast = read("win/DoorbellApp/Util/ThemeContrast.cs")
        shell = read("win/DoorbellApp/MainWindow.Shell.cs")
        # Core has no layout geometry, so its auto_ink is one whole-image average. The shell has
        # the geometry and samples only the pixels under each element.
        self.assertIn("public static bool TryAverageRegion(BitmapSource source, Int32Rect crop,",
                      contrast)
        self.assertIn("public static Int32Rect MapUniformToFill(", contrast)
        # The mapping matches Stretch=UniformToFill: scale to cover, centre the overflow.
        mapping = contrast[contrast.index("public static Int32Rect MapUniformToFill("):
                           contrast.index("public static InkDecision Decide(")]
        self.assertIn("Math.Max(viewport.Width / imageWidth, viewport.Height / imageHeight)",
                      mapping)
        self.assertIn("(viewport.Width - imageWidth * scale) / 2.0", mapping)
        # Downscale to at most 16x16 before averaging, per the spec's sampling rule.
        average = contrast[contrast.index("public static bool TryAverage(BitmapSource source"):
                           contrast.index("public static bool TryAverageRegion")]
        self.assertIn("16.0 / Math.Max(1, source.PixelWidth)", average)
        self.assertIn("0.2126 * Channel(color.R)", contrast)
        # A per-region sample, and any opaque surface core never saw, decide locally.
        decide = contrast[contrast.index("public static InkDecision Decide("):
                          contrast.index("public static bool TryContractBackground")]
        self.assertIn("object auto = decideLocally ? null", decide)
        self.assertIn("decision.NeedsShadow = Ratio(decision.Ink, background) < 4.5;", decide)
        # The outline is the opposite of whatever ink was chosen, admin colours included.
        self.assertIn("decision.Shadow = BetterInk(decision.Ink);", decide)
        under = shell[shell.index("private Color BackgroundUnder("):
                      shell.index("private static Color? SurfaceColour(")]
        self.assertIn("decideLocally = true;", under)
        self.assertIn("ThemeContrast.MapUniformToFill(bitmap,", under)
        self.assertIn("element.TransformToAncestor(this).Transform(new Point(0, 0))", under)
        # The outline is 40 % of the opposite ink and only appears when contrast falls short.
        outline = shell[shell.index("private static DropShadowEffect OutlineFor("):
                        shell.index("private Color BackgroundUnder(")]
        self.assertIn("Opacity = 0.4", outline)
        self.assertIn("decision.NeedsShadow ? OutlineFor(decision.Shadow) : null", shell)
        # Every region the spec lists, across the dashboard, visitor screen and call screens.
        applied = shell[shell.index("private void ApplyAutoInk()"):
                        shell.index("private void InkText(")]
        for element, region in (("ClockText", "RegionClock"), ("DashClock", "RegionClock"),
                                ("DateText", "RegionDate"), ("DashDate", "RegionDate"),
                                ("TouchHint", "RegionHint"), ("NodeInfo", "RegionFooter"),
                                ("VisitorVersionLine", "RegionFooter"),
                                ("VisitorNoticeText", "RegionNotice"),
                                ("MembershipText", "RegionStatusLine"),
                                ("IncomingTitle", "RegionStatusLine"),
                                ("InCallTitle", "RegionStatusLine"),
                                ("IncomingHint", "RegionHint")):
            with self.subTest(element=element):
                self.assertIn("InkText(%s, %s," % (element, region), applied)
        self.assertIn("foreach (TextBlock label in _tileLabels) InkText(label, RegionTileLabel",
                      applied)
        # Region ids are core's own list.
        for region in ("clock", "date", "status_line", "hint", "tile_label", "footer", "notice"):
            with self.subTest(region=region):
                self.assertIn('= "%s";' % region, shell)

    def test_automatic_ink_picks_the_higher_contrast_of_the_two(self):
        """The decision is a WCAG contrast comparison, not a luminance threshold at 0.5.

        A real wallpaper averaging #BBBBB4 sits at Y = 0.494, just under the old threshold, and
        took light ink at 1.7:1 where dark ink gives 9.0:1. Comparing the ratios finds the true
        crossover, near Y = 0.179, exactly.
        """
        contrast = read("win/DoorbellApp/Util/ThemeContrast.cs")
        found = re.findall(
            r"public static readonly Color (LightInk|DarkInk) = "
            r"Color\.FromRgb\(0x([0-9A-Fa-f]{2}), 0x([0-9A-Fa-f]{2}), 0x([0-9A-Fa-f]{2})\);",
            contrast)
        self.assertEqual(len(found), 2, "both ink tokens must be declared as literal colours")
        inks = {name: (int(r, 16), int(g, 16), int(b, 16)) for name, r, g, b in found}

        def channel(value):
            value /= 255.0
            return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4

        def luminance(rgb):
            return (0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) +
                    0.0722 * channel(rgb[2]))

        def ratio(first, second):
            a, b = luminance(first), luminance(second)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)

        def better(background):
            return ("DarkInk" if ratio(inks["DarkInk"], background) >=
                    ratio(inks["LightInk"], background) else "LightInk")

        # The wallpaper from the device report, and a dark grey that must stay light.
        self.assertEqual(better((0xBB, 0xBB, 0xB4)), "DarkInk")
        self.assertEqual(better((0x40, 0x40, 0x40)), "LightInk")
        # The chosen ink is always the readable one, and the old rule was not.
        self.assertGreater(ratio(inks["DarkInk"], (0xBB, 0xBB, 0xB4)), 4.5)
        self.assertLess(ratio(inks["LightInk"], (0xBB, 0xBB, 0xB4)), 4.5)
        self.assertLess(luminance((0xBB, 0xBB, 0xB4)), 0.5)  # why the old threshold failed
        # The crossover sits low in the range, near Y = 0.19 for these two tokens, not at 0.5.
        self.assertEqual(better((0x7A, 0x7A, 0x7A)), "DarkInk")   # Y 0.195, just above it
        self.assertEqual(better((0x76, 0x76, 0x76)), "LightInk")  # Y 0.181, just below it
        crossover = math.sqrt((luminance(inks["LightInk"]) + 0.05) *
                              (luminance(inks["DarkInk"]) + 0.05)) - 0.05
        self.assertLess(crossover, 0.25)
        self.assertGreater(crossover, 0.10)
        # And the implementation is that comparison.
        rule = contrast[contrast.index("public static Color BetterInk("):
                        contrast.index("public static double Ratio(")]
        self.assertIn("Ratio(DarkInk, background) >= Ratio(LightInk, background)", rule)
        # Every local decision goes through it, including the call-button direction.
        self.assertIn("bool preferDark = BetterInk(background) == DarkInk;", contrast)

    def test_core_theme_values_are_dropped_when_core_never_read_the_image(self):
        contrast = read("win/DoorbellApp/Util/ThemeContrast.cs")
        shell = read("win/DoorbellApp/MainWindow.Shell.cs")
        # auto_background.source "image_unsampled" means a background image is configured but
        # core could not read it, so its colour, ink and accent describe the flat theme colour.
        self.assertIn('source.ToString() != "image_unsampled"', contrast)
        self.assertIn("if (!CoreSampledBackground(display)) return false;", contrast)
        self.assertIn("decideLocally |= !ThemeContrast.CoreSampledBackground(_display);", shell)
        # The administrator's own call-button colour still applies; core's accent does not.
        button = contrast[contrast.index("public static Color CallButton("):
                          contrast.index("public static Color CallButtonInk(")]
        self.assertIn("if (!CoreSampledBackground(display))", button)
        self.assertIn('"devices." + nodeId + ".local.theme.call_button_bg"', button)
        self.assertIn("return LocalAccent(background);", button)

    def test_the_footer_and_the_sos_slider_never_overlap(self):
        shell = read("win/DoorbellApp/MainWindow.Shell.cs")
        xaml = read("win/DoorbellApp/MainWindow.xaml")
        # The reserved space is derived from the slider's real footprint, not a hardcoded column.
        self.assertIn('x:Name="DashboardSosColumn" Width="0"', xaml)
        self.assertNotIn('<ColumnDefinition Width="250"/>', xaml)
        numbers = dict(re.findall(
            r"private const double (\w+) = ([0-9.]+);", shell))
        for name in ("SosBarWidth", "SosBarHeight", "SosBarMargin", "SosBarBottom",
                     "SosClearance", "FooterMinimumWidth"):
            self.assertIn(name, numbers)
        reserved_width = (float(numbers["SosBarWidth"]) + float(numbers["SosBarMargin"]) +
                          float(numbers["SosClearance"]))
        reserved_height = (float(numbers["SosBarHeight"]) + float(numbers["SosBarBottom"]) +
                           float(numbers["SosClearance"]))
        # Whichever way it is placed, the reservation is strictly larger than the slider plus its
        # margin, so the footer cannot reach it.
        self.assertGreater(reserved_width,
                           float(numbers["SosBarWidth"]) + float(numbers["SosBarMargin"]))
        self.assertGreater(reserved_height,
                           float(numbers["SosBarHeight"]) + float(numbers["SosBarBottom"]))
        layout = shell[shell.index("private void LayOutSosAndFooters("):]
        # Beside the footer only when the footer still gets its minimum width; otherwise the
        # slider becomes a full-width band and the footers reserve height above it.
        self.assertIn("portrait || width < SosReservedWidth + FooterMinimumWidth", layout)
        self.assertIn("DashboardSosColumn.Width = new GridLength(reserveWidth);", layout)
        self.assertIn("DashboardFooter.Margin = new Thickness(0, 0, 0, reserveHeight);", layout)
        self.assertIn("VisitorFooter.Margin = new Thickness(0, 12, reserveWidth, reserveHeight);",
                      layout)
        # Exactly one of the two reservations is ever non-zero.
        self.assertIn("double reserveWidth = sosVisible && !sosBelow ? SosReservedWidth : 0;",
                      layout)
        self.assertIn("double reserveHeight = sosBelow ? SosReservedHeight : 0;", layout)
        self.assertIn("LayOutSosAndFooters(width, portrait);", shell)
        # Sampling needs arranged bounds, so the ink pass runs after the layout it triggered.
        self.assertIn("DispatcherPriority.Loaded", shell)
        self.assertIn("QueueInkPass();", shell)

    def test_coloured_labels_keep_their_padding(self):
        # Any text drawn on a coloured background gets at least 6 vertical / 12 horizontal
        # padding with a radius (spec 5, rule 7).
        for name in ("MainWindow.xaml", "App.xaml", "AdminDialog.xaml", "NoticeDialog.xaml",
                     "WebAdminWindow.xaml"):
            text = read("win/DoorbellApp/" + name)
            for padding in re.findall(r'Padding="(\d+),(\d+)"', text):
                horizontal, vertical = int(padding[0]), int(padding[1])
                with self.subTest(name=name, padding=padding):
                    self.assertGreaterEqual(horizontal, 12)
                    self.assertGreaterEqual(vertical, 6)
        code = read("win/DoorbellApp/MainWindow.Dashboard.cs")
        self.assertIn("new Thickness(12, 6, 12, 6)", code)

    def test_responsive_layout_is_computed_from_the_window_size(self):
        shell = read("win/DoorbellApp/MainWindow.Shell.cs")
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        self.assertIn("SizeChanged += (s, e) => ApplyResponsiveLayout();", window)
        layout = shell[shell.index("private void ApplyResponsiveLayout"):
                       shell.index("private static void PlaceVisitor")]
        self.assertIn("bool portrait = height >= width || width < 900;", layout)
        # Portrait stacks; landscape splits into two columns.
        self.assertIn("VisitorRightColumn.Width = new GridLength(0);", layout)
        self.assertIn("PlaceVisitor(LangBar, 2, 1, 1, 1);", layout)
        self.assertIn("PlaceDashboard(RecentCallsPanel, 1, 0, 2);", layout)
        self.assertIn("PlaceDashboard(RecentCallsPanel, 0, 1, 1);", layout)
        # Tablets scale the call button and the hint.
        self.assertIn("CallButton.MinHeight = large ? 170 : (tablet ? 120 : 96);", layout)

    def test_effective_volumes_reach_the_players(self):
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        self.assertIn("public Dictionary<string, object> AudioVolumes(string deviceId)", client)
        self.assertIn("db_core_audio_json", read("win/DoorbellApp/Core/CoreInterop.cs"))
        self.assertIn("_volumeCall = Clamp(DictInt(levels, \"call\", _volumeCall));", window)
        self.assertIn("Volume = volumePercent < 0 ? 1.0 : Clamp(volumePercent) / 100.0", window)
        self.assertIn('SoundValue("call_sound", "outdoor_call_alert"),\n'
                      '                ConfigBool("ui.call_sound_loop", false), null, '
                      '_volumeCall);', window)
        self.assertIn('DictInt(ev.Data, "alarm_volume", _volumeSos)', window)

    def test_pairing_pin_never_opens_the_bulk_add_window(self):
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        interop = read("win/DoorbellApp/Core/CoreInterop.cs")
        onboarding = read("win/DoorbellApp/Pairing/PairingOnboardingView.xaml.cs")
        panel = read("win/DoorbellApp/Pairing/AddDeviceWindow.xaml.cs")
        probe = read("win/abi-probe/main.cpp")
        self.assertIn("public delegate IntPtr MintJoinTokenFn(IntPtr core, int seconds);",
                      interop)
        # Bound through the shared GetProcAddress probe, never as a hard DllImport, so an older
        # Core reports "no PIN minted" instead of terminating the shell. Core now exports it, so
        # the release gate requires it.
        self.assertNotIn("extern IntPtr db_core_mint_join_token_json", interop)
        self.assertIn("db_core_mint_join_token_json", required_probe_exports(probe))
        self.assertIn('CoreInterop.OptionalExport<CoreInterop.MintJoinTokenFn>(\n'
                      '                    "db_core_mint_join_token_json")', client)
        self.assertIn("public Dictionary<string, object> MintJoinToken(int seconds)", client)
        # Founding a Cluster shows the PIN card without auto-adding anything.
        request = onboarding[onboarding.index("private void RequestNewCode"):]
        self.assertIn("App.Core.MintJoinToken(600)", request)
        self.assertNotIn("StartPairing", request)
        panel_request = panel[panel.index("private void RequestNewCode"):
                              panel.index("private void OnAddAllClick")]
        self.assertIn("App.Core.MintJoinToken(TokenSeconds)", panel_request)
        self.assertNotIn("StartPairing", panel_request)
        # Only the explicit bulk-add button opens the pairing-mode window.
        add_all = panel[panel.index("private void OnAddAllClick"):
                        panel.index("private void OnScanQrClick")]
        self.assertIn("App.Core.StartPairing(PairingModeSeconds)", add_all)
        self.assertIn('AddAllWarning.Text = Texts.T("pair.add_all_warning")', panel)

    def test_revoke_resets_the_device_to_first_run_setup(self):
        app = read("win/DoorbellApp/App.xaml.cs")
        boot = read("win/DoorbellApp/BootConfig.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        reset = app[app.index("internal static void FactoryResetAndRestart"):
                    app.index("private static bool _factoryResetStarted;")]
        self.assertIn('Core?.DeleteSecret("mesh.psk")', reset)
        self.assertIn("BootConfig.ResetToFactory(Boot.FilePath)", reset)
        self.assertIn("app.Shutdown(0)", reset)
        self.assertIn('if (ev.T == "pairing_revoked")', app)
        self.assertIn('FactoryResetAndRestart("pairing_revoked")', app)
        # Leaving the Cluster from this device resets it the same way; a device that was never
        # paired is left alone so a fresh install does not loop through setup.
        self.assertIn('FactoryResetAndRestart("unpaired")', app)
        self.assertIn("!string.IsNullOrEmpty(Boot.PskRef)", app)
        factory = boot[boot.index("public static bool ResetToFactory"):
                       boot.index("private static void AddUnique")]
        for cleared in ('data["role"] = ""', 'data["setup_complete"] = false',
                        'data["name"] = "doorbell"'):
            self.assertIn(cleared, factory)
        self.assertNotIn("psk_ref", factory)
        self.assertNotIn("seed_peers", factory)
        self.assertIn("public bool DeleteSecret(string key)", client)
        # The window no longer clears only the boot reference on a revoke.
        revoked = window[window.index('case "pairing_revoked":'):
                         window.index('case "pairing_state":')]
        self.assertNotIn("App.ClearPairingBootReference()", revoked)


    # ---- spec 5.5: one admin password, native write ABI, mic mute ---------------------

    def test_every_optional_core_export_is_probed_not_hard_linked(self):
        interop = read("win/DoorbellApp/Core/CoreInterop.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        probe = read("win/abi-probe/main.cpp")
        # Core exports all of these now, so the release gate requires them. The shell still binds
        # them through GetProcAddress rather than a hard DllImport, so a device left on an older
        # Core hides or degrades the feature instead of terminating at the first call.
        probed = {
            "db_core_mint_join_token_json", "db_core_admin_password_verify",
            "db_core_admin_password_set", "db_core_set_config_json",
            "db_core_last_write_warnings_json", "db_core_config_batch_json",
            "db_core_delete_config_key", "db_core_call_log_json_v2",
            "db_core_sip_set_mic_muted",
        }
        required = required_probe_exports(probe)
        for symbol in sorted(probed):
            with self.subTest(symbol=symbol):
                self.assertIn('"%s"' % symbol, client)
                self.assertIn(symbol, required)
                self.assertNotIn("extern IntPtr " + symbol, interop)
                self.assertNotIn("extern int " + symbol, interop)
        self.assertIn("private void ProbeOptionalExports()", client)
        # Nothing is left warning-only now that core exports the whole set.
        self.assertNotIn("kPendingExports", probe)

    def test_admin_password_is_one_cluster_secret(self):
        dialog = read("win/DoorbellApp/AdminDialog.xaml.cs")
        xaml = read("win/DoorbellApp/AdminDialog.xaml")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        # The cluster password is text, so the keypad types into a real password box.
        self.assertIn('<PasswordBox x:Name="PasswordEntry"', xaml)
        self.assertIn("PasswordEntry.Password", dialog)
        # Core decides, with the agreed codes: >0 accepted, 0 rejected, -1 locked out,
        # -2 no cluster password set yet. Only an explicit positive answer opens anything.
        verify = client[client.index("public AdminPasswordVerdict AdminPasswordVerify"):
                        client.index("public bool AdminPasswordSet")]
        self.assertIn("if (result > 0) return AdminPasswordVerdict.Accepted;", verify)
        self.assertIn("if (result == 0) return AdminPasswordVerdict.Rejected;", verify)
        self.assertIn("if (result == -1) return AdminPasswordVerdict.LockedOut;", verify)
        self.assertIn("if (result == -2) return AdminPasswordVerdict.NotSet;", verify)
        submit = dialog[dialog.index("private void Submit()"):
                        dialog.index("private void Accept()")]
        self.assertIn("App.Core.AdminPasswordVerify(password)", submit)
        self.assertIn("if (verdict == AdminPasswordVerdict.Accepted)", submit)
        # A cluster that already has a password is never opened with a stale device digest.
        self.assertIn("App.Core.AdminPasswordConfigured", submit)
        self.assertLess(submit.index("AdminPasswordConfigured"),
                        submit.index("Sha256Hex(password) != LocalDigest()"))
        # -2 asks the operator to choose the household password and publishes it.
        self.assertIn("if (verdict == AdminPasswordVerdict.NotSet)", submit)
        self.assertIn('App.Core.AdminPasswordSet("", password)', submit)
        self.assertIn('"admin.password_set_prompt"', dialog)
        self.assertIn('"admin.password_set_failed"', dialog)
        # A core-owned lockout is never worked around with the local digest.
        locked = submit[submit.index("AdminPasswordVerdict.LockedOut"):]
        self.assertLess(locked.index('L10n.T("admin.locked")'),
                        locked.index("Sha256Hex(password) != LocalDigest()"))
        # The local five-failure, ten-minute lockout stays as a second line of defence.
        self.assertIn("_lockedUntil = DateTime.Now.AddMinutes(10);", dialog)
        self.assertIn("if (++_fails >= 5)", dialog)

    def test_an_unset_password_never_traps_a_running_alarm(self):
        window = read("win/DoorbellApp/MainWindow.xaml.cs")
        dialog = read("win/DoorbellApp/AdminDialog.xaml.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        cancel = window[window.index("private void OnEmergencyCancelClick"):
                        window.index("private void StartSiren")]
        self.assertIn("if (_cancelRequiresPin && !AdminDialog.ClusterPasswordUnset())", cancel)
        self.assertIn("if (App.Core.Emergency(false)) HideEmergency()", cancel)
        self.assertIn("internal static bool ClusterPasswordUnset()", dialog)
        self.assertIn("return AdminPasswordAvailable && !AdminPasswordConfigured;", client)
        # Core folds "a password is actually set" into the flag the shell reads, and the header
        # forbids gating the clear control on emergency.cancel_requires_pin alone.
        sos = window[window.index("private void RefreshSosConfig"):
                     window.index("private void ApplySosLabel")]
        self.assertIn("App.Core.EmergencyCancelRequiresPassword(_status)", sos)
        self.assertLess(sos.index("EmergencyCancelRequiresPassword"),
                        sos.index('"emergency.cancel_requires_pin"'))
        self.assertIn('Dig(status, "emergency.cancel_requires_password")', client)
        # Once core can verify, this device stops keeping a second way in.
        self.assertIn("private static void DropLocalDigest()", dialog)
        self.assertIn("File.Delete(f)", dialog)
        accepted = dialog[dialog.index("if (verdict == AdminPasswordVerdict.Accepted)"):
                          dialog.index("if (verdict == AdminPasswordVerdict.Rejected)")]
        self.assertIn("DropLocalDigest();", accepted)

    def test_global_notice_and_history_paging_use_the_new_abi(self):
        notice = read("win/DoorbellApp/MainWindow.Notice.cs")
        history = read("win/DoorbellApp/MainWindow.History.cs")
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        # 全体 is the door target "*", and a door-specific announcement still wins over it.
        self.assertIn('public const string GlobalNoticeDoor = "*";', client)
        self.assertIn("return SetDoorNotice(GlobalNoticeDoor, text, expiresMs);", client)
        self.assertIn("return ClearDoorNotice(GlobalNoticeDoor);", client)
        self.assertIn("App.Core.SetGlobalNotice(dialog.NoticeBody, dialog.ExpiresMs)", notice)
        self.assertIn("App.Core.ClearGlobalNotice()", notice)
        # 50 rows a page with an exclusive before_ms upper bound.
        page = history[history.index("private void LoadHistoryPage"):
                       history.index("private void OnHistoryCloseClick")]
        self.assertIn("App.Core.CallLogPage(0, _historyBeforeMs, HistoryPageRows)", page)
        self.assertIn("_historyBeforeMs = oldest;", page)
        self.assertIn("public Dictionary<string, object> CallLogPage(long sinceMs, "
                      "long beforeMs, int limit)", client)
        # The growing-limit fallback stays for a core without before_ms.
        self.assertIn("App.Core.CallLog(0, _historyLimit)", page)

    def test_native_config_writes_are_prepared(self):
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        interop = read("win/DoorbellApp/Core/CoreInterop.cs")
        # A single write and a key deletion answer with a status code; only the batch returns an
        # owned document, shaped like /api/config/batch so its warnings can be rendered.
        self.assertIn("public delegate int SetConfigJsonFn(IntPtr core,", interop)
        self.assertIn("public delegate int DeleteConfigKeyFn(IntPtr core,", interop)
        self.assertIn("public delegate IntPtr ConfigBatchJsonFn(IntPtr core,", interop)
        self.assertIn("public delegate IntPtr LastWriteWarningsFn(IntPtr core);", interop)
        # One write takes the key and the JSON-encoded value, exactly like POST /api/config.
        self.assertIn("public bool SetConfigJson(string key, string valueJson)", client)
        self.assertIn("_setConfigJson(_core, key, valueJson", client)
        self.assertIn("public bool DeleteConfigKey(string key)", client)
        self.assertIn("public string ConfigBatchJson(string json)", client)
        self.assertIn("public string LastWriteWarnings()", client)
        self.assertIn("_deleteConfigKey(_core, key) == 0", client)
        self.assertIn("CoreInterop.TakeUtf8(_configBatchJson(_core, json))", client)
        self.assertNotIn("ConfigResult", client)

    def test_mic_mute_follows_the_replicated_call_state(self):
        shell = read("win/DoorbellApp/MainWindow.Shell.cs")
        call = read("win/DoorbellApp/MainWindow.CallScreen.cs")
        self.assertIn('CoreClient.Dig(status, "call")', shell)
        self.assertIn('call.ContainsKey("mic_muted")', shell)
        self.assertIn("App.Core.SipSetMicMuted(wanted)", call)


if __name__ == "__main__":
    unittest.main(verbosity=2)
