#!/usr/bin/env python3
"""Host-runnable recovery and safe-mode contract checks for native iOS clients."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class RecoverySafeModeContracts(unittest.TestCase):
    def test_ios5_requires_explicit_bootstrap_confirmation(self):
        boot = read("ios-kiosk/src/Core/DBBootConfig.m")
        app = read("ios-kiosk/src/Support/DBAppDelegate.m")
        missing_marker = boot[boot.index('objectForKey:@"setup_complete"'):
                              boot.index('objectForKey:@"ui_lang"')]
        self.assertIn("c.setupRequired = YES", missing_marker)
        self.assertNotIn("!hadStoredProfile", missing_marker)
        self.assertIn('\\"setup_complete\\": false', boot)
        self.assertIn("DBSuggestedDoor()", boot)
        self.assertIn("if (_boot.setupRequired)", app)
        self.assertIn("showBootstrapSetup:application", app)
        self.assertIn('initWithItems:@[', app)
        self.assertIn('admin.role_door', app)
        self.assertIn('admin.role_indoor', app)

    def test_modern_ios_requires_explicit_bootstrap_confirmation(self):
        boot = read("ios/Doorbell/BootConfig.swift")
        app = read("ios/Doorbell/AppDelegate.swift")
        self.assertIn("var setupComplete = false", boot)
        self.assertNotIn("var setupComplete = hadStoredProfile", boot)
        self.assertIn('value == "door_station" || value == "indoor_panel"', boot)
        self.assertIn('object["setup_complete"] = true', boot)
        self.assertIn("if boot.setupRequired", app)
        self.assertIn("BootstrapSetupViewController", app)

    def test_helper_persists_configured_auto_and_temporarily_disarms_it(self):
        source = read("ios-kiosk/src/Support/DBRecoveryClient.m")
        apply_mode = source[source.index("- (void)applyModeToHelper {"):
                            source.index("- (void)refreshEffectiveHelperState {")]
        heartbeat = source[source.index("- (void)sendHeartbeat:(NSString *)event {"):
                           source.index("- (void)reportStatus:(NSString *)event {")]
        self.assertIn("NSString *mode = [_configuredMode copy]", apply_mode)
        self.assertIn('@"MODE %@"', apply_mode)
        self.assertIn('"MAINTENANCE_BEGIN %lu"', apply_mode)
        self.assertIn('@"MAINTENANCE_END"', apply_mode)
        self.assertNotIn("MODE %@\", _effectiveMode", apply_mode)
        self.assertIn('@"policy" : _configuredMode', heartbeat)

    def test_helper_auto_requires_three_native_kiosk_failures(self):
        source = read("ios-kiosk/src/Support/DBRecoveryClient.m")
        app = read("ios-kiosk/src/Support/DBAppDelegate.m")
        self.assertIn("DBRecoveryNativeKioskFailureThreshold = 3", source)
        self.assertIn("failureCount < DBRecoveryNativeKioskFailureThreshold", source)
        self.assertIn('@"native_kiosk_failure_count"', source)
        self.assertIn('@"native_kiosk_failure_threshold"', source)
        self.assertIn("nativeKioskProbeTimerFired:", app)
        self.assertIn("[self refreshNativeKioskMeasurement]", app)

    def test_ios_compat_publishes_persisted_process_health(self):
        app = read("ios-kiosk/src/Support/DBAppDelegate.m")
        bridge_header = read("ios-kiosk/src/Core/DBCoreBridge.h")
        bridge = read("ios-kiosk/src/Core/DBCoreBridge.m")
        helper = read("ios-kiosk/src/Support/DBRecoveryClient.m")
        for key in ("runtime.generation", "runtime.last_exit_reason",
                    ' @"generation" :', ' @"heartbeat_ms" :',
                    ' @"last_exit_reason" :', ' @"components" :'):
            self.assertIn(key, app)
        self.assertIn("DBBoundedRuntimeToken", app)
        self.assertIn("scheduledTimerWithTimeInterval:10.0", app)
        self.assertIn("setRuntimeStatusValues", bridge_header)
        self.assertIn("addEntriesFromDictionary:valuesCopy", bridge)
        self.assertIn("- (NSString *)effectiveMode", helper)

    def test_ios5_safe_mode_keeps_audio_and_uses_only_bounded_jpeg(self):
        router = read("ios-kiosk/src/Screens/DBRouter.m")
        door = read("ios-kiosk/src/Screens/DBDoorScreen.m")
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")
        mjpeg = read("ios-kiosk/src/Net/DBMjpegClient.m")
        snapshot = read("ios-kiosk/src/Net/DBSnapshotPoller.m")
        safe_status = router[router.index("- (void)setSafeMode:"):
                             router.index("- (void)hideEmergencyPresentation")]
        for retained in ('@"sip_audio" : @"available"', '@"ringer" : @"available"',
                         '@"sos" : @"available"', '@"controls" : @"available"'):
            self.assertIn(retained, safe_status)
        self.assertIn('@"h264_forwarding" : @NO', door)
        self.assertIn('@"h264_decode" : @NO', incoming)
        self.assertIn('@"safe_mode_no_jpeg_fallback"', door)
        self.assertIn('@"safe_mode_no_jpeg_fallback"', incoming)
        self.assertIn("_streamer.lowResourceMode = _safeMode", incoming)
        self.assertIn("_snapshotPoller.lowResourceMode = _safeMode", incoming)
        self.assertIn("maximumPixel = _lowResourceMode", mjpeg)
        self.assertIn("maximumPixel = _lowResourceMode", snapshot)
        # The dashboard keeps its door still in safe mode, bounded smaller and
        # taken less often. A panel latched in safe mode by the root helper can
        # stay there for hours, and a black door tile is worse than a stale one.
        home = read("ios-kiosk/src/Screens/DBHomeScreen.m")
        self.assertNotIn("if (_safeMode || self.superview == nil) return;", home)
        self.assertIn("kSafeModeSnapshotMaxSide", home)
        self.assertIn("_safeMode ? kSafeModeSnapshotMaxSide : kSnapshotMaxSide", home)
        self.assertIn("_snapshotTick % kSafeModeSnapshotEveryNTicks", home)

    def test_ios5_local_safe_mode_exits_after_a_healthy_window(self):
        app = read("ios-kiosk/src/Support/DBAppDelegate.m")
        router = read("ios-kiosk/src/Screens/DBRouter.m")
        door = read("ios-kiosk/src/Screens/DBDoorScreen.m")
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")
        home = read("ios-kiosk/src/Screens/DBHomeScreen.m")

        recovery_start = app.rindex("- (void)armLocalSafeModeRecovery")
        recovery = app[recovery_start:
                       app.index("- (void)showBootstrapSetup", recovery_start)]
        # The latch now clears only after ten minutes of measured health: the
        # heartbeat must keep advancing and no unclean launch may be charged
        # during the window (qualification follow-up, 2026-09-02).
        self.assertIn("DBSafeModeRecovery shouldClearSafeModeEnteredAt:", recovery)
        self.assertIn("_lastHeartbeatAt", recovery)
        self.assertIn("crashesSinceEntry:[self crashesChargedSinceSafeModeEntry]", recovery)
        self.assertIn("DBMarkHealthyRuntime()", recovery)
        self.assertIn("_helperSafeModeActive", recovery)
        self.assertIn('setSafeMode:NO reason:@"healthy_runtime_10m"', recovery)
        self.assertIn("DBShellCapabilities(", recovery)
        self.assertIn("DBRecoveryLaunchesKey", app)
        self.assertIn('setObject:@"healthy_runtime"', app)
        # A repeating evaluation, not a one-shot timer that a wedged run loop
        # would still let fire.
        self.assertIn("scheduledTimerWithTimeInterval:30.0", recovery)
        self.assertNotIn("300 * NSEC_PER_SEC", recovery)


        self.assertIn("if (!enabled)", router)
        self.assertIn("[_incoming exitSafeMode]", router)
        self.assertIn("[_door exitSafeMode]", router)
        self.assertIn("[_home exitSafeMode]", router)
        self.assertIn("_rtspSuspendedForMemoryPressure = NO", door)
        self.assertIn("[self configureRTSPSource]", door)
        self.assertIn("_safeMode = NO", incoming)
        self.assertIn("[self startVideo:_incomingStreamUrl]", incoming)
        self.assertIn("_safeMode = NO", home)
        self.assertIn("[self applyDisplay]", home)

    def test_ios5_local_safe_mode_state_is_visible_to_the_operator(self):
        app = read("ios-kiosk/src/Support/DBAppDelegate.m")
        settings = read("ios-kiosk/src/Screens/DBSettingsScreen.m")
        policy = read("ios-kiosk/src/Support/DBSafeModeRecovery.m")

        # The window and the reason it is still running are published...
        self.assertIn('@"recovery_state" : recoveryState', app)
        self.assertIn('@"recovery_remaining_s" : @(recoveryRemaining)', app)
        self.assertIn('@"safe_mode_state" : recoveryState', app)
        # ...and rendered in the settings screen's 本機情報 section.
        self.assertIn('[_texts ts:@"info.safe_mode"]', settings)
        self.assertIn('info.safe_mode_wait', settings)
        self.assertIn('info.safe_mode_heartbeat', settings)
        self.assertIn('info.safe_mode_helper', settings)
        # The policy itself stays a pure, host-tested decision.
        self.assertIn("kHealthyWindow = 600.0", policy)
        self.assertIn("if (helperSafeModeActive) return NO;", policy)

    def test_ios5_deploy_restart_is_not_counted_as_a_crash(self):
        app = read("ios-kiosk/src/Support/DBAppDelegate.m")
        installer = read("ios-kiosk/scripts/install_via_ssh.sh")
        marker = ".doorbell-maintenance-restart"
        self.assertIn(marker, app)
        self.assertIn("maintenanceRestart", app)
        self.assertIn("previousClean = @YES", app)
        self.assertIn('lastExitReason = @"maintenance_restart"', app)
        self.assertIn(marker, installer)
        self.assertGreaterEqual(installer.count("touch '$MAINTENANCE_MARKER'"), 3)

    def test_ios5_fmp4_startup_waits_for_a_complete_gop_before_fallback(self):
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")
        self.assertIn('@"startup_timeout_ms": @5000', incoming)
        self.assertIn("timeoutMs < 5000", incoming)
        self.assertIn("timeoutMs = 5000", incoming)
        self.assertIn("return @[h264, mjpeg]", incoming)

    def test_ios5_memory_warning_and_diagnostic_trigger_share_one_handler(self):
        app = read("ios-kiosk/src/Support/DBAppDelegate.m")
        uikit_start = app.index("- (void)applicationDidReceiveMemoryWarning:")
        handler_start = app.index("- (void)handleMemoryPressureFromSource:", uikit_start)
        uikit = app[uikit_start:handler_start]
        handler = app[handler_start:app.index("- (BOOL)application:", handler_start)]
        urls = app[app.index("- (BOOL)application:"):
                   app.index("- (void)h264TestStop")]

        self.assertIn('[self handleMemoryPressureFromSource:@"uikit"]', uikit)
        self.assertEqual(app.count("[_router releaseMediaForMemoryPressure]"), 1)
        self.assertIn('isEqualToString:@"uikit"', handler)
        self.assertIn('isEqualToString:@"diagnostic_url"', handler)
        self.assertIn("[_router releaseMediaForMemoryPressure]", handler)
        self.assertIn("[_recovery noteMemoryPressure]", handler)
        self.assertIn('[_router setSafeMode:YES reason:@"memory_pressure"]', handler)
        self.assertIn("[self publishRuntimeHealth:nil]", handler)

        self.assertIn('@"memorypressure"', urls)
        self.assertIn("diagnosticAction && !_boot.diagnosticDumps", urls)
        self.assertIn("UIApplicationStateBackground", urls)
        self.assertIn('[self handleMemoryPressureFromSource:@"diagnostic_url"]', urls)
        self.assertLess(urls.index('isEqualToString:@"pin"'),
                        urls.index("diagnosticAction && !_boot.diagnosticDumps"))
        self.assertLess(urls.index('isEqualToString:@"info"'),
                        urls.index("diagnosticAction && !_boot.diagnosticDumps"))

        for key in ('@"memory_pressure"', '@"count"', '@"last_source"',
                    '@"last_at_ms"', '@"media_released"'):
            self.assertIn(key, app)

    def test_ios5_call_cancel_stops_video_without_restarting_during_banner(self):
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")
        cancelled = incoming[incoming.index("- (void)handleCallCancelled:"):
                             incoming.index("- (void)handlePurposeSelected:")]
        refresh = incoming[incoming.index("- (void)fetchAndApplyCoreSnapshot"):
                           incoming.index("- (void)applyContent")]
        self.assertIn("++_snapshotGen", cancelled)
        self.assertIn("[self stopVideoPlayers]", cancelled)
        self.assertIn("_liveView.image = nil", cancelled)
        self.assertIn('_activeVideoTransport = @"CANCELLED"', cancelled)
        self.assertIn("_answerButton.enabled = NO", cancelled)
        self.assertIn("_monitorButton.enabled = NO", cancelled)
        self.assertIn("!s->_cancelled && (mediaChanged || videoStopped)", refresh)

    def test_ios5_call_deadline_is_not_extended_by_snapshot_refresh(self):
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")
        timer = incoming[incoming.index("- (void)restartAutoClose"):
                         incoming.index("- (void)handleCallCancelled:")]
        self.assertIn("[_autoCloseTimer isValid]", timer)
        self.assertIn("_autoCloseTimerForCancelled == _cancelled", timer)
        self.assertIn("_callExpiresAtMs", timer)
        self.assertIn("deadlineMs = _callExpiresAtMs", timer)
        self.assertIn("(deadlineMs - nowMs) / 1000.0", timer)
        self.assertNotIn("kAutoCloseS", timer)
        self.assertIn("@selector(autoCloseTimerFired:)", timer)
        self.assertIn("forMode:NSRunLoopCommonModes", timer)

    def test_ios5_restores_only_a_previously_targeted_unexpired_indoor_call(self):
        router = read("ios-kiosk/src/Screens/DBRouter.m")
        restore = router[router.index("- (void)restoreTargetedIndoorCallFromStatus:"):
                         router.index("- (NSString *)effectiveSipBackend")]
        self.assertIn('DBPendingIndoorCallDefaultsKey', router)
        self.assertIn('[self persistTargetedIndoorCall:chime]', router)
        self.assertIn('objectForKey:DBPendingIndoorCallDefaultsKey', restore)
        self.assertIn('isEqualToString:callID', restore)
        self.assertIn('isEqualToString:@"ringing"', restore)
        self.assertIn('isEqualToString:@"purpose_pending"', restore)
        self.assertIn('expires > nowMs', restore)
        self.assertIn('longLongVal:call path:@"expires_at_ms"', restore)
        self.assertNotIn('intVal:call path:@"expires_at_ms"', restore)
        self.assertIn('_callEvents.currentCallID isEqualToString:callID', restore)
        self.assertIn('if (matchingCallSeen) [self clearPersistedIndoorCall:callID]', restore)
        self.assertIn('acceptChimeEvent:chime nowMs:nowMs', restore)
        self.assertIn('[self clearPersistedIndoorCall:callID]', restore)
        self.assertIn('[self clearPersistedIndoorCall:_callEvents.currentCallID]', router)

    def test_ios5_stale_transition_completion_cannot_remove_current_screen(self):
        router = read("ios-kiosk/src/Screens/DBRouter.m")
        transition = router[router.index("- (void)transitionTo:"):
                            router.index("- (void)showHomeAnimated:")]
        self.assertIn("_transitionGeneration", transition)
        self.assertIn("old != router->_current", transition)
        self.assertIn("generation == router->_transitionGeneration", transition)
        self.assertIn("next.superview != router->_container", transition)
        self.assertIn("bringSubviewToFront:next", transition)

    def test_ios5_hardware_decode_uses_a_uikit_bgra_compositor(self):
        video = read("ios-kiosk/src/Media/DBVtVideoView.m")
        player = read("ios-kiosk/src/Media/DBLowLatencyH264Player.m")
        player_header = read("ios-kiosk/src/Media/DBLowLatencyH264Player.h")
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")
        self.assertIn("kCVPixelFormatType_32BGRA", video)
        self.assertIn("UIImageView *_compatImageView", video)
        self.assertIn("CFDataCreate(kCFAllocatorDefault, base, stride * height)", video)
        self.assertIn("kCGBitmapByteOrder32Little", video)
        self.assertIn("kCGImageAlphaNoneSkipFirst", video)
        self.assertNotIn("kCGImageAlphaPremultipliedFirst", video)
        self.assertIn("_compatImageView.image = [UIImage imageWithCGImage:image]", video)
        self.assertIn("UIKit BGRA compositor active", video)
        self.assertIn("_compatImageView.image = nil", video)
        self.assertIn("DBVtVideoView", player)
        self.assertIn("UIImageView *_compatOverlay", player)
        self.assertIn("[_container addSubview:_compatOverlay]", player)
        self.assertIn("[_videoView setCompatibilityOutputView:_compatOverlay]", player)
        self.assertIn("_videoView.hidden = NO", player)
        self.assertNotIn("_videoView.hidden = YES", player)
        self.assertIn("bringSubviewToFront:player->_compatOverlay", player)
        self.assertNotIn("software H.264", player)
        self.assertIn("- (NSUInteger)decodedFrames", player_header)
        self.assertIn("- (NSUInteger)displayedFrames", player_header)
        self.assertIn('return @"uikit_bgra_sibling"', player)
        self.assertIn('setRuntimeStatusSection:@"media_playback"', incoming)
        self.assertIn('@"decoded_frames"', incoming)
        self.assertIn('@"displayed_frames"', incoming)
        self.assertIn('@"compositor"', incoming)

    def test_modern_ios_memory_pressure_retains_call_controls_and_audio_dialog(self):
        app = read("ios/Doorbell/AppDelegate.swift")
        incoming = read("ios/Doorbell/IncomingViewController.swift")
        main = read("ios/Doorbell/MainViewController.swift")
        handler = incoming[incoming.index("func enterSafeModeForMemoryPressure"):
                           incoming.index("func refresh(")]
        main_handler = main[main.index("func enterSafeModeForMemoryPressure"):
                            main.index("private func buildUi")]
        self.assertIn("incoming.enterSafeModeForMemoryPressure()", app)
        self.assertIn("videoPlayer?.stop()", handler)
        self.assertNotIn("sipHangup", handler)
        self.assertNotIn("close()", handler)
        self.assertNotIn("closeInCall()", main_handler)
        self.assertIn("inCallStreamer?.stop()", main_handler)

    def test_modern_device_info_callback_reads_only_a_bounded_main_thread_cache(self):
        bridge = read("ios/Doorbell/CoreBridge.swift")
        runtime = read("ios/Doorbell/RuntimeSupervisor.swift")
        callback = bridge[bridge.index("plat.device_info ="):
                          bridge.index("plat.release_buffer =")]
        cache = bridge[bridge.index("// UIKit-backed device state"):
                       bridge.index("private static func httpsRequestSync")]
        updates = runtime[runtime.index("private func beginDeviceInfoUpdates"):
                          runtime.index("func handleMemoryPressure")]

        self.assertIn("cachedDeviceInfoJSON()", callback)
        self.assertNotIn("UIDevice", callback)
        self.assertNotIn("ProcessInfo", callback)
        self.assertIn("guard Thread.isMainThread", cache)
        self.assertIn("deviceInfoCacheLock.lock()", cache)
        self.assertIn("data.count <= 4_096", cache)
        self.assertIn("boundedDeviceInfoString", cache)
        self.assertIn("UIApplication.didBecomeActiveNotification", updates)
        self.assertIn("UIDevice.batteryLevelDidChangeNotification", updates)
        self.assertIn("UIDevice.batteryStateDidChangeNotification", updates)
        self.assertIn("self?.core.refreshDeviceInfoCache()", runtime)

    def test_answer_lifecycle_excludes_monitor_and_yields_losing_dialog(self):
        modern = read("ios/Doorbell/IncomingViewController.swift")
        compat = read("ios-kiosk/src/Screens/DBIncomingScreen.m")
        router = read("ios-kiosk/src/Screens/DBRouter.m")
        self.assertIn('guard sipMode == "answer" else { return }', modern)
        self.assertIn("reportCallAnswered", modern)
        self.assertIn("owner != nodeId", modern)
        self.assertIn("lifecycleEnded = true", modern)
        self.assertIn('[_sipMode isEqualToString:@"answer"]', compat)
        self.assertIn("reportCallAnsweredV2", compat)
        self.assertIn("yieldAnsweredDialog", router)
        self.assertIn('@"dialog_owner"', router)

    def test_higher_purpose_revision_demotes_answer_and_losing_idle_keeps_ui(self):
        modern = read("ios/Doorbell/IncomingViewController.swift")
        modern_refresh = modern[modern.index("func refresh("):
                                modern.index("func receive(")]
        modern_idle = modern[modern.index('} else if st == "idle" {'):
                             modern.index('case "reply":')]
        modern_monitor = modern[modern.index("private func onMonitor"):
                                modern.index("private func onIgnore")]
        self.assertIn("observeWinningRevision", modern_refresh)
        self.assertIn(".answerSuperseded", modern_refresh)
        self.assertIn("demoteSupersededAnswer()", modern_refresh)
        self.assertIn("consumeSupersededIdle()", modern_idle)
        # The losing answer leg goes back to the ringing screen instead of closing it. What it
        # restarts is the indoor return countdown, which replaced the flat 30 s auto-close: the
        # panel keeps the live view and goes home on its own clock, and the visitor hanging up
        # does not take the screen away from a resident who is still walking towards it.
        self.assertIn("restartReturnCountdown()", modern_idle)
        self.assertNotIn("close()", modern_idle)
        self.assertNotIn("restartAutoClose()", modern_idle)
        # A dialog that simply ended hands the screen back to the same countdown, from the top.
        self.assertIn("resumeReturnCountdown()", modern_idle)
        self.assertIn("return", modern_idle)
        self.assertNotIn("beginAnswer", modern_monitor)

        compat = read("ios-kiosk/src/Screens/DBIncomingScreen.m")
        router = read("ios-kiosk/src/Screens/DBRouter.m")
        compat_refresh = compat[compat.index("- (void)refreshPurpose:"):
                                compat.index("- (void)fetchAndApplyCoreSnapshot")]
        compat_idle = compat[compat.index("- (void)handleSupersededSipIdle"):
                             compat.index("- (void)fetchAndApplyCoreSnapshot")]
        self.assertIn("stageRevision <= _stageRevision", compat_refresh)
        self.assertIn("_awaitingSupersededIdle = YES", compat_refresh)
        self.assertIn("_answerButton.enabled = !supersedesAnswer", compat_refresh)
        self.assertIn("[_router sipHangup]", compat_refresh)
        self.assertIn("!s->_awaitingSupersededIdle", compat)
        self.assertIn("_answerButton.enabled = ([_peerHost length] > 0)", compat_idle)
        self.assertIn("[self restartAutoClose]", compat_idle)
        self.assertIn("consumeSupersededIdleForCurrentCall", router)
        self.assertIn("handleSupersededSipIdle", router)

    def test_restart_recovery_restores_waiting_ui_but_fails_missing_in_call_dialog(self):
        delegate = read("ios/Doorbell/AppDelegate.swift")
        modern = read("ios/Doorbell/MainViewController.swift")
        compat = read("ios-kiosk/src/Screens/DBRouter.m")
        door = read("ios-kiosk/src/Screens/DBDoorScreen.m")
        self.assertIn("handleCallRecovery(ev)", delegate)
        self.assertIn('persistedState == "in_call" || eventState == "in_call"', modern)
        self.assertIn("reportRecovery(callId, restored: false)", modern)
        self.assertIn('persistedState == "ringing"', modern)
        self.assertIn("expiry > nowMs", modern)
        self.assertIn("showPurposeChoice(afterRing: true)", modern)
        self.assertIn("reportRecovery(callId, restored: true)", modern)
        self.assertIn('@"dialog_owner"', compat)
        self.assertIn('isEqualToString:@"in_call"', compat)
        self.assertIn("reportCallRecovery:callID restored:NO", compat)
        self.assertIn("restoreWaitingCall:selected recoveryState:eventState", compat)
        self.assertIn("reportCallRecovery:callID restored:restored", compat)
        self.assertIn("expires <= nowMs", door)
        self.assertIn("presentPurposeAlertForActiveCall:YES", door)

    def test_emergency_colors_are_contrast_checked_and_report_fallback(self):
        # The colour half of ConfigUtil lives in its own file so the parsing half stays
        # host-compilable for the Swift call-revision test below; the rule it enforces is
        # unchanged.
        modern_util = read("ios/Doorbell/ConfigUtilColors.swift")
        modern_ui = read("ios/Doorbell/MainViewController.swift")
        modern_report = read("ios/Doorbell/AppDelegate.swift")
        compat_util = read("ios-kiosk/src/Core/DBConfigUtil.m")
        compat_home = read("ios-kiosk/src/Screens/DBHomeScreen.m")
        compat_door = read("ios-kiosk/src/Screens/DBDoorScreen.m")
        compat_report = read("ios-kiosk/src/Screens/DBRouter.m")
        for source in (modern_util, compat_util):
            self.assertIn("invalid_emergency_presentation_colors", source)
            self.assertIn("4.5", source)
            self.assertIn("3.0", source)
        self.assertIn("ConfigUtil.emergencyPalette(ev)", modern_ui)
        self.assertIn("colorLimitation", modern_report)
        self.assertIn("bringSubviewToFront:_emergencyView", compat_home)
        self.assertIn("emergencyPalette:event", compat_door)
        self.assertIn("colorLimitation", compat_report)

    def test_tvos_manifest_and_alert_report_match_actual_in_app_behavior(self):
        runtime = read("ios/Doorbell/RuntimeSupervisor.swift")
        delegate = read("ios/DoorbellTV/TVAppDelegate.swift")
        main = read("ios/DoorbellTV/TVMainViewController.swift")
        self.assertIn('let ids = ["sos.cancel", "ring.title"', runtime)
        tvos_manifest = runtime[runtime.index("#if os(tvOS)",
                                             runtime.index("private func publishUiManifest")):
                                runtime.index("#else", runtime.index(
                                    "private func publishUiManifest"))]
        self.assertNotIn('"sos.trigger"', tvos_manifest)
        lifecycle = runtime[runtime.index("private var supportsCallLifecycle"):
                            runtime.index("init(core:")]
        self.assertIn("#if os(tvOS)", lifecycle)
        self.assertIn("return false", lifecycle)
        self.assertIn('return core.sipBackend == "pjsip"', lifecycle)
        self.assertIn("runtime?.recordDeviceAlert(report)", delegate)
        self.assertIn('result: "presented"', main)
        self.assertIn('result: "ttl_expired"', main)
        self.assertIn('"channel": "in_app"', main)

    def test_modern_ios_compensates_every_scaled_control_hit_target(self):
        source = read("ios/Doorbell/UIStyleApplier.swift")
        self.assertIn("if view is UIControl", source)
        self.assertIn("scale < 1 ? 44 / scale : 44", source)
        self.assertIn("constraints.width.constant = minimumHitTarget", source)
        self.assertIn("constraints.height.constant = minimumHitTarget", source)

    def test_modern_ios_media_caps_and_call_expiry_are_measured(self):
        runtime = read("ios/Doorbell/RuntimeSupervisor.swift")
        camera = read("ios/Doorbell/CameraFeeder.swift")
        encoder = read("ios/Doorbell/VideoEncoderVT.swift")
        main = read("ios/Doorbell/MainViewController.swift")
        availability = read("ios/Doorbell/IOSAvailability.swift")

        capabilities = runtime[runtime.index("private func publishCapabilities"):
                               runtime.index("private func publishUiManifest")]
        # The camera rule moved into AvPermissions so it can be unit-tested without driving
        # AVCaptureDevice, but it is still the same rule and it is still what is published.
        self.assertIn("AvPermissions.cameraOffered(role: boot.role, permission: cameraPermission",
                      capabilities)
        self.assertIn("runtime: cameraRuntimeState)", capabilities)
        self.assertIn('permission == "authorized" && runtime == "active"', availability)
        self.assertIn('role == "door_station"', availability)
        # not_determined is reported honestly: a prompt nobody has answered is not a refusal, and
        # an indoor panel hides the tile of a door whose camera capability is false.
        self.assertIn('default: return "not_determined"', availability)
        self.assertIn("AvPermissions.requestAtLaunch(role: boot.role)",
                      read("ios/Doorbell/AppDelegate.swift"),
                      "the ask happens before the first capability document")
        self.assertIn('microphonePermission == "authorized"', capabilities)
        self.assertIn("availableInputs?.isEmpty", capabilities)
        self.assertIn('h264EncodeState == "verified"', capabilities)
        self.assertIn('"h264_decode": false', capabilities)
        self.assertNotIn("UIImagePickerController.isSourceTypeAvailable", capabilities)
        self.assertIn("try session.setActive(true)", availability)
        self.assertIn("return false", availability)

        self.assertIn("CMSampleBufferGetImageBuffer", camera)
        self.assertIn('reportRuntime(active: true, state: "active")', camera)
        self.assertIn("AVCaptureSessionRuntimeError", camera)
        self.assertIn('reportRuntime(active: false, state: "runtime_failed")', camera)
        self.assertIn("VTCompressionSessionPrepareToEncodeFrames", encoder)
        self.assertIn('reportRuntime(available: true, state: "verified")', encoder)
        self.assertIn('markTerminalFailure("encode_failed")', encoder)
        self.assertIn('markTerminalFailure("invalid_output")', encoder)

        expiry = main[main.index("private func coreExpiryForActiveCall"):
                      main.index("private func onUiEvent")]
        self.assertIn('call["expires_at_ms"]', expiry)
        self.assertIn("coreExpiryForActiveCall()", expiry)
        self.assertIn("activeCallExpiresAtMs) / 1000", expiry)
        self.assertNotIn("TimeInterval = 60", expiry)
        self.assertNotIn("60_000", main)


if __name__ == "__main__":
    unittest.main(verbosity=2)
