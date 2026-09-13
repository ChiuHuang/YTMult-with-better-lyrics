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
from .metadata import get_search_queries
from .providers_lrclib import fetch_lrclib
from .providers_yt import fetch_yt_lyrics, get_song_info
from .providers_cubey import fetch_cubey
from .providers_unison import fetch_unison
from .providers_braccato import fetch_direct_best
from .parsers_lrc import parse_lrc, parse_plain
from .translate import cohere_translate, google_translate_fast
from .cache import is_not_found_result
from .nodes import pick_node

# ============================================================
# Main Lyrics Pipeline
# ============================================================

# Server-side in-flight dedup
_in_flight = {}  # dedup_key -> threading.Event
_in_flight_lock = threading.Lock()  # protects atomic check-and-register
import threading

def fetch_fast_lyrics(video_id, song_info, translate_to='zh-TW'):
    """Fast path: LRCLIB only + Google translate. Returns in ~1-2s."""
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    result = None

    queries = get_search_queries(song_info['title'], song_info['artist'], song_info.get('ja_title', ''), song_info.get('ja_artist', ''))
    for q in queries:
        q_title = q['title']
        q_artist = q['artist']
        lrc = fetch_lrclib(q_title, q_artist, album, duration)
        if lrc:
            if lrc.get('instrumental'):
                result = {'lyrics': [{'time': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'duration': 0}], 'source': 'LRCLib', 'synced': False}
                break
            elif lrc.get('synced'):
                print(f"  [fast] [OK] LRCLIB synced! (query: {q_title} - {q_artist})")
                result = {'lyrics': parse_lrc(lrc['synced'], duration), 'source': 'LRCLib', 'synced': True}
                break
            elif lrc.get('plain') and not result:
                print(f"  [fast] [WARN]️ LRCLIB plain (query: {q_title} - {q_artist})")
                result = {'lyrics': parse_plain(lrc['plain']), 'source': 'LRCLib', 'synced': False}

    if not result:
        yt = fetch_yt_lyrics(video_id)
        if yt and yt.get('plain'):
            print(f"  [fast] [OK] YouTube plain!")
            result = {'lyrics': parse_plain(yt['plain']), 'source': 'YouTube Music', 'synced': False}

    if not result:
        return None

    result['song'] = song_info['title']
    result['artist'] = song_info['artist']

    if translate_to and result.get('lyrics'):
        texts = [l['text'] for l in result['lyrics'] if l.get('text')]
        translations = google_translate_fast(texts, translate_to)
        for i, lyric in enumerate(result['lyrics']):
            if i < len(translations) and translations[i]:
                lyric['translated'] = translations[i]

    if result and result.get('lyrics'):
        sanitize_lyrics_parts(result['lyrics'])

    return result

def fetch_all_lyrics(video_id, song_info, translate_to=None, jwt_token=None):
    """Try all providers and keep the single best result, ranked by the same
    word-by-word-first score the stream race uses (_lyrics_score), so the
    sequential endpoint and the SSE endpoint agree on what 'best' means.
    A plain hit never outranks a synced one, and a syllable/word-timed hit
    outranks everything else."""

    title = song_info['title']
    artist = song_info['artist']
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    queries = get_search_queries(title, artist, song_info.get('ja_title', ''), song_info.get('ja_artist', ''))

    from .race import _lyrics_score

    result = None  # best across providers, decided by score

    def consider(candidate, label):
        nonlocal result
        if not candidate or not candidate.get('lyrics'):
            return
        sanitize_lyrics_parts(candidate['lyrics'])
        if result is None or _lyrics_score(candidate) > _lyrics_score(result):
            result = candidate
            print(f"  [rank] {label}: {candidate.get('source')} now best (score={_lyrics_score(result):.2f})")

    # Priority 0: Cubey API (if we have JWT) -- one pass covers Musixmatch
    # wordByWord/synced, QQ QRC, KuGou LRC, NetEase and the bLyrics/BiniLyrics
    # TTML events, with word-by-word always preferred inside the stream.
    if jwt_token:
        print(f"  [0/5] Trying Cubey API (with JWT)...")
        for q in queries:
            cubey = fetch_cubey(jwt_token, video_id, q['title'], q['artist'], duration, via_node=pick_node())
            if not cubey:
                continue
            if cubey.get('parsed'):
                print(f"  [OK] Cubey: {cubey.get('source')} TTML lyrics found (wordSynced={cubey.get('wordSynced')}) (query: {q['title']})")
                consider({'lyrics': cubey['parsed'], 'source': cubey.get('source'), 'synced': True}, 'Cubey TTML')
            elif cubey.get('synced'):
                print(f"  [OK] Cubey: synced LRC lyrics found from {cubey.get('source')}! (query: {q['title']})")
                consider({'lyrics': parse_lrc(cubey['synced'], duration), 'source': cubey.get('source'), 'synced': True}, 'Cubey synced')

    # Priority 1: direct braccato providers (no JWT) -- bLyrics TTML (often
    # syllable-timed), Portato QQ QRC (word-by-word), Legato KuGou LRC.
    direct = fetch_direct_best(queries, album, duration)
    if direct:
        print(f"  [OK] direct boidu/Binimum: {direct.get('source')} (wordSynced={direct.get('wordSynced')})")
        consider(direct, 'braccato direct')

    # Priority 2: LRCLIB (best general line-sync source)
    print(f"  [2/5] Trying LRCLIB...")
    for q in queries:
        lrc = fetch_lrclib(q['title'], q['artist'], album, duration)
        if not lrc:
            continue
        if lrc.get('instrumental'):
            consider({'lyrics': [{'time': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'duration': 0}], 'source': 'LRCLib', 'synced': False}, 'LRCLib instrumental')
            break
        if lrc.get('synced'):
            print(f"  [OK] LRCLIB: synced lyrics found! (query: {q['title']})")
            consider({'lyrics': parse_lrc(lrc['synced'], duration), 'source': 'LRCLib', 'synced': True}, 'LRCLib synced')
        elif lrc.get('plain'):
            print(f"  [WARN] LRCLIB: plain lyrics only (query: {q['title']})")
            consider({'lyrics': parse_plain(lrc['plain']), 'source': 'LRCLib', 'synced': False}, 'LRCLib plain')

    # Priority 3: Unison (community; TTML can carry word timing)
    print(f"  [3/5] Trying Unison...")
    for q in queries:
        uni = fetch_unison(video_id, q['title'], q['artist'], duration)
        if not uni:
            continue
        if uni.get('parsed'):
            print(f"  [OK] Unison: TTML lyrics found! (query: {q['title']})")
            consider({'lyrics': uni['parsed'], 'source': 'Unison', 'synced': True}, 'Unison TTML')
        elif uni.get('synced'):
            print(f"  [OK] Unison: synced LRC lyrics found! (query: {q['title']})")
            consider({'lyrics': parse_lrc(uni['synced'], duration), 'source': 'Unison', 'synced': True}, 'Unison synced')
        elif uni.get('plain'):
            print(f"  [WARN] Unison: plain lyrics only (query: {q['title']})")
            consider({'lyrics': parse_plain(uni['plain']), 'source': 'Unison', 'synced': False}, 'Unison plain')

    # Priority 4: YouTube Music lyrics
    print(f"  [4/5] Trying YouTube Music lyrics...")
    try:
        yt = fetch_yt_lyrics(video_id)
        if yt and yt.get('plain'):
            print(f"  [OK] YouTube: plain lyrics found!")
            consider({'lyrics': parse_plain(yt['plain']), 'source': yt.get('source', 'YouTube Music'), 'synced': False}, 'YouTube')
    except Exception as e:
        print(f"  [FAIL] YouTube error: {e}")

    # No lyrics found
    if not result:
        print(f"  [FAIL] No lyrics found from any provider")
        result = {
            'lyrics': [{'time': 0, 'text': f'No lyrics found', 'translated': f'找不到歌詞: {title}', 'duration': 0}],
            'source': 'none', 'synced': False
        }

    # Add song metadata
    result['song'] = title
    result['artist'] = artist
    if result.get('wordSynced') is None:
        result['wordSynced'] = any(l.get('wordSynced') for l in (result.get('lyrics') or []))

    # Translation
    if translate_to and result.get('lyrics'):
        print(f"  [TRANS] Translating {len(result['lyrics'])} lines with Cohere...")
        texts = [l['text'] for l in result['lyrics'] if l.get('text')]
        translations = cohere_translate(texts, translate_to)

        for i, lyric in enumerate(result['lyrics']):
            if i < len(translations):
                lyric['translated'] = translations[i]

    if result and result.get('lyrics'):
        sanitize_lyrics_parts(result['lyrics'])

    return result


