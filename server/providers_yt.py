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

