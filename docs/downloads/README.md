# Download chart data

The dynamic README hero counts published GitHub release assets named `Backlit-…-macOS-arm64.dmg` or `.zip`, across all releases. These are the currently supported app packages. The archived snapshot tool also recognizes other architecture labels. Source archives, add-ons and draft releases are excluded. Prerelease app assets are included. Counts include repeat and verification downloads; they are not unique users or installations.

`latest.json` records the check time, asset IDs, per-asset counters and DMG/ZIP totals. `snapshots/YYYY-MM-DDTHHMMSSZ.json` retains every successful check, including manual checks on the same day. Archives are never overwritten. The archived SVG's change compares its latest check with its immediate prior saved check, not a daily-download estimate. Removed asset IDs and decreasing counters are flagged instead of presenting their net change as ordinary growth. GitHub provides current counters, not a historical download timeline; older history is not invented.

The README embeds a combined hero and dynamic SVG from `https://t0nyz.com/counter/backlit/hero.svg`. The original photograph is embedded in the same image; the separate full breakdown remains at `https://t0nyz.com/counter/backlit`. It uses public GitHub release counts only, not website analytics or visitor tracking. The service caches data for ten minutes and serves the image through Vercel's CDN with a ten-minute shared cache plus a one-minute stale-while-revalidate window. The two cache layers can combine to exceed ten minutes; GitHub's image proxy may cache it longer still. Refreshing the README does not guarantee a fresh GitHub API request; the image displays the actual source check time. Click it to open the counter directly.

Successful totals and their actual check time are saved in a dedicated single-row database record. If GitHub fails, the last successful number remains with its original timestamp; old data is labeled as cached. Before the first successful check, or if the database itself is unavailable, the image can say unavailable rather than inventing zero. There is no daily snapshot workflow or per-view GitHub fetch. A shared database lease limits GitHub check attempts to once per ten minutes across regions, including failed attempts. CDN and data caches also reduce function and database work. No visitor or admin analytics data is read or stored by the counter.

The files below retain historical verified samples and the offline snapshot tool for audit/reference; they no longer drive the README image. No historical timeline is invented.

Maintenance:

```sh
python3 -m unittest discover -s Tests/Python -p test_downloads_chart.py -v
python3 scripts/update_downloads.py          # fetch and update
python3 scripts/update_downloads.py --check  # offline validation only
```

The SVG is generated data visualization, not a native app screenshot. It does not change historical PNG capture provenance.

## Trend and release breakdown

The trend shows up to 90 UTC days of actual successful observations, keeping the latest check within each day. Missing days are not filled with invented counts; connecting lines join the observed points, not a continuous measurement. The initial verified samples cover November 11–18, 2026 (261, 296, 317, 331, 372, 394, 420 and 459 downloads); November 11's check time was recorded approximately to the minute. This is partial history, not lifetime download activity. The headline change compares the first and last points shown and can be negative if GitHub counters fall or assets are removed.

The compact README hero shows only the total across all releases, the actual last successful update time, and the status pills. The separate full chart at `https://t0nyz.com/counter/backlit` retains the observed trend and all version counts from the same successful sample. They count app package downloads, not installation activity or comparable adoption rates: releases have different ages. New successful checks update the total, versions and daily history together; GitHub failures retain the last successful set. The one-row history is bounded to 90 days, and no visitor data is collected.

## Hero status badges

The six split badges reproduce the repository’s source/build metadata: source 0.2.10, 865 local non-UI tests passing, local build verified, macOS 14.0 target, Swift 6, and PolyForm Perimeter. These are recorded project metadata, not a live CI check or a claim that the latest branch tests ran. They change when that metadata is explicitly updated and deployed; only download counts and their dated trend refresh automatically. The combined image has one link, so the license remains available as a separate text link in the README.
