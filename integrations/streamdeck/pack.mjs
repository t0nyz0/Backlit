// Local packaging only. This never registers, launches or installs the plugin.
import { execFileSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(fileURLToPath(import.meta.url));
const bundle = path.join(root, "com.t0nyz.backlit.sdPlugin");
const output = path.join(root, "out");
const name = "com.t0nyz.backlit.streamDeckPlugin";
const artifact = path.join(output, name);
const cli = path.join(root, "node_modules/@elgato/cli/bin/streamdeck.mjs");
const version = JSON.parse(await readFile(path.join(root, "node_modules/@elgato/cli/package.json"), "utf8")).version;
if (version !== "1.10.4") throw new Error("Install the pinned local Stream Deck CLI with npm ci first.");
await mkdir(output, { recursive: true });
// Remove generated old output before validating, so failure cannot leave a
// previous package looking like the result of the requested build.
await rm(artifact, { force: true });
await rm(path.join(output, "SHA256SUMS.txt"), { force: true });
execFileSync(process.execPath, [path.join(root, "validate.mjs")], { cwd: root, stdio: "inherit" });
// The official CLI reformats its input manifest even without --version.
// Pack a generated staging copy so packaging never modifies source files.
const stage = await mkdtemp(path.join(output, ".pack-stage-"));
try {
    const stagedBundle = path.join(stage, path.basename(bundle));
    await cp(bundle, stagedBundle, { recursive: true });
    const originalManifest = JSON.parse(await readFile(path.join(bundle, "manifest.json"), "utf8"));
    execFileSync(process.execPath, [cli, "pack", stagedBundle, "--output", output, "--force", "--no-update-check", "--no-file-list"], { cwd: root, stdio: "inherit", timeout: 30_000 });
    const packedManifest = JSON.parse(await readFile(path.join(stagedBundle, "manifest.json"), "utf8"));
    if (JSON.stringify(originalManifest) !== JSON.stringify(packedManifest)) throw new Error("Packager changed the manifest values");
    execFileSync("python3", [path.join(root, "inspect-package.py"), artifact, stagedBundle], { cwd: root, stdio: "inherit" });
} catch (error) {
    await rm(artifact, { force: true });
    throw error;
} finally { await rm(stage, { recursive: true, force: true }); }
const digest = createHash("sha256").update(await readFile(artifact)).digest("hex");
await writeFile(path.join(output, "SHA256SUMS.txt"), `${digest}  ${name}\n`);
console.log(`${digest}  ${name}`);
