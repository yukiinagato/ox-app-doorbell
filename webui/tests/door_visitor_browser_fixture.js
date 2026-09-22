"use strict";
const fs=require("fs"),path=require("path"),http=require("http"),crypto=require("crypto");
const root=path.resolve(__dirname,"../.."),evidence=path.join(root,"verification/remediation-q01-q18/T35-Web/evidence");
const sha=value=>crypto.createHash("sha256").update(value).digest("hex");
function setup(catalogs,manifest) {
  const query=new URLSearchParams(location.search),clone=value=>JSON.parse(JSON.stringify(value));
  const lang=query.get("lang")||"en",large=query.get("large")==="1",long=query.get("long")==="1";
  sessionStorage.removeItem("doorbell.sos.operation.v2");
  const f=window.doorVisitorFixture={requests:[],down:false,sequence:0};
  const doorLabel=long?(lang==="zh"?"西侧花园与包裹接收处访客入口":"West garden and parcel reception visitor entrance"):(lang==="zh"?"正门":"Front door");
  f.state={call_flow:query.get("flow")||"purpose_first",doors:[{id:"front",label:doorLabel,visitor_lang:lang,calling:false}],
    purposes:[{id:"delivery",icon:"",label:{en:long?"Delivery requiring a resident to receive an oversized parcel":"Delivery",zh:long?"需要住户签收的大型包裹配送服务":"配送"}},
      {id:"visit",icon:"",label:{en:"Visiting a resident",zh:"拜访住户"}}],events:[],emergency:{active:false},server_ts:1,
    web_ui:{device_id:"isolated-visitor-fixture",manifest:manifest,elements:{}}};
  if(large)for(const id of Object.keys(manifest.elements))f.state.web_ui.elements[id]={font_scale:1.5};
  f.setCall=function(state){const d=this.state.doors[0];d.call_state=state;d.stage_revision=(d.stage_revision||0)+1;d.calling=["ringing","purpose_pending","answered","in_call"].includes(state);};
  window.XMLHttpRequest=function(){
    this.headers={};this.open=(method,url)=>{this.method=method;this.url=url;};this.setRequestHeader=(k,v)=>this.headers[k]=v;
    this.abort=()=>{this.aborted=true;if(this.onabort)this.onabort();};
    this.respond=(status,body)=>{if(this.aborted)return;this.status=status;this.responseText=JSON.stringify(body);this.readyState=4;if(this.onreadystatechange)this.onreadystatechange();if(this.onload)this.onload();};
    this.send=body=>{this.body=body;f.requests.push(this);setTimeout(()=>{
      if(this.url.startsWith("/locale/"))return this.respond(200,catalogs[this.url.split("/").pop().split(".")[0]]||catalogs.en);
      if(this.url.startsWith("/api/panel/state"))return this.respond(f.down?503:200,clone(f.state));
      if(this.url==="/api/panel/session")return this.respond(200,{ok:true,csrf_token:"c".repeat(32)});
      const values=new URLSearchParams(body||""),d=f.state.doors[0];
      if(this.url==="/api/panel/press"){
        d.call_id="fixture-call-"+(++f.sequence);d.stage_revision=1;d.expires_at_ms=Date.now()+60000;
        d.calling=true;d.call_state=f.state.call_flow==="ring_then_purpose"?"purpose_pending":"ringing";
        return this.respond(200,{ok:true,call_id:d.call_id,call_state:d.call_state,stage_revision:d.stage_revision,expires_at_ms:d.expires_at_ms});
      }
      if(this.url==="/api/panel/purpose"){
        if(["answered","in_call"].includes(d.call_state))return this.respond(409,{ok:false,err:"not_permitted"});
        f.setCall("ringing");return this.respond(200,{ok:true,call_id:d.call_id,stage_revision:d.stage_revision});
      }
      if(this.url==="/api/panel/cancel"||this.url==="/api/panel/hangup"){
        const ending=this.url.endsWith("hangup");
        if(!ending&&["answered","in_call"].includes(d.call_state))return this.respond(409,{ok:false,err:"not_permitted"});
        if(values.get("call_id")!==d.call_id)return this.respond(409,{ok:false,err:"wrong_call"});
        f.setCall(ending?"ended":"cancelled");return this.respond(200,{ok:true,call_id:d.call_id});
      }
      if(this.url==="/api/operations/prepare")return this.respond(200,{schema_version:2,ok:true,operation_id:"a".repeat(32),authority_node:"b".repeat(32),execution_state:"prepared",config_generation:"fixture",prepared_remaining_ms:30000});
      if(this.url.startsWith("/api/operations/"))return this.respond(200,{schema_version:2,ok:true,operation_id:"a".repeat(32),authority_node:"b".repeat(32),execution_state:"dispatched",config_generation:"fixture",prepared_remaining_ms:25000});
      this.respond(200,{ok:true});
    },0);};
  };
}
const server=http.createServer((req,res)=>{
  const url=new URL(req.url,"http://127.0.0.1"),phase=["baseline","final"].includes(url.searchParams.get("phase"))?url.searchParams.get("phase"):"candidate";
  const sourceRoot=phase==="baseline"?path.join(root,"build/remediation-t35-web-20260923/baseline"):phase==="final"?path.join(root,"build/remediation-t35-web-20260923/final-source-r7"):root;
  if(req.method==="POST"&&url.pathname==="/results"){
    let body="";req.on("data",chunk=>body+=chunk);req.on("end",()=>{const result=JSON.parse(body);fs.writeFileSync(path.join(evidence,phase+"-browser.json"),JSON.stringify(result,null,2)+"\n");res.end("Recorded");console.log(JSON.stringify(result));});return;
  }
  if(url.pathname==="/door.html"){
    const catalogs={};for(const lang of ["en","ja","zh"])catalogs[lang]=JSON.parse(fs.readFileSync(path.join(sourceRoot,"webui/locale/"+lang+".json"),"utf8"));
    const node=fs.readFileSync(path.join(sourceRoot,"core/src/node/node.cpp"),"utf8");
    const manifest=JSON.parse(node.match(/const char\* baseWebUiManifestJson\(\) \{\s*return R"\(([^\n]+)\)";/)[1]);
    Object.assign(manifest.elements,JSON.parse(node.match(/const char\* webOnlyUiElementsJson\(\) \{\s*return R"\(([^\n]+)\)";/)[1]));
    const page=fs.readFileSync(path.join(sourceRoot,"webui/panel/door.html"),"utf8");
    const bootstrap='<script>('+setup.toString()+')('+JSON.stringify(catalogs)+','+JSON.stringify(manifest)+');</script>';
    res.writeHead(200,{"Content-Type":"text/html","Cache-Control":"no-store"});res.end(page.replace('<script src="/panel/runtime.js">',bootstrap+'<script src="/panel/runtime.js">').replace(/src="(\/panel\/[^"?]+)"/g,'src="$1?phase='+phase+'"'));return;
  }
  if(url.pathname==="/"){
    const page=fs.readFileSync(path.join(sourceRoot,"webui/panel/door.html"),"utf8"),cases=fs.readFileSync(path.join(phase==="final"?path.join(sourceRoot,"webui/tests"):__dirname,"door_visitor_cases.js"),"utf8");
    res.writeHead(200,{"Content-Type":"text/html","Cache-Control":"no-store"});res.end(`<!doctype html><meta charset="utf-8"><title>Visitor UI verification</title><button id="run">Run visitor checks</button><pre id="results"></pre><div id="frames"></div><script>${cases}\ndocument.getElementById('run').onclick=async function(){this.disabled=true;const result={scope:'Production DOM and callbacks with controlled XHR; not Core/device qualification',phase:${JSON.stringify(phase)},door_sha256:${JSON.stringify(sha(page))},case_sha256:${JSON.stringify(sha(cases))},user_agent:navigator.userAgent,recorded_at:new Date().toISOString(),results:await runDoorVisitorChecks(${JSON.stringify(phase)})};document.getElementById('results').textContent=JSON.stringify(result,null,2);fetch('/results?phase=${phase}',{method:'POST',body:JSON.stringify(result)});this.disabled=false;};</script>`);return;
  }
  const file=path.resolve(sourceRoot,"webui",url.pathname.replace(/^\//,""));
  if(!file.startsWith(path.join(sourceRoot,"webui")+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{"Content-Type":"application/javascript","Cache-Control":"no-store"});res.end(fs.readFileSync(file));
});
server.listen(18769,"127.0.0.1",()=>console.log("Visitor UI fixture: http://127.0.0.1:18769/"));
