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
console.log("reply_fit ok");
