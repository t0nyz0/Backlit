**Backlit 0.2.6**

- The logo now keeps the brightness you set, even when you change your screen brightness.
- Backlit reconnects by itself after sleep, wake and lock instead of stopping with an error.
- Shutting down, restarting or logging out is no longer held up by Backlit’s quit prompt.
- Cancelling the administrator prompt for the brightness-limit override no longer disconnects the logo.
- Closed-lid lighting is limited to 1–30 minutes each time the lid closes. The hours and “Until turned off” options are removed; older choices move to 30 minutes.
- Status now sits beside the Logo Control heading, long messages wrap, and the closed-lid pause message names the switch to use.
- Home Assistant: added New Pairing Key, and setup errors are clearer.
- The app is signed with the hardened runtime, and leftover support files are cleaned up automatically.

Known limits: with the lid closed the logo is dim and the built-in screen may stay lit.

After updating, macOS may require you to re-add Backlit under Input Monitoring.
