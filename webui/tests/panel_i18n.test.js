"use strict";

const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

const pages = ["door", "call", "monitor"];
const catalogs = Object.fromEntries(["ja", "en", "zh"].map(lang => [
  lang, JSON.parse(fs.readFileSync("webui/locale/" + lang + ".json", "utf8")),
]));

function functionSource(source, name) {
  const start = source.indexOf("function " + name + "(");
  assert(start >= 0, "missing function " + name);
  const body = source.indexOf("{", start);
  let depth = 0;
  for (let i = body; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}" && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error("unterminated function " + name);
}

function languageSelector(source, queryLanguage) {
  return vm.runInNewContext("(function () { var QUERY_LANG = " +
    JSON.stringify(queryLanguage || "") + ";" + functionSource(source, "normalizeLang") +
    functionSource(source, "languageForState") + "; return languageForState; })()");
}

for (const page of pages) {
  const source = fs.readFileSync("webui/panel/" + page + ".html", "utf8");
  assert.strictEqual(/[\u3040-\u30ff\u3400-\u9fff]/.test(source), false,
    page + ".html must not embed Japanese UI text");
  assert.strictEqual(/t\(\s*["'][^"']+["']\s*,\s*["']/.test(source), false,
    page + ".html must not provide a hard-coded UI-text fallback to t()");
  assert(source.includes('qs("lang")') || source.includes('qs.get("lang")'),
    page + ".html must honor ?lang=");
  assert(source.includes("visitor_lang"),
    page + ".html must honor the replicated visitor language");
  assert(source.includes('"/locale/" + lang + ".json"'),
    page + ".html must load the selected generated catalog");

  const selectLanguage = languageSelector(source, "");
  const state = { doors: [
    { id: "back", visitor_lang: "zh" },
    { id: "front", calling: true, visitor_lang: "en-US" },
  ] };
  assert.strictEqual(page === "monitor" ? selectLanguage(state) :
    selectLanguage(state, "back"), page === "monitor" ? "en" : "zh");
  assert.strictEqual(page === "monitor" ? languageSelector(source, "zh")(state) :
    languageSelector(source, "zh")(state, "back"), "zh", "?lang= must win on " + page);
  assert.strictEqual(page === "monitor" ? selectLanguage({ doors: [] }) :
    selectLanguage({ doors: [] }, "front"), "ja", page + " must fall back to Japanese");

  const literalKeys = [...source.matchAll(/\bt\(\s*["']([A-Za-z0-9_.]+)["']/g)]
    .map(match => match[1]);
  for (const key of literalKeys) {
    for (const lang of ["ja", "en", "zh"])
      assert.strictEqual(typeof catalogs[lang][key], "string",
        page + ".html references missing " + lang + " catalog key " + key);
  }
}

for (const key of [
  "panel.call_end_failed",
  "panel.cancel_failed",
  "panel.mock_registered",
  "panel.push_unavailable",
  "panel.event_emergency_cancel",
  "emergency.clear_instruction",
]) {
  for (const lang of ["ja", "en", "zh"])
    assert.strictEqual(typeof catalogs[lang][key], "string", "missing " + lang + " key " + key);
}

const monitor = fs.readFileSync("webui/panel/monitor.html", "utf8");
assert.strictEqual(monitor.includes("s.message"), false,
  "runtime Push diagnostics must be mapped to the selected UI catalog");
assert(monitor.includes('"lang=" + encodeURIComponent(LANG)'),
  "monitor-to-call navigation must preserve the effective language");

for (const file of ["runtime.js", "sw.js"]) {
  const source = fs.readFileSync("webui/panel/" + file, "utf8");
  assert.strictEqual(/[\u3040-\u30ff\u3400-\u9fff]/.test(source), false,
    file + " must not embed localized user-facing fallback text");
}
const runtime = fs.readFileSync("webui/panel/runtime.js", "utf8");
assert(runtime.includes("options.clearInstruction"),
  "SOS clear instructions must be injected from the selected page catalog");
assert(runtime.includes('message_key: "panel.push_unavailable"'),
  "Push runtime failures must expose catalog keys instead of display text");
const serviceWorker = fs.readFileSync("webui/panel/sw.js", "utf8");
assert(serviceWorker.includes('typeof p.title === "string" ? p.title : ""'));
assert(serviceWorker.includes('typeof p.body === "string" ? p.body : ""'));

console.log("panel i18n tests: ok");
