# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
#
# AMLL TTML DB: word-synced TTML lyrics via the public amlldb search API.
# Mirrors beautiful-lyrics-reborn's Server/src/providers/amlldb.ts (which is
# commented out upstream, but its search + raw-lyrics endpoints are live):
#   POST https://amlldb.bikonoo.com/api/search-lyrics {query, type: "title"}
#     -> [{title, titles[], artist, artists[], file}]
#   GET https://amlldb.bikonoo.com/raw-lyrics/<file> -> TTML (word timing)
# No key, no JWT, no Spotify token needed for the title-search path.
# Every call has a short timeout and returns None on any failure so the
# caller can fall back exactly as if the provider were absent.
import requests
from .parsers_ttml import parse_ttml_basic

AMLL_SEARCH_URL = "https://amlldb.bikonoo.com/api/search-lyrics"
AMLL_RAW_URL = "https://amlldb.bikonoo.com/raw-lyrics"
_UA = "beautiful-lyrics-server/1.0"
_TIMEOUT = 10


def _norm(s):
    return (s or '').strip().lower()


def _match(result, title, artist):
    """Same matching discipline as the TS original: normalized title must
    equal-or-contain, and the artist must match bidirectionally."""
    titles = {_norm(result.get('title'))}
    titles |= {_norm(t) for t in result.get('titles') or []}
    titles.discard('')
    artists = {_norm(result.get('artist'))}
    artists |= {_norm(a) for a in result.get('artists') or []}
    artists.discard('')
    t = _norm(title)
    if not t or not titles:
        return False
    if not any(t == x or t in x for x in titles):
        return False
    if not artists:
        return True
    a = _norm(artist)
    if not a:
        return True
    return any(a in x or x in a for x in artists)


def _search(query, via_node=None):
    """POST the title search, returning the decoded list or None."""
    import json as _json
    payload = _json.dumps({'query': query, 'type': 'title'})
    if via_node:
        from .nodes import relay_http_request
        out = relay_http_request(via_node, 'POST', AMLL_SEARCH_URL,
                                 data=payload,
                                 headers={'Content-Type': 'application/json',
                                          'Accept': 'application/json'},
                                 timeout=_TIMEOUT + 5)
        if out is None:
            return None
        status, text = out
        if status != 200:
            return None
        try:
            data = _json.loads(text)
        except Exception:
            return None
        return data if isinstance(data, list) else None
    try:
        resp = requests.post(AMLL_SEARCH_URL, json={'query': query, 'type': 'title'},
                             headers={'Accept': 'application/json', 'User-Agent': _UA},
                             timeout=_TIMEOUT)
    except Exception as e:
        print(f"[AMLL] search error: {e}")
        return None
    if resp.status_code != 200:
        return None
    try:
        data = resp.json()
    except Exception:
        return None
    return data if isinstance(data, list) else None


def _fetch_ttml(file, via_node=None):
    """GET the raw TTML for a search-hit file name."""
    url = f"{AMLL_RAW_URL}/{file}"
    if via_node:
        from .nodes import relay_http_request
        out = relay_http_request(via_node, 'GET', url, timeout=_TIMEOUT + 5)
        if out is None:
            return None
        status, text = out
        return text if status == 200 else None
    try:
        resp = requests.get(url,
                            headers={'Accept': 'application/xml, text/xml, text/plain;q=0.9',
                                     'User-Agent': _UA},
                            timeout=_TIMEOUT)
    except Exception as e:
        print(f"[AMLL] ttml fetch error: {e}")
        return None
    if resp.status_code != 200:
        return None
    try:
        return resp.content.decode('utf-8', errors='replace')
    except Exception:
        return resp.text


def fetch_amll(song, artist, duration=0, via_node=None):
    """AMLL word-synced TTML (search title, match artist, parse raw TTML).
    Tries the raw title then each search query implicitly via the caller's
    query loop; returns {parsed, source, wordSynced} or None."""
    try:
        results = _search(song, via_node)
        if not results:
            return None
        for hit in results:
            if not isinstance(hit, dict) or not hit.get('file'):
                continue
            if not _match(hit, song, artist):
                continue
            ttml = _fetch_ttml(hit['file'], via_node)
            if not ttml:
                continue
            lyrics = parse_ttml_basic(ttml, duration)
            if not lyrics:
                continue
            return {'parsed': lyrics, 'source': 'AMLL',
                    'wordSynced': any(l.get('wordSynced') for l in lyrics)}
    except Exception as e:
        print(f"[AMLL] error: {e}")
        return None
    return None
