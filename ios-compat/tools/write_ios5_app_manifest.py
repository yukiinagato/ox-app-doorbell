#!/usr/bin/env python3
"""Write the verified iOS 5 application artifact manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle_hash(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(relative)
        digest.update(b"\0")
        digest.update(sha256(path).encode("ascii"))
    return digest.hexdigest()


def tracked_source_hash(repository: Path) -> str:
    raw = subprocess.check_output(
        ["git", "-C", str(repository), "ls-files", "-z", "--cached", "--others",
         "--exclude-standard", "--", "ios-kiosk", "ios-compat"]
    )
    digest = hashlib.sha256()
    for entry in sorted(item for item in raw.split(b"\0") if item):
        path = repository / entry.decode("utf-8")
        digest.update(entry)
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--core-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    app = args.app.resolve()
    executable = app / "Doorbell"
    info_path = app / "Info.plist"
    if not executable.is_file() or not info_path.is_file():
        parser.error("the verified Doorbell.app bundle is incomplete")
    if not args.core_manifest.is_file():
        parser.error("the verified iOS 5 Core manifest is missing")

    repository = Path(__file__).resolve().parents[2]
    info = plistlib.loads(info_path.read_bytes())
    architectures = command("lipo", "-archs", str(executable)).split()
    if architectures != ["armv7"]:
        raise SystemExit(f"unexpected application architectures: {architectures}")
    load_commands = command("otool", "-l", str(executable))
    if "LC_CODE_SIGNATURE" not in load_commands:
        raise SystemExit("the application has no code-signature load command")
    subprocess.run(["ldid", "-e", str(executable)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    status = command(
        "git", "-C", str(repository), "status", "--porcelain",
        "--untracked-files=normal", "--", "ios-kiosk", "ios-compat",
    )
    core_manifest = json.loads(args.core_manifest.read_text(encoding="utf-8"))
    manifest = {
        "schema_version": 1,
        "artifact": "Doorbell.app",
        "architectures": architectures,
        "bundle_identifier": info["CFBundleIdentifier"],
        "bundle_sha256": bundle_hash(app),
        "bundle_version": str(info["CFBundleVersion"]),
        "core_manifest_sha256": sha256(args.core_manifest),
        "core_sha256": core_manifest["sha256"],
        "minimum_os": str(info["MinimumOSVersion"]),
        "profile": "ios5-armv7-jailbreak",
        "short_version": str(info["CFBundleShortVersionString"]),
        "signing": "ldid-jailbreak",
        "sip_backend": "ios_compat_minisip_uac_uas",
        "source_dirty": bool(status),
        "source_revision": command("git", "-C", str(repository), "rev-parse", "HEAD"),
        "source_sha256": tracked_source_hash(repository),
        "toolchain": {
            "clang": command("xcrun", "clang", "--version").splitlines()[0],
            "sdk": "iPhoneOS7.1.sdk",
        },
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
