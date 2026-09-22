/* Camera upload lifecycle for the call panel. ES5 so older WebViews can parse it. */
(function (root, factory) {
  var api = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.DoorbellPanelVideo = api;
})(typeof window !== "undefined" ? window : {}, function () {
  "use strict";

  function stopTracks(stream) {
    var tracks = stream && stream.getTracks ? stream.getTracks() : [];
    for (var i = 0; i < tracks.length; i++) {
      try { tracks[i].stop(); } catch (e) {}
    }
  }

  function create(deps) {
    var active = null;

    function stillCurrent(state) {
      return active === state && !state.closed && deps.isCurrent(state.binding);
    }

    function dispose(state) {
      if (!state || state.closed) return;
      state.closed = true;
      if (active === state) active = null;
      if (state.timer) { deps.clearInterval(state.timer); state.timer = 0; }
      if (state.stream) stopTracks(state.stream);
      if (deps.preview.srcObject === state.stream) deps.preview.srcObject = null;
      deps.preview.style.display = "none";
      state.stream = null;
    }

    function start(binding) {
      if (active || !binding || !deps.isCurrent(binding)) return false;
      var state = { binding: binding, closed: false, stream: null, timer: 0, busy: false };
      active = state;  // Reserve the lifecycle before permission is requested.
      var requested;
      try { requested = deps.getUserMedia(); }
      catch (error) {
        if (stillCurrent(state)) deps.onError(error, state.binding);
        dispose(state);
        return false;
      }
      Promise.resolve(requested).then(function (stream) {
        if (!stillCurrent(state)) { stopTracks(stream); return; }
        state.stream = stream;
        deps.preview.srcObject = stream;
        deps.preview.style.display = "block";
        state.timer = deps.setInterval(function () {
          if (!stillCurrent(state)) { dispose(state); return; }
          if (state.busy || !deps.preview.videoWidth) return;
          state.busy = true;
          var canvas = deps.createCanvas();
          canvas.width = 320;
          canvas.height = Math.round(320 * deps.preview.videoHeight / deps.preview.videoWidth) || 240;
          try {
            canvas.getContext("2d").drawImage(deps.preview, 0, 0, canvas.width, canvas.height);
            canvas.toBlob(function (blob) {
              if (!blob || !stillCurrent(state)) { state.busy = false; return; }
              Promise.resolve(deps.postFrame(state.binding.target, blob, state.binding)).then(function () {
                state.busy = false;
              }, function () { state.busy = false; });
            }, "image/jpeg", 0.7);
          } catch (error) {
            state.busy = false;
            if (stillCurrent(state)) deps.onError(error, state.binding);
            dispose(state);
          }
        }, 500);
      }, function (error) {
        if (stillCurrent(state)) deps.onError(error, state.binding);
        dispose(state);
      });
      return true;
    }

    return { start: start, stop: function () { dispose(active); } };
  }

  return { create: create, stopTracks: stopTracks };
});
