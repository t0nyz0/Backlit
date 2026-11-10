#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_source="$PWD/dist/Backlit.app"
app_target="/Applications/Backlit.app"
[ -x "$app_source/Contents/MacOS/Backlit" ] || { echo 'Build first with bash scripts/build.sh'; exit 1; }
# Ask the running app to perform its own cleanup. Never force-kill it or copy
# over a live version that is still waiting for an off/restore decision.
"$app_source/Contents/MacOS/Backlit" --quit-running
stage_dir="$(mktemp -d /Applications/.backlit-install.XXXXXX)"
restore_install() {
  if [ -d "$stage_dir/Previous.app" ] && [ ! -d "$app_target" ]; then mv "$stage_dir/Previous.app" "$app_target"; fi
  rm -rf "$stage_dir"
}
trap restore_install EXIT
ditto "$app_source" "$stage_dir/Backlit.app"
codesign --verify --strict "$stage_dir/Backlit.app"
if [ -d "$app_target" ]; then mv "$app_target" "$stage_dir/Previous.app"; fi
mv "$stage_dir/Backlit.app" "$app_target"
open "$app_target"
echo 'Installed and reopened /Applications/Backlit.app'
