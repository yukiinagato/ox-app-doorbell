#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import unittest
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


profile_tool = load_module(
    "ios9_armv7_profile",
    REPOSITORY / "ios-compat/tools/ios9_armv7_profile.py",
)
package_tool = load_module(
    "package_ios9_armv7",
    REPOSITORY / "ios-compat/tools/package_ios9_armv7.py",
)


STATIC_FILES = (
    "ios-compat/profiles/ios9-armv7.profile.json",
    "ios-compat/profiles/ios9-armv7.Info.plist",
    "ios-compat/make/ios9-armv7.mk",
    "ios-kiosk/src/Core/DBCompatibilityProfile.h",
    "ios-kiosk/src/Media/DBVtVideoView.m",
    "ios-kiosk/src/Screens/DBRouter.m",
    "ios-kiosk/src/Support/DBRecoveryClient.m",
    "ios-kiosk/src/Support/DBAppDelegate.m",
)


class StaticProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="db-ios9-profile-")
        self.root = Path(self.temporary.name)
        for relative in STATIC_FILES:
            source = REPOSITORY / relative
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_approved_static_profile(self) -> None:
        result = profile_tool.validate_static(self.root)
        self.assertEqual(result["architectures"], ["armv7"])
        self.assertEqual(result["device_families"], [1, 2])
        self.assertEqual(result["minimum_os"], "9.0")

    def test_wrong_architecture_fails_closed(self) -> None:
        path = self.root / "ios-compat/profiles/ios9-armv7.profile.json"
        profile = json.loads(path.read_text(encoding="utf-8"))
        profile["architectures"] = ["arm64"]
        path.write_text(json.dumps(profile), encoding="utf-8")
        with self.assertRaises(profile_tool.GateError):
            profile_tool.validate_static(self.root)

    def test_non_numeric_bundle_version_is_rejected(self) -> None:
        path = self.root / "ios-compat/profiles/ios9-armv7.Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleVersion"] = "release-400"
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(profile_tool.GateError):
            profile_tool.validate_static(self.root)

    def test_third_ui_tree_is_rejected(self) -> None:
        (self.root / "ios-compat/src").mkdir(parents=True)
        with self.assertRaises(profile_tool.GateError):
            profile_tool.validate_static(self.root)

    def test_minimum_os_parser_ignores_sdk_version(self) -> None:
        commands = """
Load command 8
      cmd LC_BUILD_VERSION
 platform 2
    minos 9.0
      sdk 9.3
Load command 9
      cmd LC_SOURCE_VERSION
  version 12.4
"""
        self.assertEqual(profile_tool.parse_minimum_versions(commands), {"9.0"})

    def test_formal_preflight_requires_license_attestation(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(profile_tool.GateError, "licens"):
                profile_tool.validate_preflight(self.root, "jailbreak")


class PjsipEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="db-ios9-pjsip-")
        self.root = Path(self.temporary.name)
        self.pjsip = self.root / profile_tool.PJSIP_RELATIVE
        (self.pjsip / "include/pjsua-lib").mkdir(parents=True)
        (self.pjsip / "include/pjsua-lib/pjsua.h").write_text("/* fixture */\n")
        library_dir = self.pjsip / "lib"
        library_dir.mkdir()
        self.library = library_dir / "libpj-arm-apple-darwin.a"
        self.library.write_bytes(b"deterministic-pjsip-fixture")
        digest = hashlib.sha256()
        digest.update(self.library.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(self.library.read_bytes()).digest())
        self.manifest_path = self.pjsip / "artifact-manifest.json"
        self.manifest = {
            "schema_version": 1,
            "artifact": "pjsip-static",
            "platform": "iphoneos",
            "architectures": ["armv7"],
            "minimum_os": "9.0",
            "sip_backend": "real_pjsip",
            "pjsip_version": "2.15.1",
            "pjsip_source_sha256": "1" * 64,
            "archive_set_sha256": digest.hexdigest(),
            "signing_identity": "unsigned-static-library",
            "toolchain": {
                "xcode": "Xcode 7.3.1 Build version 7D1014",
                "sdk_version": "9.3",
            },
        }
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")
        self.tools: dict[str, str] = {}
        outputs = {
            "lipo": "#!/bin/sh\necho armv7\n",
            "otool": (
                "#!/bin/sh\n"
                "echo '      cmd LC_VERSION_MIN_IPHONEOS'\n"
                "echo '  version 9.0'\n"
            ),
            "nm": (
                "#!/bin/sh\n"
                "echo '00000000 T _pjsua_create'\n"
                "echo '00000004 T _pjsua_call_make_call'\n"
                "echo '00000008 T _pjsua_call_answer'\n"
            ),
        }
        for name, content in outputs.items():
            path = self.root / name
            path.write_text(content, encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
            self.tools[name] = str(path)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_real_armv7_uac_uas_evidence(self) -> None:
        result = profile_tool.validate_pjsip(
            self.root, {"pjsip_version": "2.15.1"}, self.tools
        )
        self.assertEqual(result["library_count"], 1)
        self.assertEqual(result["archive_set_sha256"],
                         self.manifest["archive_set_sha256"])

    def test_stub_manifest_is_rejected(self) -> None:
        self.manifest["sip_backend"] = "stub"
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")
        with self.assertRaises(profile_tool.GateError):
            profile_tool.validate_pjsip(
                self.root, {"pjsip_version": "2.15.1"}, self.tools
            )


class PackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="db-ios9-package-")
        self.root = Path(self.temporary.name)
        self.app = self.root / "Doorbell.app"
        self.app.mkdir()
        executable = self.app / "Doorbell"
        executable.write_bytes(b"Mach-O fixture")
        executable.chmod(0o755)
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"Fixture": True}))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_stock_ipa_and_jailbreak_deb_are_deterministic_and_separate(self) -> None:
        first = self.root / "first.ipa"
        second = self.root / "second.ipa"
        package_tool.scan_credentials(self.app)
        package_tool.stock_ipa(self.app, first, 1_700_000_000)
        package_tool.stock_ipa(self.app, second, 1_700_000_000)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        deb1 = self.root / "first.deb"
        deb2 = self.root / "second.deb"
        package_tool.jailbreak_deb(self.app, deb1, "0.4.0-400", 1_700_000_000)
        package_tool.jailbreak_deb(self.app, deb2, "0.4.0-400", 1_700_000_000)
        self.assertEqual(deb1.read_bytes(), deb2.read_bytes())
        self.assertNotEqual(first.read_bytes(), deb1.read_bytes())

    def test_embedded_plaintext_secret_is_rejected(self) -> None:
        (self.app / "boot.json").write_text('{"psk_hex":"abcd"}', encoding="utf-8")
        with self.assertRaises(SystemExit):
            package_tool.scan_credentials(self.app)


if __name__ == "__main__":
    unittest.main()
