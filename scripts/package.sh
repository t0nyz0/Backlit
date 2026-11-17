#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo 'Commit the source and media before packaging.' >&2; exit 1; }
app_bundle="$PWD/dist/Backlit.app"
codesign --verify --deep --strict "$app_bundle"
# Freeze one verified identity for every artifact, even if HEAD later changes.
package_work="$(mktemp -d "$PWD/dist/package-work.XXXXXX")"
trap 'rm -rf "$package_work"' EXIT
verified_record="$package_work/verified-build.json"
python3 scripts/build-provenance.py verify "$app_bundle" --output "$verified_record"
source_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$verified_record")"
source_short="$(git rev-parse --short "$source_commit")"
app_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$verified_record")"
if [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
  [ "${GITHUB_REF#refs/tags/}" = "v$app_version" ] || { echo 'Tag and app version differ.' >&2; exit 1; }
fi
python3 scripts/check_privacy.py
plugin_bundle="$PWD/integrations/streamdeck/com.t0nyz.backlit.sdPlugin"
plugin_package="$PWD/integrations/streamdeck/out/com.t0nyz.backlit.streamDeckPlugin"
if [ -f "$plugin_package" ]; then
  (cd integrations/streamdeck && npm run validate)
  python3 integrations/streamdeck/inspect-package.py "$plugin_package" "$plugin_bundle"
fi
app_arch="$(lipo -archs "$app_bundle/Contents/MacOS/Backlit" | tr ' ' '-')"
final_output="$PWD/dist/packages"
# Do not leave a failed or raced candidate looking like finished release output.
output_dir="$package_work/packages"
mkdir -p "$output_dir"
app_stem="Backlit-$app_version-macOS-$app_arch"
ditto -c -k --keepParent "$app_bundle" "$output_dir/$app_stem.zip"
dmg_root="$package_work/dmg-root"
mkdir -p "$dmg_root"
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
bash scripts/public-source.sh "$source_commit" > /dev/null
cp "dist/Backlit-public-source-$source_short.zip" "$output_dir/Backlit-$app_version-source.zip"
python3 - "$output_dir" "$verified_record" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1]);info=json.loads(Path(sys.argv[2]).read_text())
record={'version':info['version'],'build':info['build'],
        'source_commit':info['source_commit'],
        'architecture':subprocess.check_output(['lipo','-archs','dist/Backlit.app/Contents/MacOS/Backlit']).decode().strip(),
        'signing':'ad-hoc','developer_id_signed':False,'notarized':False,
        'artifacts':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir()) if p.suffix in {'.zip','.dmg','.streamDeckPlugin'}}}
(out/'BUILD-INFO.json').write_text(json.dumps(record,indent=2)+'\n')
files=sorted(p for p in out.iterdir() if p.name!='SHA256SUMS.txt')
(out/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
PY
# Changes during DMG/source generation invalidate this attempt. Existing output
# remains available and the staged attempt is removed by the trap on failure.
python3 scripts/build-provenance.py verify "$app_bundle"
rm -rf "$final_output"
mv "$output_dir" "$final_output"
echo "$final_output"
