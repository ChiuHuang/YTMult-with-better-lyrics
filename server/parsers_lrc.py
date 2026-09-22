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
# LRC Parser & Karaoke Interpolation
# ============================================================

def is_cjk(text):
    for c in text:
        if '\u4e00' <= c <= '\u9fff' or '\u3040' <= c <= '\u30ff':
            return True
    return False

def sung_duration_ratio(line_duration_ms):
    """Fraction of a line's duration that is actually sung (the rest is
    trailing breath/gap before the next line). Mirrors the -400ms/0.88 rule
    used by generate_interpolated_parts so the last word of a line ends
    inside the sung region instead of being stretched to the next line."""
    if line_duration_ms > 800:
        return max(0.88, (line_duration_ms - 400) / line_duration_ms)
    return 1.0

def line_sung_end(start_ms, line_duration_ms):
    """Absolute end of the sung portion of a line."""
    return start_ms + max(0, int(line_duration_ms * sung_duration_ratio(line_duration_ms)))

def last_part_duration_ms(part_start, line_start, line_duration_ms, next_line_start=None):
    """Duration for the final word of a line. Ends at the line's sung end
    (never the next line's start), with a sane floor."""
    sung_end = line_sung_end(line_start, line_duration_ms)
    end = min(sung_end, next_line_start) if next_line_start is not None else sung_end
    return max(end - part_start, 150)

def generate_interpolated_parts(text, start_ms, duration_ms):
    """Generate proportional word/character timestamps across line duration when provider lacks word-sync."""
    if not text or duration_ms <= 200:
        return []
    text = text.strip()
    if is_cjk(text):
        # Mixed CJK/Latin lines: CJK chars become their own tokens (no
        # space), Latin runs stay whole words with trailing space so English
        # spacing is never lost.
        tokens = []
        buf = ''
        for c in text:
            if c.strip() == '':
                if buf:
                    tokens.append(buf)
                    buf = ''
                continue
            if is_cjk(c):
                if buf:
                    tokens.append(buf)
                    buf = ''
                tokens.append(c)
            else:
                buf += c
        if buf:
            tokens.append(buf)
        tokens = [t.rstrip() for t in tokens if t and t.strip()]
        if not tokens:
            return []
        parts = []
        for i, t in enumerate(tokens):
            if len(t) == 1 and is_cjk(t):
                parts.append({'words': t, 'weight': 1})
            else:
                display = t + (' ' if i < len(tokens) - 1 else '')
                parts.append({'words': display, 'weight': max(len(t), 1)})
    else:
        words = text.split()
        if not words: return []
        parts = []
        for i, w in enumerate(words):
            display = w + (' ' if i < len(words) - 1 else '')
            parts.append({'words': display, 'weight': max(len(w), 1)})

    total_weight = sum(p['weight'] for p in parts)
    sung_dur = max(duration_ms * 0.88, duration_ms - 400) if duration_ms > 800 else duration_ms
    curr_ms = start_ms
    res = []
    n = len(parts)
    for i, p in enumerate(parts):
        p_dur = max(100, int(sung_dur * (p['weight'] / total_weight)))
        if i == n - 1:
            # Clamp the last word so the line never overshoots its sung end
            p_dur = max(100, min(p_dur, start_ms + int(sung_dur) - curr_ms))
        res.append({
            'startTimeMs': curr_ms,
            'words': p['words'],
            'durationMs': p_dur
        })
        curr_ms += p_dur
    return res

def parse_lrc(lrc_text, duration_sec=0):
    """Parse LRC format into structured JSON array.
    Supports standard [mm:ss.xx] and enhanced <mm:ss.xx> word-sync tags.
    """
    lines = lrc_text.strip().split('\n')
    result = []
    offset_ms = 0

    time_regex = re.compile(r'\[(\d+):(\d+)\.(\d+)\]')
    word_regex = re.compile(r'<(\d+):(\d+)\.(\d+)>')
    id_tag_regex = re.compile(r'^\[(\w+):(.*)\]$')

    def parse_time_tag(m, s, cs):
        minutes = int(m)
        seconds = int(s)
        cs_str = str(cs)
        if len(cs_str) == 2:
            ms = int(cs_str) * 10
        elif len(cs_str) == 1:
            ms = int(cs_str) * 100
        else:
            ms = int(cs_str[:3])
        return minutes * 60000 + seconds * 1000 + ms

    for line in lines:
        line = line.strip()
        if not line:
            continue

        # Check for offset tag
        id_match = id_tag_regex.match(line)
        if id_match and id_match.group(1) == 'offset':
            try:
                offset_ms = int(id_match.group(2))
            except:
                pass
            continue
        if id_match and id_match.group(1) in ['ti', 'ar', 'al', 'au', 'lr', 'length', 'by', 're', 'tool', 've', '#']:
            continue

        # Extract time tags
        time_matches = list(time_regex.finditer(line))
        if not time_matches:
            continue

        text = time_regex.sub('', line).strip()
        if not text:
            continue

        # Parse word-level sync if present (<mm:ss.xx>word)
        parts = []
        word_matches = list(word_regex.finditer(text))
        if word_matches:
            plain_text = re.sub(r'\s+', ' ', word_regex.sub('', text)).strip()

            # Check for leading text before first tag
            first_match = word_matches[0]
            current_parts = []
            if first_match.start() > 0:
                lead = text[:first_match.start()].strip()
                if lead:
                    current_parts.append({
                        'startTimeMs': 0, # Will be set to line start_ms
                        'words': lead + (' ' if not is_cjk(lead) else ''),
                        'durationMs': 0
                    })

            # Find tokens: (<time>) followed by chars up to next tag
            tokens = re.findall(r'<(\d+):(\d+)\.(\d+)>([^<]*)', text)
            for tm_min, tm_sec, tm_cs, word_str in tokens:
                w_ms = parse_time_tag(tm_min, tm_sec, tm_cs) + offset_ms
                clean_word = word_str
                if clean_word:
                    current_parts.append({
                        'startTimeMs': w_ms,
                        'words': clean_word,
                        'durationMs': 0
                    })

            # Calculate durations for each word part
            for pi in range(len(current_parts)):
                if pi < len(current_parts) - 1:
                    dur = current_parts[pi+1]['startTimeMs'] - current_parts[pi]['startTimeMs']
                    current_parts[pi]['durationMs'] = max(dur, 0)
                else:
                    current_parts[pi]['durationMs'] = 500

            parts = current_parts
            text = plain_text

        for tm in time_matches:
            start_ms = parse_time_tag(tm.group(1), tm.group(2), tm.group(3)) + offset_ms

            entry_parts = []
            if parts:
                import copy
                entry_parts = copy.deepcopy(parts)
                # If first part was leading text with 0, bind to start_ms
                if entry_parts and entry_parts[0]['startTimeMs'] == 0:
                    entry_parts[0]['startTimeMs'] = start_ms

            entry = {
                'time': round(start_ms / 1000.0, 3),
                'startTimeMs': start_ms,
                'text': text,
                'durationMs': 0
            }
            if entry_parts:
                entry['parts'] = entry_parts
                # Enhanced LRC carries real per-word timestamps. Generated
                # timings must never be treated as karaoke data by clients.
                entry['wordSynced'] = True

            result.append(entry)

    # Sort by time
    result.sort(key=lambda x: x['startTimeMs'])

    # Calculate durations
    duration_ms = duration_sec * 1000
    for i in range(len(result)):
        if i < len(result) - 1:
            result[i]['durationMs'] = result[i+1]['startTimeMs'] - result[i]['startTimeMs']
        else:
            result[i]['durationMs'] = max(int(duration_ms - result[i]['startTimeMs']), 3000)
        result[i]['duration'] = round(result[i]['durationMs'] / 1000.0, 3)

        # Keep generated parts for layout consumers, but mark them as
        # non-authoritative so clients do not fake word-by-word highlighting.
        if not result[i].get('parts') or len(result[i]['parts']) == 0:
            result[i]['parts'] = generate_interpolated_parts(result[i]['text'], result[i]['startTimeMs'], result[i]['durationMs'])
            result[i]['wordSynced'] = False
        else:
            # Sanitize existing parts
            p_list = result[i]['parts']
            l_start = result[i]['startTimeMs']
            prev_ms = l_start
            for pi, p in enumerate(p_list):
                if not p.get('startTimeMs') or p['startTimeMs'] < l_start:
                    p['startTimeMs'] = prev_ms + (0 if pi == 0 else 200)
                prev_ms = p['startTimeMs']
            for pi in range(len(p_list)):
                if pi < len(p_list) - 1:
                    dur = p_list[pi+1]['startTimeMs'] - p_list[pi]['startTimeMs']
                    p_list[pi]['durationMs'] = max(dur, 0)
                else:
                    p_list[pi]['durationMs'] = last_part_duration_ms(
                        p_list[pi]['startTimeMs'], result[i]['startTimeMs'], result[i]['durationMs'])

    return result


def parse_plain(plain_text):
    """Parse plain (unsynced) lyrics."""
    lines = plain_text.strip().split('\n')
    result = []
    for line in lines:
        text = line.strip()
        if text:
            result.append({
                'time': 0,
                'startTimeMs': 0,
                'text': text,
                'durationMs': 0,
                'duration': 0
            })
    return result


