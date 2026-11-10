// Source-relative hashes keep packaging freshness checks portable and private.
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const bundle = "com.t0nyz.backlit.sdPlugin";
async function files(root, directory) {
    const result = [];
    for (const entry of await readdir(path.join(root, directory), { withFileTypes: true })) {
        const relative = directory + "/" + entry.name;
        if (entry.isDirectory()) result.push(...await files(root, relative));
        else if (entry.isFile()) result.push(relative);
    }
    return result;
}
async function hash(root, names) {
    const value = createHash("sha256");
    for (const name of [...new Set(names)].sort()) {
        const data = await readFile(path.join(root, name));
        value.update(name + "\0" + data.length + "\0"); value.update(data);
    }
    return value.digest("hex");
}
export async function inputFingerprint(root = here) {
    const fixed = ["LICENSE", "build.mjs", "validate.mjs", "pack.mjs", "inspect-package.py", "fingerprint.mjs", "package.json", "package-lock.json", "tsconfig.json", "src/icon.png", bundle + "/manifest.json", bundle + "/package.json"];
    return hash(root, [...fixed, ...(await files(root, "src")).filter(name => name.endsWith(".ts") && !name.endsWith(".test.ts")), ...await files(root, bundle + "/ui"), ...(await files(root, bundle + "/images")).filter(name => name.endsWith(".svg"))]);
}
export async function stampBuild(root = here) {
    const record = { version: 1, inputs: await inputFingerprint(root), outputs: await hash(root, await files(root, bundle)) };
    await mkdir(path.join(root, "out"), { recursive: true });
    await writeFile(path.join(root, "out/build-fingerprint.json"), JSON.stringify(record) + "\n");
}
export async function assertFreshBuild(root = here) {
    let record;
    try { record = JSON.parse(await readFile(path.join(root, "out/build-fingerprint.json"), "utf8")); }
    catch { throw new Error("Plugin has no valid build fingerprint; run npm run build first."); }
    if (record.version !== 1 || record.inputs !== await inputFingerprint(root) || record.outputs !== await hash(root, await files(root, bundle))) {
        throw new Error("Plugin sources or built output changed; run npm run build before packaging.");
    }
}
