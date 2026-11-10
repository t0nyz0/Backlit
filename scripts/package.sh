#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo 'Commit the source and media before packaging.' >&2; exit 1; }
app_bundle="$PWD/dist/Backlit.app"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' assets/Info.plist)"
if [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
  [ "${GITHUB_REF#refs/tags/}" = "v$app_version" ] || { echo 'Tag and app version differ.' >&2; exit 1; }
fi
codesign --verify --strict "$app_bundle"
python3 scripts/check_privacy.py
plugin_bundle="$PWD/integrations/streamdeck/com.t0nyz.backlit.sdPlugin"
plugin_package="$PWD/integrations/streamdeck/out/com.t0nyz.backlit.streamDeckPlugin"
if [ -f "$plugin_package" ]; then
  (cd integrations/streamdeck && npm run validate)
  python3 integrations/streamdeck/inspect-package.py "$plugin_package" "$plugin_bundle"
fi
app_arch="$(lipo -archs "$app_bundle/Contents/MacOS/Backlit" | tr ' ' '-')"
output_dir="$PWD/dist/packages"
# Packages are generated output, isolated from source and old release versions.
rm -rf "$output_dir"
mkdir -p "$output_dir"
app_stem="Backlit-$app_version-macOS-$app_arch"
ditto -c -k --keepParent "$app_bundle" "$output_dir/$app_stem.zip"
dmg_root="$(mktemp -d "$PWD/dist/dmg-root.XXXXXX")"
trap 'rm -rf "$dmg_root"' EXIT
ditto "$app_bundle" "$dmg_root/Backlit.app"
ln -s /Applications "$dmg_root/Applications"
cat > "$dmg_root/Installation.txt" <<'EOF'
Backlit installation
Quit the running Backlit before replacing it. Drag Backlit to Applications.
This release is ad-hoc signed, not Developer ID signed or notarized.
See the repository README and validation matrix for permissions and limits.
EOF
hdiutil create -volname Backlit -srcfolder "$dmg_root" -format UDZO -ov "$output_dir/$app_stem.dmg" > /dev/null
# The optional native plugin is distributed separately; no plugin SDK or
# development sources are loaded by the macOS controller.
if [ -f "$plugin_package" ]; then
  cp "$plugin_package" "$output_dir/Backlit-$app_version-StreamDeck.streamDeckPlugin"
fi
bash scripts/public-source.sh > /dev/null
cp "dist/Backlit-public-source-$(git rev-parse --short HEAD).zip" "$output_dir/Backlit-$app_version-source.zip"
python3 - "$output_dir" <<'PY'
import hashlib,json,plistlib,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1]);info=plistlib.loads(Path('assets/Info.plist').read_bytes())
record={'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],
        'source_commit':subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(),
        'architecture':subprocess.check_output(['lipo','-archs','dist/Backlit.app/Contents/MacOS/Backlit']).decode().strip(),
        'signing':'ad-hoc','developer_id_signed':False,'notarized':False,
        'artifacts':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir()) if p.suffix in {'.zip','.dmg','.streamDeckPlugin'}}}
(out/'BUILD-INFO.json').write_text(json.dumps(record,indent=2)+'\n')
files=sorted(p for p in out.iterdir() if p.name!='SHA256SUMS.txt')
(out/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
PY
echo "$output_dir"
