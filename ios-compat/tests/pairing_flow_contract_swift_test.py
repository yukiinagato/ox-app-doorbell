#!/usr/bin/env python3
"""Round-6 pairing decisions for the modern Swift shell.

Two rules are easy to break by accident and expensive when they break:

1. Showing a Pairing PIN must not start adding every device it can see. Minting is its own Core
   entry point; the bulk-add window stays behind its own button and its warning.
2. Leaving the cluster — whether the administrator removes the device or it is revoked remotely —
   returns the device to its first-run state, identity included.

3. The pairing screens are stock grouped tables under a navigation bar, painted only from the
   `SystemStyle` roles; every destructive step still confirms and names its consequence, and the
   semantic identifiers automation drives stay where they were.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


bridge = source("ios/Doorbell/CoreBridge.swift")
add_device = source("ios/Doorbell/AddDeviceViewController.swift")
pairing = source("ios/Doorbell/PairingViewController.swift")
app_delegate = source("ios/Doorbell/AppDelegate.swift")
tv_delegate = source("ios/DoorbellTV/TVAppDelegate.swift")
support = source("ios/Doorbell/PairingSupport.swift")
scanner = source("ios/Doorbell/PairingScannerViewController.swift")
debug_info = source("ios/Doorbell/DebugInfoViewController.swift")
strings = source("i18n/strings.yaml")


# --- 1. minting a PIN is separate from bulk add ----------------------------
assert 'dlsym(UnsafeMutableRawPointer(bitPattern: -2),\n                                 "db_core_mint_join_token_json")' in bridge, \
    "the mint entry point is resolved at runtime so an older Core still links"
assert "var supportsMintJoinToken: Bool" in bridge
assert "func mintJoinToken(seconds: Int32 = 600)" in bridge

for shell, name in ((add_device, "AddDeviceViewController"), (pairing, "PairingViewController")):
    body = shell[shell.index("startCode"):]
    assert "core.mintJoinToken(seconds: 600)" in body, name
    assert "core.startPairing" not in body, \
        f"{name} must never mint a PIN through the bulk-add entry point"
    assert "pair.pin_unavailable" in body, \
        f"{name} must say so when Core cannot mint a PIN"

# Bulk add keeps its own button, its own window and its warning.
assert "@objc private func startAddAll() {\n        core.pairingMode(seconds: 600)" in add_device
assert "pair.add_all_warning" in add_device


# --- 2. leaving the cluster is a first-run reset ---------------------------
assert "static let doorbellResetLocalPairing" in support, \
    "the reset notification must exist in every target, not only the phone app"

unpair = add_device[add_device.index("confirmUnpairSecondStep"):]
assert "self.core.unpair()" in unpair
assert "NotificationCenter.default.post(name: .doorbellResetLocalPairing" in unpair, \
    "the device-side removal must run the full reset, not only clear the pairing fields"
assert "BootConfig.clearPairing()" not in unpair, \
    "clearing only the pairing fields would keep this device's old identity"
assert "pair.clear_resets_device" in add_device, "the confirmation must say what it does"
assert "\npair.clear_resets_device:" in strings

for delegate, name in ((app_delegate, "AppDelegate"), (tv_delegate, "TVAppDelegate")):
    reset = delegate[delegate.index("func resetLocalPairing"):]
    assert "Keychain.removeAll()" in reset, name
    assert "BootConfig.clearPersistedState()" in reset, name
    assert "removePersistentDomain" in reset, name
    assert ".doorbellResetLocalPairing" in delegate, name

# The phone app returns to first-run setup; the TV, which has no BootSetup screen, returns to the
# pairing gate. Either way nothing of the previous cluster identity survives.
assert "BootstrapSetupViewController(boot: boot)" in \
    app_delegate[app_delegate.index("func resetLocalPairing"):]
assert "presentPairingGate()" in tv_delegate[tv_delegate.index("func resetLocalPairing"):]
assert "announceRevocationThenReset" in app_delegate and \
    "resetLocalPairing()" in app_delegate[app_delegate.index("announceRevocationThenReset"):], \
    "a revoked device tells the user, then resets"



# --- 3. stock grouped tables, system colours, guarded destructive steps ----
assert "class PairingTableScreen: UIViewController, UITableViewDataSource, UITableViewDelegate" \
    in support
assert "UITableViewController(style: SystemStyle.tableStyle())" in support
assert "SystemStyle.navigation(list, largeTitles: prefersLargeTitle)" in support, \
    "a screen presented as itself hosts its own navigation bar"
assert "final class PairingViewController: PairingTableScreen" in pairing
assert "final class AddDeviceViewController: PairingTableScreen" in add_device
assert "final class DebugInfoViewController: PairingTableScreen" in debug_info
setup = app_delegate[app_delegate.index("private final class BootstrapSetupViewController"):]
assert setup.startswith("private final class BootstrapSetupViewController: PairingTableScreen")

for name, shell in (("PairingSupport", support), ("PairingViewController", pairing),
                    ("AddDeviceViewController", add_device),
                    ("DebugInfoViewController", debug_info)):
    assert "UIColor(red:" not in shell and "UIColor(white:" not in shell, \
        f"{name} takes its colours from the SystemStyle roles"
    for glyph in ("\u2713", "\u232b", "\u00b7" * 6):
        assert glyph not in shell, f"{name} must not type a glyph where a control belongs"
assert "static let background" not in support and "static let accent" not in support, \
    "the pairing palette is gone; only sizes remain in PairingTheme"

# Leaving the cluster is the last, red row and asks twice; the second alert names the reset.
assert 'tone: .negative,\n        identifier: "add_device_unpair"' in add_device
assert add_device.rindex("PairingSection(rows: [unpairRow])") > \
    add_device.rindex("PairingSection(footer: texts.t(\"pair.qr_caption\")"), \
    "the destructive row comes after everything else"
first_step = add_device[add_device.index("private func confirmUnpair()"):
                        add_device.index("private func confirmUnpairSecondStep()")]
assert "pair.clear_confirm" in first_step and "style: .destructive" in first_step
assert "self?.confirmUnpairSecondStep()" in first_step
assert "style: .destructive" in unpair and "pair.clear_resets_device" in unpair

# Ignoring a nearby device says what it does before it happens.
deny = add_device[add_device.index("private func confirmDeny"):]
assert "pair.deny_confirm" in deny[:deny.index("self.core.denyDevice(id)")]
# Adding one still goes through the eight-digit code that device shows.
add = add_device[add_device.index("private func add(_ id: String)"):]
assert "PairingCopy.normalizedCode" in add[:add.index("self.core.inviteDevice(id, confirmCode: code)")]

# Joining another cluster from a member device is destructive and confirmed once.
offer = pairing[pairing.index("private func offer("):pairing.index("private func fill(")]
assert "pair.invite_leave_current" in offer and "style: .destructive" in offer
# Creating a cluster is confirmed too.
create = pairing[pairing.index("private func createCluster()"):]
assert "pair.create_home_confirm" in create[:create.index("self.core.createCluster()")]

# "Pair again after the upgrade" is a warning state that leads with one filled action.
upgrade = pairing[pairing.index("if snapshot.upgradeRejoinRequired {"):]
upgrade = upgrade[:upgrade.index("} else {")]
assert "notice: .warning" in upgrade and "pair.upgrade_title" in upgrade
assert upgrade.count("PairingCells.button") == 0 and "PairingSection(rows: [rejoinRow])" in upgrade
assert 'private lazy var rejoinRow = PairingCells.button(' in pairing

# The big confirmation code and the QR codes stay on screen.
assert 'confirmLabel.font = SystemStyle.digits(size: PairingTheme.codeSize' in pairing
assert "PairingSection(footer: texts.t(\"pair.qr_caption\"), rows: [qrRow.row])" in pairing

# Semantic identifiers that automation and tests drive.
for shell, identifiers in (
        (pairing, ("pair_title", "pair_status", "pair_error", "pair_confirm_code",
                   "pair_join_with_code", "pair_create_home", "pair_later", "pair_retry",
                   "pair_host_field", "pair_pin_field", "pair_join_submit")),
        (add_device, ("add_device_title", "add_device_membership", "add_device_code",
                      "add_device_code_unavailable", "add_device_add_all",
                      "add_device_add_all_stop", "add_device_scan", "add_device_unpair",
                      "add_device_close", "add_device_peer_notice",
                      "add_device_security_notice", "pair_confirm_code",
                      "pair_row_\\(device.id)", "pair_add_\\(id)", "pair_deny_\\(id)")),
        (support, ("pair_own_qr", "pair_code_address", "pair_code_pin", "pair_code_qr",
                   "pair_copy_address", "pair_copy_pin")),
        (scanner, ("pair_scan_viewfinder", "pair_scan_message", "pair_scan_cancel",
                   "pair_scan_switch_camera")),
        (debug_info, ("debug_info_close", "debug_info_summary", "debug_info_addresses",
                      "debug_info_address_type", "debug_info_qr", "debug_info_refresh",
                      "debug_info_pairing", "debug_info_monitor")),
        (setup, ("setup_name", "setup_door", "setup_save", "setup_scroll"))):
    for identifier in identifiers:
        assert f'"{identifier}"' in shell, identifier

# The scanner keeps a custom viewfinder but its chrome is a navigation bar with bar buttons.
assert "SystemStyle.navigation(stage, largeTitles: false)" in scanner
assert "stage.navigationItem.leftBarButtonItem = cancelItem" in scanner

print("pairing flow contract test passed")
