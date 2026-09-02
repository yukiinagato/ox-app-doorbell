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


def heartbeat(sequence: int, pid: int | None = None) -> bytes:
    return json.dumps(
        {
            "protocol": 1,
            "event": "heartbeat",
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
                 test_exec: Path | None = None, **environment: str):
        self.root = root
        self.socket = root / "keepalive.sock"
        self.status = root / "status.json"
        self.marker = root / "safe-mode.json"
        self.mode_file = root / "mode"
        self.control_sequence = 0
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
        self.process = subprocess.Popen(
            arguments,
            env=process_environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        wait_until(
            lambda: self.socket.exists()
            and self.status.exists()
            and read_status(self.status).get("state") != "stopped"
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
