#!/bin/bash
# Verify the exact six files signed, notarized and tested for Backlit 0.2.12.
# This is a read-only check. It never creates a tag, uploads or publishes.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/verify-signed-0212.sh <asset-directory>" >&2
  exit 2
fi
cd -- "$1"
files=(SHA256SUMS.txt BUILD-INFO.json Backlit-0.2.12-macOS-arm64.zip
       Backlit-0.2.12-macOS-arm64.dmg Backlit-0.2.12-source.zip
       Backlit-0.2.12-StreamDeck.streamDeckPlugin)
for file in "${files[@]}"; do
  if [[ ! -f "$file" || -L "$file" ]]; then
    printf 'Missing or non-regular asset: %s\n' "$file" >&2
    exit 1
  fi
done
# Pin the receipt itself so an ad-hoc repack and its regenerated hashes fail.
printf '%s  SHA256SUMS.txt\n' ac156084157715674484e71593de8be377fa05d4751acfcd8451e3080596b0e1 | shasum -a 256 --check
shasum -a 256 --check SHA256SUMS.txt
