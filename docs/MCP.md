# Local MCP control

This source build includes a local Model Context Protocol (MCP) server. It lets an assistant inspect Backlit and control its light when asked. It does not run a model or require a Backlit account.

## Setup

1. Open a Backlit build containing this feature and choose **Connections → MCP control**.
2. Select **Status only** or **Allow light changes**. The default is **Off**. Keychain may ask for access during this deliberate setup action.
3. Choose **Copy Codex Setup** or **Copy Claude Code Setup**, then run the copied command in your local terminal. The installed bundle must be in `/Applications` and contain this feature. A source checkout does not update an older installed app.
4. Check the assistant's `/mcp` connections and ask it to read Backlit's status.

The commands register `/Applications/Backlit.app/Contents/MacOS/Backlit --mcp` as a local stdio server. Claude Code uses user scope; neither command contains a key. Backlit does not edit agent configuration automatically. The server can list tools with the GUI closed, but light requests require the running app and enabled AI access.

## Tools

| Tool | Input | Behavior |
| --- | --- | --- |
| `backlit_get_status` | `{}` | Requested power/mode, saved manual brightness, calculated output, hardware readback, pause/recovery and available modes. |
| `backlit_set_power` | `{"enabled": true}` | Explicit on/off; no toggle. |
| `backlit_set_brightness` | `{"percent": 35}` | Finite 0–100 manual brightness. Battery returns `BRIGHTNESS_AUTOMATIC`; selecting a manual mode is a separate action. |
| `backlit_set_mode` | `{"mode": "breathe"}` | Steady, breathe, battery, music, agents, trackpad or typing, where available. |

Every result has structured data and a text fallback. A successful tool call means settings were accepted: inspect `application_result` for `applied`, `waiting`, `paused`, `unavailable` or `recovery_required`. Neither calculated output nor hardware readback measures emitted light. Hardware samples include their age; a missing hardware-enabled field means unknown. Settings persist after the assistant disconnects. After a timeout, read status before retrying. Identical setter calls do not restart an effect; agent updates are bounded across clients.

Music must first run successfully with local system-audio authorization in the current app session. Typing requires Input Monitoring enabled locally. MCP calls never request these permissions, install hooks, repair ownership, change administrator settings, alter closed-lid/sleep policy or run arbitrary commands. Recovery/busy conditions reject unsafe mutations. A paused, owned light can be turned off when no recovery is required.

Status hooks still provide automatic working/waiting/attention signals. MCP tools are for explicit inspection and control, rather than a replacement for those hooks. Home Assistant keeps its own key and API. Existing links and Home Assistant can still save a manual brightness while Battery output remains automatic; MCP instead returns the explicit automatic-brightness error.

## Access and privacy

Status-only credentials cannot write. AI credentials cannot access Home Assistant routes, and Home Assistant credentials cannot access AI routes. AI requests require a loopback peer even if Home Assistant LAN sharing is enabled. **Off** cancels pending AI requests. **Replace AI Key** invalidates the previous bearer key; local clients can read its replacement. Use Off to stop all AI clients. Shared local credentials do not authenticate the identity of an individual assistant or isolate a hostile process running as your user.

Backlit records no prompts, code, audio, tool content or keys. The assistant may send returned light status to its model provider. See [privacy](PRIVACY.md). This implementation is local stdio; the existing REST endpoint is not a remote HTTP MCP server.

## Verification

Candidate **0.2.7, build 45** passes the native control-policy, scope-separation, key-rotation, authenticated API and stdio fixtures. `python3 scripts/check-mcp.py /path/to/Backlit` checks the built executable's handshake, including the captured Codex runtime capabilities, tool schemas, invalid calls, output isolation, EOF and process signals. It never starts the GUI, calls a live light tool or changes agent configuration.

Installed build 44 was tested with actual Codex CLI 0.155.1 using temporary invocation-only configuration. Codex discovered all four tools, read status, set brightness to 50%, then returned it to 100%; the app reported `applied` while preserving mode and power. Persistent Codex configuration was unchanged. These are reported settings and hardware state, not optical brightness measurements.

Candidate 45's headless binary separately passed actual Codex discovery and a status call against the unchanged installed build-44 GUI. That verifies the candidate's transport compatibility, **not candidate-45 GUI or native-recovery acceptance**. Build 45 has not been installed on the test Mac. Its normal startup/quit, sleep/wake and closed-lid handback, native permissions and physical output still need acceptance. Claude Code user-session acceptance remains unverified. See [validation](VALIDATION.md) for the complete evidence and limits.
