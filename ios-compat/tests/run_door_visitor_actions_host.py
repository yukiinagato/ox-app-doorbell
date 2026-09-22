#!/usr/bin/env python3
"""Run exact UIKit action selector bodies against host substitutes, not UIKit."""
import argparse
import hashlib
import json
import pathlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=pathlib.Path)
parser.add_argument("--out", type=pathlib.Path, required=True)
parser.add_argument("--sos", action="store_true")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[2]
source = args.source or root / ("ios-kiosk/src/Screens/DBWidgets.m" if args.sos else "ios-kiosk/src/Screens/DBDoorScreen.m")
raw = source.read_text()
selectors = ["- (void)onCall {", "- (void)onPurpose:", "- (BOOL)beginCallWithPurpose:",
             "- (void)alertView:", "- (void)onCancel {", "- (void)onEmergencyCancel {",
             "- (void)sosSliderDidFire:", "- (void)presentPurposeAlertForActiveCall:",
             "- (void)dismissPurposeAlert {", "- (void)handleEmergencyEvent:"]
if args.sos:
    selectors = ["- (BOOL)accessibilityActivate {", "- (void)onAccessibleButton {", "- (void)alertView:",
                 "- (void)finishArming {", "- (void)onCountdownTick:", "- (void)reset {"]
else:
    for selector in ["- (void)onCancelTouchDown {", "- (void)onCancelTouchCancel {"]:
        if selector in raw:
            selectors.append(selector)
    if "- (void)onCancelTouchDown {" in raw:
        for binding in ["action:@selector(onCancelTouchDown) forControlEvents:UIControlEventTouchDown",
                        "action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside",
                        "UIControlEventTouchUpOutside | UIControlEventTouchCancel"]:
            if binding not in raw:
                raise SystemExit("Missing production cancel gesture event binding: " + binding)
bodies = []
for selector in selectors:
    start = raw.index(selector, raw.index("@implementation DBSosSlider" if args.sos else "@implementation DBDoorScreen"))
    end = raw.index("\n}\n", start) + 3
    bodies.append(raw[start:end])
args.out.mkdir(parents=True, exist_ok=True)
template = root / ("ios-compat/tests/sos_accessibility_actions_host.m" if args.sos else "ios-compat/tests/door_visitor_actions_host.m")
compiled = args.out / "door_visitor_actions.m"
compiled.write_text(template.read_text().replace("// PRODUCTION_SELECTORS", "\n".join(bodies)))
binary = args.out / "door_visitor_actions"
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
command = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror", "-O2",
           "-isysroot", sdk, str(compiled), "-framework", "Foundation", "-o", str(binary)]
if args.sos:
    command += ["-I" + str(root / "ios-kiosk/src/Core"), str(root / "ios-kiosk/src/Core/DBSosSlideModel.m")]
subprocess.run(command, check=True)
result = subprocess.run([str(binary)])
(args.out / "provenance.json").write_text(json.dumps({
    "source": str(source), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
    "compiled_sha256": hashlib.sha256(compiled.read_bytes()).hexdigest(),
    "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "selectors": selectors, "compile_command": command, "exit_code": result.returncode,
    "scope": "Exact production Objective-C selector bodies with host substitutes; no UIKit event dispatch/device rendering qualification"
}, indent=2) + "\n")
raise SystemExit(result.returncode)
