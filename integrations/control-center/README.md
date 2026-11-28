# Backlit Control Center

The signed Backlit 0.2.12 ZIP and DMG include the **Backlit** control for
macOS 27 or later. Open Backlit once, then add it from **Control Center → Edit
Controls**. Keep Backlit running in the background. On earlier supported
versions of macOS, use the menu bar or keyboard shortcut.

## Development builds

`BACKLIT_LOCAL_CONTROL_BUILD=1 bash scripts/build.sh` builds only the host
for development, under `dist/Backlit-Control-Preview.app`.
`bash scripts/build-control-extension.sh` builds a standalone extension.
Neither command embeds or registers the extension or grants App Group access.
`scripts/package.sh` is the ad-hoc CI packaging path and rejects the preview
marker, extension, gallery icon catalog, Control Center intent, and App Group
metadata. Only the verified Developer ID-signed and notarized release assets
ship the control.

## Implemented and checked

- One macOS 27+ WidgetKit toggle named **Backlit**, using an authenticated background
  `SetValueIntent`. No slider, hardware access, network listener or IPC exception.
- Host power requests use the existing complete external admission policy; no
  public automation enabling, mode changes, permission requests or recovery bypass.
- Requested power is separate from active control. Enabled does not promise
  measured illumination; effects may legitimately have dark frames.
- Minimal versioned App Group snapshot; missing, malformed, oversized, unavailable,
  future or older-than-60-second samples fail closed rather than masquerading as Off.
  No credentials, diagnostics, audio, user/session identifiers or paths are shared.
- Host publishes every 20 seconds and on model updates, invalidates on orderly
  termination. WidgetKit owns display caching: the age check applies when queried,
  not a guarantee a cached display disappears 60 seconds after a crash.
- `swift test -Xswiftc -D -Xswiftc BACKLIT_CONTROL_CENTER` tests inert host/state
  semantics, not live widget registration or hardware.
- The standalone macOS 27 extension build validates the shared intent metadata,
  private-path absence and ad-hoc signature. No install or launch.

## Upgrading from a local preview

If you added the control from an earlier preview, remove that tile and add
**Backlit** again from the Control Center gallery. This does not reset app settings.

## Release verification and limits

The released host and extension were signed with the same team and App Group.
The final ZIP and DMG copies were both installed and registered on the test Mac.
The owner exercised the tile and confirmed it does not bring the running app
window forward. This does not establish crash recovery, behavior during sleep
or lock, unsupported hardware, denied permissions, or broader VoiceOver
acceptance. If you fully quit Backlit, reopen it before using the tile.

The extension has no action handler and fails safely if dispatched there. The
inert host/state tests and development build checks do not substitute for native
registration or physical hardware tests.

## Apple references
- https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system
- https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents
- https://developer.apple.com/documentation/xcode/accessing-app-group-containers
- https://developer.apple.com/forums/thread/776568
