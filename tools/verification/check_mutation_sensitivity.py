#!/usr/bin/env python3
"""Prove an existing production-path test rejects an injected media lifecycle defect."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    args = parser.parse_args()
    args.scratch.mkdir(parents=True, exist_ok=True)
    original = args.repo / "webui/panel/video-session.js"
    before = original.read_bytes()
    old = "if (!stillCurrent(state)) { stopTracks(stream); return; }"
    new = "if (!stillCurrent(state)) { return; }"
    if before.decode().count(old) != 1:
        raise RuntimeError("The reviewed mutation point has changed; inspect production code first.")
    with tempfile.TemporaryDirectory(prefix="media-mutation-", dir=args.scratch) as temporary:
        root = Path(temporary)
        shutil.copytree(args.repo / "webui", root / "webui")
        target = root / "webui/panel/video-session.js"
        command = ["node", "webui/tests/video_session.test.js"]
        for stage, data, expected in [("original", before, 0),
                                      ("mutated", before.decode().replace(old, new).encode(), 1),
                                      ("restored", before, 0)]:
            target.write_bytes(data)
            result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=20)
            print(f"{stage}: source_sha256={hashlib.sha256(data).hexdigest()} exit={result.returncode}")
            print(result.stdout)
            assert result.returncode == expected
            if stage == "mutated":
                assert "AssertionError" in result.stdout
                assert "a stream resolving after stop is immediately released" in result.stdout
                assert "SyntaxError" not in result.stdout
    assert not root.exists(), "the isolated mutation tree must be removed"
    assert original.read_bytes() == before, "the user's source must be byte-for-byte unchanged"
    print("Production mutation sensitivity passed; scratch removed and user source unchanged.")


if __name__ == "__main__":
    main()
