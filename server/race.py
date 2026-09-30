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
from flask import Flask, request, jsonify, render_template, session, redirect, url_for, Response, stream_with_context
from .metadata import get_search_queries
from .providers_lrclib import fetch_lrclib
from .providers_yt import fetch_yt_lyrics
from .providers_cubey import (fetch_cubey, fetch_cubey_all, cubey_candidate,
                               second_pass_token, SECOND_PASS_DELAY)
from .providers_unison import fetch_unison
from .providers_braccato import fetch_direct_best
from .parsers_lrc import parse_lrc, parse_plain
from .translate import cohere_translate, google_translate_fast
from .cache import sanitize_lyrics_parts
from .nodes import pick_node
from .jwt_pool import pick_jwt

# ============================================================
# Parallel provider race + SSE streaming
# Same providers as fetch_all_lyrics, but raced concurrently so the
# client gets the first hit fast, then upgrades when a better result
# (synced beats plain) arrives. Raw synced lines are pushed BEFORE
# translation runs, so Cohere latency never blocks first paint.
# ============================================================

_PROVIDER_RANK = {
    'Musixmatch': 40,
    'bLyrics': 38,
    'BiniLyrics': 37,
    'AMLL': 37,
    'QQ': 36,
    'KuGou': 35,
    'NetEase': 33,
    'LRCLib': 30,
    'Unison': 20,
    'YouTube Music': 10,
}

_STAGE_RANK = {'raw': 0, 'machine': 1, 'final': 2, 'cached': 3}


def _wbw_line_count(res):
    """Count lines carrying real provider word timestamps (not interpolated)."""
    n = 0
    for l in (res.get('lyrics') or []):
        parts = l.get('parts') or []
        if l.get('wordSynced') and len(parts) > 1:
            if len({p.get('startTimeMs') for p in parts}) > 1:
                n += 1
    return n


def _lyrics_score(res):
    """Higher is better. Word-by-word sync beats everything; if both sides
    have it (or neither does), provider weight decides, then coverage."""
    if not res or not res.get('lyrics'):
        return -1
    wbw = _wbw_line_count(res)
    if wbw > 0:
        base = 2000
    elif res.get('synced'):
        base = 100
    else:
        base = 0
    prov = _PROVIDER_RANK.get(res.get('source', ''), 0)
    return base + prov + min(len(res.get('lyrics', [])), 50) * 0.01 + min(wbw, 100) * 0.1


def _maybe_cubey_second_pass(merged, queries, video_id, duration, used_jwt,
                             via_node, req_id='?'):
    """The gate every Cubey caller shares: pass 1 landed but without word
    timing, so spend one more request before settling for line-sync. Returns
    `merged` untouched when the winner is already word-by-word, when the switch
    is off, or when the second pass finds nothing better."""
    if _wbw_line_count(merged) > 0:
        return merged
    try:
        from .app_settings import flag
        if not flag('fetch.wbw_retry_cubey'):
            return merged
    except Exception:
        pass  # fail open: the pass can only upgrade the tier
    better = cubey_second_pass(queries, video_id, duration, used_jwt,
                               via_node, req_id)
    if better and _lyrics_score(better) > _lyrics_score(merged):
        return better
    return merged


def cubey_second_pass(queries, video_id, duration, used_jwt, via_node=None,
                      req_id='?'):
    """Ask Cubey once more, for its inner providers SEPARATELY.

    fetch_cubey takes ONE merged answer per query and _parse_cubey_lines keeps
    a single best, so a word-timed inner source (Musixmatch wordByWord, QQ QRC,
    bLyrics/BiniLyrics TTML) can lose that merge and leave the song on
    line-sync forever. fetch_cubey_all returns the inners separately, which is
    the only way to see what the merge discarded. Returns the best candidate
    by _lyrics_score, or None -- the caller keeps whatever pass 1 found.

    Costs one extra request per song whose winner is not word-by-word, which is
    what the fetch.wbw_retry_cubey switch turns off."""
    token = second_pass_token(used_jwt)
    if not token:
        print(f"  [REQ {req_id}] [Race] Cubey second pass skipped (no JWT)")
        return None
    # Never in the same millisecond as pass 1: an identical request fired
    # immediately is how one 429 or one stream timeout becomes two.
    time_module.sleep(SECOND_PASS_DELAY)
    best = None
    for q in queries:
        try:
            got = fetch_cubey_all(token, video_id, q['title'], q['artist'],
                                  duration, via_node=via_node)
        except Exception as e:
            print(f"  [REQ {req_id}] [Race] Cubey second pass error: {e}")
            continue
        for inner, raw in (got or {}).items():
            cand = cubey_candidate(raw, duration, inner)
            if cand and (best is None or _lyrics_score(cand) > _lyrics_score(best)):
                best = cand
    if best:
        print(f"  [REQ {req_id}] [Race] Cubey second pass best: {best.get('source')} "
              f"score={_lyrics_score(best):.2f}")
    else:
        print(f"  [REQ {req_id}] [Race] Cubey second pass found nothing")
    return best


def _race_cubey(queries, video_id, duration, jwt_token, req_id='?'):
    t0 = time_module.time()
    if not jwt_token:
        jwt_token = pick_jwt()
    if not jwt_token:
        print(f"  [REQ {req_id}] [Race] Cubey skipped (no JWT in pool)")
        return None
    via_node = pick_node()
    try:
        for q in queries:
            try:
                cubey = fetch_cubey(jwt_token, video_id, q['title'], q['artist'], duration, via_node=via_node)
            except Exception as e:
                print(f"  [REQ {req_id}] [Race] Cubey query error: {e}")
                continue
            if cubey:
                if cubey.get('parsed'):
                    parsed = cubey['parsed']
                    sanitize_lyrics_parts(parsed)
                    print(f"  [REQ {req_id}] [Race] Cubey TTML hit from {cubey.get('source')} wbw={cubey.get('wordSynced')} ({(time_module.time()-t0)*1000:.0f}ms)")
                    return _maybe_cubey_second_pass(
                        {'lyrics': parsed, 'source': cubey.get('source'), 'synced': True},
                        queries, video_id, duration, jwt_token, via_node, req_id)
                if cubey.get('synced'):
                    parsed = parse_lrc(cubey['synced'], duration)
                    sanitize_lyrics_parts(parsed)
                    print(f"  [REQ {req_id}] [Race] Cubey hit from {cubey.get('source')} ({(time_module.time()-t0)*1000:.0f}ms)")
                    return _maybe_cubey_second_pass(
                        {'lyrics': parsed, 'source': cubey.get('source'), 'synced': True},
                        queries, video_id, duration, jwt_token, via_node, req_id)
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] Cubey worker error: {e}")
    print(f"  [REQ {req_id}] [Race] Cubey miss ({(time_module.time()-t0)*1000:.0f}ms)")
    return None


def _race_lrclib(queries, album, duration, req_id='?'):
    t0 = time_module.time()
    plain_fallback = None
    node = pick_node()
    try:
        for q in queries:
            try:
                lrc = fetch_lrclib(q['title'], q['artist'], album, duration, via_node=node)
            except Exception as e:
                print(f"  [REQ {req_id}] [Race] LRCLIB query error: {e}")
                continue
            if not lrc:
                continue
            if lrc.get('instrumental'):
                parsed = [{'time': 0, 'startTimeMs': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'durationMs': 0, 'duration': 0}]
                return {'lyrics': parsed, 'source': 'LRCLib', 'synced': False}
            if lrc.get('synced'):
                parsed = parse_lrc(lrc['synced'], duration)
                sanitize_lyrics_parts(parsed)
                print(f"  [REQ {req_id}] [Race] LRCLIB synced hit ({(time_module.time()-t0)*1000:.0f}ms)")
                return {'lyrics': parsed, 'source': 'LRCLib', 'synced': True}
            if lrc.get('plain') and plain_fallback is None:
                parsed = parse_plain(lrc['plain'])
                sanitize_lyrics_parts(parsed)
                plain_fallback = {'lyrics': parsed, 'source': 'LRCLib', 'synced': False}
        if plain_fallback:
            print(f"  [REQ {req_id}] [Race] LRCLIB plain fallback ({(time_module.time()-t0)*1000:.0f}ms)")
        else:
            print(f"  [REQ {req_id}] [Race] LRCLIB miss ({(time_module.time()-t0)*1000:.0f}ms)")
        return plain_fallback
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] LRCLIB worker error: {e}")
        return plain_fallback


def _race_unison(queries, video_id, duration, req_id='?'):
    t0 = time_module.time()
    plain_fallback = None
    node = pick_node()
    try:
        for q in queries:
            try:
                uni = fetch_unison(video_id, q['title'], q['artist'], duration, via_node=node)
            except Exception as e:
                print(f"  [REQ {req_id}] [Race] Unison query error: {e}")
                continue
            if not uni:
                continue
            if uni.get('parsed'):
                sanitize_lyrics_parts(uni['parsed'])
                print(f"  [REQ {req_id}] [Race] Unison TTML hit ({(time_module.time()-t0)*1000:.0f}ms)")
                return {'lyrics': uni['parsed'], 'source': 'Unison', 'synced': True}
            if uni.get('synced'):
                parsed = parse_lrc(uni['synced'], duration)
                sanitize_lyrics_parts(parsed)
                print(f"  [REQ {req_id}] [Race] Unison synced hit ({(time_module.time()-t0)*1000:.0f}ms)")
                return {'lyrics': parsed, 'source': 'Unison', 'synced': True}
            if uni.get('plain') and plain_fallback is None:
                parsed = parse_plain(uni['plain'])
                sanitize_lyrics_parts(parsed)
                plain_fallback = {'lyrics': parsed, 'source': 'Unison', 'synced': False}
        if plain_fallback:
            print(f"  [REQ {req_id}] [Race] Unison plain fallback ({(time_module.time()-t0)*1000:.0f}ms)")
        else:
            print(f"  [REQ {req_id}] [Race] Unison miss ({(time_module.time()-t0)*1000:.0f}ms)")
        return plain_fallback
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] Unison worker error: {e}")
        return plain_fallback


def _race_yt(video_id, req_id='?'):
    t0 = time_module.time()
    try:
        yt = fetch_yt_lyrics(video_id)
        if yt and yt.get('plain'):
            parsed = parse_plain(yt['plain'])
            sanitize_lyrics_parts(parsed)
            print(f"  [REQ {req_id}] [Race] YouTube plain hit ({(time_module.time()-t0)*1000:.0f}ms)")
            return {'lyrics': parsed, 'source': yt.get('source', 'YouTube Music'), 'synced': False}
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] YouTube worker error: {e}")
    print(f"  [REQ {req_id}] [Race] YouTube miss ({(time_module.time()-t0)*1000:.0f}ms)")
    return None


def _race_boidu(queries, album, duration, req_id='?'):
    """bLyrics TTML + Portato QRC + Legato LRC direct (no JWT)."""
    t0 = time_module.time()
    try:
        best = fetch_direct_best(queries, album, duration, sources=('ttml', 'qq', 'kugou'))
        if best:
            sanitize_lyrics_parts(best['lyrics'])
            print(f"  [REQ {req_id}] [Race] boidu hit from {best.get('source')} wbw={best.get('wordSynced')} ({(time_module.time()-t0)*1000:.0f}ms)")
            return best
        print(f"  [REQ {req_id}] [Race] boidu miss ({(time_module.time()-t0)*1000:.0f}ms)")
        return None
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] boidu worker error: {e}")
        return None


def _race_binimum(queries, album, duration, req_id='?'):
    """BiniLyrics TTML direct (no JWT)."""
    t0 = time_module.time()
    try:
        best = fetch_direct_best(queries, album, duration, sources=('binimum',))
        if best:
            sanitize_lyrics_parts(best['lyrics'])
            print(f"  [REQ {req_id}] [Race] Binimum hit wbw={best.get('wordSynced')} ({(time_module.time()-t0)*1000:.0f}ms)")
            return best
        print(f"  [REQ {req_id}] [Race] Binimum miss ({(time_module.time()-t0)*1000:.0f}ms)")
        return None
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] Binimum worker error: {e}")
        return None


def _race_amll(queries, duration, req_id='?'):
    """AMLL word-synced TTML direct (no JWT)."""
    t0 = time_module.time()
    try:
        from .providers_amll import fetch_amll
        for q in queries:
            try:
                amll = fetch_amll(q['title'], q['artist'], duration)
            except Exception as e:
                print(f"  [REQ {req_id}] [Race] AMLL query error: {e}")
                continue
            if amll and amll.get('parsed'):
                sanitize_lyrics_parts(amll['parsed'])
                print(f"  [REQ {req_id}] [Race] AMLL TTML hit ({(time_module.time()-t0)*1000:.0f}ms)")
                return {'lyrics': amll['parsed'], 'source': 'AMLL', 'synced': True}
        print(f"  [REQ {req_id}] [Race] AMLL miss ({(time_module.time()-t0)*1000:.0f}ms)")
        return None
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] AMLL worker error: {e}")
        return None


def _sse_event(name, payload):
    return f"event: {name}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"


