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
from collections import deque, OrderedDict
from datetime import datetime
from urllib.parse import quote
import secrets as _secrets
import uuid
import traceback
import atexit
import logging
# ============================================================
# Provider 2: YouTube Music Lyrics (via ytmusicapi)
# ============================================================

_ytm = None
_ytm_ja = None

def get_ytmusic():
    global _ytm
    if _ytm is None:
        from ytmusicapi import YTMusic
        _ytm = YTMusic()
    return _ytm

def get_ytmusic_ja():
    global _ytm_ja
    if _ytm_ja is None:
        from ytmusicapi import YTMusic
        _ytm_ja = YTMusic(language='ja')
    return _ytm_ja


def get_song_info(video_id):
    """Get song metadata from YT Music with dual-language lookup (EN & JA)."""
    try:
        ytm = get_ytmusic()
        info = ytm.get_song(video_id)
        if not info or 'videoDetails' not in info:
            return None

        d = info['videoDetails']
        title = d.get('title', '')
        artist = d.get('author', '')
        duration = int(d.get('lengthSeconds', 0))

        album = ''
        try:
            album = info.get('microformat', {}).get('microformatDataRenderer', {}).get('tags', [''])[0]
        except:
            pass

        ja_title = ''
        ja_artist = ''
        try:
            ytm_ja = get_ytmusic_ja()
            info_ja = ytm_ja.get_song(video_id)
            if info_ja and 'videoDetails' in info_ja:
                d_ja = info_ja['videoDetails']
                ja_title = d_ja.get('title', '')
                ja_artist = d_ja.get('author', '')
        except:
            pass

        return {
            'title': title,
            'artist': artist,
            'ja_title': ja_title,
            'ja_artist': ja_artist,
            'album': album,
            'duration': duration
        }
    except Exception as e:
        print(f"[ytmusicapi] get_song error: {e}")
        return None


# --- Thumbnail URLs -------------------------------------------------------
# Pure string build from the video id: no request, no ytmusicapi, so it is
# safe to call on the hot path (the `meta` SSE event) and it never fails. The
# server ships the URLs so the client and the lyrics/meta payload can never
# disagree on the quality name, and so the next track's art can be requested
# before its lyrics exist.
#
#   hq  -> hqdefault.jpg      480x360, always present for a real video
#   max -> maxresdefault.jpg  1280x720, 404s for low-res uploads
#                              (and for shorts), so `hq` must stay the fallback
_YT_VIDEO_ID_RE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')
_YT_COVER_BASE = 'https://i.ytimg.com/vi/'


def yt_cover_url(video_id, quality='hq'):
    """YouTube thumbnail URL for `video_id`, or '' if the id is unusable.

    `quality` is 'hq' (default) or 'max'; anything else falls back to 'hq'
    rather than raising -- a bad query string must not 500 a lookup."""
    vid = (video_id or '').strip() if isinstance(video_id, str) else ''
    if not _YT_VIDEO_ID_RE.match(vid):
        return ''
    name = 'maxresdefault.jpg' if quality == 'max' else 'hqdefault.jpg'
    return f'{_YT_COVER_BASE}{vid}/{name}'


def fetch_yt_lyrics(video_id):
    try:
        ytm = get_ytmusic()
        watch_playlist = ytm.get_watch_playlist(video_id)
        lyrics_browse_id = watch_playlist.get('lyrics') if watch_playlist else None

        if lyrics_browse_id:
            lyrics = ytm.get_lyrics(lyrics_browse_id)
            if lyrics and lyrics.get('lyrics'):
                return {'plain': lyrics['lyrics'], 'source': 'YouTube Music'}
    except Exception as e:
        print(f"  [FAIL] ytmusicapi error: {e}")
    return None


# --- short-lived metadata cache -------------------------------------------
# Title/artist for a video id never changes, but the JA twin lookup costs a
# second round trip. The device asks for metadata on every song change (full
# screen title/artist), so cache it briefly instead of re-querying.
_SONG_INFO_TTL_S = 1800
_SONG_INFO_MAX = 32
_song_info_cache = OrderedDict()
_song_info_lock = threading.RLock()


def get_song_info_cached(video_id, ttl_s=_SONG_INFO_TTL_S):
    """get_song_info with a small TTL+LRU cache. Returns None on failure
    without caching the failure (a retry next call is cheaper than a stale
    miss)."""
    if not video_id:
        return None
    now = time_module.time()
    with _song_info_lock:
        hit = _song_info_cache.get(video_id)
        if hit and (now - hit[0]) < ttl_s:
            _song_info_cache.move_to_end(video_id)
            return hit[1]
    info = get_song_info(video_id)
    if not info:
        return None
    with _song_info_lock:
        _song_info_cache[video_id] = (time_module.time(), info)
        _song_info_cache.move_to_end(video_id)
        while len(_song_info_cache) > _SONG_INFO_MAX:
            _song_info_cache.popitem(last=False)
    return info

