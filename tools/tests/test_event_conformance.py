#!/usr/bin/env python3
"""Tests for the bounded cross-platform event conformance runner."""

from __future__ import annotations

import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.conformance.event_trace import (  # noqa: E402
    MAX_CALL_CACHE,
    MAX_RESOLVED_CALLS,
    MAX_SEEN_CHIMES,
    MAX_TRACE_EVENTS,
    ClientProfile,
    ClientProjection,
    ConformanceError,
    declared_feature,
    effective_call_flow,
    fleet_declares,
    run_trace,
)
from tools.conformance.run import FIXTURES, run_golden_suite, run_source_contracts  # noqa: E402


def profile(features=None, channels=None):
    return ClientProfile.from_json({
        "platform": "test",
        "device_id": "panel-local",
        "role": "indoor_panel",
        "features": features if features is not None else {
            "call_flow_v2": True,
            "call_lifecycle_v2": True,
            "device_alert_v1": True,
        },
        "channels": channels if channels is not None else ["in_app", "system_notification"],
        "web_groups": ["guards"],
    })


class EventConformanceTests(unittest.TestCase):
    def test_golden_platform_traces_and_feature_gates(self):
        self.assertEqual(run_golden_suite(FIXTURES / "event-traces-v2.json"), 69)

    def test_platform_source_contracts(self):
        self.assertEqual(
            run_source_contracts(FIXTURES / "platform-source-contracts.json"), 16)

    def test_trace_length_is_bounded(self):
        case = {"events": [{"t": "tick", "advance_ms": 0}] * (MAX_TRACE_EVENTS + 1)}
        with self.assertRaisesRegex(ConformanceError, "exceeds"):
            run_trace(case, profile())

    def test_projection_maps_are_bounded(self):
        projection = ClientProjection(profile(), 1000)
        for index in range(MAX_CALL_CACHE + 10):
            projection.consume(index, {
                "schema_version": 2,
                "t": "event",
                "type": "press",
                "call_id": f"cached-{index}",
                "stage_revision": 0,
            })
        for index in range(MAX_RESOLVED_CALLS + 10):
            projection.consume(index, {
                "schema_version": 2,
                "t": "event",
                "type": "call_cancelled",
                "call_id": f"resolved-{index}",
                "stage_revision": 0,
            })
        for index in range(MAX_SEEN_CHIMES + 10):
            projection.consume(index, {
                "schema_version": 2,
                "t": "chime",
                "call_id": f"chime-{index}",
                "door": "front",
                "stage_revision": 0,
                "expires_at_ms": 10000,
                "delivered_to": "panel-local",
            })
        self.assertEqual(len(projection.cache), MAX_CALL_CACHE)
        self.assertEqual(len(projection.resolved), MAX_RESOLVED_CALLS)
        self.assertEqual(len(projection.seen_chimes), MAX_SEEN_CHIMES)

    def test_feature_gate_uses_only_nested_boolean_declarations(self):
        self.assertTrue(declared_feature({"features": {"call_flow_v2": True}},
                                         "call_flow_v2"))
        self.assertFalse(declared_feature({"call_flow_v2": True}, "call_flow_v2"))
        self.assertFalse(declared_feature({"features": {"call_flow_v2": "true"}},
                                          "call_flow_v2"))
        self.assertFalse(fleet_declares([], "call_flow_v2"))
        self.assertEqual(effective_call_flow("ring_then_purpose", [
            {"features": {"call_flow_v2": True}}, {"features": {}}
        ]), "purpose_first")

    def test_unselected_or_unsupported_alert_channels_have_no_effect(self):
        result = run_trace({"events": [{
            "schema_version": 2,
            "t": "emergency",
            "active": True,
            "trigger": "emergency_on",
            "targets": {"devices": ["panel-local"]},
            "channels": ["system_notification"],
            "sticky": True,
            "ttl_s": 0,
        }]}, profile(channels=["in_app"]))
        self.assertEqual(result["effects"], [])
        self.assertEqual(result["presentations"], {})

    def test_undeclared_feature_rejects_new_client_event(self):
        result = run_trace({"events": [{
            "schema_version": 2,
            "t": "chime",
            "call_id": "call",
            "door": "front",
            "stage_revision": 0,
            "expires_at_ms": 10000,
            "delivered_to": "panel-local",
        }]}, profile(features={"device_alert_v1": True}))
        self.assertEqual(result["effects"], [])
        self.assertEqual(result["rejections"], [{"at": 0, "reason": "feature_manifest"}])

    def test_listen_only_client_can_ring_without_call_lifecycle_reporting(self):
        result = run_trace({"events": [{
            "schema_version": 2,
            "t": "chime",
            "call_id": "call",
            "door": "front",
            "stage_revision": 0,
            "expires_at_ms": 10000,
            "delivered_to": "panel-local",
        }]}, profile(features={
            "call_flow_v2": True,
            "call_lifecycle_v2": False,
            "device_alert_v1": True,
        }))
        self.assertEqual([effect["kind"] for effect in result["effects"]],
                         ["incoming_open", "ring_start"])
        self.assertEqual(result["rejections"], [])


if __name__ == "__main__":
    unittest.main()
