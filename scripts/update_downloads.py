#!/usr/bin/env python3
"""Snapshot public app-asset counters and render the README chart (stdlib only)."""
import argparse
from datetime import datetime, timezone
from html import escape
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

REPOSITORY = 't0nyz0/Backlit'
API = f'https://api.github.com/repos/{REPOSITORY}/releases'
ASSET = re.compile(r'^Backlit-[A-Za-z0-9][A-Za-z0-9.+_-]*-macOS-[A-Za-z0-9_-]+\.(dmg|zip)$')
ROOT = Path(__file__).resolve().parents[1]


def integer(value):
    return type(value) is int and value >= 0


def fetch_assets(opener=urlopen, token=None):
    assets = {}
    headers = {'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
               'User-Agent': 'Backlit-download-snapshot'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    for page in range(1, 101):
        request = Request(f'{API}?per_page=100&page={page}', headers=headers)
        try:
            with opener(request, timeout=30) as response:
                data = json.load(response)
        except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as error:
            # Do not include headers, credentials, or arbitrary response bodies.
            raise ValueError('GitHub release fetch failed; existing snapshot retained.') from error
        if not isinstance(data, list) or len(data) > 100:
            raise ValueError('Invalid release page.')
        for release in data:
            if not isinstance(release, dict) or not isinstance(release.get('assets'), list):
                raise ValueError('Invalid release record.')
            if release.get('draft') is True:
                continue
            tag = release.get('tag_name')
            if not isinstance(tag, str):
                raise ValueError('Missing release tag.')
            for asset in release['assets']:
                if not isinstance(asset, dict) or not isinstance(asset.get('name'), str):
                    raise ValueError('Invalid asset record.')
                match = ASSET.fullmatch(asset['name'])
                if not match:
                    continue
                aid, count = asset.get('id'), asset.get('download_count')
                if not integer(aid) or aid == 0 or not integer(count) or aid in assets:
                    raise ValueError('Invalid or duplicate app asset counter.')
                assets[aid] = {'id': aid, 'name': asset['name'], 'release': tag,
                              'format': match[1], 'download_count': count}
        if len(data) < 100:
            return sorted(assets.values(), key=lambda item: item['id'])
    raise ValueError('Release pagination limit reached; snapshot not updated.')


def validate(snapshot):
    if not isinstance(snapshot, dict) or snapshot.get('repository') != REPOSITORY:
        raise ValueError('Invalid snapshot repository.')
    stamp = snapshot.get('checked_at')
    if not isinstance(stamp, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', stamp):
        raise ValueError('Invalid snapshot timestamp.')
    datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ')
    assets = snapshot.get('assets')
    if not isinstance(assets, list):
        raise ValueError('Invalid snapshot assets.')
    ids = set()
    for asset in assets:
        if not isinstance(asset, dict):
            raise ValueError('Invalid snapshot asset.')
        aid = asset.get('id'); name = asset.get('name')
        match = ASSET.fullmatch(name) if isinstance(name, str) else None
        if (not integer(aid) or aid == 0 or aid in ids or not match
                or asset.get('format') != match[1] or not integer(asset.get('download_count'))):
            raise ValueError('Invalid snapshot asset counter.')
        ids.add(aid)
    for kind in ('dmg', 'zip'):
        if not integer(snapshot.get(kind)) or snapshot.get(kind) != sum(a['download_count'] for a in assets if a['format'] == kind):
            raise ValueError('Snapshot total mismatch.')
    if not integer(snapshot.get('total')) or snapshot.get('total') != snapshot['dmg'] + snapshot['zip']:
        raise ValueError('Snapshot total mismatch.')
    comparison = snapshot.get('comparison')
    if comparison is not None:
        if not isinstance(comparison, dict) or set(comparison) != {'checked_at', 'delta', 'removed_ids', 'decreased_ids'}:
            raise ValueError('Invalid comparison metadata.')
        stamp = comparison['checked_at']
        if not isinstance(stamp, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', stamp):
            raise ValueError('Invalid comparison timestamp.')
        datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ')
        if stamp >= snapshot['checked_at'] or type(comparison['delta']) is not int:
            raise ValueError('Invalid comparison metadata.')
        for key in ('removed_ids', 'decreased_ids'):
            values = comparison[key]
            if not isinstance(values, list) or any(not integer(a) or a == 0 for a in values) or len(set(values)) != len(values):
                raise ValueError('Invalid comparison asset IDs.')
        if set(comparison['removed_ids']) & ids or not set(comparison['decreased_ids']) <= ids:
            raise ValueError('Invalid comparison asset IDs.')
    return snapshot


def snapshot(assets, previous=None, now=None):
    now = now or datetime.now(timezone.utc)
    result = {'repository': REPOSITORY, 'checked_at': now.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
              'assets': assets}
    for kind in ('dmg', 'zip'):
        result[kind] = sum(a['download_count'] for a in assets if a['format'] == kind)
    result['total'] = result['dmg'] + result['zip']
    result['comparison'] = None
    if previous is not None:
        validate(previous)
        if result['checked_at'] <= previous['checked_at']:
            raise ValueError('Snapshot must be newer than its baseline.')
        old = {a['id']: a['download_count'] for a in previous['assets']}
        new = {a['id']: a['download_count'] for a in assets}
        result['comparison'] = {'checked_at': previous['checked_at'], 'delta': result['total']-previous['total'],
                                'removed_ids': sorted(old.keys()-new.keys()),
                                'decreased_ids': sorted(a for a in old.keys() & new.keys() if new[a] < old[a])}
    return validate(result)


def render(data):
    validate(data)
    total = data['total']; date = data['checked_at'][:10]
    compare = data.get('comparison')
    subtitle = 'First recorded snapshot'
    if compare:
        if compare['removed_ids'] or compare['decreased_ids']:
            subtitle = 'Asset removal or counter decrease detected'
        else:
            subtitle = f"{compare['delta']:+,} since {compare['checked_at'][:10]}"
    # Both segments share one quantitative scale; the gap is decorative, not data.
    available = 828
    blue = available * data['dmg'] / total if total else 0
    purple = available - blue if total else 0
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="888" height="260" viewBox="0 0 888 260" role="img" aria-labelledby="title desc">
<title id="title">Backlit app downloads: {total:,}</title>
<desc id="desc">{data['dmg']:,} DMG and {data['zip']:,} app ZIP downloads, checked {escape(data['checked_at'])}. {escape(subtitle)}. Counts are not unique installs and include verification downloads.</desc>
<rect width="888" height="260" rx="8" fill="#161b22"/>
<g font-family="Arial,sans-serif">
<text x="28" y="37" fill="#919aa6" font-size="13">APP DOWNLOADS · ALL RELEASES</text>
<text x="28" y="92" fill="#f0f6fc" font-size="44" font-weight="600">{total:,}</text>
<text x="{max(119, 36+len(f'{total:,}')*27)}" y="89" fill="#8bdaab" font-size="15">{escape(subtitle)}</text>
<text x="860" y="37" text-anchor="end" fill="#919aa6" font-size="12">Snapshot · {date} UTC</text>
<rect x="28" y="121" width="{blue:.3f}" height="18" rx="3" fill="#70b7ea"/>
<rect x="{32+blue:.3f}" y="121" width="{purple:.3f}" height="18" rx="3" fill="#aa98df"/>
<circle cx="34" cy="167" r="5" fill="#70b7ea"/><text x="48" y="172" fill="#d1d9e0" font-size="15">DMG · {data['dmg']:,}</text>
<circle cx="204" cy="167" r="5" fill="#aa98df"/><text x="218" y="172" fill="#d1d9e0" font-size="15">App ZIP · {data['zip']:,}</text>
<path d="M28 196H860" stroke="#30363d"/>
<text x="28" y="222" fill="#919aa6" font-size="12">GitHub asset download counts, not unique installs. Includes verification downloads.</text>
<text x="28" y="242" fill="#919aa6" font-size="12">App DMG + app ZIP only; source archives and add-ons excluded.</text>
</g></svg>
'''


def snapshot_path(root, checked_at):
    return root/'docs/downloads/snapshots'/f"{checked_at.replace(':', '')}.json"


def update(root=ROOT, opener=urlopen, now=None, token=None):
    latest = root/'docs/downloads/latest.json'
    previous = validate(json.loads(latest.read_text())) if latest.exists() else None
    data = snapshot(fetch_assets(opener, token), previous, now)
    raw = json.dumps(data, indent=2, ensure_ascii=False)+'\n'
    svg = render(data)
    # Fetch and validate everything before touching any output. Atomic replacement
    # of each file prevents truncated JSON/SVG; CI commits the complete set together.
    archive = snapshot_path(root, data['checked_at'])
    if archive.exists():
        raise ValueError('Snapshot archive already exists; refusing to overwrite it.')
    outputs = {archive: raw,
               latest: raw, root/'docs/media/downloads.svg': svg}
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as file:
            file.write(content); temporary = Path(file.name)
        temporary.replace(path)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check the saved snapshot and SVG without network or writes.')
    args = parser.parse_args()
    if args.check:
        data = validate(json.loads((ROOT/'docs/downloads/latest.json').read_text()))
        archive = json.loads(snapshot_path(ROOT, data['checked_at']).read_text())
        if archive != data:
            raise ValueError('Latest snapshot differs from its archive.')
        if data.get('comparison'):
            previous = json.loads(snapshot_path(ROOT, data['comparison']['checked_at']).read_text())
            expected = snapshot(data['assets'], previous, datetime.strptime(data['checked_at'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc))
            if expected != data:
                raise ValueError('Comparison differs from its archived baseline.')
        if (ROOT/'docs/media/downloads.svg').read_text() != render(data):
            raise ValueError('Downloads SVG differs from its saved snapshot.')
    else:
        data = update(token=os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN'))
    print(f"Verified {data['total']} app downloads: {data['dmg']} DMG + {data['zip']} app ZIP ({data['checked_at']}).")


if __name__ == '__main__':
    main()
