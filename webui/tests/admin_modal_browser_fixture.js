"use strict";
const fs = require("fs"), path = require("path"), http = require("http"), crypto = require("crypto");
const root = path.resolve(__dirname, "../.."), evidence = path.join(root, "verification/remediation-q01-q18/T25/evidence");
const runEvidence = process.env.DOORBELL_MODAL_EVIDENCE || evidence;
const sha = text => crypto.createHash("sha256").update(text).digest("hex");
function bootstrap(dictionary) {
  window.__DOORBELL_TEST_HOOKS = {};
  const fixture = window.adminModalFixture = {requests:[], storageWrites:[]};
  const originalSetItem = Storage.prototype.setItem;
  Storage.prototype.setItem = function (key, value) { fixture.storageWrites.push([key, value]); return originalSetItem.call(this, key, value); };
  const config = {buildings:{b_fixture:{label:{en:"Fixture building"}}}, doors:{A:{label:{en:"Door A"}}},
    devices:{fixture:{name:"Fixture node", role:"door_station", door:"A"}},
    speech:{provider:"system", voices:{en:"old-voice"}},
    trigger_rules:{r_complex:{enabled:true, when:{type:"button", doors:["A"]},
      schedule:{windows:[{days:["mon","tue"],from:"08:00",to:"18:00"}]},
      actions:[{type:"sip_call",target_extension:"600"},{type:"chime",sound:"ding1"},{type:"telegram",with_snapshot:true}]}}};
  window.XMLHttpRequest = function () {
    this.headers = {};
    this.open = (method, url) => { this.method = method; this.url = url; };
    this.setRequestHeader = (key, value) => { this.headers[key] = value; };
    this.respond = (status, body) => {
      this.completed = true; this.status = status; this.responseText = JSON.stringify(body); this.readyState = 4;
      if (this.onreadystatechange) this.onreadystatechange();
    };
    this.abort = () => { this.status = 0; if (this.onabort) this.onabort(); };
    this.send = body => {
      this.body = body;
      fixture.requests.push(this);
      if (this.method !== "GET" && this.url !== "/api/login") return;
      this.respond(200, this.url.indexOf("/locale/") === 0 ? dictionary : this.url === "/api/config" ? config :
        this.url === "/api/config/snapshot" ? {schema_version:2,revision:"fixture-revision",config:config} :
        this.url === "/api/status" ? {node:{id:"fixture",name:"Fixture node"}, doors:[]} :
        this.url === "/api/login" || this.url === "/api/session" ? {ok:true, csrf_token:"fixture-csrf"} : {ok:true});
    };
  };
}
const server = http.createServer((req,res) => {
  const url = new URL(req.url, "http://127.0.0.1"), phase = url.searchParams.get("phase") === "red" ? "red" : "green";
  if (req.method === "POST" && url.pathname === "/results") {
    let body = ""; req.on("data", chunk => { body += chunk; }); req.on("end", () => {
      const result = JSON.parse(body); fs.writeFileSync(path.join(runEvidence, (process.env.DOORBELL_MODAL_PREFIX || "browser-") + phase + ".json"), JSON.stringify(result,null,2) + "\n");
      res.writeHead(200);res.end("Recorded");console.log(JSON.stringify(result));
    });return;
  }
  const app = fs.readFileSync(path.join(root, process.env.DOORBELL_MODAL_APP || (phase === "red" ? "build/remediation-t25-20260923/before-app.js" : "webui/admin/app.js")), "utf8");
  if (url.pathname === "/app.js") {
    res.writeHead(200,{"Content-Type":"application/javascript","Cache-Control":"no-store"});
    res.end(app.replace("pairAct: pairAct", "pairAct: pairAct, editRule: editRule, editBuilding: editBuilding, editSpeechSettings: editSpeechSettings, editDoorNotice: editDoorNotice, addNoticePreset: addNoticePreset"));return;
  }
  if (url.pathname === "/") {
    const dictionary = fs.readFileSync(path.join(root,"webui/locale/en.json"),"utf8");
    const cases = fs.readFileSync(process.env.DOORBELL_MODAL_CASES || path.join(__dirname,"admin_modal_cases.js"),"utf8");
    let html=fs.readFileSync(path.join(root,"webui/admin/index.html"),"utf8");
    const setup = '<script>(' + bootstrap.toString() + ')(' + dictionary + ');</script>';
    const controls = `<section style="position:fixed;bottom:0;left:0;z-index:50;background:#fff;color:#000;max-height:35vh;overflow:auto"><button id="runModalTests">Run four admin draft tests</button><pre id="modalTestResults"></pre></section><script>${cases}
      document.getElementById("runModalTests").onclick=function(){
        const result={phase:${JSON.stringify(phase)},source_sha256:${JSON.stringify(sha(app))},case_sha256:${JSON.stringify(sha(cases))},
          user_agent:navigator.userAgent,recorded_at:new Date().toISOString(),results:runAdminModalTests()};
        document.getElementById("modalTestResults").textContent=JSON.stringify(result,null,2);
        fetch("/results?phase=${phase}",{method:"POST",body:JSON.stringify(result)});
      };</script>`;
    html=html.replace('<script src="/panel/playback.js">',setup+'<script src="/panel/playback.js">').replace('src="app.js"','src="app.js?phase='+phase+'"').replace('</body>',controls+'</body>');
    res.writeHead(200,{"Content-Type":"text/html","Cache-Control":"no-store"});res.end(html);return;
  }
  const file=path.resolve(root,"webui",url.pathname.replace(/^\//,""));
  if(!file.startsWith(path.join(root,"webui")+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{"Content-Type":"application/javascript"});res.end(fs.readFileSync(file));
});
server.listen(18764,"127.0.0.1",()=>console.log("Admin draft fixture: http://127.0.0.1:18764/"));
