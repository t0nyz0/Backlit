# Contributing to Backlit

Use Xcode's macOS SDK, run `swift test`, then `bash scripts/build.sh`. Keep the effect engine independent of hardware. New integrations must preserve unrelated configuration, bound their inputs, and avoid content collection. Device changes need before/after evidence and restoration; use `--preview` for UI work.

The Home Assistant checks use Python 3.14 and Home Assistant 2026.11.1:

```sh
uv venv --python 3.14 .venv-ha
uv pip install --python .venv-ha/bin/python homeassistant==2026.11.1
.venv-ha/bin/python -m unittest discover -s Tests/Python -v
```

`bash scripts/package.sh` creates ZIP/DMG/source packages from a clean committed tree. Version tags must match the app version. GitHub Actions runs on `macos-26`; actions are pinned to commit hashes, ordinary jobs have read-only repository access, and only the tag-release job can publish release assets. No signing credentials are required or stored.

Never commit pairing keys, hook input, local configuration, raw audio, or live private account data. Native screenshots are generated with `--capture-suite`; keep their preview label and provenance intact. Do not describe an unmeasured physical behavior as verified.

The project uses PolyForm Perimeter 1.0.0, not an OSI open-source license. Contributions must be compatible with those terms.
