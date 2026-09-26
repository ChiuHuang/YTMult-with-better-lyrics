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
# Metadata Cleaning & Variants
# ============================================================

def get_search_queries(title, artist, ja_title='', ja_artist=''):
    """Generate search variations: raw original, with/without cover tags, and Japanese/English variants."""
    queries = []
    seen = set()

    def add_q(t, a):
        t_clean = re.sub(r'\s+', ' ', t or '').strip(' -_./')
        a_clean = re.sub(r'\s+', ' ', a or '').strip(' -_./')
        if not t_clean or not a_clean:
            return
        key = (t_clean.lower(), a_clean.lower())
        if key not in seen:
            seen.add(key)
            queries.append({'title': t_clean, 'artist': a_clean})

    def clean_title(t):
        if not t: return ''
        c = t
        c = re.sub(r'(?i)[/／]\s*(?:covered\s+by|cover\s+by|cover|歌ってみた).*$', '', c)
        c = re.sub(r'(?i)[/／]\s*[^/／]+$', '', c)
        c = re.sub(r'(?i)[\(\[\{【「『（［]\s*(?:official\s*(?:video|audio|music\s*video|mv|lyric\s*video)?|full\s*ver\.?|cover(?:ed)?(?:\s+by[^\)\]\}】」』）］]*)?|remix|mv|audio|feat\.?[^\)\]\}】」』）］]*|ft\.?[^\)\]\}】」』）］]*|歌ってみた|self\s*cover|[^\)\]\}】」』）］]*ver\.?)\s*[\)\]\}】」』）］]', '', c)
        c = re.sub(r'(?i)\b(?:feat\.?|ft\.?)\s+.*$', '', c)
        c = re.sub(r'(?i)\s*-\s*(?:cover|official|remix|mv).*$', '', c)
        return c.strip(' -_./')

    def clean_title_keep_remix(t):
        """Same as clean_title but KEEPS (remix): remix versions live under
        their own provider entries, so every probe must try the remix string
        as-is instead of only the stripped base title."""
        if not t: return ''
        c = t
        c = re.sub(r'(?i)[/／]\s*(?:covered\s+by|cover\s+by|cover|歌ってみた).*$', '', c)
        c = re.sub(r'(?i)[\(\[\{【「『（［]\s*(?:official\s*(?:video|audio|music\s*video|mv|lyric\s*video)?|full\s*ver\.?|cover(?:ed)?(?:\s+by[^\)\]\}】」』）］]*)?|mv|audio|feat\.?[^\)\]\}】」』）］]*|ft\.?[^\)\]\}】」』）］]*|歌ってみた|self\s*cover|[^\)\]\}】」』）］]*ver\.?)\s*[\)\]\}】」』）］]', '', c)
        c = re.sub(r'(?i)\b(?:feat\.?|ft\.?)\s+.*$', '', c)
        c = re.sub(r'(?i)\s*-\s*(?:cover|official|mv).*$', '', c)
        return c.strip(' -_./')

    def clean_artist(a):
        if not a: return ''
        c = a
        c = re.sub(r'(?i)[\(\[\{【「『（［]\s*(?:official|topic|channel|vevo)\s*[\)\]\}】」』）］]', '', c)
        c = re.sub(r'(?i)\s*-\s*topic$', '', c)
        return c.strip(' -_./')

    c_t = clean_title(title)
    c_a = clean_artist(artist)

    # 1. Clean title + clean artist
    add_q(c_t, c_a)
    # 2. Raw title + clean artist (with cover tags)
    if title != c_t:
        add_q(title, c_a)
    if artist != c_a:
        add_q(title, artist)
    # 2b. Keep-remix title: strip feat/official/etc but NEVER (remix), so
    # remix versions match their own provider entries every probe.
    r_t = clean_title_keep_remix(title)
    if r_t and r_t != c_t and r_t != (title or '').strip():
        add_q(r_t, c_a)
        if artist != c_a:
            add_q(r_t, artist)
    # 2c. Raw title + raw artist (maximum metadata, nothing stripped).
    if title and artist and (title != c_t or artist != c_a):
        add_q(title, artist)

    # 3. Japanese title/artist variants if available
    if ja_title or ja_artist:
        c_ja_t = clean_title(ja_title) or c_t
        c_ja_a = clean_artist(ja_artist) or c_a
        add_q(c_ja_t, c_ja_a)
        if ja_title and ja_title != c_ja_t:
            add_q(ja_title, c_ja_a)
        # Cross-language (e.g. English title + Japanese artist: Spiral - 明透)
        add_q(c_t, c_ja_a)
        # Japanese title + English artist (e.g. アバウト - GIRLS REVOLUTION PROJECT)
        add_q(c_ja_t, c_a)

    # 4. Extract possible original artist embedded in title (e.g. "アバウト / NAGI" -> artist: NAGI)
    for t_cand in [title, ja_title]:
        if not t_cand: continue
        parts = re.split(r'[/／\-–—]\s*', t_cand)
        if len(parts) >= 2:
            p0 = clean_title(parts[0])
            p1 = clean_title(parts[1])
            if p0 and p1:
                add_q(p0, p1)
                add_q(p1, p0)

    return queries


