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

from .parsers_credits import is_credit_line


def is_cjk(text):
    for c in text:
        if '\u4e00' <= c <= '\u9fff' or '\u3040' <= c <= '\u30ff':
            return True
    return False

def last_part_duration_ms(part_start, line_start, line_duration_ms, next_line_start=None, prior_parts=None):
    """Estimate a natural duration for the final word of a line when untimed.
    Never stretches across the inter-line gap to the next line's start."""
    max_gap = None
    if next_line_start is not None and next_line_start > part_start:
        max_gap = next_line_start - part_start
    elif line_duration_ms > 0:
        max_gap = max((line_start + line_duration_ms) - part_start, 150)

    # Derive natural duration from preceding words in the same line
    durs = [p.get('durationMs', 0) for p in (prior_parts or []) if (p.get('durationMs') or 0) > 0]
    if durs:
        avg_dur = sum(durs) / len(durs)
        estimated = int(min(max(avg_dur * 1.25, 350), 1200))
    elif prior_parts:
        elapsed = part_start - line_start
        if elapsed > 0:
            avg_dur = elapsed / len(prior_parts)
            estimated = int(min(max(avg_dur * 1.25, 350), 1200))
        else:
            estimated = 500
    else:
        estimated = 500

    if max_gap is not None:
        estimated = min(estimated, max_gap)

    return max(estimated, 150)

def generate_interpolated_parts(text, start_ms, duration_ms):
    """Never fabricate fake word-by-word timestamps from line-by-line lyrics."""
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

# LySy enhanced LRC marks a background voice with a trailing [bg:...] group.
# Anchored at the end, and greedy, so a cue that itself contains ']' survives.
_BG_MARKER_RE = re.compile(r'\[bg:(.*)\]\s*$', re.I)

# LRC ID tags. `au` is the song's author and `lr` its lyricist; `by` names
# whoever made the FILE, which is not a songwriter. Read as a set so an unknown
# vendor tag does not fall through to the time-tag branch and get parsed as a
# lyric line.
_LRC_ID_TAGS = frozenset(('ti', 'ar', 'al', 'au', 'lr', 'length', 'by',
                          'offset', 're', 'tool', 've', '#'))


def _lrc_word_parts(text, parse_time_tag, offset_ms):
    """One enhanced-LRC segment -> (plain text, parts).

    Split out of parse_lrc because the [bg:] group is the same grammar and used
    to be re-implemented (badly, by not being handled at all).
    """
    plain_text = re.sub(r'\s+', ' ', _LRC_WORD_RE.sub('', text)).strip()

    current_parts = []
    first_match = _LRC_WORD_RE.search(text)
    if first_match and first_match.start() > 0:
        # Leading text before the first tag: it belongs to the line, and its
        # timing is the line's own start.
        lead = text[:first_match.start()].strip()
        if lead:
            current_parts.append({
                'startTimeMs': 0,  # bound to the line start by the caller
                'words': lead + (' ' if not is_cjk(lead) else ''),
                'durationMs': 0
            })

    for tm_min, tm_sec, tm_cs, word_str in _LRC_TOKEN_RE.findall(text):
        if not word_str:
            continue
        current_parts.append({
            'startTimeMs': parse_time_tag(tm_min, tm_sec, tm_cs) + offset_ms,
            'words': word_str,
            'durationMs': 0
        })

    # Durations come from the next part's start; the last one has no successor
    # inside the segment and gets a nominal 500ms, which postprocess_lyrics
    # later replaces with a real figure.
    for pi in range(len(current_parts)):
        if pi < len(current_parts) - 1:
            dur = (current_parts[pi + 1]['startTimeMs']
                   - current_parts[pi]['startTimeMs'])
            current_parts[pi]['durationMs'] = max(dur, 0)
        else:
            current_parts[pi]['durationMs'] = 500
    return plain_text, current_parts


_LRC_WORD_RE = re.compile(r'<(\d+):(\d+)\.(\d+)>')
_LRC_TOKEN_RE = re.compile(r'<(\d+):(\d+)\.(\d+)>([^<]*)')


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
        if id_match and id_match.group(1) in _LRC_ID_TAGS:
            continue

        # Extract time tags
        time_matches = list(time_regex.finditer(line))
        if not time_matches:
            continue

        text = time_regex.sub('', line).strip()
        if not text:
            continue

        # LySy enhanced LRC writes a background voice as a trailing [bg:...]
        # group on the same line. The marker is format and comes off; whatever
        # the source wrote inside passes through untouched, parens included --
        # it is the same convention TTML spells ttm:role="x-bg", and it used to
        # be glued into the vocal text here, so the second voice was sung by
        # the first one.
        bg_raw = None
        _bgm = _BG_MARKER_RE.search(text)
        if _bgm:
            bg_raw = _bgm.group(1)
            text = text[:_bgm.start()].strip()

        # Parse word-level sync if present (<mm:ss.xx>word)
        parts = []
        bg_parts = []
        bg_text = ''
        word_matches = list(word_regex.finditer(text))
        if word_matches:
            plain_text, current_parts = _lrc_word_parts(text, parse_time_tag, offset_ms)
            parts = current_parts
            text = plain_text
        if bg_raw is not None:
            bg_word_matches = list(word_regex.finditer(bg_raw))
            if bg_word_matches:
                bg_text, bg_parts = _lrc_word_parts(bg_raw, parse_time_tag, offset_ms)
            else:
                bg_text = re.sub(r'\s+', ' ', bg_raw).strip()

        # A credit line is not a lyric. `作词：周杰伦` used to sail straight
        # through as a sung line -- parsers_lrc had no credit handling at all,
        # and parsers_qrc had one English regex that cannot read CJK.
        if is_credit_line(text):
            continue

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

            # The [bg:] voice becomes its own sub-line, the same shape TTML's
            # x-bg produces, so the device has ONE thing to render rather than
            # two conventions. It is never merged into `text` and never counts
            # towards the line's own word timing.
            if bg_text or bg_parts:
                bg_entry = {'text': bg_text, 'parts': bg_parts}
                if bg_parts:
                    if bg_parts[0]['startTimeMs'] == 0:
                        bg_parts[0]['startTimeMs'] = start_ms
                    b_words = [p for p in bg_parts if p.get('words')]
                    if len(b_words) > 1:
                        bg_entry['wordSynced'] = True
                _b_start = min((p['startTimeMs'] for p in bg_parts),
                               default=start_ms)
                _b_end = max((p['startTimeMs'] + p['durationMs'] for p in bg_parts),
                             default=start_ms)
                bg_entry['startTimeMs'] = _b_start
                bg_entry['durationMs'] = max(_b_end - _b_start, 0)
                bg_entry['duration'] = round(bg_entry['durationMs'] / 1000.0, 3)
                if not bg_parts:
                    bg_entry.pop('parts')
                entry['bg'] = bg_entry

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

        # Only true word-synced entries (e.g. Enhanced LRC <mm:ss.xx>) have parts.
        # Plain line-by-line (LBL) LRC must NEVER have fake parts interpolated.
        if not result[i].get('parts') or len(result[i]['parts']) <= 1:
            result[i].pop('parts', None)
            result[i]['wordSynced'] = False
        else:
            result[i]['wordSynced'] = True
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
                    nxt = result[i + 1]['startTimeMs'] if i + 1 < len(result) else None
                    p_list[pi]['durationMs'] = last_part_duration_ms(
                        p_list[pi]['startTimeMs'], result[i]['startTimeMs'], result[i]['durationMs'],
                        next_line_start=nxt, prior_parts=p_list[:-1])

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


