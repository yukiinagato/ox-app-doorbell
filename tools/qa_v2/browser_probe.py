#!/usr/bin/env python3
"""Exercise the real embedded player and Core HTTP with real Chromium JPEG decoding.

Only the harness HTML and one intentionally withheld network response are test
adapters. Playback JavaScript, HTTP routes, image bytes, and browser onload are real.
This is browser/Core component integration, not native-device or real-SIP testing.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
from typing import Any, Callable


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--browser", default=os.environ.get("QA_V2_CHROMIUM", ""))
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []
    proc: subprocess.Popen[str] | None = None
    fixture_log = (args.out / "fixture.log").open("w", encoding="utf-8")
    browser = None

    def record(identifier: str, action: Callable[[], dict[str, Any]]) -> None:
        try:
            detail = action()
            results.append({"id": identifier, "status": "PASS", "observed": detail})
        except AssertionError as error:
            results.append({"id": identifier, "status": "FAIL", "detail": str(error)})
        except Exception as error:
            results.append({"id": identifier, "status": "BLOCKED" if "ERR_BLOCKED_BY_ADMINISTRATOR" in str(error) else "ERROR", "detail": repr(error)})

    try:
        from playwright.sync_api import sync_playwright
        if not args.fixture.is_file():
            raise RuntimeError(f"Missing fixture executable: {args.fixture}")
        proc = subprocess.Popen([str(args.fixture.resolve())], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=fixture_log, text=True)
        ready_queue: queue.Queue[str] = queue.Queue()
        assert proc.stdout is not None
        def read_ready() -> None:
            for line in proc.stdout:
                if line.startswith("{"):
                    ready_queue.put(line)
                    break
        reader = threading.Thread(target=read_ready, daemon=True)
        reader.start()
        ready = json.loads(ready_queue.get(timeout=20))
        base = f"http://127.0.0.1:{ready['port']}"
        with sync_playwright() as pw:
            executable = args.browser or shutil.which("chromium") or shutil.which("chromium-browser")
            options: dict[str, Any] = {"headless": True}
            if executable:
                options["executable_path"] = executable
            if hasattr(os, "geteuid") and os.geteuid() == 0:
                options["args"] = ["--no-sandbox"]
            browser = pw.chromium.launch(**options)

            def local_component(valid: bool) -> dict[str, Any]:
                # Browser navigation policy can block the network lane. This
                # separate component lane uses real embedded source + real Core
                # JPEG bytes, delivered by the harness. It is NOT network E2E.
                context = browser.new_context()
                try:
                    script = context.request.get(base + "/panel/playback.js")
                    jpeg = context.request.get(base + "/snapshot.jpg")
                    if script.status != 200 or jpeg.status != 200:
                        raise RuntimeError("Core could not provide player source and control JPEG")
                    page = context.new_page()
                    page.set_content('<img id="picture"><video id="video" muted></video>')
                    page.add_script_tag(content=script.text())
                    content = jpeg.body() if valid else b"not-a-jpeg"
                    uri = "data:image/jpeg;base64," + base64.b64encode(content).decode("ascii")
                    page.evaluate("""uri => {
                      window.probeStates=[];
                      window.probe=DoorbellPlayback.start({
                        profile:{strategies:[{id:'mjpeg',enabled:true}]},
                        mjpeg:uri,mjpegMode:'image',img:document.querySelector('#picture'),
                        video:document.querySelector('#video'),
                        onState:(state,strategy,reason)=>probeStates.push({state,strategy,reason})
                      });
                    }""", uri)
                    if valid:
                        page.wait_for_function("document.querySelector('#picture').naturalWidth === 64", timeout=5000)
                    else:
                        page.wait_for_timeout(200)
                    observed = page.evaluate("({states:probeStates,width:document.querySelector('#picture').naturalWidth})")
                    page.evaluate("probe.stop()")
                    if valid:
                        assert observed["width"] == 64, str(observed)
                    else:
                        assert observed["width"] == 0, "Invalid image control unexpectedly decoded"
                        assert not any(row["state"] == "playing" for row in observed["states"]), (
                            "The image never decodes, but the real browser player emitted playing: " + json.dumps(observed))
                    return observed
                finally:
                    context.close()

            record("qa_v2.browser_component.real_jpeg_decodes_control", lambda: local_component(True))
            record("qa_v2.browser_component.invalid_image_never_playing", lambda: local_component(False))

            def scenario(action: Callable[[Any], dict[str, Any]]) -> dict[str, Any]:
                context = browser.new_context(viewport={"width": 800, "height": 480})
                try:
                    login = context.request.post(base + "/api/panel/session",
                        headers={"Origin": base}, data={"credential": ready["credential"]})
                    if login.status != 200:
                        raise RuntimeError(f"Fixture login failed: HTTP {login.status}: {login.text()}")
                    page = context.new_page()
                    page.route("**/__qa_v2__", lambda route: route.fulfill(
                        status=200, content_type="text/html", body="""<!doctype html>
                        <meta charset="utf-8"><title>Doorbell real player probe</title>
                        <h1>Real Core / browser frame probe</h1>
                        <img id="picture"><video id="video" muted playsinline></video>
                        <script src="/panel/playback.js"></script>"""))
                    page.goto(base + "/__qa_v2__", wait_until="load")
                    page.wait_for_function("typeof DoorbellPlayback === 'object'")
                    return action(page)
                finally:
                    context.close()

            def start(page: Any, url: str, image_mode: bool) -> None:
                page.evaluate("""o => {
                  window.probeStates = [];
                  window.probe = DoorbellPlayback.start({
                    profile: {strategies: [{id:'mjpeg', enabled:true,
                      startup_timeout_ms:3000, stall_timeout_ms:1500}]},
                    mjpeg:o.url, mjpegMode:o.image ? 'image' : undefined,
                    img:document.querySelector('#picture'),
                    video:document.querySelector('#video'),
                    onState:(state,strategy,reason) => probeStates.push({state,strategy,reason})
                  });
                }""", {"url": url, "image": image_mode})

            def sample(page: Any) -> dict[str, Any]:
                # Read DECODED pixels over time, not packet counts, src assignment, or "playing".
                return page.evaluate("""async () => {
                  const image = document.querySelector('#picture');
                  const canvas = document.createElement('canvas'); canvas.width=1; canvas.height=1;
                  const ctx = canvas.getContext('2d'); const samples=[];
                  for(let i=0;i<16;i++) {
                    if(image.naturalWidth>0) {
                      ctx.drawImage(image,0,0,1,1);
                      samples.push(ctx.getImageData(0,0,1,1).data[0]);
                    }
                    await new Promise(resolve=>setTimeout(resolve,150));
                  }
                  return {samples, distinct:[...new Set(samples)], states:probeStates,
                    width:image.naturalWidth, src:image.getAttribute('src')};
                }""")

            def withheld(page: Any) -> dict[str, Any]:
                held = []
                page.route("**/stream.mjpeg", lambda route: held.append(route))
                start(page, "/stream.mjpeg", True)
                page.wait_for_timeout(500)
                state = page.evaluate("({states:probeStates,width:document.querySelector('#picture').naturalWidth})")
                if not held or state["width"] != 0:
                    raise RuntimeError(f"The withholding fixture did not hold a frameless response: {state}")
                assert not any(s["state"] == "playing" for s in state["states"]), (
                    "No HTTP response or decoded frame exists, but the real player reports playing: "
                    + json.dumps(state))
                return state

            def direct(page: Any) -> dict[str, Any]:
                start(page, "/stream.mjpeg", True)
                observed = sample(page)
                assert len(observed["distinct"]) >= 3, (
                    "The live positive control must decode multiple distinct frames: " + json.dumps(observed))
                return observed

            def live_proxy(page: Any) -> dict[str, Any]:
                # Match both the URL and mjpegMode:"image" in call.html:456-458.
                # live=1 is an optional server upgrade, so the player must also
                # keep moving when the documented fallback response is one JPEG.
                start(page, "/snapshot-proxy?door=front&live=1", True)
                observed = sample(page)
                page.screenshot(path=str(args.out / "live-proxy.png"))
                assert len(observed["distinct"]) >= 3, (
                    "A moving source must remain moving through the call-page fallback; observed "
                    + json.dumps(observed))
                return observed

            def stopped(page: Any) -> dict[str, Any]:
                start(page, "/stream.mjpeg", True)
                page.wait_for_function("document.querySelector('#picture').naturalWidth > 0", timeout=5000)
                page.evaluate("probe.stop(); window.eventsAtStop=probeStates.length")
                page.wait_for_timeout(300)
                observed = page.evaluate("({src:document.querySelector('#picture').getAttribute('src'),"
                                         "laterEvents:probeStates.length-eventsAtStop})")
                assert observed["src"] is None and observed["laterEvents"] == 0, str(observed)
                return observed

            record("qa_v2.browser.no_frame_must_not_report_playing", lambda: scenario(withheld))
            record("qa_v2.browser.real_mjpeg_decodes_moving_pixels_control", lambda: scenario(direct))
            record("qa_v2.browser.call_fallback_keeps_moving_after_single_jpeg", lambda: scenario(live_proxy))
            record("qa_v2.browser.stop_releases_image_control", lambda: scenario(stopped))
            browser.close()
            browser = None
    except Exception as error:
        results.append({"id": "qa_v2.browser.infrastructure", "status": "BLOCKED", "detail": repr(error)})
    finally:
        if proc is not None:
            try:
                proc.communicate("stop\n", timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate(timeout=5)
        fixture_log.close()
    report = {"suite": "chromium-component-and-core-network-integration", "results": results}
    (args.out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if any(row["status"] in {"ERROR", "BLOCKED"} for row in results):
        return 2
    return 1 if any(row["status"] == "FAIL" for row in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
