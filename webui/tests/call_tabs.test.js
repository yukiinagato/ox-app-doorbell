"use strict";
const assert = require("assert"), fs = require("fs"), path = require("path");
const { runtime } = require("./call_page_fixture.js");
const page = runtime();
page.run(fs.readFileSync(path.join(__dirname, "call_tabs_cases.js"), "utf8"));
const results = page.run("runDoorTabTests()");
for (const result of results) {
  console.log(result.id + ": " + result.status + (result.message ? " " + result.message : ""));
  assert.strictEqual(result.status, "PASS");
}
console.log("Door tabs execute the production page renderer; native browser focus is verified separately.");
