# Backlit native media

The retained screenshots below were captured for 0.2.5 (30); no new screenshot session was run for the later versions described here. The manifest `app_version` records that actual capture version, not the current package version. Running `scripts/check_media.py` validates the existing image hashes and dimensions without changing provenance. An explicit `--strip` removes PNG metadata and refreshes hashes while preserving the recorded capture version; after a new capture session, record its actual version deliberately. These older images do not show the 0.2.6 status heading, the 1–30 minute closed-lid duration control or the New Pairing Key button. They also predate the 0.2.8 Connections layout and Dock visibility setting.

The README labels retained screenshots as historical and omits the outdated Connections and Settings images. Those current pages are described in text. Historical assets remain here for provenance; they are not evidence of the current layout or defaults.

Workspace, Connections, Settings, menu, Music, Trackpad and Typing views are refreshed for **0.2.5 (30)**. The captures include standalone Typing, automatic Music capture controls, and remembered closed-lid settings. Battery uses the isolated 82% fixture. The original photographic header is unchanged. The standalone app icon is generated from the [centered-square native artwork](../ICON.md); all window captures include the same centered-square glyph. These previews illustrate controls, not physical output.

These are real native SwiftUI/AppKit views captured from the running Backlit executable using an owned-window capture path. They are not image-generated app mockups or borrowed screenshots.

```sh
bash scripts/build.sh
dist/Backlit.app/Contents/MacOS/Backlit --capture-suite "$PWD/docs/media"
```

Capture runs in isolated `--preview` mode. The sidebar says **ISOLATED PREVIEW**, and the logo illustration says **LIVE PREVIEW / Logo unchanged**. The battery fixture is 82%; no live agent sessions, existing home connection, credentials, recordings, or private settings are shown. The same production views and effect engine are used in the normal app. Preview does not change the physical logo, install hooks, register login items, start audio, or open a network listener.

`light-*`, `connections-*`, and `settings-*` show the running native workspace in both appearances. Settings uses a taller owned native window with a 1,120-point content height to include the complete footer, Download Latest Version control and disabled-preview guidance. This is a capture-only geometry fixture; the normal app window is unchanged and Settings remains scrollable. The Music, Trackpad, Typing and Other apps images use the same capture height. `menu-light.png` captures the same native menu panel on an opaque background with all labels readable. Additional light-mode captures show Music presets, Trackpad with optional typing switched off, standalone Typing and its permission controls, and Other apps with its UI switch on. Preview still disables live routing/listeners, input/audio capture and hook changes; the Other apps image is not a live integration pass. The Buy Me a Coffee badge is the official third-party asset described in ../ATTRIBUTION.md.

The README feature panels in `preview/panel-*.svg` and the download button are drawn by `scripts/render-readme-panels.py`. Their lids are illustrations of the light using Backlit's own square artwork; the motion is drawn, not recorded from hardware. Two panels embed native captures: `preview/menu-bar.jpg`, cropped to the popover, from a 0.2.12 development build in isolated preview, and `preview/main-window.jpg`, the top of the 0.2.5 `light-dark.png` capture scaled to 1,280 pixels wide. Replace a capture and rerun the script to refresh its panel. The flags in `preview/panel-languages.svg` are small simplified drawings, so they look the same on every system. `preview/light-effects.gif`, `preview/settings.gif` and `preview/connections.png` are earlier drawn previews that the README no longer shows.

Images are visually reviewed before staging. Their metadata is inspected for private paths or identity. Hardware verification is recorded separately; an animated drawing is not evidence of emitted light.
