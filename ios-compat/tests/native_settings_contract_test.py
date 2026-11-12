#!/usr/bin/env python3
"""Contracts the modern Swift shell must keep for the batch-2 surfaces.

These are source contracts rather than behavioural tests because every screen here is UIKit and
cannot be instantiated on a build host. They pin the decisions that are easy to regress silently:
which Core entry point each value comes from, that settings write the same keys the web admin
writes, and that the safety rules (no visitor route into settings, no silent unlock no-op, no
Core call before the SOS countdown ends) stay in place.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


bridge = source("ios/Doorbell/CoreBridge.swift")
admin = source("ios/Doorbell/AdminPinViewController.swift")
theme = source("ios/Doorbell/DoorbellTheme.swift")
clock = source("ios/Doorbell/DoorbellClock.swift")
writer = source("ios/Doorbell/ConfigWriter.swift")
sos = source("ios/Doorbell/SosSlideControl.swift")
notice = source("ios/Doorbell/NoticeSupport.swift")
history = source("ios/Doorbell/CallHistory.swift")
settings = source("ios/Doorbell/SettingsViewController.swift") + source("ios/Doorbell/SettingsCatalog.swift")
dashboard = source("ios/Doorbell/DashboardView.swift")
visitor = source("ios/Doorbell/VisitorScreenView.swift")
incoming = source("ios/Doorbell/IncomingViewController.swift")
main = source("ios/Doorbell/MainViewController.swift")
tv = source("ios/DoorbellTV/TVMainViewController.swift")
app_delegate = source("ios/Doorbell/AppDelegate.swift")
tv_delegate = source("ios/DoorbellTV/TVAppDelegate.swift")
debug_info = source("ios/Doorbell/DebugInfoViewController.swift")
availability = source("ios/Doorbell/IOSAvailability.swift")
strings = source("i18n/strings.yaml")


# --- platform SPI ----------------------------------------------------------
assert "plat.power_state = {" in bridge, "the power_state SPI must be published to Core"
assert "plat.struct_size = UInt32(MemoryLayout<db_platform_v2>.size)" in bridge
assert '"battery_pct": -1' in bridge and '"mains": true' in bridge, "tvOS reports mains, no battery"
assert "UIDevice.current.isBatteryMonitoringEnabled = true" in bridge
assert "refreshPowerStateCache()" in bridge and "powerStateCacheLock" in bridge, \
    "UIDevice must be sampled on main and handed to Core as a snapshot"

# --- new Core entry points -------------------------------------------------
for symbol in ("db_core_local_time_json", "db_core_time_sync_now", "db_core_audio_json",
               "db_core_set_door_notice", "db_core_clear_door_notice",
               "db_core_call_log_json", "db_core_call_log_mark_seen"):
    assert symbol in bridge, symbol

# Entry points Core is still landing are resolved at runtime, never linked blindly, and each one
# has a capability flag so the UI can say what it cannot do instead of doing nothing.
for symbol, flag in (("db_core_sip_set_mic_muted", "supportsMicMute"),
                     ("db_core_set_config_json", "supportsConfigWrite"),
                     ("db_core_config_batch_json", "supportsConfigWrite"),
                     ("db_core_delete_config_key", "supportsConfigWrite"),
                     ("db_core_last_write_warnings_json", "supportsConfigWrite"),
                     ("db_core_admin_password_verify", "supportsAdminPassword"),
                     ("db_core_admin_password_set", "supportsAdminPasswordChange"),
                     ("db_core_call_log_json_v2", "supportsCallLogPaging"),
                     ("db_core_mint_join_token_json", "supportsMintJoinToken")):
    assert f'symbol("{symbol}")' in bridge or f'"{symbol}"' in bridge, symbol
    assert f"var {flag}: Bool" in bridge, flag
assert 'dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)' in bridge, \
    "runtime lookups go through one helper"

# The signatures the runtime lookups assume are the ones core actually exports.
header = source("core/include/doorbell/doorbell.h")
assert "DB_API int db_core_set_config_json(" in header and \
    "typealias SetConfigKeyFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,\n" \
    "                                                       UnsafePointer<CChar>?) -> Int32" in bridge, \
    "the single-key write returns a status code, not void"
assert "DB_API int db_core_delete_config_key(" in header and \
    "DeleteConfigKeyFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?)\n        -> Int32" \
    in bridge
assert "db_core_set_global_notice" not in bridge and "db_core_set_global_notice" not in header, \
    "there is no global-notice entry point; the house-wide announcement is the door \"*\""
assert 'static let globalNoticeDoor = "*"' in bridge

# A wrong password and a cluster that has never set one are different answers, and neither one
# may open the settings screen by being mistaken for success.
assert "enum AdminPasswordResult" in bridge
assert "case let code where code > 0: return .accepted" in bridge
assert "case -2: return .unset" in bridge
assert "case .unset:" in admin and "admin.password_set_prompt" in admin, \
    "an unset cluster password turns the gate into a set-once flow"
assert 'core?.setAdminPassword(current: "", new: pin)' in admin
# An alarm is never held behind a password the cluster does not have.
assert "core.sosCancelRequiresPassword" in main and "core.sosCancelRequiresPassword" in tv
assert 'ConfigUtil.bool(cfg, "emergency.cancel_requires_pin"' not in main + tv, \
    "cancel_requires_pin alone would lock a household out of its own alarm"
assert '"cancel_requires_password"' in bridge

# Core's advisory readability warnings reach the status line; a warning is never a refusal.
assert "case ok(contrasts: [Double])" in writer and "theme.contrast_warning" in writer
assert "db_core_last_write_warnings_json" in bridge

# The 管理パスワード is the cluster secret, and the old per-node digest is retired once Core has
# accepted it on this device.
assert "core?.verifyAdminPassword(pin) ?? .unavailable" in admin
assert "retireLegacyDigest()" in admin and "exit_pin.txt" in admin
assert "FileManager.default.removeItem(atPath: path)" in admin
assert "settings.change_password" in source("ios/Doorbell/SettingsCatalog.swift") and \
    "core.setAdminPassword(current:" in settings
settings_ui = source("ios/Doorbell/SettingsUI.swift")
assert "final class SettingsSecretCell" in settings_ui and \
    "field.isSecureTextEntry = true" in settings_ui, \
    "a password field is never pre-filled or echoed"
assert "field.isSecureTextEntry = true" in admin and "UIAlertController(" in admin, \
    "the admin password prompt is the system alert with a secure field"

# The home-wide announcement and history paging prefer Core's entry points.
assert "core.setGlobalNotice(text:" in notice and "core.clearGlobalNotice()" in notice
assert "core.callLogPage(sinceMs: 0, beforeMs: beforeMs, limit: limit)" in history

# --- every clock goes through Core -----------------------------------------
assert "func localTime(wallMs: Int64 = 0)" in bridge
assert "core.localTime(wallMs: wallMs)" in clock
# The iOS shell draws from a base Core gave it, re-taken off the main thread: db_core_local_time_json
# is synchronous into Core and does not answer while Core is mid-SNTP, which made the panel's
# seconds advance in threes. The reading still originates in Core, never in the OS calendar.
assert "clockSource.reading()" in main, "MainViewController draws from the disciplined clock"
assert "clockSource.refresh(core)" in main, "and re-takes its base from Core"
assert "DoorbellClock.read(core)" in clock, "which is still Core's reading, not the OS calendar's"
assert "clockSource.reading()" in tv, "TVMainViewController draws from the same source"
for shell, name in ((main, "MainViewController"), (tv, "TVMainViewController")):
    assert "Calendar(identifier: .gregorian)" not in shell.split("private func updateClock")[1][:600], \
        f"{name} must not render its clock from the OS calendar"

# --- settings write what the web writes ------------------------------------
assert "/api/config/batch" in writer, "native settings must use the atomic batch endpoint"
assert '"op": "set"' in writer and '"op": "delete"' in writer
assert "admin.atomic_batch_unavailable" in writer
for key in ('"audio.volume.\\(name)"', '"time.zone"', '"time.ntp.enabled"',
            '"time.ntp.servers"', '"time.ntp.interval_s"', '"display.appearance"',
            '"display.appearance_schedule.dark_from"', '"display.theme.bg_color"',
            '"display.theme.bg_image"', '"doors.\\(door).unlock.show_button"',
            '"visit_purposes.\\(id).enabled"', '"quiet_hours.default.windows"'):
    assert key in settings, key
assert 'deviceKey("local.audio.volume.\\(name)")' in settings
assert 'deviceKey("local.ui_lang")' in settings
assert 'deviceKey("local.video.playback")' in settings
assert 'deviceKey("local.video.rotation")' in settings

# Native editors replace the former web-only placeholders.
for reason in ("settings.web_only_upload", "settings.web_only_wording",
               "settings.web_only_rule_actions", "settings.web_only_secrets",
               "settings.web_only_raw_config"):
    assert reason not in settings, reason

# --- announcements ---------------------------------------------------------
assert 'ConfigUtil.dig(status, "doors.\\(door).notice")' in notice, \
    "the resolved announcement comes from status, where Core applied the precedence"
assert 'ConfigUtil.dig(config, "doors.\\(door).notice")' in notice
assert '"notice.global"' in notice, "the home-wide announcement lives in notice.global"
assert 'ConfigUtil.dig(config, "notice.presets")' in notice, "presets are administrator-editable"
assert "func effective(config:" in notice
assert notice.index('doors.\\(door).notice') < notice.index('"notice.global"'), \
    "a door-specific announcement must win over the home-wide one"

# --- SOS: Core hears about it only at countdown zero ------------------------
assert "emergency.trigger.countdown_s" in main and "emergency.trigger.countdown_s" in tv
assert "core.emergency" not in sos, "the slider must not talk to Core itself"
assert "onTriggered?()" in sos and "private func fire()" in sos
assert "func cancelCountdown()" in sos
assert "sosSlider.onTriggered = { [weak self] in self?.triggerEmergency() }" in main
assert 'ConfigUtil.double(cfg, "emergency.hold_to_trigger_s"' not in main, \
    "the legacy long-press must no longer drive the trigger"
assert "UILongPressGestureRecognizer" not in main + tv + sos + dashboard + visitor, \
    "no press-and-hold anywhere in the SOS flow"
# The trigger is a compact outlined button that only opens the confirmation surface; the slide
# that confirms lives on that surface, and the same slide confirms clearing an alarm.
assert "final class SosTriggerButton: UIButton" in sos and "layer.borderWidth = 1.5" in sos
assert "final class SosConfirmViewController" in sos and "SosConfirmation.idleTimeout" in sos
assert "static let idleTimeout: TimeInterval = 10" in sos, "the surface closes after 10 s idle"
assert "alert.preferredAction = cancel" in sos, "Send SOS is never the default focus"
assert "private lazy var sosSlider = SosTriggerButton(texts: texts)" in main
assert "private lazy var sosSlider = SosTriggerButton(texts: texts)" in tv
assert "SosConfirmViewController(texts: texts, purpose: .clear)" in main
assert "SosSlideControl(" not in main + tv + dashboard + visitor, \
    "the slide is never laid out on a home screen"

# --- visitor safety --------------------------------------------------------
assert "onOpenAdmin" not in visitor and "SettingsViewController" not in visitor, \
    "the door station's visitor screen must have no route into settings"
assert "AdminPinViewController(texts: texts, core: core)" in main and \
    "showSettings()" in main
assert main.count("dialog.onUnlocked = { [weak self] in self?.showSettings() }") >= 1

# --- incoming screen (A2) --------------------------------------------------
assert "NoticeChipView" in incoming, "the announcement is a compact chip"
assert "purposeSlot.heightAnchor.constraint(equalToConstant:" in incoming, \
    "the purpose slot keeps its height so the layout never jumps"
assert "applyVideoAspect" in incoming and "videoBackdrop.heightAnchor.constraint(equalTo:" in incoming
# Every live picture zooms: pinch 1x-4x, drag while zoomed, double tap for fit/2x, reset when the
# door or call changes. One view owns it for both renderers.
zoom = source("ios/Doorbell/ZoomableVideoView.swift")
monitor = source("ios/Doorbell/MonitorViewController.swift")
assert "static let maximumScale: CGFloat = 4" in zoom and "doubleTapScale: CGFloat = 2" in zoom
for shell, name in ((incoming, "incoming"), (monitor, "monitor"), (main, "in-call")):
    assert "ZoomableVideoView()" in shell and "resetZoom()" in shell, name
assert "videoZoom.host(liveView)" in incoming and "videoZoom.host(h264View)" in incoming
# The fixed action zone keeps its order: Answer (End in a call), Reply, Ignore.
assert "actionZone.setActions(primary: [answerButton, quickReplyButton, ignoreButton]," in incoming
assert "secondary: [monitorButton, unlockButton, micButton])" in incoming
assert "CallActionButton(type: .custom)" in incoming, "call actions are circular buttons with captions"
# Both toggles show their state, and the state is the authored second line rather than a suffix
# the button would have to shrink to fit.
assert "ring.monitor_two_line_on" in incoming and "ring.mic_two_line_on" in incoming
assert "DoorbellTheme.twoPartTitle(text, on: button," in incoming, \
    "the control row renders its labels through the two-part renderer"
assert 'color: button.titleColor(for: .normal)' in incoming, \
    "a semantic foreground override must survive the two-part rendering"
assert "incoming.debug_line_hidden" in incoming, "the debug line's state is remembered"
assert "AdminQrView(core: core, boot: boot, texts: texts, compact: true)" in incoming
assert "sheetPresentationController?.detents = [.medium(), .large()]" in \
    source("ios/Doorbell/DoorbellLayout.swift"), "quick replies open in a system sheet"
assert "DoorUnlock.showsButton(status: core.status(), config: cfg,\n" in incoming
assert "core.openDoor(door: door, callId: callId, stageRevision: stageRevision)" in incoming, \
    "incoming unlock binds the door, call identity and revision through Core"
assert "door.unlock_not_configured" in incoming, "an unconfigured unlock must explain itself"

# --- the theme background is behind the home surfaces only -------------------
# An indoor panel wears the household's theme background on its Home tab, as the door station does
# on the visitor screen, and automatic contrast keeps the text drawn on it readable. Every other
# screen, the call and monitor screens included, is a system surface.
assert "class ThemeBackgroundView" in theme and "func apply(display:" in theme
assert "struct DoorbellSkin" in theme and "func cardInk(" in theme, \
    "bare text takes the region's automatic ink; cards this shell painted keep the palette"
assert "surfaceSolid" in theme and "func solid(" in theme, \
    "a card over a theme picture has to be opaque or its palette ink stops being readable"
for region in ("clock", "date", "status_line", "hint", "tile_label", "footer", "notice"):
    assert f'"{region}"' in theme + dashboard + visitor + main + \
        source("ios/Doorbell/HomeTabs.swift"), region
for shell, name in ((main, "MainViewController"), (tv, "TVMainViewController")):
    assert "themeBg.apply(display:" in shell, name
for shell, name in ((incoming, "IncomingViewController"), (monitor, "Monitor")):
    assert "ThemeBackgroundView" not in shell, f"{name} uses the system background"
    assert "SystemStyle.background" in shell, name
assert 'boot.role == "door_station"' not in main.split("private func applyTheme")[1][:400], \
    "the theme background is no longer gated on the door station"
assert 'skin.apply("clock", to: clockLabel)' in dashboard
assert "final class HaloLabel: UILabel" in theme and "override func drawText" in theme, \
    "wallpaper labels can protect low-contrast text with an opposite-color shadow"
assert "guard let contrastColor = outlineColor" in theme and \
    "(label as? HaloLabel)?.outlineColor = decided.shadow" in theme, \
    "text decoration follows the contrast decision and clears on readable backgrounds"
assert "backgroundColor = .black" in incoming, "the video keeps its own black frame"

# --- visit_purposes.<id>.enabled -------------------------------------------
# One definition of "offered", used by both choosers; the settings list deliberately shows every
# purpose, because that is where a switched-off one is switched back on.
config_util = source("ios/Doorbell/ConfigUtil.swift")
assert "func enabledPurposeIds(" in config_util and "func allPurposeIds(" in config_util
assert 'bool(entry, "enabled", true)' in config_util, "an absent switch means offered"
assert "ConfigUtil.enabledPurposeIds(cfg)" in main and \
    main.count("ConfigUtil.enabledPurposeIds(cfg)") >= 2, \
    "the door buttons and the ring-then-purpose chooser share one answer"
assert "ConfigUtil.allPurposeIds(cfg)" in settings, "the settings list shows every purpose"
assert "ConfigUtil.purposeIsEnabled(entry)" in settings
assert 'write([.set("visit_purposes.\\(id).enabled", on)])' in settings, \
    "the toggle writes that one key and nothing else"

# --- dashboard -------------------------------------------------------------
assert 'LocalMediaAuth.sibling(url, "snapshot.jpg")' in dashboard and \
    "withTimeInterval: Self.previewInterval(for: rate)" in dashboard
assert "history.missed_badge" in dashboard, "unread missed calls get one row on Home"
assert "onUnreadMissedChanged?(unread)" in dashboard, "and the count is the History tab's badge"
assert "RecentCallsView" not in dashboard + history, "call history is not repeated on Home"
assert "UICollectionViewFlowLayout()" in dashboard and "func columnCount(forWidth" in dashboard, \
    "door tiles are a collection view with adaptive columns"
tabs = source("ios/Doorbell/HomeTabs.swift")
assert "final class PanelTabBarController: UITabBarController" in tabs
assert "settingsGate.onUnlockRequested?()" in tabs and "return false" in tabs, \
    "the Settings tab does not open without the admin password"
assert "settingsGate.lock()" in tabs, "leaving the Settings tab closes the admin window"
assert "self.adminQr = AdminQrView(core: core, boot: boot, texts: texts," in dashboard, \
    "the admin QR is always visible on an indoor panel"
assert "footerCard.contentView.addSubview(adminQr)" in dashboard
assert "let side = qrSide ?? 72" in source("ios/Doorbell/AdminQrView.swift")
assert "adminQr.setDetailText(DoorbellTheme.versionLine" in dashboard
assert "func applyLayout(for size: CGSize)" in dashboard and \
    "func applyLayout(for size: CGSize)" in visitor, "both home screens are size-driven"
assert "core.markCallLogSeen()" in history, "showing the history marks it seen"
assert "UISegmentedControl" in history and "UISplitViewController()" in history and \
    "final class CallHistoryDetailController: UITableViewController" in history
assert "CallHistory.pageSize" in history and "history.load_more" in strings

# --- cross-cutting rules ---------------------------------------------------
assert "UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)" in theme, \
    "coloured labels keep 6/12 padding"
assert "func twoPart(" in theme and "primarySize * 0.8" in theme, \
    "a two-part label renders its second line smaller"
assert "func twoPartTitle(" in theme and "for: .focused" in theme, \
    "a button's two-part title keeps its split when tvOS focuses it"
assert "0.2126" in theme and "func contrast(" in theme
# The automatic theme is computed by Core and delivered in the display contract; it is never
# stored, so a shell that read it from configuration would find nothing.
assert '"theme.auto_ink.\\(region)"' in theme and '"theme.ink_override.\\(region)"' in theme
assert '"theme.call_button_bg"' in theme and '"theme.call_button_ink"' in theme, \
    "the button's text colour must come from Core, not be recomputed"
assert '"theme.auto_background.color"' in theme
assert '"appearance.effective"' in theme and '"appearance.follow_system"' in theme
assert "func contrastWarning(" in theme and "theme.contrast_warning" in strings, \
    "a colour that fails WCAG is warned about, never rejected"
assert "auto_schedule" in theme
assert "core v" in theme and "app v" in theme, "both versions appear in the identity line"
assert "power.charging" in theme

# --- localization ----------------------------------------------------------
for key in ("settings.title", "settings.section_device", "web_admin.open", "door.hint_call",
            "notice.target_global", "sos.slide_two_line", "history.filter_missed",
            "ring.mic_unavailable", "theme.contrast_warning"):
    assert f"\n{key}:" in strings, key
assert "sos.slide_two_line" in sos, "the SOS label is a deliberate two-part string"

# --- the panel stays awake, and stays on the mesh ---------------------------
# An auto-locked device suspends its foreground app: the listening sockets are closed, so 47180
# and 47172 refuse connections instead of stalling, the cluster marks the node dead, and the
# process is evicted later with no crash report, no jetsam event and no resource report. From the
# outside that is indistinguishable from a hang. The override that prevents it is an intent held
# in one place and re-asserted on activation, never a flag set once at launch.
assert "enum ScreenAwake" in availability, "one owner for the idle-timer override"
assert "UIApplication.shared.isIdleTimerDisabled = wanted" in availability
for name, shell in (("AppDelegate", app_delegate), ("TVAppDelegate", tv_delegate)):
    assert "ScreenAwake.want(true)" in shell, f"{name} asks for a screen that never sleeps"
    assert "func applicationDidBecomeActive" in shell and "ScreenAwake.apply()" in shell, \
        f"{name} re-asserts the override on every activation, not only at launch"
# Nothing may write the flag behind ScreenAwake's back: the iOS 9 admin alert used to clear it and
# restore it from its OK button alone, so leaving through either of the other two actions left the
# panel able to lock, for good.
for name, shell in (("AppDelegate", app_delegate), ("MainViewController", main),
                    ("DebugInfoViewController", debug_info), ("TVAppDelegate", tv_delegate)):
    assert "isIdleTimerDisabled = " not in shell, \
        f"{name} must change the idle timer through ScreenAwake"

# A door station that resigned active is still the household's doorbell. Core is stopped only on a
# real termination or a deliberate reset -- never on a lifecycle transition.
for name, shell in (("AppDelegate", app_delegate), ("TVAppDelegate", tv_delegate)):
    for handler in ("applicationDidBecomeActive", "applicationWillResignActive",
                    "applicationDidEnterBackground", "applicationWillEnterForeground"):
        marker = "func " + handler
        if marker not in shell:
            continue
        body = shell.split(marker, 1)[1].split("\n    func ", 1)[0]
        assert "core.stop()" not in body, f"{name}.{handler} must never stop Core"
        assert "runtime?.stop(" not in body, f"{name}.{handler} must never stop the supervisor"
    assert "func applicationWillTerminate" in shell and "core.stop()" in shell, \
        f"{name} still stops Core on a real termination"

# --- a silent death leaves a file behind ------------------------------------
# The last one left nothing at all to read, so the shell now keeps its own record next to the
# database: the launch, Core starting and stopping, every lifecycle transition and the most recent
# UI events. Only when boot.json asks for timings, and the UI events are buffered so that
# peers_changed several times a second does not become its own load.
assert "enum ShellLog" in availability
assert "shell.log" in availability, "written next to the database, readable over SSH"
assert "minFlushIntervalS" in availability, "UI events are buffered, not written per event"
assert "ShellLog.enabled = boot.debugTimings" in app_delegate, "off on a shipped panel"
for line in ("ShellLog.start(", "ShellLog.note(\"core.start", "ShellLog.uiEvent(",
             "lifecycle didBecomeActive", "lifecycle willResignActive",
             "lifecycle didEnterBackground", "lifecycle willTerminate"):
    assert line in app_delegate, line


print("native settings contract test passed")
