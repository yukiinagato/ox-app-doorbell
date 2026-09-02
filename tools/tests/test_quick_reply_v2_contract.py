#!/usr/bin/env python3
"""Cross-platform source contracts for call-scoped native quick replies."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class QuickReplyV2Contract(unittest.TestCase):
    def test_every_native_bridge_uses_the_versioned_abi(self):
        sources = [
            "android/app/src/main/cpp/jni_bridge.cpp",
            "ios/Doorbell/CoreBridge.swift",
            "ios-kiosk/src/Core/DBCoreBridge.m",
            "win/DoorbellApp/Core/CoreInterop.cs",
        ]
        for relative in sources:
            with self.subTest(source=relative):
                self.assertIn("db_core_quick_reply_v2", read(relative))

    def test_incoming_screens_send_exact_call_identity_and_report_rejection(self):
        expectations = {
            "android/app/src/main/java/jp/ox/doorbell/IncomingActivity.kt":
                "quickReplyV2(replyId, door, callId, stageRevision)",
            "ios/Doorbell/IncomingViewController.swift":
                "door: door, callId: callId,",
            "ios-kiosk/src/Screens/DBIncomingScreen.m":
                "door:_door callID:_callID",
            "win/DoorbellApp/MainWindow.xaml.cs":
                "_incomingCallId, _incomingStageRevision",
        }
        for relative, scoped_call in expectations.items():
            with self.subTest(source=relative):
                source = read(relative)
                self.assertIn(scoped_call, source)
                self.assertIn('reply.failed', source)


if __name__ == "__main__":
    unittest.main()
