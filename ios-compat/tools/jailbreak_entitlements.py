#!/usr/bin/env python3
"""The entitlements an ldid-signed jailbreak build is given, and nothing else's.

A jailbreak build is installed into /Applications rather than a sandboxed container, and on that
path `tccd` refuses every privacy service to a binary whose signature does not claim it: the app
asks for the camera, no prompt is ever shown, TCC.db is not written, and `authorizationStatus`
answers `denied` a fraction of a second later. From the shell that is indistinguishable from a
resident who said no -- and since an indoor panel hides the tile of a door station whose
`caps.camera` is false, the door simply disappears from every panel in the house.

`com.apple.private.tcc.allow` is what tells tccd to allow the listed services without a prompt.
It is a private Apple entitlement: it is honoured only because the device is jailbroken, and a
binary carrying it is rejected outright by App Store and Ad Hoc signing. So it lives here, on the
jailbreak path alone, and never in the provisioning profile the stock lane signs against.
"""
from __future__ import annotations

import plistlib

# The services the door station actually uses. Nothing is claimed that the app does not ask the
# resident for through the ordinary AVCaptureDevice prompt on a stock build.
TCC_SERVICES = ["kTCCServiceCamera", "kTCCServiceMicrophone"]

TCC_KEY = "com.apple.private.tcc.allow"


def jailbreak_entitlements(bundle_identifier: str) -> dict:
    """The full entitlement set for an ldid-signed build of `bundle_identifier`."""
    if not bundle_identifier:
        raise ValueError("bundle_identifier is required")
    return {
        "application-identifier": bundle_identifier,
        # Installed outside a container, which is what puts it on the tccd path above.
        "com.apple.private.security.no-container": True,
        "get-task-allow": True,
        TCC_KEY: list(TCC_SERVICES),
    }


def write(bundle_identifier: str, path: str) -> None:
    with open(path, "wb") as handle:
        plistlib.dump(jailbreak_entitlements(bundle_identifier), handle, sort_keys=True)


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 3:
        raise SystemExit("usage: jailbreak_entitlements.py <bundle-identifier> <output.plist>")
    write(sys.argv[1], sys.argv[2])
