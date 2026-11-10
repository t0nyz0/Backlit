#!/bin/bash
# Called only by an explicitly requested future build, never at app launch.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "Backlit Shortcuts metadata: $*" >&2; exit 1; }
backlit_compiler="$(xcrun --find swiftc)"
backlit_toolchain="$(cd "$(dirname "$backlit_compiler")/../.." && pwd)"
backlit_protocols="$backlit_toolchain/usr/share/swift/SwiftConstantValues/AppIntents.json"
[ -s "$backlit_protocols" ] || fail 'The selected Xcode toolchain has no AppIntents protocol list. Select a full supported Xcode installation.'

if [ "${1:-}" = protocols ] && [ "$#" -eq 1 ]; then
    printf '%s\n' "$backlit_protocols"
    exit 0
fi
[ "$#" -eq 3 ] && [ "$1" = extract ] || fail 'Usage: shortcuts-metadata.sh protocols | extract APP_BUNDLE TARGET_TRIPLE'
backlit_bundle="$2"
backlit_target="$3"
case "$backlit_bundle" in "$PWD"/dist/*.app) ;; *) fail 'App bundle must be a generated app under this project’s dist directory.' ;; esac
case "$backlit_target" in arm64-apple-macos*|x86_64-apple-macos*) ;; *) fail 'Pass the same macOS target triple used for compilation.' ;; esac
backlit_binary="$backlit_bundle/Contents/MacOS/Backlit"
[ -x "$backlit_binary" ] || fail 'Compile and copy the app binary before extracting metadata.'
backlit_work="$PWD/dist/appintents"
backlit_const="$backlit_work/Backlit.swiftconstvalues"
[ -s "$backlit_const" ] || fail 'Missing compiler constants. Build Backlit with -const-gather-protocols-list and -emit-const-values-path before this step.'
backlit_processor="$(xcrun --find appintentsmetadataprocessor)"
backlit_help="$("$backlit_processor" --help 2>&1 || true)"
# Xcode 27 exposes some registered options in its binary but omits them in help.
backlit_options="$backlit_help
$(/usr/bin/strings "$backlit_processor")"
backlit_sdk="$(xcrun --sdk macosx --show-sdk-path)"
backlit_xcode_build="$(xcodebuild -version | awk '/Build version/{print $3;exit}')"
[ -n "$backlit_xcode_build" ] || fail 'Could not read the selected Xcode build version.'
backlit_deployment="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$backlit_bundle/Contents/Info.plist")"
backlit_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$backlit_bundle/Contents/Info.plist")"
backlit_resources="$backlit_bundle/Contents/Resources"
mkdir -p "$backlit_work" "$backlit_resources"

python3 - "$PWD" "$backlit_work" "$backlit_const" "$backlit_resources" <<'PY'
import json
from pathlib import Path
import shutil
import sys
root,work,const,resources=map(Path,sys.argv[1:])
if not resources.resolve().is_relative_to((root/'dist').resolve()):
    raise SystemExit('Backlit Shortcuts metadata: output escapes generated dist directory.')
try:
    values=json.loads(const.read_text())
except (OSError,ValueError):
    raise SystemExit('Backlit Shortcuts metadata: compiler constant-value JSON is missing or invalid.')
if not isinstance(values,(dict,list)) or not values:
    raise SystemExit('Backlit Shortcuts metadata: compiler emitted no AppIntents constants; check protocol-gather flags.')
sources=sorted(root.joinpath('Sources/Backlit').glob('*.swift'))
(work/'sources.list').write_text(''.join(str(path.resolve())+'\n' for path in sources))
(work/'constants.list').write_text(str(const.resolve())+'\n')
# These are generated extraction outputs, not user data. Avoid accepting stale
# metadata if the processor skips extraction for the new executable.
for path in resources.iterdir():
    if path.name.lower()=='metadata.appintents':
        if path.is_symlink():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
PY

backlit_args=(
    --toolchain-dir "$backlit_toolchain"
    --module-name Backlit
    --sdk-root "$backlit_sdk"
    --xcode-version "$backlit_xcode_build"
    --platform-family macOS
    --deployment-target "$backlit_deployment"
    --target-triple "$backlit_target"
    --output "$backlit_resources"
    --source-file-list "$backlit_work/sources.list"
)
case "$backlit_help" in
    *--swift-const-vals-list*) backlit_args+=(--swift-const-vals-list "$backlit_work/constants.list") ;;
    *) fail 'This processor does not advertise constant-value input; adapt this build step to the selected Xcode version.' ;;
esac
case "$backlit_help" in
    *--binary-file*) backlit_args+=(--binary-file "$backlit_binary") ;;
esac
case "$backlit_options" in
    *--bundle-identifier*) backlit_args+=(--bundle-identifier "$backlit_identifier") ;;
esac
case "$backlit_options" in
    *--compile-time-extraction*) backlit_args+=(--compile-time-extraction) ;;
esac
case "$backlit_help" in
    *--deployment-aware-processing*) backlit_args+=(--deployment-aware-processing) ;;
esac
case "$backlit_help" in
    *--no-app-shortcuts-localization*) backlit_args+=(--no-app-shortcuts-localization) ;;
esac
# Never use --force-metadata-output: it suppresses errors in invalid intents.
"$backlit_processor" "${backlit_args[@]}"

python3 - "$backlit_resources" <<'PY'
from pathlib import Path
import sys
resources=Path(sys.argv[1])
folders=[p for p in resources.iterdir() if p.is_dir() and p.name.lower()=='metadata.appintents']
if len(folders)!=1:
    raise SystemExit('Backlit Shortcuts metadata: extraction produced no unique Metadata.appintents directory. Do not package this build as Shortcuts-ready.')
files=[p for p in folders[0].rglob('*') if p.is_file() and p.stat().st_size]
if not files:
    raise SystemExit('Backlit Shortcuts metadata: extraction output is empty.')
content=b'\n'.join(p.read_bytes() for p in files)
for name in [b'ToggleBacklightIntent',b'SetBacklightPowerIntent',b'SetBacklightBrightnessIntent',b'SetBacklightBehaviorIntent',b'SendBacklightSignalIntent']:
    if name not in content:
        raise SystemExit('Backlit Shortcuts metadata: expected action is missing; inspect extraction output before packaging.')
normalized=content.replace(b'\\/',b'/')
private_roots=[b'/' + name + b'/' for name in (b'Users',b'Volumes',b'var/folders')]
if any(value in normalized for value in [str(Path.home()).encode(),*private_roots]):
    raise SystemExit('Backlit Shortcuts metadata: private host path found in generated metadata. Fix compiler prefix mapping before packaging.')
print('Extracted metadata includes all five Backlit actions. Discovery in Shortcuts still requires a packaged-app runtime check.')
PY
