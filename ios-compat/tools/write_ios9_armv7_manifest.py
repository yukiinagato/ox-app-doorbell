#!/usr/bin/env python3
"""Write release evidence for an iOS 9/armv7 compatibility package."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from ios9_armv7_profile import parse_minimum_versions


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def bundle_hash(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(relative)
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def source_hash(repository: Path) -> str:
    paths = subprocess.check_output([
        "git", "-C", str(repository), "ls-files", "-z", "--cached", "--others",
        "--exclude-standard", "--", "core", "ios-kiosk", "ios-compat",
    ]).split(b"\0")
    digest = hashlib.sha256()
    for raw in sorted(item for item in paths if item):
        path = repository / raw.decode("utf-8")
        digest.update(raw)
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"error: {message}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--context", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--core-archive", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    repository = Path(__file__).resolve().parents[2]
    context = json.loads(args.context.read_text(encoding="utf-8"))
    app = args.app.resolve()
    executable = app / "Doorbell"
    artifact = args.artifact.resolve()
    core_archive = args.core_archive.resolve()
    for path in (executable, app / "Info.plist", artifact, core_archive):
        require(path.exists(), f"release input is missing: {path}")
    require(context.get("profile") == "ios9-armv7-pjsip",
            "preflight context has the wrong profile")
    require(context.get("architectures") == ["armv7"] and
            context.get("minimum_os") == "9.0" and
            context.get("sip_backend") == "real_pjsip",
            "preflight context does not describe the formal lane")
    tools = context["tools"]
    require(command(tools["lipo"], "-archs", str(executable)).split() == ["armv7"],
            "application is not armv7-only")
    minimums = parse_minimum_versions(command(tools["otool"], "-l", str(executable)))
    require(minimums == {"9.0"},
            f"application minimum OS is {sorted(minimums)}, expected 9.0")
    symbols = command(tools["nm"], "-gU", str(executable))
    for symbol in ("_db_core_create_v2", "_pjsua_create",
                   "_pjsua_call_make_call", "_pjsua_call_answer"):
        require(any(line.rstrip().endswith(symbol) for line in symbols.splitlines()),
                f"application does not define {symbol}")
    unresolved = command(tools["nm"], "-u", str(executable))
    require("_pjsua_" not in unresolved, "application has unresolved PJSIP symbols")
    require("_ms_call" not in symbols and "_ms_listen" not in symbols,
            "application contains forbidden MiniSIP symbols")

    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info.get("MinimumOSVersion") == "9.0", "Info.plist minimum OS is not 9.0")
    require(info.get("UIDeviceFamily") == [1, 2],
            "Info.plist must support both iPhone and iPad")
    require(str(info.get("CFBundleShortVersionString")) == context["short_version"] and
            str(info.get("CFBundleVersion")) == context["build_version"],
            "Info.plist versions differ from the preflight evidence")

    signing = dict(context["signing"])
    signing.pop("profile_path", None)
    signing.pop("ldid", None)
    if signing["mode"] == "stock":
        profile = app / "embedded.mobileprovision"
        require(profile.is_file(), "stock package has no embedded provisioning profile")
        require(sha256(profile) == signing["profile_sha256"],
                "embedded provisioning profile differs from preflight")
        codesign = shutil.which("codesign")
        require(codesign is not None, "codesign is required")
        subprocess.run([codesign, "--verify", "--deep", "--strict", str(app)], check=True)
        signing["codesign_strict_verified"] = True
        require(artifact.suffix.lower() == ".ipa", "stock artifact must be an IPA")
    else:
        ldid = context["signing"]["ldid"]
        entitlements = subprocess.check_output([ldid, "-e", str(executable)])
        signing["entitlements_sha256"] = hashlib.sha256(entitlements).hexdigest()
        require(artifact.suffix.lower() == ".deb", "jailbreak artifact must be a DEB")

    status = command(
        "git", "-C", str(repository), "status", "--porcelain",
        "--untracked-files=normal", "--", "core", "ios-kiosk", "ios-compat",
    )
    require(status == "", "formal release evidence cannot be written from a dirty source tree")
    pjsip_manifest = Path(context["pjsip"]["manifest"])
    source_revision = command("git", "-C", str(repository), "rev-parse", "HEAD")
    manifest = {
        "schema_version": 1,
        "artifact": artifact.name,
        "artifact_key": context["cache_key"],
        "artifact_key_fields": {
            "platform": "iphoneos",
            "minimum_os": "9.0",
            "architectures": ["armv7"],
            "sip_backend": "real_pjsip",
            "signing_mode": signing["mode"],
            "sdk_settings_sha256": context["sdk_settings_sha256"],
        },
        "artifact_sha256": sha256(artifact),
        "architectures": ["armv7"],
        "build_version": context["build_version"],
        "bundle_identifier": context["bundle_identifier"],
        "bundle_sha256": bundle_hash(app),
        "core_archive_sha256": sha256(core_archive),
        "device_families": [1, 2],
        "minimum_os": "9.0",
        "pjsip_archive_set_sha256": context["pjsip"]["archive_set_sha256"],
        "pjsip_manifest_sha256": sha256(pjsip_manifest),
        "profile": context["profile"],
        "short_version": context["short_version"],
        "signing": signing,
        "sip_backend": "real_pjsip",
        "source_dirty": False,
        "source_revision": source_revision,
        "source_sha256": source_hash(repository),
        "toolchain": {
            "app_clang": command(context["tools"]["app_clang"], "--version").splitlines()[0],
            "core_clang": command(context["tools"]["core_clang"], "--version").splitlines()[0],
            "sdk_canonical_name": context["sdk_canonical_name"],
            "sdk_settings_sha256": context["sdk_settings_sha256"],
            "sdk_version": context["sdk_version"],
            "xcode": context["xcode"],
        },
        "video_adapter": "public_videotoolbox",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                         encoding="utf-8")
    temporary.replace(args.output)
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
