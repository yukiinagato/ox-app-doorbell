#!/usr/bin/env python3
"""Source contracts for the round-6 and round-7 decisions (spec §5.4, §5.5)
and for the cross-platform visit-purpose flag.

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


class AdminPasswordAndWriteContracts(unittest.TestCase):
    """One cluster-wide admin password and native config writes (spec §5.5)."""

    def test_the_admin_gate_is_the_cluster_password_and_the_digest_is_migrated(self):
        overlay = read("ios-kiosk/src/Screens/DBPinOverlay.m")
        bridge = read("ios-kiosk/src/Core/DBCoreBridge.m")

        accept = overlay[overlay.index("- (BOOL)acceptsEnteredPassword:"):
                         overlay.index("- (void)submit {")]
        # Core owns the comparison and the lockout it shares with /api/login.
        self.assertIn("[DBCoreBridge supportsAdminPassword]", accept)
        self.assertIn("[_core verifyAdminPassword:entered]", accept)
        self.assertIn("retireLocalDigest", accept)
        # The old per-node digest is accepted only while the cluster has no
        # password at all, proven by Core accepting it as the first one.
        self.assertIn('setAdminPasswordFrom:@"" to:entered', accept)
        self.assertIn("if (!localMatches) return NO;", accept)
        # ...and then the file is gone, so it is never a second credential.
        retire = overlay[overlay.index("+ (void)retireLocalDigest"):
                         overlay.index("- (BOOL)acceptsEnteredPassword:")]
        self.assertIn("removeItemAtPath:path", retire)
        self.assertIn('DBCoreSymbol("db_core_admin_password_verify")', bridge)
        self.assertIn("dlsym(RTLD_DEFAULT, name)", bridge)

    def test_native_settings_write_through_the_core_abi(self):
        settings = read("ios-kiosk/src/Screens/DBSettingsScreen.m")
        bridge = read("ios-kiosk/src/Core/DBCoreBridge.m")
        dialog = read("ios-kiosk/src/Screens/DBNoticeDialog.m")
        history = read("ios-kiosk/src/Screens/DBHistoryScreen.m")
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")

        for symbol in ("db_core_set_config_json", "db_core_config_batch_json",
                       "db_core_delete_config_key", "db_core_set_global_notice",
                       "db_core_clear_global_notice", "db_core_call_log_json_v2",
                       "db_core_sip_set_mic_muted"):
            self.assertIn('DBCoreSymbol("%s")' % symbol, bridge)

        # No loopback HTTP anywhere in the settings path.
        self.assertNotIn("api/config", settings)
        self.assertNotIn("api/login", settings)
        self.assertIn("[_core setConfigKey:", settings)
        self.assertIn("[_core deleteConfigKey:", settings)
        # A Core without the export says so instead of claiming a save.
        self.assertIn("status == -100", settings)

        self.assertIn("[_core setGlobalNotice:", dialog)
        self.assertIn("[_core clearGlobalNotice]", dialog)
        self.assertIn("callLogSince:0 beforeMs:beforeMs", history)
        self.assertIn("[DBCoreBridge supportsMicMute]", incoming)
        self.assertIn("[_core setMicMuted:muted]", incoming)


class VisitPurposeContracts(unittest.TestCase):
    """`visit_purposes.<id>.enabled` (bool, default true), introduced by the iOS
    package and honoured here. The arithmetic is covered by the host suite; this
    pins which screens filter on it and which deliberately do not."""

    def test_choosers_hide_disabled_purposes_but_records_keep_them(self):
        door = read("ios-kiosk/src/Screens/DBDoorScreen.m")
        settings = read("ios-kiosk/src/Screens/DBSettingsScreen.m")
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")

        # The visitor's grid, and the follow-up chooser that reads the same
        # list, offer only enabled purposes.
        rebuild = door[door.index("- (void)rebuildPurposes"):
                       door.index("- (void)rebuildLanguages")]
        self.assertIn("enabledPurposeIdsInConfig", rebuild)
        self.assertNotIn("sortedByOrder", rebuild)
        self.assertIn("_purposeAlertIDs = [_purposeIds copy]", door)

        # The editor lists every purpose, or a disabled one could never be
        # switched back on from the device, and its toggle writes the key.
        purpose_rows = settings[settings.index("- (NSArray *)purposeRows"):
                                settings.index("- (NSArray *)ruleRows")]
        self.assertIn("allPurposeIdsInConfig", purpose_rows)
        self.assertIn("enabledKeyForPurpose:purpose", purpose_rows)
        self.assertIn('@"toggle"', purpose_rows)

        # A purpose the visitor already pressed is still reported back.
        self.assertIn("Deliberately not filtered by visit_purposes", incoming)
        self.assertNotIn("enabledPurposeIdsInConfig", incoming)


if __name__ == "__main__":
    unittest.main(verbosity=2)
