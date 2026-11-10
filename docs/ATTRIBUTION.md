# Original work and reference sources

Backlit's Swift/Python implementation, native interface, vector app icon, laptop illustration, product copy, and screenshots are project work. Fonts and SF Symbols are rendered by macOS; no font files are redistributed. The preview uses an original Backlit light marker. No Apple logo glyph is used in the app or its generated screenshots.

Functional research used:

- https://backglow.app/ and its public mode/settings guides to inventory behavior. No Backglow executable, website graphics, icons, copy, or source is bundled in the app.
- https://github.com/siumiu1968/LidPulse to inventory features and identify interoperability facts such as the device path, CoreBrightness property names, and hook formats. No LidPulse source file is included.
- Apple's installed SDK and https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/RootDomainUserClient.cpp for the clamshell user-client signature; these facts are isolated in RuntimeServices rather than copied kernel code.
- https://learn.chatgpt.com/docs/hooks for Codex's current hooks, trust requirements, and input boundaries.
- https://docs.anthropic.com/en/docs/claude-code/hooks for Claude Code lifecycle hooks.
- Apple's macOS 27 AppKit SDK and https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support for the direct-touch delivery model. Global device interoperability signatures were checked against the installed MultitouchSupport framework and the declarations in https://github.com/calftrail/Touch/blob/master/TouchSynthesis/MultitouchSupport.h; no source implementation or contact-coordinate handling is copied.
- https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html for brand review. Backlit's app/status identity uses original artwork; this is not a claim of legal clearance.
- https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps and the installed Core Audio SDK for the private-to-process audio tap/aggregate lifecycle.
- https://developers.home-assistant.io/ for light entities, config flows, and coordinator behavior.

The Buy Me a Coffee badge is the official asset at https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png. It links to https://buymeacoffee.com/tonyz, verified from the owner's https://t0nyz.com site. That third-party badge is not covered by the project's PolyForm Perimeter license.

The public repository starts with a clean source snapshot. Private reference screenshots and planning documents are retained only outside its tracked files and history. Agent configuration locations and event names follow the agents’ published formats; Backlit owns its adapter, validation, merging, and launch code.

Sparkle 2.10.1 provides the in-app update framework, under its MIT license and included third-party notices. See [Sparkle license](licenses/Sparkle.txt) and [upstream](https://github.com/sparkle-project/Sparkle).
