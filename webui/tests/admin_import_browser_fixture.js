"use strict";
const fs=require('fs'),path=require('path'),http=require('http'),crypto=require('crypto');
const root=path.resolve(process.env.IMPORT_SOURCE_ROOT||path.join(__dirname,'../..'));
const evidence=path.resolve(process.env.IMPORT_EVIDENCE||path.join(root,'verification/remediation-q01-q18/T30/evidence'));
fs.mkdirSync(evidence,{recursive:true});
const app=fs.readFileSync(path.join(root,'webui/admin/app.js'),'utf8'),cases=fs.readFileSync(path.join(__dirname,'admin_import_cases.js'),'utf8');
const sha=s=>crypto.createHash('sha256').update(s).digest('hex');
function bootstrap(dictionary){
  window.__DOORBELL_TEST_HOOKS={};
  const clone=v=>JSON.parse(JSON.stringify(v)), f=window.adminImportFixture={requests:[],config:{settings:{keep:'existing'}},version:1,mode:'normal',receipts:{}};
  if(!new URL(location.href).searchParams.has('recover'))sessionStorage.removeItem('doorbell.admin.import.v2');
  const nativeCreate=URL.createObjectURL;URL.createObjectURL=function(blob){f.exportBlob=blob;return nativeCreate.call(URL,blob);};
  const nativeClick=HTMLAnchorElement.prototype.click;HTMLAnchorElement.prototype.click=function(){if(this.download){f.download=this.download;return;}return nativeClick.call(this);};
  f.failHeld=function(code,body){const r=f.held;f.held=null;r.respond(code,body);};
  f.timeoutHeld=function(){const r=f.held;f.held=null;if(r.ontimeout)r.ontimeout();};
  window.XMLHttpRequest=function(){
    this.headers={};this.open=(method,url)=>{this.method=method;this.url=url;};this.setRequestHeader=(k,v)=>this.headers[k]=v;
    this.respond=(code,body)=>{this.status=code;this.responseText=JSON.stringify(body);this.readyState=4;if(this.onreadystatechange)this.onreadystatechange();};
    this.abort=()=>{this.status=0;if(this.onabort)this.onabort();};
    this.send=body=>{this.body=body;f.requests.push(this);setTimeout(()=>{
      const data=body?JSON.parse(body):{};
      if(this.url.startsWith('/locale/'))return this.respond(200,dictionary);
      if(this.url==='/api/status')return this.respond(200,{node:{id:'import-fixture',version:'test'},features:{config_cas_v1:true},doors:{},peers:[{id:'peer-one',status:'alive'},{id:'peer-two',status:'dead'}]});
      if(this.url==='/api/config/snapshot')return this.respond(200,{schema_version:2,revision:'revision-'+f.version,config:clone(f.config),edit_conflicts:[]});
      if(this.url.startsWith('/api/config/import/')){
        const action=this.url.split('/').pop();
        if(f.mode==='stage-conflict'&&action==='stage')return this.respond(409,{error_code:'config_conflict'});
        if(action==='stage'){
          f.stage=clone(data);f.token='a'.repeat(32);f.digest='b'.repeat(64);
          return this.respond(200,{ok:true,schema_version:2,stage_token:f.token,digest:f.digest,expected_revision:data.expected_revision,expires_in_ms:600000});
        }
        if(action==='preflight'){
          const diff=[];function leaves(obj,prefix,out){for(const k of Object.keys(obj)){const p=prefix+'/'+k,v=obj[k];if(v&&typeof v==='object'&&!Array.isArray(v))leaves(v,p,out);else out[p]=v;}}
          const old={},next={};leaves(f.config,'',old);leaves(f.stage.document.config,'',next);
          for(const p of new Set([...Object.keys(old),...Object.keys(next)]))if(JSON.stringify(old[p])!==JSON.stringify(next[p]))diff.push({path:p,op:p in next?'set':'delete',before:old[p],after:next[p]});
          const missing=f.mode==='missing-secret'?['secret:mqtt.restore']:[],assets=f.mode==='missing-asset'?['fixture-asset']:[];
          return this.respond(200,{ok:true,schema_version:2,stage_token:f.token,digest:f.mode==='wrong-digest'?'c'.repeat(64):f.digest,expected_revision:f.stage.expected_revision,atomicity:'local_persistence',can_commit:!missing.length&&!assets.length,differences:diff,expanded_leaf_mutations:diff.length,missing_secret_refs:missing,missing_assets:assets,problems:[]});
        }
        if(action==='commit'){
          if(f.mode==='auth-loss'){f.held=this;return;}
          f.config=clone(f.stage.document.config);f.version++;
          const result={ok:true,schema_version:2,operation_id:data.operation_id,digest:data.digest,committed_revision:'revision-'+f.version,atomicity:'local_persistence',n:257};
          f.receipts[data.operation_id]=result;
          if(f.mode==='lost-reply'||f.mode==='query-missing'){f.held=this;return;}
          return this.respond(200,result);
        }
        if(action==='query'){
          const result=f.receipts[data.operation_id];return result&&f.mode!=='query-missing'?this.respond(200,{ok:true,schema_version:2,state:'committed',result:clone(result)}):this.respond(404,{ok:false,error_code:'operation_not_found'});
        }
        if(action==='cancel')return this.respond(200,{ok:true});
      }
      this.respond(200,{ok:true,csrf_token:'fixture-only',events:[]});
    },0);};
  };
}
const server=http.createServer((req,res)=>{
  const url=new URL(req.url,'http://127.0.0.1');
  if(req.method==='POST'&&url.pathname==='/results'){
    let body='';req.on('data',chunk=>body+=chunk);req.on('end',()=>{const result=JSON.parse(body);fs.writeFileSync(path.join(evidence,'controlled-browser.json'),JSON.stringify(result,null,2)+'\n');res.end('Recorded');console.log(JSON.stringify(result));});return;
  }
  if(url.pathname==='/app.js'){res.writeHead(200,{'Content-Type':'application/javascript','Cache-Control':'no-store'});res.end(app);return;}
  if(url.pathname==='/'){
    const dictionary=fs.readFileSync(path.join(root,'webui/locale/en.json'),'utf8');let html=fs.readFileSync(path.join(root,'webui/admin/index.html'),'utf8');
    html=html.replace('<script src="/panel/playback.js">','<script>('+bootstrap.toString()+')('+dictionary+');</script><script src="/panel/playback.js">');
    res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});res.end(html);return;
  }
  if(url.pathname==='/tests'){
    res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});res.end('<!doctype html><html lang="en"><title>T30 production import tests</title><button id="run">Run import tests</button><pre id="result"></pre><iframe id="subject" title="Production administration page" style="width:1100px;height:760px"></iframe><script>'+cases+'\ndocument.getElementById("run").onclick=async function(){this.disabled=true;const result={scope:"actual production DOM with controlled XHR; not Core HTTP end-to-end",source_sha256:'+JSON.stringify(sha(app))+',cases_sha256:'+JSON.stringify(sha(cases))+',recorded_at:new Date().toISOString(),user_agent:navigator.userAgent,results:await runAdminImportTests()};document.getElementById("result").textContent=JSON.stringify(result,null,2);await fetch("/results",{method:"POST",body:JSON.stringify(result)});this.disabled=false;};</script></html>');return;
  }
  let file=path.resolve(root,'webui',url.pathname.replace(/^\//,''));if(url.pathname==='/style.css')file=path.join(root,'webui/admin/style.css');
  if(!file.startsWith(path.join(root,'webui')+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'Content-Type':file.endsWith('.css')?'text/css':'application/javascript'});res.end(fs.readFileSync(file));
});server.listen(18770,'127.0.0.1',()=>console.log('T30 controlled fixture: http://127.0.0.1:18770/tests'));
