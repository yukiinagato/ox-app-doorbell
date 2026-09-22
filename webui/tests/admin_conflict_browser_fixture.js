"use strict";
const fs=require("fs"),path=require("path"),http=require("http"),crypto=require("crypto");
const root=path.resolve(__dirname,"../.."), evidence=path.join(root,"verification/remediation-q01-q18/T27/evidence");
const sha=s=>crypto.createHash("sha256").update(s).digest("hex");
function bootstrap(dictionary){
  window.__DOORBELL_TEST_HOOKS={};
  const clone=v=>JSON.parse(JSON.stringify(v));
  const fixture=window.adminConflictFixture={requests:[],version:1,config:{},hold:false};
  fixture.reset=function(){this.version++;this.hold=false;this.beforeCommit=null;this.config={buildings:{b_fixture:{label:{en:"Original",ja:"",zh:""},notifications:true,future:{nullable:null,array:[1,2]}}},doors:{A:{label:{en:"A"}}}};};
  fixture.reset();
  fixture.change=function(fn){fn(this.config);this.version++;};
  function merge(a,b){if(!b||typeof b!=="object"||Array.isArray(b))return clone(b); const out=a&&typeof a==="object"&&!Array.isArray(a)?clone(a):{}; Object.keys(b).forEach(k=>out[k]=merge(out[k],b[k]));return out;}
  fixture.apply=function(ops,cas){for(const op of ops){const parts=op.key.split(".");let node=this.config;while(parts.length>1){const p=parts.shift();if(!node[p]||typeof node[p]!=="object")node[p]={};node=node[p];}const key=parts[0];if(op.op==="delete")delete node[key];else {node[key]=cas?merge(node[key],op.value):clone(op.value);(op.remove_fields||[]).forEach(field=>delete node[key][field]);}}this.version++;};
  window.XMLHttpRequest=function(){
    this.headers={}; this.open=(method,url)=>{this.method=method;this.url=url;};this.setRequestHeader=(k,v)=>this.headers[k]=v;
    this.respond=(status,body)=>{this.completed=true;this.status=status;this.responseText=JSON.stringify(body);this.readyState=4;if(this.onreadystatechange)this.onreadystatechange();};
    this.abort=()=>{this.status=0;if(this.onabort)this.onabort();};
    this.send=body=>{this.body=body;fixture.requests.push(this);const data=body?JSON.parse(body):{};
      if(this.url.startsWith("/locale/"))return this.respond(200,dictionary);
      if(this.url==="/api/config/snapshot")return this.respond(200,{schema_version:2,revision:String(fixture.version),config:clone(fixture.config)});
      if(this.url==="/api/config")return this.respond(200,clone(fixture.config));
      if(this.url==="/api/config/commit"||this.url==="/api/config/batch"){
        if(fixture.beforeCommit)fixture.beforeCommit(this);
        if(fixture.hold)return;
        if(this.url.endsWith("commit")&&data.expected_revision!==String(fixture.version))return this.respond(409,{ok:false,error_code:"config_conflict",revision:String(fixture.version)});
        fixture.apply(data.ops,this.url.endsWith("commit"));return this.respond(200,{ok:true,revision:String(fixture.version)});
      }
      if(this.method==="POST"&&(this.url==="/api/notice"||/^\/api\/doors\/[^/]+\/notice$/.test(this.url))){
        if(data.expected_revision!==String(fixture.version))return this.respond(409,{ok:false,error_code:"config_conflict"});
        if("expires_ms" in data||"created_ms" in data||"from_device" in data)return this.respond(400,{ok:false,error_code:"invalid_request"});
        const key=this.url==="/api/notice"?"notice.global":"doors."+this.url.split("/")[3]+".notice";
        fixture.apply([{op:"set",key,value:{text:data.text,created_ms:123456,expires_ms:data.ttl_s?123456+data.ttl_s*1000:0}}],true);
        return this.respond(200,{ok:true,revision:String(fixture.version)});
      }
      if(this.url==="/api/status")return this.respond(200,{node:{id:"fixture"},features:{config_cas_v1:true},ui_manifest:window.AdminLogic.defaultUiManifest("door_station"),doors:{}});
      this.respond(200,{ok:true,csrf_token:"fixture-only"});
    };
  };
}
const server=http.createServer((req,res)=>{
 const url=new URL(req.url,"http://127.0.0.1"),phase=url.searchParams.get("phase")==="red"?"red":"green";
 if(req.method==="POST"&&url.pathname==="/results"){let text="";req.on("data",c=>text+=c);req.on("end",()=>{const result=JSON.parse(text);fs.writeFileSync(path.join(evidence,"browser-"+phase+".json"),JSON.stringify(result,null,2)+"\n");res.end("Recorded");console.log(JSON.stringify(result));});return;}
 const app=fs.readFileSync(path.join(root,phase==="red"?"build/remediation-t27-20260923/before-app.js":"webui/admin/app.js"),"utf8");
 if(url.pathname==="/app.js"){res.writeHead(200,{"Content-Type":"application/javascript","Cache-Control":"no-store"});res.end(app.replace("pairAct: pairAct","pairAct: pairAct, editBuilding: editBuilding, refreshConfig: refreshConfig, editDoorNotice: editDoorNotice, addNoticePreset: addNoticePreset, editDoorUnlock: editDoorUnlock, editRule: editRule, editDeviceUi: editDeviceUi"));return;}
 if(url.pathname==="/"){const dict=fs.readFileSync(path.join(root,"webui/locale/en.json"),"utf8"),cases=fs.readFileSync(path.join(__dirname,"admin_conflict_cases.js"),"utf8");let html=fs.readFileSync(path.join(root,"webui/admin/index.html"),"utf8");
 const setup='<script>('+bootstrap.toString()+')('+dict+');</script>';
 const controls=`<section style="position:fixed;bottom:0;left:0;z-index:100;background:white;color:black;max-height:40vh;overflow:auto"><button id="runConflictTests">Run config conflict tests</button><button id="showConflictPreview">Show conflict preview</button><pre id="conflictResults"></pre></section><script>${cases}\ndocument.getElementById("runConflictTests").onclick=function(){const result={phase:${JSON.stringify(phase)},source_sha256:${JSON.stringify(sha(app))},case_sha256:${JSON.stringify(sha(cases))},user_agent:navigator.userAgent,recorded_at:new Date().toISOString(),results:runAdminConflictTests()};document.getElementById("conflictResults").textContent=JSON.stringify(result,null,2);fetch("/results?phase=${phase}",{method:"POST",body:JSON.stringify(result)});};document.getElementById("showConflictPreview").onclick=function(){const f=window.adminConflictFixture,h=window.__DOORBELL_TEST_HOOKS.adminRuntime;f.reset();h.refreshConfig();h.editBuilding("b_fixture");document.querySelector("[data-f=\'en\']").value="East entrance";f.change(c=>c.buildings.b_fixture.label.en="Main entrance");document.getElementById("mSave").click();};</script>`;
 html=html.replace('<script src="/panel/playback.js">',setup+'<script src="/panel/playback.js">').replace('src="app.js"','src="app.js?phase='+phase+'"').replace('</body>',controls+'</body>');res.writeHead(200,{"Content-Type":"text/html","Cache-Control":"no-store"});res.end(html);return;}
 let file=path.resolve(root,"webui",url.pathname.replace(/^\//,""));if(url.pathname==="/style.css")file=path.join(root,"webui/admin/style.css");
 if(!file.startsWith(path.join(root,"webui")+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}res.writeHead(200,{"Content-Type":file.endsWith("css")?"text/css":"application/javascript"});res.end(fs.readFileSync(file));
});
server.listen(18765,"127.0.0.1",()=>console.log("Config conflict fixture: http://127.0.0.1:18765/"));
