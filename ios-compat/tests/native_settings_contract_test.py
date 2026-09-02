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
                     ("db_core_admin_password_verify", "supportsAdminPassword"),
                     ("db_core_admin_password_set", "supportsAdminPasswordChange"),
                     ("db_core_set_global_notice", "supportsGlobalNotice"),
                     ("db_core_clear_global_notice", "supportsGlobalNotice"),
                     ("db_core_call_log_json_v2", "supportsCallLogPaging"),
                     ("db_core_mint_join_token_json", "supportsMintJoinToken")):
    assert f'symbol("{symbol}")' in bridge or f'"{symbol}"' in bridge, symbol
    assert f"var {flag}: Bool" in bridge, flag
assert 'dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)' in bridge, \
    "runtime lookups go through one helper"

# The 管理パスワード is the cluster secret, and the old per-node digest is retired once Core has
# accepted it on this device.
admin = source("ios/Doorbell/AdminPinViewController.swift")
assert "core?.verifyAdminPassword(pin)" in admin
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
for shell, name in ((main, "MainViewController"), (tv, "TVMainViewController")):
    assert "DoorbellClock.read(core)" in shell, name
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
assert "ring.monitor_on" in incoming and "ring.mic_on" in incoming
assert "incoming.debug_line_hidden" in incoming, "the debug line's state is remembered"
assert "AdminQrView(core: core, boot: boot, texts: texts, compact: true)" in incoming
assert "DoorUnlock.showsButton(status: core.status(), config: cfg,\n" in incoming
assert "core.openDoor(door)" in incoming, "unlock uses Core's own open-door action"
assert "door.unlock_not_configured" in incoming, "an unconfigured unlock must explain itself"

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
