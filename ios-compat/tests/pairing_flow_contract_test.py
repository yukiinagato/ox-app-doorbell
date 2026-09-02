#!/usr/bin/env python3
"""Round-6 pairing decisions for the modern Swift shell.

Two rules are easy to break by accident and expensive when they break:

1. Showing a Pairing PIN must not start adding every device it can see. Minting is its own Core
   entry point; the bulk-add window stays behind its own button and its warning.
2. Leaving the cluster — whether the administrator removes the device or it is revoked remotely —
   returns the device to its first-run state, identity included.
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

print("pairing flow contract test passed")
