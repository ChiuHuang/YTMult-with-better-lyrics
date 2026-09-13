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
    """Try all providers in priority order, return best result."""

    title = song_info['title']
    artist = song_info['artist']
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    queries = get_search_queries(title, artist, song_info.get('ja_title', ''), song_info.get('ja_artist', ''))

    result = None

    # Priority 0: Cubey API (if we have JWT)
    if jwt_token:
        print(f"  [0/4] Trying Cubey API (with JWT)...")
        for q in queries:
            q_title = q['title']
            q_artist = q['artist']
            cubey = fetch_cubey(jwt_token, video_id, q_title, q_artist, duration, via_node=pick_node())
            if cubey and cubey.get('synced'):
                print(f"  [OK] Cubey: synced LRC lyrics found from {cubey.get('source')}! (query: {q_title} - {q_artist})")
                parsed = parse_lrc(cubey['synced'], duration)
                result = {'lyrics': parsed, 'source': cubey.get('source'), 'synced': True}
                # Skip other providers - we already have the best
                result['song'] = title
                result['artist'] = artist
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

    # Priority 1: LRCLIB (best for synced lyrics)
    print(f"  [1/3] Trying LRCLIB...")
    for q in queries:
        q_title = q['title']
        q_artist = q['artist']
        lrc = fetch_lrclib(q_title, q_artist, album, duration)
        if lrc:
            if lrc.get('instrumental'):
                result = {
                    'lyrics': [{'time': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'duration': 0}],
                    'source': 'LRCLib', 'synced': False
                }
                break
            elif lrc.get('synced'):
                print(f"  [OK] LRCLIB: synced lyrics found! (query: {q_title} - {q_artist})")
                parsed = parse_lrc(lrc['synced'], duration)
                result = {'lyrics': parsed, 'source': 'LRCLib', 'synced': True}
                break
            elif lrc.get('plain') and not result:
                print(f"  [WARN]️ LRCLIB: plain lyrics only (query: {q_title} - {q_artist})")
                parsed = parse_plain(lrc['plain'])
                result = {'lyrics': parsed, 'source': 'LRCLib', 'synced': False}

    # Priority 2: Unison (community)
    if not result or not result.get('synced'):
        print(f"  [2/3] Trying Unison...")
        for q in queries:
            uni = fetch_unison(video_id, q['title'], q['artist'], duration)
            if uni:
                if uni.get('parsed'):
                    print(f"  [OK] Unison: TTML lyrics found! (query: {q['title']})")
                    if not result or not result.get('synced'):
                        result = {'lyrics': uni['parsed'], 'source': 'Unison', 'synced': True}
                        break
                elif uni.get('synced'):
                    print(f"  [OK] Unison: synced LRC lyrics found! (query: {q['title']})")
                    parsed = parse_lrc(uni['synced'], duration)
                    if not result or not result.get('synced'):
                        result = {'lyrics': parsed, 'source': 'Unison', 'synced': True}
                        break
                elif uni.get('plain') and not result:
                    print(f"  [WARN]️ Unison: plain lyrics only (query: {q['title']})")
                    parsed = parse_plain(uni['plain'])
                    result = {'lyrics': parsed, 'source': 'Unison', 'synced': False}

    # Priority 3: YouTube Music lyrics
    if not result:
        print(f"  [3/3] Trying YouTube Music lyrics...")
        yt = fetch_yt_lyrics(video_id)
        if yt and yt.get('plain'):
            print(f"  [OK] YouTube: plain lyrics found!")
            parsed = parse_plain(yt['plain'])
            result = {'lyrics': parsed, 'source': yt.get('source', 'YouTube Music'), 'synced': False}

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


