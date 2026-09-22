"use strict";
function runAdminModalTests() {
  const hooks = window.__DOORBELL_TEST_HOOKS.adminRuntime;
  const fixture = window.adminModalFixture;
  const results = [];
  const $ = selector => document.querySelector(selector);
  const assert = (ok, message) => { if (!ok) throw new Error(message); };
  const visible = element => !element.classList.contains("hidden");
  const writes = () => fixture.requests.filter(x => x.method !== "GET" && !x.completed);
  const answer = (request, status, result) => { request.respond(status, result); };
  function test(id, body) {
    writes().forEach(request => answer(request, 500, {ok:false}));
    if (visible($("#login"))) $("#loginBtn").onclick();
    fixture.requests.length = 0;
    try { body(); results.push({id, status:"PASS"}); }
    catch (error) { results.push({id, status:"FAIL", message:error.message}); }
  }
  test("T25-01", () => {
    hooks.editRule("r_complex");
    const modal = $("#modal"), field = modal.querySelector("[data-ra='target_extension']");
    modal.style.height = "300px"; modal.style.bottom = "auto";
    field.value = "9876"; field.focus(); modal.scrollTop = 120;
    const scroll = modal.scrollTop;
    const fields = Array.from(modal.querySelectorAll("input,select,textarea"));
    const before = fields.map(x => [x, x.value, x.checked]);
    $("#mSave").onclick(); assert(writes().length === 1, "Complex rule must issue one batch");
    answer(writes()[0], 500, {ok:false, err:"Controlled failure"});
    assert(visible(modal), "Failed save closed the complex rule editor");
    assert(before.every(x => x[0].isConnected && x[0].value === x[1] && x[0].checked === x[2]), "Failed save replaced or changed form fields");
    assert(document.activeElement === field, "Failed save lost the current field focus");
    assert(modal.scrollTop === scroll && scroll > 0, "Failed save lost nonzero scroll position: " + scroll + " -> " + modal.scrollTop);
    assert(fixture.requests.filter(x => x.url === "/api/config/snapshot").length === 0, "Failed save refreshed config over the draft");
  });
  test("T25-02", () => {
    hooks.editRule("r_complex"); $("#modal").querySelector("[data-ra='target_extension']").value="changed-target";
    const save = $("#mSave"); save.onclick(); save.onclick(); save.onclick();
    assert(writes().length === 1, "Repeated Save submitted the same form more than once");
    assert(save.disabled && $("#mCancel").disabled, "Submitting must prevent duplicate saves and accidental discard");
    assert(visible($("#modal")), "Slow save hid its draft");
    answer(writes()[0], 200, {ok:true});
    assert(!visible($("#modal")), "Confirmed successful save did not close its editor");
  });
  test("T25-03", () => {
    hooks.editSpeechSettings();
    const modal = $("#modal"), secret = modal.querySelector("[data-f='key']"), voice = modal.querySelector("[data-f='en']");
    secret.value = "sensitive-test-value"; voice.value = "retained-voice";
    $("#mSave").onclick(); const request = writes()[0]; assert(request && request.url === "/api/secrets", "Speech editor did not stage its credential");
    answer(request, 401, {ok:false});
    assert(!visible(modal), "Expired authorization left the editor covering login");
    assert(secret.value === "", "Expired authorization retained the plaintext secret");
    assert(voice.value === "retained-voice", "Authorization expiry discarded the non-sensitive draft");
    $("#pw").value = "fixture-login"; $("#loginBtn").onclick();
    assert(visible(modal), "Successful login did not restore the draft");
    assert(voice.isConnected && voice.value === "retained-voice" && secret.value === "", "Draft restoration lost fields or restored a secret");
    assert(!JSON.stringify(fixture.storageWrites).includes("sensitive-test-value"), "Plaintext secret entered local storage");
    request.respond(200, {ok:true});
    assert(visible(modal), "Late pre-login success closed the restored draft");
  });
  test("T25-04", () => {
    hooks.editRule("r_complex"); $("#modal").querySelector("[data-ra='target_extension']").value="changed-target"; $("#mSave").onclick(); const old = writes()[0];
    hooks.editBuilding("b_fixture");
    const modal = $("#modal"), field = modal.querySelector("[data-f='en']");
    field.value = "New editor draft"; field.focus();
    answer(old, 200, {ok:true});
    assert(visible(modal) && field.isConnected && field.value === "New editor draft", "Old save changed or closed the new editor");
    assert(document.activeElement === field, "Old save moved focus out of the new editor");
    assert(fixture.requests.filter(x => x.url === "/api/config/snapshot").length === 0, "Old save refreshed configuration underneath the new editor");
  });
  test("synchronous validation retains the editor without a request", () => {
    hooks.editSpeechSettings();
    const rate = $("#modal").querySelector("[data-f='rate']"); rate.value = "9";
    $("#mSave").onclick();
    assert(writes().length === 0, "Invalid rate sent a request");
    assert(visible($("#modal")) && !$("#mSave").disabled && rate.value === "9", "Validation error lost or locked the editor");
  });
  test("notice API failure retains its dedicated editor", () => {
    hooks.editDoorNotice("A"); $("#noticeText").value = "Retained notice";
    $("#mSave").onclick(); const request = writes()[0];
    assert(request.url === "/api/doors/A/notice", "Notice did not use its actual dedicated API");
    answer(request, 500, {ok:false});
    assert(visible($("#modal")) && $("#noticeText").value === "Retained notice", "Notice failure lost its input");
  });
  test("retrying a failed preset does not duplicate the draft", () => {
    hooks.addNoticePreset(); $("#modal").querySelector("[data-f='text']").value = "One preset";
    $("#mSave").onclick(); answer(writes()[0], 500, {ok:false}); $("#mSave").onclick();
    const body = JSON.parse(writes()[0].body);
    assert(body.ops[0].value.length === 1, "Failed preset retry duplicated the new row");
    answer(writes()[0], 200, {ok:true});
  });
  test("unknown secret config outcome does not delete a possibly live credential", () => {
    hooks.editSpeechSettings(); $("#modal").querySelector("[data-f='key']").value = "transient-test-secret";
    $("#mSave").onclick(); answer(writes()[0], 200, {ok:true});
    const batch = writes()[0]; assert(batch.url === "/api/config/commit", "Expected the credential reference commit");
    answer(batch, 503, {ok:false, error_code:"outcome_unknown"});
    assert(!fixture.requests.some(x => x.method === "DELETE"), "Unknown commit removed the staged credential");
    assert(visible($("#modal")) && !$("#mSave").disabled, "Unknown result lost or locked the draft");
  });
  test("native timeout and late success settle the save once", () => {
    hooks.editBuilding("b_fixture"); $("#modal").querySelector("[data-f='en']").value="Timeout draft"; $("#mSave").onclick(); const request = writes()[0];
    assert(request.timeout === 10000, "Save request lacks the native deadline"); request.ontimeout();
    assert(visible($("#modal")) && !$("#mSave").disabled, "Timeout did not restore editing");
    request.respond(200, {ok:true});
    assert(visible($("#modal")), "Late success after timeout closed the retained draft");
  });
  return results;
}
