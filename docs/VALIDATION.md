# Backlit validation

Date: November 9, 2026. Version: **0.1.7**, build 16. Early source preview. The exact audited commit and binary checksums are recorded in the release's QA report rather than a self-referential commit field in this file.

## Passed

- 22 native Swift tests and five Python integration/client tests. Agent-hook regression coverage includes configuration overrides, migration of earlier Backlit hooks while preserving other commands, literal shell-path quoting, and invalid session rejection.

- Release packaging strips linker debug references and checks the compiled app for the local home path. The app bundles its license and attribution notices.
- Native Swift debug/test build and optimized app packaging on Apple silicon with Xcode's macOS 27.2 SDK.
- The installed private Core Audio tap received nonzero playback, and the owner confirmed the physical logo responds. Initial Music performance was reported slow/buggy; latency and efficiency are not established by functional capture.
- A synthetic PCM bass signal produces a bounded audio envelope, reset clears it, non-finite samples are discarded, and denied-capture errors provide a readable recovery message.
- Automated effects, off precedence, bounded output, battery scaling, explicit breathing cycles, attention patterns, HTTP framing/authentication, complete-command validation, real localhost bridge traffic, safe hook merging, metadata-only event storage/expiry, and recovery-curve checks.
- Native contact state filters hover, tracks separate paths/devices, handles release, and resets between sessions. Preference loading preserves stored brightness and pace.
- A nonblocking process lease prevents two Backlit instances from overwriting the same hardware recovery session.
- Python client tests against a real local HTTP fixture.
- The actual custom integration loaded in isolated Home Assistant **2026.11.1 Core**: pairing form rejects a wrong key, creates a valid entry, rejects duplicate devices, creates a light + three sensors + two binary sensors, applies brightness/effect service commands, marks preview output unavailable, and unloads.
- A live hardware check on MacBook PROLED **Mac17,12**, M5 Pro, macOS **27.2.1 (26B8132)** acknowledged a 120-nit curve and exactly restored the previous curve. PWM duty changed during the check; the display-brightness register remained **32768** before, during, and after. This is register/service evidence, not an optical measurement.
- The owner physically confirmed Breathe and global trackpad response. Breathe previously stayed steady because the app incorrectly applied the system Reduce Motion preference to the explicitly chosen hardware effect; that override was removed. PWM samples now vary while Reduce Motion remains enabled. Native installed-app interaction exercised mode selection, brightness, and breathing pace. Real native light/dark workspace and compact-menu screenshots were visually reviewed; the menu has an opaque readable background.
- Whole-row hit testing was exercised in the installed app by clicking empty trailing space to select Breathe, then restoring the prior behavior.
- Normal app Quit restores the previous curve. The installer uses the app's graceful quit path and refuses to overwrite a copy awaiting a quit/recovery decision.

## Implemented, with physical or owner-permission checks still separate

| Feature | What is implemented | Remaining verification |
| --- | --- | --- |
| Music | Private Core Audio tap on 14.2+, audio-only ScreenCaptureKit fallback on 14.0–14.1, streaming bass envelope, intensity, dark-between-beat option; plain-language permission recovery | Owner confirmed live playback drives the physical logo. Remaining: multiple sources/devices, protected audio, latency, and efficiency |
| Claude Code / Codex | Separate connectors, custom folders, reversible config merge, metadata extraction, event aggregation. The owner confirmed Claude Code works live | Codex live-session verification; Codex hook trust must be granted in Codex |
| Login launch | SMAppService registration/unregistration | Owner opt-in and actual login/reboot |
| Ambient override | Native administrator authorization, two-key backup/change/restore helper | Owner-authorized execution and physical range measurement; existing third-party limit settings were preserved |
| Closed-lid session | Separate watchdog, Apple user-client interface, parent/lease checks, monotonic 30-minute no-display deadline, battery/thermal limits, journal and cleanup | Physical lid closure with and without external display, permission availability on other builds, timeout and heat/battery cutoffs on real hardware |
| Leave dark after Quit | Explicit quit choice retains the zero curve and recovery record | Reboot/power-cycle persistence is not claimed; normal release/restore and the durable system `LEBacklightMode` setting are different things |
| Trackpad | Native MultitouchSupport path callbacks filtered to trackpad usage 13/5; global contact/release confirmed by owner. Optional device-specific click callback, no polling or coordinates | Click-accent behavior, missed-release stress testing, optical latency. Global screen touch FAILED: in-window gesture recognition worked, but global device path/frame and filtered passive IOHID streams delivered no screen contacts; Screen/Both are unavailable |
| Home Assistant at home | Packaged custom integration and authenticated opt-in bridge, tested in isolated Core | Pairing to the owner's existing home instance and its actual LAN policy |

## Efficiency policy

The effect engine computes bounded scalar output. Steady, Battery, Trackpad, off, and paused states use one-second housekeeping rather than a high-frequency animation timer. Breathing and active musical/agent effects use a capped 20 Hz update loop. Preview publication is capped at 10 Hz and isolated from the full workspace's observable state; native windows do not need to repaint all controls for each effect frame.

Trackpad adds callbacks only while selected and enabled. It does not poll a device, inspect coordinates, scan other applications, request keyboard-monitoring access, or seize a HID device. A down/up transition requests an immediate output update; software acknowledgement timing is distinct from emitted-light latency.

A 10-second sample with native Trackpad selected and the window visible while the owner tested measured **1.0% of one CPU core**, with **128.2 MiB RSS**. This is a short sample, not an idle benchmark.

The animation timer runs in common run-loop modes, so dragging controls does not pause it. Competing-controller detection uses application launch/quit events instead of repeated app enumeration. Unchanged power/agent values are not republished, and hidden previews do not keep redrawing. Audio envelope release is time-based, and stale audio packets fade out.

The release workflow builds ZIP/DMG/source packages and records signing status and exact source metadata. Its GitHub execution result is recorded in the release QA artifact, separately from local test evidence.

CPU measurements are a short local smoke check, not a battery-life guarantee or full Instruments profile. The release QA report records measured samples and conditions. If a touch input path cannot reliably deliver native events, it must remain experimental or be omitted; no heavy monitoring fallback is part of this release.

## Current limits

- Private Apple interfaces may change. Older macOS, Intel, other enclosure variants, and unknown logo hardware remain unverified.
- Lock observation includes a compatibility-sensitive session dictionary key. Sleep, display sleep, lock, lid closure, and user switching are distinct conditions.
- Force-killing both app and watchdog is not equivalent to a clean quit. Recovery records are retained for repair; a successful compile is not proof of crash cleanup under every condition.
- A view's glow is a calculated preview; neither it nor service readback is an optical sensor measurement.
- English/Traditional Chinese primary controls are present; this is not a claim that every diagnostic/error string is fully translated.
- Update checking opens GitHub Releases. No signed automatic updater is installed.
- The app is ad-hoc signed, not Developer ID signed/notarized. Source-preview release does not imply broad binary-distribution readiness.
