#!/usr/bin/env python3
"""Mount the iOS 5.1 Developer Disk Image through the classic lockdown flow.

Modern image-mounter clients do not reliably complete this flow with iOS 5.
The image is uploaded separately to PublicStaging by mount_ddi.sh; this tool
performs usbmuxd pairing, lockdown TLS, StartService, and MountImage.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import socket
import ssl
import struct
import subprocess
import tempfile
from typing import BinaryIO


USBMUXD = "/var/run/usbmuxd"
LOCKDOWN_PORT = 62078
STAGING_PATH = "/private/var/mobile/Media/PublicStaging/staging.dimage"
STEP = 0


def log(message: str) -> None:
    global STEP
    STEP += 1
    print(f"[{STEP:02d}] {message}", flush=True)


def detect_udid() -> str:
    configured = os.environ.get("IOS_DEVICE_UDID") or os.environ.get("LEGACY_UDID")
    if configured:
        return configured
    result = subprocess.run(
        ["idevice_id", "-l"], capture_output=True, text=True, check=False
    )
    devices = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not devices:
        raise RuntimeError("no paired USB device found (idevice_id -l)")
    return devices[0]


def receive_exact(stream: BinaryIO | socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        chunk = stream.recv(length - len(result))  # type: ignore[attr-defined]
        if not chunk:
            raise ConnectionError("device connection closed")
        result.extend(chunk)
    return bytes(result)


def usbmux_send(stream: socket.socket, message: dict) -> None:
    payload = plistlib.dumps(message, fmt=plistlib.FMT_BINARY)
    stream.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload)


def usbmux_receive(stream: socket.socket) -> dict:
    header = receive_exact(stream, 16)
    length, _version, _message, _tag = struct.unpack("<IIII", header)
    payload = receive_exact(stream, length - 16) if length > 16 else b""
    return plistlib.loads(payload) if payload else {}


def usbmux_request(message: dict) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.connect(USBMUXD)
        stream.settimeout(5)
        usbmux_send(stream, message)
        return usbmux_receive(stream)


def find_device_id(udid: str) -> int:
    response = usbmux_request({"MessageType": "ListDevices"})
    for device in response.get("DeviceList", []):
        if device.get("Properties", {}).get("SerialNumber") == udid:
            return int(device["DeviceID"])
    raise RuntimeError(f"device {udid} is not present in usbmuxd")


def usbmux_connect_port(udid: str, port: int) -> socket.socket:
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stream.connect(USBMUXD)
    usbmux_send(
        stream,
        {
            "MessageType": "Connect",
            "DeviceID": find_device_id(udid),
            "PortNumber": socket.htons(port) & 0xFFFF,
            "ProgName": "doorbell-ddi-mount",
        },
    )
    response = usbmux_receive(stream)
    if response.get("MessageType") != "Result" or response.get("Number") != 0:
        stream.close()
        raise RuntimeError(f"usbmuxd Connect failed: {response}")
    return stream


def read_pair_record(udid: str) -> dict:
    response = usbmux_request(
        {"MessageType": "ReadPairRecord", "PairRecordID": udid}
    )
    data = response.get("PairRecordData")
    if not data:
        raise RuntimeError(f"pair record unavailable: {response}")
    return plistlib.loads(bytes(data))


def lockdown_send(stream: socket.socket, message: dict) -> None:
    payload = plistlib.dumps(message, fmt=plistlib.FMT_BINARY)
    stream.sendall(struct.pack(">I", len(payload)) + payload)


def lockdown_receive(stream: socket.socket, timeout: int = 90) -> dict:
    stream.settimeout(timeout)
    length = struct.unpack(">I", receive_exact(stream, 4))[0]
    return plistlib.loads(receive_exact(stream, length))


def pem_text(value: bytes | str) -> str:
    return value.decode() if isinstance(value, bytes) else value


def make_ssl_context(pair: dict) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_ciphers("ALL:!aNULL:!eNULL:@SECLEVEL=0")
    context.options |= getattr(ssl, "OP_LEGACY_SERVER_CONNECT", 0x4)
    with tempfile.TemporaryDirectory(prefix="doorbell-ddi-") as temporary:
        certificate = os.path.join(temporary, "host.pem")
        private_key = os.path.join(temporary, "host.key")
        with open(certificate, "w", encoding="utf-8") as stream:
            stream.write(pem_text(pair["HostCertificate"]))
        with open(private_key, "w", encoding="utf-8") as stream:
            stream.write(pem_text(pair["HostPrivateKey"]))
        context.load_cert_chain(certificate, private_key)
    return context


def lockdown_client(udid: str) -> ssl.SSLSocket:
    pair = read_pair_record(udid)
    log(f"pair record ok (HostID={pair.get('HostID')})")
    stream = usbmux_connect_port(udid, LOCKDOWN_PORT)
    lockdown_send(stream, {"Label": "doorbell-ddi", "Request": "QueryType"})
    response = lockdown_receive(stream, 15)
    log(f"QueryType -> {response.get('Type')}")
    lockdown_send(
        stream,
        {
            "Label": "doorbell-ddi",
            "Request": "StartSession",
            "HostID": pair["HostID"],
            "SystemBUID": pair["SystemBUID"],
        },
    )
    response = lockdown_receive(stream, 15)
    if response.get("Error"):
        raise RuntimeError(f"StartSession failed: {response}")
    secure = make_ssl_context(pair).wrap_socket(stream)
    log(f"lockdown TLS established ({secure.version()})")
    return secure


def start_service(udid: str, lockdown: ssl.SSLSocket, service: str) -> socket.socket:
    lockdown_send(
        lockdown,
        {"Label": "doorbell-ddi", "Request": "StartService", "Service": service},
    )
    response = lockdown_receive(lockdown, 20)
    if response.get("Error"):
        raise RuntimeError(f"StartService({service}) failed: {response}")
    log(
        f"StartService({service}) -> port {response['Port']} "
        f"ssl={bool(response.get('EnableServiceSSL'))}"
    )
    stream = usbmux_connect_port(udid, int(response["Port"]))
    stream.settimeout(60)
    return stream


def mount_image(udid: str, lockdown: ssl.SSLSocket, signature: bytes) -> None:
    with start_service(
        udid, lockdown, "com.apple.mobile.mobile_image_mounter"
    ) as mounter:
        lockdown_send(mounter, {"Command": "LookupImage", "ImageType": "Developer"})
        response = lockdown_receive(mounter, 20)
        log(
            "LookupImage -> "
            f"ImagePresent={response.get('ImagePresent')} (not reliable on iOS 5)"
        )
        lockdown_send(
            mounter,
            {
                "Command": "MountImage",
                "ImagePath": STAGING_PATH,
                "ImageSignature": signature,
                "ImageType": "Developer",
            },
        )
        response = lockdown_receive(mounter, 120)
        log(f"MountImage -> {response}")
        if response.get("Status") != "Complete":
            raise RuntimeError(f"mount failed: {response}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dmg")
    parser.add_argument("signature")
    args = parser.parse_args()
    udid = detect_udid()
    with open(args.signature, "rb") as stream:
        signature = stream.read()
    log(f"udid={udid} dmg={args.dmg}")
    with lockdown_client(udid) as lockdown:
        mount_image(udid, lockdown, signature)
    print("DONE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
