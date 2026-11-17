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
