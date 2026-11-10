#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$PWD=/build/Backlit"
binary_dir="$(swift build -c release --show-bin-path)"
app_bundle="$PWD/dist/Backlit.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary_dir/Backlit" "$app_bundle/Contents/MacOS/Backlit"
cp assets/Info.plist "$app_bundle/Contents/Info.plist"
cp LICENSE "$app_bundle/Contents/Resources/LICENSE"
cp docs/ATTRIBUTION.md "$app_bundle/Contents/Resources/ATTRIBUTION.md"
if [ -f assets/Backlit.icns ]; then cp assets/Backlit.icns "$app_bundle/Contents/Resources/Backlit.icns"; fi
mkdir -p "$app_bundle/Contents/Resources/HomeAssistant"
rsync -a --delete --delete-excluded --exclude=__pycache__ --exclude='*.pyc' homeassistant/ "$app_bundle/Contents/Resources/HomeAssistant/"
strip -S "$app_bundle/Contents/MacOS/Backlit"
codesign --force --sign - --identifier local.backlit "$app_bundle"
echo "$app_bundle"
