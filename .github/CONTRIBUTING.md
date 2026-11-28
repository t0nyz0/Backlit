# Contributing to Backlit

Use Xcode's macOS SDK, run `swift test`, then `bash scripts/build.sh`. Keep the effect engine independent of hardware. New integrations must preserve unrelated configuration, bound their inputs, and avoid content collection. Device changes need before/after evidence and restoration; use `--preview` for UI work.

The Home Assistant checks use Python 3.14 and Home Assistant 2026.11.1:

```sh
uv venv --python 3.14 .venv-ha
uv pip install --python .venv-ha/bin/python homeassistant==2026.11.1
.venv-ha/bin/python -m unittest discover -s Tests/Python -v
```

`bash scripts/package.sh` creates local ad-hoc ZIP, DMG and source packages. GitHub Actions uses pinned actions, read-only repository permissions, and CI-only artifacts. It cannot create or publish a release. For the signed 0.2.12 release, follow the [release preflight](../docs/RELEASE-PREFLIGHT.md). In-app updates remain disabled without a trusted signing key and signed feed.

Never commit pairing keys, hook input, local configuration, raw audio, or live private account data. Native screenshots are generated with `--capture-suite`; keep their preview label and provenance intact. Do not describe an unmeasured physical behavior as verified.

The project uses PolyForm Perimeter 1.0.0, not an OSI open-source license. Contributions must be compatible with those terms.

Optional signature fixtures use the official Sparkle 2.10.1 `sign_update` tool, with its path supplied as `BACKLIT_SPARKLE_SIGN_TOOL`. They generate ephemeral fixture keys and pass them through stdin; they never read Keychain or production signing keys. Without the tool, those three tests are explicitly skipped.
