#!/bin/bash
# Local Control Center preview only: package the existing artwork for modern
# macOS gallery lookups, without changing the standalone legacy app icon.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$#" -eq 1 && -d "$1/Contents/Resources" ]] || exit 2
resources="$1/Contents/Resources"
info="$1/Contents/Info.plist"
work="$(mktemp -d "$PWD/dist/control-gallery-icon.XXXXXX")"
trap 'rm -rf "$work"' EXIT
set="$work/Assets.xcassets/BacklitGalleryIcon.appiconset"
mkdir -p "$set"
iconutil -c iconset -o "$work/Backlit.iconset" assets/Backlit.icns
python3 - "$work" "$set" <<'PY'
import json, re, shutil, sys
from pathlib import Path

work, appicon = map(Path, sys.argv[1:])
metadata = {"version": 1, "author": "xcode"}
images = []
for path in sorted((work / "Backlit.iconset").glob("*.png")):
    m = re.fullmatch(r"icon_(\d+x\d+)(@2x)?\.png", path.name)
    if not m:
        continue
    shutil.copyfile(path, appicon / path.name)
    images.append({"idiom": "mac", "size": m[1], "scale": "2x" if m[2] else "1x",
                   "filename": path.name})
expected = {(f"{n}x{n}", scale) for n in [16,32,128,256,512] for scale in ["1x","2x"]}
if {(row["size"], row["scale"]) for row in images} != expected:
    raise SystemExit("Backlit.icns does not contain the full macOS app-icon set.")
(appicon.parent / "Contents.json").write_text(json.dumps({"info": metadata}) + "\n")
(appicon / "Contents.json").write_text(json.dumps({"info": metadata, "images": images}) + "\n")
PY
xcrun actool --compile "$resources" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon BacklitGalleryIcon --output-partial-info-plist "$work/partial.plist" \
    --output-format human-readable-text --errors "$work/Assets.xcassets"
test -s "$resources/Assets.car"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$info" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string BacklitGalleryIcon' "$info"
plutil -lint "$info"
