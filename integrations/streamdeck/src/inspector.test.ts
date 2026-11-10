import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

function inspector() {
    class Field {
        value: string | number = "";
        hidden = false; disabled = false; textContent = "";
        handlers = new Map<string, () => void>();
        get valueAsNumber() { return Number(this.value); }
        addEventListener(kind: string, handler: () => void) { this.handlers.set(kind, handler); }
    }
    const fields = new Map(["brightness", "mode", "brightness-row", "mode-row", "status"].map(id => [id, new Field()]));
    class Socket {
        static OPEN = 1;
        readyState = 1; closed = false;
        sent: string[] = [];
        onopen?: () => void;
        onmessage?: (message: { data: string }) => void;
        constructor(publicURL: string) { assert.match(publicURL, /^ws:\/\/127\.0\.0\.1:\d+$/); sockets.push(this); }
        send(value: string) { this.sent.push(value); }
        close() { this.closed = true; }
    }
    const sockets: Socket[] = [];
    const window: { connectElgatoStreamDeckSocket?: (...args: string[]) => void } = {};
    runInNewContext(readFileSync(new URL("../com.t0nyz.backlit.sdPlugin/ui/settings.js", import.meta.url), "utf8"), {
        window, document: { getElementById: (id: string) => fields.get(id) }, WebSocket: Socket,
    });
    function connect(action = "brightness", settings = {}, actionContext = "action-instance") {
        window.connectElgatoStreamDeckSocket!("12345", "inspector-instance", "registerPropertyInspector", "{}", JSON.stringify({ action: "com.t0nyz.backlit." + action, context: actionContext, payload: { settings } }));
    }
    return { fields, sockets, connect, window };
}

test("inspector registers its own UUID and saves using action identity", () => {
    const ui = inspector(); ui.connect();
    const socket = ui.sockets[0];
    assert.equal(ui.fields.get("brightness")!.disabled, true);
    socket.onopen!();
    assert.deepEqual(JSON.parse(socket.sent[0]), { event: "registerPropertyInspector", uuid: "inspector-instance" });
    ui.fields.get("brightness")!.value = "37";
    ui.fields.get("mode")!.value = "steady";
    ui.fields.get("brightness")!.handlers.get("change")!();
    assert.deepEqual(JSON.parse(socket.sent[1]), { event: "setSettings", action: "com.t0nyz.backlit.brightness", context: "action-instance", payload: { percentage: 37, mode: "steady" } });
});

test("inspector ignores unrelated messages and resets empty settings to actual defaults", () => {
    const ui = inspector(); ui.connect("mode", { percentage: 90, mode: "music" });
    const socket = ui.sockets[0]; socket.onopen!();
    socket.onmessage!({ data: JSON.stringify({ event: "didReceiveSettings", action: "com.t0nyz.backlit.mode", context: "wrong-action", payload: { settings: {} } }) });
    assert.equal(ui.fields.get("mode")!.value, "music");
    socket.onmessage!({ data: JSON.stringify({ event: "didReceiveSettings", action: "com.t0nyz.backlit.mode", context: "action-instance", payload: { settings: {} } }) });
    assert.equal(ui.fields.get("mode")!.value, "steady");
    assert.equal(ui.fields.get("brightness")!.value, 50);
});

test("invalid registration does not open a socket", () => {
    const ui = inspector(); ui.connect("unknown");
    assert.equal(ui.sockets.length, 0);
    ui.window.connectElgatoStreamDeckSocket!("bad-port", "fixture", "registerPropertyInspector", "{}", "{}");
    assert.equal(ui.sockets.length, 0);
    for (const invalid of ["null", "[]", "true", "42", "broken JSON"]) {
        assert.doesNotThrow(() => ui.window.connectElgatoStreamDeckSocket!("12345", "fixture", "registerPropertyInspector", "{}", invalid));
    }
    assert.equal(ui.sockets.length, 0);
});

test("new registration closes previous socket and ignores stale messages", () => {
    const ui = inspector(); ui.connect("brightness", { percentage: 90 });
    const old = ui.sockets[0];
    ui.connect("brightness", { percentage: 20 }, "new-action");
    assert.equal(old.closed, true);
    old.onmessage!({ data: JSON.stringify({ event: "didReceiveSettings", action: "com.t0nyz.backlit.brightness", context: "new-action", payload: { settings: { percentage: 100 } } }) });
    assert.equal(ui.fields.get("brightness")!.value, 20);
});


test("inspector migrates a removed behavior to a supported selection on save", () => {
    const ui = inspector(); ui.connect("mode", { mode: "signals" });
    const socket = ui.sockets[0]; socket.onopen!();
    assert.equal(ui.fields.get("mode")!.value, "steady");
    ui.fields.get("mode")!.handlers.get("change")!();
    assert.equal(JSON.parse(socket.sent[1]).payload.mode, "steady");
});
