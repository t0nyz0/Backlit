# Backlit user guide

[Back to Backlit](../README.md)

## Install and update

Download the [latest ZIP or DMG](https://github.com/t0nyz0/Backlit/releases), move Backlit to **Applications**, and open it. If you’re updating, quit the old copy first. Actual logo control needs compatible MacBook Pro hardware with PROLED XDR and an illuminated, independently controlled logo.

Use **Download Latest Version** in Settings to open the [installer page](https://t0nyz.com/backlit/install), then replace Backlit in Applications. Installation remains manual. See [validation](VALIDATION.md) for update verification and known limits.

## Behavior details and permissions

| Behavior | What it does |
| --- | --- |
| **Steady** | Hold the brightness you choose. |
| **Breathe** | Fade in and out on a 3–30 second cycle. |
| **Battery** | Follow battery charge and charging activity. |
| **Music** | Respond to bass energy in system playback. |
| **Agents** | Show working, waiting and attention states. |
| **Trackpad** | Light up while a finger rests on the trackpad. |
| **Typing** | Respond to typing timing, not characters. |

**Battery.** Automatic pulse only while actively charging; solid at full or paused charging. Unplugged, output equals the battery percentage down to zero. Manual brightness has no effect. Includes pulse speed, a configurable “Dim to” floor (0% by default), optional plugged-in styles, and charge-ready cues.

Battery mode displays **Battery-driven output** in the workspace and menu, without a manual brightness slider. Switching to another mode restores its saved manual brightness. Optional Battery styles and brief charge-ready signals can override the automatic charging pattern.

For Typing, select **Enable or retry typing access** and follow macOS’s Input Monitoring instructions. Secure Input can suppress typing response. With the lid closed, typing requires an external keyboard and Trackpad requires a compatible external trackpad.

The logo supports white light. Brightness and timing are adjustable; RGB colors and pixel animations are not supported.

**Music.** Automatic level adjustment, Smooth/Balanced/Punchy response, sensitivity and dark-between-beat controls.

**Trackpad.** Optional click blink and permission-gated typing response.

### Music and audio privacy

Selecting Music starts system audio automatically after macOS permits it; switching to another behavior stops capture. If access fails, use Retry System Audio or open the privacy settings shown in the app. On macOS 14.2+, a private Core Audio tap captures playback without display/window capture or microphone input. No audio is saved or uploaded.

## Menu bar and shortcuts

The menu includes a small preview and controls for the selected behavior. Battery shows its actual battery-driven output; the other behaviors retain manual brightness. Backlit’s own outlined status icon remains visible when dim; its center follows current output. **Control–Command–B** or **Option-click** toggles the light. Toggle and brightness-up/down shortcuts are configurable in Settings. You can hide the menu bar icon in Settings and reopen Backlit from the Dock or Applications. Settings also offers **Hide Dock icon**. New defaults show the menu-bar icon and hide the Dock icon; saved choices are preserved. Hiding the menu-bar icon restores the Dock icon first so the app stays reachable. This does not remove shortcuts you have pinned to the macOS Dock.

Brightness-up/down shortcuts are **Off by default** and can be assigned in Settings. Existing choices, including the previous Control–Command–Up/Down Arrow defaults, are preserved on upgrade. An assigned shortcut changes manual logo brightness by five percentage points while preserving its behavior and on/off state. Battery stays automatic. A separate, off-by-default experimental **Shift + hardware brightness keys** option requires Accessibility, Input Monitoring and physical keyboard validation before screen suppression can be claimed. See [shortcut setup and limits](SHORTCUTS.md).

## Connection setup and limits

Claude Code and Codex have separate, reversible status hooks. Existing hooks are preserved. They send a session identifier and status—not prompts, code, or tool output. Codex requires hook review/trust in its settings. Live status-hook delivery in Codex remains unverified.

Opt-in local Backlit links and a separately packaged Stream Deck plugin provide toggle, on/off, brightness and behavior controls. Stream Deck remains experimental; real key/profile acceptance is unverified. The four native Shortcuts actions are unavailable in this ad-hoc signed build. Extracted action metadata does not establish discovery.

An optional [Home Assistant integration](HOME-ASSISTANT.md) exposes a light and status sensors over a local, authenticated connection. It is off by default.

Backlit includes optional [MCP control](MCP.md) for local AI assistants. Open **Connections → MCP control** and choose **Status only** or **Allow light changes**. MCP access starts off and has a separate Keychain key. The four tools read status, set power, set manual brightness and select an available behavior. The separate **Coding status hooks** section connects automatic Claude Code and Codex activity feedback.

Keep Backlit open. For Codex, run:

```sh
codex mcp add backlit -- /Applications/Backlit.app/Contents/MacOS/Backlit --mcp
```

Start a new local Codex session, check `/mcp`, then ask **“Read Backlit's status through MCP.”** For Claude Code, use **Copy Claude Code Setup** in Backlit. This is a local stdio connection; registering it does not automatically connect a cloud chat.

## Settings and hardware limits

Settings includes appearance, language, launch at login, shortcuts, **Hide Dock icon**, **Show menu bar icon**, closed-lid duration and the optional brightness-limit override. New installations show the menu-bar icon and hide the running app's Dock icon. Saved choices are preserved; a pinned Dock shortcut is not removed.

Downloads are disabled in isolated preview. In the app, **Download Latest Version** opens the installer page.

A physically illuminated, independently controlled logo is required. The macOS 14 deployment target is not a claim that every older Mac/OS is supported. Unsupported hardware can use preview mode.

**Closed-lid lighting.** Choose 1–30 minutes (default and maximum: 30). Sleep counts toward the timer; relaunching does not reset it. Low battery, Low Power Mode and heat stop the session. The keyboard stays dark and the real lid state is restored when stopped. **The built-in screen may remain lit while closed.** Other hardware, lid transitions and administrator behavior still need validation. Global screen-touch detection is not included. See [validation and troubleshooting](VALIDATION.md).

The brightness-limit override runs only built-in macOS tools with administrator authorization. Original limits are saved, and the saved copy is kept until restoration is verified.

## Native app gallery

Historical 0.2.5 screenshots show the native app in isolated preview; some controls and layouts have since changed. The illustrated light is a preview, not a hardware measurement. [Provenance](media/README.md).

[Music](media/music-light.png) · [Trackpad](media/trackpad-light.png) · [Typing](media/typing-light.png) (historical light-mode image links)

## Build from source

```sh
git clone https://github.com/t0nyz0/Backlit.git
cd Backlit
swift test
bash scripts/build.sh
bash scripts/install.sh
```

The local installer gracefully quits, replaces, and reopens `/Applications/Backlit.app`. Preferences are preserved. For UI work without hardware writes:

```sh
open -n dist/Backlit.app --args --preview
```

The [GitHub Actions workflow](https://github.com/t0nyz0/Backlit/actions) runs tests, privacy/secret checks, and an optimized build. Release publication requires that workflow to pass for the exact version tag. It packages ZIP, DMG, clean source, the separate Stream Deck add-on, build metadata, and SHA-256 checksums. Check the tagged workflow run for its commit and results. [Contributing](../.github/CONTRIBUTING.md) covers packaging and Home Assistant tests.

**0.2.11 (build 57)** supports ten interface languages, System Default and manual language selection, with independent Mac regional number formatting. [Interface language behavior](LOCALIZATION.md).

Source **0.2.11** · [Download counts and refresh details](downloads/README.md) · [View all releases](https://github.com/t0nyz0/Backlit/releases) · [License](../LICENSE)

[Privacy](PRIVACY.md) · [Validation](VALIDATION.md) · [Security](../.github/SECURITY.md) · [Attribution](ATTRIBUTION.md)

## License and attribution

Backlit is independent of Apple, Anthropic, OpenAI, Home Assistant, Backglow, and LidPulse. Their names and marks belong to their owners. Backlit’s original code and artwork use [PolyForm Perimeter 1.0.0](../LICENSE), a source-available license that restricts competing reuse. The header photograph, third-party marks and the coffee badge are excluded.

Header photograph (`docs/header.png` and the underlying original photo): © 2026 t0nyz. All rights reserved. Reuse requires prior permission, except where permitted by law or GitHub’s terms.
