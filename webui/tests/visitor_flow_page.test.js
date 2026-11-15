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
assert(/flowBrokenRevision = flowRevision; flowDrop\(\)/.test(flowCode));

// Layout: options are at least 72 px tall and live in a fixed zone that never scrolls the page.
for (const selector of ["#flowOptions .doorBtn", "#flowOptions .purposeBtn"]) {
  const rule = css.split(selector + " {").slice(1).map((chunk) => chunk.split("}")[0]).join(" ");
  const heights = (rule.match(/min-height:\s*(?:clamp\()?\s*(\d+)px/g) || []).map((m) => Number(/(\d+)px/.exec(m)[1]));
  assert(heights.length && Math.min.apply(null, heights) >= 72, selector + " keeps a 72 px minimum");
}
assert(/body\.flowOn #doorList, body\.flowOn #hint \{ display:none !important; \}/.test(css), "the classic call button is hidden while the wizard is on");
assert(/#flowOptions \{ display:grid; grid-template-columns:minmax\(0, 1fr\)/.test(css), "one column by default");
assert(/@media \(min-width: 600px\) \{\s*#flowOptions \{ grid-template-columns:repeat\(2, minmax\(0, 1fr\)\); \}/.test(css), "two columns from 600 px");
assert(/@media \(max-width:599px\) \{ #flowOptions \.purposeBtn/.test(css), "one column on phones without grid support");
console.log("visitor flow page: PASS");
