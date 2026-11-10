Backlit 0.2.1 (build 26) for MacBook PROLED.

Fixes a Swift compiler option used during packaging so release builds complete on the GitHub Actions toolchain.

Battery mode now follows the battery percentage exactly when unplugged, independently of saved manual brightness. The default pulses only during active charging and stays solid when charging pauses or finishes. Pulse speed, the “Dim to” minimum, optional plugged-in styles and charge-ready cues are configurable. The workspace and menu label battery-driven output; other modes retain manual brightness.

Saved selections for the removed activity mode migrate to Battery while preserving other settings.

This release also includes square lid previews, a hideable menu bar icon with Dock/Applications recovery, Music response presets and automatic level adjustment, optional timing-only typing response, and local automation links. The Stream Deck integration is experimental. Native Shortcuts actions are unavailable in this ad-hoc signed build.

Download the Apple silicon ZIP or DMG and replace the app manually. The app is ad-hoc signed, not Developer ID signed or notarized. In-app updates remain disabled because no production publisher key or signed feed is provisioned. A disposable signed update fixture passed installation/relaunch and rejected a modified feed; that does not establish production updater trust, resumed/cancelled installation, interruption recovery or rollback.

Assets include the app ZIP/DMG, source archive, separate Stream Deck add-on, BUILD-INFO.json and SHA256SUMS.txt. Build metadata records the exact source commit. Checksums detect changed bytes; they do not authenticate the publisher. Release publication requires passing CI for the exact version tag.

See [validation and known limits](https://github.com/t0nyz0/Backlit/blob/v0.2.1/docs/VALIDATION.md), [installation](https://github.com/t0nyz0/Backlit/blob/v0.2.1/README.md#install) and [privacy](https://github.com/t0nyz0/Backlit/blob/v0.2.1/docs/PRIVACY.md).
