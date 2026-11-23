#!/bin/bash
# Build a standalone experimental WidgetKit extension artifact. Does not embed,
# install, register, launch, notarize or establish effective App Group access.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$#" -eq 0 ] || { echo 'Usage: bash scripts/build-control-extension.sh' >&2; exit 2; }

src="$PWD/integrations/control-center"
shared="$PWD/Sources/Backlit/ControlCenterShared.swift"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
compiler="$(xcrun --find swiftc)"
toolchain="$(cd "$(dirname "$compiler")/../.." && pwd)"
protocols="$toolchain/usr/share/swift/SwiftConstantValues/AppIntents.json"
target="arm64-apple-macosx27.0"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
[[ "$(uname -m)" = arm64 ]] || { echo 'This local Backlit experiment requires Apple silicon.' >&2; exit 2; }
[ -s "$protocols" ] || { echo 'Select Xcode with macOS 27+ SDK and App Intents tools.' >&2; exit 2; }

mkdir -p dist
output="$(mktemp -d "$PWD/dist/control-center-experimental.XXXXXX")"
complete=false
trap 'if [ "$complete" = false ]; then rm -rf "$output"; fi' EXIT
work="$output/extraction"
bundle="$output/BacklitControl.appex"
resources="$bundle/Contents/Resources"
binary="$bundle/Contents/MacOS/BacklitControl"
mkdir -p "$work" "$resources" "$(dirname "$binary")"
cp "$src/Info.plist" "$bundle/Contents/Info.plist"
for field in CFBundleShortVersionString CFBundleVersion; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$field" assets/Info.plist)"
    /usr/libexec/PlistBuddy -c "Add :$field string $value" "$bundle/Contents/Info.plist"
done
plutil -lint "$bundle/Contents/Info.plist" "$src/BacklitControl.entitlements"
python3 - "$protocols" "$work/protocols.json" <<'PY'
import json
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
protocols = json.loads(source.read_bytes())
if isinstance(protocols, dict):
    protocols = protocols.get("constValueProtocols")
if not protocols or not isinstance(protocols, list) or not all(isinstance(p, str) for p in protocols):
    raise SystemExit("Unexpected App Intents protocol inventory.")
destination.write_text(json.dumps(sorted(set(protocols))) + "\n")
PY

"$compiler" -target "$target" -sdk "$sdk" -module-cache-path "$work/module-cache" -application-extension \
    -parse-as-library -module-name BacklitControl -O -whole-module-optimization \
    -D BACKLIT_CONTROL_CENTER -file-prefix-map "$PWD=/build/Backlit" \
    -emit-const-values -Xfrontend -const-gather-protocols-file -Xfrontend "$work/protocols.json" \
    -Xlinker -application_extension -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -platform_version -Xlinker macos -Xlinker 27.0 -Xlinker "$sdk_version" \
    "$shared" "$src/BacklitControl.swift" -o "$binary"
# A standard executable entrypoint bypasses Apple's extension initialization.
# Verify the Mach-O markers, not merely compilation and PlugInKit registration.
xcrun vtool -show-build "$binary" | grep -Fq "sdk $sdk_version"
python3 - "$binary" <<'PY_ENTRY'
import re, subprocess, sys
path = sys.argv[1]
commands = subprocess.check_output(['xcrun', 'otool', '-l', path], text=True)
symbols = subprocess.check_output(['xcrun', 'nm', '-m', path], text=True)
stubs = subprocess.check_output(['xcrun', 'otool', '-Iv', path], text=True)
entry = re.search(r'cmd LC_MAIN\s+cmdsize \d+\s+entryoff (\d+)', commands)
text = re.search(r'segname __TEXT\s+vmaddr (0x[0-9a-fA-F]+)\s+vmsize 0x[0-9a-fA-F]+\s+fileoff (\d+)', commands)
bootstrap_stubs = {int(address, 16) for address in re.findall(
    r'^\s*(0x[0-9a-fA-F]+)\s+\d+\s+_NSExtensionMain$', stubs, flags=re.M)}
if (not re.search(r'\b_NSExtensionMain \(from Foundation\)', symbols)
        or not entry or not text
        or int(text[1], 16) + int(entry[1]) - int(text[2]) not in bootstrap_stubs):
    raise SystemExit('Widget extension entrypoint is not the Foundation extension bootstrap.')
PY_ENTRY
mv "${binary}.swiftconstvalues" "$work/BacklitControl.swiftconstvalues"
[ -s "$work/BacklitControl.swiftconstvalues" ]
printf '%s\n' "$shared" "$src/BacklitControl.swift" > "$work/sources.list"
printf '%s\n' "$work/BacklitControl.swiftconstvalues" > "$work/constants.list"

processor="$(xcrun --find appintentsmetadataprocessor)"
xcode_version="$(xcodebuild -version | awk '/Build version/{print $3;exit}')"
"$processor" --toolchain-dir "$toolchain" --module-name BacklitControl \
    --sdk-root "$sdk" --xcode-version "$xcode_version" --platform-family macOS \
    --deployment-target 27.0 --target-triple "$target" --output "$resources" \
    --bundle-identifier local.backlit.control --binary-file "$binary" \
    --source-file-list "$work/sources.list" --swift-const-vals-list "$work/constants.list" \
    --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization

python3 - "$resources" <<'PY'
import json
from pathlib import Path
import sys
resources = Path(sys.argv[1])
folders = [p for p in resources.iterdir() if p.is_dir() and p.name.lower() == "metadata.appintents"]
if len(folders) != 1:
    raise SystemExit("Missing unique extension intent metadata.")
content = b"\n".join(p.read_bytes() for p in folders[0].rglob("*") if p.is_file())
action = json.loads((folders[0] / "extract.actionsdata").read_bytes()).get("actions", {}).get("SetBacklitControlPowerIntent", {})
parameters = action.get("parameters", [])
if (action.get("openAppWhenRun") is not False or action.get("supportedModes") != 1
        or action.get("allowedTargets") != [{"type": 1}] or not action.get("isAuthPolExplicit")
        or action.get("isDiscoverable") is not False
        or "com.apple.link.systemProtocol.SetValue" not in action.get("systemProtocols", [])
        or len(parameters) != 1 or parameters[0].get("name") != "value"
        or parameters[0].get("isOptional") is not False):
    raise SystemExit("Expected authenticated background SetValue intent metadata is missing.")
normalized = content.replace(b"\\/", b"/")
# Match the existing shortcuts-metadata checker: these are generic search
# prefixes, not embedded host paths.
private_roots = [b'/' + name + b'/' for name in (b'Users', b'Volumes', b'var/folders')]
if any(prefix in normalized for prefix in [str(Path.home()).encode(), *private_roots]):
    raise SystemExit("Private host path found in extension metadata.")
PY
strip -S "$binary"
python3 - "$binary" <<'PY_BINARY'
from pathlib import Path
import sys
private_roots = [b'/' + name + b'/' for name in (b'Users', b'Volumes', b'var/folders')]
if any(prefix in Path(sys.argv[1]).read_bytes() for prefix in [str(Path.home()).encode(), *private_roots]):
    raise SystemExit('Private host path found in extension executable.')
PY_BINARY
codesign --force --sign - --options runtime --entitlements "$src/BacklitControl.entitlements" \
    --identifier local.backlit.control "$bundle"
codesign --verify --strict --deep "$bundle"
complete=true
printf 'Experimental build only; not runtime-qualified or registered: %s\n' "$bundle"
