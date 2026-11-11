import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

test("property inspector offers and retains standalone Typing without a connection", () => {
    const ui = new URL("./com.t0nyz.backlit.sdPlugin/ui/", import.meta.url);
    const html = readFileSync(new URL("settings.html", ui), "utf8");
    assert.match(html, /<option value="typing">Typing<\/option>/);
    const elements = new Map();
    const document = { getElementById(id) {
        if (!elements.has(id)) elements.set(id, { value: "", addEventListener() {} });
        return elements.get(id);
    } };
    const source = readFileSync(new URL("settings.js", ui), "utf8");
    runInNewContext(source + '\nshow({ mode: "typing" });', { document, window: {} });
    assert.equal(elements.get("mode").value, "typing");
});
