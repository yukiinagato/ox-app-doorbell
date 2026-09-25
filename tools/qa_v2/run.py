#!/usr/bin/env python3
"""Run bounded regression lanes without converting missing evidence into PASS.

The default covers newly added regressions. --include-existing additionally runs
legacy Core, WebUI, and source/model checks. This runner does not certify native
APK/IPA/WPF releases; --release-gate intentionally remains blocked without them.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from typing import Any

ROOT = Path(__file__).resolve().parents[2]


CORE_IDS = {
    "qa_v2.clock.stable_ntp_advances_against_independent_authority",
    "qa_v2.clock.os_corrects_slow_clock_without_double_offset",
    "qa_v2.clock.os_corrects_fast_clock_without_double_offset",
    "qa_v2.clock.explicit_event_timestamp_is_not_corrected_twice",
    "qa_v2.clock.disabling_ntp_restores_raw_system_time",
}
SWIFT_IDS = {"qa_v2.swift." + name for name in (
    "exact_second_control", "before_boundary_control", "fractional_second_boundary",
    "fractional_multi_second_boundary", "minute_boundary", "midnight_boundary",
    "unstarted_core_control", "obsolete_generation_control")}
BROWSER_IDS = {
    "qa_v2.browser_component.real_jpeg_decodes_control",
    "qa_v2.browser_component.invalid_image_never_playing",
    "qa_v2.browser.no_frame_must_not_report_playing",
    "qa_v2.browser.real_mjpeg_decodes_moving_pixels_control",
    "qa_v2.browser.call_fallback_keeps_moving_after_single_jpeg",
    "qa_v2.browser.stop_releases_image_control",
}


def execute(name: str, command: list[str], out: Path, timeout: int,
            *, success_status: str = "PASS", test_failure: bool = True) -> dict[str, Any]:
    logfile = out / f"{name}.log"
    start = time.monotonic()
    result: dict[str, Any] = {"id": name, "command": command, "log": str(logfile)}
    try:
        with logfile.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(command, cwd=ROOT, stdout=log,
                stderr=subprocess.STDOUT, start_new_session=(os.name == "posix"))
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                # Kill descendants too; leaked compilers and fixture servers must
                # not contaminate the next lane or the user's machine.
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.wait()
                result.update(status="TIMEOUT", reason=f"Exceeded {timeout}s")
            else:
                result.update(exit_code=code, status=(success_status if code == 0 else
                                                     "FAIL" if test_failure else "ERROR"))
    except FileNotFoundError as error:
        result.update(status="BLOCKED", reason=str(error))
    except OSError as error:
        result.update(status="ERROR", reason=str(error))
    result["duration_s"] = round(time.monotonic() - start, 3)
    print(f"{name}: {result['status']}", flush=True)
    return result


def validate_core_report(path: Path, expected: set[str]) -> dict[str, Any]:
    try:
        root = ET.parse(path).getroot()
        cases = [case for case in root.iter("TestCase") if case.get("skipped") != "true"]
        names = [case.get("name", "") for case in cases]
        if len(names) != len(expected) or set(names) != expected:
            raise ValueError(f"Expected exact case IDs {sorted(expected)}, got {names}")
        observed = []
        for case in cases:
            assertions = case.find("OverallResultsAsserts")
            if assertions is None:
                raise ValueError(f"No assertion report: {case.get('name')}")
            passed = int(assertions.get("successes", "0"))
            failed = int(assertions.get("failures", "0"))
            if passed < 0 or failed < 0 or passed + failed == 0:
                raise ValueError(f"Empty or invalid assertions: {case.get('name')}")
            # A crash/exception may fail the case without an ordinary CHECK failure.
            status = "PASS" if assertions.get("test_case_success") == "true" and failed == 0 else "FAIL"
            observed.append({"id": case.get("name"), "status": status,
                             "assertions_passed": passed, "assertions_failed": failed})
        counts = root.find("OverallResultsTestCases")
        if counts is None:
            raise ValueError("Missing doctest summary")
        passed = int(counts.get("successes", "0"))
        failed = int(counts.get("failures", "0"))
        if passed != sum(row["status"] == "PASS" for row in observed) or failed != len(observed) - passed:
            raise ValueError("Doctest summary disagrees with per-case evidence")
        return {"id": "core-collection", "status": "PASS", "cases": observed,
                "passed": passed, "failed": failed,
                "skipped": int(counts.get("skipped", "0"))}
    except (OSError, ValueError, ET.ParseError) as error:
        return {"id": "core-collection", "status": "ERROR", "reason": str(error)}


def read_cases(path: Path, expected: set[str], lane: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
        rows = doc["results"]
        if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
            raise ValueError("Case results must be an array of objects")
        names = [row["id"] for row in rows]
        if len(names) != len(expected) or set(names) != expected:
            raise ValueError(f"Expected exact case IDs {sorted(expected)}, got {names}")
        if any(row.get("status") not in {"PASS", "FAIL", "BLOCKED", "ERROR", "TIMEOUT"} for row in rows):
            raise ValueError("Invalid case status")
        return {"id": lane + "-collection", "status": "PASS", "count": len(rows)}, rows
    except (OSError, ValueError, KeyError, TypeError) as error:
        return {"id": lane + "-collection", "status": "ERROR", "reason": str(error)}, []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "verification/qa-v2/latest")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build-qa-v2")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--include-existing", action="store_true")
    parser.add_argument("--release-gate", action="store_true")
    parser.add_argument("--browser", default="")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    args.out = args.out.resolve(); args.build_dir = args.build_dir.resolve()
    # A new evidence directory prevents stale JSON from an earlier green run.
    if args.out.exists() and any(args.out.iterdir()):
        parser.error("--out must be absent or empty; choose a new run directory")
    args.out.mkdir(parents=True, exist_ok=True)
    out = args.out
    lanes: list[dict[str, Any]] = []
    cases: list[dict[str, Any]] = []
    def run(name: str, command: list[str], timeout: int, **kwargs: Any) -> dict[str, Any]:
        value = execute(name, command, out, timeout, **kwargs)
        lanes.append(value)
        return value

    run("runner-self-tests", [sys.executable, str(ROOT / "tools/qa_v2/test_runner.py")], 30)
    run("playback-oracle-corrected", ["node", str(ROOT / "webui/tests/playback.test.js")], 45)
    configured = run("configure", ["cmake", "-S", str(ROOT / "core"), "-B", str(args.build_dir),
        "-DDB_WITH_PJSIP=OFF", "-DDB_REQUIRE_PJSIP=OFF", "-DDB_BUILD_TESTS=ON",
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo"], 180, test_failure=False)
    built = {"status": "BLOCKED"}
    if configured["status"] == "PASS":
        built = run("build", ["cmake", "--build", str(args.build_dir), "--parallel", str(args.jobs),
                               "--target", "doorbell_tests", "doorbell_qa_v2_fixture"],
                    900, test_failure=False)
    if built["status"] == "PASS":
        report = out / "core-new.xml"
        run("core-new", [str(args.build_dir / "doorbell_tests"), "--test-case=qa_v2.clock.*",
                         "--reporters=xml", f"--out={report}"], 90)
        collection = validate_core_report(report, CORE_IDS)
        cases += collection.pop("cases", [])
        lanes.append(collection)
    else:
        lanes.append({"id": "core-new", "status": "BLOCKED", "reason": "Core fixture did not build"})

    swift_exe = out / "clock-probe"
    swift_build = run("swift-build", ["swiftc", "-swift-version", "5",
        str(ROOT / "tools/qa_v2/clock_probe.swift"), str(ROOT / "ios/Doorbell/DoorbellClock.swift"),
        "-o", str(swift_exe)], 120, test_failure=False)
    if swift_build["status"] == "PASS":
        run("swift-new", [str(swift_exe)], 30)
        # The executable writes JSON to stdout, captured by execute.
        collection, rows = read_cases(out / "swift-new.log", SWIFT_IDS, "swift")
        lanes.append(collection); cases += rows
    else:
        lanes.append({"id": "swift-new", "status": "BLOCKED", "reason": "Swift probe did not build"})

    if built["status"] == "PASS":
        command = [sys.executable, str(ROOT / "tools/qa_v2/browser_probe.py"),
                   "--fixture", str(args.build_dir / "doorbell_qa_v2_fixture"),
                   "--out", str(out / "browser")]
        if args.browser:
            command += ["--browser", args.browser]
        lane = run("browser-new", command, 120)
        collection, rows = read_cases(out / "browser/results.json", BROWSER_IDS, "browser")
        lanes.append(collection); cases += rows
        if rows and any(row["status"] == "BLOCKED" for row in rows):
            lane["status"] = "BLOCKED"
            lane["reason"] = "See per-case results; successful components do not qualify blocked network tests"
    else:
        lanes.append({"id": "browser-new", "status": "BLOCKED", "reason": "Core fixture did not build"})

    if args.include_existing and built["status"] == "PASS":
        run("core-existing", [str(args.build_dir / "doorbell_tests"), "--test-case-exclude=qa_v2.*"], 900)
        web_files = sorted((ROOT / "webui/tests").glob("*.test.js"))
        if not web_files:
            lanes.append({"id": "web-existing", "status": "ERROR", "reason": "No tests collected"})
        for path in web_files:
            run("web-" + path.stem, ["node", str(path)], 45)
        run("model-traces-existing", [sys.executable, str(ROOT / "tools/conformance/run.py"),
                                      "--skip-source-contracts"], 60)
        run("source-contracts-existing", [sys.executable, str(ROOT / "tools/conformance/run.py")], 60)
    else:
        lanes.append({"id": "existing-suites", "status": "NOT_RUN", "reason": "Use --include-existing"})

    required_device_gates = ["real-sip-audio-loopback", "android-installed-lifecycle",
        "modern-ios-installed-ui", "ipad-mini1-ios9-armv7", "ios5-installed-kiosk", "windows-installed-ui"]
    native = [{"id": identifier, "status": "NOT_RUN", "reason": "No current installed-artifact evidence collected"}
              for identifier in required_device_gates]
    if args.release_gate:
        lanes.append({"id": "release", "status": "BLOCKED",
                      "reason": "This host runner cannot qualify required native/device/real-SIP gates"})
    hashes = {}
    for relative in ["core/src/util/clock.h", "core/src/node/node.cpp",
                     "ios/Doorbell/DoorbellClock.swift", "webui/panel/playback.js",
                     "core/tests/test_qa_v2_clock.cpp", "tools/qa_v2/clock_probe.swift",
                     "tools/qa_v2/browser_probe.py", "tools/qa_v2/run.py", "tools/qa_v2/test_runner.py"]:
        hashes[relative] = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
    report_doc = {"schema_version": 1, "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "host regression only; SIP stub; no native release certification",
        "inputs_sha256": hashes, "lanes": lanes, "cases": cases, "native_gates": native,
        "release_eligible": False}
    (out / "summary.json").write_text(json.dumps(report_doc, indent=2) + "\n", encoding="utf-8")
    bad = {"FAIL", "ERROR", "BLOCKED", "TIMEOUT"}
    failed = any(row["status"] in bad for row in lanes + cases)
    print(f"Evidence: {out / 'summary.json'}")
    print("Release eligibility: NOT ESTABLISHED")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
