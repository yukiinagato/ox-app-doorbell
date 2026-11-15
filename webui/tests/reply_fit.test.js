"use strict";
const assert = require("assert");
const C = require("../panel/panel-common.js");

const CJK = /[぀-鿿]/;
// Deterministic wrapper: CJK glyphs are 1.0 em wide, Latin 0.55 em; CJK wraps per character,
// Latin per word; explicit newlines start a new paragraph.
function measurer(text, width) {
  return size => {
    let lines = 0, widest = 0;
    text.split("\n").forEach(par => {
      const tokens = CJK.test(par) ? par.split("") : par.split(/(?<= )/);
      let cur = 0;
      lines++;
      tokens.forEach(tok => {
        const tw = [...tok].reduce((a, ch) => a + (CJK.test(ch) ? 1 : 0.55) * size, 0);
        if (cur + tw > width && cur > 0) { widest = Math.max(widest, cur); lines++; cur = 0; }
        cur += tw;
      });
      widest = Math.max(widest, cur);
    });
    return { width: widest, height: lines * size * 1.15 };
  };
}
function fit(text, w, h) { return C.fitFontSize(w, h, measurer(text, w), 28, h); }
function assertMaximal(text, w, h, r) {
  const at = measurer(text, w)(r.size), next = measurer(text, w)(r.size + 1);
  assert(at.width <= w + 0.5 && at.height <= h + 0.5, "fits: " + text);
  assert(r.size >= h || next.width > w + 0.5 || next.height > h + 0.5, "largest size: " + text);
}

let r = fit("OK", 1000, 600);
assertMaximal("OK", 1000, 600, r);
assert(r.size >= 400, "a short text fills the box");
for (const t of ["少々お待ちください", "One moment please, I will be right with you", "请稍等，我马上过来"]) {
  for (const box of [[1200, 600], [340, 500], [700, 900]]) {
    r = fit(t, box[0], box[1]);
    assert(r.fits);
    assertMaximal(t, box[0], box[1], r);
  }
}
r = fit("あ".repeat(600), 340, 300);
assert.strictEqual(r.size, 28);
assert.strictEqual(r.fits, false, "the floor is kept when nothing fits");
assert(fit("a\nb\nc\nd", 600, 600).size < fit("a b c d", 600, 600).size, "explicit newlines add lines");
assert.strictEqual(C.fitFontSize(10, 10, () => ({ width: 1, height: 1 }), 10, 20).size, 20, "ceiling is respected");

// Guarded dismissal: ignored for 3 s, then arm, then close on a separate later tap.
{
  const g = C.createReplyGuard(1000);
  assert.strictEqual(g.hint(1000), "none");
  assert.strictEqual(g.tap(3999), "ignore", "taps do nothing for the first 3 s");
  assert.strictEqual(g.hint(3999), "none");
  assert.strictEqual(g.hint(4000), "exit");
  assert.strictEqual(g.tap(4000), "arm");
  assert.strictEqual(g.hint(4100), "confirm");
  assert.strictEqual(g.tap(4200), "ignore", "a bounce under 300 ms does not count");
  assert.strictEqual(g.tap(4300), "close");
  const h = C.createReplyGuard(0);
  assert.strictEqual(h.tap(5000), "arm");
  assert.strictEqual(h.hint(8000), "confirm");
  assert.strictEqual(h.hint(8001), "exit", "the confirm state lapses after 3 s");
  assert.strictEqual(h.tap(9000), "arm", "a late second tap only re-arms");
  assert.strictEqual(h.tap(9500), "close");
}

// Reply ink on its surface reaches 7:1 in light and dark.
{
  const css = require("fs").readFileSync(require("path").join(__dirname, "../panel/panel.css"), "utf8");
  const lum = hex => { const c = [1, 3, 5].map(i => parseInt(hex.substr(i, 2), 16) / 255)
    .map(v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const light = css.match(/:root \{[^}]*\}/)[0], dark = css.match(/:root\[data-theme="dark"\] \{[^}]*\}/)[0];
  const v = (block, name) => block.match(new RegExp("--" + name + ":(#[0-9a-fA-F]{6})"))[1];
  assert(ratio(v(light, "on-surface"), v(light, "surface")) >= 7, "light ink 7:1");
  assert(ratio(v(dark, "on-surface"), v(dark, "surface")) >= 7, "dark ink 7:1");
}
console.log("reply_fit ok");
