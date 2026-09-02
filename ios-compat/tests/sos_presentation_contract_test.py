#!/usr/bin/env python3
"""Static SOS presentation checks for Apple shells with incompatible SDK baselines."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class SosPresentationContract(unittest.TestCase):
    def test_modern_ios_reports_actual_channel_application(self):
        app = read("ios/Doorbell/AppDelegate.swift")
        runtime = read("ios/Doorbell/RuntimeSupervisor.swift")
        notifier = app[app.index("private final class EmergencySystemNotifier"):]

        self.assertIn("ConfigUtil.eventChannels(event)", notifier)
        self.assertIn("systemSoundEnabled", notifier)
        self.assertIn('finish("permission_denied")', notifier)
        self.assertIn("settings.alertSetting == .enabled", notifier)
        self.assertIn("settings.soundSetting == .enabled", notifier)
        self.assertIn("guard !sticky, ttl > 0", notifier)
        self.assertIn('next["result"] = active ? "ttl_expired" : "cleared"', notifier)
        self.assertIn("recordDeviceAlert", runtime)
        self.assertIn('"device_alert": deviceAlertReport', runtime)
        self.assertIn('"ui_style": UIStyleApplier.runtimeReport()', runtime)

    def test_ios_compat_keeps_core_state_when_local_ttl_expires(self):
        router = read("ios-kiosk/src/Screens/DBRouter.m")
        timeout = router[router.index("onEmergencyPresentationTimeout:"):
                         router.index("postEmergencySystemNotification:")]
        handler = router[router.index('isEqualToString:@"emergency"'):
                         router.index('isEqualToString:@"paired"')]

        self.assertIn("hideEmergencyPresentation", timeout)
        self.assertIn("clearEmergencySystemNotification", timeout)
        self.assertNotIn("emergency:NO", timeout)
        self.assertIn("systemSound = sound && (!inApp || !active)", handler)
        self.assertIn("if (!sticky && ttl > 0)", handler)
        self.assertIn("publishEmergencyReportForEvent", handler)
        self.assertIn('@"unsupported_channel"', handler)
        self.assertNotIn("systemNotification || !active", handler)

    def test_ios_compat_preserves_sos_ui_when_durable_commit_fails(self):
        bridge = read("ios-kiosk/src/Core/DBCoreBridge.m")
        header = read("ios-kiosk/src/Core/DBCoreBridge.h")
        home = read("ios-kiosk/src/Screens/DBHomeScreen.m")
        self.assertIn("- (BOOL)emergency:(BOOL)active", header)
        self.assertIn("db_core_emergency_v2", bridge)
        self.assertIn("return committed", bridge)
        cancel = home[home.index("- (void)cancelEmergencyConfirmed"):
                      home.index("- (void)playChime")]
        self.assertIn("if ([_core emergency:NO]) [self hideEmergencyEvent:nil]", cancel)


if __name__ == "__main__":
    unittest.main()
