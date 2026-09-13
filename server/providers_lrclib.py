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
from urllib.parse import urlencode
from .nodes import relay_http_request
# ============================================================
# Provider 1: LRCLIB (free, no auth)
# ============================================================

def fetch_lrclib(title, artist, album='', duration=0, via_node=None):
    """Fetch lyrics from LRCLIB. Tries exact match, then search with strict validation.
    When via_node is set the HTTP calls go out over a connected node's outbound IP
    (same relay Cubey uses) so per-IP rate limits don't reach this server; any node
    failure falls back to a direct local request."""
    headers = {'User-Agent': 'YTMusicUltimate/1.0 (https://github.com/user/ytmusicultimate)'}

    def _get(url, params, timeout=8):
        if via_node:
            relayed = relay_http_request(via_node, 'GET', f'{url}?{urlencode(params)}',
                                         headers=headers, timeout=timeout)
            if relayed is not None:
                status, text = relayed
                if status == 200:
                    try:
                        return json.loads(text)
                    except Exception:
                        return None
                print(f"  [FAIL] LRCLIB via node {via_node}: HTTP {status}")
            print(f"  [WARN] Node {via_node} relay failed, falling back to a direct request")
        resp = requests.get(url, params=params, timeout=timeout, headers=headers)
        if resp.status_code == 200:
            return resp.json()
        return None

    # Exact match
    try:
        params = {'track_name': title, 'artist_name': artist}
        if album:
            params['album_name'] = album
        if duration:
            params['duration'] = duration

        data = _get('https://lrclib.net/api/get', params)
        if data and (data.get('syncedLyrics') or data.get('plainLyrics')):
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
        results = _get('https://lrclib.net/api/search', {'q': q_str})
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


