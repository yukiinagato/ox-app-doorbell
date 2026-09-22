"use strict";
const fs=require("fs"),path=require("path"),http=require("http"),crypto=require("crypto");
const root=path.resolve(__dirname,"../.."), evidence=path.join(root,"verification/remediation-q01-q18/T28-Web/evidence");
const sha=value=>crypto.createHash("sha256").update(value).digest("hex");
const app=fs.readFileSync(path.join(root,"webui/admin/app.js"),"utf8");
const cases=fs.readFileSync(path.join(__dirname,"admin_partition_conflict_cases.js"),"utf8");
function bootstrap(dictionary) {
  window.__DOORBELL_TEST_HOOKS={};
  const clone=value=>JSON.parse(JSON.stringify(value));
  const fixture=window.adminPartitionFixture={requests:[],version:0};
  fixture.reset=function(){
    this.version++;this.hold=false;this.capacity=true;this.originalVersion=this.version;
    this.extraConflicts=[];this.originalHeads=["a".repeat(32),"b".repeat(32)];
    this.config={settings:{partition_test:"B intent",onlyB:true},devices:{node_a:{name:"Node A"},node_b:{name:"Node B"}}};
    this.conflict={entity:"settings",state:"unresolved",heads:this.originalHeads.slice(),effective_exists:true,
      effective:clone(this.config.settings),effective_requires_reentry:false,candidates:[
        {change_id:this.originalHeads[0],author_node:"node_a",parents:["d".repeat(32)],base_entity_version:"base",ops:[{op:"set",key:"settings.partition_test",value:"A intent"}],candidate_exists:true,candidate:{partition_test:"A intent",onlyA:true},requires_reentry:false,is_head:true},
        {change_id:this.originalHeads[1],author_node:"node_b",parents:["d".repeat(32)],base_entity_version:"base",ops:[{op:"set",key:"settings.partition_test",value:"B intent"}],candidate_exists:true,candidate:{partition_test:"B intent",onlyB:true},requires_reentry:false,is_head:true}]};
  };
  fixture.reset();
  window.XMLHttpRequest=function(){
    this.headers={};this.open=(method,url)=>{this.method=method;this.url=url;};this.setRequestHeader=(k,v)=>this.headers[k]=v;
    this.respond=(status,body)=>{this.status=status;this.responseText=JSON.stringify(body);this.readyState=4;if(this.onreadystatechange)this.onreadystatechange();};
    this.abort=()=>{this.status=0;if(this.onabort)this.onabort();};
    this.send=body=>{this.body=body;fixture.requests.push(this);const data=body?JSON.parse(body):{};
      if(this.url.startsWith("/locale/"))return this.respond(200,dictionary);
      if(this.url==="/api/config/snapshot")return this.respond(200,{schema_version:2,revision:"revision-"+fixture.version,config:clone(fixture.config),edit_conflicts:(fixture.conflict?[clone(fixture.conflict)]:[]).concat(clone(fixture.extraConflicts)),edit_journal:{capacity_available:fixture.capacity}});
      if(this.url==="/api/config/commit"){
        if(fixture.hold)return;
        if(data.expected_revision!=="revision-"+fixture.version)return this.respond(409,{ok:false,error_code:"config_conflict"});
        if(!fixture.conflict||JSON.stringify(data.resolves.settings)!==JSON.stringify(fixture.conflict.heads))return this.respond(409,{ok:false,error_code:"stale_config_resolution"});
        const operation=data.ops[0];if(operation.op==="delete")delete fixture.config.settings;else fixture.config.settings=clone(operation.value);
        fixture.version++;fixture.conflict=null;return this.respond(200,{ok:true,revision:"revision-"+fixture.version});
      }
      if(this.url==="/api/status")return this.respond(200,{node:{id:"fixture"},features:{config_cas_v1:true},doors:{}});
      this.respond(200,{ok:true,csrf_token:"fixture-only"});
    };
  };
}
const server=http.createServer((req,res)=>{
  const url=new URL(req.url,"http://127.0.0.1");
  if(req.method==="POST"&&url.pathname==="/results"){
    let body="";req.on("data",chunk=>body+=chunk);req.on("end",()=>{const result=JSON.parse(body);fs.writeFileSync(path.join(evidence,"controlled-browser.json"),JSON.stringify(result,null,2)+"\n");res.end("Recorded");console.log(JSON.stringify(result));});return;
  }
  if(url.pathname==="/app.js"){
    res.writeHead(200,{"Content-Type":"application/javascript","Cache-Control":"no-store"});
    res.end(app.replace("pairAct: pairAct","pairAct: pairAct, refreshConfig: refreshConfig"));return;
  }
  if(url.pathname==="/"){
    const dict=fs.readFileSync(path.join(root,"webui/locale/en.json"),"utf8");
    let html=fs.readFileSync(path.join(root,"webui/admin/index.html"),"utf8");
    const setup='<script>('+bootstrap.toString()+')('+dict+');</script>';
    const controls=`<section style="position:fixed;bottom:0;left:0;z-index:100;background:white;color:black;max-height:40vh;overflow:auto"><button id="runPartitionTests">Run partition conflict tests</button><button id="showPartitionPreview">Show partition conflict preview</button><pre id="partitionResults"></pre></section><script>${cases}\ndocument.getElementById("runPartitionTests").onclick=async function(){const result={scope:"production DOM with controlled XHR; not Core HTTP end-to-end",source_sha256:${JSON.stringify(sha(app))},case_sha256:${JSON.stringify(sha(cases))},user_agent:navigator.userAgent,recorded_at:new Date().toISOString(),results:await runAdminPartitionConflictTests()};document.getElementById("partitionResults").textContent=JSON.stringify(result,null,2);fetch("/results",{method:"POST",body:JSON.stringify(result)});};document.getElementById("showPartitionPreview").onclick=function(){document.getElementById("partitionResults").textContent="";const f=window.adminPartitionFixture,h=window.__DOORBELL_TEST_HOOKS.adminRuntime;f.reset();h.refreshConfig();document.querySelector("[data-edit-conflict]").click();};</script>`;
    html=html.replace('<script src="/panel/playback.js">',setup+'<script src="/panel/playback.js">').replace('</body>',controls+'</body>');
    res.writeHead(200,{"Content-Type":"text/html","Cache-Control":"no-store"});res.end(html);return;
  }
  let file=path.resolve(root,"webui",url.pathname.replace(/^\//,""));if(url.pathname==="/style.css")file=path.join(root,"webui/admin/style.css");
  if(!file.startsWith(path.join(root,"webui")+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{"Content-Type":file.endsWith("css")?"text/css":"application/javascript"});res.end(fs.readFileSync(file));
});
server.listen(18768,"127.0.0.1",()=>console.log("T28 controlled fixture: http://127.0.0.1:18768/"));
