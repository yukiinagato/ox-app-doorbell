#!/usr/bin/env python3
"""Mount the legacy Developer Disk Image on iOS 5.x devices (iPad1, iOS 5.1.1 / 9B206).

Why this exists
---------------
Both the modern `ideviceimagemounter` (libimobiledevice 1.4.x) and
`pymobiledevice3 mounter mount-developer` fail on iOS 5 ("Unknown error" /
ConnectionReset). The classic 1.2.x flow still works and is implemented here:

    usbmuxd(ListDevices) -> lockdown(QueryType, StartSession, TLS)
    -> StartService(com.apple.mobile.mobile_image_mounter)
    -> LookupImage -> MountImage{ImagePath, ImageSignature, ImageType}

The dmg itself is uploaded out-of-band via `pymobiledevice3 afc push` to
/PublicStaging/staging.dimage (see mount_ddi.sh).

Legacy-device pitfalls handled here:
  * pair record fields are PEM *text* (not DER)
  * iOS 5 TLS has no safe renegotiation -> ssl.OP_LEGACY_SERVER_CONNECT
  * lockdown StartSession+TLSv1.2 works fine after that
  * `LookupImage` reports ImagePresent=False even after a successful mount
    (false negative - verify by actually using screenshotr instead)

Usage:
    python3 mount_ddi.py <dmg> <signature>
"""
import base64
import os
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import plistlib

USBMUXD = "/var/run/usbmuxd"
LOCKDOWN_PORT = 62078
STAGING_PATH = "/private/var/mobile/Media/PublicStaging/staging.dimage"


def detect_udid() -> str:
    env = os.environ.get("LEGACY_UDID")
    if env:
        return env
    out = subprocess.run(["idevice_id", "-l"], capture_output=True, text=True).stdout
    udid = out.strip().splitlines()[0].strip()
    if not udid:
        raise RuntimeError("no device found (idevice_id -l); plug in the iPad via USB")
    return udid


UDID = detect_udid()
DMG = sys.argv[1]
SIG_FILE = sys.argv[2]

step = [0]
def log(msg):
    step[0] += 1
    print(f"[{step[0]:02d}] {msg}", flush=True)


def _usbmux_recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("usbmuxd connection closed")
        buf += chunk
    return buf


def usbmux_send(sock, msg):
    payload = plistlib.dumps(msg, fmt=plistlib.FMT_BINARY)
    hdr = struct.pack("<IIII", 16 + len(payload), 1, 8, 1)  # MESSAGE_PLIST=8
    sock.sendall(hdr + payload)


def usbmux_recv(sock):
    hdr = _usbmux_recv_exact(sock, 16)
    length, _v, _m, _t = struct.unpack("<IIII", hdr)
    payload = _usbmux_recv_exact(sock, length - 16) if length > 16 else b""
    return plistlib.loads(payload) if payload else {}


def find_device_id():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(USBMUXD)
    s.settimeout(5)
    usbmux_send(s, {"MessageType": "ListDevices"})
    m = usbmux_recv(s)
    s.close()
    for d in m.get("DeviceList", []):
        if d.get("Properties", {}).get("SerialNumber") == UDID:
            return d["DeviceID"]
    raise RuntimeError(f"device {UDID} not in usbmuxd list")


def usbmux_connect_port(port):
    dev_id = find_device_id()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(USBMUXD)
    usbmux_send(s, {"MessageType": "Connect", "DeviceID": dev_id,
                    "PortNumber": socket.htons(port) & 0xFFFF,
                    "ProgName": "ddi-mount"})
    r = usbmux_recv(s)
    if r.get("MessageType") != "Result" or r.get("Number") != 0:
        raise RuntimeError(f"usbmuxd Connect failed: {r}")
    return s


def read_pair_record():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(USBMUXD)
    usbmux_send(s, {"MessageType": "ReadPairRecord", "PairRecordID": UDID})
    m = usbmux_recv(s)
    s.close()
    data = m.get("PairRecordData")
    if not data:
        raise RuntimeError(f"no pair record: {m}")
    return plistlib.loads(bytes(data))


# ---------- lockdown plist protocol ----------

def recvall(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("device connection closed")
        buf += chunk
    return buf


def lockdown_send(sock, d):
    payload = plistlib.dumps(d, fmt=plistlib.FMT_BINARY)
    sock.sendall(struct.pack(">I", len(payload)) + payload)


def lockdown_recv(sock, timeout=90):
    sock.settimeout(timeout)
    n = struct.unpack(">I", recvall(sock, 4))[0]
    return plistlib.loads(recvall(sock, n))


def make_ssl_context(pair):
    """Pair-record fields are PEM *text* on macOS usbmuxd."""
    cert_text = bytes(pair["HostCertificate"]).decode()
    key_text = bytes(pair["HostPrivateKey"]).decode()
    tmp = tempfile.mkdtemp(prefix="ddi-")
    cert_path = os.path.join(tmp, "host.pem")
    key_path = os.path.join(tmp, "host.key")
    with open(cert_path, "w") as f:
        f.write(cert_text)
    with open(key_path, "w") as f:
        f.write(key_text)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_ciphers("ALL:!aNULL:!eNULL:@SECLEVEL=0")
    ctx.options |= getattr(ssl, "OP_LEGACY_SERVER_CONNECT", 0x4)
    ctx.load_cert_chain(cert_path, key_path)
    return ctx


def lockdown_client():
    pair = read_pair_record()
    log(f"pair record ok (HostID={pair.get('HostID')})")
    s = usbmux_connect_port(LOCKDOWN_PORT)
    lockdown_send(s, {"Label": "ddi-mount", "Request": "QueryType"})
    r = lockdown_recv(s, 15)
    log(f"QueryType -> {r.get('Type')}")
    lockdown_send(s, {"Label": "ddi-mount", "Request": "StartSession",
                      "HostID": pair["HostID"], "SystemBUID": pair["SystemBUID"]})
    r = lockdown_recv(s, 15)
    if r.get("Error"):
        raise RuntimeError(f"StartSession failed: {r}")
    log("StartSession ok")
    ts = make_ssl_context(pair).wrap_socket(s)
    log(f"TLS established ({ts.version()})")
    return ts


def start_service(ld, service):
    lockdown_send(ld, {"Label": "ddi-mount", "Request": "StartService", "Service": service})
    r = lockdown_recv(ld, 20)
    if r.get("Error"):
        raise RuntimeError(f"StartService({service}) failed: {r}")
    log(f"StartService({service}) -> port {r['Port']} ssl={bool(r.get('EnableServiceSSL'))}")
    s = usbmux_connect_port(int(r["Port"]))
    s.settimeout(60)
    return s


def mount_image(ld, sig_bytes):
    mim = start_service(ld, "com.apple.mobile.mobile_image_mounter")
    lockdown_send(mim, {"Command": "LookupImage", "ImageType": "Developer"})
    r = lockdown_recv(mim, 20)
    log(f"LookupImage -> ImagePresent={r.get('ImagePresent')} (false is NOT reliable)")
    lockdown_send(mim, {"Command": "MountImage",
                        "ImagePath": STAGING_PATH,
                        "ImageSignature": sig_bytes,
                        "ImageType": "Developer"})
    r = lockdown_recv(mim, 120)
    log(f"MountImage -> {r}")
    if r.get("Status") != "Complete":
        raise RuntimeError(f"mount failed: {r}")


if __name__ == "__main__":
    with open(SIG_FILE, "rb") as f:
        sig = f.read()
    log(f"udid={UDID} dmg={DMG}")
    ld = lockdown_client()
    mount_image(ld, sig)
    print("DONE")
