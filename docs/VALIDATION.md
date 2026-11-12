# Backlit validation

Version: **0.2.6**, build 38. Publication requires a passing [Build and package workflow](https://github.com/t0nyz0/Backlit/actions) for the exact `v0.2.6` tag. Check that run for its commit and results. BUILD-INFO.json records artifact source identity and signing status; SHA256SUMS.txt covers package bytes.

Build 38 was installed on the test Mac and is the build that was exercised there. Observed on that Mac: the app and its recovery helper start under the hardened runtime; with the lid open the logo holds the requested level; with closed-lid lighting on, closing and reopening the lid recovers without an error. A read-only recording of one 35-second closure showed the logo enabled for the whole closure at about 12% duty, which is consistent with the closed session using the native ambient-driven curve, while the built-in display was not reported asleep. Earlier internal builds 35 and 36 stopped light control on that lid transition; build 37 retries the cleanup and build 38 corrects the pause wording. These are functional observations on one Mac, not photometric measurements.

## Current limits

- Closed-lid lighting may leave the built-in screen lit. The screen was observed off after Backlit quit. The feature is retained with a 30-minute maximum and an explicit in-app warning; this limits duration but does not guarantee safe temperatures.
- Independent closed-lid brightness and physical sleep/wake/native handback remain unqualified. The separate finite-output experiments are excluded from this app.
- Some failed-cleanup paths retain a manual recovery requirement rather than completing automatic recovery. Saved fault pauses are not automatically cleared by the duration migration.
- The administrator-only ambient override retains the existing full-app elevation route. Its privilege boundary remains unresolved. All native adapters now require exact method signatures; those signatures were read on macOS 27.2.1 only, so another macOS version may report closed-lid controls as unsupported.

## Release checks

Build 38 source passed 566 Swift tests with zero failures, including 20 new cases for lid-transition session replacement, support-file pruning and signature matching, and 19 Python tests with three optional signing fixtures skipped. Every step of the workflow’s verify job was also replayed on a clean clone of the build 38 source and passed, including the Stream Deck typecheck, tests, audit, build and package, and the same six release files were produced; the three update-signature tests need a tool only the workflow provisions and were skipped locally. Hardened-runtime signing was checked on a copy of the app and on the packaged ZIP: it loads, strict signature verification passes and an injected library is refused. On build 38 the owner confirmed on the test Mac that Typing works under the hardened runtime. Music capture and the administrator prompt for the brightness-limit override have not been confirmed under it. The pairing-key change uses the real Keychain and has no automated test. With library validation disabled for Sparkle, the bundled framework is not protected against replacement.

The main-project source passed 546 Swift tests with zero failures, including 14 independent-brightness cases and nine new duration-cap migration and clock cases. Coverage includes bounded requested nits even if refresh resets the fade, zero-to-positive reapplication, previous/intended mapping ownership, original-curve restoration before Unblank, failed refresh retry, closed recovery without wake, and safety changes. Cap tests cover legacy hours/unlimited settings, exact deadlines, sleep/relaunch continuity, corrupted checkpoints, clock failure/regression and preservation of fault metadata.

Build 34 was installed with an exact binary/signature check and retained build 33 backup. Its running app and recovery helper were verified. All preferences matched the preinstallation backup, with closed-lid lighting and ambient override Off. The user physically reported that the logo stayed bright at 100% while display brightness was lowered. This is an observed functional check, not a photometric measurement or verification of every positive-to-positive slider update.

The build 35 cap is tested with inert clocks and temporary preferences/files, not a 30-minute live hardware run. No running-app setting or hardware state was changed to prepare it. Automated tests do not prove panel darkness, exact physical brightness, native handback or compatibility on other devices.

The unchanged integrations retain build 32 evidence: 16 Python tests passed with three optional signing fixtures skipped, and Stream Deck typecheck, 16 tests, build/package validation and zero-vulnerability audit passed. Those integration checks must also pass in the exact release CI. Existing screenshots remain explicitly labeled as older captures. Local source/build checks do not substitute for a passing release workflow on the exact published commit.

## Earlier validation history

The sections below describe prior checks and limitations; they are not a current release approval and do not override the blockers above.


Version: **0.2.4**, build 29. Publication requires a passing [Build and package workflow](https://github.com/t0nyz0/Backlit/actions) for the exact `v0.2.4` tag. Check that run for its commit and results. BUILD-INFO.json records artifact source identity and signing status; SHA256SUMS.txt covers package bytes.

## App icon regression

The 0.2.4 icon uses unchanged master artwork with regenerated smaller ICNS representations. A local Finder comparison reproduced white edge points with the released 0.2.3 ICNS and showed clean edges with the regenerated icon. The full-size representation is unchanged. The icon change does not alter settings.

## Closed-lid effects candidate

Requested mapping values could change while actual hardware output stayed fixed with the lid closed. The candidate uses feedback from the hardware fade factor, preserves ambient limits and keeps the keyboard dark. Effect batches and watchdog cleanup share an exclusive lock; cleanup revokes frame permission before resetting hardware. Exact endpoints can settle to one-second housekeeping. Interior levels retain bounded periodic feedback so abandoned native ramps cannot remain indefinitely.

On the test Mac, user-assisted installed-app checks verified closed-lid On, Breathe, and Music, including closing from Off before turning On. Exact Off was separately confirmed by zero hardware factor and disabled PWM. Earlier bounded probes also checked 30%/70% levels. The latest lifecycle and performance revisions still require final installed-app acceptance, including ordinary lid-policy transitions and graceful quit. Sleep/lock/crash recovery, external-display color preservation, and broader hardware compatibility are not established by these checks.

## Clamshell indicator regression

The logo-enable flag is sampled once per second, independently of the requested brightness mapping. Confirmed hardware-off produces dark previews and a dark menu bar icon; the menu label distinguishes “Off · lid closed” from unavailable readback. Seven regression cases cover disabled/open/closed, enabled closed-lid operation, unavailable readback, no ownership, isolated preview, and repeated close/reopen state transitions. Saved brightness is preserved.

## Closed-lid control regression

The existing opt-in helper sends a temporary CoreBrightness lid notification override only after macOS observes the real closed lid, then keeps keyboard modules in their closed state. Recovery is recorded before writes. It restores the current physical lid state, not a stale startup snapshot. Failed logo restoration does not prevent independent normal-sleep recovery, and logo-only records do not change unowned power state.

Regression tests cover durable-before-write ordering, repeated-poll suppression, missing keyboard capability, daemon readiness, partial/rejected writes, current-lid restoration, unknown state, cleanup retry, reopen/reclose state, independent recovery and ownership. Earlier duration-policy tests covered exact timer boundaries, no-timer sessions and retained safety cutoffs. Build 35 removes the no-timer option and caps all new and migrated sessions at 30 minutes, with or without an external display. Duration changes apply to a new session. Existing helper cancellation and lifecycle fixtures remain in place.

The private global notification also reaches display/color modules. Unchanged True Tone and color behavior has not been established. Broader compatibility, repeated physical lid transitions and keyboard restoration, external-display hotplug, real thermal/low-battery cutoffs and force-killed helper recovery remain hardware acceptance limits. No optical brightness measurement or broader hardware-compatibility claim is implied. No persistent brightness or security setting is changed by this option.

## Music capture

Selecting Music starts system playback capture when the app owns a ready light and the session is unlocked. Leaving Music stops capture. Failed requests do not retry automatically. A 30-second startup deadline reports a stalled native request while retaining its single worker until macOS returns and cleanup finishes; it does not forcibly cancel native audio work. One live setup was unusually slow before eventually succeeding, so timely startup across audio devices remains unverified. No audio is recorded.

## Manual-download controls

Settings offers Download Latest Version when trusted in-app updating is unavailable. It opens the installer page and explains manual replacement; internal publisher-configuration diagnostics stay hidden. Valid strict configuration retains Check for Updates. Preview disables downloads and in-app update checks. Six presentation regressions cover missing, invalid and valid configurations, policy flags, the destination and preview safety.

## Executed local checks

- 380 Swift tests cover effects, Battery requirements through the production model, preferences/migration, charge transitions, Music responses and malformed PCM, passive input timing, local bridge lifecycles, automation validation, update configuration/consent and device leases/recovery values.
- 17 Python tests cover Home Assistant Core/client fixtures, plugin archive validation, signed update payload/feed tampering, and disposable-filesystem local installer rollback cases.
- 16 Stream Deck tests cover command/settings validation, bounded ordering and failure recovery, inspector context/persistence, and package freshness. Typecheck/schema/license checks and dependency audit also pass locally.
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

Music and interactive effects use a capped 20 Hz feedback loop; Breathe, Battery and interior static levels use 10 Hz. Exact settled endpoints and paused states use one-second housekeeping. Previews publish at most 10 Hz, cache static artwork, and skip occluded windows. The independent recovery helper uses event-woken polling with a nominal 250 ms idle interval; this is not a hard scheduling guarantee. Input callbacks run only while eligible; hidden previews do not keep publishing frames. Tray/preview redraws are suppressed while the cached session/display state is unavailable; hardware effects keep their separate timing/safety policy and UI refresh resumes when the user returns. These mechanisms are not measured battery-life/latency claims.

The app targets Apple silicon/macOS 14+ and uses compatibility-sensitive private hardware/audio interfaces. Global screen-touch is unsupported. It is ad-hoc signed and not notarized. Sparkle requires a pinned publisher public key, signed feed/notes/archives, and a trusted manual bootstrap before updating older public versions. Current same-source hashes do not establish authenticity.

## Current candidate follow-up checks

Saved closed-lid intent tests cover explicit opt-in, separate-instance relaunch/upgrade, remaining continuous-time deadlines, invalid or expired records, startup while already closed, and expiry before another effect frame. Input tests cover production agent/contact/typing output and a 64-combination locked/sleeping/console/closed-lid eligibility matrix. These are isolated tests, not physical upgrade or external-input acceptance.

Physically confirmed during candidate development: Steady/On, exact Off, Breathe and Music with the lid closed. Battery at full charge and Agents idle, working, and present-attention states were subsequently confirmed by the user with the lid closed. External Trackpad/typing still need final physical validation; compatible external input hardware and required macOS permissions are prerequisites. No claim that an inaccessible built-in trackpad works with a closed lid.

The installer-style quit/relaunch path was physically checked after the run-loop scheduling fix: the first quit completed, recovery journals were removed, and relaunch connected without a recovery warning. The remembered closed-lid choice resumed.

Ad-hoc replacement builds can invalidate macOS Input Monitoring grants. A visible enabled entry does not prove the current binary is authorized. Typing requires a successful current-process access check; no permission bypass is attempted.

The user subsequently confirmed standalone Typing works with the lid closed after reauthorizing the installed build; the app reported Ready for typing. Permission-feedback follow-up tests use inert access APIs and do not request live permissions. External Trackpad contact has not been physically verified.
