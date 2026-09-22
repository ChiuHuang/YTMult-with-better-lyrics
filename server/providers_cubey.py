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
            wbw = (results.get("timingType") == "syllable") or any(l.get('wordSynced') for l in parsed)
            print(f"  [OK] Cubey: BiniLyrics TTML found (timingType={results.get('timingType')})")
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
                return _parse_cubey_lines(text.splitlines(), duration_sec)
            print(f"  [FAIL] Cubey via node {via_node}: HTTP {status}")
            return None
        print(f"  [WARN] Node {via_node} relay failed, falling back to a direct request")

    try:
        response = requests.post(url, data=data, stream=True, timeout=15)
        if response.status_code != 200:
            print(f"  [FAIL] Cubey API error: {response.status_code}")
            return None
        return _parse_cubey_lines(response.iter_lines(), duration_sec)
    except Exception as e:
        print(f"  [FAIL] Cubey API request failed: {e}")
        return None


