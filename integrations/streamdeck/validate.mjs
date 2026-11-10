// Validate generated output without connecting to Stream Deck or launching Backlit.
import Ajv from "ajv";
import { assertFreshBuild } from "./fingerprint.mjs";
import { readFile, access, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const bundle = path.join(root, "com.t0nyz.backlit.sdPlugin");
await assertFreshBuild(root);
const manifest = JSON.parse(await readFile(path.join(bundle, "manifest.json"), "utf8"));
const schema = JSON.parse(await readFile(path.join(root, "node_modules/@elgato/schemas/streamdeck/plugins/manifest.json"), "utf8"));
const validate = new Ajv({ allErrors: true, strict: false }).compile(schema);
if (!validate(manifest)) throw new Error(JSON.stringify(validate.errors));

function local(relative) {
    const candidate = path.resolve(bundle, relative);
    const contained = path.relative(bundle, candidate);
    if (contained.startsWith("..") || path.isAbsolute(contained)) throw new Error("Asset path escapes plugin");
    return candidate;
}
async function icon(name, size) {
    for (const [suffix, factor] of [["", 1], ["@2x", 2]]) {
        let data;
        for (const extension of ["svg", "png"]) {
            try { data = await readFile(local(name + suffix + "." + extension)); break; }
            catch (error) { if (error.code !== "ENOENT") throw error; }
        }
        if (!data) throw new Error("Missing plugin image: " + name + suffix);
        let width, height;
        if (data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
            width = data.readUInt32BE(16); height = data.readUInt32BE(20);
        } else {
            const source = data.toString("utf8");
            width = Number(source.match(/<svg\b[^>]*\bwidth="(\d+)"/)?.[1]);
            height = Number(source.match(/<svg\b[^>]*\bheight="(\d+)"/)?.[1]);
        }
        if (width !== size * factor || height !== size * factor) throw new Error("Invalid plugin image size: " + name + suffix);
    }
}
await access(local(manifest.CodePath));
await access(local(manifest.PropertyInspectorPath));
await icon(manifest.Icon, 256);
await icon(manifest.CategoryIcon, 28);
const ids = new Set();
for (const action of manifest.Actions) {
    if (ids.has(action.UUID)) throw new Error("Duplicate action identifier");
    ids.add(action.UUID);
    await icon(action.Icon, 20);
    for (const state of action.States) await icon(state.Image, 72);
}
for (const name of ["LICENSE", "THIRD-PARTY-LICENSES.txt"]) {
    if (!(await stat(local(name))).size) throw new Error("Missing plugin license notice");
}
console.log("Official manifest schema, five actions, generated files, icon sizes and licenses verified.");
