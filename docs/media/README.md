# Backlit native media

Workspace, Connections, Settings and menu views were recaptured for **0.2.1 (26)**. Battery shows the 82% unplugged preview fixture with no manual brightness slider. The existing original icon artwork is unchanged.

These are real native SwiftUI/AppKit views captured from the running Backlit executable using an owned-window capture path. They are not image-generated app mockups or borrowed screenshots.

```sh
bash scripts/build.sh
dist/Backlit.app/Contents/MacOS/Backlit --capture-suite "$PWD/docs/media"
```

Capture runs in isolated `--preview` mode. The sidebar says **ISOLATED PREVIEW**, and the logo illustration says **LIVE PREVIEW / Logo unchanged**. The battery fixture is 82%; no live agent sessions, existing home connection, credentials, recordings, or private settings are shown. The same production views and effect engine are used in the normal app. Preview does not change the physical logo, install hooks, register login items, start audio, or open a network listener.

`light-*`, `connections-*`, and `settings-*` show the running native workspace in both appearances. Settings is a scrollable viewport, so controls below its fold remain accessible in the app. `menu-light.png` captures the same native menu panel on an opaque background with all labels readable. Additional light-mode captures show Music presets, Trackpad with optional typing switched off, Other apps with its UI switch on. Preview still disables live routing/listeners, input/audio capture and hook changes; the Other apps image is not a live integration pass. The existing original app icon is unchanged. The Buy Me a Coffee badge is the official third-party asset described in ../ATTRIBUTION.md.

Images are visually reviewed before staging. Their metadata is inspected for private paths or identity. Hardware verification is recorded separately; an animated drawing is not evidence of emitted light.
