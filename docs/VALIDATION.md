# Backlit validation

Version: **0.2.2**, build 27. Publication requires a passing [Build and package workflow](https://github.com/t0nyz0/Backlit/actions) for the exact `v0.2.2` tag. Check that run for its commit and results. BUILD-INFO.json records artifact source identity and signing status; SHA256SUMS.txt covers package bytes.

## Clamshell indicator regression

The logo-enable flag is sampled once per second, independently of the requested brightness mapping. Confirmed hardware-off produces dark previews and a dark menu bar icon; the menu label distinguishes “Off · lid closed” from unavailable readback. Seven regression cases cover disabled/open/closed, enabled closed-lid operation, unavailable readback, no ownership, isolated preview, and repeated close/reopen state transitions. Saved brightness is preserved.

Read-only checks on the test Mac confirmed closed lid and disabled logo despite nonzero stored PWM duty. The installed same-code local build was observed with a dark workspace preview and “Off · lid closed” while saved brightness stayed 100%. The owner confirmed the corrected menu state and visually confirmed closed-lid illumination on the installed 0.2.2 candidate. Repeated physical lid transitions remain unverified. No optical brightness measurement or broader hardware-compatibility claim is implied.

## Closed-lid control regression

The existing opt-in helper sends a temporary CoreBrightness lid notification override only after macOS observes the real closed lid, then keeps keyboard modules in their closed state. Recovery is recorded before writes. It restores the current physical lid state, not a stale startup snapshot. Failed logo restoration does not prevent independent normal-sleep recovery, and logo-only records do not change unowned power state.

On the test Mac with an external display, a bounded five-second probe and a 60-second visual test enabled the logo while the keyboard remained disabled. Cleanup and an independent test watchdog restored the original off state. The owner confirmed visible light. Integrated app toggle-on/off checks confirmed logo enable/disable, dark keyboard, released sleep assertion and cleared recovery journal. Production-helper checks also passed short timer expiry, graceful cancellation and parent-process exit. Native minutes/hours selection, Until turned off, and locked active-session controls were verified; the test preferences were restored to the 30-minute default. The external display stayed active and reported display nits were unchanged; this does not establish unchanged True Tone/color behavior.

Regression tests cover durable-before-write ordering, repeated-poll suppression, missing keyboard capability, daemon readiness, partial/rejected writes, current-lid restoration, unknown state, cleanup retry, reopen/reclose state, independent recovery and ownership. Duration-policy tests cover exact timer boundaries, no-timer sessions and retained safety cutoffs. Timers apply with or without an external display; Until turned off removes only the timer, not safety stops. Duration changes apply to a new session. Existing helper cancellation and lifecycle fixtures remain in place.

The private global notification also reaches display/color modules. Broader compatibility, physical reopening/keyboard restoration, external-display hotplug, real thermal/low-battery cutoffs and force-killed helper recovery remain hardware acceptance limits. No persistent brightness or security setting is changed by this option.

## Executed local checks

- 179 Swift tests cover effects, Battery requirements through the production model, preferences/migration, charge transitions, Music responses and malformed PCM, passive input timing, local bridge lifecycles, automation validation, update configuration/consent and device leases/recovery values.
- 17 Python tests cover Home Assistant Core/client fixtures, plugin archive validation, signed update payload/feed tampering, and disposable-filesystem local installer rollback cases.
- 15 Stream Deck tests cover command/settings validation, bounded ordering and failure recovery, inspector context/persistence, and package freshness. Typecheck/schema/license checks and dependency audit also pass locally.
- Optimized arm64 build, four-action AppIntents metadata extraction, nested framework/helper code-signature verification, source exclusions, artifact hashes/ZIP CRCs/DMG, documentation/media integrity and privacy/secret scans are checked locally.

Battery tests use saved manual levels of 0%, 25%, 50%, and other values; every unplugged percentage including zero is tested. Default/migrated preferences, active/full/paused/unplugged transitions, optional styles/cues, mode switching and preserved manual settings are covered. The corrected tests exercise the production model, rather than treating a manual-brightness multiplier as the expected result. Native captures show the workspace and menu output without a Battery manual slider.

Battery pulse-floor tests cover arbitrary 20 Hz phases, delayed timestamps and cycle crossing. The floor is delivered on the next available frame and the pulse restarts smoothly; this cannot make a stalled process produce timely physical frames. Explicit zero writes bypass near-zero coalescing. Optical darkness and timing still need device observation. Menu visibility preference, repeated item lifecycles and asynchronous closed-lid cleanup/recovery are covered by isolated fixtures.

Preview geometry/render tests verify fixed centered square marks at off/low/mid/high levels, filled corners, a continuous concentric halo, and finite rendering for invalid inputs.

Screenshots are captured from current native views in isolated preview; they illustrate UI and do not measure emitted light. See [provenance](media/README.md).

## Boundaries

| Area | Acceptance limit |
| --- | --- |
| Battery | Automated/model tests do not establish natural full-charge optical behavior on every device. Hardware reads and preview values are not optical measurements. |
| Music | Playback devices, protected audio, perceived latency and sustained whole-app resource use still need live acceptance. No performance guarantee. |
| Typing | Input Monitoring, Secure Input, sleep/lock/user-switch handling need live acceptance. No permission bypass. |
| Shortcuts | Native actions are unavailable in this ad-hoc signed build. Four basic actions extract as metadata, which is not a discovery pass. |
| Stream Deck | Fixture/plugin packaging tests pass; actual key/profile use remains unverified. |
| Home Assistant / agents | Local fixtures pass; existing installation/LAN policy and live Codex compatibility remain separate checks. |
| Updater | Trust key/feed missing, so disabled. A disposable two-version host passed a signed upgrade/relaunch and rejected a modified signed feed. Its routes used fixture-only localhost overrides and synthetic restoration. Production transport/signing, resumed/interrupted updates, cancellation acknowledgement and failure rollback/relaunch remain unverified. |
| Local installer | Fixtures cover copy/signature/swap/launch failure, interruption, failed rollback moves, and accepted launch followed by immediate exit. A verified prior bundle is retained until explicit validation; launch acceptance alone is not a health check. Separate from Sparkle's installer. |
| Hardware / power | Other hardware/OS, login/reboot, administrator overrides, physical lid closure/timeout/thermal cutoffs, and forced termination recovery remain separate gates. |

## Efficiency and distribution

Animated effects use a capped 20 Hz loop and previews a capped 10 Hz publication rate. Static/off/paused states use one-second housekeeping. Input callbacks run only while eligible; hidden previews do not keep publishing frames. Tray/preview redraws are suppressed while the cached session/display state is unavailable; hardware effects keep their separate timing/safety policy and UI refresh resumes when the user returns. These mechanisms are not measured battery-life/latency claims.

The app targets Apple silicon/macOS 14+ and uses compatibility-sensitive private hardware/audio interfaces. Global screen-touch is unsupported. It is ad-hoc signed and not notarized. Sparkle requires a pinned publisher public key, signed feed/notes/archives, and a trusted manual bootstrap before updating older public versions. Current same-source hashes do not establish authenticity.
