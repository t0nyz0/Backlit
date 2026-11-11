#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/dist/icon-generation"
mkdir -p "$output"
swiftc -parse-as-library Sources/Backlit/BrandGlyph.swift scripts/render-icon.swift -o "$output/render-icon"
"$output/render-icon" "$output"
python3 scripts/package-icons.py "$output/Backlit.iconset" "$output/Backlit.icns"
cp "$output/icon-master.png" assets/icon-master.png
cp "$output/Backlit.icns" assets/Backlit.icns
cp "$output/icon.png" docs/media/icon.png
python3 scripts/check_media.py --strip
echo "Generated the native icon, all ICNS representations, and README icon."
