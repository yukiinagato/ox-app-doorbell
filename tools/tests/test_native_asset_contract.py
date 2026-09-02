#!/usr/bin/env python3
"""Cross-platform contract checks for native theme asset retrieval."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NativeAssetContract(unittest.TestCase):
    def test_native_theme_requests_do_not_use_panel_credentials(self):
        sources = [
            "android/app/src/main/java/jp/keihan/doorbell/MainActivity.kt",
            "ios/Doorbell/MainViewController.swift",
            "ios-kiosk/src/Screens/DBHomeScreen.m",
            "win/DoorbellApp/MainWindow.xaml.cs",
        ]
        for relative in sources:
            with self.subTest(source=relative):
                source = (ROOT / relative).read_text(encoding="utf-8")
                self.assertIn("/asset/", source)
                self.assertNotIn("panel.tokens", source)
                self.assertNotIn("?k=", source)


if __name__ == "__main__":
    unittest.main()
