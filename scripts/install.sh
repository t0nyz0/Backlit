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
install_committed=false
backup_dir=""
restore_install() {
  if [ "$install_committed" = false ] && [ -d "$stage_dir/Previous.app" ]; then
    if [ -d "$app_target" ]; then
      if ! mv "$app_target" "$stage_dir/Failed.app"; then
        echo "Rollback could not move the new bundle. Prior bundle retained at $stage_dir/Previous.app" >&2
        return 1
      fi
    fi
    if ! mv "$stage_dir/Previous.app" "$app_target"; then
      echo "Rollback could not restore the prior bundle. It remains at $stage_dir/Previous.app" >&2
      return 1
    fi
    open "$app_target" || true
  fi
  rm -rf "$stage_dir"
}
trap restore_install EXIT
trap 'exit 130' HUP INT TERM
ditto "$app_source" "$stage_dir/Backlit.app"
codesign --verify --deep --strict "$stage_dir/Backlit.app"
if [ -d "$app_target" ]; then
  # Verify and retain a copy BEFORE renaming the existing installation. `open`
  # returning zero means Launch Services accepted the request, not that the new
  # app survived startup. A normal EXIT must not delete the recoverable copy.
  codesign --verify --deep --strict "$app_target"
  mkdir -p "$PWD/dist/install-backups"
  backup_dir="$(mktemp -d "$PWD/dist/install-backups/previous.XXXXXX")"
  ditto "$app_target" "$backup_dir/Previous.app"
  codesign --verify --deep --strict "$backup_dir/Previous.app"
  cat > "$backup_dir/VALIDATION.txt" <<'EOF'
The previous app bundle passed strict nested signature verification before replacement.
Startup health of the replacement app has NOT been verified by this installer.
Retain this backup until the replacement has been explicitly validated.
This installer never removes retained backups; review/remove them manually after validation.
EOF
  mv "$app_target" "$stage_dir/Previous.app"
fi
mv "$stage_dir/Backlit.app" "$app_target"
open "$app_target"
install_committed=true
echo 'Installed /Applications/Backlit.app and requested launch; startup health is not yet verified.'
if [ -n "$backup_dir" ]; then echo "Verified prior bundle retained at $backup_dir/Previous.app"; fi
