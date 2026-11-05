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

// Protocol v3: peer media goes through this node's session-authenticated proxy.
assert.strictEqual(P.peerMediaUrl({ stream_mjpeg: "/stream.mjpeg" }, "mjpeg"), "/stream.mjpeg");
assert.strictEqual(P.peerMediaUrl({ stream_mjpeg: "http://10.0.0.5:47180/stream.mjpeg",
  source_node_id: "a1b2" }, "mjpeg"), "/media/peer/a1b2/stream.mjpeg");
assert.strictEqual(P.peerMediaUrl({ stream_mjpeg: "http://10.0.0.5:47180/stream.mjpeg" }, "mjpeg"),
  "", "an unknown peer is never fetched cross-origin");
assert.strictEqual(P.peerMediaUrl({ stream_mjpeg: "/media/peer/a1b2/stream.mjpeg" }, "snapshot"),
  "/media/peer/a1b2/snapshot.jpg");
assert.strictEqual(P.peerMediaUrl({ source_node_id: "a1b2" }, "mjpeg"), "",
  "no published stream means no URL");
assert.strictEqual(P.peerMediaUrl({ stream_mjpeg: "https://x/stream.mjpeg", source_node_id: "a/b" },
  "mjpeg"), "", "node ids are validated before they enter a path");

function box(type, payload) {
  const out = new Uint8Array(8 + payload.length);
  const n = out.length;
  out.set([n >>> 24 & 255, n >>> 16 & 255, n >>> 8 & 255, n & 255], 0);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(payload, 8);
  return out;
}
function concat(...parts) {
  const out = new Uint8Array(parts.reduce((a, p) => a + p.length, 0));
  let at = 0; for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}
const avcC = box("avcC", new Uint8Array([1, 0x64, 0x00, 0x28, 0xff, 0xe1]));
const moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", box("stsd",
  concat(new Uint8Array(8), box("avc1", concat(new Uint8Array(78), avcC)))))))));
const init = concat(box("ftyp", new Uint8Array([0x69, 0x73, 0x6f, 0x6d, 0, 0, 0, 1])), moov);
const info = P.initSegmentInfo(concat(init, box("moof", new Uint8Array(4))));
assert.strictEqual(info.complete, true);
assert.strictEqual(info.codec, "avc1.640028", "High profile level 4.0 is announced from avcC");
assert.strictEqual(info.end, init.length);
assert.strictEqual(P.initSegmentInfo(init.subarray(0, init.length - 3)).complete, false,
  "a partial moov waits for more bytes");
assert.strictEqual(P.initSegmentInfo(box("mdat", new Uint8Array(4))).error, true,
  "media before an init segment is rejected");

const imageStates = [];
const imageOnly = { style: {}, removeAttribute(name) { if (name === "src") this.src = ""; } };
const imageVideo = { style: {}, removeAttribute() {}, load() {}, pause() {} };
const imageSession = P.start({ profile: { strategies: [
  { id: "mjpeg", enabled: true, startup_timeout_ms: 5000, stall_timeout_ms: 3000 }
] }, mjpeg: "/snapshot.jpg", mjpegMode: "image", img: imageOnly, video: imageVideo,
onState(state) { imageStates.push(state); } });
assert(!imageStates.includes("playing"), "image transport must wait for a decoded frame");
imageOnly.naturalWidth = 64;
imageOnly.naturalHeight = 48;
imageOnly.onload();
assert(imageStates.includes("playing"), "decoded image should start playback");
imageSession.stop();

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
