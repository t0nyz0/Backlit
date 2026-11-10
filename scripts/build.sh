#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
target_triple="$(uname -m)-apple-macosx14.0"
toolchain_usr="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
intent_protocols="$toolchain_usr/share/swift/SwiftConstantValues/AppIntents.json"
[ -s "$intent_protocols" ] || { echo 'This Xcode toolchain is missing AppIntents constant-gathering definitions.' >&2; exit 1; }
mkdir -p dist/appintents
swift build -c release --triple "$target_triple" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=/build/Backlit" \
    -Xswiftc -whole-module-optimization \
    -Xswiftc -const-gather-protocols-list -Xswiftc "$intent_protocols" \
    -Xswiftc -emit-const-values-path -Xswiftc "$PWD/dist/appintents/Backlit.swiftconstvalues"
binary_dir="$(swift build -c release --triple "$target_triple" --show-bin-path)"
app_bundle="$PWD/dist/Backlit.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary_dir/Backlit" "$app_bundle/Contents/MacOS/Backlit"
cp assets/Info.plist "$app_bundle/Contents/Info.plist"
cp LICENSE "$app_bundle/Contents/Resources/LICENSE"
cp docs/ATTRIBUTION.md "$app_bundle/Contents/Resources/ATTRIBUTION.md"
if [ -f assets/Backlit.icns ]; then cp assets/Backlit.icns "$app_bundle/Contents/Resources/Backlit.icns"; fi
mkdir -p "$app_bundle/Contents/Resources/HomeAssistant"
rsync -a --delete --delete-excluded --exclude=__pycache__ --exclude='*.pyc' homeassistant/ "$app_bundle/Contents/Resources/HomeAssistant/"
mkdir -p "$app_bundle/Contents/Resources/Integrations"
rsync -a --delete --delete-excluded --exclude=__pycache__ --exclude='*.pyc' --exclude=node_modules --exclude=.git integrations/ "$app_bundle/Contents/Resources/Integrations/"
bash scripts/shortcuts-metadata.sh extract "$app_bundle" "$target_triple"
strip -S "$app_bundle/Contents/MacOS/Backlit"
codesign --force --sign - --identifier local.backlit "$app_bundle"
echo "$app_bundle"
