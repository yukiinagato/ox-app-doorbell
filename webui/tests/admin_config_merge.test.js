"use strict";
const assert=require("assert"),L=require("../admin/app.js");
const ops=(entries,dels)=>L.configBatchOps(entries,dels);
const base={settings:{name:"old",notify:true,unknown:{nullable:null},array:[1,2]}};
let changes=L.configIntents(base,ops([{key:"settings",value:{name:"mine"}}]));
assert.deepStrictEqual(L.configIntentOps(changes),[{op:"set",key:"settings",value:{name:"mine"}}]);
let merged=L.configRebase(changes,{settings:{name:"old",notify:false,unknown:{nullable:null}}});
assert.strictEqual(merged.conflicts.length,0); assert.strictEqual(merged.changes.length,1);
merged=L.configRebase(changes,{settings:{name:"theirs"}});
assert.strictEqual(merged.conflicts.length,1);assert.strictEqual(merged.conflicts[0].base,"old");
assert.strictEqual(L.configRebase(changes,{settings:{name:"mine"}}).changes.length,0);
changes=L.configIntents(base,ops([{key:"settings.unknown.nullable",value:null}]));assert.strictEqual(changes.length,0);
changes=L.configIntents(base,ops([],["settings.unknown.nullable"]));assert.strictEqual(changes[0].op,"delete");
assert.strictEqual(L.configRebase(changes,{settings:{unknown:{nullable:7}}}).conflicts.length,1);
assert.strictEqual(L.configRebase(changes,{settings:{unknown:{}}}).changes.length,0);
changes=L.configIntents(base,ops([{key:"settings.array",value:[1,3]}]));
assert.strictEqual(L.configRebase(changes,{settings:{array:[2,2]}}).conflicts.length,1);
assert.strictEqual(L.configComparisonValue("integrations.key", "private-value"),'"••••"');
assert.strictEqual(L.configComparisonValue("settings",{password:"private",name:"safe",nested:{token:"private"}}),'{"password":"••••","name":"safe","nested":{"token":"••••"}}');
assert.strictEqual(L.configComparisonValue("setting.ref","secret:private-ref"),'"••••"');
assert.strictEqual(L.configComparisonValue("setting",null),'null');
assert.strictEqual(L.configComparisonValue("setting",undefined),undefined);
assert.deepStrictEqual(L.noticeCommitPayload({text:"Hello",expiry:"1h"}),{body:{text:"Hello",ttl_s:3600}});
assert.deepStrictEqual(L.noticeCommitPayload({text:"Hello",expiry:"today"}),{body:{text:"Hello",expiry:"today"}});
assert.deepStrictEqual(L.noticeCommitPayload({text:"Hello",expiry:"until_cleared"}),{body:{text:"Hello",ttl_s:0}});
assert.deepStrictEqual(L.noticeCommitPayload({text:"Hello",expiry:"custom",custom_hours:"4"}),{body:{text:"Hello",ttl_s:14400}});
assert(L.noticeCommitPayload({text:"Hello",expiry:"custom",custom_hours:"NaN"}).error);
console.log("Typed config merge, array/delete/null and redaction tests: PASS");
changes=L.configIntents({settings:{existing:true}},ops([{key:"settings",value:{added:"mine"}}]));
assert.strictEqual(L.configRebase(changes,{settings:null}).conflicts.length,1,"Adding a field must not resurrect a concurrently removed container");
assert.throws(()=>L.configBatchOps([{key:"__proto__.unsafe",value:1}]),/invalid config path/);
const withDeletion={doors:{A:{label:{en:"Door",ja:"入口",extra:null},building:"B",unknown:5}}};
changes=L.configIntents(withDeletion,L.configBatchOps(L.doorEntries("A",{en:"Updated",ja:"",zh:"",building:""},withDeletion.doors.A)),true);
assert.deepStrictEqual(L.configIntentOps(changes),[
 {op:"set",key:"doors.A.label.en",value:"Updated"},
 {op:"delete",key:"doors.A.label.ja"},
 {op:"delete",key:"doors.A.building"}
]);
const semanticKey="devices.dev.local.ui.elements.call.primary";
const uiBase={devices:{dev:{local:{ui:{elements:{call:{primary:{scale:1.2,radius:10}}}}}}}};
changes=L.configIntents(uiBase,L.configBatchOps([{key:semanticKey,value:{scale:1.5}}]),true);
assert.deepStrictEqual(L.configIntentOps(changes),[{op:"set",key:semanticKey,value:{scale:1.5},remove_fields:["radius"]}]);
assert.strictEqual(L.configRebase(changes,{devices:{dev:{local:{ui:{elements:{call:{primary:{scale:1.2,radius:20}}}}}}}}).conflicts.length,1);

changes=L.configIntents({},ops([{key:"settings.added",value:"mine"}]));
assert.strictEqual(L.configRebase(changes,{settings:null}).conflicts.length,1,"Absent versus null ancestor must conflict");
changes=L.configIntents({settings:1},ops([{key:"settings.added",value:"mine"}]));
assert.strictEqual(L.configRebase(changes,{settings:2}).conflicts.length,1,"Different scalar ancestors must conflict");
changes=L.configIntents({settings:[1]},ops([{key:"settings.added",value:"mine"}]));
assert.strictEqual(L.configRebase(changes,{settings:[2]}).conflicts.length,1,"Different array ancestors must conflict");
