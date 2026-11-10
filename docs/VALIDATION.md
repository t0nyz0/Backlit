# Backlit validation

Candidate: **0.2.0-dev.3**, build 23. Local development build; not published. The exact candidate has not run in remote GitHub Actions. Artifact source identity and signing status are recorded in BUILD-INFO.json; SHA256SUMS.txt covers package bytes.

## Executed local checks

- 109 Swift tests cover effects, Battery requirements through the production model, preferences/migration, charge transitions, Music responses and malformed PCM, passive input timing, signal expiry/priority, local bridge lifecycles, automation validation, update configuration/consent and device leases/recovery values.
- 43 Python tests cover Home Assistant Core/client fixtures, process/job cancellation, OBS worker/HTTP fixtures, plugin archive validation, signed update payload/feed tampering, and disposable-filesystem local installer rollback cases.
- 14 Stream Deck tests cover command/settings validation, bounded ordering and failure recovery, inspector context/persistence, and package freshness. Typecheck/schema/license checks and dependency audit also pass locally.
- Optimized arm64 build, five-action AppIntents metadata extraction, nested framework/helper code-signature verification, source exclusions, artifact hashes/ZIP CRCs/DMG, documentation/media integrity and privacy/secret scans are checked locally.

Battery tests use saved manual levels of 0%, 25%, 50%, and other values; every unplugged percentage including zero is tested. Default/migrated preferences, active/full/paused/unplugged transitions, optional styles/cues, mode switching and preserved manual settings are covered. The original multiplier-based expectation was wrong and has been replaced. Native UI review must confirm the workspace and menu show output without a Battery manual slider.

Screenshots are captured from current native views in isolated preview; they illustrate UI and do not measure emitted light. See [provenance](media/README.md).

## Boundaries

| Area | Acceptance limit |
| --- | --- |
| Battery | Automated/model tests do not establish natural full-charge optical behavior on every device. Hardware reads and preview values are not optical measurements. |
| Music | Playback devices, protected audio, perceived latency and sustained whole-app resource use still need live acceptance. No performance guarantee. |
| Typing | Input Monitoring, Secure Input, sleep/lock/user-switch handling need live acceptance. No permission bypass. |
| Shortcuts | Five actions extract, but native discovery is blocked in the ad-hoc signing setup. Metadata extraction is not a discovery pass. |
| Stream Deck / OBS | Fixture/plugin packaging tests pass; actual key/profile, OBS script and recording/streaming operation remain unverified. |
| Home Assistant / agents | Local fixtures pass; existing installation/LAN policy and live Codex compatibility remain separate checks. |
| Updater | Trust key/feed missing, so disabled. Signature fixtures and consent tests do not prove end-to-end discovery, installation, resumed/interrupted updates or rollback/relaunch. |
| Local installer | Filesystem fixtures cover success, signature/copy/swap/launch failure and interruption restoration. This is separate from Sparkle's update installer. |
| Hardware / power | Other hardware/OS, login/reboot, administrator overrides, physical lid closure/timeout/thermal cutoffs, and forced termination recovery remain separate gates. |

## Efficiency and distribution

Animated effects use a capped 20 Hz loop and previews a capped 10 Hz publication rate. Static/off/paused states use one-second housekeeping. Input callbacks run only while eligible; hidden previews do not keep publishing frames. These mechanisms are not measured battery-life/latency claims.

The app targets Apple silicon/macOS 14+ and uses compatibility-sensitive private hardware/audio interfaces. Global screen-touch is unsupported. It is ad-hoc signed and not notarized. Sparkle requires a pinned publisher public key, signed feed/notes/archives, and a trusted manual bootstrap before updating older public versions. Current same-source hashes do not establish authenticity.
