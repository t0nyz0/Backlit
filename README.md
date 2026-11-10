<p align="center"><img src="docs/header.png" width="1200" alt="Backlit — MacBook PROLED logo light control for macOS. A real MacBook with its illuminated logo."></p>
<p align="center">
<img src="https://img.shields.io/badge/source-0.2.2-9a7400?style=flat" alt="Source 0.2.2">
<img src="https://img.shields.io/badge/local_tests-171_passing-2d6085?style=flat" alt="171 local tests passing">
<img src="https://img.shields.io/badge/local_build-verified-55565f?style=flat" alt="Local build verified">
<img src="https://img.shields.io/badge/macOS-14.0_target-55565f?style=flat" alt="macOS 14.0 target">
<img src="https://img.shields.io/badge/Swift-6-a7440c?style=flat" alt="Swift 6">
<a href="LICENSE"><img src="https://img.shields.io/badge/license-PolyForm_Perimeter-67538c?style=flat" alt="PolyForm Perimeter 1.0.0 license"></a>
</p>

Control the brightness of a compatible MacBook PROLED’s illuminated Apple logo from the menu bar. Backlit is a native Swift app with an original interface, local processing, and no account requirement.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/light-dark.png">
  <img src="docs/media/light-light.png" alt="Backlit workspace with logo preview, behaviors, and brightness controls">
</picture>

*Screenshots show the running native app in isolated preview. The illustrated light is a preview, not a hardware measurement. [Provenance](docs/media/README.md).*

## Behaviors

| Behavior | What it does |
| --- | --- |
| Steady | Holds the brightness you choose. |
| Breathe | Fades in and out on a 3–10 second cycle. |
| Battery | Automatic pulse only while actively charging; solid at full or paused charging. Unplugged, output equals the battery percentage down to zero. Manual brightness has no effect. Includes pulse speed, a configurable “Dim to” floor (0% by default), optional plugged-in styles, and charge-ready cues. |
| Music | Responds to bass energy in system playback, with automatic level adjustment, Smooth/Balanced/Punchy response, sensitivity, and dark-between-beat controls. |
| Agents | Shows working, waiting, and attention states from coding agents. |
| Trackpad | Lights while a finger rests on the trackpad, with any app open. Optional click blink and permission-gated typing response. |

Battery mode displays **Battery-driven output** in the workspace and menu, without a manual brightness slider. Switching to another mode restores its saved manual brightness. Optional Battery styles and brief charge-ready signals can override the automatic charging pattern.

The logo supports white light. Brightness and timing are adjustable; RGB colors and pixel animations are not supported.

<details>
<summary>Music and Trackpad screenshots</summary>

<img src="docs/media/music-light.png" width="280" alt="Native Music controls with Automatic level and response presets">
<img src="docs/media/trackpad-light.png" width="280" alt="Native Trackpad controls with optional typing response switched off">

</details>

## Menu bar

<p align="center"><img src="docs/media/menu-light.png" width="320" alt="Backlit menu with a small logo preview, behavior picker, and brightness controls"></p>

The menu includes a small preview and controls for the selected behavior. Battery shows its actual battery-driven output; the other behaviors retain manual brightness. Backlit’s own outlined status icon remains visible when dim; its center follows current output. **Control–Command–B** or **Option-click** toggles the light. The shortcut is configurable. You can hide the menu bar icon in Settings and reopen Backlit from the Dock or Applications.

Launch connects compatible hardware automatically. Quit restores the previous logo curve. If restoration fails, Backlit retains a recovery record and offers Restore Light.

## Connections

Claude Code and Codex have separate, reversible status hooks. Existing hooks are preserved. They send a session identifier and status—not prompts, code, or tool output. Codex requires hook review/trust in its settings. Codex live-session compatibility remains unverified.

Opt-in local Backlit links and a separately packaged Stream Deck plugin provide toggle, on/off, brightness and behavior controls. Stream Deck remains experimental; real key/profile acceptance is unverified. The four native Shortcuts actions are unavailable in this ad-hoc signed build. Extracted action metadata does not establish discovery.

<details>
<summary>Other apps screenshot</summary>

<img src="docs/media/connections-automation-light.png" width="700" alt="Native Other apps controls in isolated preview; no live connections or permissions enabled">

</details>

An optional [Home Assistant integration](docs/HOME-ASSISTANT.md) exposes a light and status sensors over a local, authenticated connection. It is off by default.

<details>
<summary>Connections screenshot</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/connections-dark.png">
  <img src="docs/media/connections-light.png" alt="Backlit Connections with agent connectors and optional Home Assistant setup">
</picture>

</details>

## Settings

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/settings-dark.png">
  <img src="docs/media/settings-light.png" alt="Backlit settings: appearance, language, login launch, keyboard shortcut, closed-lid option, and brightness override">
</picture>

## Install

Download the Apple silicon ZIP or DMG from [Releases](https://github.com/t0nyz0/Backlit/releases). Quit any running Backlit, then put the new app in **Applications**. Backlit 0.2.2 is **ad-hoc signed, not Developer ID signed or notarized**.

A physically illuminated, independently controlled logo is required. The macOS 14 deployment target is not a claim that every older Mac/OS is supported. Unsupported hardware can use preview mode.

Music starts only after you enable system audio and macOS permits it. On macOS 14.2+, a private Core Audio tap captures playback without display/window capture or microphone input. No audio is saved or uploaded.

Optional login launch, closed-lid operation, and an administrator-authorized brightness-limit override are in Settings. Closed-lid and administrator behavior still need physical validation. Global screen-touch detection is not included. See [validation and known limits](docs/VALIDATION.md).

## Updates

Download updates from [GitHub Releases](https://github.com/t0nyz0/Backlit/releases) and replace the app manually. In-app updates are **disabled in 0.2.2** because a publisher trust key and signed feed have not been provisioned. There is no fallback to unsigned downloads. SHA-256 checksums detect changed bytes; they do not prove publisher identity. See [validation](docs/VALIDATION.md) for the updater test scope.

## Build

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

The [GitHub Actions workflow](https://github.com/t0nyz0/Backlit/actions) runs tests, privacy/secret checks, and an optimized build. Release publication requires that workflow to pass for the exact version tag. It packages ZIP, DMG, clean source, the separate Stream Deck add-on, build metadata, and SHA-256 checksums. Check the tagged workflow run for its commit and results. [Contributing](CONTRIBUTING.md) covers packaging and Home Assistant tests.

[Privacy](docs/PRIVACY.md) · [Validation](docs/VALIDATION.md) · [Security](SECURITY.md) · [Attribution](docs/ATTRIBUTION.md)

Backlit is independent of Apple, Anthropic, OpenAI, Home Assistant, Backglow, and LidPulse. Their names and marks belong to their owners. Backlit’s original code and artwork use [PolyForm Perimeter 1.0.0](LICENSE), a source-available license that restricts competing reuse. Third-party marks and the coffee badge are excluded.

---

<p align="center">Made with care by <a href="https://t0nyz.com">t0nyz</a>.</p>
<p align="center"><a href="https://buymeacoffee.com/tonyz"><img src="docs/media/buy-me-a-coffee.png" width="190" alt="Buy t0nyz a coffee"></a></p>
