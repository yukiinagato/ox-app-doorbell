#!/usr/bin/env python3
"""Record a bounded local verification command and its exact source provenance."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-id", default="T01")
    parser.add_argument("--id", required=True)
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--cwd", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--kind", default="host")
    parser.add_argument("--expected-exit", type=int, default=0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    manifest_bytes = args.source_manifest.read_bytes()
    source = json.loads(manifest_bytes)
    args.out.mkdir(parents=True, exist_ok=True)
    log = args.out.resolve() / (args.id + ".log")
    record = {key: source[key] for key in ("source_sha", "tree_state", "diff_sha256")}
    record.update(task_id=args.task_id, test_id=args.id, evidence_kind=args.kind,
                  source_manifest=str(args.source_manifest.resolve()),
                  source_manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
                  command=command, cwd=str(args.cwd.resolve()), started_at=timestamp(),
                  platform=platform.system(), os_version=platform.release(), arch=platform.machine(),
                  device_or_browser=None, app_version=None, build_number=None,
                  sip_backend="not_qualified", signing_state="not_qualified",
                  artifact_sha256=None, log_path=str(log), limitations=[], timed_out=False)
    with log.open("w") as output:
        try:
            child = subprocess.Popen(command, cwd=args.cwd, stdout=output,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = child.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                record["timed_out"] = True
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
                # A parent may exit on TERM while a descendant keeps the session alive.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
                code = 124
        except OSError as error:
            output.write(str(error) + "\n")
            code = 127
    record.update(exit_code=code, finished_at=timestamp(), expected_exit_code=args.expected_exit,
                  status="PASS" if code == args.expected_exit else "FAIL",
                  observed_result="Command exit status only; inspect the log for behavioral evidence.")
    (args.out / (args.id + ".json")).write_text(json.dumps(record, indent=2) + "\n")
    print(f"{args.id}: exit={code}, expected={args.expected_exit}, log={log}")
    return 0 if code == args.expected_exit else 1


if __name__ == "__main__":
    sys.exit(main())
