#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import tempfile
import time
import unittest


HELPER: Path
TEST_APP: Path


def wait_until(predicate, timeout: float = 5.0):
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (FileNotFoundError, json.JSONDecodeError) as error:
            last_error = error
        time.sleep(0.02)
    if last_error:
        raise AssertionError(f"condition timed out: {last_error}")
    raise AssertionError("condition timed out")


def read_status(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def fixed_failing_launcher() -> Path:
    """A real root-owned executable that always exits nonzero.

    The helper rejects scripts, so the launcher-failure path needs a compiled
    binary rather than a shell stub.
    """
    for candidate in (Path("/usr/bin/false"), Path("/bin/false")):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise unittest.SkipTest("no fixed false(1) binary available")


def heartbeat(sequence: int, pid: int | None = None, event: str = "heartbeat") -> bytes:
    return json.dumps(
        {
            "protocol": 1,
            "event": event,
            "pid": pid or os.getpid(),
            "bundle_id": "jp.keihan.doorbell",
            "app_version": "test",
            "role": "test",
            "policy": "auto",
            "state": "ready",
            "sequence": sequence,
            "memory_warnings": 0,
            "unix_time": time.time(),
        },
        separators=(",", ":"),
    ).encode()


class HelperProcess:
    def __init__(self, root: Path, mode: str, stream: bool = False,
                 test_exec: Path | None = None, extra: list[str] | None = None,
                 stderr_path: Path | None = None, **environment: str):
        self.root = root
        self.socket = root / "keepalive.sock"
        self.status = root / "status.json"
        self.marker = root / "safe-mode.json"
        self.mode_file = root / "mode"
        self.control_sequence = 0
        self.stderr_path = stderr_path
        self._stderr_file = stderr_path.open("wb") if stderr_path else None
        process_environment = os.environ.copy()
        process_environment.update(environment)
        arguments = [
                str(HELPER),
                "--socket",
                str(self.socket),
                "--status",
                str(self.status),
                "--marker",
                str(self.marker),
                "--mode-file",
                str(self.mode_file),
                "--mode",
                mode,
                "--profile",
                "test",
                "--test-exec",
                str(test_exec or TEST_APP),
                "--app-uid",
                str(os.getuid()),
                "--heartbeat-timeout-ms",
                "2000",
                "--startup-timeout-ms",
                "60",
                "--terminate-grace-ms",
                "60",
                "--time-scale",
                "0.01",
            ]
        if stream:
            arguments += ["--test-stream", "yes"]
        arguments += extra or []
        self.process = subprocess.Popen(
            arguments,
            env=process_environment,
            stdout=subprocess.DEVNULL,
            stderr=self._stderr_file or subprocess.PIPE,
            text=self._stderr_file is None,
        )
        wait_until(
            lambda: self.socket.exists()
            and self.status.exists()
            and read_status(self.status).get("state") != "stopped"
        )

    def control(self, *arguments: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(HELPER), "--control", *arguments, "--socket", str(self.socket)],
            capture_output=True,
            text=True,
            check=False,
        )

    def send(self, payload: bytes) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
            client.sendto(payload, str(self.socket))

    def command(self, command: str) -> dict:
        self.control_sequence += 1
        control_path = self.root / f"c{self.control_sequence}.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
            client.bind(str(control_path))
            client.settimeout(1)
            client.sendto(command.encode(), str(self.socket))
            return json.loads(client.recv(512))

    def stream_command(self, command: str) -> dict:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(1)
            client.connect(str(self.socket))
            client.sendall((command + "\n").encode("ascii"))
            response = bytearray()
            while len(response) < 512:
                byte = client.recv(1)
                if not byte or byte == b"\n":
                    break
                response.extend(byte)
            return json.loads(response)

    def stop(self) -> str:
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
        _, stderr = self.process.communicate(timeout=3)
        if self._stderr_file is not None:
            self._stderr_file.close()
            self._stderr_file = None
            return self.stderr_path.read_text(encoding="utf-8", errors="replace")
        return stderr

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        self.stop()


class KeepaliveTests(unittest.TestCase):
    def test_auto_cold_boot_launches_then_accepts_strict_heartbeat_and_maintenance(self):
        with tempfile.TemporaryDirectory(prefix="dbh-auto-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            with HelperProcess(root, "auto", DB_KEEPALIVE_TEST_LOG=str(launch_log)) as helper:
                wait_until(lambda: launch_log.exists())
                self.assertTrue(read_status(helper.status)["armed"])
                helper.send(b'{"protocol":1,"event":"heartbeat","unknown":true}')
                time.sleep(0.1)
                self.assertNotEqual(read_status(helper.status)["state"], "healthy")
                helper.send(heartbeat(1))
                wait_until(lambda: read_status(helper.status)["state"] == "healthy")
                response = helper.command("MAINTENANCE_BEGIN 1")
                self.assertTrue(response["ok"])
                wait_until(lambda: read_status(helper.status)["state"] == "maintenance")
                response = helper.command("MAINTENANCE_END")
                self.assertTrue(response["ok"])
                wait_until(lambda: read_status(helper.status)["state"] == "healthy")
                status = helper.command("STATUS")
                self.assertEqual(status["mode"], "auto")
                self.assertEqual(status["peer_credentials"],
                                 "enforced" if os.uname().sysname == "Linux"
                                 else "socket_permissions")
                self.assertFalse(list(root.glob("status.json.tmp.*")))

    def test_off_never_launches(self):
        with tempfile.TemporaryDirectory(prefix="dbh-off-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            with HelperProcess(root, "off", DB_KEEPALIVE_TEST_LOG=str(launch_log)) as helper:
                time.sleep(0.2)
                status = read_status(helper.status)
                self.assertEqual(status["state"], "off")
                self.assertFalse(status["armed"])
                self.assertFalse(launch_log.exists())

    def test_mode_off_does_not_terminate_running_app(self):
        with tempfile.TemporaryDirectory(prefix="dbh-off-live-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            app = subprocess.Popen(["/bin/sleep", "5"])
            try:
                with HelperProcess(
                    root, "auto", DB_KEEPALIVE_TEST_LOG=str(launch_log)
                ) as helper:
                    helper.send(heartbeat(1, app.pid))
                    wait_until(lambda: read_status(helper.status)["app_pid"] == app.pid)
                    self.assertTrue(helper.command("MODE off")["ok"])
                    wait_until(lambda: read_status(helper.status)["state"] == "off")
                    time.sleep(0.1)
                    self.assertIsNone(app.poll())
            finally:
                if app.poll() is None:
                    app.terminate()
                    app.wait(timeout=2)

    def test_android_stream_protocol_matches_fixed_client_contract(self):
        with tempfile.TemporaryDirectory(prefix="dbh-stream-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            with HelperProcess(
                root, "auto", stream=True, DB_KEEPALIVE_TEST_LOG=str(launch_log)
            ) as helper:
                initial = helper.stream_command("STATUS")
                self.assertEqual(
                    set(initial), {"enabled", "running", "version", "safe_mode", "error"}
                )
                self.assertTrue(initial["enabled"])
                self.assertEqual(helper.stream_command("MODE invalid")["error"], "invalid_mode")
                self.assertEqual(helper.stream_command("MODE off")["error"], "")
                self.assertEqual(helper.stream_command("ENABLE")["error"], "mode_off")
                self.assertEqual(helper.stream_command("MODE auto")["error"], "")
                enabled = helper.stream_command("ENABLE")
                self.assertTrue(enabled["enabled"])
                self.assertTrue(enabled["running"])
                kicked = helper.stream_command(f"KICK {time.monotonic_ns()}")
                self.assertTrue(kicked["running"])
                paused = helper.stream_command("PAUSE_LEASE 30")
                self.assertTrue(paused["enabled"])
                wait_until(lambda: read_status(helper.status)["state"] == "maintenance")
                disabled = helper.stream_command("DISABLE")
                self.assertFalse(disabled["enabled"])
                wait_until(lambda: read_status(helper.status)["state"] == "waiting_heartbeat")
                invalid = helper.stream_command("RUN /bin/sh")
                self.assertEqual(invalid["error"], "invalid_command")

    def test_script_launcher_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="dbh-script-", dir="/tmp") as temporary:
            root = Path(temporary)
            script = root / "app"
            script.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            script.chmod(0o755)
            with HelperProcess(root, "on", test_exec=script) as helper:
                wait_until(
                    lambda: read_status(helper.status)["last_reason"]
                    == "fixed_launcher_rejected"
                )

    def test_mode_transition_and_restart_persistence(self):
        with tempfile.TemporaryDirectory(prefix="dbh-mode-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            helper = HelperProcess(root, "off", DB_KEEPALIVE_TEST_LOG=str(launch_log))
            try:
                self.assertEqual(stat.S_IMODE(helper.socket.stat().st_mode), 0o660)
                invalid = helper.command("MODE invalid")
                self.assertEqual(invalid["error"], "invalid_mode")
                self.assertEqual(helper.mode_file.read_text(encoding="utf-8"), "off\n")
                self.assertTrue(helper.command("MODE auto")["ok"])
                wait_until(lambda: read_status(helper.status)["armed"])
                helper.send(heartbeat(1))
                wait_until(lambda: read_status(helper.status)["state"] == "healthy")
                self.assertTrue(helper.command("MODE off")["ok"])
                wait_until(lambda: read_status(helper.status)["state"] == "off")
                self.assertTrue(helper.command("MODE auto")["ok"])
                self.assertEqual(helper.mode_file.read_text(encoding="utf-8"), "auto\n")
                launch_count = launch_log.read_text(encoding="utf-8").count("safe=")
            finally:
                helper.stop()
            with HelperProcess(root, "off", DB_KEEPALIVE_TEST_LOG=str(launch_log)) as restarted:
                wait_until(
                    lambda: launch_log.read_text(encoding="utf-8").count("safe=")
                    > launch_count
                )
                status = read_status(restarted.status)
                self.assertEqual(status["mode"], "auto")
                self.assertTrue(status["armed"])

    def test_mode_file_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="dbh-mode-link-", dir="/tmp") as temporary:
            root = Path(temporary)
            target = root / "target"
            target.write_text("auto\n", encoding="utf-8")
            mode_file = root / "mode"
            mode_file.symlink_to(target)
            result = subprocess.run(
                [
                    str(HELPER), "--socket", str(root / "socket"),
                    "--status", str(root / "status"),
                    "--marker", str(root / "marker"),
                    "--mode-file", str(mode_file),
                    "--mode", "off", "--profile", "test",
                    "--test-exec", str(TEST_APP), "--app-uid", str(os.getuid()),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("mode file rejected", result.stderr)

    def test_mode_file_requires_exact_owner_only_permissions(self):
        with tempfile.TemporaryDirectory(prefix="dbh-mode-perm-", dir="/tmp") as temporary:
            root = Path(temporary)
            mode_file = root / "mode"
            mode_file.write_text("auto\n", encoding="utf-8")
            mode_file.chmod(0o644)
            result = subprocess.run(
                [
                    str(HELPER), "--socket", str(root / "socket"),
                    "--status", str(root / "status"),
                    "--marker", str(root / "marker"),
                    "--mode-file", str(mode_file),
                    "--mode", "off", "--profile", "test",
                    "--test-exec", str(TEST_APP), "--app-uid", str(os.getuid()),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("mode file rejected", result.stderr)

    def test_crash_loop_uses_backoff_and_enters_safe_mode(self):
        with tempfile.TemporaryDirectory(prefix="dbh-crash-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            helper = HelperProcess(root, "on", DB_KEEPALIVE_TEST_LOG=str(launch_log))
            try:
                wait_until(lambda: helper.marker.exists())
                wait_until(
                    lambda: launch_log.exists()
                    and "safe=1" in launch_log.read_text(encoding="utf-8")
                )
                status = read_status(helper.status)
                self.assertTrue(status["safe_mode"])
                self.assertGreaterEqual(status["restart_count_5m"], 3)
            finally:
                stderr = helper.stop()
            self.assertIn("restart scheduled after 20 ms", stderr)
            self.assertIn("restart scheduled after 50 ms", stderr)
            self.assertIn("restart scheduled after 100 ms in safe mode", stderr)

    def test_unknown_launcher_or_arbitrary_exec_is_rejected(self):
        common = [
            str(HELPER),
            "--socket", "/tmp/doorbell-reject.sock",
            "--status", "/tmp/doorbell-reject-status.json",
            "--marker", "/tmp/doorbell-reject-marker.json",
            "--mode-file", "/tmp/doorbell-reject-mode",
            "--mode", "on",
            "--app-uid", str(os.getuid()),
        ]
        unknown = subprocess.run(
            common + ["--profile", "unknown"], capture_output=True, check=False
        )
        arbitrary = subprocess.run(
            common + ["--profile", "ios5", "--exec", "/bin/sh"],
            capture_output=True,
            check=False,
        )
        self.assertEqual(unknown.returncode, 2)
        self.assertEqual(arbitrary.returncode, 2)


class ColdBootTests(unittest.TestCase):
    """C1: nothing may be launched before the window server exists."""

    def test_launch_waits_for_springboard_and_never_charges_a_failure(self):
        with tempfile.TemporaryDirectory(prefix="dbh-sb-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            processes = root / "processes"
            processes.write_text("", encoding="utf-8")
            with HelperProcess(
                root, "on",
                extra=["--test-process-file", str(processes), "--boot-grace-ms", "0"],
                DB_KEEPALIVE_TEST_LOG=str(launch_log),
            ) as helper:
                wait_until(
                    lambda: read_status(helper.status)["state"] == "waiting_springboard"
                )
                time.sleep(0.4)
                status = read_status(helper.status)
                self.assertFalse(launch_log.exists())
                self.assertFalse(status["ui_ready"])
                self.assertFalse(status["safe_mode"])
                # A missing window server is not a crash: no backoff, no safe mode.
                self.assertEqual(status["restart_count_5m"], 0)
                processes.write_text("SpringBoard\n", encoding="utf-8")
                wait_until(lambda: launch_log.exists())
                wait_until(lambda: read_status(helper.status)["ui_ready"])

    def test_bounded_boot_grace_defers_the_first_launch(self):
        with tempfile.TemporaryDirectory(prefix="dbh-grace-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            processes = root / "processes"
            processes.write_text("SpringBoard\n", encoding="utf-8")
            with HelperProcess(
                root, "on",
                extra=["--test-process-file", str(processes), "--boot-grace-ms", "900"],
                DB_KEEPALIVE_TEST_LOG=str(launch_log),
            ) as helper:
                wait_until(lambda: read_status(helper.status)["state"] == "boot_grace")
                self.assertFalse(launch_log.exists())
                # Deferring inside the grace is not a failure.
                self.assertEqual(read_status(helper.status)["restart_count_5m"], 0)
                started = time.monotonic()
                wait_until(lambda: launch_log.exists(), timeout=5.0)
                self.assertGreater(time.monotonic() - started, 0.2)

    def test_failing_launcher_is_reported_instead_of_a_silent_startup_timeout(self):
        false_binary = fixed_failing_launcher()
        with tempfile.TemporaryDirectory(prefix="dbh-launcher-", dir="/tmp") as temporary:
            root = Path(temporary)
            with HelperProcess(root, "on", test_exec=false_binary) as helper:
                wait_until(
                    lambda: read_status(helper.status)["last_reason"] == "launcher_failed"
                )
                self.assertGreaterEqual(
                    read_status(helper.status)["restart_count_5m"], 1
                )


class UnprovisionedAppTests(unittest.TestCase):
    """C3: an app that has not started its heartbeat is still running."""

    def test_present_app_without_heartbeat_is_not_relaunched(self):
        with tempfile.TemporaryDirectory(prefix="dbh-silent-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            processes = root / "processes"
            app = subprocess.Popen(["/bin/sleep", "5"])
            try:
                processes.write_text(
                    f"SpringBoard\nDoorbell {app.pid}\n", encoding="utf-8"
                )
                with HelperProcess(
                    root, "on",
                    extra=["--test-process-file", str(processes),
                           "--boot-grace-ms", "0"],
                    DB_KEEPALIVE_TEST_LOG=str(launch_log),
                ) as helper:
                    wait_until(
                        lambda: read_status(helper.status)["state"]
                        == "launch_pending_no_heartbeat"
                    )
                    time.sleep(0.5)
                    status = read_status(helper.status)
                    # Activation nudges may run, but nothing may be *launched*.
                    if launch_log.exists():
                        lines = launch_log.read_text(encoding="utf-8").splitlines()
                        self.assertTrue(lines and all("activate=1" in l for l in lines))
                    self.assertTrue(status["app_process_present"])
                    self.assertEqual(status["restart_count_5m"], 0)
                    self.assertFalse(status["safe_mode"])
            finally:
                if app.poll() is None:
                    app.terminate()
                    app.wait(timeout=2)

    def test_present_silent_app_gets_bounded_activation_nudges(self):
        """iOS 5 `uiopen` starts the app in the background; a re-open activates it."""
        with tempfile.TemporaryDirectory(prefix="dbh-nudge-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            processes = root / "processes"
            app = subprocess.Popen(["/bin/sleep", "8"])
            try:
                processes.write_text(
                    f"SpringBoard\nDoorbell {app.pid}\n", encoding="utf-8"
                )
                with HelperProcess(
                    root, "on",
                    extra=["--test-process-file", str(processes),
                           "--boot-grace-ms", "0", "--activate-interval-ms", "20000"],
                    DB_KEEPALIVE_TEST_LOG=str(launch_log),
                ) as helper:
                    wait_until(
                        lambda: read_status(helper.status)["state"]
                        == "launch_pending_no_heartbeat"
                    )
                    wait_until(
                        lambda: launch_log.exists()
                        and launch_log.read_text(encoding="utf-8").count("activate=1") >= 2
                    )
                    status = read_status(helper.status)
                    lines = launch_log.read_text(encoding="utf-8").splitlines()
                    self.assertTrue(all("activate=1" in l for l in lines))
                    self.assertEqual(status["state"], "launch_pending_no_heartbeat")
                    self.assertEqual(status["restart_count_5m"], 0)
                    self.assertGreaterEqual(status["activation_nudges"], 2)
                    self.assertFalse(status["safe_mode"])
                    self.assertEqual(status["app_pid"], 0)
            finally:
                if app.poll() is None:
                    app.terminate()
                    app.wait(timeout=2)

    def test_a_dead_listed_pid_is_not_treated_as_a_running_app(self):
        with tempfile.TemporaryDirectory(prefix="dbh-stalepid-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            processes = root / "processes"
            app = subprocess.Popen(["/bin/sleep", "5"])
            app.terminate()
            app.wait(timeout=2)
            processes.write_text(
                f"SpringBoard\nDoorbell {app.pid}\n", encoding="utf-8"
            )
            with HelperProcess(
                root, "on",
                extra=["--test-process-file", str(processes), "--boot-grace-ms", "0"],
                DB_KEEPALIVE_TEST_LOG=str(launch_log),
            ) as helper:
                wait_until(lambda: launch_log.exists())
                self.assertFalse(read_status(helper.status)["app_process_present"])


class RailTests(unittest.TestCase):
    """C4: kill switch, absolute safe-mode cap, and expected-exit accounting."""

    def test_root_owned_kill_switch_forces_off_and_release_resumes(self):
        with tempfile.TemporaryDirectory(prefix="dbh-kill-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            disable = root / "disable"
            disable.write_text("", encoding="utf-8")
            with HelperProcess(
                root, "auto", extra=["--disable-file", str(disable)],
                DB_KEEPALIVE_TEST_LOG=str(launch_log),
            ) as helper:
                wait_until(
                    lambda: read_status(helper.status)["state"] == "disabled_by_file"
                )
                time.sleep(0.3)
                status = read_status(helper.status)
                self.assertFalse(launch_log.exists())
                self.assertEqual(status["mode"], "off")
                self.assertEqual(status["configured_mode"], "auto")
                self.assertTrue(status["disabled_by_file"])
                self.assertFalse(status["armed"])
                disable.unlink()
                wait_until(lambda: launch_log.exists())
                self.assertFalse(read_status(helper.status)["disabled_by_file"])

    def test_a_symlinked_kill_switch_is_ignored(self):
        with tempfile.TemporaryDirectory(prefix="dbh-killlink-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            target = root / "target"
            target.write_text("", encoding="utf-8")
            disable = root / "disable"
            disable.symlink_to(target)
            with HelperProcess(
                root, "auto", extra=["--disable-file", str(disable)],
                DB_KEEPALIVE_TEST_LOG=str(launch_log),
            ) as helper:
                wait_until(lambda: launch_log.exists())
                self.assertFalse(read_status(helper.status)["disabled_by_file"])

    def test_safe_mode_launch_cap_stops_relaunching_but_keeps_serving_status(self):
        with tempfile.TemporaryDirectory(prefix="dbh-cap-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            helper = HelperProcess(
                root, "on", extra=["--safe-mode-launch-cap", "2"],
                DB_KEEPALIVE_TEST_LOG=str(launch_log),
            )
            try:
                wait_until(
                    lambda: read_status(helper.status)["state"] == "launch_inhibited",
                    timeout=15.0,
                )
                launches = launch_log.read_text(encoding="utf-8").count("safe=")
                time.sleep(0.6)
                status = read_status(helper.status)
                self.assertTrue(status["launch_inhibited"])
                self.assertTrue(status["safe_mode"])
                self.assertEqual(
                    launch_log.read_text(encoding="utf-8").count("safe="), launches
                )
                # The control surface stays available while launching is inhibited.
                self.assertEqual(helper.command("STATUS")["state"], "launch_inhibited")
            finally:
                stderr = helper.stop()
            self.assertIn("safe-mode launch cap 2 reached", stderr)

    def test_marker_removal_clears_safe_mode_and_the_launch_cap(self):
        with tempfile.TemporaryDirectory(prefix="dbh-clear-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            with HelperProcess(
                root, "on", extra=["--safe-mode-launch-cap", "2"],
                DB_KEEPALIVE_TEST_LOG=str(launch_log),
            ) as helper:
                wait_until(
                    lambda: read_status(helper.status)["state"] == "launch_inhibited",
                    timeout=15.0,
                )
                self.assertTrue(helper.command("MODE off")["ok"])
                wait_until(lambda: read_status(helper.status)["state"] == "off")
                helper.marker.unlink()
                wait_until(lambda: not read_status(helper.status)["safe_mode"])
                status = read_status(helper.status)
                self.assertFalse(status["launch_inhibited"])
                self.assertEqual(status["last_reason"], "safe_mode_cleared")
                self.assertEqual(status["restart_count_5m"], 0)

    def test_announced_stop_is_not_charged_as_a_crash(self):
        with tempfile.TemporaryDirectory(prefix="dbh-clean-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            app = subprocess.Popen(["/bin/sleep", "10"])
            try:
                with HelperProcess(
                    root, "auto", DB_KEEPALIVE_TEST_LOG=str(launch_log)
                ) as helper:
                    helper.send(heartbeat(1, app.pid))
                    wait_until(lambda: read_status(helper.status)["state"] == "healthy")
                    helper.send(heartbeat(2, app.pid, event="stopping"))
                    wait_until(
                        lambda: read_status(helper.status)["last_reason"] == "stopping"
                    )
                    app.terminate()
                    app.wait(timeout=2)
                    wait_until(
                        lambda: read_status(helper.status)["last_reason"] == "clean_exit"
                    )
                    self.assertEqual(
                        read_status(helper.status)["restart_count_5m"], 0
                    )
            finally:
                if app.poll() is None:
                    app.terminate()
                    app.wait(timeout=2)

    def test_a_kill_under_a_maintenance_lease_is_not_charged_as_a_crash(self):
        with tempfile.TemporaryDirectory(prefix="dbh-lease-", dir="/tmp") as temporary:
            root = Path(temporary)
            launch_log = root / "launch.log"
            app = subprocess.Popen(["/bin/sleep", "10"])
            try:
                with HelperProcess(
                    root, "auto", DB_KEEPALIVE_TEST_LOG=str(launch_log)
                ) as helper:
                    helper.send(heartbeat(1, app.pid))
                    wait_until(lambda: read_status(helper.status)["state"] == "healthy")
                    self.assertTrue(helper.command("MAINTENANCE_BEGIN 1")["ok"])
                    wait_until(
                        lambda: read_status(helper.status)["state"] == "maintenance"
                    )
                    app.terminate()
                    app.wait(timeout=2)
                    wait_until(
                        lambda: read_status(helper.status)["last_reason"]
                        == "maintenance_exit",
                        timeout=8.0,
                    )
                    self.assertEqual(
                        read_status(helper.status)["restart_count_5m"], 0
                    )
            finally:
                if app.poll() is None:
                    app.terminate()
                    app.wait(timeout=2)


class LogAndControlTests(unittest.TestCase):
    """C5/C8: bounded diagnostics and the fixed maintenance control client."""

    def test_stderr_log_is_bounded_by_the_configured_cap(self):
        with tempfile.TemporaryDirectory(prefix="dbh-log-", dir="/tmp") as temporary:
            root = Path(temporary)
            log = root / "helper.log"
            helper = HelperProcess(
                root, "on",
                extra=["--log-max-bytes", "512", "--safe-mode-launch-cap", "1000"],
                stderr_path=log,
                DB_KEEPALIVE_TEST_LOG=str(root / "launch.log"),
            )
            try:
                wait_until(
                    lambda: "log truncated" in log.read_text(
                        encoding="utf-8", errors="replace"
                    ),
                    timeout=20.0,
                )
                self.assertLess(log.stat().st_size, 4096)
            finally:
                helper.stop()

    def test_control_client_only_speaks_the_fixed_maintenance_vocabulary(self):
        with tempfile.TemporaryDirectory(prefix="dbh-ctl-", dir="/tmp") as temporary:
            root = Path(temporary)
            with HelperProcess(
                root, "auto", DB_KEEPALIVE_TEST_LOG=str(root / "launch.log")
            ) as helper:
                status = helper.control("status")
                self.assertEqual(status.returncode, 0)
                self.assertEqual(json.loads(status.stdout)["configured_mode"], "auto")

                begin = helper.control("begin", "--seconds", "30")
                self.assertEqual(begin.returncode, 0)
                self.assertTrue(json.loads(begin.stdout)["ok"])
                wait_until(
                    lambda: read_status(helper.status)["state"] == "maintenance"
                )

                end = helper.control("end")
                self.assertEqual(end.returncode, 0)
                self.assertTrue(json.loads(end.stdout)["ok"])
                wait_until(
                    lambda: read_status(helper.status)["state"] != "maintenance"
                )

                self.assertEqual(helper.control("reboot").returncode, 2)
                self.assertEqual(
                    helper.control("begin", "--seconds", "99999").returncode, 2
                )
                missing = subprocess.run(
                    [str(HELPER), "--control", "end", "--socket", str(root / "absent")],
                    capture_output=True, text=True, check=False,
                )
                self.assertNotEqual(missing.returncode, 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--test-app", type=Path, required=True)
    arguments, unittest_arguments = parser.parse_known_args()
    global HELPER, TEST_APP
    HELPER = arguments.helper.resolve()
    TEST_APP = arguments.test_app.resolve()
    program = unittest.main(argv=[__file__, *unittest_arguments], exit=False)
    return 0 if program.result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
