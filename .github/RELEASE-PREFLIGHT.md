# Signed Backlit 0.2.12 release

GitHub Actions verifies source and generates ad-hoc **CI-only** artifacts. No
workflow has permission to create a release. Never upload the CI ZIP or DMG as
the 0.2.12 public download: neither includes the signed Control Center build.

## Before publication

1. Approve the README and release notes. Run CI on the release-preflight
   changes and confirm the workflow has no release job and only read access.
   Do not tag the older binary source commit: it still contains the old
   auto-publisher.
2. Keep the six exact assets from the signed candidate together. Run
   `bash scripts/verify-signed-0212.sh PATH_TO_CANDIDATE`. It pins the approved
   checksum manifest before checking its files, so a repack (even one with
   regenerated checksums) fails. The ZIP and DMG must both contain the
   notarized app, with the Backlit control extension. The DMG itself is also
   notarized.
3. Verify the commit authors and committers against the owner's exact approved
   identity and reject co-author trailers before pushing. The release tag
   must point to the reviewed commit containing the read-only workflow, as
   a fast-forward from `main`. The app code is unchanged from build 58;
   `BUILD-INFO.json` and the custom source ZIP identify the exact binary
   source commit `1aced8869d13454556037110c3da47c867d6431d`. GitHub's
   generated source archive describes the tag, which also includes the
   release-only changes.
4. Only after approval, create a draft for `v0.2.12` targeting that reviewed
   commit. Upload only the six verified files by name, not a wildcard or any
   CI artifact. Download the draft assets into a fresh directory and repeat the
   pinned checksum verification. Do not publish if any asset is missing, extra,
   or different. Publish from the reviewed draft, then verify the latest
   release, all six downloads, and the installer link.

## Upgrade caveat

Startup tests cover the saved-key success and failure paths, including a denied
Keychain read. They do not prove macOS will allow a different signing identity
to read every prior 0.2.11 user's keys. Do not guarantee silent migration.
The user guide and release notes explain how to re-enable an affected
connection without resetting Backlit or rotating its keys.
