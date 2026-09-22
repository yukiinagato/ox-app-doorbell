"use strict";
async function runAdminPartitionConflictTests() {
  const hooks=window.__DOORBELL_TEST_HOOKS.adminRuntime, f=window.adminPartitionFixture;
  const $=s=>document.querySelector(s), results=[];
  const assert=(v,m)=>{if(!v)throw Error(m);};
  const saves=()=>f.requests.filter(r=>r.url==="/api/config/commit");
  const save=()=>$("#mSave").onclick();
  const choice=v=>{$("[data-edit-choice]").value=v;};
  function start(){f.reset();hooks.refreshConfig();$("[data-edit-conflict]").click();f.requests.length=0;}
  function test(id,body){try{start();body();results.push({id,status:"PASS"});}catch(error){results.push({id,status:"FAIL",message:error.message});}}
  test("Partition banner exposes the effective value and both candidate intents",()=>{
    assert(!$("#configConflicts").classList.contains("hidden"),"Banner hidden");
    assert($("[data-edit-candidates]").textContent.includes("A intent")&&$("[data-edit-candidates]").textContent.includes("B intent"),"Candidate missing");
    save();assert(saves().length===0,"An implicit choice wrote configuration");
  });
  test("Resolution choice has an accessible name",()=>{
    assert($("[data-edit-choice]").getAttribute("aria-label")==="Choose the settings to keep","Resolution selector has no accessible name");
  });
  test("Explicit effective choice sends the exact revision and all current heads",()=>{
    choice("current");save();const p=JSON.parse(saves()[0].body);
    assert(p.schema_version===2&&p.expected_revision==="revision-"+f.originalVersion,"Revision absent");
    assert(p.ops.length===1&&p.ops[0].key==="settings"&&p.ops[0].op==="set","Entity operation incorrect");
    assert(JSON.stringify(p.resolves.settings)===JSON.stringify(f.originalHeads),"Resolution did not reference every head");
    assert(p.ops[0].value.partition_test==="B intent","Effective value not selected");
  });
  test("Head selection sends its full candidate rather than the LWW winner",()=>{
    choice(f.originalHeads[0]);save();const p=JSON.parse(saves()[0].body);
    assert(p.ops[0].value.partition_test==="A intent"&&p.ops[0].value.onlyA===true,"Wrong candidate");
    assert(!("onlyB" in f.config.settings),"Losing fields silently merged into resolution");
  });
  test("Sensitive candidates cannot be restored by current or head choice",()=>{
    f.conflict.effective_requires_reentry=true;f.conflict.candidates[0].requires_reentry=true;
    hooks.refreshConfig();$("[data-edit-conflict]").click();f.requests.length=0;
    choice("current");save();assert(saves().length===0,"Redacted effective value submitted");
    choice(f.originalHeads[0]);save();assert(saves().length===0,"Redacted candidate submitted");
  });
  test("Refresh preserves custom JSON and updates revision and every resolution head",()=>{
    choice("custom");$("[data-edit-value]").value='{"partition_test":"manual draft"}';
    f.version++;f.conflict.heads.push("c".repeat(32));
    $("[data-edit-refresh]").click();
    assert($("[data-edit-choice]").value==="custom"&&$("[data-edit-value]").value.includes("manual draft"),"Refresh discarded manual draft");
    save();const p=JSON.parse(saves()[0].body);
    assert(p.expected_revision==="revision-"+(f.version-1)&&p.resolves.settings.length===3,"Refresh used stale identity");
  });
  test("409 remains visible and never automatically overwrites the newer heads",()=>{
    choice(f.originalHeads[0]);f.version++;f.conflict.heads.push("c".repeat(32));save();
    assert(saves().length===1&&!$("#modal").classList.contains("hidden"),"Conflict auto-resubmitted or dismissed");
    assert(f.config.settings.partition_test==="B intent","409 overwrote current configuration");
    assert($("#mSaveState").textContent.length>0,"Conflict not explained");
  });
  test("401 retains non-sensitive choice but clears arbitrary custom JSON",()=>{
    choice("custom");$("[data-edit-value]").value='{"password":"synthetic fixture value"}';
    f.hold=true;save();const old=saves()[0];old.respond(401,{ok:false,error_code:"unauthorized"});
    assert($("#modal").classList.contains("hidden"),"Expired auth concealed sign-in");
    assert($("[data-edit-value]").value==="","Sensitive custom JSON retained");
    f.hold=false;$("#pw").value="fixture-only";$("#loginBtn").onclick();
    assert(!$("#modal").classList.contains("hidden")&&$("[data-edit-choice]").value==="custom","Non-sensitive selection lost");
    old.respond(200,{ok:true});assert(!$("#modal").classList.contains("hidden"),"Old response closed restored draft");
    save();assert(saves().length===1,"Empty cleared JSON was silently resubmitted");
  });
  test("Invalid custom JSON cannot create a resolution",()=>{
    choice("custom");$("[data-edit-value]").value="{";save();assert(saves().length===0,"Invalid JSON sent");
  });
  test("Custom entity deletion is explicit and references the candidate heads",()=>{
    choice("custom");$("[data-edit-delete]").checked=true;save();const p=JSON.parse(saves()[0].body);
    assert(p.ops[0].op==="delete"&&!Object.prototype.hasOwnProperty.call(p.ops[0],"value")&&p.resolves.settings.length===2,"Deletion intent incorrect");
  });
  test("Deleted candidate produces a delete rather than a null set",()=>{
    f.conflict.candidates[0].candidate_exists=false;f.conflict.candidates[0].candidate=null;
    hooks.refreshConfig();$("[data-edit-conflict]").click();f.requests.length=0;choice(f.originalHeads[0]);save();
    assert(JSON.parse(saves()[0].body).ops[0].op==="delete","Deleted candidate restored as null");
  });
  test("Candidate strings are rendered as text",()=>{
    f.conflict.candidates[0].candidate.partition_test="<img src=x onerror='window.partitionInjected=true'>";
    hooks.refreshConfig();$("[data-edit-conflict]").click();
    assert(!$("[data-edit-candidates] img")&&!window.partitionInjected,"Candidate executed markup");
  });
  test("History capacity is visible without inventing an unresolved candidate",()=>{
    f.conflict=null;f.capacity=false;hooks.refreshConfig();
    assert(!$("#configConflicts").classList.contains("hidden"),"Capacity warning hidden");
    assert(!$("[data-edit-conflict]"),"Invented conflict button");
  });
  try {
    start();choice("custom");$('[data-edit-value]').value='{"partition_test":"draft during polling"}';
    const remote=JSON.parse(JSON.stringify(f.conflict));f.conflict=null;hooks.refreshConfig();
    f.conflict=remote;f.version++;f.requests.length=0;
    const deadline=Date.now()+6500;
    while(Date.now()<deadline&&$('#configConflicts').classList.contains('hidden')) await new Promise(resolve=>setTimeout(resolve,50));
    assert(!$('#configConflicts').classList.contains('hidden'),"An open page did not discover the new remote conflict");
    assert($('[data-edit-value]').value==='{"partition_test":"draft during polling"}',"Polling overwrote the open custom draft");
    assert(saves().length===0,"Polling automatically submitted a resolution");
    results.push({id:"Open page discovers remote conflicts without replacing an editor draft",status:"PASS"});
  } catch(error) {
    results.push({id:"Open page discovers remote conflicts without replacing an editor draft",status:"FAIL",message:error.message});
  }
  try {
    start();$("#mCancel").click();
    let review=$('[data-edit-conflict]');review.focus();f.requests.length=0;
    async function nextSnapshot() {
      const before=f.requests.filter(r=>r.url==='/api/config/snapshot').length,deadline=Date.now()+6500;
      while(Date.now()<deadline&&f.requests.filter(r=>r.url==='/api/config/snapshot').length===before)
        await new Promise(resolve=>setTimeout(resolve,50));
      assert(f.requests.filter(r=>r.url==='/api/config/snapshot').length>before,"Background snapshot did not arrive");
    }
    await nextSnapshot();
    assert(document.activeElement===review,"Unchanged snapshot removed keyboard focus from Review");
    f.version++;f.conflict.heads.push('e'.repeat(32));
    await nextSnapshot();
    review=$('[data-edit-conflict]');
    assert(document.activeElement===review,"Changed heads removed Review focus");
    review.click();choice('current');f.hold=true;f.requests.length=0;save();
    const pending=saves()[0],posted=JSON.parse(pending.body);
    assert(posted.resolves.settings.length===3&&posted.resolves.settings.includes('e'.repeat(32)),"Retained button used obsolete candidate heads");
    f.hold=false;pending.respond(409,{ok:false,error_code:'stale_config_resolution'});$("#mCancel").click();review.focus();
    f.extraConflicts=[{entity:'doors.front',state:'unresolved',heads:['f'.repeat(32)],effective_exists:true,effective:{},effective_requires_reentry:false,candidates:[]}];
    await nextSnapshot();
    assert(document.activeElement===$('[data-edit-conflict]'),"Changed banner did not restore Review focus by entity");
    results.push({id:"Background snapshots preserve Review keyboard focus and use current heads",status:"PASS"});
  } catch(error) {
    results.push({id:"Background snapshots preserve Review keyboard focus and use current heads",status:"FAIL",message:error.message});
  }
  return results;
}
