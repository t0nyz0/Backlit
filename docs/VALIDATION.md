# Backlit validation

Version: **0.2.7, build 45**. Installed-app GUI and physical smoke checks for build 45 remain pending, including normal startup/quit, sleep/wake and closed-lid handback. The live GUI evidence below is from installed build 44 and is distinguished from build-45 headless and isolated checks.

Publication requires the exact source in a clean commit and a passing [Build and package workflow](https://github.com/t0nyz0/Backlit/actions) for the matching `v0.2.7` tag. Check the matching tagged workflow for its exact commit and outcome; local checks are recorded separately below. BUILD-INFO.json records artifact source identity and signing status; SHA256SUMS.txt covers package bytes.

## Current local checks

- **673 Swift tests passed**, with zero failures. Fourteen new recovery regressions exercise the production model with injected native operations; they do not trigger power or hardware failures on the live Mac.
- **21 Python tests passed**, with zero failures or skips. Two source-export regressions inspect the actual ZIP from a disposable committed repository, including public-document links, committed bytes, provenance, private-file exclusion and absence of Git history. Restoring the earlier allowlist makes the regression fail on missing MCP documentation.
- The optimized macOS 14 arm64 bundle built successfully and passed strict nested code-signature verification. It remains ad-hoc signed with the hardened runtime.
- The headless MCP subprocess checks passed initialization, the captured Codex runtime capabilities, strict arguments, negotiated versions, EOF, signals and message/output bounds. Those checks do not call a live light tool.
- Public-source checks found no Gitleaks findings across 241 committed public files plus the generated provenance record. The source export includes MCP, shortcut and icon documentation; all 36 archived local links resolve. Documentation checks and 13 media images passed. A scan of 106 bundled files found no private host paths.
- Canonical Stream Deck checks passed typecheck, 16 tests, build/package validation and dependency audit. The exact release workflow reruns these checks.

Local checks do not replace the matching tag/CI gate for publication.

## MCP acceptance

Installed build 44 was exercised with **Codex CLI 0.155.1**, using temporary invocation-only MCP settings. Codex connected, discovered all four tools, read the running app's status, set manual brightness to 50%, then returned it to 100%. Readback reported `applied`; Steady mode and the power setting were preserved. The checks did not register a permanent Codex server or change its persistent configuration. API output is not an optical measurement of emitted light.

Candidate 45's headless MCP binary also connected through the actual Codex client and read the unchanged installed build-44 GUI. This verifies candidate transport compatibility and its connection to the existing bridge. **It does not exercise the candidate-45 GUI, its recovery admission or native hardware behavior.** Claude Code user-session acceptance remains unverified.

Fixtures cover control policy, local Music/Typing authorization, automatic Battery brightness, recovery ownership, separate AI/Home Assistant keys, key replacement, cancellation, redirects, response bounds and real stdio pipes. The installed-client preference lookup and Codex's object-valued experimental capability are covered by regressions. MCP setup and access controls are described in [Local MCP control](MCP.md).

## Recovery checks

Candidate 45 blocks output and unsafe commands when recovery is orphaned or cannot be confirmed. The admission applies to startup, rearming, effect frames, MCP, shortcuts, ambient changes, readiness and quitting. Healthy owned recovery journals remain usable; dead owners enter cleanup. Recovery reports success only after both restoration stages succeed and a fresh check finds no remaining journal. Turning the light off, withdrawing control or quitting during repair prevents later automatic rearming.

Fourteen isolated regressions cover partial failure after logo cleanup, orphaned or corrupt journals, retained journals, healthy ownership, dead or pending helpers, update resume and user withdrawal. These tests use injected native operations and temporary files/preferences. Native power failure was not induced on the test Mac.

The ambient override invokes fixed system tools rather than elevating the app executable. Restore checks original values and originally absent keys through fresh readback before removing the saved copy. Failure retains the backup for retry. Tests cover failed deletion, silent write mismatch, unreadable readback, an already absent key and partial restoration. The real administrator prompt, system preference writes and brightness-service restart have not been exercised on build 45.

## Shortcut checks

Fixtures cover saved/custom/disabled bindings, registration conflicts, action IDs, recording suspension, manual bounds, Battery and power preservation, and recovery guards. The experimental hardware-key policy covers exact Shift, native/plain/Option–Shift preservation, paired key-up, changed modifiers, unknown repeats, repeat bounds and denied startup. Failed-update recovery restarts a saved enabled Shift filter without prompting; a denied restart stays off and reports the issue.

Synthetic events remain in memory and are never posted. Installing build 44 and passing these fixtures do not establish real shortcut dispatch in another foreground app. Accessibility/Input Monitoring behavior, actual Shift-only screen suppression, keyboard/Fn/Touch Bar variants, held repeats, permission revocation, sleep/wake and quit handback remain unverified. Hardware interception starts off. See [shortcut setup and acceptance](SHORTCUTS.md).

## Current limits and remaining acceptance

- Build 45 still needs normal installed startup, quit and relaunch acceptance with settings preserved and no unowned recovery left behind.
- Sleep/wake, closed-lid native handback and the 30-minute expiry need physical acceptance on the installed candidate. Do not intentionally force a native power failure on the live Mac to reproduce an injected regression.
- Closed-lid lighting may leave the built-in screen lit. Earlier testing observed it off after Backlit quit. The feature has a 30-minute maximum and an in-app warning; a time limit does not guarantee safe temperatures. Independent closed-lid brightness remains unqualified.
- Some failed-cleanup paths retain a manual recovery requirement. Saved fault pauses are not automatically cleared by duration migration.
- Visual logo output and independence from display brightness, ordinary global shortcut dispatch, and experimental Shift-key suppression/repeats need physical observation. Returned `applied` state and hardware readback do not measure emitted light.
- CoreBrightness Objective-C adapters check exact method signatures, observed on macOS 27.2.1. The private C multitouch ABI remains assumed; other OS/hardware combinations are not qualified. Trackpads are enumerated at initialization, so newly attached devices may require relaunch. Global screen-touch detection is unsupported.
- Hardware apply and restoration still run from the main actor. Native waits and recovery can affect responsiveness; no whole-app latency or battery-life guarantee is established.
- Home Assistant credentials are stored in Keychain, but its optional LAN transport is plaintext TCP. LAN sharing is off by default. AI MCP requests remain loopback-only.
- The app is ad-hoc signed and not Developer ID signed or notarized. Library validation is disabled for bundled Sparkle. In-app updates remain disabled without a trusted publisher key and signed feed; manual installation is the available path.

## Earlier validation history

The following results describe earlier builds. They are retained as background and do not qualify candidate 45's changed recovery or substitute for its remaining acceptance.

### Builds 34–41

Builds 38 and 39 were installed on the test Mac. On build 38, selecting Music started and stopped audio capture about twice a second: each beat that crossed zero produced a frame still waiting to observe its output, which was treated as hardware not ready. Build 39 keeps readiness across such brief waits and is otherwise identical to build 38, the build exercised for everything else below. Build 40 changes only Home Assistant pairing-key replacement: sharing now stops before the stored key changes and stays off if a new key cannot be created, so a failed replacement cannot leave the old key working. That path is covered by automated tests, including one against the real listener, and has not been exercised by hand. Observed on that Mac: the app and its recovery helper start under the hardened runtime; with the lid open the logo holds the requested level; with closed-lid lighting on, closing and reopening the lid recovers without an error. A read-only recording of one 35-second closure showed the logo enabled for the whole closure at about 12% duty, which is consistent with the closed session using the native ambient-driven curve, while the built-in display was not reported asleep. Earlier internal builds 35 and 36 stopped light control on that lid transition; build 37 retries the cleanup and build 38 corrects the pause wording. These are functional observations on one Mac, not photometric measurements.

The baseline 0.2.7, build 41 changed only the administrator step of the ambient override; everything else was the 0.2.6 code. That baseline passed 583 Swift tests with zero failures. Eight new cases run the real administrator script without administrator rights, against a temporary folder and a throwaway settings domain: saving the original limits once, writing the flat limits, restoring, restoring from a saved copy written by the 0.2.6 helper, refusing a wrong-owner or symlinked folder and a symlinked or unreadable saved copy, and checking that only system-owned tools are called. The same script was also run end to end through AppleScript without administrator rights. The privileged path itself, with the real password prompt, system limits and brightness-service restart, has not been exercised on build 41.

Build 40 source passed 575 Swift tests with zero failures, including 29 new cases for lid-transition session replacement, support-file pruning, signature matching, Music capture readiness and pairing-key replacement, and 19 Python tests with three optional signing fixtures skipped. Every step of the workflow’s verify job was also replayed on a clean clone of the build 38 source and passed, including the Stream Deck typecheck, tests, audit, build and package, and the same six release files were produced; the three update-signature tests need a tool only the workflow provisions and were skipped locally. Hardened-runtime signing was checked on a copy of the app and on the packaged ZIP: it loads, strict signature verification passes and an injected library is refused. On the test Mac the owner confirmed that Typing works on build 38 and that Music follows playback on build 39, both under the hardened runtime; the system log for that Music session shows a single audio capture that ran for about two minutes. The owner also confirmed that the administrator prompt for the brightness-limit override appears on build 39. The pairing-key change uses the real Keychain and has no automated test. With library validation disabled for Sparkle, the bundled framework is not protected against replacement.

The main-project source passed 546 Swift tests with zero failures, including 14 independent-brightness cases and nine new duration-cap migration and clock cases. Coverage includes bounded requested nits even if refresh resets the fade, zero-to-positive reapplication, previous/intended mapping ownership, original-curve restoration before Unblank, failed refresh retry, closed recovery without wake, and safety changes. Cap tests cover legacy hours/unlimited settings, exact deadlines, sleep/relaunch continuity, corrupted checkpoints, clock failure/regression and preservation of fault metadata.

Build 34 was installed with an exact binary/signature check and retained build 33 backup. Its running app and recovery helper were verified. All preferences matched the preinstallation backup, with closed-lid lighting and ambient override Off. The user physically reported that the logo stayed bright at 100% while display brightness was lowered. This is an observed functional check, not a photometric measurement or verification of every positive-to-positive slider update.

The build 35 cap is tested with inert clocks and temporary preferences/files, not a 30-minute live hardware run. No running-app setting or hardware state was changed to prepare it. Automated tests do not prove panel darkness, exact physical brightness, native handback or compatibility on other devices.

The unchanged integrations retain build 32 evidence: 16 Python tests passed with three optional signing fixtures skipped, and Stream Deck typecheck, 16 tests, build/package validation and zero-vulnerability audit passed. Those integration checks must also pass in the exact release CI. Existing screenshots remain explicitly labeled as older captures. Local source/build checks do not substitute for a passing release workflow on the exact published commit.


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

## Earlier candidate follow-up checks

Saved closed-lid intent tests cover explicit opt-in, separate-instance relaunch/upgrade, remaining continuous-time deadlines, invalid or expired records, startup while already closed, and expiry before another effect frame. Input tests cover production agent/contact/typing output and a 64-combination locked/sleeping/console/closed-lid eligibility matrix. These are isolated tests, not physical upgrade or external-input acceptance.

Physically confirmed during earlier candidate development, not repeated on build 45: Steady/On, exact Off, Breathe and Music with the lid closed. Battery at full charge and Agents idle, working, and present-attention states were subsequently confirmed by the user with the lid closed. External Trackpad/typing still need final physical validation; compatible external input hardware and required macOS permissions are prerequisites. No claim that an inaccessible built-in trackpad works with a closed lid.

The installer-style quit/relaunch path was physically checked after the run-loop scheduling fix: the first quit completed, recovery journals were removed, and relaunch connected without a recovery warning. The remembered closed-lid choice resumed.

Ad-hoc replacement builds can invalidate macOS Input Monitoring grants. A visible enabled entry does not prove the current binary is authorized. Typing requires a successful current-process access check; no permission bypass is attempted.

The user subsequently confirmed standalone Typing works with the lid closed after reauthorizing the installed build; the app reported Ready for typing. Permission-feedback follow-up tests use inert access APIs and do not request live permissions. External Trackpad contact has not been physically verified.
