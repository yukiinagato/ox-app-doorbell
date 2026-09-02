#!/usr/bin/env python3
"""Create a reproducible, legacy-iOS-compatible Debian package."""

from __future__ import annotations

import argparse
import gzip
import io
import os
from pathlib import Path
import tarfile


def normalized(info: tarfile.TarInfo) -> tarfile.TarInfo:
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "wheel"
    info.mtime = 0
    return info


def virtual_file(name: str, content: bytes, mode: int) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = mode
    return normalized(info)


def virtual_dir(name: str, mode: int = 0o755) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = mode
    return normalized(info)


def gzip_tar(build) -> bytes:
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.GNU_FORMAT) as archive:
        build(archive)
    compressed = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=compressed, mtime=0) as stream:
        stream.write(tar_buffer.getvalue())
    return compressed.getvalue()


def control_archive(version: str) -> bytes:
    control = (
        "Package: jp.keihan.doorbell\n"
        "Name: Doorbell\n"
        f"Version: {version}\n"
        "Architecture: iphoneos-arm\n"
        "Description: Doorbell mesh intercom compatibility kiosk (armv7/iOS 5.1)\n"
        "Maintainer: keihan <support@keihan.co>\n"
        "Author: keihan\n"
        "Section: Utilities\n"
        "Depends: firmware (>= 5.0)\n"
    ).encode()
    postinst = b"""#!/bin/sh
set -e
chown -R root:wheel /Applications/Doorbell.app 2>/dev/null || true
chmod -R 0755 /Applications/Doorbell.app 2>/dev/null || true
if command -v uicache >/dev/null 2>&1; then
  uicache -p /Applications/Doorbell.app 2>/dev/null || uicache 2>/dev/null || true
fi
exit 0
"""
    prerm = b"#!/bin/sh\nexit 0\n"

    def build(archive: tarfile.TarFile) -> None:
        for name, content, mode in (
            ("./control", control, 0o644),
            ("./postinst", postinst, 0o755),
            ("./prerm", prerm, 0o755),
        ):
            archive.addfile(virtual_file(name, content, mode), io.BytesIO(content))

    return gzip_tar(build)


def data_archive(app: Path) -> bytes:
    def build(archive: tarfile.TarFile) -> None:
        archive.addfile(virtual_dir("./Applications"))
        archive.add(str(app), arcname="./Applications/Doorbell.app",
                    recursive=False, filter=normalized)
        entries: list[Path] = []
        for directory, dirnames, filenames in os.walk(app):
            dirnames[:] = sorted(name for name in dirnames if not name.startswith("._"))
            for dirname in dirnames:
                entries.append(Path(directory) / dirname)
            for filename in sorted(filenames):
                if filename == ".DS_Store" or filename.startswith("._"):
                    continue
                entries.append(Path(directory) / filename)
        for entry in entries:
            relative = entry.relative_to(app)
            archive.add(str(entry), arcname=f"./Applications/Doorbell.app/{relative}",
                        recursive=False, filter=normalized)

    return gzip_tar(build)


def ar_header(name: str, size: int) -> bytes:
    header = (
        name.ljust(16)
        + "0".ljust(12)
        + "0".ljust(6)
        + "0".ljust(6)
        + "100644".ljust(8)
        + str(size).ljust(10)
        + "`\n"
    ).encode()
    if len(header) != 60:
        raise ValueError("invalid ar header")
    return header


def make_package(app: Path, output: Path, version: str) -> None:
    members = (
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control_archive(version)),
        ("data.tar.gz", data_archive(app)),
    )
    result = bytearray(b"!<arch>\n")
    for name, content in members:
        result += ar_header(name, len(content))
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
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    if not args.app.is_dir():
        parser.error(f"app directory not found: {args.app}")
    make_package(args.app.resolve(), args.output.resolve(), args.version)
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
