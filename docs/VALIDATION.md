# Backlit validation

Version: **0.1.8**, build 19. This is an early source preview. Release source metadata and artifact checksums are in `BUILD-INFO.json` and `SHA256SUMS.txt`. Test and package results are available in [GitHub Actions](https://github.com/t0nyz0/Backlit/actions).

## Automated checks

- 40 native Swift tests cover bounded effects, off precedence, automatic charging/paused/full/unplugged battery behavior, preference migration and customization, bounded opt-in charge-ready signals, breathing cycles, audio envelopes, contact state, preference loading, device leases, recovery curves, authenticated HTTP framing, command validation, and localhost bridge traffic.
- Agent-hook tests cover configuration overrides, preservation of unrelated commands, migration of earlier Backlit hooks, literal shell-path quoting, metadata-only storage, expiry, and invalid session rejection.
- Five Python tests cover the client against a local HTTP fixture and the custom integration in isolated Home Assistant 2026.11.1 Core. They exercise pairing, invalid keys, duplicate devices, entities, light commands, preview availability, and unloading.
- Packaging checks compiled binaries for local home paths, bundles the license and attribution notices, and verifies the app signature. Documentation/media checks cover local links, version metadata, PNG integrity, and image metadata.

Screenshots use the production native views in isolated preview mode. They are visually reviewed; they do not measure physical light output.

## Compatibility and verification limits

| Feature | Remaining checks |
| --- | --- |
| Hardware control | Other hardware and operating-system variants; optical brightness and latency. Private interfaces may change. Service readback is not an optical measurement. |
| Music | Multiple playback sources/devices, protected audio, latency, and sustained resource use. Core Audio is used on macOS 14.2+; macOS 14.0–14.1 uses an audio-only ScreenCaptureKit fallback. |
| Coding agents | Codex live-session compatibility; hook review/trust must be granted in Codex. |
| Login launch | Actual login/reboot behavior after opt-in. |
| Ambient override | Administrator-authorized execution and physical brightness range. |
| Closed-lid operation | Physical closure with and without an external display, permissions, timeout, and thermal/battery cutoffs. |
| Quit and recovery | Normal shutdown requests restoration. Force-killing the app and watchdog is a separate recovery case. Reboot persistence of a deliberately retained dark state is not claimed. |
| Trackpad | Click accents, missed-release stress, and optical latency. Global screen touch is unsupported and is not offered. |
| Home Assistant | Pairing with an existing installation and its LAN policy. |

## Efficiency design

Steady, non-charging Battery, Trackpad, off, and paused states use one-second housekeeping. Battery animates at 20 Hz while actively charging with Automatic pulse selected, or during an explicitly enabled animated charge-ready signal; power state is sampled once per second while Battery is selected. Animated effects use a capped 20 Hz loop; preview publication is capped at 10 Hz. Hidden previews do not keep redrawing. Competing-controller detection uses launch/quit notifications rather than repeated application enumeration. Unchanged battery and agent values are not republished.

Trackpad input uses callbacks only while selected and enabled. It does not poll a device, inspect coordinates, record input, or seize a HID device. Audio is analyzed locally without recording; its envelope release is time-based and stale packets fade out. These implementation choices are not a battery-life or latency guarantee.

## Distribution limits

- The binary targets Apple silicon and macOS 14+. This does not establish support for every Mac or macOS release.
- The app is ad-hoc signed, not Developer ID signed or notarized.
- Lock observation uses a compatibility-sensitive session key. Sleep, display sleep, lock, lid closure, and user switching are distinct conditions.
- Update checking opens GitHub Releases; there is no automatic updater.
- English and Traditional Chinese primary controls are available; some diagnostics remain English.
