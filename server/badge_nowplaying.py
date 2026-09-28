# "Now serving" card: a rounded badge showing the last song served, with its
# cover art, title and artist. Rendered server-side as an SVG so a README can
# show it with one <img>.
#
# WHY THE COVER IS A DATA URI. An SVG referenced from an <img> is rendered in
# a restricted mode: no external resources at all, so <image href="https://...">
# renders as an empty box. GitHub additionally proxies README images through
# camo, which would need to fetch the cover itself. Embedding base64 JPEG is
# the only thing that actually displays. mqdefault is 320x180 and ~5-8 KB,
# base64 ~7-11 KB, which is a heavy badge -- hence the cache below and the
# ?art=0 escape hatch for anyone who only wants the text.
#
# "word by word": the title is revealed with a CSS mask that sweeps left to
# right. SMIL <animate> would be ignored by every GitHub-side renderer, and a
# CSS animation is equally still when the SVG is rasterised, so the title
# animates in a browser and simply appears complete everywhere else. It is
# never left half-hidden: the mask is only ever applied when there is
# something to reveal, and the full title is always in the DOM for
# accessibility and for aria-label.
import base64
import re
import threading
import time as _time

# How long a fetched cover stays usable, and how many to keep. The card is
# requested at most every _TTL seconds and the song changes rarely, so a
# small cache absorbs nearly all refetching.
_ART_TTL = 900.0
_ART_MAX = 8
_art_cache = {}
_art_lock = threading.Lock()

# Bounds on the artwork we are willing to embed. A hostile or broken upstream
# must not be able to make the server hold a huge string in RAM and hand it to
# every reader of the README. This only applies to the UNSHRUNK path -- with
# Pillow the output is ~1 KB by construction.
_ART_MAX_BYTES = 64 * 1024

# Geometry. 28px cover + 8px gap + 10px trailing pad.
_NP_ART = 28
_NP_GAP = 8
_NP_PAD_L = 8
_NP_PAD_R = 12
_NP_H = 44
_NP_MAX_W = 460
_NP_MIN_W = 200

# Two lines: title on top, artist under it.
_NP_TITLE_Y = 19
_NP_ARTIST_Y = 33
_NP_TITLE_PX = 13
_NP_ARTIST_PX = 11

# The Roboto advance-width table lives in routes_misc, which IMPORTS this
# module -- so importing it back would be circular. Read it out of that
# module's source once, lazily, and cache it. Kept as a copy rather than a
# second hard-coded table so the two can never drift.
_W = None


def _width_table():
    global _W
    if _W is None:
        from . import routes_misc
        # _BADGE_ASCII_W is the raw space-separated string; _BADGE_W is the
        # parsed float list. Taking the wrong one fails at the first index.
        _W = routes_misc._BADGE_W
    return _W


def _esc(s):
    """XML-escape text and attribute content. Quotes matter: the title goes
    into an aria-label attribute, and an unescaped " would end it early."""
    s = (s or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    return s.replace('"', '&quot;').replace("'", '&apos;')


def _text_width(text, px=13.0):
    """Advance width of `text` at `px`, in the same font the badges use.

    The table is Roboto Medium at 13px, so scale linearly. Non-ASCII gets a
    rough width: CJK is full width, everything else (accents, symbols) is
    treated as a narrow latin glyph.
    """
    if not text:
        return 0.0
    w = _width_table()
    total = 0.0
    for ch in text:
        cp = ord(ch)
        if 32 <= cp <= 126:
            total += w[cp - 32]
        elif cp > 0x2E80:
            total += 13.0            # CJK and friends
        else:
            total += 7.0
    return total * px / 13.0


def _shrink(raw):
    """Re-encode `raw` to a 2x thumbnail, or None if Pillow is unavailable.

    Pillow is NOT in requirements.txt, so this is opportunistic: with it the
    cover costs ~1 KB instead of 6-15 KB, without it the raw bytes are used.
    Never a hard dependency for a badge.
    """
    try:
        import io
        from PIL import Image
        img = Image.open(io.BytesIO(raw))
        img = img.convert('RGB')
        # Centre-crop to square: YouTube's 16:9 thumbs letterbox, and a
        # squeezed 16:9 into 28x28 puts the subject in a sliver.
        w, h = img.size
        side = min(w, h)
        img = img.crop(((w - side) // 2, (h - side) // 2,
                        (w - side) // 2 + side, (h - side) // 2 + side))
        img = img.resize((_NP_ART * 2, _NP_ART * 2), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, 'JPEG', quality=72, optimize=True)
        return buf.getvalue()
    except Exception:
        return None


def _art_for(video_id):
    """base64 JPEG for `video_id`, or '' when unavailable.

    Never raises and never returns a partial image: a failed cover must still
    yield a usable card with the text on it.
    """
    if not video_id:
        return ''
    now = _time.time()
    with _art_lock:
        hit = _art_cache.get(video_id)
        if hit and now - hit[0] < _ART_TTL:
            return hit[1]
    try:
        from .providers_yt import yt_cover_url
        url = yt_cover_url(video_id, 'hq')
        if not url:
            return ''
        # mqdefault is the 16:9 crop at 320x180, the smallest YouTube serves.
        url = url.replace('/hqdefault.jpg', '/mqdefault.jpg')
        import requests
        r = requests.get(url, timeout=6)
        if r.status_code != 200 or not r.content:
            return ''
        ctype = (r.headers.get('Content-Type') or 'image/jpeg').split(';')[0]
        if not ctype.startswith('image/'):
            return ''
        if len(r.content) > _ART_MAX_BYTES:
            return ''
        small = _shrink(r.content)
        if small:
            payload, ctype = small, 'image/jpeg'
        else:
            payload = r.content
        b64 = base64.b64encode(payload).decode('ascii')
        data = f'data:{ctype};base64,{b64}'
    except Exception:
        return ''
    with _art_lock:
        if len(_art_cache) >= _ART_MAX:
            oldest = min(_art_cache, key=lambda k: _art_cache[k][0])
            _art_cache.pop(oldest, None)
        _art_cache[video_id] = (now, data)
    return data


def _np_clean(s, limit):
    """One line of text: no newlines, no control chars, trimmed, clipped.

    Coerces non-strings. A record with song=12345 comes from a provider that
    returned a number, and a badge must not be the thing that 500s.
    """
    if s is None:
        return ''
    if not isinstance(s, str):
        try:
            s = str(s)
        except Exception:
            return ''
    s = re.sub(r'\s+', ' ', s).strip()
    s = ''.join(ch for ch in s if ch == ' ' or ord(ch) > 0x1F)
    return s[:limit]


def _np_fit(s, max_px, px):
    """Clip `s` with an ellipsis so it fits `max_px` at font size `px`."""
    if _text_width(s, px) <= max_px:
        return s
    ell = '...'
    lo, hi = 0, len(s)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if _text_width(s[:mid] + ell, px) <= max_px:
            lo = mid
        else:
            hi = mid - 1
    return (s[:lo].rstrip() + ell) if lo else ell


def _np_svg(last, art=True, reveal_ms=1400):
    """The card. `last` is usage_stats' last-served record.

    Rounded 22px pill, optional cover on the left, title over artist.
    Dark/light via prefers-color-scheme like the other badges.
    """
    song = _np_clean((last or {}).get('song'), 60)
    artist = _np_clean((last or {}).get('artist'), 48)
    vid = (last or {}).get('video_id') or ''
    if not isinstance(vid, str):
        vid = ''
    if not (song or artist):
        return None

    cover = _art_for(vid) if (art and vid) else ''
    art_w = (_NP_ART + _NP_GAP) if cover else 0
    text_x = _NP_PAD_L + art_w

    # Width follows the WIDER of the two lines, both clipped to the cap.
    budget = _NP_MAX_W - text_x - _NP_PAD_R
    title = _np_fit(song, budget, _NP_TITLE_PX) if song else ''
    artist_t = _np_fit(artist, budget, _NP_ARTIST_PX) if artist else ''
    widest = max(_text_width(title, _NP_TITLE_PX) if title else 0,
                 _text_width(artist_t, _NP_ARTIST_PX) if artist_t else 0)
    w = max(_NP_MIN_W, int(round(text_x + widest + _NP_PAD_R)))

    aria = f'Now serving: {song}' + (f' by {artist}' if artist else '')
    title_len = len(title)
    # Only sweep when there is something to sweep AND a caller asked for it.
    # reveal_ms<=0 or a 1-2 char title looks like a glitch, not an effect.
    sweep = bool(reveal_ms and title_len > 3)

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{_NP_H}" '
        f'viewBox="0 0 {w} {_NP_H}" role="img" aria-label="{_esc(aria)}">',
        '<style>.bg{fill:#D3E3FD}.fg{fill:#041E49}.sub{fill:#3F4A5A;opacity:.85}'
        "font-family:Roboto,-apple-system,'Segoe UI',sans-serif}",
        f'.t{{font-size:{_NP_TITLE_PX}px;font-weight:500}}',
        f'.a{{font-size:{_NP_ARTIST_PX}px;font-weight:400}}',
        '@media (prefers-color-scheme: dark){.bg{fill:#004A77}.fg{fill:#D3E3FD}'
        '.sub{fill:#D3E3FD;opacity:.72}}',
    ]
    if sweep:
        # The mask grows to full width and stays there, so the title is never
        # left partially hidden if the animation is cut short.
        parts.append(
            f'@keyframes np{{from{{clip-path:inset(0 100% 0 0)}}'
            f'to{{clip-path:inset(0 0 0 0)}}}}'
            f'.rev{{animation:np {reveal_ms}ms ease-out forwards}}'
            '@media (prefers-reduced-motion: reduce){.rev{animation:none}}')
    parts.append('</style>')
    parts.append(f'<rect class="bg" width="{w}" height="{_NP_H}" rx="22"/>')

    if cover:
        cx, cy = _NP_PAD_L, (_NP_H - _NP_ART) // 2
        parts.append(
            f'<clipPath id="npc"><rect x="{cx}" y="{cy}" width="{_NP_ART}" '
            f'height="{_NP_ART}" rx="8"/></clipPath>')
        parts.append(
            f'<image href="{cover}" x="{cx}" y="{cy}" width="{_NP_ART}" '
            f'height="{_NP_ART}" preserveAspectRatio="xMidYMid slice" '
            f'clip-path="url(#npc)"/>')

    if title:
        cls = 't rev' if sweep else 't'
        parts.append(f'<text class="fg {cls}" x="{text_x}" y="{_NP_TITLE_Y}">'
                     f'{_esc(title)}</text>')
    if artist_t:
        parts.append(f'<text class="sub a" x="{text_x}" y="{_NP_ARTIST_Y}">'
                     f'{_esc(artist_t)}</text>')
    parts.append('</svg>')
    return ''.join(parts)


def now_playing_svg(art=True, reveal_ms=1400):
    """Public entry. Returns an SVG string, or a plain pill if the record is
    empty, so the README never shows a broken image.

    routes_misc is imported HERE, not at module scope: routes_misc imports
    this module for the route, so a top-level import back would be circular.
    By request time routes_misc is fully loaded, so this is safe.
    """
    from .usage_stats import snapshot
    last = (snapshot() or {}).get('last') or {}
    try:
        svg = _np_svg(last, art=art, reveal_ms=reveal_ms)
    except Exception as e:
        print(f'[BADGE] [WARN] now-playing failed: {e}')
        svg = None
    if svg:
        return svg
    try:
        from .routes_misc import _badge_svg
        return _badge_svg('Nothing served yet', glyph='lyrics')
    except Exception as e:
        print(f'[BADGE] [WARN] fallback pill failed: {e}')
        # A hand-built pill, so even a broken import cannot yield a non-SVG
        # body -- the endpoint would then serve JSON with an image mime type.
        return ('<svg xmlns="http://www.w3.org/2000/svg" width="180" height="32" '
                'viewBox="0 0 180 32" role="img" aria-label="Nothing served yet">'
                '<rect width="180" height="32" rx="16" fill="#D3E3FD"/>'
                '<text x="16" y="21" font-family="Roboto,sans-serif" '
                'font-size="13" fill="#041E49">Nothing served yet</text></svg>')
