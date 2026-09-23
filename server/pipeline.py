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
from .translate import google_translate_fast
from .cache import is_not_found_result, sanitize_lyrics_parts
from .nodes import pick_node
from .jwt_pool import pick_jwt

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
    node = pick_node()
    for q in queries:
        q_title = q['title']
        q_artist = q['artist']
        lrc = fetch_lrclib(q_title, q_artist, album, duration, via_node=node)
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
    # No request JWT? Fall back to the contributed pool before giving up.
    if not jwt_token:
        jwt_token = pick_jwt()
        if jwt_token:
            print(f"  [0/5] No request JWT -- using a contributed token from the pool")
    if jwt_token:
        print(f"  [0/5] Trying Cubey API (with JWT)...")
        cubey_node = pick_node()
        for q in queries:
            cubey = fetch_cubey(jwt_token, video_id, q['title'], q['artist'], duration, via_node=cubey_node)
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
    lrclib_node = pick_node()
    for q in queries:
        lrc = fetch_lrclib(q['title'], q['artist'], album, duration, via_node=lrclib_node)
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
    unison_node = pick_node()
    for q in queries:
        uni = fetch_unison(video_id, q['title'], q['artist'], duration, via_node=unison_node)
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
    # Translation (shared helper -- the background queue uses the same one)
    if translate_to and result.get('lyrics'):
        print(f"  [TRANS] Translating {len(result['lyrics'])} lines with Cohere...")
        from .translate import translate_result_in_place
        translate_result_in_place(result, translate_to)

    if result and result.get('lyrics'):
        sanitize_lyrics_parts(result['lyrics'])

    result['wordSynced'] = any(l.get('wordSynced') for l in (result.get('lyrics') or []))

    return result


def probe_providers(video_id, song_info, jwt_token=None, only_source=None):
    """Fetch each provider independently and return one candidate per
    provider/format so the dashboard can show every finding and let the admin
    pick which one to cache (not just the default best). Each entry is
    self-contained: {'provider', 'source', 'synced', 'wordSynced', 'tier',
    'lines', 'score', 'data'} where data is the full song-shape dict
    {lyrics, source, synced, wordSynced, song, artist} ready to cache. Sorted
    best-first by the same _lyrics_score used by the race, so the winner that
    fetch_all_lyrics would pick is index 0 -- but nothing is excluded."""
    from .race import _lyrics_score
    from .providers_braccato import _DIRECT_FETCHERS, _candidate_dict

    title = song_info['title']
    artist = song_info['artist']
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    queries = get_search_queries(title, artist, song_info.get('ja_title', ''), song_info.get('ja_artist', ''))

    candidates = []

    def emit(logical_provider, label, cand):
        if not cand or not cand.get('lyrics'):
            return
        try:
            sanitize_lyrics_parts(cand['lyrics'])
            lyrics = cand['lyrics']
            synced = bool(cand.get('synced'))
            wbw = bool(cand.get('wordSynced')) or any(l.get('wordSynced') for l in lyrics)
            tier = 'wbw' if wbw else ('line' if synced else 'plain')
            score = _lyrics_score(cand)
        except Exception as e:
            print(f"  [probe] emit {logical_provider} error: {e}")
            return
        candidates.append({
            'provider': logical_provider,
            'source': cand.get('source') or label,
            'synced': synced,
            'wordSynced': wbw,
            'tier': tier,
            'lines': len(lyrics),
            'score': round(score, 3),
            'data': {
                'lyrics': lyrics, 'source': cand.get('source') or label,
                'synced': synced, 'wordSynced': wbw,
                'song': title, 'artist': artist,
            },
        })

    def wants(name):
        return only_source is None or only_source.lower() == name.lower()

    # Cubey API (needs JWT): one entry, TTML/QRC preferred over LRC.
    if wants('Cubey'):
        try:
            from .providers_cubey import fetch_cubey
            if not jwt_token:
                jwt_token = pick_jwt()
            if jwt_token:
                cubey_node = pick_node()
                best = None
                for q in queries:
                    cubey = fetch_cubey(jwt_token, video_id, q['title'], q['artist'], duration, via_node=cubey_node)
                    if not cubey:
                        continue
                    if cubey.get('parsed'):
                        cand = {'lyrics': cubey['parsed'], 'source': cubey.get('source'), 'synced': True}
                        if best is None or _lyrics_score(cand) > _lyrics_score(best):
                            best = cand
                    elif cubey.get('synced'):
                        cand = {'lyrics': parse_lrc(cubey['synced'], duration), 'source': cubey.get('source'), 'synced': True}
                        if best is None or _lyrics_score(cand) > _lyrics_score(best):
                            best = cand
                emit('Cubey', 'Cubey', best)
        except Exception as e:
            print(f"  [probe] Cubey error: {e}")

    # Direct braccato providers: keep each sub-source visible separately --
    # this is exactly the "check each provider and choose" case (bLyrics TTML,
    # Portato QQ QRC, Legato KuGou LRC, BiniLyrics syllable TTML).
    boidu_names = list(_DIRECT_FETCHERS.keys())
    for name in boidu_names:
        logical = {'ttml': 'bLyrics', 'qq': 'QQ', 'kugou': 'KuGou', 'binimum': 'BiniLyrics'}.get(name, name)
        if not wants(logical):
            continue
        best = None
        chooser = {
            'ttml': 'bLyrics', 'qq': 'QQ', 'kugou': 'KuGou', 'binimum': 'BiniLyrics',
        }
        for q in queries:
            fetcher = _DIRECT_FETCHERS[name]
            try:
                raw = fetcher(q['title'], q['artist'], duration, album)
                cand = _candidate_dict(raw, duration, priority=0)
                if cand and (best is None or _lyrics_score(cand) > _lyrics_score(best)):
                    best = cand
            except Exception:
                continue
        emit(chooser[name], chooser[name], best)

    # LRCLib: one entry (synced beats plain).
    if wants('LRCLib'):
        try:
            from .providers_lrclib import fetch_lrclib
            lrclib_node = pick_node()
            best = None
            for q in queries:
                lrc = fetch_lrclib(q['title'], q['artist'], album, duration, via_node=lrclib_node)
                if not lrc:
                    continue
                if lrc.get('instrumental'):
                    cand = {'lyrics': [{'time': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'duration': 0}], 'source': 'LRCLib', 'synced': False}
                elif lrc.get('synced'):
                    cand = {'lyrics': parse_lrc(lrc['synced'], duration), 'source': 'LRCLib', 'synced': True}
                else:
                    cand = {'lyrics': parse_plain(lrc.get('plain', '')), 'source': 'LRCLib', 'synced': False}
                if best is None or _lyrics_score(cand) > _lyrics_score(best):
                    best = cand
            emit('LRCLib', 'LRCLib', best)
        except Exception as e:
            print(f"  [probe] LRCLib error: {e}")

    # Unison: one entry (TTML/synced preferred over plain).
    if wants('Unison'):
        try:
            from .providers_unison import fetch_unison
            unison_node = pick_node()
            best = None
            for q in queries:
                uni = fetch_unison(video_id, q['title'], q['artist'], duration, via_node=unison_node)
                if not uni:
                    continue
                if uni.get('parsed'):
                    cand = {'lyrics': uni['parsed'], 'source': 'Unison', 'synced': True}
                elif uni.get('synced'):
                    cand = {'lyrics': parse_lrc(uni['synced'], duration), 'source': 'Unison', 'synced': True}
                else:
                    cand = {'lyrics': parse_plain(uni.get('plain', '')), 'source': 'Unison', 'synced': False}
                if best is None or _lyrics_score(cand) > _lyrics_score(best):
                    best = cand
            emit('Unison', 'Unison', best)
        except Exception as e:
            print(f"  [probe] Unison error: {e}")

    # YouTube Music: plain only.
    if wants('YouTube'):
        try:
            yt = fetch_yt_lyrics(video_id)
            if yt and yt.get('plain'):
                emit('YouTube', yt.get('source', 'YouTube Music'),
                     {'lyrics': parse_plain(yt['plain']), 'source': yt.get('source', 'YouTube Music'), 'synced': False})
        except Exception as e:
            print(f"  [probe] YouTube error: {e}")

    candidates.sort(key=lambda c: c['score'], reverse=True)
    return candidates


