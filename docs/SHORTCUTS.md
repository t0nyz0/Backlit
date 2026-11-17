# Logo brightness shortcuts

Backlit's Settings contains three independent global shortcuts. Each can be changed, reset or disabled.

| Action | Default | Result |
| --- | --- | --- |
| Toggle logo | Control–Command–B | Existing on/off action. |
| Increase logo brightness | Off | Adds five percentage points to the saved manual level. |
| Decrease logo brightness | Off | Subtracts five percentage points from the saved manual level. |

Brightness stays between 0% and 100%. These actions preserve the current behavior and on/off state; adjusting while Off saves the level without turning the logo on. Battery output stays automatic, so its brightness shortcuts show an explanation without changing the manual level. Busy/recovery states reject changes. An accepted level is not a measurement of emitted light.

The ordinary shortcuts use the same public `RegisterEventHotKey` API as the existing toggle and request no new keyboard-monitoring permission. Use Command, Control or Option with a regular key; Shift can be added. The recorder shows arrow/function key names, temporarily releases Backlit's shortcuts and prevents actions while recording. Duplicate combinations are rejected. A failed native replacement keeps the previous binding. macOS or another application may reserve a combination; registration errors appear beside the action. Existing saved shortcuts and disabled choices are retained. Upgrades also preserve the previous implicit Control–Command–Up/Down Arrow bindings. Reset adopts the new defaults: Control–Command–B for Toggle, Off for each brightness action.

Literal F1/F2 key events are different from the screen-brightness media events. If a literal function-key chord is recorded, the keyboard's Fn/function-key setting may affect how it is produced. It is not a guarantee that pressing the brightness-labelled key will trigger it. Ordinary arrow-key chords avoid that distinction.

## Shift plus hardware brightness keys

This local source includes an **experimental**, separately enabled option. It is **Off by default**. With it Off, the hardware keys retain macOS behavior.

1. Enable **Shift + hardware brightness keys (experimental)** in Settings.
2. If macOS asks, grant Backlit Accessibility access, then enable the option again. This implementation also preflights Input Monitoring before creating a filter; missing listening access leaves it off. Use the Input Monitoring link and enable the option again. If Backlit is absent from that list, add the installed app with its plus button. Startup never requests permission.
3. With a manual behavior selected, test Shift + Brightness Up/Down on the actual keyboard. Confirm both the logo response and that screen brightness does not change. If it does, turn the option off and use the ordinary configurable shortcuts.

**Screen suppression has not been physically verified.** Creating a tap and passing unit tests does not prove that the OS delivers these events before its display-brightness handler. Touch Bar controls, external keyboards and keyboards using different event routes are not claimed to work.

The active session filter recognizes only auxiliary display-brightness events that start with Shift alone. Command, Option, Control or Fn variants, unmodified brightness and unrelated media keys remain native. Option–Shift–Brightness, Apple's fine display-brightness shortcut, is preserved. Caps Lock is not treated as a shortcut modifier. Once a Shift-only press is owned, its repeats and key-up remain paired even if Shift is released first; no second action occurs on key-up. A press started natively is not hijacked if Shift is added while holding it. Repeat actions are bounded. Opening or closing the shortcut recorder cancels queued logo actions while retaining the same active filter's held-key pairing until key-up. Disabling the filter or an OS timeout returns control to macOS, clears pending actions and does not synthesize/replay a key.

This option uses a public Quartz session event tap with an active filter. A passive event monitor cannot suppress the original event. The app does not change display settings to undo a key, request root access or install a privileged helper. It reads no characters and logs no keyboard payloads. See [privacy](PRIVACY.md).

## Verification

Fixtures cover capture and preference migration, disabled/custom bindings, registration conflicts and action IDs, recording suspension, clamping, Battery/manual behavior, exact modifiers, native versus owned gestures, key-up pairing, repeat bounds and permission-denied startup. Synthetic events are created in memory and are never posted to macOS. The real global shortcuts and event tap were not activated during this background work.

Physical acceptance still needs another foreground app, repeated presses and held-key repeats, Shift released before the brightness key, Option–Shift and plain brightness, Fn modes, the built-in/external keyboards in use, Accessibility/Input Monitoring denial/revocation, sleep/wake and quitting. Verify that ordinary shortcuts change only the logo and that the experimental Shift path actually suppresses screen brightness before relying on it.

Sources: [Apple event-tap callback behavior](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback), [Apple event monitoring limits](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)), [Apple keyboard shortcuts](https://support.apple.com/en-us/102650), and [MediaKeyTap's session-filter precedent](https://github.com/MonitorControl/MediaKeyTap/blob/master/MediaKeyTap/MediaKeyTapInternals.swift). API signatures and auxiliary key constants were also checked in the installed public macOS SDK headers.
