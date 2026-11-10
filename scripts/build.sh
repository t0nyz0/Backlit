#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
target_triple="$(uname -m)-apple-macosx14.0"
toolchain_usr="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
intent_protocols="$toolchain_usr/share/swift/SwiftConstantValues/AppIntents.json"
[ -s "$intent_protocols" ] || { echo 'This Xcode toolchain is missing AppIntents constant-gathering definitions.' >&2; exit 1; }
mkdir -p dist/appintents
# The SDK definition is versioned on newer toolchains; the frontend consumes
# a plain protocol-name array on both older and newer Swift compilers.
intent_array="$PWD/dist/appintents/protocols.json"
python3 - "$intent_protocols" "$intent_array" <<'PY_PROTOCOLS'
import json
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
value = json.loads(source.read_text())
if isinstance(value, dict):
    value = value.get('constValueProtocols')
if not isinstance(value, list) or not value or not all(isinstance(name, str) and name for name in value):
    raise SystemExit('Invalid AppIntents protocol definition in the selected toolchain.')
normalized = json.dumps(sorted(set(value))) + '\n'
if not destination.is_file() or destination.read_text() != normalized:
    destination.write_text(normalized)
PY_PROTOCOLS
swift build -c release --triple "$target_triple" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=/build/Backlit" \
    -Xswiftc -whole-module-optimization \
    -Xswiftc -emit-const-values \
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$intent_array"
binary_dir="$(swift build -c release --triple "$target_triple" --show-bin-path)"
# Let the driver assign compile-only outputs. Forwarding an explicit frontend
# output path also reaches dependency scanning, where constant emission is invalid.
python3 - "$PWD" "$binary_dir" "$target_triple" <<'PY_CONSTANTS'
import json
from pathlib import Path
import sys
root, binary = map(lambda value: Path(value).resolve(), sys.argv[1:3])
architecture = sys.argv[3].split('-')[0]
module_maps = []
for path in root.joinpath('.build').rglob('*.json'):
    if 'outputfilemap' not in path.name.lower().replace('-', '') or 'Backlit.build' not in path.parts:
        continue
    if path.is_relative_to(binary) or ('Release' in path.parts and architecture in path.parts):
        module_maps.append(path)
constants = []
for path in sorted(module_maps, key=lambda value: value.stat().st_mtime_ns, reverse=True):
    record = json.loads(path.read_text())
    outputs = [Path(value['const-values']) for value in record.values()
               if isinstance(value, dict) and 'const-values' in value]
    if outputs:
        constants = outputs
        break
if not constants:
    # Native SwiftPM layouts may not describe the driver's sidecar outputs.
    module = binary / 'Backlit.build'
    whole_module = module / 'Backlit.swiftconstvalues'
    constants = [whole_module] if whole_module.is_file() else sorted(module.glob('*.swiftconstvalues'))
if not constants or any(not path.is_file() or not path.stat().st_size for path in constants):
    raise SystemExit('The release compiler produced no complete Backlit constant-value outputs.')
values, seen = [], set()
for path in constants:
    records = json.loads(path.read_text())
    if not isinstance(records, list):
        raise SystemExit('Unexpected compiler constant-value format.')
    for record in records:
        identity = json.dumps(record, sort_keys=True)
        if identity not in seen:
            seen.add(identity)
            values.append(record)
if not values:
    raise SystemExit('The release compiler emitted no AppIntents constants.')
root.joinpath('dist/appintents/Backlit.swiftconstvalues').write_text(json.dumps(values) + '\n')
print(f'Collected compiler constants from {len(constants)} release output(s).')
PY_CONSTANTS
app_bundle="$PWD/dist/Backlit.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary_dir/Backlit" "$app_bundle/Contents/MacOS/Backlit"
cp assets/Info.plist "$app_bundle/Contents/Info.plist"
mkdir -p "$app_bundle/Contents/Frameworks"
ditto "$binary_dir/Sparkle.framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"
codesign --verify --strict "$app_bundle/Contents/Frameworks/Sparkle.framework"
cp LICENSE "$app_bundle/Contents/Resources/LICENSE"
cp docs/ATTRIBUTION.md "$app_bundle/Contents/Resources/ATTRIBUTION.md"
mkdir -p "$app_bundle/Contents/Resources/licenses"
cp docs/licenses/Sparkle.txt "$app_bundle/Contents/Resources/licenses/Sparkle.txt"
if [ -f assets/Backlit.icns ]; then cp assets/Backlit.icns "$app_bundle/Contents/Resources/Backlit.icns"; fi
mkdir -p "$app_bundle/Contents/Resources/HomeAssistant"
rsync -a --delete --delete-excluded --exclude=__pycache__ --exclude='*.pyc' homeassistant/ "$app_bundle/Contents/Resources/HomeAssistant/"
# Retired integrations must not survive an incremental generated-bundle build.
rm -rf "$app_bundle/Contents/Resources/Integrations"
bash scripts/shortcuts-metadata.sh extract "$app_bundle" "$target_triple"
strip -S "$app_bundle/Contents/MacOS/Backlit"
codesign --force --sign - --identifier local.backlit "$app_bundle"
echo "$app_bundle"
