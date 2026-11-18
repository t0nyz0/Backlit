## Backlit 0.2.11

Prepared locally; not published. Public downloads remain unchanged until an
explicitly approved release passes exact-tag CI.

### Interface languages

- Adds Spanish, French, German, Japanese, Korean, Brazilian Portuguese,
  Simplified Chinese and Thai alongside English and Traditional Chinese.
- System Default follows macOS language preferences for Backlit. A manual
  language choice is available in Settings; existing choices are preserved.
- Mac regional number conventions remain independent of interface language.
- Native String Catalogs provide interface and permission-description resources;
  actionable connection errors preserve app names and diagnostic details.
- Includes localized menu, shortcut and accessibility text, including reconnect
  controls, with layout and placeholder regression coverage.

### Limits

Translations have automated consistency checks and sampled visual review, not a
complete native-speaker or live VoiceOver audit. macOS permission dialogs follow
its app-language choice and can require relaunch; the in-app choice does not
change system preferences. Some low-level diagnostics remain in English.

This remains an ad-hoc signed, non-notarized arm64 build. In-app updates are not
enabled without a trusted publisher feed and signing key. Existing hardware,
permission and closed-lid safety limits are unchanged. No new hardware-compatibility
claim is made by this language update.

## Backlit 0.2.10

The 0.2.9 tag is retained as a failed release attempt: packaging fixtures inherited the CI tag and stopped verification before any release files were published. 0.2.10 fixes that fixture isolation without weakening production package validation.

### Improvements

- New installations and Reset keep Control–Command–B for Toggle and leave brightness-up/down shortcuts Off. Existing shortcut choices are preserved on upgrade.

- Rejects excessively nested MCP requests before JSON parsing, preventing crashes of the local stdio MCP process.
- Breathing pace now ranges from 3 to 30 seconds, preserving existing settings.
- Supports native measured-output readback used by newer MacBook logo hardware.
- Known transient closed-lid failures receive bounded automatic recovery with persisted retry limits and exact-session cleanup verification. Recovery preserves the original closed-lid deadline; unknown faults and exhausted budgets still stop safely.
- Restore Light explicitly retries a recovered closed-lid fault without requiring an off/on toggle.
- More reliable ambient-setting reconnects and rapid closed-lid off/on changes.
- Removed an unnecessary launch-time Dock request that could leave a misleading warning in menu-bar-only mode.

### Validation limits

- Native logo output and breathing were observed on the local Mac after the readback correction. Automatic fault/relaunch recovery is covered by isolated end-to-end tests, not a deliberate live hardware-fault injection.
- Existing permission requirements, the 30-minute closed-lid limit, and ad-hoc signing/notarization limitations remain unchanged.

## Backlit 0.2.8

### New

- **Menu-bar mode:** Hide the Dock icon while keeping Backlit accessible from the menu bar.
- New installations show the menu-bar icon and hide the Dock icon by default. Existing preferences are preserved.

### Improvements

- **Clearer Connections:** MCP controls and AI agent activity are easier to distinguish.
- Click anywhere in a sidebar row to switch panels.
- Improved shortcut disabling and brightness-key handling while recording shortcuts.
- More accurate agent connection status, clearer repair options, and a warning when session counts are incomplete.
- Better preservation of customized agent hooks.
- Unavailable Trackpad mode stays selected and dark instead of unexpectedly switching to Steady.
- More reliable status refreshes during busy and recovery states.
- Added checks to keep release packages aligned with their source and build information.

### Good to know

- After updating, macOS may ask you to re-enable Backlit under Input Monitoring.
- Shift + hardware brightness keys remain experimental.
- Closed-lid lighting is limited to 30 minutes per cycle and may keep the built-in display lit.
- Backlit is ad-hoc signed, not notarized by Apple.
- An existing pinned Dock shortcut is retained, even when the running app's Dock icon is hidden.
