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

def _qrc_clean_text(text):
    text = re.sub(r'\s+([.,!?;:\'")\]}])', r'\1', text)
    text = re.sub(r'([(\["\'])\s+', r'\1', text)
    return re.sub(r'\s+', ' ', text).strip()

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
        text = _qrc_clean_text(' '.join(w for w, _, _ in words))
        if not text:
            continue
        if ti_text and ti_text in text:
            continue
        if _QRC_CREDIT_RE.search(text):
            continue
        line = _qrc_tag(line_start)
        for w, start, dur in words:
            line += _qrc_tag(start, bracket=False) + w + ' '
        out_lines.append(line.rstrip())
    if not out_lines:
        return None
    return '\n'.join(out_lines)


