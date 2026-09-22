"use strict";
const fs = require("fs"), path = require("path"), http = require("http"), crypto = require("crypto");
const root = path.resolve(__dirname, "../..");
const evidence = path.join(root, "verification/remediation-q01-q18/T13/evidence");
const sha = text => crypto.createHash("sha256").update(text).digest("hex");
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "POST" && url.pathname === "/results") {
    let body = "";
    req.on("data", chunk => { body += chunk; });
    req.on("end", () => {
      const result = JSON.parse(body);
      const phase = url.searchParams.get("phase") === "red" ? "red" : "green";
      fs.writeFileSync(path.join(evidence, "browser-" + phase + ".json"), JSON.stringify(result, null, 2) + "\n");
      res.writeHead(200, { "Content-Type": "text/plain" }); res.end("Recorded");
      console.log(JSON.stringify(result));
    });
    return;
  }
  if (url.pathname === "/") {
    const phase = url.searchParams.get("phase") === "red" ? "red" : "green";
    const source = phase === "red" ? "build/remediation-t13-20260922/before-call.html" : "webui/panel/call.html";
    const page = fs.readFileSync(path.join(root, source), "utf8");
    const cases = fs.readFileSync(path.join(__dirname, "call_tabs_cases.js"), "utf8");
    const fixture = `<script>
      DoorbellPlayback.start = function () { return {stop:function(){}}; };
      DoorbellPlayback.proxyMp4Url = function () { return ""; };
      LANG = "en"; I18N = {}; els.title.textContent = "Door tab focus verification";
      ${cases}
      document.getElementById("runTests").onclick = function () {
        const result = {phase:${JSON.stringify(phase)}, source_sha256:${JSON.stringify(sha(page))},
          case_sha256:${JSON.stringify(sha(cases))}, user_agent:navigator.userAgent,
          recorded_at:new Date().toISOString(), results:runDoorTabTests()};
        document.getElementById("testResults").textContent = JSON.stringify(result, null, 2);
        fetch("/results?phase=${phase}", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(result)});
      };
    </script>`;
    const html = page.replace(/\nstart\(\);\s*<\/script>/, "\n</script>")
      .replace("</body>", '<section><button id="runTests">Run four door focus tests</button><pre id="testResults" style="white-space:pre-wrap"></pre></section>' + fixture + "</body>");
    res.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "no-store" }); res.end(html); return;
  }
  const relative = url.pathname.replace(/^\//, "");
  const resolved = path.resolve(root, "webui", relative.startsWith("vendor/") ? "panel/" + relative : relative);
  if (!resolved.startsWith(path.join(root, "webui") + path.sep) || !fs.existsSync(resolved)) {
    res.writeHead(404); res.end(); return;
  }
  res.writeHead(200, { "Content-Type": "application/javascript", "Cache-Control": "no-store" }); res.end(fs.readFileSync(resolved));
});
server.listen(18763, "127.0.0.1", () => console.log("Door tab browser fixture: http://127.0.0.1:18763/"));
