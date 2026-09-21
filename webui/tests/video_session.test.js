"use strict";

const assert = require("assert");
const Video = require("../panel/video-session.js");

function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

function fixture(onError) {
  const timers = new Map();
  let nextTimer = 1;
  let current = null;
  const media = [];
  const preview = { style: {}, srcObject: null, videoWidth: 320, videoHeight: 240 };
  const blobs = [];
  let canvases = 0, posts = 0;
  const session = Video.create({
    getUserMedia() { const request = deferred(); media.push(request); return request.promise; }, preview,
    createCanvas() {
      canvases++;
      return { getContext() { return { drawImage() {} }; }, toBlob(callback) { blobs.push(callback); } };
    },
    setInterval(fn) { const id = nextTimer++; timers.set(id, fn); return id; },
    clearInterval(id) { timers.delete(id); },
    isCurrent(binding) { return current === binding; },
    postFrame() { posts++; return Promise.resolve(); },
    onError(error, binding) { if (onError) onError(error, binding); else throw error; }
  });
  return { session, media, preview, timers, blobs, setCurrent(v) { current = v; },
    canvases: () => canvases, posts: () => posts };
}

(async function main() {
  {
    let failedBinding = null;
    const f = fixture((_error, binding) => { failedBinding = binding; });
    const binding = { target: "A" };
    f.setCurrent(binding); f.session.start(binding);
    f.media[0].reject({ name: "NotAllowedError" });
    await Promise.resolve(); await Promise.resolve();
    assert.strictEqual(failedBinding, binding,
      "an asynchronous camera failure reports the binding that may be cleared by its owner");
    assert(f.session.start(binding), "camera failure leaves the helper retryable");
  }

  {
    const f = fixture(), binding = { target: "A" };
    f.setCurrent(binding);
    assert(f.session.start(binding));
    f.setCurrent(null);
    f.session.stop();
    const track = { stopped: false, stop() { this.stopped = true; } };
    f.media[0].resolve({ getTracks() { return [track]; } });
    await Promise.resolve(); await Promise.resolve();
    assert(track.stopped, "a stream resolving after stop is immediately released");
  }

  {
    const f = fixture(), first = { target: "A" }, second = { target: "B" };
    f.setCurrent(first); f.session.start(first);
    f.setCurrent(null); f.session.stop();
    f.setCurrent(second); f.session.start(second);
    const secondTrack = { stopped: false, stop() { this.stopped = true; } };
    f.media[1].resolve({ getTracks() { return [secondTrack]; } });
    await Promise.resolve(); await Promise.resolve();
    const firstTrack = { stopped: false, stop() { this.stopped = true; } };
    f.media[0].resolve({ getTracks() { return [firstTrack]; } });
    await Promise.resolve(); await Promise.resolve();
    assert.strictEqual(f.preview.srcObject.getTracks()[0], secondTrack,
      "an older permission result cannot replace the later session preview");
    assert(firstTrack.stopped, "an older permission result releases its tracks");
  }

  {
    const f = fixture(), binding = { target: "A" };
    f.setCurrent(binding); f.session.start(binding);
    f.media[0].resolve({ getTracks() { return []; } });
    await Promise.resolve(); await Promise.resolve();
    const tick = Array.from(f.timers.values())[0];
    tick();
    assert.strictEqual(f.canvases(), 1, "encoding reserves busy before toBlob returns");
    f.setCurrent(null); f.session.stop();
    f.blobs[0]({ size: 1 });
    await Promise.resolve();
    assert.strictEqual(f.posts(), 0, "a blob completing after stop cannot upload");
  }

  {
    const stopped = [];
    Video.stopTracks({ getTracks() { return [
      { stop() { throw new Error("first track failed"); } },
      { stop() { stopped.push("second"); } }
    ]; } });
    assert.deepStrictEqual(stopped, ["second"], "one track failure does not skip later tracks");
  }

  console.log("video session tests: ok");
})().catch((error) => { console.error(error.stack || error); process.exitCode = 1; });
