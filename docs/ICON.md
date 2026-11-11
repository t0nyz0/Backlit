# Backlit icon

The original native artwork now uses the selected centered-square design. The white rounded square occupies 17.5% of the icon width and is centered in the tile. The graphite gradient, laptop outline, base and restrained glow retain the existing visual language.

`Sources/Backlit/BrandGlyph.swift` is the shared source for the in-app logo and exported assets. Run `bash scripts/generate-icons.sh` on macOS to regenerate the 1024-pixel master, every ICNS representation and the 512-pixel README image. All ten representations use PNG-backed ICNS entries to preserve edge alpha. Each size renders directly from the native vector artwork; no generated mockup texture or screenshot resampling is used.

Regression tests check the centered square, absence of the former top bar and transparent corners at 16, 32, 64, 128, 256, 512 and 1024 pixels. Packaging and installed Finder/Dock appearance should be checked with the combined app update. Icon changes do not alter hardware control, preferences, app version or release metadata.
