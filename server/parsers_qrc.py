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

def parse_qrc_to_lrc(blob):
    """Convert QQ QRC payload to enhanced LRC. Returns LRC string or None."""
    if isinstance(blob, dict):
        blob = blob.get('lyrics', '')
    if not isinstance(blob, str) or not blob:
        return None
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
        return None
    # Tolerate partially-decoded escapes
    if '\\n' in s and '\n' not in s:
        s = s.replace('\\n', '\n')
    # Title text (ti:) marks the header line to drop (it carries timed words)
    ti_match = re.search(r'\[ti:(.*?)\]', s)
    ti_text = _qrc_clean_text(ti_match.group(1)) if ti_match else ''

    out_lines = []
    for m in re.finditer(r'\[(\d+),(\d+)\]([^\[]*)', s):
        line_start, seg = int(m.group(1)), m.group(3)
        els = re.split(r'\((\d+),(\d+)\)', seg)
        n = (len(els) - 1) // 3
        if n <= 0:
            continue  # metadata ([ti:]/[ar:]/[offset:]) or wordless line
        words = []
        for k in range(1, n + 1):
            txt = els[3 * k - 3].strip()
            if not txt:
                continue
            off, dur = int(els[3 * k - 2]), int(els[3 * k - 1])
            start = off if off >= line_start else line_start + off
            words.append((txt, start, max(dur, 1)))
        if not words:
            continue
        text = _qrc_clean_text(_qrc_join_words([w for w, _, _ in words]))
        if not text:
            continue
        if ti_text and ti_text in text:
            continue
        if _QRC_CREDIT_RE.search(text):
            continue
        line = _qrc_tag(line_start)
        for i, (w, start, dur) in enumerate(words):
            line += _qrc_tag(start, bracket=False) + w
            if i < len(words) - 1:
                nxt = words[i + 1][0]
                if nxt and w and not (_is_cjk_char(w[-1]) and _is_cjk_char(nxt[0])):
                    line += ' '
        out_lines.append(line.rstrip())
    if not out_lines:
        return None
    return '\n'.join(out_lines)


