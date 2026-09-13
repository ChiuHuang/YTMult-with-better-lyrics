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
from .providers_cubey import fetch_cubey
from .providers_unison import fetch_unison
from .providers_braccato import fetch_direct_best
from .parsers_lrc import parse_lrc, parse_plain
from .translate import cohere_translate, google_translate_fast
from .cache import sanitize_lyrics_parts

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


def _race_cubey(queries, video_id, duration, jwt_token, req_id='?'):
    t0 = time_module.time()
    try:
        for q in queries:
            try:
                cubey = fetch_cubey(jwt_token, video_id, q['title'], q['artist'], duration)
            except Exception as e:
                print(f"  [REQ {req_id}] [Race] Cubey query error: {e}")
                continue
            if cubey:
                if cubey.get('parsed'):
                    parsed = cubey['parsed']
                    sanitize_lyrics_parts(parsed)
                    print(f"  [REQ {req_id}] [Race] Cubey TTML hit from {cubey.get('source')} wbw={cubey.get('wordSynced')} ({(time_module.time()-t0)*1000:.0f}ms)")
                    return {'lyrics': parsed, 'source': cubey.get('source'), 'synced': True}
                if cubey.get('synced'):
                    parsed = parse_lrc(cubey['synced'], duration)
                    sanitize_lyrics_parts(parsed)
                    print(f"  [REQ {req_id}] [Race] Cubey hit from {cubey.get('source')} ({(time_module.time()-t0)*1000:.0f}ms)")
                    return {'lyrics': parsed, 'source': cubey.get('source'), 'synced': True}
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] Cubey worker error: {e}")
    print(f"  [REQ {req_id}] [Race] Cubey miss ({(time_module.time()-t0)*1000:.0f}ms)")
    return None


def _race_lrclib(queries, album, duration, req_id='?'):
    t0 = time_module.time()
    plain_fallback = None
    try:
        for q in queries:
            try:
                lrc = fetch_lrclib(q['title'], q['artist'], album, duration)
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
    try:
        for q in queries:
            try:
                uni = fetch_unison(video_id, q['title'], q['artist'], duration)
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


def _sse_event(name, payload):
    return f"event: {name}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"


