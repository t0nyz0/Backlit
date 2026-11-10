// Source-only build recipe; development does not execute this automatically.
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile, copyFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(fileURLToPath(import.meta.url));
const bundle = path.join(root, "com.t0nyz.backlit.sdPlugin");
await mkdir(path.join(bundle, "bin"), { recursive: true });
await copyFile(path.join(root, "LICENSE"), path.join(bundle, "LICENSE"));
await build({
    absWorkingDir: root, entryPoints: ["src/plugin.ts"], outfile: path.join(bundle, "bin/plugin.js"),
    platform: "node", target: "node24", format: "esm", bundle: true, sourcemap: false, legalComments: "eof",
    banner: { js: "import { createRequire as _createRequire } from 'node:module'; const require = _createRequire(import.meta.url);" },
});
execFileSync("/usr/bin/sips", ["-z", "256", "256", path.join(root, "src/icon.png"), "--out", path.join(bundle, "images/plugin.png")], { stdio: "ignore" });
await copyFile(path.join(root, "src/icon.png"), path.join(bundle, "images/plugin@2x.png"));
const notices = [];
for (const name of ["@elgato/streamdeck", "@elgato/utils", "@elgato/schemas", "ws", "zod"]) {
    let license;
    for (const filename of ["LICENSE", "LICENSE.md", "LICENSE.txt"]) {
        try { license = await readFile(path.join(root, "node_modules", name, filename), "utf8"); break; }
        catch (error) { if (error.code !== "ENOENT") throw error; }
    }
    if (!license) throw new Error("Missing runtime dependency license: " + name);
    notices.push(name + "\n" + license);
}
await writeFile(path.join(bundle, "THIRD-PARTY-LICENSES.txt"), notices.join("\n\n"));
