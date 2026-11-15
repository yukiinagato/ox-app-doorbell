"use strict";
// Static guarantees of the door page's wizard that need no browser: it stays ES5 for iOS 5 Safari,
// loads the shared walker, keeps the controls the contract names, and has no way to leave the page.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const root = path.join(__dirname, "../panel");
const html = fs.readFileSync(path.join(root, "door.html"), "utf8");
const walker = fs.readFileSync(path.join(root, "visitor-flow.js"), "utf8");
const css = fs.readFileSync(path.join(root, "panel.css"), "utf8");

const inline = html.split("<script>")[1].split("</script>")[0];
for (const [name, source] of [["door.html", inline], ["visitor-flow.js", walker], ["call-flow.js", fs.readFileSync(path.join(root, "call-flow.js"), "utf8")]]) {
  assert(!/=>/.test(source), name + " uses an arrow function");
  assert(!/\b(let|const)\s/.test(source.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, "")), name + " uses let/const");
  assert(!/`/.test(source), name + " uses a template literal");
  assert(!/\bclass\s+\w/.test(source), name + " declares a class");
  assert(!/\.(includes|startsWith|endsWith|find|findIndex|assign)\(|Array\.from|Object\.(keys|values|entries)/.test(source.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, "")),
    name + " uses an API missing from iOS 5 Safari");
}

// The walker is loaded before the page script and the flow controls keep their semantic ids.
assert(html.indexOf('/panel/visitor-flow.js') > html.indexOf('/panel/call-flow.js'));
assert(html.indexOf('/panel/visitor-flow.js') < html.indexOf("<script>"));
for (const id of ["flow.back", "flow.done", "flow.text"]) assert(html.indexOf('data-semantic-id="' + id + '"') > 0, id);
assert(inline.indexOf("call.primary") > 0 && inline.indexOf("purpose.button") > 0);
// Safety controls are untouched: SOS, cancel/end and the language bar stay in the page.
for (const id of ['id="cancelCall"', 'id="visitorLanguage"', 'id="replyBanner"', 'id="offlineBand"']) assert(html.indexOf(id) > 0, id);
// The visitor side passes a step id and nothing else.
assert(/visitor-notify/.test(inline) && /notifyForm\(doorId, act\.step\)/.test(inline));
// An option is a button that calls the walker: no link, no navigation, no text input from the flow.
const flowCode = inline.slice(inline.indexOf("Visitor flow (docs"), inline.indexOf("var failCount"));
assert(!/href|location\.|window\.open|<input|innerHTML/.test(flowCode.replace(/\/\/.*$/gm, "")), "flow rendering must only use DOM text APIs and never navigate");
// A failure degrades to the classic screen.
assert(/flowBrokenRevision = flowRevision; selectedDoor = ""; flowDrop\(\)/.test(flowCode));

// Layout: options are at least 72 px tall and sit in the content column under the title, so the
// title and the cards are one centred block; the action bar keeps only Back/Done and SOS.
for (const selector of ["#flowOptions .doorBtn", "#flowOptions .purposeBtn"]) {
  const rule = css.split(selector + " {").slice(1).map((chunk) => chunk.split("}")[0]).join(" ");
  const heights = (rule.match(/min-height:\s*(?:clamp\()?\s*(\d+)px/g) || []).map((m) => Number(/(\d+)px/.exec(m)[1]));
  assert(heights.length && Math.min.apply(null, heights) >= 72, selector + " keeps a 72 px minimum");
}
assert(/body\.flowOn #doorList, body\.flowOn #hint \{ display:none !important; \}/.test(css), "the classic call button is hidden while the wizard is on");
assert(html.indexOf('id="flowOptions"') > html.indexOf('id="flowView"') && html.indexOf('id="flowOptions"') < html.indexOf("</main>"), "options follow the title block inside the content column");
assert(/#flowOptions \{ display:grid; grid-template-columns:minmax\(0, 1fr\)/.test(css), "one column by default");
assert(/@media \(min-width: 600px\) \{\s*#flowOptions \{ grid-template-columns:repeat\(2, minmax\(0, 1fr\)\); \}/.test(css), "two columns from 600 px");
assert(/@media \(min-width: 900px\) \{\s*#main > #flowOptions \{ max-width:960px; grid-template-columns:repeat\(3/.test(css), "three columns from 900 px");
assert(/@media \(max-width:599px\) \{ #flowOptions \.purposeBtn/.test(css), "one column on phones without grid support");
// Nothing of the classic screen shows before Core's first answer.
assert(/body\.doorPage:not\(\.ready\) #hint/.test(css) && /document\.body\.className \+= " ready"/.test(inline), "neutral until the first state");

// Option icons come from the vendored set through the shared mapping, never as emoji text.
assert(/VF\.iconFor\(option\.purpose, option\.icon\)/.test(inline) && /C\.icon\(/.test(inline), "flow options draw vendored icons");
assert(/VF \? VF\.iconFor\(p\.id, p\.icon\)/.test(inline), "the classic purpose picker draws vendored icons too");
assert(!/pIcon/.test(inline) && !/pIcon/.test(css), "no emoji text slot is left");
const sprite = fs.readFileSync(path.join(root, "icons/tabler-sprite.svg"), "utf8");
const V = require("../panel/visitor-flow.js");
for (const [purpose, glyph, name] of [["p_visit", "\u{1F3E0}", "home"], ["p_delivery", "\u{1F4E6}", "package"], ["p_mail", "\u2709\uFE0F", "mail"],
    ["p_sales", "\u{1F4BC}", "briefcase"], ["p_work", "\u{1F527}", "tool"], ["p_other", "\u2753", "dots"], ["", "", "user"], ["p_x", "?", "user"],
    ["p_delivery", "", "package"], ["visit", "", "home"], ["", "\u270D\uFE0F", "pencil"]]) {
  assert.strictEqual(V.iconFor(purpose, glyph), name, purpose + " " + glyph);
  assert(sprite.indexOf('id="i-' + name + '"') > 0, name + " is in the sprite");
}

// Several doors: a row opens that door's flow start (the state request names the door); Back from
// the start page, the idle timeout and Done return to the rows.
assert(/selectDoor\(id\)/.test(inline) && /data-flow/.test(inline) && /doc\.door !== selectedDoor/.test(inline), "multi-door rows open their own flow");
assert(/R\.panelStateUrl\(selectedDoor\)/.test(inline), "the poll asks for the selected door's flow");
assert(/if \(selectedDoor\) \{ selectDoor\(""\); return; \}/.test(inline), "idle, Done and Back leave the door's flow");
console.log("visitor flow page: PASS");
