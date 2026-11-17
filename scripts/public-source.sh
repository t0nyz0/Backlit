#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
source_ref="${1:-HEAD}"
source_commit="$(git rev-parse --verify --end-of-options "$source_ref^{commit}")"
short_commit="$(git rev-parse --short "$source_commit")"
staging="$(mktemp -d "$PWD/dist/public-candidate.XXXXXX")"
export_root="$staging/Backlit"
mkdir "$export_root"
# Deliberate allowlist: source/build/tests and current public-facing docs. No
# Git metadata, private research screenshots, historical planning, or host state.
git archive "$source_commit" README.md LICENSE SECURITY.md CONTRIBUTING.md Package.swift Package.resolved .gitignore .github Sources Tests scripts assets homeassistant integrations docs/header.png docs/ICON.md docs/HOME-ASSISTANT.md docs/MCP.md docs/SHORTCUTS.md docs/PRIVACY.md docs/ATTRIBUTION.md docs/licenses docs/VALIDATION.md docs/RELEASE.md docs/media | tar -x -C "$export_root"
printf '{"source_commit":"%s","contains_git_history":false,"visibility_changed":false}\n' "$source_commit" > "$export_root/PUBLICATION.json"
ditto -c -k --keepParent "$export_root" "$PWD/dist/Backlit-public-source-$short_commit.zip"
echo "$export_root"
