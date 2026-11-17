**Backlit 0.2.8 — local candidate, not published**

### Improvements

- Clearer native Connections settings distinguish MCP control from automatic coding-status hooks.
- Optional Hide Dock icon setting, with the menu-bar icon shown and Dock icon hidden by default. Saved choices are preserved, and hiding the menu-bar icon restores Dock access first. Existing pinned Dock shortcuts are retained.
- Sidebar navigation responds across the full row.
- Dock visibility is rechecked after startup and activation.
- Native presentation is invalidated when recovery or busy checks prevent a normal frame.
- Customized legacy coding hooks are preserved when reconnecting or disconnecting Backlit.
- Packaging verifies the bundle's version and source provenance and rejects stale or concurrently changed build inputs.

### Qualification

Build 50 passed non-UI and isolated integration checks. It has not been installed or physically qualified. Sleep/wake, lid handback, emitted light, native shortcut suppression and fresh agent-session acceptance remain pending. Closed-lid lighting stays capped at 30 minutes and may keep the built-in screen lit.

This candidate is ad-hoc signed with hardened runtime, not Developer ID signed or notarized. No public release or tag has been created. See [validation](VALIDATION.md).
