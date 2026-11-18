# Download chart data

The README chart counts published GitHub release assets named `Backlit-…-macOS-….dmg` or `.zip`, across all releases. Source archives, add-ons and draft releases are excluded. Prerelease app assets are included. Counts include repeat and verification downloads; they are not unique users or installations.

`latest.json` records the check time, asset IDs, per-asset counters and DMG/ZIP totals. `snapshots/YYYY-MM-DDTHHMMSSZ.json` retains every successful check, including manual checks on the same day. Archives are never overwritten. The chart's change compares the latest check with its immediate prior saved check, not a daily-download estimate. Removed asset IDs and decreasing counters are flagged instead of presenting their net change as ordinary growth. GitHub provides current counters, not a historical download timeline; older history is not invented.

The `Update download chart` workflow refreshes the chart daily (scheduled for 06:47 UTC) or manually on `main`. GitHub scheduling and image caching can delay visibility; this is a dated snapshot, not a real-time counter. No external analytics service is used. The workflow uses its ephemeral repository token to publish only the chart and snapshot files. It does not create releases or change app code. Chart-only commits use `[skip ci]` to avoid running the full macOS packaging build; the updater regression tests and offline consistency check run in the chart workflow before every such commit.

Fetch, pagination, API/rate-limit and validation failures leave the last saved snapshot and chart unchanged. The workflow fails visibly instead of replacing counts with zero. Writes are individually atomic and committed together. A concurrent update to `main` safely prevents a non-fast-forward push; there is no force push.

Maintenance:

```sh
python3 -m unittest discover -s Tests/Python -p test_downloads_chart.py -v
python3 scripts/update_downloads.py          # fetch and update
python3 scripts/update_downloads.py --check  # offline validation only
```

The SVG is generated data visualization, not a native app screenshot. It does not change historical PNG capture provenance.
