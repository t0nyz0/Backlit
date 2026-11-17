**Backlit 0.2.8 — local candidate, not published**

### Improvements

- Clearer native Connections settings distinguish MCP control from automatic coding-status hooks.
- Optional Hide Dock icon setting, with the menu-bar icon shown and Dock icon hidden by default. Saved choices are preserved, and hiding the menu-bar icon restores Dock access first. Existing pinned Dock shortcuts are retained.
- Sidebar navigation responds across the full row.
- Dock visibility is rechecked after startup and activation.
- Native presentation is invalidated when recovery or busy checks prevent a normal frame.
- Customized legacy coding hooks are preserved when reconnecting or disconnecting Backlit.
- Packaging uses a verified private bundle snapshot and frozen source/digest identity for both ZIP and DMG, rejecting concurrent rebuild races and preserving earlier output on failure.

### Follow-up fixes

- Automatic connection restoration reuses keys without prompting or creating replacements; an unavailable Home Assistant key no longer disables healthy local MCP.
- Agent metadata reads reject links/special files and enforce per-file and aggregate scan budgets, with explicit incomplete status when limited. Hook status checks the complete configuration and keeps repair/disconnect access for partial installations.
- Incomplete coding-session summaries and warnings are consistent in the menu and workspace; counts are qualified as observed until a complete snapshot returns.
- Initial hook-file creation does not overwrite a file created concurrently; existing-file writer races remain a known limit.
- Unavailable Trackpad stays selected and dark with a clear explanation, including after reopening.
- Lid helpers verify the parent's process-start identity to avoid following a reused PID.
- Recorder transitions preserve held Shift-brightness pairing; disabling ordinary shortcuts works even if handler creation failed.
- Imported manual controls reject malformed/nonfinite values before reaching sliders while preserving valid settings.
- MCP closes excessive pending-output pressure without changing request IDs or cancellation semantics.

### Qualification

Build 53 passed non-UI and isolated integration checks. It has not been installed or physically qualified. Sleep/wake, lid handback, emitted light, native shortcut suppression and fresh agent-session acceptance remain pending. Closed-lid lighting stays capped at 30 minutes and may keep the built-in screen lit.

This candidate is ad-hoc signed with hardened runtime, not Developer ID signed or notarized. No public release or tag has been created. See [validation](VALIDATION.md).
