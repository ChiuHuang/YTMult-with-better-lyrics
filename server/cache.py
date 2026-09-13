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
from urllib.parse import quote, unquote
import secrets as _secrets
import uuid
import traceback
import atexit
import logging
from .parsers_lrc import generate_interpolated_parts

# ============================================================
# Cache
# ============================================================

def is_not_found_result(data):
    """Check if result represents an empty or not found state."""
    if not data:
        return True
    source = data.get('source')
    lyrics = data.get('lyrics', [])
    if source in ['none', 'error'] or not lyrics:
        return True
    if len(lyrics) == 1 and 'No lyrics found' in lyrics[0].get('text', ''):
        return True
    return False

def sanitize_lyrics_parts(lyrics):
    """Ensure every line has valid, monotonically increasing parts with proper durations and spaces."""
    if not lyrics:
        return
    for l in lyrics:
        if not l.get('text'):
            continue
        l_ms = int(l.get('startTimeMs', l.get('time', 0) * 1000))
        l_dur = int(l.get('durationMs', l.get('duration', 0) * 1000))
        parts = l.get('parts')
        if not parts or len(parts) == 0:
            if l_dur > 0:
                l['parts'] = generate_interpolated_parts(l['text'], l_ms, l_dur)
        else:
            prev_ms = l_ms
            for pi, p in enumerate(parts):
                if not p.get('startTimeMs') or p['startTimeMs'] < l_ms:
                    p['startTimeMs'] = prev_ms + (0 if pi == 0 else 200)
                prev_ms = p['startTimeMs']
            for pi in range(len(parts)):
                if pi < len(parts) - 1:
                    dur = parts[pi+1]['startTimeMs'] - parts[pi]['startTimeMs']
                    parts[pi]['durationMs'] = max(dur, 0)
                else:
                    parts[pi]['durationMs'] = max(l_ms + l_dur - parts[pi]['startTimeMs'], 200)

def _cache_filename(key):
    """Windows-safe on-disk name for a logical cache key. Logical keys are
    "vid:lang" / "vid:lang:fast"; colons are illegal to *enumerate* on NTFS
    (they become alternate-data-stream names, so os.listdir/glob only see a
    bare base file). Percent-encoding keeps every file listable and is fully
    reversible for the dashboard/list nodes."""
    return quote(key, safe='')


def _cache_key_from_filename(fname):
    """Reverse of _cache_filename: 'dQw%3Azh-TW.json' -> 'dQw:zh-TW'."""
    if not fname.endswith('.json'):
        return None
    return unquote(fname[:-5])


def get_cached(video_id):
    path = f"cache/lyrics/{_cache_filename(video_id)}.json"
    if os.path.exists(path):
        try:
            with open(path, 'r', encoding='utf-8') as f:
                entry = json.load(f)
            data = entry.get('data')
            if is_not_found_result(data):
                return None
            if data and data.get('lyrics'):
                sanitize_lyrics_parts(data['lyrics'])
            ts = datetime.fromisoformat(entry['ts'])
            if (datetime.now() - ts).total_seconds() < 86400 * 3:
                return data
        except:
            pass
    return None

def set_cached(video_id, data):
    # Do not cache not-found or error records so future attempts or new lyrics can be resolved
    if is_not_found_result(data):
        return
    path = f"cache/lyrics/{_cache_filename(video_id)}.json"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump({'data': data, 'ts': datetime.now().isoformat()}, f, ensure_ascii=False)
    except:
        pass

def clear_not_found_caches():
    lyrics_dir = 'cache/lyrics'
    if not os.path.exists(lyrics_dir):
        return
    removed = 0
    for fname in os.listdir(lyrics_dir):
        if _cache_key_from_filename(fname) is not None:
            fpath = os.path.join(lyrics_dir, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    entry = json.load(f)
                if is_not_found_result(entry.get('data')):
                    os.remove(fpath)
                    removed += 1
            except Exception:
                pass
    if removed > 0:
        print(f"[CLEAN] Cleaned {removed} empty/not-found cache files at startup.")


