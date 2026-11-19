#!/usr/bin/env python3
"""Render the README feature panels as self-contained animated SVGs (stdlib only).

Every panel is drawn here, so the copy, the illustrated lid and the embedded
native captures stay in one place. Run it after replacing a capture:

    python3 scripts/render-readme-panels.py

The lid drawings are illustrations of the light, not hardware footage. The two
captures are embedded as data URIs because an SVG shown through <img> cannot
load other files.
"""
import base64
import math
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/media/preview'
FONT = "-apple-system,BlinkMacSystemFont,'SF Pro Display','Segoe UI',Helvetica,Arial,sans-serif"
INK, MUTED, SOFT, TILE = '#f5f5f7', '#a1a1a6', '#c7c7cc', '#1c1c1e'

STYLE = f"""
text{{font-family:{FONT}}}
.eyebrow{{font-size:15px;font-weight:600;fill:{MUTED}}}
.h{{font-weight:700;fill:{INK}}}
.p{{fill:{MUTED}}}
.s{{fill:{SOFT}}}
.b{{font-weight:600;fill:{INK}}}
@keyframes breathe{{0%,100%{{opacity:.1}}50%{{opacity:1}}}}
@keyframes beat{{0%,100%{{opacity:.2}}8%{{opacity:1}}34%{{opacity:.2}}}}
@keyframes eq{{0%,100%{{transform:scaleY(.25)}}50%{{transform:scaleY(1)}}}}
.breathe{{animation:breathe 4.5s ease-in-out infinite}}
.beat{{animation:beat 1.1s ease-out infinite}}
.eq{{transform-box:fill-box;transform-origin:50% 100%;animation:eq 1.1s ease-in-out infinite}}
"""

DEFS = """
<linearGradient id="lid" x1="0" y1="0" x2=".55" y2="1"><stop offset="0" stop-color="#2c2c2f"/><stop offset=".5" stop-color="#171719"/><stop offset="1" stop-color="#0b0b0c"/></linearGradient>
<radialGradient id="glow"><stop offset="0" stop-color="#fff" stop-opacity=".62"/><stop offset=".2" stop-color="#fff" stop-opacity=".27"/><stop offset=".55" stop-color="#fff" stop-opacity=".07"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
"""


def data_uri(path: Path, kind: str) -> str:
    return f'data:image/{kind};base64,' + base64.b64encode(path.read_bytes()).decode()


def text(x, y, value, cls, size=None, anchor=None, spacing=None):
    attrs = f' font-size="{size}"' if size else ''
    attrs += f' text-anchor="{anchor}"' if anchor else ''
    attrs += f' letter-spacing="{spacing}"' if spacing else ''
    return f'<text x="{x}" y="{y}" class="{cls}"{attrs}>{escape(value)}</text>'


def lines(x, y, values, cls, size, step, anchor=None, spacing=None):
    return ''.join(text(x, y + index * step, value, cls, size, anchor, spacing)
                   for index, value in enumerate(values))


def lid(name, x, y, w, h, r, mark, motion='', duration=None, level=1.0):
    """An illustrated lid: Backlit's own square light, never a third-party mark."""
    cx, cy = x + w / 2, y + h / 2
    style = f' style="animation-duration:{duration}"' if duration else ''
    cls = f' class="{motion}"' if motion else ''
    level_attr = f' opacity="{level}"' if level != 1.0 else ''
    return (
        f'<clipPath id="{name}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}"/></clipPath>'
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="url(#lid)"/>'
        f'<rect x="{x + .5}" y="{y + .5}" width="{w - 1}" height="{h - 1}" rx="{r}" fill="none" stroke="#fff" stroke-opacity=".09"/>'
        f'<g clip-path="url(#{name})"><g{level_attr}><g{cls}{style}>'
        f'<circle cx="{cx}" cy="{cy}" r="{mark * 5.2}" fill="url(#glow)"/>'
        f'<rect x="{cx - mark / 2}" y="{cy - mark / 2}" width="{mark}" height="{mark}" rx="{round(mark * .26, 2)}" fill="#fff"/>'
        f'</g></g></g>')


def bars(x, bottom, heights, width=7, gap=5):
    tones = ['#ffffff'] * 5 + [MUTED] * 4 + ['#6e6e73'] * 9
    delays = [.1, .5, .9, .3, .7, .2, .6, 1, .4, .8, .15, .55, .95, .35]
    return ''.join(
        f'<rect class="eq" style="animation-delay:-{delays[i % len(delays)]}s" x="{x + i * (width + gap)}" y="{bottom - value}" width="{width}" height="{value}" rx="3" fill="{tones[i]}"/>'
        for i, value in enumerate(heights))


def star(cx, cy, outer, inner, points=5, turn=-90.0):
    coords = []
    for index in range(points * 2):
        radius = outer if index % 2 == 0 else inner
        angle = math.radians(turn + index * 180 / points)
        coords.append(f'{cx + radius * math.cos(angle):.2f},{cy + radius * math.sin(angle):.2f}')
    return ' '.join(coords)


def stripes(colors, vertical=False, weights=None):
    weights = weights or [1] * len(colors)
    total, offset, out = sum(weights), 0.0, ''
    for color, weight in zip(colors, weights):
        size = (30 if vertical else 20) * weight / total
        out += (f'<rect x="{offset:.2f}" width="{size:.2f}" height="20" fill="{color}"/>' if vertical else
                f'<rect y="{offset:.2f}" width="30" height="{size:.2f}" fill="{color}"/>')
        offset += size
    return out


def trigram(angle, side, broken):
    bars = ''
    for position, split in zip((-1.45, 0, 1.45), broken):
        spans = [(-2.3, 1.95), (.35, 1.95)] if split else [(-2.3, 4.6)]
        bars += ''.join(f'<rect x="{position - .45:.2f}" y="{top}" width=".9" height="{height}"/>' for top, height in spans)
    return f'<g transform="translate(15,10) rotate({angle}) translate({side * 9.3},0)">{bars}</g>'


def flag(code):
    """Small flat flags drawn in a 30 by 20 box, simplified for size, so they look the same on every system."""
    if code == 'us':
        dots = ''.join(f'<circle cx="{1.2 + col * 1.92:.2f}" cy="{1.1 + row * 2.15:.2f}" r=".42"/>'
                       for row in range(5) for col in range(6))
        return (stripes(['#B22234', '#fff'] * 6 + ['#B22234'])
                + f'<rect width="12" height="10.77" fill="#3C3B6E"/><g fill="#fff">{dots}</g>')
    if code == 'es':
        return stripes(['#AA151B', '#F1BF00', '#AA151B'], weights=[1, 2, 1])
    if code == 'fr':
        return stripes(['#0055A4', '#fff', '#EF4135'], vertical=True)
    if code == 'de':
        return stripes(['#000', '#DD0000', '#FFCE00'])
    if code == 'jp':
        return '<rect width="30" height="20" fill="#fff"/><circle cx="15" cy="10" r="6" fill="#BC002D"/>'
    if code == 'kr':
        return ('<rect width="30" height="20" fill="#fff"/><g transform="translate(15,10) rotate(33.69)">'
                '<path d="M-5,0A5,5 0 0 1 5,0Z" fill="#CD2E3A"/><path d="M-5,0A5,5 0 0 0 5,0Z" fill="#0047A0"/>'
                '<circle cx="-2.5" r="2.5" fill="#CD2E3A"/><circle cx="2.5" r="2.5" fill="#0047A0"/></g>'
                + trigram(33.69, -1, (False, False, False)) + trigram(33.69, 1, (True, True, True))
                + trigram(-33.69, 1, (True, False, True)) + trigram(-33.69, -1, (False, True, False)))
    if code == 'br':
        return ('<rect width="30" height="20" fill="#009C3B"/><polygon points="15,2.2 27.4,10 15,17.8 2.6,10" fill="#FFDF00"/>'
                '<circle cx="15" cy="10" r="4.4" fill="#002776"/>'
                '<path d="M10.9,8.9Q15.2,7.9 19.2,11.3" fill="none" stroke="#fff" stroke-width=".9"/>')
    if code == 'cn':
        small = ''.join(
            f'<polygon points="{star(x, y, 1, .382, turn=math.degrees(math.atan2(5 - y, 5 - x)))}"/>'
            for x, y in ((10, 2), (12, 4), (12, 7), (10, 9)))
        return ('<rect width="30" height="20" fill="#DE2910"/>'
                f'<g fill="#FFDE00"><polygon points="{star(5, 5, 3, 1.146)}"/>{small}</g>')
    if code == 'tw':
        return ('<rect width="30" height="20" fill="#FE0000"/><rect width="15" height="10" fill="#000095"/>'
                f'<polygon points="{star(7.5, 5, 3.75, 2, points=12)}" fill="#fff"/>'
                '<circle cx="7.5" cy="5" r="2.2" fill="#000095"/><circle cx="7.5" cy="5" r="1.85" fill="#fff"/>')
    return stripes(['#A51931', '#F4F5F8', '#2D2A4A', '#F4F5F8', '#A51931'], weights=[1, 1, 2, 1, 1])


def flag_at(code, x, y, scale=1.2):
    return (f'<g transform="translate({x},{y}) scale({scale})"><clipPath id="flag-{code}"><rect width="30" height="20" rx="2.5"/></clipPath>'
            f'<g clip-path="url(#flag-{code})">{flag(code)}</g>'
            '<rect x=".3" y=".3" width="29.4" height="19.4" rx="2.3" fill="none" stroke="#fff" stroke-opacity=".22" stroke-width=".6"/></g>')


def panel(name, width, height, title, description, body):
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">'
        f'<title id="title">{escape(title)}</title><desc id="desc">{escape(description)}</desc>'
        f'<style>{STYLE}</style><defs>{DEFS}<clipPath id="panel"><rect width="{width}" height="{height}" rx="28"/></clipPath></defs>'
        f'<rect width="{width}" height="{height}" rx="28" fill="#000"/><g clip-path="url(#panel)">{body}</g></svg>\n')
    OUT.joinpath(name).write_text(svg)


def half(name, eyebrow, heading, copy, visual, title, description, height=420):
    body = (text(36, 50, eyebrow, 'eyebrow')
            + lines(36, 91, heading, 'h', 32, 35, spacing='-.03em')
            + lines(36, 91 + 35 * len(heading) - 3, copy, 'p', 16, 22)
            + visual)
    panel(name, 395, height, title, description, body)


def main() -> None:
    menu = data_uri(OUT / 'menu-bar.jpg', 'jpeg')
    window = data_uri(OUT / 'main-window.jpg', 'jpeg')

    panel('panel-menu-bar.svg', 806, 440, 'Menu bar: one click away',
          'Backlit’s native menu bar popover with the backlight switch, behavior picker and current output. '
          'Switch the light, pick a behavior and see a live preview, or press Control-Command-B from any app.',
          text(48, 128, 'Menu bar', 'eyebrow')
          + lines(48, 186, ['One click', 'away.'], 'h', 50, 51, spacing='-.035em')
          + lines(48, 280, ['Switch the light, pick a behavior,', 'see a live preview. Or press',
                            'Control-Command-B from any app.'], 'p', 17, 24)
          + '<clipPath id="popover"><rect x="446" y="38" width="300" height="364" rx="14"/></clipPath>'
          + '<g clip-path="url(#popover)"><svg x="446" y="38" width="300" height="364" viewBox="407 60 334 409" preserveAspectRatio="none">'
          + f'<image width="870" height="530" href="{menu}"/></svg></g>'
          + '<rect x="446" y="38" width="300" height="364" rx="14" fill="none" stroke="#fff" stroke-opacity=".14"/>')

    panel('panel-main-window.svg', 806, 480, 'Main window: pick a mode, tune the glow',
          'Backlit’s native main window with the live logo preview, the list of seven behaviors and the output settings.',
          text(403, 58, 'Main window', 'eyebrow', anchor='middle')
          + text(403, 106, 'Pick a mode. Tune the glow.', 'h', 40, 'middle', '-.03em')
          + '<clipPath id="window"><rect x="83" y="150" width="640" height="400" rx="12"/></clipPath>'
          + f'<g clip-path="url(#window)"><image x="83" y="150" width="640" height="400" href="{window}"/></g>'
          + '<rect x="83" y="150" width="640" height="400" rx="12" fill="none" stroke="#fff" stroke-opacity=".14"/>')

    panel('panel-breathe.svg', 806, 340, 'Breathe: a slow, quiet pulse',
          'An illustrated lid whose light fades in and out. Breathe runs on a 3 to 30 second cycle, '
          'and you set the brightness and how low it dims.',
          text(48, 103, 'Breathe', 'eyebrow')
          + lines(48, 160, ['A slow,', 'quiet pulse.'], 'h', 50, 51, spacing='-.035em')
          + lines(48, 252, ['A 3 to 30 second cycle. You set the', 'brightness and how low it dims.'], 'p', 17, 24)
          + lid('l', 450, 75, 300, 190, 14, 24, 'breathe'))

    half('panel-music.svg', 'Music', ['It moves with the', 'bass.'],
         ['Follows whatever your Mac is playing.', 'Smooth, Balanced or Punchy.', 'No microphone.'],
         lid('l', 92.5, 216, 210, 132, 10, 17, 'beat')
         + bars(116, 388, [14, 24, 18, 26, 16, 22, 12, 18, 10, 20, 13, 8, 16, 11]),
         'Music: it moves with the bass',
         'An illustrated lid whose light flashes on each bass hit, above a moving level meter. '
         'Music follows whatever your Mac is playing, with Smooth, Balanced or Punchy response, and never uses the microphone.')

    half('panel-agents.svg', 'Agents', ['Know when your', 'agent needs you.'],
         ['Working, waiting, or asking for you.', 'For Claude Code and Codex.'],
         lid('l', 92.5, 208, 210, 132, 10, 17, 'beat', '2.2s')
         + f'<rect x="72.5" y="352" width="250" height="36" rx="18" fill="{TILE}"/>'
         + '<rect x="73" y="352.5" width="249" height="35" rx="17.5" fill="none" stroke="#fff" stroke-opacity=".1"/>'
         + '<rect class="beat" style="animation-duration:2.2s" x="88" y="366" width="8" height="8" rx="2.5" fill="#fff"/>'
         + text(106, 375, 'Claude Code is waiting for you', 'b', 14),
         'Agents: know when your agent needs you',
         'An illustrated lid whose light pulses beside a status reading “Claude Code is waiting for you”. '
         'Agents shows working, waiting and attention states for Claude Code and Codex.')

    half('panel-battery.svg', 'Battery', ['Glows with your', 'charge.'],
         ['Brightness follows your battery. It', 'pulses while charging and holds', 'steady when full.'],
         text(36, 332, '82%', 'h', 68, spacing='-.05em') + lid('l', 189, 241, 170, 107, 9, 14, level=.82),
         'Battery: glows with your charge',
         'An illustrated lid lit at 82 percent beside the figure 82%. Brightness follows your battery, '
         'pulses while charging and holds steady when full.', height=380)

    keys = ''.join(
        (f'<rect class="beat" style="animation-duration:.7s" x="{36 + i * 45}" y="275.5" width="38" height="38" rx="9" fill="{INK}"/>'
         if i == 1 else
         f'<rect x="{36 + i * 45}" y="275.5" width="38" height="38" rx="9" fill="{TILE}"/>'
         f'<rect x="{36.5 + i * 45}" y="276" width="37" height="37" rx="8.5" fill="none" stroke="#fff" stroke-opacity=".1"/>')
        for i in range(3))
    half('panel-trackpad-typing.svg', 'Trackpad · Typing', ['Lights up as you', 'work.'],
         ['A finger resting on the trackpad, or', 'the rhythm of your typing. Never', 'what you type.'],
         keys + lid('l', 189, 241, 170, 107, 9, 14, 'beat', '.7s'),
         'Trackpad and Typing: lights up as you work',
         'Three illustrated keys, one lit, beside a lid whose light flashes in time. Trackpad lights up while a finger '
         'rests on the trackpad, and Typing follows the rhythm of your typing, never what you type.', height=380)

    modes = [('Steady', '', None, 1.0), ('Breathe', 'breathe', None, 1.0), ('Battery', '', None, .45),
             ('Music', 'beat', None, 1.0), ('Agents', 'beat', '2.2s', 1.0), ('Trackpad', '', None, .75),
             ('Typing', 'beat', '.6s', 1.0)]
    cell = (806 - 96 - 6 * 14) / 7
    strip = text(48, 78, 'Seven ways to light up.', 'h', 36, spacing='-.03em')
    for index, (label, motion, duration, level) in enumerate(modes):
        x = round(48 + index * (cell + 14), 2)
        strip += lid(f'm{index}', x, 116, round(cell, 2), 56, 7, 10, motion, duration, level)
        strip += text(x, 197, label, 'b', 15)
    panel('panel-modes.svg', 806, 240, 'Seven ways to light up',
          'Seven illustrated lids, one for each behavior: Steady, Breathe, Battery, Music, Agents, Trackpad and Typing.', strip)

    panel('panel-closed-lid.svg', 806, 300, 'Closed lid: shut the lid, keep the light',
          'An illustrated lid with its light on and a 30 min label. Closed-lid lighting runs for 1 to 30 minutes.',
          text(48, 92, 'Closed lid', 'eyebrow')
          + lines(48, 146, ['Shut the lid.', 'Keep the light.'], 'h', 46, 47, spacing='-.035em')
          + text(48, 234, 'Closed-lid lighting for 1 to 30 minutes.', 'p', 17)
          + lid('l', 490, 45, 260, 164, 12, 20)
          + '<rect x="578.5" y="223.5" width="83" height="31" rx="15.5" fill="none" stroke="#fff" stroke-opacity=".2"/>'
          + text(620, 244, '30 min', 'b', 15, 'middle'))

    links = [('Claude Code and Codex', ['Status hooks light the logo while', 'your agent works.']),
             ('Home Assistant', ['A local light and status sensors.', 'No cloud needed.']),
             ('MCP', ['Local AI assistants can read the', 'light, or change it if you allow.']),
             ('Stream Deck', ['Put the light on a key.', 'Experimental add-on.'])]
    tiles = text(48, 58, 'Connections', 'eyebrow') + text(48, 106, 'Fits your setup.', 'h', 40, spacing='-.03em')
    for index, (label, copy) in enumerate(links):
        x, y = 48 + (index % 2) * 362, 134 + (index // 2) * 154
        tiles += f'<rect x="{x}" y="{y}" width="348" height="140" rx="20" fill="{TILE}"/>'
        tiles += text(x + 26, y + 50, label, 'h', 26, spacing='-.02em')
        tiles += lines(x + 26, y + 82, copy, 's', 17, 24)
    panel('panel-connections.svg', 806, 472, 'Connections: fits your setup',
          'Four connections. Claude Code and Codex: status hooks light the logo while your agent works. '
          'Home Assistant: a local light and status sensors, no cloud needed. MCP: local AI assistants can read the light, '
          'or change it if you allow. Stream Deck: put the light on a key, an experimental add-on.', tiles)

    extras = [('Option-click', ['Toggle the light', 'from the menu bar', 'icon.']),
              ('Your shortcuts', ['Toggle, brighter,', 'dimmer. Set your', 'own keys.']),
              ('Out of the way', ['Hide the menu bar', 'icon or the Dock', 'icon.']),
              ('Launch at login', ['Ready when your', 'Mac starts.']),
              ('No account', ['Nothing to sign', 'up for.']),
              ('Private', ['No audio saved.', 'Hooks never send', 'prompts or code.']),
              ('Preview mode', ['Try the interface', 'without the', 'hardware.']),
              ('Source available', ['Read it, or build', 'it yourself.'])]
    rest = text(48, 86, 'And the rest.', 'h', 40, spacing='-.03em')
    for index, (label, copy) in enumerate(extras):
        x, y = round(48 + (index % 4) * 183.5, 1), 144 + (index // 4) * 118
        rest += text(x, y, label, 'h', 19, spacing='-.01em') + lines(x, y + 26, copy, 's', 15, 21)
    panel('panel-more.svg', 806, 372, 'And the rest',
          'Option-click the menu bar icon to toggle the light. Your own shortcuts for toggle, brighter and dimmer. '
          'Hide the menu bar icon or the Dock icon. Launch at login. No account. Private: no audio saved, and hooks never '
          'send prompts or code. Preview mode to try the interface without the hardware. Source available to read or build.', rest)

    languages = [('us', 'English'), ('es', 'Español'), ('fr', 'Français'), ('de', 'Deutsch'), ('jp', '日本語'),
                 ('kr', '한국어'), ('br', 'Português'), ('cn', '简体中文'), ('tw', '繁體中文'), ('th', 'ไทย')]
    tongues = text(48, 58, 'Languages', 'eyebrow') + text(48, 106, 'In ten languages.', 'h', 40, spacing='-.03em')
    for index, (code, label) in enumerate(languages):
        x, y = 48 + (index % 5) * 148, 148 + (index // 5) * 46
        tongues += flag_at(code, x, y) + text(x + 46, y + 18, label, 'b', 16)
    tongues += text(48, 262, 'Follows your Mac’s language, or pick one in Settings.', 'p', 17)
    panel('panel-languages.svg', 806, 306, 'In ten languages',
          'Ten interface languages, each shown with a small flag: English, Spanish, French, German, Japanese, Korean, '
          'Brazilian Portuguese, Simplified Chinese, Traditional Chinese and Thai. Backlit follows your Mac’s language, '
          'or you can pick one in Settings.', tongues)

    ROOT.joinpath('docs/media/download-backlit.svg').write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" width="250" height="56" viewBox="0 0 250 56" role="img" aria-labelledby="title desc">\n'
        '<title id="title">Download Backlit for Apple silicon</title><desc id="desc">Get the latest ZIP or DMG from the official Backlit installer page.</desc>\n'
        '<rect x="1" y="1" width="248" height="54" rx="27" fill="#f5f5f7" stroke="#c9c9ce" stroke-width="1"/>\n'
        '<path d="M52 18v15m-7-7 7 7 7-7M43 39h18" stroke="#000" stroke-width="2.4" fill="none" stroke-linecap="round" stroke-linejoin="round"/>\n'
        f'<text x="76" y="34" font-family="{FONT}" font-size="17" font-weight="600" fill="#000">Download Backlit</text>\n'
        '</svg>\n')
    print(f'Rendered {len(list(OUT.glob("panel-*.svg")))} README panels and the download button.')


if __name__ == '__main__':
    main()
