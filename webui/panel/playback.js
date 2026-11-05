/* Doorbell live playback policy runner. ES5 only: monitor.html must still parse on iOS 5. */
(function (root) {
  "use strict";

  // Cancelling a stream reader returns a promise that rejects once the fetch was aborted; that
  // rejection is expected and must not surface as an unhandled error.
  function quiet(promise) {
    if (promise && typeof promise.catch === "function") promise.catch(function () {});
    return promise;
  }

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

  // Protocol v3 serves another node's camera through this node's session-authenticated proxy.
  // A same-origin URL published by Core is used as-is; a cross-origin peer URL is rewritten to
  // /media/peer/<node>/...; anything else yields no URL rather than a mixed-content request.
  var MEDIA_SUFFIX = { mjpeg: "stream.mjpeg", mp4: "stream.mp4", snapshot: "snapshot.jpg",
                       meta: "video-meta" };
  function peerMediaUrl(door, kind, locationLike) {
    var suffix = MEDIA_SUFFIX[kind];
    if (!door || !suffix) return "";
    var direct = kind === "mjpeg" ? door.stream_mjpeg : kind === "mp4" ? door.stream_mp4 :
      (door.stream_mjpeg || door.stream_mp4);
    if (!direct) return "";
    if (sameOrigin(direct, locationLike)) {
      if (kind === "mjpeg" || kind === "mp4") return String(direct);
      return String(direct).replace(/\/stream\.(?:mjpeg|mp4)(\?.*)?$/, "/" + suffix);
    }
    var peer = String(door.source_node_id || "");
    if (!/^[A-Za-z0-9_.:-]{1,128}$/.test(peer)) return "";
    return "/media/peer/" + encodeURIComponent(peer) + "/" + suffix;
  }

  function readUint32(bytes, at) {
    return ((bytes[at] << 24) >>> 0) + (bytes[at + 1] << 16) + (bytes[at + 2] << 8) + bytes[at + 3];
  }
  function boxType(bytes, at) {
    return String.fromCharCode(bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]);
  }
  function hex2(value) { return (value < 16 ? "0" : "") + value.toString(16).toUpperCase(); }

  // Returns {complete, end, codec} for the leading ftyp/moov of a live fMP4 byte prefix. The codec
  // string comes from the AVCDecoderConfigurationRecord (profile, compatibility, level), so a
  // Main/High or level >3.0 encoder is announced correctly to MediaSource.
  function initSegmentInfo(bytes) {
    var at = 0, n = bytes.length;
    while (at + 8 <= n) {
      var size = readUint32(bytes, at), type = boxType(bytes, at + 4), header = 8;
      if (size === 1) {
        if (at + 16 > n) return { complete: false };
        if (readUint32(bytes, at + 8) !== 0) return { complete: true, error: true };
        size = readUint32(bytes, at + 12); header = 16;
      } else if (size === 0) return { complete: true, error: true };
      if (size < header) return { complete: true, error: true };
      if (type === "moov") {
        if (at + size > n) return { complete: false };
        var codec = "";
        for (var i = at + header; i + 8 <= at + size; i++) {
          if (bytes[i + 4] === 0x61 && bytes[i + 5] === 0x76 && bytes[i + 6] === 0x63 &&
              bytes[i + 7] === 0x43) {
            var record = i + 8;
            if (record + 4 <= at + size && bytes[record] === 1)
              codec = "avc1." + hex2(bytes[record + 1]) + hex2(bytes[record + 2]) +
                hex2(bytes[record + 3]);
            break;
          }
        }
        return { complete: true, end: at + size, codec: codec };
      }
      if (type !== "ftyp" && type !== "free" && type !== "styp") return { complete: true, error: true };
      if (at + size > n) return { complete: false };
      at += size;
    }
    return { complete: false };
  }

  function concatBytes(a, b) {
    var out = new root.Uint8Array(a.length + b.length);
    out.set(a, 0); out.set(b, a.length);
    return out;
  }

  var MSE_DEFAULT_CODEC = "avc1.42E01E";
  var MSE_MAX_PENDING_BYTES = 8 * 1024 * 1024;
  var MSE_MAX_INIT_BYTES = 1024 * 1024;

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
      try { if (reader) quiet(reader.cancel()); } catch (e) {}
      failed();
    }
    function frame() { if (!stopped) { activity(); ready(); } }
    video.onerror = fail;
    video.addEventListener("loadeddata", frame);
    video.addEventListener("playing", frame);
    video.addEventListener("timeupdate", activity);
    var ms = new root.MediaSource();
    ms.addEventListener("sourceopen", function () {
      // The SourceBuffer is created once the init segment has arrived, so its codec matches the
      // stream. Pending bytes are bounded: a subscriber that falls this far behind restarts
      // instead of growing memory without limit.
      var sb = null, queue = [], queuedBytes = 0, head = new root.Uint8Array(0);
      function pump() {
        if (stopped || !sb || sb.updating) return;
        try {
          if (sb.buffered.length && video.currentTime - sb.buffered.start(0) > 30) {
            sb.remove(0, video.currentTime - 10);
            return;
          }
          if (queue.length) {
            var next = queue.shift();
            queuedBytes -= next.length;
            sb.appendBuffer(next);
          }
        } catch (e2) { fail(); }
      }
      function enqueue(chunk) {
        queue.push(chunk);
        queuedBytes += chunk.length;
        if (queuedBytes > MSE_MAX_PENDING_BYTES) { fail(); return false; }
        return true;
      }
      function openBuffer(codec) {
        var type = 'video/mp4; codecs="' + (codec || MSE_DEFAULT_CODEC) + '"';
        if (root.MediaSource.isTypeSupported && !root.MediaSource.isTypeSupported(type)) {
          fail(); return false;
        }
        try { sb = ms.addSourceBuffer(type); } catch (e) { fail(); return false; }
        sb.addEventListener("error", fail);
        sb.addEventListener("updateend", pump);
        return true;
      }
      function accept(chunk) {
        if (sb) return enqueue(chunk);
        head = concatBytes(head, chunk);
        var info = initSegmentInfo(head);
        if (info.error || (!info.complete && head.length > MSE_MAX_INIT_BYTES)) { fail(); return false; }
        if (!info.complete) return true;
        var buffered = head;
        head = new root.Uint8Array(0);
        return openBuffer(info.codec) && enqueue(buffered);
      }
      var fetchOptions = { cache: "no-store", credentials: "same-origin" };
      if (aborter) fetchOptions.signal = aborter.signal;
      root.fetch(url, fetchOptions).then(function (resp) {
        if (!resp.ok || !resp.body) { fail(); return; }
        reader = resp.body.getReader();
        (function read() {
          reader.read().then(function (r) {
            if (stopped) return;
            if (r.done) { fail(); return; }
            if (!accept(r.value)) return;
            pump();
            try {
              if (sb && sb.buffered.length) {
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
      try { if (reader) quiet(reader.cancel()); } catch (e) {}
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
      try { if (reader) quiet(reader.cancel()); } catch (e1) {}
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
      try { if (reader) quiet(reader.cancel()); } catch (e1) {}
    };
  }

  function attachSnapshotPoll(url, frame, failed) {
    if (!root.fetch || !root.URL || !root.URL.createObjectURL || !sameOrigin(url)) return null;
    var stopped = false, timer = null, aborter = null, requestTimer = null, failures = 0;
    function schedule(delay) {
      if (!stopped) timer = root.setTimeout(poll, delay);
    }
    function poll() {
      if (stopped) return;
      aborter = root.AbortController ? new root.AbortController() : null;
      requestTimer = root.setTimeout(function () {
        try { if (aborter) aborter.abort(); } catch (e) {}
      }, 2200);
      var request = { cache: "no-store", credentials: "same-origin" };
      if (aborter) request.signal = aborter.signal;
      root.fetch(url, request).then(function (resp) {
        if (!resp.ok || !resp.headers ||
            !/^image\/jpeg(?:\s*;|$)/i.test(resp.headers.get("content-type") || ""))
          throw new Error("invalid snapshot response");
        var length = Number(resp.headers.get("content-length") || 0);
        if (length > 300 * 1024) throw new Error("snapshot too large");
        return resp.blob();
      }).then(function (blob) {
        if (requestTimer) root.clearTimeout(requestTimer);
        requestTimer = null;
        if (stopped) return;
        if (!blob || blob.size < 4 || blob.size > 300 * 1024 ||
            (blob.type && blob.type.toLowerCase().indexOf("image/jpeg") !== 0))
          throw new Error("invalid snapshot body");
        failures = 0;
        frame(blob);
        schedule(300);
      }).catch(function () {
        if (requestTimer) root.clearTimeout(requestTimer);
        requestTimer = null;
        if (stopped) return;
        failures++;
        if (failures >= 5) failed();
        else schedule(Math.min(1500, 250 * failures));
      });
    }
    poll();
    return function () {
      stopped = true;
      if (timer) root.clearTimeout(timer);
      if (requestTimer) root.clearTimeout(requestTimer);
      try { if (aborter) aborter.abort(); } catch (e) {}
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
      if (options.mjpegMode === "poll") {
        if (!sameOrigin(mjpeg)) { failedMjpeg(); return; }
        mjpegPrecise = true;
        mjpegStop = attachSnapshotPoll(mjpeg, function (blob) {
          if (stopped) return;
          var old = mjpegObjectUrl;
          mjpegObjectUrl = root.URL.createObjectURL(blob);
          img.src = mjpegObjectUrl;
          lastActivity = new Date().getTime();
          if (old) try { root.URL.revokeObjectURL(old); } catch (e) {}
        }, failedMjpeg);
      } else {
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
      }
      if (mjpegStop) mjpegPrecise = true;
      else if (options.mjpegMode !== "poll") img.src = mjpeg;
    }
    function selectMjpeg() {
      if (stopped || !current || current.id !== "mjpeg" || playing) return;
      if (!mjpegReady) return;
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
        // Every MJPEG path waits for the first image load before reporting playback.
        if (!mjpegReady) {
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
                            sameOrigin: sameOrigin, proxyMp4Url: proxyMp4Url,
                            peerMediaUrl: peerMediaUrl, initSegmentInfo: initSegmentInfo };
})(window);
