"use strict";
function runAdminConflictTests(){
 const hooks=window.__DOORBELL_TEST_HOOKS.adminRuntime,f=window.adminConflictFixture,results=[],$=s=>document.querySelector(s);
 const assert=(v,m)=>{if(!v)throw Error(m);};
 const saves=()=>f.requests.filter(r=>r.url==="/api/config/commit"||r.url==="/api/config/batch");
 function start(){f.reset();hooks.refreshConfig();hooks.editBuilding("b_fixture");f.requests.length=0;$("[data-f='en']").value="Mine";}
 function test(id,body){try{start();body();results.push({id,status:"PASS"});}catch(e){results.push({id,status:"FAIL",message:e.message});}}
 test("T27-01",()=>{f.change(c=>c.buildings.b_fixture.notifications=false);$("#mSave").onclick();assert(f.config.buildings.b_fixture.label.en==="Mine","Name edit lost");assert(f.config.buildings.b_fixture.notifications===false,"Old whole object overwrote concurrent notification change");assert(saves().every(r=>r.url.endsWith("commit")&&JSON.parse(r.body).expected_revision),"Save bypassed CAS");});
 test("T27-02",()=>{f.change(c=>c.buildings.b_fixture.label.en="Theirs");$("#mSave").onclick();assert(f.config.buildings.b_fixture.label.en==="Theirs","Conflicting field silently overwritten");assert($("[data-config-conflict]"),"No visible three-way choice");assert(!$("#modal").classList.contains("hidden")&&$("[data-f='en']").value==="Mine","Conflict lost original draft");});
 test("T27-03",()=>{$("#mSave").onclick();const value=f.config.buildings.b_fixture;assert(value.future.nullable===null&&value.future.array.join(",")==="1,2","Unknown/null fields changed");const ops=JSON.parse(saves()[0].body).ops;assert(ops.length===1&&JSON.stringify(ops).indexOf("future")===-1&&JSON.stringify(ops).indexOf("notifications")===-1,"Preview/write includes untouched fields");});
 test("T27-04",()=>{f.change(c=>c.buildings.b_fixture.label.en="Theirs");$("#mSave").onclick();const choice=$("[data-conflict-choice='mine']");assert(choice,"Conflict choice absent");choice.checked=true;f.change(c=>c.buildings.b_fixture.label.en="Newer");$("[data-conflict-submit]").onclick();assert(f.config.buildings.b_fixture.label.en==="Newer","Resolution overwrote a newer revision without another comparison");assert($("[data-config-conflict]").textContent.indexOf("Newer")>=0,"Latest value not shown after second conflict");assert(saves().length<=3,"Conflict caused an unbounded automatic retry");});
 test("Login restoration compares the retained base",()=>{
   f.hold=true;$("#mSave").onclick();const old=saves()[0];old.respond(401,{ok:false});
   assert($("#modal").classList.contains("hidden"),"Login was covered by draft");
   f.change(c=>c.buildings.b_fixture.label.en="Changed during login");f.hold=false;$("#pw").value="fixture-only";$("#loginBtn").onclick();
   assert(!$("#modal").classList.contains("hidden")&&$("[data-f='en']").value==="Mine","Login lost draft");
   $("#mSave").onclick();assert($("[data-config-conflict]"),"Restored draft skipped three-way compare");
   old.respond(200,{ok:true});assert($("[data-config-conflict]"),"Old login-generation response removed conflict");
   assert(f.config.buildings.b_fixture.label.en==="Changed during login","Restored draft overwrote current value");
 });
 test("Array edits require a whole-array decision",()=>{
   f.change(c=>c.notice={presets:[{id:"one",text:"One"}]});hooks.refreshConfig();hooks.addNoticePreset();$("[data-f='text']").value="Mine";
   f.change(c=>c.notice.presets.push({id:"two",text:"Theirs"}));$("#mSave").onclick();
   assert($("[data-config-conflict]"),"Unidentified array entries were guessed/overwritten");assert(f.config.notice.presets.length===2,"Array conflict wrote without a choice");
   $("[data-conflict-choice='current']").checked=true;$("[data-conflict-submit]").onclick();
   assert(f.config.notice.presets.length===2&&$("#modal").classList.contains("hidden"),"Keep-current choice failed");
 });
 test("Unselected conflicts retain completed choices",()=>{
   $("[data-f='ja']").value="Mine Japanese";f.change(c=>{c.buildings.b_fixture.label.en="Their English";c.buildings.b_fixture.label.ja="Their Japanese";});$("#mSave").onclick();
   const choices=document.querySelectorAll("[data-conflict-choice='mine']");assert(choices.length===2,"Expected two changed fields");choices[0].checked=true;const count=saves().length;$("[data-conflict-submit]").onclick();
   assert(choices[0].checked&&saves().length===count,"Incomplete conflict choice reset selections or wrote");
 });
 test("Inline settings capture the rendered revision",()=>{
   $("#mCancel").onclick();hooks.switchTab("system");const input=$("#webSosEnabled");assert(input,"Real inline setting missing");input.checked=true;
   f.change(c=>c.buildings.b_fixture.label.en="Concurrent name");$("#webSosSave").onclick();
   assert(f.config.buildings.b_fixture.label.en==="Concurrent name"&&f.config.emergency.web_active_page_alerts===true,"Inline setting lost concurrent changes");
   assert(saves().every(r=>r.url.endsWith("commit")),"Inline setting retained a legacy write path");
 });
 test("Notice expiry is stamped only by Core",()=>{
   hooks.editDoorNotice("A");$("#noticeText").value="Notice draft";$("#noticeExpiry").value="today";
   f.change(c=>c.buildings.b_fixture.notifications=false);$("#mSave").onclick();
   const requests=f.requests.filter(r=>r.method==="POST"&&r.url==="/api/doors/A/notice");
   assert(requests.length===2,"Notice did not retry through revision comparison");
   assert(requests.every(r=>{const b=JSON.parse(r.body);return b.expected_revision&&b.expiry==="today"&&!("expires_ms"in b)&&!("created_ms"in b);}),"Notice generated a client wall timestamp");
 });
 test("Clearing a known field is an explicit delete",()=>{
   f.change(c=>c.doors.A.unlock={command:"open_a",show_button:true,future:null});hooks.refreshConfig();hooks.editDoorUnlock("A");
   $("[data-f='mode']").value="hide";$("[data-f='command']").value="";$("#mSave").onclick();
   const value=f.config.doors.A.unlock;assert(!("command"in value)&&value.show_button===false&&value.future===null,"Clearing a field was treated as omission or lost unknown fields");
   const payload=JSON.parse(saves()[0].body);assert(payload.ops.some(op=>op.op==="delete"&&op.key.endsWith("command")),"Delete intent was not explicit");
 });
 test("Semantic reset and edit share one conditional commit",()=>{
   f.change(c=>c.devices={fixture:{role:"door_station",door:"A",local:{ui:{elements:{call:{primary:{scale:1.2,radius:10}}}}}}});
   hooks.refreshConfig();hooks.editDeviceUi("fixture");
   const scale=$("[data-ui-row][data-element='call.primary'][data-property='scale']"),radius=$("[data-ui-row][data-element='call.primary'][data-property='radius']");
   assert(scale&&radius,"Real semantic UI controls unavailable");scale.querySelector("[data-ui-value]").value="1.5";radius.querySelector("[data-ui-on]").checked=false;$("#mSave").onclick();
   const value=f.config.devices.fixture.local.ui.elements.call.primary;
   assert(value.scale===1.5&&!("radius"in value),"Mixed semantic reset did not apply");
   const requests=saves();assert(requests.length===1,"Semantic reset split the transaction");const op=JSON.parse(requests[0].body).ops[0];
   assert(op.remove_fields.length===1&&op.remove_fields[0]==="radius"&&op.value.scale===1.5,"Semantic removal omitted explicit intent");
 });
 test("Inline login restoration preserves the original base",()=>{
   $("#mCancel").onclick();hooks.switchTab("system");const input=$("#webSosEnabled");input.checked=false;
   f.hold=true;$("#webSosSave").onclick();const old=saves()[0];assert(old,"Inline save did not start");old.respond(401,{ok:false});
   f.change(c=>c.buildings.b_fixture.label.en="During sign-in");f.hold=false;$("#pw").value="fixture-only";$("#loginBtn").onclick();
   assert(input.isConnected&&input.checked===false&&!$("#tab-system").classList.contains("hidden"),"Inline sign-in discarded or hid non-sensitive controls");
   $("#webSosSave").onclick();assert(f.config.emergency.web_active_page_alerts===false&&f.config.buildings.b_fixture.label.en==="During sign-in","Inline restored draft bypassed comparison");
 });
 return results;
}
