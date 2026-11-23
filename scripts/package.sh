#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo 'Commit the source and media before packaging.' >&2; exit 1; }
app_bundle="$PWD/dist/Backlit.app"
codesign --verify --deep --strict "$app_bundle"
# Freeze one verified identity for every artifact, even if HEAD later changes.
package_work="$(mktemp -d "$PWD/dist/package-work.XXXXXX")"
final_output="$PWD/dist/packages"
previous_output="$package_work/previous-packages"
output_committed=false
cleanup_package() {
  result=$?
  if [ "$output_committed" = false ] && [ -e "$previous_output" ]; then
    if [ -e "$final_output" ] || ! mv "$previous_output" "$final_output"; then
      echo "Could not restore previous packages; retained at $previous_output" >&2
      return 1
    fi
  fi
  rm -rf "$package_work"
  return "$result"
}
trap cleanup_package EXIT
trap 'exit 130' HUP INT TERM
verified_record="$package_work/frozen-build.json"
python3 scripts/build-provenance.py freeze "$app_bundle" --output "$verified_record"
# A private snapshot is the sole app input from this point. Builds may replace
# dist/Backlit.app; they must never mutate the bundle used by either package.
snapshot_bundle="$package_work/app/Backlit.app"
mkdir -p "$(dirname "$snapshot_bundle")"
ditto "$app_bundle" "$snapshot_bundle"
codesign --verify --deep --strict "$snapshot_bundle"
python3 scripts/build-provenance.py verify "$snapshot_bundle" --frozen "$verified_record"
python3 - "$snapshot_bundle" <<'PY_RELEASE_FLAVOR'
import plistlib
from pathlib import Path
import sys

contents = Path(sys.argv[1], 'Contents')
info = plistlib.loads((contents / 'Info.plist').read_bytes())
resources = contents / 'Resources'
metadata = [p for p in resources.iterdir() if p.name.lower() == 'metadata.appintents']
if ('BacklitLocalControlPreview' in info or 'BacklitControlAppGroup' in info
        or (contents / 'PlugIns').exists() or (resources / 'Assets.car').exists()
        or any(b'SetBacklitControlPowerIntent' in p.read_bytes()
               for folder in metadata for p in folder.rglob('*') if p.is_file())):
    raise SystemExit('Local Control Center artifacts cannot be packaged as a public release.')
PY_RELEASE_FLAVOR
source_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["provenance"]["source_commit"])' "$verified_record")"
source_short="$(git rev-parse --short "$source_commit")"
app_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["provenance"]["version"])' "$verified_record")"
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
app_architectures="$(lipo -archs "$snapshot_bundle/Contents/MacOS/Backlit")"
app_arch="${app_architectures// /-}"
# Do not leave a failed or raced candidate looking like finished release output.
output_dir="$package_work/packages"
mkdir -p "$output_dir"
app_stem="Backlit-$app_version-macOS-$app_arch"
ditto -c -k --keepParent "$snapshot_bundle" "$output_dir/$app_stem.zip"
dmg_root="$package_work/dmg-root"
mkdir -p "$dmg_root"
ditto "$snapshot_bundle" "$dmg_root/Backlit.app"
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
python3 - "$output_dir" "$verified_record" "$app_architectures" <<'PY'
import hashlib,json,sys
from pathlib import Path
out=Path(sys.argv[1]);frozen=json.loads(Path(sys.argv[2]).read_text());info=frozen['provenance']
record={'version':info['version'],'build':info['build'],
        'source_commit':info['source_commit'],
        'architecture':sys.argv[3], 'app_bundle_sha256':frozen['bundle_sha256'],
        'signing':'ad-hoc','developer_id_signed':False,'notarized':False,
        'artifacts':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir()) if p.suffix in {'.zip','.dmg','.streamDeckPlugin'}}}
(out/'BUILD-INFO.json').write_text(json.dumps(record,indent=2)+'\n')
files=sorted(p for p in out.iterdir() if p.name!='SHA256SUMS.txt')
(out/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
PY
# Changes during DMG/source generation invalidate this attempt. Existing output
# remains available and the staged attempt is removed by the trap on failure.
codesign --verify --deep --strict "$snapshot_bundle"
python3 scripts/build-provenance.py verify "$snapshot_bundle" --frozen "$verified_record"
python3 scripts/build-provenance.py verify "$app_bundle" --frozen "$verified_record"
if [ -e "$final_output" ]; then mv "$final_output" "$previous_output"; fi
mv "$output_dir" "$final_output"
output_committed=true
echo "$final_output"
