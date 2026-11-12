**Backlit 0.2.6, build 33: private stability candidate**

This candidate is prepared for review, not published or installed automatically.

- Moved current logo status beside the top Logo Control heading, with compatibility details underneath and recovery actions alongside. Long errors wrap instead of truncating.
- Fixed administrator-prompt cancellation so prior control intent can resume after safe cleanup; new Off or Quit choices win. Unknown helper failures stay paused. Active closed-lid cleanup must finish before changing ambient limits.
- System logout, restart and shutdown no longer show the optional Off-logo warning. Verified cleanup is still required, and explicit app quits retain the warning.
- Added bounded reconnection after recoverable sleep, wake, lock and session interruptions.
- Preserved pending cleanup and limited retries instead of discarding a failed restoration or repeatedly rearming it.
- Distinguished old recoverable closed-lid pauses from faults that still require confirmed cleanup or manual recovery.
- Corrected waiting and ready status so an accepted request or a zero-output source cannot report that the light is ready.
- Added field-specific native-readback errors and regression coverage for stale native state, reentrant recovery, cancellation and failed writes.

**Known issue: keep closed-lid lighting off.** A physical test showed the built-in screen staying lit with the lid fully closed; it turned off when Backlit quit. Closed-lid brightness can still depend on screen brightness. The feature is retained, but these issues are unresolved. Automatic handback, physical sleep/wake recovery and broader device compatibility are not established by the automated checks.

No experimental direct-PWM test, calibration pilot or separate handback tool is included. Existing user settings are not changed by preparing this build. It is ad-hoc signed, not Developer ID signed or notarized. macOS may require Input Monitoring to be reauthorized after replacement.

The administrator-only ambient override still uses the existing full-app elevation route. Its privilege boundary remains under review; avoid enabling it in this candidate. The fixes above do not claim to harden that boundary or establish compatibility with untested private-API versions.
