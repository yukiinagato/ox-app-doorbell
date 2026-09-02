#!/usr/bin/env python3
"""Validate the commissioned iOS 9/armv7 compatibility release profile."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
from typing import Any


PROFILE_RELATIVE = Path("ios-compat/profiles/ios9-armv7.profile.json")
INFO_RELATIVE = Path("ios-compat/profiles/ios9-armv7.Info.plist")
PJSIP_RELATIVE = Path(
    "core/third_party/pjsip/ios/iphoneos/armv7/min-9.0"
)
SEMVER_RE = re.compile(r"[0-9]+(?:\.[0-9]+){2}\Z")
BUILD_RE = re.compile(r"[1-9][0-9]*\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
SHA1_RE = re.compile(r"[0-9A-F]{40}\Z")


class GateError(RuntimeError):
    """A release precondition is not satisfied."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise GateError(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"cannot read JSON {path}: {error}") from error
    require(isinstance(value, dict), f"{path} must contain a JSON object")
    return value


def load_plist(path: Path) -> dict[str, Any]:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise GateError(f"cannot read plist {path}: {error}") from error
    require(isinstance(value, dict), f"{path} must contain a plist dictionary")
    return value


def command(
    args: list[str],
    *,
    extra_env: dict[str, str] | None = None,
    stdin: str | None = None,
    check: bool = True,
) -> str:
    environment = os.environ.copy()
    if extra_env:
        environment.update(extra_env)
    process = subprocess.run(
        args,
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=environment,
        check=False,
    )
    if check and process.returncode != 0:
        detail = process.stdout.strip().splitlines()
        suffix = f": {detail[-1]}" if detail else ""
        raise GateError(f"command failed ({' '.join(args)}){suffix}")
    return process.stdout.strip()


def validate_profile(repository: Path) -> dict[str, Any]:
    path = repository / PROFILE_RELATIVE
    profile = load_json(path)
    expected = {
        "schema_version": 1,
        "profile": "ios9-armv7-pjsip",
        "platform": "iphoneos",
        "minimum_os": "9.0",
        "architectures": ["armv7"],
        "sip_backend": "real_pjsip",
        "source_root": "ios-kiosk/src",
        "ui_source_policy": "shared_no_copy",
        "video_adapter": "public_videotoolbox",
        "device_families": [1, 2],
        "compact_layout_breakpoint": 500,
        "pjsip_version": "2.15.1",
        "signing_modes": ["stock", "jailbreak"],
    }
    for key, expected_value in expected.items():
        require(
            profile.get(key) == expected_value,
            f"{path}: {key} must be {expected_value!r}",
        )
    sdk = profile.get("sdk")
    require(isinstance(sdk, dict), f"{path}: sdk must be an object")
    require(sdk.get("canonical_prefix") == "iphoneos9.",
            f"{path}: SDK canonical prefix must be iphoneos9.")
    require(sdk.get("xcode_major") == 7,
            f"{path}: the commissioned toolchain must be Xcode 7")
    require(sdk.get("license_attestation_required") is True,
            f"{path}: SDK license attestation must be required")
    required_keys = {
        "platform", "minimum_os", "architectures", "sip_backend",
        "signing_mode", "sdk_settings_sha256",
    }
    require(set(profile.get("artifact_key_fields", [])) == required_keys,
            f"{path}: artifact key fields are incomplete")
    forbidden = set(profile.get("forbidden_formal_components", []))
    require(
        {"mini_sip", "sipctl_stub", "private_videotoolbox_dlopen"} <= forbidden,
        f"{path}: formal-component denylist is incomplete",
    )
    return profile


def validate_info(
    repository: Path,
    short_version: str | None = None,
    build_version: str | None = None,
) -> dict[str, Any]:
    path = repository / INFO_RELATIVE
    info = load_plist(path)
    expected = {
        "CFBundleIdentifier": "jp.ox.doorbell.compat.ios9",
        "MinimumOSVersion": "9.0",
        "UIDeviceFamily": [1, 2],
        "UIRequiredDeviceCapabilities": ["armv7"],
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
    }
    for key, value in expected.items():
        require(info.get(key) == value, f"{path}: {key} must be {value!r}")
    short = short_version or str(info.get("CFBundleShortVersionString", ""))
    build = build_version or str(info.get("CFBundleVersion", ""))
    require(SEMVER_RE.fullmatch(short) is not None,
            "CFBundleShortVersionString must be numeric major.minor.patch")
    require(BUILD_RE.fullmatch(build) is not None,
            "CFBundleVersion must be a positive integer")
    result = dict(info)
    result["CFBundleShortVersionString"] = short
    result["CFBundleVersion"] = build
    return result


def validate_source_contract(repository: Path) -> None:
    makefile = (repository / "ios-compat/make/ios9-armv7.mk").read_text(
        encoding="utf-8"
    )
    compatibility = (
        repository / "ios-kiosk/src/Core/DBCompatibilityProfile.h"
    ).read_text(encoding="utf-8")
    video = (repository / "ios-kiosk/src/Media/DBVtVideoView.m").read_text(
        encoding="utf-8"
    )
    router = (repository / "ios-kiosk/src/Screens/DBRouter.m").read_text(
        encoding="utf-8"
    )
    recovery = (repository / "ios-kiosk/src/Support/DBRecoveryClient.m").read_text(
        encoding="utf-8"
    )
    delegate = (repository / "ios-kiosk/src/Support/DBAppDelegate.m").read_text(
        encoding="utf-8"
    )
    require(not (repository / "ios-compat/src").exists(),
            "ios-compat/src would create a forbidden third UI source tree")
    require("$(ROOT)/ios-kiosk/src" in makefile,
            "the iOS 9 makefile must compile the shared ios-kiosk source tree")
    for token in (
        "DB_IOS_COMPAT_OS_FLOOR=90000",
        "DB_IOS_COMPAT_CORE_PJSIP=1",
        "DB_IOS_COMPAT_PUBLIC_VIDEOTOOLBOX=1",
        "DB_IOS_COMPAT_DEVICE_FAMILY_PHONE=1",
        "DB_IOS_COMPAT_DEVICE_FAMILY_IPAD=1",
    ):
        require(token in makefile, f"the iOS 9 makefile is missing {token}")
    require("! -path '*/Media/DBSipSession.m'" in makefile and
            "! -path '*/Media/DBSipListener.m'" in makefile,
            "the formal profile must exclude MiniSIP Objective-C adapters")
    require("$(MINISIP)/" not in makefile,
            "the formal profile must not compile MiniSIP sources")
    require("#import <VideoToolbox/VideoToolbox.h>" in video and
            "VTDecompressionSessionCreate(" in video,
            "the shared decoder must provide a direct public VideoToolbox adapter")
    require("#ifdef DB_IOS_COMPAT_PUBLIC_VIDEOTOOLBOX" in video,
            "public VideoToolbox must be selected at compile time")
    require("DBCompatibilityLayoutForWidth" in compatibility and
            "width < 500.0" in compatibility,
            "the compact-layout build guard is missing")
    require("minisip_forbidden_by_ios9_profile" in router and
            "coreSipCall" in router,
            "the formal profile must route calls through Core/PJSIP")
    paired = router[router.find("- (void)onPaired:"):]
    require("psk_ref" in paired and "psk_hex" not in paired,
            "the pairing sink must persist only psk_ref")
    require('stringWithFormat:@"MODE %@"' in recovery and
            'DBRecoveryControlCommand(@"STATUS")' in recovery,
            "the recovery client must use only the frozen MODE and STATUS protocol")
    require("nativeKioskHealthy" in recovery and
            'effectiveModeForConfiguredMode' in recovery,
            "the auto helper policy must measure native kiosk health")
    require('@"devices"' in delegate and '@"local"' in delegate and
            '@"recovery"' in delegate and '@"helper_mode"' in delegate,
            "the shell must resolve the canonical per-device recovery mode")


def validate_static(repository: Path) -> dict[str, Any]:
    profile = validate_profile(repository)
    info = validate_info(repository)
    validate_source_contract(repository)
    return {
        "profile": profile["profile"],
        "minimum_os": profile["minimum_os"],
        "architectures": profile["architectures"],
        "device_families": info["UIDeviceFamily"],
        "short_version": info["CFBundleShortVersionString"],
        "build_version": info["CFBundleVersion"],
    }


def xcrun(developer_dir: Path, *arguments: str) -> str:
    executable = Path("/usr/bin/xcrun")
    require(executable.is_file(), "/usr/bin/xcrun is required")
    return command(
        [str(executable), *arguments],
        extra_env={"DEVELOPER_DIR": str(developer_dir)},
    )


def selected_identity(identity: str) -> dict[str, str]:
    security = shutil.which("security")
    require(security is not None, "security is required for stock signing")
    listing = command([security, "find-identity", "-v", "-p", "codesigning"])
    candidates = re.findall(r'\)\s+([0-9A-F]{40})\s+"([^"]+)"', listing)
    matches = [item for item in candidates if identity in item]
    require(len(matches) == 1,
            "DB_IOS9_SIGNING_IDENTITY must select exactly one valid identity")
    return {"identity_sha1": matches[0][0], "identity_name": matches[0][1]}


def decode_profile(path: Path) -> dict[str, Any]:
    security = shutil.which("security")
    require(security is not None, "security is required for stock signing")
    raw = command([security, "cms", "-D", "-i", str(path)])
    try:
        profile = plistlib.loads(raw.encode("utf-8"))
    except plistlib.InvalidFileException as error:
        raise GateError(f"cannot decode provisioning profile {path}") from error
    require(isinstance(profile, dict), "provisioning profile is not a dictionary")
    return profile


def validate_stock_signing(info: dict[str, Any]) -> dict[str, Any]:
    require(shutil.which("codesign") is not None,
            "codesign is required for stock signing")
    identity_input = os.environ.get("DB_IOS9_SIGNING_IDENTITY", "")
    profile_value = os.environ.get("DB_IOS9_PROVISIONING_PROFILE", "")
    require(identity_input != "", "DB_IOS9_SIGNING_IDENTITY is required")
    require(profile_value != "", "DB_IOS9_PROVISIONING_PROFILE is required")
    profile_path = Path(profile_value).expanduser().resolve()
    require(profile_path.is_file(),
            f"provisioning profile not found: {profile_path}")
    identity = selected_identity(identity_input)
    profile = decode_profile(profile_path)
    expiration = profile.get("ExpirationDate")
    require(isinstance(expiration, dt.datetime),
            "provisioning profile has no expiration date")
    now = dt.datetime.now(expiration.tzinfo or dt.timezone.utc)
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    require(expiration > now, "provisioning profile has expired")
    entitlements = profile.get("Entitlements")
    require(isinstance(entitlements, dict),
            "provisioning profile has no entitlements")
    application_id = str(entitlements.get("application-identifier", ""))
    bundle_id = str(info["CFBundleIdentifier"])
    allowed_suffix = application_id.split(".", 1)[1] if "." in application_id else ""
    require(allowed_suffix == bundle_id or
            (allowed_suffix.endswith("*") and bundle_id.startswith(allowed_suffix[:-1])),
            "provisioning profile does not allow the compatibility bundle identifier")
    certificates = profile.get("DeveloperCertificates", [])
    certificate_fingerprints = {
        hashlib.sha1(bytes(value)).hexdigest().upper()
        for value in certificates
        if isinstance(value, bytes)
    }
    require(identity["identity_sha1"] in certificate_fingerprints,
            "selected signing identity is not included in the provisioning profile")
    uuid = str(profile.get("UUID", ""))
    require(uuid != "", "provisioning profile has no UUID")
    return {
        "mode": "stock",
        **identity,
        "profile_path": str(profile_path),
        "profile_sha256": sha256(profile_path),
        "profile_uuid": uuid,
        "profile_expiration": expiration.isoformat(),
    }


def validate_jailbreak_signing() -> dict[str, Any]:
    ldid = shutil.which("ldid")
    require(ldid is not None, "ldid is required for jailbreak fallback packaging")
    version = command([ldid, "-h"], check=False).splitlines()
    return {
        "mode": "jailbreak",
        "ldid": ldid,
        "ldid_version": version[0] if version else "ldid (version unavailable)",
    }


def parse_minimum_versions(load_commands: str) -> set[str]:
    versions: set[str] = set()
    active: str | None = None
    for raw in load_commands.splitlines():
        parts = raw.strip().split()
        if len(parts) >= 2 and parts[0] == "cmd":
            active = parts[1] if parts[1] in {
                "LC_VERSION_MIN_IPHONEOS", "LC_BUILD_VERSION"
            } else None
            continue
        if active == "LC_VERSION_MIN_IPHONEOS" and len(parts) >= 2 and \
                parts[0] == "version":
            versions.add(parts[1])
            active = None
        elif active == "LC_BUILD_VERSION" and len(parts) >= 2 and \
                parts[0] == "minos":
            versions.add(parts[1])
            active = None
    return versions


def validate_pjsip(
    repository: Path,
    profile: dict[str, Any],
    tools: dict[str, str],
) -> dict[str, Any]:
    root = (repository / PJSIP_RELATIVE).resolve()
    require(root.is_dir(),
            f"commissioned PJSIP artifact is missing: {root}")
    require((root / "include/pjsua-lib/pjsua.h").is_file(),
            "PJSIP UAC/UAS headers are missing")
    manifest_path = root / "artifact-manifest.json"
    manifest = load_json(manifest_path)
    expected = {
        "schema_version": 1,
        "artifact": "pjsip-static",
        "platform": "iphoneos",
        "architectures": ["armv7"],
        "minimum_os": "9.0",
        "sip_backend": "real_pjsip",
        "pjsip_version": profile["pjsip_version"],
        "signing_identity": "unsigned-static-library",
    }
    for key, value in expected.items():
        require(manifest.get(key) == value,
                f"{manifest_path}: {key} must be {value!r}")
    for key in ("pjsip_source_sha256", "archive_set_sha256"):
        require(SHA256_RE.fullmatch(str(manifest.get(key, ""))) is not None,
                f"{manifest_path}: {key} is missing or invalid")
    toolchain = manifest.get("toolchain")
    require(isinstance(toolchain, dict),
            f"{manifest_path}: toolchain evidence is missing")
    require(re.match(r"Xcode 7(?:\.|\s)", str(toolchain.get("xcode", ""))) is not None,
            "PJSIP must be produced by the commissioned Xcode 7 toolchain")
    require(str(toolchain.get("sdk_version", "")).startswith("9."),
            "PJSIP must be produced with an iPhoneOS 9.x SDK")

    libraries = sorted((root / "lib").glob("lib*.a"))
    require(libraries, "PJSIP artifact contains no static libraries")
    archive_digest = hashlib.sha256()
    symbols: list[str] = []
    for library in libraries:
        archive_digest.update(library.name.encode("utf-8"))
        archive_digest.update(b"\0")
        archive_digest.update(hashlib.sha256(library.read_bytes()).digest())
        architectures = command([tools["lipo"], "-archs", str(library)]).split()
        require(architectures == ["armv7"],
                f"{library} is not armv7-only: {architectures}")
        versions = parse_minimum_versions(
            command([tools["otool"], "-l", str(library)])
        )
        require(versions == {"9.0"},
                f"{library} records minimum OS {sorted(versions)}, expected 9.0")
        symbols.append(command([tools["nm"], "-g", str(library)]))
    require(archive_digest.hexdigest() == manifest["archive_set_sha256"],
            "PJSIP archive set does not match its manifest hash")
    symbol_text = "\n".join(symbols)
    for symbol in ("pjsua_create", "pjsua_call_make_call", "pjsua_call_answer"):
        require(re.search(rf"\b[TDSB]\s+_{re.escape(symbol)}$", symbol_text,
                          re.MULTILINE) is not None,
                f"real PJSIP artifact does not define {symbol}")
    require(re.search(r"\b_ms_(?:call|listen|poll|hangup)\b", symbol_text) is None,
            "PJSIP artifact unexpectedly contains MiniSIP symbols")
    return {
        "root": str(root),
        "manifest": str(manifest_path),
        "manifest_sha256": sha256(manifest_path),
        "archive_set_sha256": archive_digest.hexdigest(),
        "library_count": len(libraries),
    }


def tool_path(name: str) -> str:
    value = shutil.which(name)
    require(value is not None, f"{name} is required")
    return value


def validate_preflight(repository: Path, signing_mode: str) -> dict[str, Any]:
    static = validate_static(repository)
    profile = validate_profile(repository)
    info = validate_info(
        repository,
        os.environ.get("DB_IOS9_SHORT_VERSION"),
        os.environ.get("DB_IOS9_BUILD_VERSION"),
    )
    require(os.environ.get("DB_IOS9_SDK_LICENSE_ATTESTED") == "1",
            "set DB_IOS9_SDK_LICENSE_ATTESTED=1 only after verifying SDK licensing")
    developer_value = os.environ.get("DB_IOS9_DEVELOPER_DIR", "")
    require(developer_value != "", "DB_IOS9_DEVELOPER_DIR is required")
    developer_dir = Path(developer_value).expanduser().resolve()
    require(developer_dir.is_dir(),
            f"historical Xcode Developer directory not found: {developer_dir}")
    xcode_version = command(
        ["/usr/bin/xcodebuild", "-version"],
        extra_env={"DEVELOPER_DIR": str(developer_dir)},
    )
    require(re.search(r"^Xcode 7(?:\.|\s|$)", xcode_version, re.MULTILINE) is not None,
            f"formal armv7 signing requires Xcode 7, found: {xcode_version!r}")
    sdk_selected = Path(xcrun(
        developer_dir, "--sdk", "iphoneos", "--show-sdk-path"
    )).resolve()
    sdk_value = os.environ.get("DB_IOS9_SDK_ROOT", str(sdk_selected))
    sdk_root = Path(sdk_value).expanduser().resolve()
    require(sdk_root == sdk_selected,
            "DB_IOS9_SDK_ROOT must be the iPhoneOS SDK selected by commissioned Xcode")
    settings_path = sdk_root / "SDKSettings.plist"
    settings = load_plist(settings_path)
    canonical = str(settings.get("CanonicalName", "")).lower()
    version = str(settings.get("Version", ""))
    require(canonical.startswith(profile["sdk"]["canonical_prefix"]),
            f"selected SDK canonical name is not iPhoneOS 9.x: {canonical!r}")
    require(version.startswith("9."),
            f"selected SDK version is not 9.x: {version!r}")
    require(sdk_root.is_relative_to(developer_dir),
            "the SDK must reside inside the commissioned Xcode Developer directory")

    app_clang = xcrun(developer_dir, "--sdk", "iphoneos", "--find", "clang")
    tools = {
        name: xcrun(developer_dir, "--sdk", "iphoneos", "--find", name)
        for name in ("lipo", "otool", "nm", "libtool", "ar")
    }
    core_clang = os.environ.get("DB_IOS9_CORE_CLANG") or command(
        ["/usr/bin/xcrun", "--find", "clang"]
    )
    core_clangxx = os.environ.get("DB_IOS9_CORE_CLANGXX") or command(
        ["/usr/bin/xcrun", "--find", "clang++"]
    )
    for compiler in (core_clang, core_clangxx):
        require(Path(compiler).is_file(), f"Core compiler not found: {compiler}")
    command([core_clangxx, "-std=c++17", "-x", "c++", "-fsyntax-only", "-"],
            stdin="inline constexpr int db_ios9_cxx17 = 17;\n")
    resource_dir = Path(command([core_clang, "-print-resource-dir"]))
    clang_rt = resource_dir / "lib/darwin/libclang_rt.ios.a"
    require(clang_rt.is_file(), f"armv7 compiler runtime not found: {clang_rt}")
    require("armv7" in command([tools["lipo"], "-archs", str(clang_rt)]).split(),
            "Core compiler runtime has no armv7 slice")
    tools.update({
        "app_clang": app_clang,
        "core_clang": core_clang,
        "core_clangxx": core_clangxx,
        "clang_rt": str(clang_rt),
        "cmake": tool_path("cmake"),
        "make": tool_path("make"),
        "python3": tool_path("python3"),
    })
    pjsip = validate_pjsip(repository, profile, tools)
    signing = validate_stock_signing(info) if signing_mode == "stock" \
        else validate_jailbreak_signing()
    sdk_hash = sha256(settings_path)
    cache_key = (
        f"platform-iphoneos_osfloor-9.0_arch-armv7_sip-pjsip_"
        f"signing-{signing_mode}_sdk-{sdk_hash[:16]}"
    )
    return {
        **static,
        "profile": profile["profile"],
        "platform": "iphoneos",
        "minimum_os": "9.0",
        "architectures": ["armv7"],
        "sip_backend": "real_pjsip",
        "developer_dir": str(developer_dir),
        "sdk_root": str(sdk_root),
        "sdk_version": version,
        "sdk_canonical_name": settings.get("CanonicalName", ""),
        "sdk_settings_sha256": sdk_hash,
        "xcode": xcode_version.replace("\n", " "),
        "tools": tools,
        "pjsip": pjsip,
        "signing": signing,
        "cache_key": cache_key,
        "bundle_identifier": info["CFBundleIdentifier"],
        "short_version": info["CFBundleShortVersionString"],
        "build_version": info["CFBundleVersion"],
    }


def write_json(path: Path | None, value: dict[str, Any]) -> None:
    text = json.dumps(value, indent=2, sort_keys=True) + "\n"
    if path is None:
        sys.stdout.write(text)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path,
                        default=Path(__file__).resolve().parents[2])
    subparsers = parser.add_subparsers(dest="action", required=True)
    static_parser = subparsers.add_parser("static")
    static_parser.add_argument("--output", type=Path)
    preflight_parser = subparsers.add_parser("preflight")
    preflight_parser.add_argument("--signing", choices=("stock", "jailbreak"),
                                  required=True)
    preflight_parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repository = args.repository.resolve()
    try:
        if args.action == "static":
            result = validate_static(repository)
        else:
            result = validate_preflight(repository, args.signing)
        write_json(args.output, result)
    except GateError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
