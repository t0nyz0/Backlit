# Backlit native media

Workspace, Connections, Settings, menu, Music, Trackpad and Typing views are refreshed for **0.2.4 (29)**. The captures include standalone Typing, automatic Music capture controls, and remembered closed-lid settings. Battery uses the isolated 82% fixture. The original photographic header and app icon artwork are unchanged. These previews illustrate controls, not physical output.

These are real native SwiftUI/AppKit views captured from the running Backlit executable using an owned-window capture path. They are not image-generated app mockups or borrowed screenshots.

```sh
bash scripts/build.sh
dist/Backlit.app/Contents/MacOS/Backlit --capture-suite "$PWD/docs/media"
```

Capture runs in isolated `--preview` mode. The sidebar says **ISOLATED PREVIEW**, and the logo illustration says **LIVE PREVIEW / Logo unchanged**. The battery fixture is 82%; no live agent sessions, existing home connection, credentials, recordings, or private settings are shown. The same production views and effect engine are used in the normal app. Preview does not change the physical logo, install hooks, register login items, start audio, or open a network listener.

`light-*`, `connections-*`, and `settings-*` show the running native workspace in both appearances. Settings uses a taller owned native window with a 1,120-point content height to include the complete footer, Download Latest Version control and disabled-preview guidance. This is a capture-only geometry fixture; the normal app window is unchanged and Settings remains scrollable. The Music, Trackpad, Typing and Other apps images use the same capture height. `menu-light.png` captures the same native menu panel on an opaque background with all labels readable. Additional light-mode captures show Music presets, Trackpad with optional typing switched off, standalone Typing and its permission controls, and Other apps with its UI switch on. Preview still disables live routing/listeners, input/audio capture and hook changes; the Other apps image is not a live integration pass. The existing original app icon is unchanged. The Buy Me a Coffee badge is the official third-party asset described in ../ATTRIBUTION.md.

Images are visually reviewed before staging. Their metadata is inspected for private paths or identity. Hardware verification is recorded separately; an animated drawing is not evidence of emitted light.
