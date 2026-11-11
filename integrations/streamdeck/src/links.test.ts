import assert from "node:assert/strict";
import test from "node:test";
import { linkFor } from "./links.ts";

test("fixed commands and validated settings produce only Backlit links", () => {
    assert.equal(linkFor("toggle"), "backlit://toggle");
    assert.equal(linkFor("on"), "backlit://power?state=on");
    assert.equal(linkFor("off"), "backlit://power?state=off");
    assert.equal(linkFor("brightness", { percentage: 1 }), "backlit://brightness?value=1");
    assert.equal(linkFor("brightness", { percentage: 100 }), "backlit://brightness?value=100");
    assert.equal(linkFor("mode", { mode: "trackpad" }), "backlit://mode?name=trackpad");
    assert.equal(linkFor("mode", { mode: "typing" }), "backlit://mode?name=typing");
});

test("URLs, credentials, booleans and nonfinite values cannot become settings", () => {
    for (const percentage of [-1, 101, NaN, Infinity, "50", true, null]) assert.throws(() => linkFor("brightness", { percentage }));
    for (const mode of ["signals", "focus", "steady&token=value", "https://example.invalid", "$(command)", false, null]) assert.throws(() => linkFor("mode", { mode }));
    assert.throws(() => linkFor("toggle", { token: "fixture" }));
    assert.throws(() => linkFor("unknown"));
    assert.throws(() => linkFor("toggle", null));
    assert.throws(() => linkFor("toggle", []));
});
