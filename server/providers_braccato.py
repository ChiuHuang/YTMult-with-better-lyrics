# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Direct lyric providers mirroring better-lyrics/braccato
# packages/provider-blyrics/src/providers: these need no JWT/Turnstile and
# give the same sources the Better Lyrics extension races:
#   blyrics.ts  -> GET lyrics-api.boidu.dev/getLyrics          (TTML)
#   portato.ts  -> GET lyrics-api.boidu.dev/qq/getLyrics       (QRC, word-by-word)
#   legato.ts   -> GET lyrics-api.boidu.dev/kugou/getLyrics    (LRC)
#   binimum.ts  -> lyrics-api.binimum.org search + lyricsUrl   (TTML, syllable)
# Every call has a short timeout and returns None on any failure so the
# caller can fall back exactly as if the provider were absent.
import re
import json
import requests
from urllib.parse import urlencode
from .parsers_qrc import parse_qrc_to_lrc
from .parsers_ttml import parse_ttml_basic

BOIDU_TTML_URL = "https://lyrics-api.boidu.dev/getLyrics"
BOIDU_QQ_URL = "https://lyrics-api.boidu.dev/qq/getLyrics"
BOIDU_KUGOU_URL = "https://lyrics-api.boidu.dev/kugou/getLyrics"
BINIMUM_SEARCH_URL = "https://lyrics-api.binimum.org/"

_TIMEOUT = 10


def _retrieve(url, params, via_node=None):
    """GET url+params, returning the response body text or None on any
    failure. When via_node is set the request egresses through that node's
    IP (same discipline as every other provider): node failure falls back to
    a direct request so a dead node never blocks a re-race."""
    if via_node:
        from .nodes import relay_http_request
        full = url + ('?' + urlencode(params) if params else '')
        out = relay_http_request(via_node, 'GET', full, timeout=_TIMEOUT + 5)
        if out is not None:
            status, text = out
            return text if status == 200 else None
    try:
        resp = requests.get(url, params=params, timeout=_TIMEOUT)
    except Exception as e:
        print(f"[braccato] fetch error: {e}")
        return None
    if resp.status_code != 200:
        return None
    return resp.text


def _peel_json_string(value):
    """Return a plain text payload out of a decoded-API envelope: either the
    string itself, or the inner {'lyrics': ...} / {'ttml': ...} a provider
    sometimes double-encodes."""
    if isinstance(value, dict):
        return value.get('lyrics') or value.get('ttml') or ''
    if not isinstance(value, str):
        return ''
    stripped = value.strip()
    if not stripped.startswith('{'):
        return value
    try:
        inner = json.loads(stripped)
        if isinstance(inner, dict):
            inner = inner.get('lyrics') or inner.get('ttml') or inner
        return inner if isinstance(inner, str) else value
    except Exception:
        return value


def _parse_ttml(payload):
    """Parse a (possibly double-encoded) TTML payload into lyric entries."""
    if isinstance(payload, dict):
        payload = payload.get('ttml', payload)
    if not isinstance(payload, str) or not payload.strip():
        return None
    stripped = payload.strip()
    if stripped.startswith('{'):
        try:
            inner = json.loads(stripped)
            if isinstance(inner, dict) and inner.get('ttml'):
                payload = inner['ttml']
        except Exception:
            pass
    return parse_ttml_basic(payload)


def fetch_boidu_ttml(song, artist, duration=0, album='', via_node=None):
    """bLyrics TTML (boidu.dev/getLyrics). Word-synced when spans exist."""
    try:
        params = {'s': song, 'a': artist, 'd': str(int(duration))}
        if album:
            params['al'] = album
        text = _retrieve(BOIDU_TTML_URL, params, via_node)
        if not text:
            return None
        data = json.loads(text)
        lyrics = _parse_ttml(data.get('ttml'))
        if not lyrics:
            return None
        return {'parsed': lyrics, 'source': 'bLyrics', 'wordSynced': any(l.get('wordSynced') for l in lyrics)}
    except Exception as e:
        print(f"[bLyrics] error: {e}")
        return None


def fetch_boidu_qq(song, artist, duration=0, album='', via_node=None):
    """Portato QRC (boidu.dev/qq/getLyrics): true word-by-word timing."""
    try:
        params = {'s': song, 'a': artist, 'd': str(int(duration))}
        if album:
            params['al'] = album
        text = _retrieve(BOIDU_QQ_URL, params, via_node)
        if not text:
            return None
        data = json.loads(text)
        if not data.get('lyrics') or data.get('error'):
            return None
        qrc_lrc = parse_qrc_to_lrc(_peel_json_string(data.get('lyrics')))
        if not qrc_lrc:
            return None
        return {'synced': qrc_lrc, 'source': 'QQ', 'wordSynced': True}
    except Exception as e:
        print(f"[Portato] error: {e}")
        return None


def fetch_boidu_kugou(song, artist, duration=0, album='', via_node=None):
    """Legato LRC (boidu.dev/kugou/getLyrics)."""
    try:
        params = {'s': song, 'a': artist, 'd': str(int(duration))}
        if album:
            params['al'] = album
        text = _retrieve(BOIDU_KUGOU_URL, params, via_node)
        if not text:
            return None
        data = json.loads(text)
        lrc = _peel_json_string(data.get('lyrics'))
        if not lrc:
            return None
        return {'synced': lrc, 'source': 'KuGou', 'wordSynced': False}
    except Exception as e:
        print(f"[Legato] error: {e}")
        return None


def fetch_binimum(song, artist, duration=0, album='', via_node=None):
    """BiniLyrics TTML via search -> lyricsUrl (lyrics-api.binimum.org)."""
    try:
        params = {'track': song, 'artist': artist, 'duration': str(int(duration))}
        if album:
            params['album'] = album
        text = _retrieve(BINIMUM_SEARCH_URL, params, via_node)
        if not text:
            return None
        search = json.loads(text)
        selected = (search.get('results') or [{}])[0]
        lyrics_url = selected.get('lyricsUrl')
        if not lyrics_url:
            return None
        ttml_text = _retrieve(lyrics_url, None, via_node)
        if not ttml_text:
            return None
        lyrics = _parse_ttml(ttml_text)
        if not lyrics:
            return None
        syllable = selected.get('timing_type') == 'syllable' or any(l.get('wordSynced') for l in lyrics)
        return {'parsed': lyrics, 'source': 'BiniLyrics', 'wordSynced': syllable}
    except Exception as e:
        print(f"[Binimum] error: {e}")
        return None


_DIRECT_FETCHERS = {
    'ttml': fetch_boidu_ttml,
    'qq': fetch_boidu_qq,
    'kugou': fetch_boidu_kugou,
    'binimum': fetch_binimum,
}


def _candidate_dict(raw, duration, priority):
    """Shape a provider result into the race-compatible dict with fidelity
    tier, so the best-of set picks word-by-word ahead of line sync."""
    if not raw:
        return None
    if raw.get('parsed'):
        lyrics = raw['parsed']
        wbw = bool(raw.get('wordSynced'))
    elif raw.get('synced'):
        from .parsers_lrc import parse_lrc
        lyrics = parse_lrc(raw['synced'], duration)
        wbw = bool(raw.get('wordSynced'))
    else:
        return None
    return {'lyrics': lyrics, 'source': raw.get('source', ''), 'synced': True,
            'wordSynced': wbw, 'tier': (0 if wbw else 1), 'priority': priority}


def fetch_direct_best(queries, album='', duration=0, sources=('ttml', 'qq', 'kugou', 'binimum'), via_node=None):
    """Race the direct braccato providers across all search queries and
    return the single best result ({lyrics, source, synced, wordSynced}) or
    None. Word/syllable timing beats line sync; within a tier, source order
    above is the tiebreak. via_node relays every request through a node
    (falling back to a direct request when the relay fails)."""
    best = None
    for q in queries:
        for i, name in enumerate(sources):
            fetcher = _DIRECT_FETCHERS.get(name)
            if not fetcher:
                continue
            try:
                raw = fetcher(q['title'], q['artist'], duration, album, via_node)
            except Exception:
                continue
            cand = _candidate_dict(raw, duration, priority=i)
            if not cand:
                continue
            if best is None or cand['tier'] < best['tier'] or (
                    cand['tier'] == best['tier'] and cand['priority'] < best['priority']):
                best = cand
    if best:
        del best['tier']
        del best['priority']
    return best