#!/usr/bin/env python3
"""Run golden event traces and narrow source-contract probes."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any, Mapping

try:
    from .event_trace import (ClientProfile, ConformanceError, assert_expected,
                              effective_call_flow, eligible_profiles, fleet_declares, run_trace)
except ImportError:  # Direct script execution keeps the tool usable without installation.
    from event_trace import (ClientProfile, ConformanceError, assert_expected,
                             effective_call_flow, eligible_profiles, fleet_declares, run_trace)


ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"


def load_json(path: pathlib.Path) -> Mapping[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, Mapping):
        raise ConformanceError(f"{path}: root must be an object")
    return value


def run_golden_suite(path: pathlib.Path) -> int:
    suite = load_json(path)
    if suite.get("schema_version") != 1:
        raise ConformanceError("unsupported conformance fixture schema")
    raw_profiles = suite.get("platform_profiles")
    cases = suite.get("traces")
    gates = suite.get("feature_gates")
    if not isinstance(raw_profiles, list) or not isinstance(cases, list) or not isinstance(gates, list):
        raise ConformanceError("platform_profiles, traces, and feature_gates must be arrays")
    profiles = [ClientProfile.from_json(value) for value in raw_profiles]
    checks = 0
    for case in cases:
        if not isinstance(case, Mapping) or not isinstance(case.get("expect"), Mapping):
            raise ConformanceError("each trace needs an expect object")
        for profile in eligible_profiles(case, profiles):
            actual = run_trace(case, profile)
            try:
                assert_expected(actual, case["expect"])
            except ConformanceError as error:
                raise ConformanceError(f"{case.get('name')}[{profile.platform}]: {error}") from error
            checks += 1
    for gate in gates:
        if not isinstance(gate, Mapping):
            raise ConformanceError("feature gate must be an object")
        manifests = gate.get("manifests")
        if not isinstance(manifests, list) or not all(isinstance(item, Mapping) for item in manifests):
            raise ConformanceError(f"{gate.get('name')}: manifests must be an object array")
        if "configured_call_flow" in gate:
            actual: Any = effective_call_flow(_string(gate.get("configured_call_flow")), manifests)
        else:
            actual = fleet_declares(manifests, _string(gate.get("feature")))
        if actual != gate.get("expect"):
            raise ConformanceError(
                f"{gate.get('name')}: expected {gate.get('expect')!r}, got {actual!r}")
        checks += 1
    return checks


def _string(value: Any) -> str:
    return value if isinstance(value, str) else ""


def run_source_contracts(path: pathlib.Path) -> int:
    suite = load_json(path)
    if suite.get("schema_version") != 1 or not isinstance(suite.get("checks"), list):
        raise ConformanceError("invalid source-contract fixture")
    count = 0
    for check in suite["checks"]:
        if not isinstance(check, Mapping):
            raise ConformanceError("source check must be an object")
        relative = pathlib.PurePosixPath(_string(check.get("path")))
        if relative.is_absolute() or ".." in relative.parts:
            raise ConformanceError(f"{check.get('id')}: unsafe source path")
        source_path = ROOT.joinpath(*relative.parts)
        if not source_path.is_file():
            raise ConformanceError(f"{check.get('id')}: missing {relative}")
        if source_path.stat().st_size > 2 * 1024 * 1024:
            raise ConformanceError(f"{check.get('id')}: source probe exceeds 2 MiB")
        text = source_path.read_text(encoding="utf-8")
        literals = check.get("ordered_literals")
        if not isinstance(literals, list) or not literals or not all(
                isinstance(item, str) and item for item in literals):
            raise ConformanceError(f"{check.get('id')}: ordered_literals must be non-empty")
        offset = 0
        for literal in literals:
            found = text.find(literal, offset)
            if found < 0:
                raise ConformanceError(
                    f"{check.get('id')}: missing ordered source contract {literal!r}")
            offset = found + len(literal)
        count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=pathlib.Path,
                        default=FIXTURES / "event-traces-v2.json")
    parser.add_argument("--source-contracts", type=pathlib.Path,
                        default=FIXTURES / "platform-source-contracts.json")
    parser.add_argument("--skip-source-contracts", action="store_true")
    args = parser.parse_args()
    try:
        trace_checks = run_golden_suite(args.fixtures)
        source_checks = 0 if args.skip_source_contracts else run_source_contracts(
            args.source_contracts)
    except (ConformanceError, OSError, json.JSONDecodeError) as error:
        print(f"event conformance: FAIL: {error}", file=sys.stderr)
        return 1
    print(f"event conformance: ok ({trace_checks} platform traces, "
          f"{source_checks} source contracts)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
