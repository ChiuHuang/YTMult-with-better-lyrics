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
                postprocess_lyrics(data['lyrics'], data.get('duration', 0))
            ts = datetime.fromisoformat(entry['ts'])
            if (datetime.now() - ts).total_seconds() < 86400 * 3:
                return data
        except:
            pass
    return None

def set_cached(video_id, data):
    if is_not_found_result(data):
        return
    if data and data.get('lyrics'):
        postprocess_lyrics(data['lyrics'], data.get('duration', 0))
    path = f"cache/lyrics/{_cache_filename(video_id)}.json"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump({'data': data, 'ts': datetime.now().isoformat()}, f, ensure_ascii=False)
        try:
            from .app import _sse_broadcast
            _sse_broadcast('cache', {'video_id': video_id, 'song': data.get('song', ''), 'artist': data.get('artist', ''), 'source': data.get('source', ''), 'synced': data.get('synced', False)})
        except Exception:
            pass
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


# -------------------------------------------------------------------
# Lyrics post-processing (mirrors iOS tweak n_ pipeline)
# -------------------------------------------------------------------
def postprocess_lyrics(lyrics, duration_s=0):
    if not lyrics:
        return lyrics
    duration_ms = int(duration_s * 1000) if duration_s > 0 else 0
    _merge_spaces(lyrics)
    _fudge_short_durations(lyrics)
    _fix_zero_durations(lyrics, duration_ms)
    _fix_last_word_durations(lyrics)
    _insert_instrumental_gaps(lyrics, duration_ms)
    return lyrics


def _merge_spaces(lyrics):
    """Merge tiny-duration spaces into adjacent words."""
    for line in lyrics:
        parts = line.get('parts')
        if not parts or len(parts) < 2:
            continue
        i = 1
        while i < len(parts):
            cur = parts[i]
            prev = parts[i - 1]
            if cur.get('words') == ' ' and prev.get('words') != ' ':
                diff = abs((cur.get('durationMs') or 0) - (prev.get('durationMs') or 0))
                cur_dur = cur.get('durationMs') or 0
                if diff <= 15 or cur_dur <= 100:
                    prev['durationMs'] = (prev.get('durationMs') or 0) + cur_dur
                    cur['durationMs'] = 0
                    cur['startTimeMs'] = (cur.get('startTimeMs') or 0) + cur_dur
                    parts.pop(i)
                    continue
            i += 1


def _fudge_short_durations(lyrics):
    """If >50% of non-space words have duration <=100ms, redistribute."""
    for line in lyrics:
        parts = line.get('parts')
        if not parts:
            continue
        non_space = [p for p in parts if p.get('words') != ' ']
        if len(non_space) < 3:
            continue
        short = sum(1 for p in non_space if (p.get('durationMs') or 0) <= 100)
        if short / len(non_space) <= 0.5:
            continue
        for p in parts:
            dur = p.get('durationMs') or 0
            if p.get('words') != ' ' and dur <= 400:
                idx = parts.index(p)
                nxt = parts[idx + 1] if idx + 1 < len(parts) else None
                if nxt and nxt.get('words') == ' ':
                    p['durationMs'] = dur + (nxt.get('durationMs') or 0)
                    nxt['startTimeMs'] = (nxt.get('startTimeMs') or 0) + (nxt.get('durationMs') or 0)
                    nxt['durationMs'] = 0
                elif nxt:
                    gap = (nxt.get('startTimeMs') or 0) - (p.get('startTimeMs') or 0)
                    p['durationMs'] = max(gap, 300) if gap > 0 else 300
                else:
                    p['durationMs'] = 300


def _fix_zero_durations(lyrics, duration_ms):
    """Fix lines with 0 total duration."""
    for i, line in enumerate(lyrics):
        d = line.get('durationMs') or 0
        if d > 0:
            continue
        if i + 1 < len(lyrics):
            next_start = lyrics[i + 1].get('startTimeMs') or 0
            line_start = line.get('startTimeMs') or 0
            line['durationMs'] = max(next_start - line_start, 3000)
        elif duration_ms > 0:
            line_start = line.get('startTimeMs') or 0
            line['durationMs'] = max(duration_ms - line_start, 3000)


def _fix_last_word_durations(lyrics):
    """Fix 0-duration last words in each line."""
    for i, line in enumerate(lyrics):
        parts = line.get('parts')
        if not parts:
            continue
        last = parts[-1]
        if (last.get('durationMs') or 0) > 0:
            continue
        if i + 1 < len(lyrics):
            next_start = lyrics[i + 1].get('startTimeMs') or 0
            last['durationMs'] = max(next_start - (last.get('startTimeMs') or 0), 150)
        else:
            line_dur = line.get('durationMs') or 0
            last_start = last.get('startTimeMs') or 0
            line_start = line.get('startTimeMs') or 0
            line_end = line_start + line_dur
            last['durationMs'] = max(line_end - last_start, 150)


def _insert_instrumental_gaps(lyrics, duration_ms):
    """Insert instrumental markers for gaps >5s between lines."""
    if len(lyrics) < 2:
        return
    instrumental = lambda start, dur: {
        'startTimeMs': start, 'durationMs': dur, 'text': '[instrumental]',
        'parts': [{'startTimeMs': start, 'durationMs': dur, 'words': '[instrumental]'}],
        'isInstrumental': True
    }
    i = 0
    while i < len(lyrics) - 1:
        end = (lyrics[i].get('startTimeMs') or 0) + (lyrics[i].get('durationMs') or 0)
        nxt_start = lyrics[i + 1].get('startTimeMs') or 0
        gap = nxt_start - end
        if gap > 5000:
            lyrics.insert(i + 1, instrumental(end, gap))
            i += 2
        else:
            i += 1


