import assert from "node:assert/strict";
import test from "node:test";
import { cp, mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { assertFreshBuild, inputFingerprint, stampBuild } from "./fingerprint.mjs";

const plugin = "com.t0nyz.backlit.sdPlugin";
async function fixture() {
    const root = await mkdtemp(path.join(os.tmpdir(), "backlit-fingerprint-"));
    const names = ["LICENSE", "build.mjs", "validate.mjs", "pack.mjs", "inspect-package.py", "fingerprint.mjs", "package.json", "package-lock.json", "tsconfig.json", "src/icon.png", "src/plugin.ts", "src/fixture.test.ts", plugin + "/manifest.json", plugin + "/package.json", plugin + "/ui/settings.js", plugin + "/images/action.svg", plugin + "/bin/plugin.js"];
    for (const name of names) {
        await mkdir(path.dirname(path.join(root, name)), { recursive: true });
        await writeFile(path.join(root, name), "fixture source — never executed");
    }
    return root;
}

test("freshness rejects production source, settings, assets, licenses, lockfile and runtime changes", async () => {
    const root = await fixture();
    try {
        await stampBuild(root); await assertFreshBuild(root);
        for (const name of ["src/plugin.ts", plugin + "/ui/settings.js", plugin + "/images/action.svg", "src/icon.png", "LICENSE", "package-lock.json", "build.mjs", plugin + "/bin/plugin.js"]) {
            await writeFile(path.join(root, name), "changed fixture");
            await assert.rejects(assertFreshBuild(root), /run npm run build/);
            await stampBuild(root); await assertFreshBuild(root);
        }
    } finally { await rm(root, { recursive: true, force: true }); }
});

test("fingerprints exclude absolute paths and unrelated test-source edits", async () => {
    const first = await fixture(), second = await fixture();
    try {
        assert.equal(await inputFingerprint(first), await inputFingerprint(second));
        await stampBuild(first);
        await writeFile(path.join(first, "src/fixture.test.ts"), "test-only change");
        await assertFreshBuild(first);
        await cp(path.join(first, "out"), path.join(second, "out"), { recursive: true });
        await assertFreshBuild(second);
    } finally { await rm(first, { recursive: true, force: true }); await rm(second, { recursive: true, force: true }); }
});

test("unbuilt bundles are rejected without running code", async () => {
    const root = await fixture();
    try { await assert.rejects(assertFreshBuild(root), /run npm run build/); }
    finally { await rm(root, { recursive: true, force: true }); }
});
