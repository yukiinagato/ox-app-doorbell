"use strict";
const assert = require("assert");

global.window = {
  setTimeout, clearTimeout, setInterval, clearInterval,
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
assert(states.some(s => s[0] === "playing" && s[1] === "mjpeg"));
assert.strictEqual(img.style.visibility, "visible");
session.stop();
console.log("playback policy tests: ok");
