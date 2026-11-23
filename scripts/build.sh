#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
target_triple="$(uname -m)-apple-macosx14.0"
toolchain_usr="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
intent_protocols="$toolchain_usr/share/swift/SwiftConstantValues/AppIntents.json"
[ -s "$intent_protocols" ] || { echo 'This Xcode toolchain is missing AppIntents constant-gathering definitions.' >&2; exit 1; }
app_bundle="$PWD/dist/Backlit.app"
scratch_dir="$PWD/.build"
intent_work="$PWD/dist/appintents"
if [ "${BACKLIT_LOCAL_CONTROL_BUILD:-0}" = "1" ]; then
    app_bundle="$PWD/dist/Backlit-Control-Preview.app"
    scratch_dir="$PWD/.build/control-preview"
    intent_work="$PWD/dist/appintents-control-preview"
fi
mkdir -p "$intent_work"
build_snapshot="$(mktemp "$PWD/dist/build-input.XXXXXX")"
trap 'rm -f "$build_snapshot"' EXIT
python3 scripts/compile-localizations.py --write
python3 scripts/build-provenance.py capture "$build_snapshot"
# The SDK definition is versioned on newer toolchains; the frontend consumes
# a plain protocol-name array on both older and newer Swift compilers.
intent_array="$intent_work/protocols.json"
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
experimental_flags=()
if [ "${BACKLIT_LOCAL_CONTROL_BUILD:-0}" = "1" ]; then
    sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
    experimental_flags=(-Xswiftc -D -Xswiftc BACKLIT_CONTROL_CENTER
        -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version")
fi
# macOS Bash 3.2 treats an empty array expansion as unbound under set -u.
swift build -c release --scratch-path "$scratch_dir" --triple "$target_triple" ${experimental_flags[@]+"${experimental_flags[@]}"} \
    -Xswiftc -D -Xswiftc BACKLIT_STANDALONE \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=/build/Backlit" \
    -Xswiftc -whole-module-optimization \
    -Xswiftc -emit-const-values \
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$intent_array"
binary_dir="$(swift build -c release --scratch-path "$scratch_dir" --triple "$target_triple" --show-bin-path)"
# Let the driver assign compile-only outputs. Forwarding an explicit frontend
# output path also reaches dependency scanning, where constant emission is invalid.
python3 - "$scratch_dir" "$binary_dir" "$target_triple" "$intent_work" <<'PY_CONSTANTS'
import json
from pathlib import Path
import sys
scratch, binary = map(lambda value: Path(value).resolve(), sys.argv[1:3])
architecture = sys.argv[3].split('-')[0]
module_maps = []
for path in scratch.rglob('*.json'):
    if scratch.name == '.build' and 'control-preview' in path.relative_to(scratch).parts:
        continue
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
Path(sys.argv[4], 'Backlit.swiftconstvalues').write_text(json.dumps(values) + '\n')
print(f'Collected compiler constants from {len(constants)} release output(s).')
PY_CONSTANTS
python3 scripts/check-localizations.py
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary_dir/Backlit" "$app_bundle/Contents/MacOS/Backlit"
if [ "${BACKLIT_LOCAL_CONTROL_BUILD:-0}" = "1" ]; then
    xcrun vtool -show-build "$app_bundle/Contents/MacOS/Backlit" | grep -Fq "sdk $sdk_version"
fi
cp assets/Info.plist "$app_bundle/Contents/Info.plist"
# Copy SwiftPM’s compiled native interface resources into the standalone app.
[ -d "$binary_dir/Backlit_Backlit.bundle" ] || { echo "Missing compiled interface resource bundle." >&2; exit 1; }
rm -rf "$app_bundle/Contents/Resources/Backlit_Backlit.bundle"
ditto "$binary_dir/Backlit_Backlit.bundle" "$app_bundle/Contents/Resources/Backlit_Backlit.bundle"
# Native macOS privacy dialogs use localized InfoPlist strings.
for locale in assets/Localizations/*.lproj; do
    [ -d "$locale" ] || continue
    mkdir -p "$app_bundle/Contents/Resources/$(basename "$locale")"
    cp "$locale/InfoPlist.strings" "$app_bundle/Contents/Resources/$(basename "$locale")/InfoPlist.strings"
done
mkdir -p "$app_bundle/Contents/Frameworks"
ditto "$binary_dir/Sparkle.framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"
codesign --verify --strict "$app_bundle/Contents/Frameworks/Sparkle.framework"
cp LICENSE "$app_bundle/Contents/Resources/LICENSE"
cp docs/ATTRIBUTION.md "$app_bundle/Contents/Resources/ATTRIBUTION.md"
mkdir -p "$app_bundle/Contents/Resources/licenses"
cp docs/licenses/*.txt "$app_bundle/Contents/Resources/licenses/"
if [ -f assets/Backlit.icns ]; then cp assets/Backlit.icns "$app_bundle/Contents/Resources/Backlit.icns"; fi
if [ "${BACKLIT_LOCAL_CONTROL_BUILD:-0}" = "1" ]; then
    /usr/libexec/PlistBuddy -c 'Add :BacklitLocalControlPreview bool true' "$app_bundle/Contents/Info.plist"
    bash scripts/compile-control-gallery-icon.sh "$app_bundle"
else
    # Do not carry outputs from historical local previews into the public app.
    rm -rf "$app_bundle/Contents/PlugIns"
    rm -f "$app_bundle/Contents/Resources/Assets.car"
fi
mkdir -p "$app_bundle/Contents/Resources/HomeAssistant"
rsync -a --delete --delete-excluded --exclude=__pycache__ --exclude='*.pyc' integrations/homeassistant/ "$app_bundle/Contents/Resources/HomeAssistant/"
# Retired integrations must not survive an incremental generated-bundle build.
rm -rf "$app_bundle/Contents/Resources/Integrations"
bash scripts/shortcuts-metadata.sh extract "$app_bundle" "$target_triple"
strip -S "$app_bundle/Contents/MacOS/Backlit"
python3 scripts/check-localizations.py --app "$app_bundle"
# Seal exact source/build identity with the bundle before signing.
python3 scripts/build-provenance.py write "$app_bundle" --snapshot "$build_snapshot"
# Hardened runtime makes macOS ignore DYLD_INSERT_LIBRARIES and similar
# variables, so other processes cannot load code into Backlit and inherit its
# Input Monitoring or audio permissions. It works with ad-hoc signing. The
# entitlement is needed only because the ad-hoc app and the bundled Sparkle
# framework have no team ID; drop it if Sparkle is ever removed. Keep the
# entitlements file free of XML comments.
codesign --force --sign - --options runtime --entitlements assets/Backlit.entitlements --identifier local.backlit "$app_bundle"
# Capture first: with pipefail, `grep -q` closing the pipe early fails the check.
signature_details="$(codesign -dvv "$app_bundle" 2>&1)"
case "$signature_details" in
  *flags=*runtime*) ;;
  *) echo 'The app was signed without the hardened runtime.' >&2; exit 1 ;;
esac
echo "$app_bundle"
