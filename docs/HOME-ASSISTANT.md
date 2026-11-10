# Backlit + Home Assistant

Your MacBook PROLED's logo can be a local, brightness-only Home Assistant light. No cloud account or MQTT broker is needed. The custom component is bundled with the app and lives at `homeassistant/custom_components/backlit` in this repository.

## Pair your Mac

1. Quit other logo controllers and open Backlit. A compatible logo connects automatically.
2. Open **Connections**, enable the Home Assistant bridge, and enable **Allow connections from your local network** if Home Assistant is on another machine. Port: **48261**.
3. Choose **Copy Pairing Key**. The key is stored in Keychain and deliberately hidden from screenshots.
4. Choose **Open Integration Folder**. Copy its `custom_components/backlit` folder into your Home Assistant configuration's `custom_components` folder. The resulting path is `/config/custom_components/backlit/manifest.json` on typical installations.
5. Restart Home Assistant. Open **Settings → Devices & services → Add integration → Backlit**.
6. Enter `http://YOUR-MAC.local:48261` (or its LAN address) and the copied key. If macOS asks for local-network permission, decide whether to allow it for your setup.

The app must stay running and the Mac must be awake and reachable. A DHCP reservation or stable `.local` hostname helps. Backlit waits when another controller is using the logo; Home Assistant marks the light unavailable until the logo is connected.

## What appears

| Entity | Behavior |
| --- | --- |
| Logo light | On/off, brightness 0–255, effects Steady/Breathe/Battery/Music/Agents, plus Trackpad where offered |
| Battery sensor | Internal battery percentage |
| Agent status sensor | waiting, working, attention, or no_recent_signals |
| Agent sessions sensor | Recent unexpired sessions |
| Logo control active | Distinguishes device ownership from mere app/network reachability |
| Plugged in | AC power state, distinct from battery percentage |

Music must first be started and authorized in the app. Network commands cannot grant audio permission, take hardware ownership, change power policy, unlock brightness limits, or install agent hooks.

## Example automation

Replace the example entity ID with the one your installation creates:

```yaml
alias: Backlit evening light
triggers:
  - trigger: sun
    event: sunset
actions:
  - action: light.turn_on
    target:
      entity_id: light.backlit_logo
    data:
      brightness_pct: 25
      effect: Breathe
mode: single
```

## Local API

Every request requires `Authorization: Bearer <pairing-key>`.

- `GET /v1/state`: version, per-installation ID, requested enabled/brightness/effect, effects, battery, agent metadata, hardware capability, ownership, pause status, and calculated output.
- `POST /v1/light`: JSON containing any of `enabled` (boolean), `brightness` (0–255), and `effect` (one of the effects returned by `/v1/state`). Validation finishes before mutation. Returns the resulting state.

Only active, unpaused hardware control accepts light commands. `output` is the calculated waveform, not an optical measurement. The protocol has no RGB field. This first version uses HTTP for trusted local-network use; the key is sent over that transport. Keep it on your trusted LAN or put an independently managed HTTPS proxy in front of it. Never port-forward the listener to the public internet.

## Verification

The Swift tests exercise a real authenticated localhost listener. Python tests exercise the shipped client against a local HTTP fixture. An isolated Home Assistant 2026.11.1 Core test loads the actual custom component, creates all six entities, invokes a brightness/effect light service, checks preview unavailability, and unloads it. These checks do not connect to or alter your existing home instance.
