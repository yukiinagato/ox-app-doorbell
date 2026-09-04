#!/usr/bin/env python3
"""Host contracts for the modern Apple VideoToolbox and root-helper boundaries."""

from __future__ import annotations

import json
from pathlib import Path
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class RetiredSessionModel:
    """Models a VT invalidate that synchronously waits for its output callback."""

    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.retired = True

    def callback(self) -> None:
        with self.lock:
            pass

    def invalidate(self) -> None:
        worker = threading.Thread(target=self.callback)
        worker.start()
        worker.join(timeout=0.5)
        if worker.is_alive():
            raise TimeoutError("callback waited for lifecycle lock")

    def stop(self) -> None:
        with self.lock:
            retired = self.retired
            self.retired = False
        if retired:
            self.invalidate()


class ResolutionTransitionModel:
    """Models the unlock/invalidate/relock loop used for VT size changes."""

    def __init__(self, initial_size: tuple[int, int]) -> None:
        self.lock = threading.RLock()
        self.session_size: tuple[int, int] | None = initial_size
        self.generation = 1
        self.invalidated: list[tuple[int, int]] = []

    def feed(self, requested: tuple[int, int], after_invalidate=None) -> tuple[int, int]:
        while True:
            with self.lock:
                if self.session_size == requested:
                    return self.session_size
                retired = self.session_size
                self.session_size = None
                self.generation += 1
                transition = self.generation

            if retired is not None:
                self.invalidated.append(retired)
            if after_invalidate is not None:
                callback, after_invalidate = after_invalidate, None
                callback()

            with self.lock:
                if self.generation != transition or self.session_size is not None:
                    continue
                self.session_size = requested
                return requested


class SentinelModel:
    """Pure foreground/grace/timeout state machine used to keep fatal testing off-host."""

    def __init__(self, grace: float = 8, timeout: float = 15) -> None:
        self.grace = grace
        self.timeout = timeout
        self.armed = False
        self.tripped = False
        self.grace_until = 0.0
        self.next_probe = 0.0
        self.pending = False
        self.deadline = 0.0
        self.failures = 0

    def foreground(self, now: float) -> None:
        self.armed, self.tripped = True, False
        self.grace_until = now + self.grace
        self.next_probe = self.grace_until
        self.pending = False
        self.failures = 0

    def background(self) -> None:
        self.armed, self.tripped = False, False

    def check(self, now: float) -> bool:
        if not self.armed or self.tripped or now < self.grace_until or now < self.next_probe:
            return False
        if self.pending and now >= self.deadline:
            self.pending = False
            self.failures += 1
            if self.failures >= 3:
                self.tripped = True
                return True
        self.pending = True
        self.deadline = now + self.timeout
        self.next_probe = now + self.timeout
        return False


class ModernKeepaliveContracts(unittest.TestCase):
    def test_retired_vt_session_is_invalidated_after_lifecycle_unlock(self) -> None:
        encoder = source("ios/Doorbell/VideoEncoderVT.swift")
        invalidator = encoder[encoder.index("private func invalidateRetiredSession"):
                              encoder.index("func feed(pixelBuffer")]
        self.assertIn("VTCompressionSessionInvalidate(retired)", invalidator)
        self.assertNotIn("lock.", invalidator)
        self.assertIn("let retired = detachSessionLocked()", encoder)
        self.assertIn("lock.unlock()\n        invalidateRetiredSession(retired)", encoder)
        self.assertIn("sessionGeneration &+= 1", encoder)
        self.assertIn("while true", encoder)
        self.assertIn("sessionGeneration == transition, session == nil", encoder)

        model = RetiredSessionModel()
        stopped = threading.Thread(target=model.stop)
        stopped.start()
        stopped.join(timeout=0.5)
        self.assertFalse(stopped.is_alive(), "a draining callback must not deadlock stop")

    def test_resolution_transition_retries_after_an_interleaved_feed(self) -> None:
        model = ResolutionTransitionModel((640, 480))
        selected = model.feed((1280, 720), after_invalidate=lambda: model.feed((320, 240)))
        self.assertEqual(selected, (1280, 720))
        self.assertEqual(model.session_size, (1280, 720))
        self.assertEqual(model.invalidated, [(640, 480), (320, 240)])

    def test_modern_keepalive_matches_the_strict_datagram_contract(self) -> None:
        schema = json.loads(source("ios-compat/helper/protocol-v1.schema.json"))
        required = set(schema["required"])
        self.assertTrue({"pid", "sequence", "policy"} <= required)
        self.assertFalse(schema["additionalProperties"])

        client = source("ios/Doorbell/KeepaliveClient.swift")
        for field in ("protocol", "event", "pid", "bundle_id", "app_version", "role",
                      "policy", "state", "sequence", "memory_warnings",
                      "unix_time"):
            self.assertIn(f'"{field}"', client)
        self.assertIn('withTimeInterval: KeepaliveClient.interval', client)
        self.assertIn('private static let interval: TimeInterval = 3', client)
        self.assertIn('send(event: "started")', client)
        self.assertIn('send(event: "stopping")', client)
        self.assertIn('send(event: "memory_pressure")', client)
        self.assertIn('self.control("MODE \\(requestedMode)")', client)
        self.assertIn('self.control("STATUS")', client)
        self.assertIn('modeReply?["ok"] as? Bool == true', client)
        self.assertIn('MAINTENANCE_BEGIN \\(KeepaliveClient.nativeKioskLeaseSeconds)', client)
        self.assertIn('"MAINTENANCE_END"', client)
        stop = client[client.index("func stop()"):
                      client.index("func noteMemoryPressure()")]
        self.assertIn('statusQueue.async { _ = self.control("MAINTENANCE_END") }', stop)
        self.assertNotIn("[weak self]", stop)
        self.assertIn('func reconfigure(policy: String, nativeKioskActive: Bool)', client)
        self.assertNotIn("Process(" , client)
        self.assertNotIn("/bin/sh", client)

    def test_runtime_does_not_double_start_or_claim_unmeasured_health(self) -> None:
        runtime = source("ios/Doorbell/RuntimeSupervisor.swift")
        delegate = source("ios/Doorbell/AppDelegate.swift")
        boot = source("ios/Doorbell/BootConfig.swift")
        project = source("ios/Doorbell.xcodeproj/project.pbxproj")

        self.assertIn("guard heartbeat == nil else {", runtime)
        self.assertIn("refreshHelperPolicy()", runtime)
        self.assertIn("KeepaliveClient(policy: helperPolicy", runtime)
        self.assertIn("keepalive.reconfigure(policy: helperPolicy", runtime)
        self.assertIn('return helperPolicy != "off"', runtime)
        self.assertIn('"helper_available": {', runtime)
        helper_mode = runtime[runtime.index('"helper_mode": {'):
                              runtime.index('"helper_available": {')]
        self.assertNotIn('return "native_kiosk"', helper_mode)
        self.assertIn('"ui": uiComponentState()', runtime)
        self.assertNotIn('"ui": "running"', runtime)
        self.assertIn('var keepaliveHelperPolicy = "off"', boot)
        self.assertIn('\\"keepalive_helper\\": \\"off\\"', boot)
        self.assertIn("runtime = RuntimeSupervisor(core: core, boot: boot)", delegate)
        self.assertIn("runtime?.start()", delegate)
        self.assertIn("runtime.updateAudioSessionReady(audioSessionReady)", delegate)
        self.assertIn("KeepaliveClient.swift", project)

    def test_hang_sentinel_arms_only_in_foreground_and_trips_after_grace(self) -> None:
        sentinel = source("ios/Doorbell/MainRunLoopHangSentinel.swift")
        runtime = source("ios/Doorbell/RuntimeSupervisor.swift")
        self.assertIn("DispatchSource.makeTimerSource(queue: queue)", sentinel)
        self.assertIn("private static let foregroundGrace: TimeInterval = 5", sentinel)
        self.assertIn("private static let probeInterval: TimeInterval = 5", sentinel)
        self.assertIn("private static let failureLimit = 3", sentinel)
        self.assertIn("Darwin.raise(SIGABRT)", sentinel)
        self.assertIn("private var externalSupervisorActive = false", sentinel)
        self.assertIn("setExternalSupervisorActive", sentinel)
        self.assertIn("recordAndAbort", sentinel)
        self.assertNotIn("UserDefaults", sentinel)
        self.assertNotIn("externalSupervisorProvider", sentinel)
        self.assertIn("UIApplication.didEnterBackgroundNotification", runtime)
        self.assertIn("UIApplication.willEnterForegroundNotification", runtime)
        self.assertIn("hangSentinel.disarmForBackground()", runtime)
        self.assertIn("hangSentinel.armAfterForegroundGrace()", runtime)
        self.assertIn("nativeKioskActive: nativeKioskActive", runtime)
        self.assertIn('"native_kiosk_measurement": {', runtime)
        self.assertIn('"guided_access": nativeKioskActive', runtime)
        self.assertIn("UIApplication.shared.applicationState != .background", runtime)
        self.assertIn("UIAccessibility.guidedAccessStatusDidChangeNotification", runtime)
        self.assertIn("DispatchQueue.main.asyncAfter(deadline: .now() + 2)", runtime)
        self.assertIn("ProcessInfo.processInfo.systemUptime", runtime)
        self.assertIn("devices.\\(id).local.recovery.helper_mode", runtime)

        model = SentinelModel(grace=5, timeout=5)
        model.foreground(100)
        self.assertFalse(model.check(104.9), "foreground grace prevents startup false positives")
        self.assertFalse(model.check(105), "the first probe is not a failure")
        self.assertFalse(model.check(110), "the first missed five-second probe is bounded")
        self.assertFalse(model.check(115), "the second missed five-second probe is bounded")
        self.assertTrue(model.check(120), "three missed probes expose the foreground hang once")
        self.assertFalse(model.check(125), "one stall cannot repeatedly terminate")
        model.foreground(200)
        model.background()
        self.assertFalse(model.check(1000), "background suspension is explicitly disarmed")


if __name__ == "__main__":
    unittest.main()
