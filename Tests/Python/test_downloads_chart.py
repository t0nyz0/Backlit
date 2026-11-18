import importlib.util
import io
import json
from datetime import datetime, timezone, timedelta
from pathlib import Path
import tempfile
import unittest
from urllib.error import HTTPError
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location('downloads', Path(__file__).resolve().parents[2]/'scripts/update_downloads.py')
M = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(M)
NOW = datetime(2026, 11, 18, 1, tzinfo=timezone.utc)


def asset(aid=1, count=10, name='Backlit-0.2.10-macOS-arm64.dmg'):
    return {'id': aid, 'name': name, 'download_count': count}


def release(*assets, **extra):
    return {'tag_name': 'v0.2.10', 'assets': list(assets), **extra}


def opener(pages):
    calls = []
    def open_(request, timeout):
        calls.append(request)
        return io.StringIO(json.dumps(pages[len(calls)-1]))
    open_.calls = calls
    return open_


class DownloadsTests(unittest.TestCase):
    def test_filters_exact_app_assets_and_drafts_but_includes_prereleases(self):
        open_ = opener([[release(asset(), asset(2, 12, 'Backlit-0.2.11-beta-macOS-arm64.zip'),
                                 asset(3, 99, 'Backlit-0.2.10-source.zip'),
                                 asset(4, 99, 'Backlit-0.2.10-StreamDeck.streamDeckPlugin')),
                         release(asset(5), draft=True)]])
        data = M.snapshot(M.fetch_assets(open_), now=NOW)
        self.assertEqual((data['total'], data['dmg'], data['zip']), (22, 10, 12))

    def test_paginates_full_pages_including_final_empty_page(self):
        open_ = opener([[release(asset(i)) for i in range(1, 101)], []])
        self.assertEqual(len(M.fetch_assets(open_)), 100)
        self.assertTrue(open_.calls[1].full_url.endswith('page=2'))

    def test_bad_pages_and_assets_fail(self):
        for page in [{}, [None], [{'assets': []}], [release(None)],
                     [release(asset(count=-1))], [release(asset(count=True))],
                     [release(asset(aid=0))], [release(asset(), asset())]]:
            with self.subTest(page=page), self.assertRaises(ValueError):
                M.fetch_assets(opener([page]))

    def test_duplicates_across_pages_fail(self):
        with self.assertRaises(ValueError):
            M.fetch_assets(opener([[release(asset(i)) for i in range(1, 101)], [release(asset())]]))

    def test_pagination_cap_fails_instead_of_partial_result(self):
        pages = [[release(asset(page*100+i)) for i in range(1, 101)] for page in range(100)]
        with self.assertRaisesRegex(ValueError, 'pagination limit'):
            M.fetch_assets(opener(pages))

    def test_rate_limit_preserves_all_previous_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            old = M.update(root, opener([[release(asset())]]), NOW)
            before = {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
            def denied(*args, **kwargs):
                raise HTTPError('https://api.github.com', 403, 'rate limit', {}, None)
            with self.assertRaisesRegex(ValueError, 'existing snapshot retained'):
                M.update(root, denied, NOW+timedelta(days=1))
            after = {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
            self.assertEqual(before, after)

    def test_malformed_json_preserves_previous_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); M.update(root, opener([[release(asset())]]), NOW)
            before = (root/'docs/downloads/latest.json').read_bytes()
            with self.assertRaises(ValueError):
                M.update(root, lambda *a, **k: io.StringIO('{'), NOW+timedelta(days=1))
            self.assertEqual((root/'docs/downloads/latest.json').read_bytes(), before)

    def test_removal_and_reset_are_flagged_even_if_total_grows(self):
        old = M.snapshot(M.fetch_assets(opener([[release(asset(), asset(2))]])), now=NOW)
        new = M.snapshot(M.fetch_assets(opener([[release(asset(count=1), asset(3, 100))]])), old, NOW+timedelta(days=1))
        self.assertEqual(new['comparison']['removed_ids'], [2])
        self.assertEqual(new['comparison']['decreased_ids'], [1])
        self.assertIn('counter decrease detected', M.render(new))
        self.assertNotIn('+81 since', M.render(new))

    def test_delta_is_raw_counter_difference(self):
        old = M.snapshot(M.fetch_assets(opener([[release(asset())]])), now=NOW)
        new = M.snapshot(M.fetch_assets(opener([[release(asset(count=15))]])), old, NOW+timedelta(days=1))
        self.assertIn('+5 since 2026-11-18', M.render(new))
        self.assertEqual(new['comparison']['delta'], 5)

    def test_timestamp_must_advance(self):
        old = M.snapshot([], now=NOW)
        with self.assertRaises(ValueError):
            M.snapshot([], old, NOW)

    def test_empty_initial_snapshot_renders_without_divide_by_zero(self):
        svg = M.render(M.snapshot([], now=NOW))
        ET.fromstring(svg)
        self.assertIn('First recorded snapshot', svg)
        self.assertNotIn('nan', svg)

    def test_snapshot_validates_totals_and_identity(self):
        data = M.snapshot([], now=NOW)
        for key, value in [('total', True), ('total', 1), ('dmg', -1), ('repository', 'wrong'), ('checked_at', 'bad')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                M.validate({**data, key: value})

    def test_render_is_accessible_and_has_disclaimers(self):
        svg = M.render(M.snapshot(M.fetch_assets(opener([[release(asset())]])), now=NOW))
        root = ET.fromstring(svg)
        self.assertEqual(root.get('role'), 'img')
        self.assertIn('not unique installs', svg)
        self.assertIn('verification downloads', svg)
        self.assertNotIn('<script', svg)

    def test_manual_same_day_checks_keep_both_baselines(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            M.update(root, opener([[release(asset())]]), NOW)
            M.update(root, opener([[release(asset(count=11))]]), NOW+timedelta(minutes=1))
            self.assertEqual(len(list((root/'docs/downloads/snapshots').glob('*.json'))), 2)

    def test_invalid_comparison_metadata_fails_closed(self):
        old = M.snapshot(M.fetch_assets(opener([[release(asset())]])), now=NOW)
        data = M.snapshot(old['assets'], old, NOW+timedelta(days=1))
        for compare in [[], {}, {**data['comparison'], 'delta': True},
                        {**data['comparison'], 'removed_ids': [1]},
                        {**data['comparison'], 'decreased_ids': [999]},
                        {**data['comparison'], 'checked_at': 'injected'}]:
            with self.subTest(compare=compare), self.assertRaises(ValueError):
                M.render({**data, 'comparison': compare})

    def test_readme_layout_invariants(self):
        text = (Path(__file__).resolve().parents[2]/'README.md').read_text()
        self.assertIn('src="https://t0nyz.com/counter/backlit/hero.svg"', text)
        self.assertNotIn('## Downloads', text)
        self.assertNotIn('img.shields.io', text)
        self.assertIn('[License](LICENSE)', text)
        self.assertIn('](docs/media/download-backlit.svg)](https://t0nyz.com/backlit/install)', text)
        install = text.index('## Get Backlit')
        chart = text.index('https://t0nyz.com/counter/backlit/hero.svg')
        picture = text.index('width="780"', install)
        start = text.index('## Seven ways to light up', picture)
        connections = text.index('## Connections', start)
        self.assertLess(chart, install)
        self.assertLess(chart, picture)
        self.assertLess(picture, start)
        self.assertLess(start, connections)
        self.assertIn('built-in screen may remain lit', text)
        self.assertNotIn('## Restoration and automatic recovery', text)

    def test_success_saves_snapshot_and_matching_chart(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); data = M.update(root, opener([[release(asset())]]), NOW)
            self.assertEqual(json.loads((root/'docs/downloads/latest.json').read_text()), data)
            self.assertEqual((root/'docs/media/downloads.svg').read_text(), M.render(data))
            self.assertTrue((M.snapshot_path(root, '2026-11-18T01:00:00Z')).exists())
