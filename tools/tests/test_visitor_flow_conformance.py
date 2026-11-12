#!/usr/bin/env python3
"""Tests for the visitor-flow contract fixture and its reference walker."""

from __future__ import annotations

import copy
import json
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.conformance.event_trace import ConformanceError  # noqa: E402
from tools.conformance.run import FIXTURES  # noqa: E402
from tools.conformance.visitor_flow import (  # noqa: E402
    FlowWalker,
    check_resolved_document,
    load_suite,
    resolved_flows,
    run_visitor_flow_suite,
    run_walk_case,
    text_in,
)

FIXTURE = FIXTURES / "visitor-flow-v1.json"


def all_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from all_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from all_strings(item)


class VisitorFlowConformanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.suite = load_suite(FIXTURE)
        cls.flows = resolved_flows(cls.suite)
        cls.walks = {case["name"]: case for case in cls.suite["walk"]}

    def test_fixture_replays_against_the_reference_walker(self):
        self.assertEqual(run_visitor_flow_suite(FIXTURE), 89)

    def test_resolve_cases_cover_the_contract(self):
        self.assertLessEqual({
            "default-with-delivery", "default-without-delivery", "explicit-flow",
            "disabled-purpose", "dangling-target", "unknown-kind", "per-door-start",
            "missing-language", "missing-asset", "require-call-true", "require-call-false",
            "flow-disabled", "legacy-call-flow", "broken-start", "merge-cycle",
        }, set(self.flows))

    def test_walk_cases_cover_the_contract(self):
        events = set()
        for case in self.suite["walk"]:
            for step in case["steps"]:
                events.update(step["event"])
        self.assertLessEqual({"tap", "back", "idle_timeout", "done", "end_timeout", "call_ended",
                              "reply", "flow_changed", "lang"}, events)
        self.assertLessEqual({"unanswered-branch", "throttled-notify", "reply-over-page",
                              "failed-notify-rings", "back-and-idle"}, set(self.walks))

    def test_write_verdicts_separate_repairable_data_from_writable_data(self):
        verdicts = {case["name"]: case["write"] for case in self.suite["resolve"]}
        self.assertEqual(verdicts["explicit-flow"], "ok")
        self.assertEqual(verdicts["require-call-false"], "ok")
        self.assertEqual(verdicts["require-call-true"], "visitor_flow.no_reachable_call: start")
        self.assertEqual(verdicts["dangling-target"], "visitor_flow.unknown_target: s_home.o_visit")
        self.assertEqual(verdicts["unknown-kind"], "visitor_flow.unknown_kind: x_survey")
        self.assertEqual(verdicts["merge-cycle"], "visitor_flow.cycle: s_home")
        # A flow the validator refuses still resolves to something a visitor can use.
        for case in self.suite["resolve"]:
            if case["write"] != "ok":
                self.assertTrue(case["expect"]["enabled"], case["name"])

    def test_default_wizard_follows_the_delivery_purpose(self):
        with_delivery = self.flows["default-with-delivery"]
        self.assertEqual(with_delivery["source"], "default")
        home = {option["id"]: option for option in with_delivery["steps"]["s_home"]["options"]}
        self.assertEqual(home["o_call"]["semantic_id"], "call.primary")
        self.assertEqual(home["o_p_delivery"]["to"], "s_parcel")
        self.assertEqual(with_delivery["steps"]["c_p_delivery"]["on_unanswered"], "s_parcel")
        self.assertEqual(with_delivery["steps"]["n_left"]["to"], "e_thanks")
        self.assertEqual(with_delivery["steps"]["s_where"]["images"], [])
        without = self.flows["default-without-delivery"]
        self.assertNotIn("s_parcel", without["steps"])
        self.assertNotIn("o_p_delivery",
                         [option["id"] for option in without["steps"]["s_home"]["options"]])

    def test_resolved_documents_never_carry_resident_text_or_credentials(self):
        for name, flow in self.flows.items():
            text = json.dumps(flow, ensure_ascii=False)
            self.assertNotIn("secret:", text, name)
            self.assertNotIn("192.0.2.20", text, name)
            for step in flow.get("steps", {}).values():
                self.assertNotIn("message", step, name)
                self.assertNotIn("snapshot", step, name)

    def test_no_option_can_leave_the_flow(self):
        allowed = {"id", "semantic_id", "label", "icon", "style", "to", "purpose"}
        for name, flow in self.flows.items():
            for step in flow.get("steps", {}).values():
                for option in step.get("options", []):
                    self.assertLessEqual(set(option), allowed, name)
            for value in all_strings(flow.get("steps", {})):
                self.assertFalse(value.startswith(("http://", "https://", "doorbell://")), name)

    def test_every_language_is_filled_in(self):
        flow = self.flows["missing-language"]
        home = flow["steps"]["s_home"]
        self.assertEqual(set(home["title"]), {"ja", "en", "zh", "ko"})
        self.assertEqual(home["title"]["ko"], home["title"]["ja"])
        self.assertEqual(home["body"]["ja"], "English only body")
        labels = {option["id"]: option["label"] for option in home["options"]}
        self.assertEqual(labels["o_call"]["ja"], "Ring")
        self.assertEqual(labels["o_visit"]["zh"], "访客")
        # The option whose purpose does not exist is not offered at all.
        self.assertNotIn("o_blank", labels)

    def test_checker_rejects_documents_that_break_a_promise(self):
        good = self.flows["explicit-flow"]
        for mutate in (
            lambda flow: flow["steps"]["s_home"]["options"][0].update(to="s_gone"),
            lambda flow: flow["steps"]["s_home"]["options"][0].update(url="https://example.com"),
            lambda flow: flow["steps"]["s_home"]["options"][1].update(style="primary"),
            lambda flow: flow["steps"]["s_home"].update(options=[]),
            lambda flow: flow["steps"]["n_left"].update(message={"ja": "x"}),
            lambda flow: flow["steps"]["n_left"].update(to="s_home"),
            lambda flow: flow.update(start="c_any"),
            lambda flow: flow["steps"]["c_any"].update(kind="survey"),
        ):
            broken = copy.deepcopy(good)
            mutate(broken)
            with self.assertRaises(ConformanceError):
                check_resolved_document("broken", broken)

    def test_a_walker_that_strands_the_visitor_fails_the_fixture(self):
        class Stranding(FlowWalker):
            def _direct_call(self, purpose, event):
                return []

        with self.assertRaises(ConformanceError):
            run_walk_case(self.walks["unknown-kind-rings"], self.flows, Stranding)

    def test_a_walker_that_reveals_throttling_fails_the_fixture(self):
        class Revealing(FlowWalker):
            def _tap(self, event):
                calls = super()._tap(event)
                if event.get("notify_result", {}).get("throttled"):
                    self._home()
                return calls

        with self.assertRaises(ConformanceError):
            run_walk_case(self.walks["throttled-notify"], self.flows, Revealing)

    def test_unknown_targets_and_kinds_ring_directly(self):
        flow = copy.deepcopy(self.flows["explicit-flow"])
        flow["steps"]["s_home"]["options"][1]["to"] = "s_not_here"
        flow["steps"]["c_any"]["kind"] = "hologram"
        walker = FlowWalker(flow)
        self.assertEqual(walker.apply({"tap": "o_visit"}), [{"press": ""}])
        self.assertEqual(walker.snapshot()["mode"], "calling")
        walker.apply({"call_ended": "visitor"})
        self.assertEqual(walker.apply({"tap": "o_call"}), [{"press": ""}])

    def test_inputs_outside_their_mode_are_ignored(self):
        walker = FlowWalker(self.flows["explicit-flow"])
        self.assertEqual(walker.apply({"tap": "o_missing"}), [])
        walker.apply({"tap": "o_call"})
        before = walker.snapshot()
        for event in ({"tap": "o_visit"}, {"back": True}, {"idle_timeout": True}, {"done": True}):
            self.assertEqual(walker.apply(event), [])
        self.assertEqual(walker.snapshot(), before)
        with self.assertRaises(ConformanceError):
            walker.apply({"open_settings": True})

    def test_text_lookup_falls_back_to_japanese_then_any_text(self):
        self.assertEqual(text_in({"ja": "A", "en": "B"}, "en"), "B")
        self.assertEqual(text_in({"ja": "A", "en": ""}, "en"), "A")
        self.assertEqual(text_in({"zh": "C"}, "en"), "C")
        self.assertIsNone(text_in({}, "en"))
        self.assertIsNone(text_in(None, "en"))


if __name__ == "__main__":
    unittest.main()
