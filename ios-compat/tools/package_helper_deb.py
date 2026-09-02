#!/usr/bin/env python3
"""Create a reproducible, opt-in iOS 5 keepalive-helper package."""

from __future__ import annotations

import argparse
import gzip
import io
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
        "Package: jp.ox.doorbell.keepalive\n"
        "Name: Doorbell Keepalive Helper (staged)\n"
        f"Version: {version}\n"
        "Architecture: iphoneos-arm\n"
        "Description: Opt-in fixed-purpose Doorbell supervisor for armv7/iOS 5.1; "
        "installation does not enable the root service\n"
        "Maintainer: ox\n"
        "Author: ox\n"
        "Section: Utilities\n"
        "Depends: firmware (>= 5.0)\n"
    ).encode()
    postinst = b"""#!/bin/sh
set -e
chown root:wheel /usr/local/libexec/doorbell-keepalive
chmod 0755 /usr/local/libexec/doorbell-keepalive
chown root:wheel /usr/local/share/doorbell/jp.ox.doorbell.keepalive.plist
chmod 0644 /usr/local/share/doorbell/jp.ox.doorbell.keepalive.plist
exit 0
"""
    prerm = b"""#!/bin/sh
set -e
if [ -e /Library/LaunchDaemons/jp.ox.doorbell.keepalive.plist ]; then
  echo "disable the Doorbell helper before removing its staged package" >&2
  exit 1
fi
exit 0
"""

    def build(archive: tarfile.TarFile) -> None:
        for name, content, mode in (
            ("./control", control, 0o644),
            ("./postinst", postinst, 0o755),
            ("./prerm", prerm, 0o755),
        ):
            archive.addfile(virtual_file(name, content, mode), io.BytesIO(content))

    return gzip_tar(build)


def data_archive(helper: Path, launchd_template: Path) -> bytes:
    binary = helper.read_bytes()
    template = launchd_template.read_bytes()

    def build(archive: tarfile.TarFile) -> None:
        for directory in (
            "./usr",
            "./usr/local",
            "./usr/local/libexec",
            "./usr/local/share",
            "./usr/local/share/doorbell",
        ):
            archive.addfile(virtual_dir(directory))
        archive.addfile(
            virtual_file("./usr/local/libexec/doorbell-keepalive", binary, 0o755),
            io.BytesIO(binary),
        )
        archive.addfile(
            virtual_file(
                "./usr/local/share/doorbell/jp.ox.doorbell.keepalive.plist",
                template,
                0o644,
            ),
            io.BytesIO(template),
        )

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


def make_package(helper: Path, launchd_template: Path, output: Path, version: str) -> None:
    members = (
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control_archive(version)),
        ("data.tar.gz", data_archive(helper, launchd_template)),
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
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--launchd-template", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    if not args.helper.is_file():
        parser.error(f"helper not found: {args.helper}")
    if not args.launchd_template.is_file():
        parser.error(f"launchd template not found: {args.launchd_template}")
    make_package(
        args.helper.resolve(),
        args.launchd_template.resolve(),
        args.output.resolve(),
        args.version,
    )
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
