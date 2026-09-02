#!/usr/bin/env python3
"""Source contract for the round-6 pairing decisions (spec §5.4) on the kiosk.

Two rules the UI must not blur:
  1. Minting the Pairing PIN is separate from 「まとめて追加」. The PIN card and
     the founder flow call the dedicated mint export; only the explicit bulk-add
     button, which carries its own warning, opens the pairing window.
  2. Revoke is a factory reset. Both a remote `pairing_revoked` and the local
     「クラスタから外す」 confirmation wipe the secure PSK, the boot.json pairing
     fields, and the name/role/door/setup_complete choice, then return the
     device to first-run setup.

The arithmetic behind rule 2 is covered by the host suite
(ios-compat/tests/native_settings_ux_test.m); this file pins the wiring.
"""

import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def read(relative_path):
    with open(os.path.join(ROOT, relative_path), encoding="utf-8") as handle:
        return handle.read()


class PairingFlowContracts(unittest.TestCase):
    def test_pin_minting_never_opens_the_bulk_add_window(self):
        add_device = read("ios-kiosk/src/Screens/DBAddDeviceScreen.m")
        pairing = read("ios-kiosk/src/Screens/DBPairingScreen.m")
        bridge_header = read("ios-kiosk/src/Core/DBCoreBridge.h")
        bridge = read("ios-kiosk/src/Core/DBCoreBridge.m")

        # The PIN card mints; it does not open the window.
        start_code = add_device[add_device.index("- (void)onStartCode"):
                                add_device.index("- (void)onAddAll")]
        self.assertIn("mintJoinTokenWithSeconds:600", start_code)
        self.assertNotIn("startPairingWithSeconds", start_code)
        self.assertNotIn("setPairingMode", start_code)

        # Founding a cluster shows the PIN card and this device's own QR only.
        create = pairing[pairing.index("- (void)onCreate"):]
        self.assertIn("mintJoinTokenWithSeconds:600", create)
        self.assertNotIn("startPairingWithSeconds", create)

        # 「まとめて追加」 is the one caller that opens the window.
        add_all = add_device[add_device.index("- (void)onAddAll"):
                             add_device.index("- (void)onStopAddAll")]
        self.assertIn("startPairingWithSeconds:600", add_all)
        self.assertIn("pair.add_all_warning", add_device)

        # An older core has no export: the card stays empty and says why,
        # rather than falling back to the window.
        self.assertIn("supportsJoinTokenMinting", bridge_header)
        self.assertIn("pair.mint_unsupported", add_device)
        self.assertIn('dlsym(RTLD_DEFAULT, "db_core_mint_join_token_json")', bridge)

    def test_revocation_is_a_factory_reset_of_identity_and_setup(self):
        router = read("ios-kiosk/src/Screens/DBRouter.m")
        add_device = read("ios-kiosk/src/Screens/DBAddDeviceScreen.m")
        boot = read("ios-kiosk/src/Core/DBBootConfig.m")
        delegate = read("ios-kiosk/src/Support/DBAppDelegate.m")

        reset_start = router.index("- (void)factoryResetForRevocation:")
        reset = router[reset_start:router.index("\n- (", reset_start + 10)]
        self.assertIn("[_core unpair]", reset)
        self.assertIn('storeSecret:@"mesh.psk" value:@""', reset)
        self.assertIn("clearPairingAndSetup", reset)
        self.assertIn("setupRequired = YES", reset)
        self.assertIn("restartIntoBootstrapSetup", reset)

        # Both entry points reach it: the replicated event and the local confirm.
        revoked = router[router.index('isEqualToString:@"pairing_revoked"'):]
        self.assertIn("factoryResetForRevocation:", revoked[:600])
        unpair = add_device[add_device.index("- (void)onUnpair"):]
        self.assertIn("factoryResetForRevocation:", unpair)

        # The profile transformation drops cluster identity and the setup choice.
        transform = boot[boot.index("+ (NSString *)factoryResetJsonFromJson:"):
                         boot.index("+ (BOOL)persistSetupName:")]
        for key in ("psk_hex", "psk_ref", "seed_peers", "name", "role", "door"):
            self.assertIn('removeObjectForKey:@"%s"' % key, transform)
        self.assertIn('forKey:@"setup_complete"', transform)

        # Returning to first-run setup stops the running node first.
        restart_start = delegate.index("- (void)restartIntoBootstrapSetup {")
        restart = delegate[restart_start:delegate.index("\n- (", restart_start + 10)]
        self.assertIn("[_core stop]", restart)
        self.assertIn("[_recovery stop]", restart)
        self.assertIn("showBootstrapSetup", restart)


if __name__ == "__main__":
    unittest.main(verbosity=2)
