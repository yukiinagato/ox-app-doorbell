#!/usr/bin/env python3
"""Bounded reference projection for versioned client event traces."""

from __future__ import annotations

from collections import OrderedDict
from copy import deepcopy
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Optional, Sequence


MAX_TRACE_EVENTS = 256
MAX_CALL_CACHE = 64
MAX_RESOLVED_CALLS = 64
MAX_SEEN_CHIMES = 128


class ConformanceError(ValueError):
    """Raised when a trace or declared contract is malformed."""


def _integer(value: Any, fallback: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        return fallback
    return value


def _string(value: Any) -> str:
    return value if isinstance(value, str) else ""


def declared_feature(manifest: Mapping[str, Any], feature: str) -> bool:
    """Return only explicitly declared boolean features; do not infer capabilities."""
    features = manifest.get("features")
    return isinstance(features, Mapping) and features.get(feature) is True


def fleet_declares(manifests: Sequence[Mapping[str, Any]], feature: str) -> bool:
    return bool(manifests) and all(declared_feature(manifest, feature) for manifest in manifests)


def effective_call_flow(configured: str, manifests: Sequence[Mapping[str, Any]]) -> str:
    if configured != "ring_then_purpose":
        return "purpose_first"
    return "ring_then_purpose" if fleet_declares(manifests, "call_flow_v2") else "purpose_first"


@dataclass(frozen=True)
class ClientProfile:
    platform: str
    device_id: str
    role: str
    features: Mapping[str, Any]
    channels: frozenset[str]
    web_groups: frozenset[str]

    @classmethod
    def from_json(cls, value: Mapping[str, Any]) -> "ClientProfile":
        platform = _string(value.get("platform"))
        device_id = _string(value.get("device_id"))
        role = _string(value.get("role"))
        features = value.get("features")
        channels = value.get("channels")
        groups = value.get("web_groups", [])
        if not platform or not device_id or not role:
            raise ConformanceError("profile platform, device_id, and role are required")
        if not isinstance(features, Mapping):
            raise ConformanceError(f"{platform}: features must be an object")
        if not isinstance(channels, list) or not all(isinstance(item, str) for item in channels):
            raise ConformanceError(f"{platform}: channels must be a string array")
        if not isinstance(groups, list) or not all(isinstance(item, str) for item in groups):
            raise ConformanceError(f"{platform}: web_groups must be a string array")
        return cls(platform, device_id, role, deepcopy(features), frozenset(channels),
                   frozenset(groups))

    def manifest(self) -> Mapping[str, Any]:
        return {"features": self.features}


class ClientProjection:
    """Normalize UI-visible effects from one already-delivered client event stream."""

    def __init__(self, profile: ClientProfile, now_ms: int) -> None:
        self.profile = profile
        self.now_ms = now_ms
        self.cache: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
        self.resolved: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
        self.seen_chimes: "OrderedDict[str, None]" = OrderedDict()
        self.current: Optional[Dict[str, Any]] = None
        self.effects: List[Dict[str, Any]] = []
        self.rejections: List[Dict[str, Any]] = []
        self.state_transitions: List[Dict[str, Any]] = []
        self.emergency_active = False
        self.presentations: Dict[str, Dict[str, Any]] = {}

    @staticmethod
    def _bounded_put(target: MutableMapping[str, Any], key: str, value: Any, limit: int) -> None:
        if key in target:
            del target[key]
        target[key] = value
        while len(target) > limit:
            del target[next(iter(target))]

    def _reject(self, at: int, reason: str) -> None:
        self.rejections.append({"at": at, "reason": reason})

    def _effect(self, at: int, kind: str, **values: Any) -> None:
        effect = {"at": at, "kind": kind}
        effect.update(values)
        self.effects.append(effect)

    def _call_fields(self, event: Mapping[str, Any]) -> Optional[Dict[str, Any]]:
        call_id = _string(event.get("call_id"))
        if not call_id:
            return None
        return {
            "call_id": call_id,
            "door": _string(event.get("door")),
            "purpose": _string(event.get("purpose")),
            "stage_revision": max(0, _integer(event.get("stage_revision"))),
            "expires_at_ms": max(0, _integer(event.get("expires_at_ms"))),
        }

    def _cache_call(self, fields: Dict[str, Any]) -> bool:
        previous = self.cache.get(fields["call_id"])
        if previous and fields["stage_revision"] < previous["stage_revision"]:
            return False
        merged = dict(previous or {})
        for key, value in fields.items():
            if value != "" and value != 0 or key in ("call_id", "stage_revision"):
                merged[key] = value
        self._bounded_put(self.cache, fields["call_id"], merged, MAX_CALL_CACHE)
        if self.current and self.current["call_id"] == fields["call_id"]:
            self.current["stage_revision"] = max(self.current["stage_revision"],
                                                  fields["stage_revision"])
            if fields["purpose"]:
                self.current["purpose"] = fields["purpose"]
        return True

    def _minimum_revision(self, call_id: str) -> int:
        values = [0]
        if call_id in self.cache:
            values.append(self.cache[call_id]["stage_revision"])
        if call_id in self.resolved:
            values.append(self.resolved[call_id]["stage_revision"])
        if self.current and self.current["call_id"] == call_id:
            values.append(self.current["stage_revision"])
        return max(values)

    def _targeted(self, event: Mapping[str, Any]) -> bool:
        delivered_to = event.get("delivered_to")
        if delivered_to is not None and delivered_to != self.profile.device_id:
            return False
        targets = event.get("targets")
        if targets is None:
            return True
        if not isinstance(targets, Mapping):
            return False
        devices = targets.get("devices")
        roles = targets.get("roles")
        groups = targets.get("web_subscription_groups")
        selectors = 0
        matched = False
        if devices is not None:
            selectors += 1
            if devices == "all" or isinstance(devices, list) and self.profile.device_id in devices:
                matched = True
        if roles is not None:
            selectors += 1
            if roles == "all" or isinstance(roles, list) and self.profile.role in roles:
                matched = True
        if groups is not None:
            selectors += 1
            if groups == "all" or isinstance(groups, list) and self.profile.web_groups.intersection(groups):
                matched = True
        return selectors > 0 and matched

    def _lifecycle(self, at: int, event: Mapping[str, Any]) -> None:
        event_type = _string(event.get("type"))
        recognized = ("press", "purpose_selected", "call_cancelled", "call_answered",
                      "call_ended", "emergency", "emergency_cancel")
        if event_type not in recognized:
            return
        if _integer(event.get("schema_version")) != 2:
            self._reject(at, "schema_version")
            return
        if event_type in ("emergency", "emergency_cancel"):
            self.emergency_active = event_type == "emergency"
            self.state_transitions.append({"at": at, "active": self.emergency_active})
            return
        fields = self._call_fields(event)
        if fields is None:
            self._reject(at, "call_id")
            return
        call_id = fields["call_id"]
        revision = fields["stage_revision"]
        if revision < self._minimum_revision(call_id):
            self._reject(at, "stale_revision")
            return
        if event_type in ("press", "purpose_selected"):
            self._cache_call(fields)
            return
        previous = self.resolved.get(call_id)
        resolution = event_type.removeprefix("call_")
        if previous and previous["state"] == resolution and revision <= previous["stage_revision"]:
            return
        self._bounded_put(self.resolved, call_id,
                          {"state": resolution, "stage_revision": revision}, MAX_RESOLVED_CALLS)
        matches = bool(self.current and self.current["call_id"] == call_id)
        if not matches:
            return
        if self.current and self.current["ringing"]:
            self._effect(at, "ring_stop", call_id=call_id)
            self.current["ringing"] = False
        if event_type == "call_answered" and _string(event.get("device")) == self.profile.device_id:
            self.current["state"] = "in_call"
            self._effect(at, "call_established", call_id=call_id)
            return
        self._effect(at, "incoming_close", call_id=call_id, reason=resolution)
        self.current = None

    def _chime(self, at: int, event: Mapping[str, Any]) -> None:
        if _integer(event.get("schema_version")) != 2:
            self._reject(at, "schema_version")
            return
        if not declared_feature(self.profile.manifest(), "call_flow_v2"):
            self._reject(at, "feature_manifest")
            return
        fields = self._call_fields(event)
        if fields is None:
            self._reject(at, "call_id")
            return
        if not self._targeted(event):
            self._reject(at, "target")
            return
        call_id = fields["call_id"]
        revision = fields["stage_revision"]
        cached = self.cache.get(call_id, {})
        for key in ("door", "purpose"):
            if not fields[key] and cached.get(key):
                fields[key] = cached[key]
        if not fields["expires_at_ms"] and cached.get("expires_at_ms"):
            fields["expires_at_ms"] = cached["expires_at_ms"]
        if not fields["door"]:
            self._reject(at, "door")
            return
        if not fields["expires_at_ms"]:
            self._reject(at, "expires_at_ms")
            return
        if fields["expires_at_ms"] and fields["expires_at_ms"] <= self.now_ms:
            self._reject(at, "expired")
            return
        if call_id in self.resolved:
            self._reject(at, "resolved_call")
            return
        if revision < self._minimum_revision(call_id):
            self._reject(at, "stale_revision")
            return
        seen_key = f"{call_id}:{revision}"
        if seen_key in self.seen_chimes:
            self._reject(at, "replay")
            return
        self._bounded_put(self.seen_chimes, seen_key, None, MAX_SEEN_CHIMES)
        self._cache_call(fields)
        same_call = bool(self.current and self.current["call_id"] == call_id)
        if self.current and not same_call:
            old_id = self.current["call_id"]
            if self.current["ringing"]:
                self._effect(at, "ring_stop", call_id=old_id)
            self._effect(at, "incoming_close", call_id=old_id, reason="superseded")
            self.current = None
        if same_call:
            assert self.current is not None
            self.current.update({"stage_revision": revision, "purpose": fields["purpose"],
                                 "ringing": True, "state": "ringing"})
            self._effect(at, "incoming_refresh", call_id=call_id, stage_revision=revision)
            self._effect(at, "ring_refresh", call_id=call_id, stage_revision=revision)
            return
        self.current = {
            "call_id": call_id,
            "stage_revision": revision,
            "purpose": fields["purpose"],
            "ringing": True,
            "state": "ringing",
        }
        self._effect(at, "incoming_open", call_id=call_id, stage_revision=revision)
        self._effect(at, "ring_start", call_id=call_id, stage_revision=revision)

    def _emergency(self, at: int, event: Mapping[str, Any]) -> None:
        if _integer(event.get("schema_version")) != 2:
            self._reject(at, "schema_version")
            return
        if not declared_feature(self.profile.manifest(), "device_alert_v1"):
            self._reject(at, "feature_manifest")
            return
        if not self._targeted(event):
            self._reject(at, "target")
            return
        channels = event.get("channels")
        if not isinstance(channels, list) or not all(isinstance(item, str) for item in channels):
            self._reject(at, "channels")
            return
        active = event.get("active") is True
        trigger = event.get("trigger")
        if trigger is not None and trigger != ("emergency_on" if active else "emergency_off"):
            self._reject(at, "trigger")
            return
        sticky = event.get("sticky") is True
        ttl_s = max(0, _integer(event.get("ttl_s")))
        for channel in channels:
            if channel not in self.profile.channels:
                continue
            if active:
                presentation = {"sticky": sticky, "ttl_s": ttl_s, "active": True}
                if not sticky and ttl_s > 0:
                    presentation["expires_at_ms"] = self.now_ms + ttl_s * 1000
                self.presentations[channel] = presentation
                self._effect(at, "alert_present", channel=channel, active=True,
                             sticky=sticky, ttl_s=ttl_s)
            else:
                self.presentations.pop(channel, None)
                self._effect(at, "alert_clear", channel=channel, active=False,
                             sticky=sticky, ttl_s=ttl_s)

    def _tick(self, at: int, event: Mapping[str, Any]) -> None:
        advance_ms = _integer(event.get("advance_ms"), -1)
        if advance_ms < 0:
            self._reject(at, "advance_ms")
            return
        self.now_ms += advance_ms
        for channel in sorted(list(self.presentations)):
            expiry = self.presentations[channel].get("expires_at_ms", 0)
            if expiry and expiry <= self.now_ms:
                del self.presentations[channel]
                self._effect(at, "alert_expire", channel=channel)

    def consume(self, at: int, event: Mapping[str, Any]) -> None:
        kind = _string(event.get("t"))
        if kind == "event":
            self._lifecycle(at, event)
        elif kind == "chime":
            self._chime(at, event)
        elif kind == "emergency":
            self._emergency(at, event)
        elif kind == "tick":
            self._tick(at, event)
        else:
            self._reject(at, "event_kind")

    def summary(self) -> Dict[str, Any]:
        return {
            "effects": deepcopy(self.effects),
            "rejections": deepcopy(self.rejections),
            "state_transitions": deepcopy(self.state_transitions),
            "emergency_active": self.emergency_active,
            "current_call": deepcopy(self.current),
            "presentations": deepcopy(self.presentations),
        }


def validate_flow_trace(case: Mapping[str, Any]) -> None:
    flow = case.get("flow")
    if flow is None:
        return
    events = case.get("events")
    if not isinstance(events, list):
        raise ConformanceError("trace events must be an array")
    presses = [(index, event) for index, event in enumerate(events)
               if isinstance(event, Mapping) and event.get("t") == "event" and
               event.get("type") == "press"]
    if len(presses) != 1:
        raise ConformanceError(f"{case.get('name')}: flow trace requires exactly one press")
    press_index, press = presses[0]
    if flow == "purpose_first":
        if not _string(press.get("purpose")):
            raise ConformanceError(f"{case.get('name')}: purpose_first press needs a purpose")
    elif flow == "ring_then_purpose":
        if _string(press.get("purpose")):
            raise ConformanceError(f"{case.get('name')}: ring_then_purpose rings before purpose")
        chime_indexes = [index for index, event in enumerate(events)
                         if isinstance(event, Mapping) and event.get("t") == "chime"]
        purpose_events = [(index, event) for index, event in enumerate(events)
                          if isinstance(event, Mapping) and event.get("t") == "event" and
                          event.get("type") == "purpose_selected"]
        if not chime_indexes or not purpose_events or not chime_indexes[0] < purpose_events[0][0]:
            raise ConformanceError(f"{case.get('name')}: purpose must follow the first chime")
        if _integer(purpose_events[0][1].get("stage_revision")) <= _integer(
                press.get("stage_revision")):
            raise ConformanceError(f"{case.get('name')}: delayed purpose must advance revision")
    else:
        raise ConformanceError(f"{case.get('name')}: unsupported flow {flow}")
    if not any(isinstance(event, Mapping) and event.get("t") == "chime"
               for event in events[press_index + 1:]):
        raise ConformanceError(f"{case.get('name')}: flow trace has no targeted chime")


def run_trace(case: Mapping[str, Any], profile: ClientProfile) -> Dict[str, Any]:
    events = case.get("events")
    if not isinstance(events, list):
        raise ConformanceError("trace events must be an array")
    if len(events) > MAX_TRACE_EVENTS:
        raise ConformanceError(f"trace exceeds {MAX_TRACE_EVENTS} events")
    if not all(isinstance(event, Mapping) for event in events):
        raise ConformanceError("every trace event must be an object")
    validate_flow_trace(case)
    projection = ClientProjection(profile, _integer(case.get("now_ms")))
    for index, event in enumerate(events):
        projection.consume(index, event)
    return projection.summary()


def assert_expected(actual: Mapping[str, Any], expected: Mapping[str, Any], path: str = "") -> None:
    for key, expected_value in expected.items():
        current_path = f"{path}.{key}" if path else key
        if key not in actual:
            raise ConformanceError(f"missing result field {current_path}")
        actual_value = actual[key]
        if isinstance(expected_value, Mapping):
            if not isinstance(actual_value, Mapping):
                raise ConformanceError(f"{current_path}: expected an object")
            assert_expected(actual_value, expected_value, current_path)
        elif actual_value != expected_value:
            raise ConformanceError(
                f"{current_path}: expected {expected_value!r}, got {actual_value!r}")


def eligible_profiles(case: Mapping[str, Any], profiles: Iterable[ClientProfile]) -> List[ClientProfile]:
    required = case.get("requires_channels", [])
    selected = case.get("profiles")
    if not isinstance(required, list) or not all(isinstance(item, str) for item in required):
        raise ConformanceError("requires_channels must be a string array")
    if selected is not None and (not isinstance(selected, list) or
                                 not all(isinstance(item, str) for item in selected)):
        raise ConformanceError("profiles must be a string array")
    result = []
    for profile in profiles:
        if selected is not None and profile.platform not in selected:
            continue
        if not set(required).issubset(profile.channels):
            continue
        result.append(profile)
    if not result:
        raise ConformanceError(f"{case.get('name')}: no eligible platform profiles")
    return result
