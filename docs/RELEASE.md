**Backlit 0.2.6, build 38: stability candidate**

This candidate is prepared for review, not published or installed automatically.

- The closed-lid pause message now says the logo is off and names the Settings switch to use. It previously said "this setting" on the main page, beside the Logo on switch.
- Closing or opening the lid with closed-lid lighting on no longer stops light control when the first cleanup check runs while the lid and display are still settling. The same verified cleanup is retried up to six times over about twelve seconds; nothing is replaced until it succeeds.
- Signed the app with the hardened runtime, so other processes can no longer load code into Backlit to borrow its Input Monitoring or audio permissions. It remains ad-hoc signed; one entitlement is needed for the bundled Sparkle framework.
- Opening or closing the lid with closed-lid lighting on no longer uses up the automatic-recovery budget, and a session created during sleep or lock now pauses instead of counting as a failure.
- Stale agent status files, old agent-settings backups, superseded closed-lid timer files and orphaned fade lease files are now removed. Recovery records are never touched.
- All native brightness adapters now verify the exact private method signatures before use and report an unsupported interface instead of calling a changed method.
- Added **New Pairing Key** for the Home Assistant bridge. The old key stops working immediately.
- Home Assistant setup no longer reports a bad server response as an invalid address.
- Restored independent open-lid logo brightness. The requested logo level uses its own bounded brightness curve rather than scaling the screen-dependent native source. Original settings are retained for verified recovery.
- Limited closed-lid lighting to 1–30 minutes and removed the unlimited and hours choices. Older unlimited or longer saved choices migrate to 30 minutes. Existing timed sessions keep their original start, sleep counts toward their deadline, and relaunching cannot reset them. An old unlimited session with no verified start waits for the lid to reopen.
- Moved current logo status beside the top Logo Control heading, with compatibility details underneath and recovery actions alongside. Long errors wrap instead of truncating.
- Fixed administrator-prompt cancellation so prior control intent can resume after safe cleanup; new Off or Quit choices win. Unknown helper failures stay paused. Active closed-lid cleanup must finish before changing ambient limits.
- System logout, restart and shutdown no longer show the optional Off-logo warning. Verified cleanup is still required, and explicit app quits retain the warning.
- Added bounded reconnection after recoverable sleep, wake, lock and session interruptions.
- Preserved pending cleanup and limited retries instead of discarding a failed restoration or repeatedly rearming it.
- Distinguished old recoverable closed-lid pauses from faults that still require confirmed cleanup or manual recovery.
- Corrected waiting and ready status so an accepted request or a zero-output source cannot report that the light is ready.
- Added field-specific native-readback errors and regression coverage for stale native state, reentrant recovery, cancellation and failed writes.

**Closed-lid warning:** Keeping the logo on keeps the Mac awake and may leave its built-in screen lit while fully closed. Use a hard, ventilated surface, never a bag. The 30-minute maximum limits duration; it does not fix screen illumination or guarantee safe temperatures. Closed-lid brightness, automatic native handback, physical sleep/wake recovery and broader device compatibility remain unverified by these automated checks. Existing fault pauses are preserved rather than silently cleared.

No experimental direct-PWM test, calibration pilot or separate handback tool is included. On first launch, old unlimited or longer duration preferences are capped; unrelated settings and saved fault pauses are preserved. It is ad-hoc signed with the hardened runtime, not Developer ID signed or notarized. macOS may require Input Monitoring to be reauthorized after replacement.

The administrator-only ambient override still uses the existing full-app elevation route. Its privilege boundary remains under review; avoid enabling it in this candidate. The fixes above do not claim to harden that boundary or establish compatibility with untested private-API versions.
