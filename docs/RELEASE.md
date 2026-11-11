Backlit 0.2.4 (build 29) for MacBook PROLED.

Fixes white points around the app icon in Finder by regenerating the smaller icon sizes. The original artwork is unchanged.

Fixes closed-lid output so the logo follows the selected behavior. The same hardware path serves Steady, Breathe, Battery, Music, Agents, Trackpad and Typing; external input hardware is required to use Trackpad or typing with the lid closed.

Music capture starts automatically when selected and stops when you leave it. Its intensity control is easier to adjust. Typing is now a separate behavior, with an explicit control to enable or retry macOS input access. Trackpad’s optional typing response remains available. Trackpad, typing and agent-state output wiring is corrected.

The closed-lid choice is now remembered across relaunches and updates without restarting an active finite timer. Older versions did not save this choice: enable it once in this version to remember it. Static preview artwork is cached to reduce redraw work, with additional cleanup and recovery safeguards.

This is a local release-notes draft, not a published release. On, Off, Breathe, Music, full-charge Battery and Agents states have been physically checked. Clean quit/relaunch and the remembered closed-lid choice were verified. Standalone Typing was also confirmed with the lid closed after macOS input access was reauthorized. External-trackpad and sustained performance acceptance remain in progress.

Download the Apple silicon ZIP or DMG, quit Backlit, and replace it in Applications.

See [validation and known limits](https://github.com/t0nyz0/Backlit/blob/v0.2.4/docs/VALIDATION.md) and [installation](https://github.com/t0nyz0/Backlit/blob/v0.2.4/README.md#install).
