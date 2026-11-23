# Control Center experiment (not in public builds)

The regular Backlit build targets macOS 14 and later. This separate local
experiment requires macOS 27 or later and is not part of the public build.
`BACKLIT_LOCAL_CONTROL_BUILD=1 bash scripts/build.sh` builds only the host
for development, under `dist/Backlit-Control-Preview.app`.
`bash scripts/build-control-extension.sh` builds a standalone extension.
Neither command embeds or registers the extension or grants App Group access.
The public packaging script rejects artifacts with the local preview marker,
extension, gallery icon catalog, Control Center intent, or App Group metadata.

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

## Upgrading the preview

If you added the control from an earlier local preview, remove that tile and add
**Backlit** again from the Control Center gallery. This does not reset app settings.

## No-ship gates

Compilation/signing is not App Group authorization or live discovery/action proof.
Before public release, establish a reproducible signed host and extension with the
same supported App Group, containing-app metadata and working macOS 27 background
routing to the host. The regular ad-hoc public build does not claim any of these.
The extension has no action handler and fails safely if dispatched there.

Controlled user testing must cover discovery, closed/relaunched app, quit/crash,
repeated requests, unsupported hardware, sleeping/locked/lid-closed states,
recovery/busy and denied permissions. Background intent mode does not prove a
cold app launch won't display Backlit's window. Control-specific strings are
English-only; native UI/VoiceOver and minimum-OS acceptance remain unverified.
No private IPC or fake-state fallback is acceptable.

Do not package this experiment as public Control Center support.

## Apple references
- https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system
- https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents
- https://developer.apple.com/documentation/xcode/accessing-app-group-containers
- https://developer.apple.com/forums/thread/776568
