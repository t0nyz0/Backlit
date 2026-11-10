import assert from "node:assert/strict";
import test from "node:test";
import { CommandQueue } from "./dispatch.ts";

function gate() {
    let release!: () => void;
    const promise = new Promise<void>(resolve => { release = resolve; });
    return { promise, release };
}

test("rapid On/Off multi-actions run in order without concurrent launchers", async () => {
    const first = gate(), events: string[] = [];
    let active = 0, maximum = 0;
    const queue = new CommandQueue(async link => {
        active++; maximum = Math.max(maximum, active); events.push(link);
        if (link === "on") await first.promise;
        active--;
    });
    const on = queue.enqueue("on"), off = queue.enqueue("off"), toggle = queue.enqueue("toggle");
    await Promise.resolve();
    assert.deepEqual(events, ["on"]);
    first.release();
    await Promise.all([on, off, toggle]);
    assert.deepEqual(events, ["on", "off", "toggle"]);
    assert.equal(maximum, 1);
});

test("one failed action does not jam following actions", async () => {
    const sent: string[] = [];
    const queue = new CommandQueue(async link => { sent.push(link); if (link === "bad") throw new Error("fixture"); });
    const bad = queue.enqueue("bad"), off = queue.enqueue("off");
    await assert.rejects(bad);
    await off;
    assert.deepEqual(sent, ["bad", "off"]);
});

test("queue bounds reject excess work then recover after drain", async () => {
    const pending = gate();
    const queue = new CommandQueue(() => pending.promise, 2);
    const first = queue.enqueue("first"), second = queue.enqueue("second");
    await assert.rejects(queue.enqueue("excess"));
    pending.release();
    await Promise.all([first, second]);
    await queue.enqueue("after-drain");
});

test("idle queue creates no launcher work and rejects invalid limits", () => {
    let calls = 0;
    new CommandQueue(async () => { calls++; });
    assert.equal(calls, 0);
    for (const capacity of [0, -1, 0.5, 129, NaN]) assert.throws(() => new CommandQueue(async () => {}, capacity));
});


test("stale queued actions fail instead of changing the light much later", async () => {
    let now = 0;
    const first = gate(), sent: string[] = [];
    const queue = new CommandQueue(async link => { sent.push(link); if (link === "first") await first.promise; }, 32, () => now);
    const active = queue.enqueue("first"), stale = queue.enqueue("stale");
    await Promise.resolve();
    now = 2001; first.release();
    await active; await assert.rejects(stale);
    await queue.enqueue("fresh");
    assert.deepEqual(sent, ["first", "fresh"]);
});
