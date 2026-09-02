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
settings = source("ios/Doorbell/SettingsViewController.swift")
dashboard = source("ios/Doorbell/DashboardView.swift")
visitor = source("ios/Doorbell/VisitorScreenView.swift")
incoming = source("ios/Doorbell/IncomingViewController.swift")
main = source("ios/Doorbell/MainViewController.swift")
tv = source("ios/DoorbellTV/TVMainViewController.swift")
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
assert "settings.change_password" in settings and "core.setAdminPassword(current:" in settings
assert "case secret(title: String" in source("ios/Doorbell/SettingsForm.swift"), \
    "a password field is never pre-filled or echoed"

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

# Items that deliberately stay in the web admin must say why, next to what they replace.
for reason in ("settings.web_only_upload", "settings.web_only_wording",
               "settings.web_only_rule_actions", "settings.web_only_secrets",
               "settings.web_only_raw_config"):
    assert reason in settings, reason
    assert reason.replace("_", "_") in strings

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
assert "emergency.trigger.countdown_s" in main and "emergency.trigger.countdown_s" in dashboard
assert "core.emergency" not in sos, "the slider must not talk to Core itself"
assert "onTriggered?()" in sos and "private func fire()" in sos
assert "func cancelCountdown()" in sos
assert "sosSlider.onTriggered = { [weak self] in self?.triggerEmergency() }" in main
assert 'ConfigUtil.double(cfg, "emergency.hold_to_trigger_s"' not in main, \
    "the legacy long-press must no longer drive the trigger"
assert "UILongPressGestureRecognizer" not in main, "the SOS long press is replaced by the slider"

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
assert "applyVideoAspect" in incoming and "liveView.heightAnchor.constraint(equalTo:" in incoming
# Both toggles show their state, and the state is the authored second line rather than a suffix
# the button would have to shrink to fit.
assert "ring.monitor_two_line_on" in incoming and "ring.mic_two_line_on" in incoming
assert "DoorbellTheme.twoPartTitle(text, on: button," in incoming, \
    "the control row renders its labels through the two-part renderer"
assert 'color: button.titleColor(for: .normal)' in incoming, \
    "a semantic foreground override must survive the two-part rendering"
assert "incoming.debug_line_hidden" in incoming, "the debug line's state is remembered"
assert "AdminQrView(core: core, boot: boot, texts: texts, compact: true)" in incoming
assert "DoorUnlock.showsButton(status: core.status(), config: cfg,\n" in incoming
assert "core.openDoor(door)" in incoming, "unlock uses Core's own open-door action"
assert "door.unlock_not_configured" in incoming, "an unconfigured unlock must explain itself"

# --- the theme background reaches every panel, not only the door station ----
# The owner's decision: an indoor panel wears the household's theme background too, and §5's
# automatic contrast — not a switch back to the palette — is what keeps its text readable.
assert "class ThemeBackgroundView" in theme and "func apply(display:" in theme
assert "struct DoorbellSkin" in theme and "func cardInk(" in theme, \
    "bare text takes the region's automatic ink; cards this shell painted keep the palette"
assert "surfaceSolid" in theme and "func solid(" in theme, \
    "a card over a theme picture has to be opaque or its palette ink stops being readable"
for region in ("clock", "date", "status_line", "hint", "tile_label", "footer", "notice"):
    assert f'"{region}"' in theme + dashboard + visitor + incoming, region
for shell, name in ((main, "MainViewController"), (tv, "TVMainViewController"),
                    (incoming, "IncomingViewController"),
                    (source("ios/Doorbell/MonitorViewController.swift"), "Monitor")):
    assert "themeBg.apply(display:" in shell, name
assert 'boot.role == "door_station"' not in main.split("private func applyTheme")[1][:400], \
    "the theme background is no longer gated on the door station"
assert 'skin.apply("clock", to: clockLabel)' in dashboard and \
    'skin.apply("footer", to: versionLabel, quiet: true)' in dashboard
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
assert "ConfigUtil.allPurposeIds(config)" in settings, "the settings list shows every purpose"
assert "ConfigUtil.purposeIsEnabled(entry)" in settings
assert 'write([.set("visit_purposes.\\(id).enabled", value)])' in settings, \
    "the toggle writes that one key and nothing else"

# --- dashboard -------------------------------------------------------------
assert "/snapshot.jpg" in dashboard and "withTimeInterval: 5" in dashboard
assert "history.missed_badge" in dashboard and "history.see_all" in dashboard
assert "AdminQrView(core: core, boot: boot, texts: texts, compact: false)" in dashboard, \
    "the admin QR is always visible on an indoor panel"
assert "DoorbellTheme.versionLine" in dashboard
assert "func applyLayout(for size: CGSize)" in dashboard and \
    "func applyLayout(for size: CGSize)" in visitor, "both home screens are size-driven"
assert "core.markCallLogSeen()" in history, "opening the history marks it seen"
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

print("native settings contract test passed")
