# Interface languages

Backlit 0.2.12 supports sixteen interface languages: English, Spanish, French, German, Japanese, Korean,
Brazilian Portuguese, Simplified Chinese, Traditional Chinese, Thai, Italian, Dutch,
Polish, Turkish, Vietnamese, and Indonesian. That is six more than 0.2.11.

In Settings → Language, **System Default** follows the first supported language
selected by Foundation for this app, including macOS per-app language settings
and the ordered system language list. Unsupported lists fall back to
English. Chinese script identifiers take priority over region; Taiwan, Hong Kong,
and Macao default to Traditional Chinese, other Chinese variants to Simplified.
Portuguese variants use the supported Brazilian Portuguese translation.

A manual choice overrides the system. Existing explicit English and Traditional
Chinese choices are preserved during upgrade. New installations use System Default.
Changing the in-app choice does not require restarting the app or its light session.
Mac region and custom number conventions remain independent of interface language;
changing language never rewrites the system or per-app AppleLanguages preference.

Translations affect interface text, not protocol fields, identifiers, URLs,
keyboard shortcuts, logs, or command-line output. Unrecognized diagnostic text
falls back to English. Native macOS permission prompts follow the system's app
language selection, not Backlit's in-app manual override. macOS may require an app
relaunch for changes made in its per-app language settings to affect native prompts.

Translations are original to this implementation, not copied from a pull request.
Automated coverage checks verify key and placeholder consistency; they do not
constitute native-speaker review. Technical errors and third-party product names
may remain in English. English documentation captures use a transient override
and do not change the saved preference.

## Native string catalog workflow

Edit `assets/Localizations/Localizable.xcstrings` in Xcode's String Catalog editor.
It is the single source for interface translations; translator comments explain
runtime placeholders and diagnostic values. `InfoPlist.xcstrings` contains native
macOS privacy prompt descriptions. Preserve every named placeholder exactly.

Run `python3 scripts/compile-localizations.py --write` with full Xcode selected.
This uses Apple's `xcstringstool`, not a custom string-file compiler. The resulting
`Sources/Backlit/Resources/*.lproj/Localizable.strings` and
`assets/Localizations/*.lproj/InfoPlist.strings` are generated compatibility
resources for direct SwiftPM builds and must not be edited by hand.
`python3 scripts/check-localizations.py` verifies every generated value against
the catalogs and checks language and placeholder completeness. Missing or stale
resources fail validation; the build regenerates them before compilation.

SwiftPM packages the interface resources into `Backlit_Backlit.bundle`. The
standalone app build copies that bundle into `Contents/Resources`; lookup uses
Foundation's `Bundle.localizedString` with an explicit language bundle for the
in-app override. A read-only dictionary index exists solely for template
compatibility and tests, not as a second translation source. Native macOS privacy
prompts use their app-level `InfoPlist.strings` files.

Validate a packaged app with `python3 scripts/check-localizations.py --app
/path/to/Backlit.app`, then run its `--verify-localizations` mode from outside the
checkout. Unit-test resource resolution alone does not prove app packaging.

The four actionable listener/key/competing-app errors use typed message cases and
named arguments. Opaque diagnostics and app names are inserted after localization.
Some existing display-only status strings retain a compatibility template matcher;
uncataloged low-level diagnostics intentionally remain unchanged. This migration
uses native resources but does not claim every runtime message is a generated
Swift String Catalog symbol or that translations have native-speaker review.

For process-level checks, `--verify-language-preferences -AppleLanguages '(fr)'
-AppleLocale de_DE` runs without starting the UI or light control. These launch
arguments are volatile; they do not change saved Mac language/region preferences.

## Runtime-message coverage

The parity follow-up adds independently worded runtime text, not code or Thai
translations copied from an external contribution. The catalog contains 485 keys
in each language. Tests generate shortcut conflicts, permission-check results,
bridge status and failures, frame-pause decisions, audio errors and restoration
failures through production-used paths with inert dependencies. They do not open
listeners, change power settings, or acquire light hardware.

`check-ui-localizations.py` checks static readable literals in 17 explicitly
scoped status/error producers. Its exact file-scoped protocol/log/key-name
exclusions are recorded in `Tests/Fixtures/ui-localization-exemptions.json`.
New prose in those producers requires a catalog entry or a reviewed exclusion.
Interpolated/composite messages have separate behavioral tests. This is a bounded
regression guard, not a full Swift parser or a guarantee that all possible native
or third-party error text is translated. Technical diagnostics outside that scope
retain the documented English fallback.
