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
# Provider 1: LRCLIB (free, no auth)
# ============================================================

def fetch_lrclib(title, artist, album='', duration=0):
    """Fetch lyrics from LRCLIB. Tries exact match, then search with strict validation."""
    headers = {'User-Agent': 'YTMusicUltimate/1.0 (https://github.com/user/ytmusicultimate)'}

    # Exact match
    try:
        params = {'track_name': title, 'artist_name': artist}
        if album:
            params['album_name'] = album
        if duration:
            params['duration'] = duration

        resp = requests.get('https://lrclib.net/api/get', params=params, timeout=8, headers=headers)
        if resp.status_code == 200:
            data = resp.json()
            if data.get('syncedLyrics') or data.get('plainLyrics'):
                return {
                    'synced': data.get('syncedLyrics'),
                    'plain': data.get('plainLyrics', ''),
                    'source': 'LRCLib',
                    'instrumental': data.get('instrumental', False)
                }
    except Exception as e:
        pass

    # Search fallback with strict verification
    try:
        q_str = f"{artist} {title}".strip() if artist else title.strip()
        resp = requests.get('https://lrclib.net/api/search',
                          params={'q': q_str},
                          timeout=8, headers=headers)
        if resp.status_code == 200:
            results = resp.json()
            if isinstance(results, list):
                # First pass: find synced lyrics that match duration & artist
                for r in results:
                    r_dur = float(r.get('duration', 0) or 0)
                    r_artist = (r.get('artistName') or '').lower()
                    a_lower = (artist or '').lower()

                    # If duration is known, reject anything differing by > 5 seconds
                    if duration > 0 and r_dur > 0 and abs(r_dur - duration) > 5:
                        continue

                    # If artist is specified, ensure match unless duration is identical
                    if a_lower and a_lower not in r_artist and r_artist not in a_lower:
                        if duration > 0 and abs(r_dur - duration) > 2:
                            continue

                    if r.get('syncedLyrics'):
                        return {
                            'synced': r['syncedLyrics'],
                            'plain': r.get('plainLyrics', ''),
                            'source': 'LRCLib',
                            'instrumental': r.get('instrumental', False)
                        }

                # Second pass: plain lyrics with same strict match
                for r in results:
                    r_dur = float(r.get('duration', 0) or 0)
                    r_artist = (r.get('artistName') or '').lower()
                    a_lower = (artist or '').lower()

                    if duration > 0 and r_dur > 0 and abs(r_dur - duration) > 5:
                        continue
                    if a_lower and a_lower not in r_artist and r_artist not in a_lower:
                        if duration > 0 and abs(r_dur - duration) > 2:
                            continue

                    if r.get('plainLyrics'):
                        return {
                            'synced': None,
                            'plain': r['plainLyrics'],
                            'source': 'LRCLib',
                            'instrumental': r.get('instrumental', False)
                        }
    except Exception as e:
        print(f"[LRCLIB search] Error: {e}")

    return None


