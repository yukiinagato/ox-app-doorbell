#!/usr/bin/env python3
"""Create deterministic stock and jailbreak iOS 9/armv7 packages."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
from pathlib import Path
import re
import stat
import tarfile
import time
import zipfile


TEXT_LIMIT = 2 * 1024 * 1024
FORBIDDEN_NAMES = {"boot.json", ".env", "id_rsa", "id_ed25519"}
FORBIDDEN_SUFFIXES = {".p12", ".pfx", ".pem", ".key"}
FORBIDDEN_TEXT = (
    re.compile(rb"psk_hex", re.IGNORECASE),
    re.compile(rb'"(?:password|passwd|passphrase|token)"\s*:', re.IGNORECASE),
    re.compile(rb"(?:rtsp|https?)://[^\s/@:]+:[^\s/@]+@", re.IGNORECASE),
    re.compile(rb"authorization\s*:\s*(?:basic|bearer)\s+", re.IGNORECASE),
    re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
)
VERSION_RE = re.compile(r"[0-9]+(?:\.[0-9]+){2}-[1-9][0-9]*\Z")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle_entries(app: Path) -> list[Path]:
    entries = sorted(app.rglob("*"), key=lambda item: item.relative_to(app).as_posix())
    for entry in entries:
        if entry.is_symlink():
            raise SystemExit(f"error: application bundle contains a symlink: {entry}")
    return entries


def scan_credentials(app: Path) -> None:
    for path in bundle_entries(app):
        if not path.is_file():
            continue
        lower_name = path.name.lower()
        if lower_name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
            raise SystemExit(f"error: credential-like file is forbidden in bundle: {path}")
        if path.name in {"Doorbell", "embedded.mobileprovision"} or \
                path.stat().st_size > TEXT_LIMIT:
            continue
        data = path.read_bytes()
        for pattern in FORBIDDEN_TEXT:
            if pattern.search(data):
                raise SystemExit(
                    f"error: credential-like content is forbidden in bundle: {path}"
                )


def zip_datetime(epoch: int) -> tuple[int, int, int, int, int, int]:
    value = time.gmtime(max(epoch, 315532800))
    return value.tm_year, value.tm_mon, value.tm_mday, value.tm_hour, value.tm_min, value.tm_sec


def stock_ipa(app: Path, output: Path, epoch: int) -> None:
    timestamp = zip_datetime(epoch)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as archive:
        for path in bundle_entries(app):
            if not path.is_file():
                continue
            relative = Path("Payload") / app.name / path.relative_to(app)
            info = zipfile.ZipInfo(relative.as_posix(), timestamp)
            info.create_system = 3
            mode = 0o755 if path.stat().st_mode & stat.S_IXUSR else 0o644
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED,
                             compresslevel=9)
    temporary.replace(output)


def normalized(info: tarfile.TarInfo, epoch: int) -> tarfile.TarInfo:
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "wheel"
    info.mtime = epoch
    return info


def virtual_file(name: str, content: bytes, mode: int, epoch: int) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = mode
    return normalized(info, epoch)


def virtual_dir(name: str, epoch: int, mode: int = 0o755) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = mode
    return normalized(info, epoch)


def gzip_tar(epoch: int, build) -> bytes:
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.GNU_FORMAT) as archive:
        build(archive)
    compressed = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=compressed, mtime=epoch) as stream:
        stream.write(tar_buffer.getvalue())
    return compressed.getvalue()


def control_archive(version: str, epoch: int) -> bytes:
    control = (
        "Package: jp.ox.doorbell.compat.ios9\n"
        "Name: Doorbell iOS 9 Compatibility\n"
        f"Version: {version}\n"
        "Architecture: iphoneos-arm\n"
        "Description: Doorbell compatibility shell (armv7/iOS 9.0, real PJSIP)\n"
        "Maintainer: ox\n"
        "Author: ox\n"
        "Section: Utilities\n"
        "Depends: firmware (>= 9.0)\n"
    ).encode("utf-8")
    postinst = b"""#!/bin/sh
set -e
chown -R root:wheel /Applications/Doorbell.app 2>/dev/null || true
chmod -R 0755 /Applications/Doorbell.app 2>/dev/null || true
if command -v uicache >/dev/null 2>&1; then
  uicache -p /Applications/Doorbell.app 2>/dev/null || uicache 2>/dev/null || true
fi
exit 0
"""

    def build(archive: tarfile.TarFile) -> None:
        for name, content, mode in (
            ("./control", control, 0o644),
            ("./postinst", postinst, 0o755),
        ):
            archive.addfile(virtual_file(name, content, mode, epoch), io.BytesIO(content))

    return gzip_tar(epoch, build)


def data_archive(app: Path, epoch: int) -> bytes:
    def build(archive: tarfile.TarFile) -> None:
        archive.addfile(virtual_dir("./Applications", epoch))
        archive.addfile(virtual_dir("./Applications/Doorbell.app", epoch))
        for path in bundle_entries(app):
            relative = path.relative_to(app).as_posix()
            arcname = f"./Applications/Doorbell.app/{relative}"
            if path.is_dir():
                archive.addfile(virtual_dir(arcname, epoch))
                continue
            info = archive.gettarinfo(str(path), arcname=arcname)
            info = normalized(info, epoch)
            with path.open("rb") as source:
                archive.addfile(info, source)

    return gzip_tar(epoch, build)


def ar_header(name: str, size: int, epoch: int) -> bytes:
    header = (
        name.ljust(16)
        + str(epoch).ljust(12)
        + "0".ljust(6)
        + "0".ljust(6)
        + "100644".ljust(8)
        + str(size).ljust(10)
        + "`\n"
    ).encode("ascii")
    if len(header) != 60:
        raise ValueError("invalid ar header")
    return header


def jailbreak_deb(app: Path, output: Path, version: str, epoch: int) -> None:
    if VERSION_RE.fullmatch(version) is None:
        raise SystemExit("error: DEB version must be numeric major.minor.patch-build")
    members = (
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control_archive(version, epoch)),
        ("data.tar.gz", data_archive(app, epoch)),
    )
    result = bytearray(b"!<arch>\n")
    for name, content in members:
        result += ar_header(name, len(content), epoch)
        result += content
        if len(content) % 2:
            result += b"\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_bytes(result)
    temporary.replace(output)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("stock", "jailbreak"), required=True)
    parser.add_argument("--version")
    parser.add_argument("--source-date-epoch", type=int,
                        default=int(os.environ.get("SOURCE_DATE_EPOCH", "0")))
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output.resolve()
    if not app.is_dir() or not (app / "Doorbell").is_file():
        parser.error("Doorbell.app is incomplete")
    scan_credentials(app)
    if args.mode == "stock":
        if output.suffix.lower() != ".ipa":
            parser.error("stock output must use .ipa")
        stock_ipa(app, output, args.source_date_epoch)
    else:
        if output.suffix.lower() != ".deb":
            parser.error("jailbreak output must use .deb")
        if not args.version:
            parser.error("--version is required for jailbreak packaging")
        jailbreak_deb(app, output, args.version, args.source_date_epoch)
    print(f"{output} sha256={sha256(output)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
