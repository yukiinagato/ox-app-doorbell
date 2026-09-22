#!/usr/bin/env python3
"""Decode production VideoTrack output and compare frame identities after a rejected AU."""
import argparse
import pathlib
import subprocess


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def hashes(path):
    return [line.split(",")[-1].strip() for line in path.read_text().splitlines()
            if line and not line.startswith("#")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True, type=pathlib.Path)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    fixture = args.out / "fixture.h264"
    run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25",
        "-frames:v", "20", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "5", "-bf", "0",
        "-x264-params", "aud=1:repeat-headers=1:scenecut=0", "-f", "h264", str(fixture))
    results = {}
    for mode in ["normal", "reject"]:
        mp4 = args.out / (mode + ".mp4")
        digest = args.out / (mode + ".framemd5")
        run(str(args.probe.resolve()), str(fixture), str(mp4), mode)
        run("ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(mp4),
            "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", str(digest))
        results[mode] = hashes(digest)
    assert len(results["normal"]) == 20, results
    expected = results["normal"][:1] + results["normal"][5:]
    assert results["reject"] == expected, "recovery must match source frame 0 and frames 5–19"
    print("Production decode passed: 20 normal frames; 16 recovered frames with identical pixels.")


if __name__ == "__main__":
    main()
