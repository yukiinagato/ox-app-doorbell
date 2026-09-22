"use strict";
function runDoorTabTests() {
  const results = [];
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const door = id => ({ id, label: "Door " + id, extension: "8001", online: true });
  const buttons = () => Array.from(els.tabs.children);
  const reset = () => {
    session = null; latestPanelState = null; selected = null; doors = []; renderTabs();
    doors = [door("A"), door("B"), door("C")]; selected = doors[0]; renderTabs();
  };
  function test(id, body) {
    try { reset(); body(); results.push({ id, status: "PASS" }); }
    catch (error) { results.push({ id, status: "FAIL", message: error.message }); }
  }
  test("T13-01", () => {
    const before = buttons(); before[1].focus();
    els.tabs.style.width = "120px"; els.tabs.style.flexWrap = "nowrap"; els.tabs.style.overflowX = "auto";
    els.tabs.scrollLeft = 7;
    const scroll = els.tabs.scrollLeft;
    const observer = typeof MutationObserver === "function" ? new MutationObserver(() => {}) : null;
    if (observer) observer.observe(els.tabs, {childList:true, subtree:true, characterData:true, attributes:true});
    for (let i = 0; i < 10; i++) { doors = doors.map(d => Object.assign({}, d)); renderTabs(); }
    const mutations = observer ? observer.takeRecords() : [];
    const finalScroll = els.tabs.scrollLeft;
    if (observer) observer.disconnect();
    els.tabs.style.width = ""; els.tabs.style.flexWrap = ""; els.tabs.style.overflowX = "";
    assert(document.activeElement === before[1], "Unchanged polls lost keyboard focus");
    assert(buttons().every((b, i) => b === before[i]), "Unchanged polls replaced a door node");
    assert(scroll === 7, "Scroll assertion requires a nonzero initial scroll offset");
    assert(finalScroll === scroll, "Unchanged polls changed scroll position");
    assert(mutations.length === 0, "Unchanged polls rewrote accessible content");
  });
  test("T13-02", () => {
    const before = buttons(); before[1].focus();
    doors = [door("C"), door("A"), door("B")]; renderTabs();
    assert(buttons()[0] === before[2] && buttons()[1] === before[0] && buttons()[2] === before[1],
      "Reorder recreated door nodes");
    assert(document.activeElement === before[1], "Reorder lost keyboard focus");
  });
  test("T13-03", () => {
    buttons()[1].focus(); doors = [door("A"), door("C")]; renderTabs();
    assert(document.activeElement === buttons()[1], "Removed B must focus its next available neighbor C");
    doors = [door("A")]; renderTabs();
    assert(document.activeElement === buttons()[0], "Removed final neighbor must focus preceding A");
    doors = []; renderTabs();
    assert(document.activeElement === els.title, "Empty door list must focus its title");
  });
  test("T13-04", () => {
    const retained = buttons()[1];
    for (let i = 0; i < 20; i++) {
      doors = [door("A"), door("B"), door("temporary-" + i)]; renderTabs();
      doors = [door("B"), door("A")]; renderTabs();
    }
    const latest = door("B"); latest.extension = "9999";
    doors = [latest, door("A")]; renderTabs();
    assert(buttons()[0] === retained, "Repeated add/remove replaced retained button");
    const prior = selectionRevision;
    retained.click();
    assert(selectionRevision === prior + 1, "One click must dispatch one selection action");
    assert(selected === latest, "Retained handler selected an obsolete door object");
    assert(buttons().length === 2, "Removed door nodes leaked");
    assert(retained.getAttribute("aria-pressed") === "true", "Selected state is not accessible");
  });
  return results;
}
