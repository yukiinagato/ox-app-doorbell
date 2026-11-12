#!/usr/bin/env python3
"""Reference walker for the resolved visitor flow.

Core resolves the flow (``db_core_visitor_flow_json``); a shell only walks it. This module is
the model every shell-side walker must agree with: it keeps a stack of page ids, turns a tap
into the next page or into one of the two terminal Core calls, and handles Back, the idle
timeout, an unanswered call, a throttled or failed notify, a replaced document, and a reply
banner arriving over a page. ``fixtures/visitor-flow-v1.json`` holds the cases.

The walker never reads raw configuration and never invents text: it shows what the resolved
document carries.
"""

from __future__ import annotations

import json
import pathlib
from typing import Any, Dict, List, Mapping, Optional

try:
    from .event_trace import ConformanceError
except ImportError:  # Direct script execution keeps the tool usable without installation.
    from event_trace import ConformanceError


MAX_WALK_EVENTS = 64
MAX_STEPS = 34  # 32 written steps plus the two a repair may add.
KNOWN_KINDS = ("page", "call", "notify", "end")
SEMANTIC_IDS = ("call.primary", "purpose.button")
NO_ANSWER_NOTICE = "calling.no_answer"
PRESS_FAILED_NOTICE = "flow.call_failed"


def text_in(labels: Any, lang: str) -> Optional[str]:
    """The language, then Japanese, then whatever the document carries."""
    if not isinstance(labels, Mapping):
        return None
    for key in (lang, "ja"):
        value = labels.get(key)
        if isinstance(value, str) and value:
            return value
    for value in labels.values():
        if isinstance(value, str) and value:
            return value
    return None


class FlowWalker:
    """Navigation state of one door screen over one resolved document."""

    def __init__(self, flow: Mapping[str, Any], lang: str = "ja") -> None:
        self.lang = lang
        self.flow: Mapping[str, Any] = {}
        self.mode = "legacy"
        self.stack: List[str] = []
        self.active_step: Optional[str] = None
        self.notice: Optional[str] = None
        self.reply = False
        self._load(flow)
        self._home()

    # ---- document access ----
    def _load(self, flow: Mapping[str, Any]) -> None:
        if not isinstance(flow, Mapping):
            raise ConformanceError("a resolved flow must be an object")
        steps = flow.get("steps", {})
        if not isinstance(steps, Mapping) or len(steps) > MAX_STEPS:
            raise ConformanceError("resolved steps must be a bounded object")
        self.flow = flow

    def _enabled(self) -> bool:
        return self.flow.get("enabled") is True and self._kind(self.flow.get("start")) == "page"

    def _step(self, step_id: Any) -> Mapping[str, Any]:
        steps = self.flow.get("steps")
        step = steps.get(step_id) if isinstance(steps, Mapping) and isinstance(step_id, str) else None
        return step if isinstance(step, Mapping) else {}

    def _kind(self, step_id: Any) -> str:
        kind = self._step(step_id).get("kind")
        return kind if isinstance(kind, str) else ""

    def _home(self) -> None:
        self.active_step = None
        if self._enabled():
            self.mode = "page"
            self.stack = [self.flow["start"]]
        else:
            # No flow for this door: the shell shows its classic screen and this model is idle.
            self.mode = "legacy"
            self.stack = []

    # ---- what is on screen ----
    def snapshot(self) -> Dict[str, Any]:
        page: Optional[str] = None
        if self.mode == "page":
            page = self.stack[-1]
        elif self.mode == "end":
            page = self.active_step
        step = self._step(page)
        options = []
        if self.mode == "page":
            for option in step.get("options", []):
                options.append({
                    "id": option.get("id"),
                    "semantic_id": option.get("semantic_id"),
                    "label": text_in(option.get("label"), self.lang),
                })
        return {
            "mode": self.mode,
            "page": page,
            "title": text_in(step.get("title"), self.lang) if page else None,
            "options": options,
            "back": self.mode == "page" and len(self.stack) > 1,
            "done": self.mode == "end",
            "notice": self.notice,
            "reply": self.reply,
        }

    # ---- input ----
    def apply(self, event: Mapping[str, Any]) -> List[Dict[str, Any]]:
        """Applies one input and returns the Core calls it caused, in order."""
        if "reply" in event:
            # The reply banner is an overlay; it never moves the flow.
            self.reply = bool(event["reply"])
            return []
        if "lang" in event:
            self.lang = str(event["lang"])
            return []
        if "flow_changed" in event:
            self._replace(event["flow_changed"])
            return []
        if "tap" in event:
            return self._tap(event)
        if event.get("back"):
            if self.mode == "page" and len(self.stack) > 1:
                self.stack.pop()
                self.notice = None
            return []
        if event.get("idle_timeout"):
            if self.mode == "page":
                self.stack = self.stack[:1]
                self.notice = None
            return []
        if event.get("done") or event.get("end_timeout"):
            if self.mode == "end":
                self._home()
            return []
        if "call_ended" in event:
            self._call_ended(str(event["call_ended"]))
            return []
        raise ConformanceError(f"unknown walk event {dict(event)!r}")

    def _direct_call(self, purpose: str, event: Mapping[str, Any]) -> List[Dict[str, Any]]:
        if event.get("press_result") == "failed":
            self.notice = PRESS_FAILED_NOTICE
        else:
            self.mode = "calling"
        return [{"press": purpose}]

    def _tap(self, event: Mapping[str, Any]) -> List[Dict[str, Any]]:
        if self.mode != "page":
            return []
        chosen = None
        for option in self._step(self.stack[-1]).get("options", []):
            if option.get("id") == event["tap"]:
                chosen = option
        if chosen is None:
            return []
        self.notice = None
        target = chosen.get("to")
        kind = self._kind(target)
        if kind == "page":
            if target in self.stack:
                del self.stack[self.stack.index(target) + 1:]
            else:
                self.stack.append(target)
            return []
        if kind == "call":
            self.active_step = target
            return self._direct_call(self._purpose(target), event)
        if kind == "notify":
            calls: List[Dict[str, Any]] = [{"notify": target}]
            result = event.get("notify_result", {"ok": True})
            after = self._step(target).get("to")
            if result.get("ok") is not True or self._kind(after) != "end":
                # A message that could not be sent must not look delivered: ring instead.
                self.active_step = None
                return calls + self._direct_call(self._purpose(target), event)
            self.mode = "end"
            self.active_step = after
            return calls
        if kind == "end":
            self.mode = "end"
            self.active_step = target
            return []
        # Unknown kind or a target that is not in the document: a visitor can always ring.
        self.active_step = None
        return self._direct_call("", event)

    def _purpose(self, step_id: Any) -> str:
        purpose = self._step(step_id).get("purpose")
        return purpose if isinstance(purpose, str) else ""

    def _call_ended(self, reason: str) -> None:
        if self.mode != "calling":
            return
        unanswered = self._step(self.active_step).get("on_unanswered")
        self._home()
        if reason != "timeout" or self.mode != "page":
            return
        if self._kind(unanswered) == "page":
            if unanswered != self.stack[0]:
                self.stack.append(unanswered)
        else:
            self.notice = NO_ANSWER_NOTICE

    def _replace(self, flow: Mapping[str, Any]) -> None:
        previous_mode = self.mode
        previous_stack = list(self.stack)
        self._load(flow)
        if not self._enabled():
            if previous_mode != "calling":
                self._home()
            return
        if previous_mode == "calling":
            return
        if previous_mode == "end" and self._kind(self.active_step) == "end":
            return
        keep = (previous_mode == "page" and previous_stack[:1] == [self.flow["start"]] and
                all(self._kind(step_id) == "page" for step_id in previous_stack))
        self._home()
        if keep:
            self.stack = previous_stack


def check_resolved_document(name: str, flow: Mapping[str, Any]) -> None:
    """Structural promises every resolved document makes to a shell."""
    if flow.get("schema_version") != 1 or not isinstance(flow.get("enabled"), bool):
        raise ConformanceError(f"{name}: schema_version and enabled are required")
    if not flow["enabled"]:
        if flow.get("reason") not in ("disabled", "legacy_call_flow", "unsupported_shell"):
            raise ConformanceError(f"{name}: a disabled document needs a known reason")
        return
    steps = flow.get("steps")
    if not isinstance(steps, Mapping) or len(steps) > MAX_STEPS:
        raise ConformanceError(f"{name}: steps must be a bounded object")
    start = steps.get(flow.get("start"))
    if not isinstance(start, Mapping) or start.get("kind") != "page":
        raise ConformanceError(f"{name}: start must name a page")
    for step_id, step in steps.items():
        kind = step.get("kind") if isinstance(step, Mapping) else None
        if kind not in KNOWN_KINDS:
            raise ConformanceError(f"{name}: {step_id} has no known kind")
        if kind == "page":
            options = step.get("options")
            if not isinstance(options, list) or not options:
                raise ConformanceError(f"{name}: page {step_id} has nothing to press")
            if sum(1 for option in options if option.get("style") == "primary") > 1:
                raise ConformanceError(f"{name}: page {step_id} has two primary options")
            for option in options:
                # The closed option shape is the invariant that no option can open settings,
                # Admin, a URL or free-text input.
                extra = set(option) - {"id", "semantic_id", "label", "icon", "style", "to",
                                       "purpose"}
                if extra:
                    raise ConformanceError(f"{name}: option carries {sorted(extra)}")
                if option.get("semantic_id") not in SEMANTIC_IDS:
                    raise ConformanceError(f"{name}: {step_id} option has no semantic id")
                expected = "call.primary" if option.get("style") == "primary" else "purpose.button"
                if option["semantic_id"] != expected:
                    raise ConformanceError(f"{name}: {step_id} semantic id disagrees with style")
                if option.get("to") not in steps:
                    raise ConformanceError(f"{name}: {step_id} option leads nowhere")
        if kind == "notify":
            target = steps.get(step.get("to"))
            if not isinstance(target, Mapping) or target.get("kind") != "end":
                raise ConformanceError(f"{name}: notify {step_id} must lead to an end step")
            if "message" in step or "snapshot" in step:
                raise ConformanceError(f"{name}: notify {step_id} leaks resident-facing data")
        if kind == "call" and "on_unanswered" in step:
            target = steps.get(step["on_unanswered"])
            if not isinstance(target, Mapping) or target.get("kind") != "page":
                raise ConformanceError(f"{name}: call {step_id} has a bad unanswered branch")


def load_suite(path: pathlib.Path) -> Mapping[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        suite = json.load(handle)
    if not isinstance(suite, Mapping) or suite.get("schema_version") != 1:
        raise ConformanceError("unsupported visitor-flow fixture schema")
    if not isinstance(suite.get("resolve"), list) or not isinstance(suite.get("walk"), list):
        raise ConformanceError("resolve and walk must be arrays")
    return suite


def resolved_flows(suite: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    flows: Dict[str, Mapping[str, Any]] = {}
    for case in suite["resolve"]:
        name = case.get("name") if isinstance(case, Mapping) else None
        if not isinstance(name, str) or name in flows or not isinstance(case.get("expect"), Mapping):
            raise ConformanceError("each resolve case needs a unique name and an expect object")
        if not isinstance(case.get("config"), Mapping) or not isinstance(case.get("door"), str):
            raise ConformanceError(f"{name}: config and door are required")
        check_resolved_document(name, case["expect"])
        flows[name] = case["expect"]
    return flows


def run_walk_case(case: Mapping[str, Any], flows: Mapping[str, Mapping[str, Any]],
                  walker_factory: Any = FlowWalker) -> int:
    """Replays one walk case against a walker and returns the number of checked steps."""
    name = case.get("name")
    if case.get("flow") not in flows:
        raise ConformanceError(f"{name}: unknown resolve case {case.get('flow')!r}")
    events = case.get("steps")
    if not isinstance(events, list) or not events or len(events) > MAX_WALK_EVENTS:
        raise ConformanceError(f"{name}: steps must be a bounded non-empty array")
    walker = walker_factory(flows[case["flow"]], case.get("lang", "ja"))
    if "start" in case and walker.snapshot() != case["start"]:
        raise ConformanceError(f"{name}: start: expected {case['start']!r}, got {walker.snapshot()!r}")
    for index, entry in enumerate(events):
        event = dict(entry["event"])
        if "flow_changed" in event:
            if event["flow_changed"] not in flows:
                raise ConformanceError(f"{name}[{index}]: unknown resolve case")
            event["flow_changed"] = flows[event["flow_changed"]]
        calls = walker.apply(event)
        if calls != entry.get("calls", []):
            raise ConformanceError(
                f"{name}[{index}]: expected calls {entry.get('calls', [])!r}, got {calls!r}")
        actual = walker.snapshot()
        if actual != entry["expect"]:
            raise ConformanceError(
                f"{name}[{index}]: expected {entry['expect']!r}, got {actual!r}")
    return len(events)


def run_visitor_flow_suite(path: pathlib.Path, walker_factory: Any = FlowWalker) -> int:
    suite = load_suite(path)
    flows = resolved_flows(suite)
    checks = len(flows)
    for case in suite["walk"]:
        if not isinstance(case, Mapping):
            raise ConformanceError("each walk case must be an object")
        checks += run_walk_case(case, flows, walker_factory)
    return checks
