/* Doorbell live playback policy runner. ES5 only: monitor.html must still parse on iOS 5. */
(function (root) {
  "use strict";

  function supportedMse() {
    return !!(root.MediaSource && root.fetch && root.ReadableStream && root.URL &&
              root.URL.createObjectURL);
  }

  function sameOrigin(url, locationLike) {
    if (!url) return false;
    if (/^\//.test(url) && !/^\/\//.test(url)) return true;
    var loc = locationLike || root.location || {};
    try {
      if (typeof root.URL === "function") return new root.URL(url, loc.href).origin === loc.origin;
    } catch (e) {}
    var m = String(url).match(/^(https?:)\/\/([^/]+)/i);
    if (!m) return true;
    return String(loc.protocol || "").toLowerCase() === m[1].toLowerCase() &&
           String(loc.host || "").toLowerCase() === m[2].toLowerCase();
  }

  // Cross-node fMP4 fetch cannot rely on CORS. Panel/admin pages always select the same-origin
  // authenticated proxy when a semantic door id is known. Direct URLs are accepted only when
  // they are already same-origin (for a local station or development server).
  function proxyMp4Url(door, token, direct, locationLike) {
    if (door) return "/stream-proxy.mp4?door=" + encodeURIComponent(door);
    return sameOrigin(direct, locationLike) ? String(direct || "") : "";
  }

  function strategies(profile) {
    var raw = profile && profile.strategies;
    var out = [], seen = {}, i, s, id;
    if (raw && raw.length) {
      for (i = 0; i < raw.length; i++) {
        s = raw[i] || {};
        id = String(s.id || "");
        if (!s.enabled || seen[id] ||
            (id !== "h264_low_latency" && id !== "h264_hls" && id !== "mjpeg")) continue;
        seen[id] = true;
        out.push({ id: id,
          startup_timeout_ms: Math.max(100, Number(s.startup_timeout_ms) || 5000),
          stall_timeout_ms: Math.max(1000, Number(s.stall_timeout_ms) || 3000) });
      }
    }
    if (!out.length) {
      out = [{ id: "h264_low_latency", startup_timeout_ms: 5000, stall_timeout_ms: 3000 },
             { id: "mjpeg", startup_timeout_ms: 5000, stall_timeout_ms: 3000 }];
    }
    var h264 = [], fallback = [];
    for (i = 0; i < out.length; i++) {
      if (out[i].id === "h264_low_latency" || out[i].id === "h264_hls") h264.push(out[i]);
      else fallback.push(out[i]);
    }
    return h264.concat(fallback);
  }

  function attachMse(video, url, ready, failed, activity) {
    var stopped = false, reader = null, objectUrl = "";
    var aborter = root.AbortController ? new root.AbortController() : null;
    function fail() {
      if (stopped) return;
      stopped = true;
      try { if (aborter) aborter.abort(); } catch (e0) {}
      try { if (reader) reader.cancel(); } catch (e) {}
      failed();
    }
    function frame() { if (!stopped) { activity(); ready(); } }
    video.onerror = fail;
    video.addEventListener("loadeddata", frame);
    video.addEventListener("playing", frame);
    video.addEventListener("timeupdate", activity);
    var ms = new root.MediaSource();
    ms.addEventListener("sourceopen", function () {
      var sb;
      try { sb = ms.addSourceBuffer('video/mp4; codecs="avc1.42E01E"'); }
      catch (e) { fail(); return; }
      var queue = [];
      sb.addEventListener("error", fail);
      sb.addEventListener("updateend", pump);
      function pump() {
        if (stopped || sb.updating) return;
        try {
          if (sb.buffered.length && video.currentTime - sb.buffered.start(0) > 30) {
            sb.remove(0, video.currentTime - 10);
            return;
          }
          if (queue.length) sb.appendBuffer(queue.shift());
        } catch (e2) { fail(); }
      }
      var fetchOptions = { cache: "no-store" };
      if (aborter) fetchOptions.signal = aborter.signal;
      root.fetch(url, fetchOptions).then(function (resp) {
        if (!resp.ok || !resp.body) { fail(); return; }
        reader = resp.body.getReader();
        (function read() {
          reader.read().then(function (r) {
            if (stopped) return;
            if (r.done) { fail(); return; }
            queue.push(r.value);
            pump();
            try {
              if (sb.buffered.length) {
                var end = sb.buffered.end(sb.buffered.length - 1);
                if (end - video.currentTime > 3) video.currentTime = end - 0.5;
              }
            } catch (e3) {}
            read();
          }, fail);
        })();
      }, fail);
    });
    objectUrl = root.URL.createObjectURL(ms);
    video.src = objectUrl;
    var p = video.play && video.play();
    if (p && p.catch) p.catch(function () {});
    return function () {
      stopped = true;
      try { if (aborter) aborter.abort(); } catch (e0) {}
      try { if (reader) reader.cancel(); } catch (e) {}
      try {
        video.removeEventListener("loadeddata", frame);
        video.removeEventListener("playing", frame);
        video.removeEventListener("timeupdate", activity);
      } catch (e1) {}
      try { video.pause(); video.removeAttribute("src"); video.load(); } catch (e2) {}
      try { if (objectUrl) root.URL.revokeObjectURL(objectUrl); } catch (e3) {}
    };
  }

  // Modern browsers parse the MJPEG byte stream so first-frame/stall timing is observable.
  // Legacy Safari falls back to a direct <img src="stream.mjpeg"> below.
  function attachMjpeg(url, frame, failed) {
    if (!(root.fetch && root.ReadableStream && root.Uint8Array && root.Blob)) return null;
    var stopped = false, reader = null;
    var aborter = root.AbortController ? new root.AbortController() : null;
    var buffer = new root.Uint8Array(0), frames = 0;
    function fail() {
      if (stopped) return;
      stopped = true;
      try { if (aborter) aborter.abort(); } catch (e0) {}
      try { if (reader) reader.cancel(); } catch (e1) {}
      failed();
    }
    function append(chunk) {
      var next = new root.Uint8Array(buffer.length + chunk.length);
      next.set(buffer, 0); next.set(chunk, buffer.length); buffer = next;
      var start, end, i;
      while (buffer.length > 1) {
        start = -1; end = -1;
        for (i = 0; i + 1 < buffer.length; i++) {
          if (start < 0 && buffer[i] === 0xff && buffer[i + 1] === 0xd8) start = i;
          if (start >= 0 && buffer[i] === 0xff && buffer[i + 1] === 0xd9) { end = i + 2; break; }
        }
        if (start < 0 || end <= start) break;
        frames++;
        frame(new root.Blob([buffer.slice(start, end)], { type: "image/jpeg" }));
        buffer = buffer.slice(end);
      }
      if (buffer.length > 5 * 1024 * 1024) {
        buffer = start >= 0 ? buffer.slice(start) : new root.Uint8Array(0);
      }
    }
    var fetchOptions = { cache: "no-store" };
    if (aborter) fetchOptions.signal = aborter.signal;
    root.fetch(url, fetchOptions).then(function (resp) {
      if (!resp.ok || !resp.body) { fail(); return; }
      reader = resp.body.getReader();
      (function read() {
        reader.read().then(function (result) {
          if (stopped) return;
          // A proxy may legally return one JPEG even when live=1 is unsupported. Keep that
          // decoded frame visible; the stall policy can later advance instead of erasing it.
          if (result.done) { if (!frames) fail(); return; }
          append(result.value); read();
        }, fail);
      })();
    }, fail);
    return function () {
      stopped = true;
      try { if (aborter) aborter.abort(); } catch (e0) {}
      try { if (reader) reader.cancel(); } catch (e1) {}
    };
  }

  function start(options) {
    var list = strategies(options.profile), video = options.video, img = options.img;
    var mp4 = options.mp4 || "", mjpeg = options.mjpeg || "";
    var stopped = false, index = -1, attempt = 0, current = null, playing = false;
    var mseStop = null, mjpegStop = null, timer = null, stallTimer = null, lastActivity = 0;
    var mjpegStarted = false, mjpegReady = false, mjpegPrecise = false, mjpegObjectUrl = "";
    function notify(state, reason) {
      if (options.onState) options.onState(state, current ? current.id : "", reason || "");
    }
    function clearTimer() { if (timer) { root.clearTimeout(timer); timer = null; } }
    function stopMse() { if (mseStop) { mseStop(); mseStop = null; } }
    function stopMjpeg() {
      if (mjpegStop) { mjpegStop(); mjpegStop = null; }
      if (mjpegObjectUrl) { try { root.URL.revokeObjectURL(mjpegObjectUrl); } catch (e) {} }
      mjpegObjectUrl = ""; mjpegStarted = false; mjpegReady = false; mjpegPrecise = false;
      if (img) { img.onload = null; img.onerror = null; img.removeAttribute("src"); }
    }
    function prewarmMjpeg() {
      if (mjpegStarted || !mjpeg || !img) return;
      mjpegStarted = true;
      img.style.display = "";
      img.style.visibility = "visible";
      img.onload = function () {
        if (stopped) return;
        mjpegReady = true;
        lastActivity = new Date().getTime();
        if (current && current.id === "mjpeg") selectMjpeg();
        else if (!playing && video) video.style.display = "none";
      };
      function failedMjpeg() {
        if (stopped) return;
        if (mjpegStop) { mjpegStop(); mjpegStop = null; }
        if (mjpegObjectUrl) {
          try { root.URL.revokeObjectURL(mjpegObjectUrl); } catch (e) {}
        }
        mjpegObjectUrl = ""; mjpegStarted = false; mjpegReady = false; mjpegPrecise = false;
        img.onload = null; img.onerror = null; img.removeAttribute("src");
        if (current && current.id === "mjpeg") advance("stream_error");
      }
      img.onerror = failedMjpeg;
      mjpegStop = options.mjpegMode === "image" || !sameOrigin(mjpeg) ? null :
        attachMjpeg(mjpeg, function (blob) {
        if (stopped) return;
        var old = mjpegObjectUrl;
        mjpegObjectUrl = root.URL.createObjectURL(blob);
        img.src = mjpegObjectUrl;
        mjpegPrecise = true;
        lastActivity = new Date().getTime();
        if (old) try { root.URL.revokeObjectURL(old); } catch (e) {}
        }, failedMjpeg);
      if (mjpegStop) mjpegPrecise = true;
      else img.src = mjpeg;
    }
    function selectMjpeg() {
      if (stopped || !current || current.id !== "mjpeg" || playing) return;
      if (mjpegPrecise && !mjpegReady) return;
      clearTimer(); stopMse(); playing = true;
      if (video) video.style.display = "none";
      img.style.display = "";
      img.style.visibility = "visible";
      notify("playing", mjpegReady ? "prewarmed" : "streaming");
    }
    function selectH264() {
      if (stopped || !current ||
          (current.id !== "h264_low_latency" && current.id !== "h264_hls") || playing) return;
      playing = true; clearTimer(); lastActivity = new Date().getTime();
      if (img) img.style.visibility = "hidden";
      if (video) video.style.display = "";
      notify("playing", "first_frame");
    }
    function scheduleStall() {
      if (stallTimer) root.clearInterval(stallTimer);
      stallTimer = root.setInterval(function () {
        if (!stopped && playing && current && lastActivity &&
            (current.id === "h264_low_latency" || current.id === "h264_hls" ||
             (current.id === "mjpeg" && mjpegPrecise)) &&
            new Date().getTime() - lastActivity > current.stall_timeout_ms)
          if (current.id === "mjpeg") advance("frame_stall");
          else retryH264("frame_stall");
      }, 500);
    }
    function begin() {
      if (stopped || index >= list.length) {
        notify("failed", "exhausted");
        return;
      }
      current = list[index]; playing = false; attempt++;
      var mine = attempt;
      notify("loading", "");
      if (current.id === "mjpeg") {
        if (!mjpeg) { advance("no_url"); return; }
        prewarmMjpeg();
        // Modern fetch mode waits for a decoded JPEG; legacy multipart <img> has no
        // portable per-frame signal, so reveal it immediately once selected.
        if (mjpegPrecise && !mjpegReady) {
          timer = root.setTimeout(function () {
            if (!stopped && mine === attempt && !playing) advance("startup_timeout");
          }, current.startup_timeout_ms);
          return;
        }
        selectMjpeg();
        return;
      }
      if (!supportedMse() || !mp4 || !video) { advance("unsupported"); return; }
      stopMse();
      video.style.display = "none";
      mseStop = attachMse(video, mp4, function () {
        if (!stopped && mine === attempt) selectH264();
      }, function () {
        if (!stopped && mine === attempt) retryH264("stream_error");
      }, function () { lastActivity = new Date().getTime(); });
      timer = root.setTimeout(function () {
        if (!stopped && mine === attempt && !playing) retryH264("startup_timeout");
      }, current.startup_timeout_ms);
    }
    function retryH264(reason) {
      if (stopped || !current ||
          (current.id !== "h264_low_latency" && current.id !== "h264_hls")) {
        advance(reason); return;
      }
      clearTimer(); stopMse(); playing = false; attempt++;
      if (video) video.style.display = "none";
      if (img) { img.style.display = ""; img.style.visibility = "visible"; }
      notify("fallback", reason || "h264_failed");
      var mine = attempt;
      timer = root.setTimeout(function () {
        if (!stopped && mine === attempt) begin();
      }, 2000);
    }
    function advance(reason) {
      if (stopped) return;
      clearTimer(); stopMse(); playing = false; attempt++;
      if (current && current.id === "mjpeg") stopMjpeg();
      index++;
      begin();
      if (options.onFallback) options.onFallback(reason || "failed");
    }
    var firstMjpeg = -1, i;
    for (i = 0; i < list.length; i++) if (list[i].id === "mjpeg") { firstMjpeg = i; break; }
    if (firstMjpeg > 0) prewarmMjpeg();
    scheduleStall();
    index = 0;
    begin();
    return { stop: function () {
      stopped = true; clearTimer(); stopMse();
      stopMjpeg();
      if (stallTimer) root.clearInterval(stallTimer);
      if (video) { video.style.display = "none"; try { video.removeAttribute("src"); } catch (e) {} }
    } };
  }

  root.DoorbellPlayback = { start: start, strategies: strategies, mseSupported: supportedMse,
                            sameOrigin: sameOrigin, proxyMp4Url: proxyMp4Url };
})(window);
