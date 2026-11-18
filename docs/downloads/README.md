# Download chart data

The dynamic README chart counts published GitHub release assets named `Backlit-…-macOS-arm64.dmg` or `.zip`, across all releases. These are the currently supported app packages. The archived snapshot tool also recognizes other architecture labels. Source archives, add-ons and draft releases are excluded. Prerelease app assets are included. Counts include repeat and verification downloads; they are not unique users or installations.

`latest.json` records the check time, asset IDs, per-asset counters and DMG/ZIP totals. `snapshots/YYYY-MM-DDTHHMMSSZ.json` retains every successful check, including manual checks on the same day. Archives are never overwritten. The chart's change compares the latest check with its immediate prior saved check, not a daily-download estimate. Removed asset IDs and decreasing counters are flagged instead of presenting their net change as ordinary growth. GitHub provides current counters, not a historical download timeline; older history is not invented.

The README now embeds a dynamic SVG from `https://t0nyz.com/counter/backlit`. It uses public GitHub release counts only, not website analytics or visitor tracking. The service caches data for ten minutes and serves the image through Vercel's CDN with a ten-minute shared cache plus a one-minute stale-while-revalidate window. The two cache layers can combine to exceed ten minutes; GitHub's image proxy may cache it longer still. Refreshing the README does not guarantee a fresh GitHub API request; the image displays the actual source check time. Click it to open the counter directly.

Successful totals and their actual check time are saved in a dedicated single-row database record. If GitHub fails, the last successful number remains with its original timestamp; old data is labeled as cached. Before the first successful check, or if the database itself is unavailable, the image can say unavailable rather than inventing zero. There is no daily snapshot workflow or per-view GitHub fetch. A shared database lease limits GitHub check attempts to once per ten minutes across regions, including failed attempts. CDN and data caches also reduce function and database work. No visitor or admin analytics data is read or stored by the counter.

The files below retain historical verified samples and the offline snapshot tool for audit/reference; they no longer drive the README image. No historical timeline is invented.

Maintenance:

```sh
python3 -m unittest discover -s Tests/Python -p test_downloads_chart.py -v
python3 scripts/update_downloads.py          # fetch and update
python3 scripts/update_downloads.py --check  # offline validation only
```

The SVG is generated data visualization, not a native app screenshot. It does not change historical PNG capture provenance.
