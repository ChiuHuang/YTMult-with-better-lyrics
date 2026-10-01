# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
import functools
import json
import os
import re
import sys
import requests
import hashlib
import time as time_module
import subprocess
import threading
import concurrent.futures
from collections import deque
from datetime import datetime
from urllib.parse import quote
import secrets as _secrets
import uuid
import traceback
import atexit
import logging
from .nodes import relay_http_request
from .parsers_lrc import parse_lrc
from .parsers_ttml import parse_ttml_basic

# ============================================================
# Cubey API (Turnstile bypassed)
#
# Events mapped to the same provider set the Better Lyrics extension
# understands, so a JWT request covers them all in one pass:
#   musixmatch  -> wordByWord (LRC) or synced (LRC)
#   qq          -> QRC (true word-by-word)
#   kugou       -> LRC
#   netease     -> LRC
#   golyrics    -> bLyrics TTML (word-synced or line-synced)
#   binimum     -> BiniLyrics TTML (timingType: syllable | line)
# Word-by-word / syllable timing always outranks line sync -- that is the
# same fidelity ordering the client-side renderer and _lyrics_score use.
# ============================================================

# Rank used ONLY to break ties within the same fidelity tier (which
# stream source to keep when both are line-synced). Kept out of race.py
# to avoid a circular import; race.py's _PROVIDER_RANK powers scoring.
_CUBEY_TIE_RANK = {'Musixmatch': 40, 'bLyrics': 38, 'BiniLyrics': 37,
                   'KuGou': 35, 'NetEase': 33}


def _parse_ttml_payload(payload, duration_sec=0):
    """Accept raw TTML text or a JSON string/envelope containing it."""
    if isinstance(payload, dict):
        payload = payload.get('ttml', payload)
    if isinstance(payload, str):
        stripped = payload.strip()
        if stripped.startswith('{'):
            try:
                inner = json.loads(stripped)
                if isinstance(inner, dict) and inner.get('ttml'):
                    payload = inner['ttml']
            except Exception:
                pass
    ttml_text = payload if isinstance(payload, str) else ''
    if not ttml_text:
        return None
    return parse_ttml_basic(ttml_text, duration_sec)


def _parse_kugou_payload(text):
    """KuGou's results.lyrics is a JSON string wrapping an LRC blob."""
    try:
        k_json = json.loads(text)
        if k_json.get("lyrics"):
            return k_json["lyrics"]
    except Exception:
        pass
    return None


def _collect_cubey_event(event_data, duration_sec=0):
    """Return [(inner_provider, raw_result)] for EVERY inner provider present
    in one Cubey SSE event (no best-only merging). Inner names match the
    source labels the device menu shows: Musixmatch, QQ, bLyrics,
    BiniLyrics, NetEase, KuGou."""
    from .parsers_qrc import parse_qrc_structured
    provider = event_data.get("provider")
    results = event_data.get("results")
    if not results:
        return []
    out = []
    if provider == "musixmatch":
        if results.get("wordByWord"):
            out.append(("Musixmatch", {"synced": results["wordByWord"], "source": "Musixmatch", "wordSynced": True}))
        if results.get("synced"):
            out.append(("Musixmatch", {"synced": results["synced"], "source": "Musixmatch", "wordSynced": False}))
    elif provider == "qq" and results.get("lyrics"):
        qrc_entries = parse_qrc_structured(results["lyrics"])
        if qrc_entries:
            out.append(("QQ", {"parsed": qrc_entries, "source": "QQ", "wordSynced": True}))
    elif provider == "golyrics" and results.get("lyrics"):
        parsed = _parse_ttml_payload(results["lyrics"], duration_sec)
        if parsed:
            wbw = any(l.get('wordSynced') for l in parsed)
            out.append(("bLyrics", {"parsed": parsed, "source": "bLyrics", "wordSynced": wbw}))
    elif provider == "binimum" and results.get("lyrics"):
        parsed = _parse_ttml_payload(results["lyrics"], duration_sec)
        if parsed:
            wbw = any(l.get('wordSynced') for l in parsed)
            out.append(("BiniLyrics", {"parsed": parsed, "source": "BiniLyrics", "wordSynced": wbw}))
    elif provider == "netease" and results.get("synced"):
        out.append(("NetEase", {"synced": results["synced"], "source": "NetEase", "wordSynced": False}))
    elif provider == "kugou" and results.get("lyrics"):
        lrc = _parse_kugou_payload(results["lyrics"])
        if lrc:
            out.append(("KuGou", {"synced": lrc, "source": "KuGou", "wordSynced": False}))
    return out


def _apply_cubey_event(event_data, state):
    """Handle one parsed SSE event from Cubey, updating `state` in place.
    Returns a result dict to short-circuit immediately (perfect match), or
    None to keep scanning for a better one."""
    provider = event_data.get("provider")
    results = event_data.get("results")
    if not results:
        return None

    def accept(candidate, wbw):
        """Word-level timing always wins; within one tier keep the
        higher-ranked provider, else keep the first-found result."""
        if wbw and not state['best_is_wbw']:
            state['best_lyrics'] = candidate
            state['best_is_wbw'] = True
            return True
        if wbw == state['best_is_wbw']:
            cur = state['best_lyrics']
            if cur is None:
                state['best_lyrics'] = candidate
                return True
            if not wbw:
                cur_rank = _CUBEY_TIE_RANK.get(cur.get('source', ''), 0)
                new_rank = _CUBEY_TIE_RANK.get(candidate.get('source', ''), 0)
                if new_rank > cur_rank:
                    state['best_lyrics'] = candidate
            return True
        return False

    def parse_ttml_payload(payload):
        """Accept raw TTML text or a JSON string/envelope containing it."""
        if isinstance(payload, dict):
            payload = payload.get('ttml', payload)
        if isinstance(payload, str):
            stripped = payload.strip()
            if stripped.startswith('{'):
                try:
                    inner = json.loads(stripped)
                    if isinstance(inner, dict) and inner.get('ttml'):
                        payload = inner['ttml']
                except Exception:
                    pass
        ttml_text = payload if isinstance(payload, str) else ''
        if not ttml_text:
            return None
        return parse_ttml_basic(ttml_text, state.get('duration', 0))

    if provider == "musixmatch":
        if results.get("wordByWord"):
            return {"synced": results["wordByWord"], "source": "Musixmatch", "wordSynced": True}
        if results.get("synced"):
            accept({"synced": results["synced"], "source": "Musixmatch", "wordSynced": False}, False)
    elif provider == "qq" and results.get("lyrics"):
        # QRC carries true word-by-word timing: outranks any
        # line-sync best collected so far (e.g. Musixmatch LRC).
        # Structured path keeps real word/line durations (no LRC round-trip).
        from .parsers_qrc import parse_qrc_structured
        qrc_entries = parse_qrc_structured(results["lyrics"])
        if qrc_entries:
            print(f"  [OK] Cubey: QQ word-sync lyrics found!")
            accept({"parsed": qrc_entries, "source": "QQ", "wordSynced": True}, True)
    elif provider == "golyrics" and results.get("lyrics"):
        # bLyrics TTML: word-synced spans are the syllable-rich source
        parsed = parse_ttml_payload(results["lyrics"])
        if parsed:
            wbw = any(l.get('wordSynced') for l in parsed)
            print(f"  [OK] Cubey: bLyrics TTML found (wordSynced={wbw})")
            accept({"parsed": parsed, "source": "bLyrics", "wordSynced": wbw}, wbw)
    elif provider == "binimum" and results.get("lyrics"):
        # BiniLyrics TTML: timingType tells us whether parts are syllables
        parsed = parse_ttml_payload(results["lyrics"])
        if parsed:
            wbw = any(l.get('wordSynced') for l in parsed)
            print(f"  [OK] Cubey: BiniLyrics TTML found (wordSynced={wbw} timingType={results.get('timingType')})")
            accept({"parsed": parsed, "source": "BiniLyrics", "wordSynced": wbw}, wbw)
    elif provider == "netease" and results.get("synced"):
        accept({"synced": results["synced"], "source": "NetEase", "wordSynced": False}, False)
    elif provider == "kugou" and results.get("lyrics"):
        try:
            k_json = json.loads(results["lyrics"])
            if k_json.get("lyrics"):
                accept({"synced": k_json["lyrics"], "source": "KuGou", "wordSynced": False}, False)
        except Exception:
            pass
    return None


def _parse_cubey_lines(line_iter, duration_sec=0):
    state = {'best_lyrics': None, 'best_is_wbw': False, 'duration': duration_sec}
    for line in line_iter:
        if not line:
            continue
        if isinstance(line, bytes):
            line = line.decode('utf-8', errors='ignore')
        line = line.strip()
        if not line.startswith("data:"):
            continue
        data_str = line[5:].strip()
        if data_str == "[DONE]":
            break
        try:
            event_data = json.loads(data_str)
        except Exception:
            continue
        early = _apply_cubey_event(event_data, state)
        if early:
            return early
    return state['best_lyrics']


def _raw_is_wbw(raw):
    """True when a raw Cubey result carries real word/syllable timing."""
    if raw.get('parsed'):
        try:
            return any(l.get('wordSynced') for l in raw['parsed'])
        except Exception:
            return False
    return bool(raw.get('wordSynced'))


def _collect_cubey_lines(line_iter, duration_sec=0):
    """Buffer a Cubey SSE stream into {inner_provider: raw_result}, keeping
    the best hit per inner provider (word-timed beats line-synced, first hit
    wins ties). Unlike _parse_cubey_lines nothing is merged or discarded, so
    the probe can list Musixmatch / QQ / bLyrics / BiniLyrics / NetEase /
    KuGou as separate providers instead of one opaque 'Cubey' entry."""
    best = {}  # inner -> (is_wbw, raw)
    for line in line_iter:
        if not line:
            continue
        if isinstance(line, bytes):
            line = line.decode('utf-8', errors='ignore')
        line = line.strip()
        if not line.startswith("data:"):
            continue
        data_str = line[5:].strip()
        if data_str == "[DONE]":
            break
        try:
            event_data = json.loads(data_str)
        except Exception:
            continue
        for inner, raw in _collect_cubey_event(event_data, duration_sec):
            wbw = _raw_is_wbw(raw)
            cur = best.get(inner)
            if cur is None or (wbw and not cur[0]):
                best[inner] = (wbw, raw)
    return {inner: raw for inner, (_, raw) in best.items()}


def _note_cubey_auth_failure(jwt_token, status):
    """Deprecated shim, kept so the name still resolves: the counting and the
    strike now happen together in _account(), which every outcome site calls.
    A 429/5xx/timeout still counts as a request but is NOT death."""
    if status not in (401, 403):
        return
    _account(jwt_token, status)


def _account(jwt_token, status_or_outcome, exception=False):
    """The ONE bookkeeping call for a Cubey request (jwt_pool.note_request).

    Reached from every outcome below, including the failures, because the number
    that matters is "requests this token served", not "requests that worked" -- a
    token that burned a hundred requests on 429s has a very different value from
    one that answered a hundred.

    An 'auth' outcome is ALSO the strike, because this is the only place the pool
    hears that a credential was rejected. 429 / 5xx / a timeout are counted as
    requests and are never death: the pool only evicts on a proven 401/403."""
    outcome = 'other' if exception else _outcome_for(status_or_outcome)
    try:
        from .jwt_pool import note_request
        note_request(jwt_token, outcome,
                     reason=f'cubey {status_or_outcome}' if not exception else 'exception')
    except Exception:
        pass  # never let bookkeeping break a fetch


def _outcome_for(status):
    """Map an HTTP status onto a request outcome. 200 worked; 401/403 is an auth
    rejection (the only kind that can kill a token); everything else -- 429, 5xx,
    a redirect -- is an unknown verdict."""
    if status == 200:
        return 'ok'
    if status in (401, 403):
        return 'auth'
    return 'other'


# How long to wait before the SECOND Cubey request for a song whose winner is
# not word-by-word. Zero would re-send the identical request in the same
# millisecond, which is how one rate-limit 429 or one 15s stream timeout
# becomes two of each instead of one. Under a second: invisible next to the
# multi-second full fetch it rides on.
SECOND_PASS_DELAY = 0.8


def second_pass_delay():
    """SECOND_PASS_DELAY, or the operator's `fetch.wbw_retry_delay_s`.

    A function, not a constant read at import: a setting edited in the dashboard
    has to take effect without a server restart, and reading the module constant
    at call sites would freeze whatever it was when the process started.
    Fails back to the constant -- a settings read must not stop a fetch."""
    try:
        from .app_settings import number
        return number('fetch.wbw_retry_delay_s', SECOND_PASS_DELAY, 0, 30)
    except Exception:
        return SECOND_PASS_DELAY


def second_pass_token(used):
    """A DIFFERENT credential for the second Cubey pass when one exists.

    A device JWT arrives as a plain argument and never touches jwt_pool, so
    nothing demotes it after a 401 -- re-sending the same credential is not a
    retry. Prefer another pool token; fall back to the one that was used,
    because a token with no alternative is still worth the second request.
    Never raises: this runs on the fetch path."""
    fresh = None
    try:
        from .jwt_pool import pick_jwt
        fresh = pick_jwt()
    except Exception:
        pass
    if fresh and fresh != used:
        return fresh
    return used or fresh


def cubey_candidate(raw, duration_sec=0, inner=None):
    """One Cubey raw result -> the pipeline's {lyrics, source, synced} shape,
    or None when that inner source carried nothing usable. Shared by the probe,
    the race and the pipeline so all three agree on what a raw result means
    (parsed TTML/QRC entries, else an LRC blob). Sanitizes in place, same as
    every other consumer."""
    if not isinstance(raw, dict):
        return None
    if raw.get('parsed'):
        parsed = raw['parsed']
    elif raw.get('synced'):
        parsed = parse_lrc(raw['synced'], duration_sec)
    else:
        return None
    if not parsed:
        return None
    from .cache import sanitize_lyrics_parts
    sanitize_lyrics_parts(parsed)
    return {'lyrics': parsed, 'source': raw.get('source') or inner,
            'synced': True}


def fetch_cubey_all(jwt_token, video_id, title, artist, duration_sec, via_node=None):
    """Same request as fetch_cubey, but returns every inner provider's hit as
    {inner_name: raw_result} instead of the single best merge. Returns {} on
    any failure. Raw values are the same shapes fetch_cubey yields ({synced}
    LRC text or {parsed} entries with source/wordSynced flags)."""
    url = "https://lyrics.api.dacubeking.com/v2/lyrics"
    data = {
        "videoId": video_id,
        "song": title,
        "artist": artist,
        "duration": str(int(duration_sec)),
        "alwaysFetchMetadata": "false",
        "token": jwt_token
    }

    if via_node:
        relayed = relay_http_request(via_node, method="POST", url=url, data=data, timeout=15)
        if relayed is not None:
            status, text = relayed
            if status == 200:
                _account(jwt_token, 200)
                return _collect_cubey_lines(text.splitlines(), duration_sec)
            _account(jwt_token, status)
            print(f"  [FAIL] Cubey via node {via_node}: HTTP {status}")
            return {}
        print(f"  [WARN] Node {via_node} relay failed, falling back to a direct request")

    try:
        response = requests.post(url, data=data, stream=True, timeout=15)
        if response.status_code != 200:
            _account(jwt_token, response.status_code)
            print(f"  [FAIL] Cubey API error: {response.status_code}")
            return {}
        _account(jwt_token, 200)
        return _collect_cubey_lines(response.iter_lines(), duration_sec)
    except Exception as e:
        _account(jwt_token, None, exception=True)
        print(f"  [FAIL] Cubey API request failed: {e}")
        return {}


def fetch_cubey(jwt_token, video_id, title, artist, duration_sec, via_node=None):
    url = "https://lyrics.api.dacubeking.com/v2/lyrics"
    data = {
        "videoId": video_id,
        "song": title,
        "artist": artist,
        "duration": str(int(duration_sec)),
        "alwaysFetchMetadata": "false",
        "token": jwt_token
    }

    if via_node:
        # Route through a connected node's outbound IP for diversity against
        # provider rate limits. Buffers the whole response instead of
        # streaming it (unavoidable when relaying a full HTTP response back
        # over a JSON WebSocket message), so this trades a little of the
        # streaming early-exit speed for that IP diversity -- acceptable
        # since low latency here was explicitly not a priority.
        relayed = relay_http_request(via_node, method="POST", url=url, data=data, timeout=15)
        if relayed is not None:
            status, text = relayed
            if status == 200:
                _account(jwt_token, 200)
                return _parse_cubey_lines(text.splitlines(), duration_sec)
            _account(jwt_token, status)
            print(f"  [FAIL] Cubey via node {via_node}: HTTP {status}")
            return None
        print(f"  [WARN] Node {via_node} relay failed, falling back to a direct request")

    try:
        response = requests.post(url, data=data, stream=True, timeout=15)
        if response.status_code != 200:
            _account(jwt_token, response.status_code)
            print(f"  [FAIL] Cubey API error: {response.status_code}")
            return None
        _account(jwt_token, 200)
        return _parse_cubey_lines(response.iter_lines(), duration_sec)
    except Exception as e:
        _account(jwt_token, None, exception=True)
        print(f"  [FAIL] Cubey API request failed: {e}")
        return None


