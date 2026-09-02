#!/usr/bin/env python3
"""Host-runnable contract checks for the Windows client (no Windows SDK needed)."""

from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
WIN = ROOT / "win"


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


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
                     *sorted((WIN / "DoorbellApp" / "Resources").glob("*.resx"))]:
            with self.subTest(path=path.name):
                ET.parse(path)

    def test_platform_v2_layout_and_owned_buffers(self):
        source = read("win/DoorbellApp/Core/CoreInterop.cs")
        fields = re.findall(r"public (?:uint|IntPtr) (\w+);",
                            source[source.index("struct DbPlatformV2"):source.index(
                                "delegate void LogLineCb")])
        self.assertEqual(fields, ["struct_size", "version", "user", "https_request",
                                 "secure_get", "secure_put", "log_line", "tts_speak",
                                 "device_info", "release_buffer"])
        client = read("win/DoorbellApp/Core/CoreClient.cs")
        self.assertIn("Marshal.SizeOf(typeof(CoreInterop.DbPlatformV2))", client)
        self.assertIn("Marshal.FreeHGlobal(buffer)", client)
        self.assertIn("db_core_create_v2", client)

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
            "android/app/src/main/java/jp/keihan/doorbell/DoorbellCore.kt")
        android_jni = read("android/app/src/main/cpp/jni_bridge.cpp")
        android_app = read("android/app/src/main/java/jp/keihan/doorbell/App.kt")
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
        android_app = read("android/app/src/main/java/jp/keihan/doorbell/App.kt")
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
            "android/app/src/main/java/jp/keihan/doorbell/BootConfig.kt")
        self.assertIn('d.remove("psk_hex")', android_boot)
        self.assertIn('d.put("psk_ref", "secret:mesh.psk")', android_boot)
        self.assertIn("writeAndRename(backup, js)", android_boot)
        self.assertIn("writeAndRename(file, js)", android_boot)
        android_core = read(
            "android/app/src/main/java/jp/keihan/doorbell/DoorbellCore.kt")
        secure_put = android_core[android_core.index("private fun onSecurePutFromNative"):
                                  android_core.index("private fun onDeviceInfoFromNative")]
        self.assertIn("secureStore.put(key, value)", secure_put)
        pairing_ui = read(
            "android/app/src/main/java/jp/keihan/doorbell/PairingActivity.kt")
        self.assertIn("pairingPersistence.canMarkReady", pairing_ui)

    def test_android_helper_policy_uses_only_the_fixed_local_protocol(self):
        client = read(
            "android/app/src/main/java/jp/keihan/doorbell/RootKeepaliveClient.kt")
        supervisor = read(
            "android/app/src/main/java/jp/keihan/doorbell/RuntimeSupervisor.kt")
        controller = read(
            "android/app/src/main/java/jp/keihan/doorbell/KioskController.kt")
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
        self.assertIn('SipSendDtmf("*1")', window)

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
        self.assertIn('PublishUiStyleStatus', window)
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
        self.assertIn("if (!App.SafeMode && !string.IsNullOrEmpty(_incomingStreamMp4Url))",
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
