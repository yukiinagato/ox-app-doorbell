#!/usr/bin/env python3
"""Record bounded local T35 compatibility build evidence from frozen inputs."""
import datetime
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[4]
evidence = root / "verification/remediation-q01-q18/T35-ios-compat/evidence"
revision = sys.argv[2] if len(sys.argv) > 2 else "r2"
frozen = root / ("build/remediation-t35-compat/frozen-" + revision)
kind = sys.argv[1]
commands = {
    "host": [str(frozen / "ios-compat/scripts/test_host.sh")],
    "ios5-core": [str(frozen / "ios-compat/scripts/build_core_ios5.sh"), "--install"],
    "ios5-app": [str(frozen / "ios-compat/scripts/build_app_ios5.sh")],
    "ios9-preflight": [str(frozen / "ios-compat/scripts/build_ios9_armv7.sh"), "--signing", "jailbreak", "--preflight-only"],
}
env = os.environ.copy()
env.update(GIT_DIR=str(root / ".git"), GIT_WORK_TREE=str(frozen), GIT_OPTIONAL_LOCKS="0",
           DB_ALLOW_DIRTY="1", DB_BUILD_ID="remediation-t35-compat-" + revision, DB_BUILD_JOBS="4")
manifest = root / ("verification/remediation-q01-q18/T35-ios-compat/source-frozen-" + revision + ".json")
record = {"command": commands[kind], "cwd": str(frozen), "environment": {k: env[k] for k in
          ["GIT_DIR", "GIT_WORK_TREE", "GIT_OPTIONAL_LOCKS", "DB_ALLOW_DIRTY", "DB_BUILD_ID", "DB_BUILD_JOBS"]},
          "source_manifest": str(manifest), "source_manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
          "platform": platform.platform(), "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
start = time.monotonic()
log_path = evidence / (kind + "-" + revision + ".log")
with log_path.open("w") as log:
    try:
        result = subprocess.run(commands[kind], cwd=frozen, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600)
        record["exit_code"] = result.returncode
    except subprocess.TimeoutExpired:
        record["exit_code"] = 124
        record["timed_out"] = True
record["elapsed_seconds"] = round(time.monotonic() - start, 3)
record["log_sha256"] = hashlib.sha256(log_path.read_bytes()).hexdigest()
record["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
(evidence / (kind + "-" + revision + ".json")).write_text(json.dumps(record, indent=2) + "\n")
print(kind, record["exit_code"], record["elapsed_seconds"])
raise SystemExit(record["exit_code"])
