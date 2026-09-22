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
# QQ QRC Parser (word-by-word, ms precision)
# QRC lines: [lineStartMs,lineDurMs]word (offMs,durMs)word (offMs,durMs)...
# Each word's text PRECEDES its timing group; offsets are absolute ms in
# practice (treated as relative when below the line start). Cubey
# double-encodes the payload: results["lyrics"] is a JSON string holding
# {"lyrics": "<QrcInfos.../>", "provider": "qq"}.
# Output is enhanced LRC so the standard parse_lrc path (wordSynced=True)
# handles parts/timing downstream with no special cases.
# ============================================================

_QRC_CREDIT_RE = re.compile(r'\b(lyrics|composed|arranged|produced|written|vocals?|chorus|mixed|mastered)\s*by\b', re.I)

def _qrc_tag(ms, bracket=True):
    ms = max(int(ms), 0)
    tag = f"{ms // 60000:02d}:{(ms % 60000) // 1000:02d}.{(ms % 1000) // 10:02d}"
    return f"[{tag}]" if bracket else f"<{tag}>"

def _is_cjk_char(c):
    # Mirrors is_cjk() in parsers_lrc.py, extended with Katakana Phonetic
    # Extensions (31F0-31FF), Halfwidth Katakana (FF61-FF9F), CJK
    # Symbols/Punctuation (3000-303F) and CJK Extension A (3400-4DBF).
    o = ord(c)
    return ((0x4E00 <= o <= 0x9FFF) or (0x3040 <= o <= 0x30FF) or
            (0x31F0 <= o <= 0x31FF) or (0xFF61 <= o <= 0xFF9F) or
            (0x3000 <= o <= 0x303F) or (0x3400 <= o <= 0x4DBF))


def _qrc_join_words(words):
    """CJK-aware join: no space when both boundary chars are CJK."""
    out = ''
    for i, w in enumerate(words):
        if i > 0:
            prev = out[-1] if out else ''
            nxt = w[0] if w else ''
            if not (prev and nxt and _is_cjk_char(prev) and _is_cjk_char(nxt)):
                out += ' '
        out += w
    return out


def _qrc_strip_cjk_spaces(text):
    """Drop spaces sitting between two CJK chars; keep other spacing."""
    res = []
    n = len(text)
    for i, ch in enumerate(text):
        if ch == ' ':
            prev = res[-1] if res else ''
            nxt = text[i + 1] if i + 1 < n else ''
            if prev and nxt and _is_cjk_char(prev) and _is_cjk_char(nxt):
                continue
        res.append(ch)
    return ''.join(res)


def _qrc_clean_text(text):
    text = re.sub(r'\s+([.,!?;:\'")\]}])', r'\1', text)
    text = re.sub(r'([(\["\'])\s+', r'\1', text)
    text = re.sub(r'\s+', ' ', text)
    return _qrc_strip_cjk_spaces(text).strip()

def _qrc_split_words(line_start, seg):
    """Extract (text, start_ms, dur_ms) triples from a QRC line segment."""
    els = re.split(r'\((\d+),(\d+)\)', seg)
    n = (len(els) - 1) // 3
    words = []
    for k in range(1, n + 1):
        txt = els[3 * k - 3].strip()
        if not txt:
            continue
        off, dur = int(els[3 * k - 2]), int(els[3 * k - 1])
        start = off if off >= line_start else line_start + off
        words.append((txt, start, max(dur, 1)))
    return words


def parse_qrc_structured(blob):
    """Convert QQ QRC payload straight to structured lyric entries, keeping
    the real per-word durations and the real line duration so the last word
    of every line ends where the line itself ends -- never stretched to the
    next line's start.

    Returns a list of entries shaped like parse_lrc output on success, or [].
    Each entry: {time, startTimeMs, text, durationMs, duration, parts, wordSynced}\n    parts: [{startTimeMs, words, durationMs}, ...]
    """
    if isinstance(blob, dict):
        blob = blob.get('lyrics', '')
    if not isinstance(blob, str) or not blob:
        return []
    # Peel Cubey's inner JSON envelope when present
    s = blob.strip()
    if s.startswith('{'):
        try:
            inner = json.loads(s)
            if isinstance(inner, dict) and inner.get('lyrics'):
                s = inner['lyrics']
        except Exception:
            pass
    if not isinstance(s, str) or not s:
        return []
    # Tolerate partially-decoded escapes
    if '\\n' in s and '\n' not in s:
        s = s.replace('\\n', '\n')
    # Title text (ti:) marks the header line to drop (it carries timed words)
    ti_match = re.search(r'\[ti:(.*?)\]', s)
    ti_text = _qrc_clean_text(ti_match.group(1)) if ti_match else ''

    out = []
    for m in re.finditer(r'\[(\d+),(\d+)\]([^\[]*)', s):
        line_start, line_dur = int(m.group(1)), int(m.group(2))
        seg = m.group(3)
        words = _qrc_split_words(line_start, seg)
        if not words:
            continue  # metadata ([ti:]/[ar:]/[offset:]) or wordless line
        text = _qrc_clean_text(_qrc_join_words([w for w, _, _ in words]))
        if not text:
            continue
        if ti_text and ti_text in text:
            continue
        if _QRC_CREDIT_RE.search(text):
            continue
        line_ms = max(line_dur, 1)
        parts = []
        prev_end = line_start
        for i, (w, start, dur) in enumerate(words):
            s_ms = max(start, prev_end)
            dur_ms = max(dur, 1)
            is_last = (i == len(words) - 1)
            # Keep the word inside the line's own sung span. Only the last
            # word gets shrunk to the line end (never stretched to the next
            # line); earlier words just yield to the next word's start.
            if is_last:
                if s_ms + dur_ms > line_start + line_ms:
                    dur_ms = max(line_start + line_ms - s_ms, 150)
            else:
                nxt_s = words[i + 1][1]
                if s_ms + dur_ms > nxt_s:
                    dur_ms = max(nxt_s - s_ms, 1)
            parts.append({'startTimeMs': s_ms, 'words': w, 'durationMs': dur_ms})
            prev_end = s_ms + dur_ms
        entry = {
            'time': round(line_start / 1000.0, 3),
            'startTimeMs': line_start,
            'text': text,
            'durationMs': line_ms,
            'duration': round(line_ms / 1000.0, 3),
            'parts': parts,
            'wordSynced': True,
        }
        out.append(entry)
    if not out:
        return []
    return out


def parse_qrc_to_lrc(blob):
    """Convert QQ QRC payload to enhanced LRC. Returns LRC string or None.
    Legacy wrapper over parse_qrc_structured kept for callers that need a
    plain string; prefer parse_qrc_structured for real timing."""
    entries = parse_qrc_structured(blob)
    if not entries:
        return None
    out_lines = []
    for e in entries:
        line = _qrc_tag(e['startTimeMs'])
        parts = e['parts']
        for i, p in enumerate(parts):
            w = p['words']
            line += _qrc_tag(p['startTimeMs'], bracket=False) + w
            if i < len(parts) - 1:
                nxt = parts[i + 1]['words']
                if nxt and w and not (_is_cjk_char(w[-1]) and _is_cjk_char(nxt[0])):
                    line += ' '
        out_lines.append(line.rstrip())
    return '\n'.join(out_lines)


