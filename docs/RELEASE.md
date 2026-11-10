Backlit v0.1.9 adds Battery behavior customization while keeping automatic charging behavior as the default.

- Automatic pulse while actively charging, steady light while plugged in but not charging, and charge-level brightness while unplugged.
- Choose Automatic pulse, Steady, or Match battery level while plugged in, and adjust the pulse cycle.
- Optional charge-ready signals with a configurable threshold, style, and duration. They are off by default.
- Battery controls in Your light and Settings, plus Restore Battery Defaults. Existing preferences are preserved.

Backlit is a native MacBook PROLED logo-control source preview with original branding and interface. It also includes Steady, Breathe, Music, Agents, and Trackpad behaviors, plus an optional Home Assistant integration.

The ZIP and drag-to-Applications DMG are compiled on Apple silicon. The source package is an allowlisted snapshot without private research or Git history. BUILD-INFO.json records the exact source commit and signing status; SHA256SUMS.txt covers the packages. Quit any running Backlit before replacing the app in Applications.

This preview is ad-hoc signed, not Developer ID signed or notarized. Active-charging pulse was checked on the local Mac. Full/paused-charge and unplugged states are covered by automated tests, but their physical behavior remains unverified. Global screen touch is unavailable. Codex, login, administrator brightness overrides, closed-lid behavior, click accents, and optical latency retain separate verification gates. See docs/VALIDATION.md in the source package.
