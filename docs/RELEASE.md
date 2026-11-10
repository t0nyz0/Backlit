Backlit 0.2.2 (build 27) for MacBook PROLED.

Fixes the menu bar icon and laptop previews showing a glowing logo when the hardware reports it disabled, including closed-lid use. The menu now shows “Off · lid closed” when that state is confirmed. Missing hardware readback is labeled unavailable rather than presented as illumination.

Also fixes the existing “Keep logo on with lid closed” setting: eligible sessions now enable the logo while keeping the keyboard dark. The supervised helper restores the real lid state on stop or exit and retains recovery information if cleanup fails. Choose a session duration in minutes or hours, or Until turned off; the default remains 30 minutes. Low battery, Low Power Mode and thermal safeguards remain active.

Your saved brightness and behavior settings are unchanged. Enabled-state percentages describe requested output, not an optical measurement. This update adds no new modes and does not change Battery behavior. Closed-lid control uses private macOS interfaces; see the validation limits below.

Download the Apple silicon ZIP or DMG and replace the app manually. The app is ad-hoc signed, not Developer ID signed or notarized. In-app updates remain disabled; no production publisher key or signed feed is provisioned.

Assets include the app ZIP/DMG, source archive, separate Stream Deck add-on, BUILD-INFO.json and SHA256SUMS.txt. Build metadata records the exact source commit. Checksums detect changed bytes; they do not authenticate the publisher. Release publication requires passing CI for the exact version tag.

See [validation and known limits](https://github.com/t0nyz0/Backlit/blob/v0.2.2/docs/VALIDATION.md), [installation](https://github.com/t0nyz0/Backlit/blob/v0.2.2/README.md#install) and [privacy](https://github.com/t0nyz0/Backlit/blob/v0.2.2/docs/PRIVACY.md).
