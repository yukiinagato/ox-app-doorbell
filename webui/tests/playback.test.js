"use strict";
const assert = require("assert");

global.window = {
  setTimeout, clearTimeout, setInterval, clearInterval,
  AbortController, Blob, ReadableStream, Uint8Array,
  fetch() {
    let read = false;
    return Promise.resolve({ ok: true, body: { getReader() {
      return { read() {
        if (read) return new Promise(() => {});
        read = true;
        return Promise.resolve({ done: false,
          value: new Uint8Array([255, 216, 255, 217]) });
      }, cancel() {} };
    } } });
  },
  location: { href: "https://panel.local/panel/monitor.html", origin: "https://panel.local",
              protocol: "https:", host: "panel.local" },
  URL: { createObjectURL() { return "blob:test"; }, revokeObjectURL() {} }
};
require("../panel/playback.js");

const P = global.window.DoorbellPlayback;
const normalized = P.strategies({ strategies: [
  { id: "mjpeg", enabled: true, startup_timeout_ms: 1234, stall_timeout_ms: 4321 },
  { id: "h264_hls", enabled: false, startup_timeout_ms: 300, stall_timeout_ms: 5000 },
  { id: "mjpeg", enabled: true, startup_timeout_ms: 1, stall_timeout_ms: 1 },
  { id: "unknown", enabled: true, startup_timeout_ms: 300, stall_timeout_ms: 3000 }
] });
assert.deepStrictEqual(normalized.map(s => s.id), ["mjpeg"]);
assert.strictEqual(normalized[0].startup_timeout_ms, 1234);
assert.strictEqual(P.proxyMp4Url("d front", "a+b", "http://peer/stream.mp4"),
                   "/stream-proxy.mp4?door=d%20front");
assert.strictEqual(P.proxyMp4Url("", "", "/stream.mp4"), "/stream.mp4");
assert.strictEqual(P.proxyMp4Url("", "", "http://peer/stream.mp4"), "");

const states = [];
const img = { style: {}, removeAttribute(name) { if (name === "src") this.src = ""; } };
const video = { style: {}, removeAttribute() {}, load() {}, pause() {} };
const session = P.start({ profile: { strategies: [
  { id: "h264_low_latency", enabled: true, startup_timeout_ms: 300, stall_timeout_ms: 3000 },
  { id: "h264_hls", enabled: true, startup_timeout_ms: 300, stall_timeout_ms: 5000 },
  { id: "mjpeg", enabled: true, startup_timeout_ms: 5000, stall_timeout_ms: 3000 }
] }, mp4: "/stream.mp4", mjpeg: "/stream.mjpeg", img, video,
onState(state, strategy, reason) { states.push([state, strategy, reason]); } });

assert.deepStrictEqual(states.filter(s => s[0] === "loading").map(s => s[1]),
                       ["h264_low_latency", "h264_hls", "mjpeg"]);
try {
  // Selecting a transport is not evidence that any image decoded. This unit
  // test controls the boundary; the Chromium probe separately verifies decoding.
  assert(!states.some(s => s[0] === "playing"),
         "Do not report playing before the first decoded frame");
  assert.strictEqual(typeof img.onload, "function");
  img.naturalWidth = 64;
  img.naturalHeight = 48;
  img.onload();
  assert(states.some(s => s[0] === "playing" && s[1] === "mjpeg"));
  assert.strictEqual(img.style.visibility, "visible");
} finally {
  session.stop();
}

async function verifySnapshotPolling() {
  let polls = 0;
  global.window.fetch = (url, request) => {
    polls++;
    assert.strictEqual(url, "/snapshot-proxy?door=d_front&live=1");
    assert.strictEqual(request.credentials, "same-origin");
    assert.strictEqual(request.cache, "no-store");
    return Promise.resolve({ ok: true,
      headers: { get(name) { return name === "content-type" ? "image/jpeg" : "4"; } },
      blob() { return Promise.resolve(new Blob([new Uint8Array([255, 216, 255, 217])],
        { type: "image/jpeg" })); }
    });
  };
  let objectId = 0;
  global.window.URL.createObjectURL = () => "blob:poll-" + (++objectId);
  const pollImg = { style: {}, removeAttribute(name) { if (name === "src") this.src = ""; } };
  const pollVideo = { style: {}, removeAttribute() {}, load() {}, pause() {} };
  const pollStates = [];
  const pollSession = P.start({ profile: { strategies: [
    { id: "mjpeg", enabled: true, startup_timeout_ms: 5000, stall_timeout_ms: 3000 }
  ] }, mjpeg: "/snapshot-proxy?door=d_front&live=1", mjpegMode: "poll",
    img: pollImg, video: pollVideo,
    onState(state, strategy) { pollStates.push([state, strategy]); }
  });
  const tick = ms => new Promise(resolve => setTimeout(resolve, ms));
  try {
    await tick(0);
    assert.strictEqual(pollImg.src, "blob:poll-1");
    pollImg.onload();
    assert(pollStates.some(state => state[0] === "playing" && state[1] === "mjpeg"));
    await tick(350);
    assert(polls >= 2, "snapshot fallback must retrieve later frames");
    assert.strictEqual(pollImg.src, "blob:poll-" + polls);
  } finally {
    pollSession.stop();
  }
  const stoppedAt = polls;
  await tick(350);
  assert.strictEqual(polls, stoppedAt, "stopping playback must cancel future polls");
}

verifySnapshotPolling().then(() => {
  console.log("playback policy tests: ok");
}, error => {
  console.error(error);
  process.exitCode = 1;
});
