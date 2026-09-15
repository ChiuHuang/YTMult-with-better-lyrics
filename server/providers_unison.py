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
from .parsers_ttml import parse_ttml_basic

# ============================================================
# Provider 3: Unison (community lyrics, free with x-key-id)
# ============================================================

def generate_unison_key():
    """Generate a unique key ID for Unison API."""
    import uuid
    return hashlib.sha256(str(uuid.uuid4()).encode()).hexdigest()[:32]

_unison_key = None

def get_unison_key():
    global _unison_key
    if _unison_key is None:
        _unison_key = generate_unison_key()
    return _unison_key


def _unwrap_unison(raw):
    """Unison API wraps responses as { success, data }. Unwrap and return
    data on success, None on failure. Handles both old flat and new wrapped
    formats for backwards compatibility."""
    if not raw or not isinstance(raw, dict):
        return None
    # New format: { success: true, data: { ... } }
    if 'success' in raw:
        if not raw['success']:
            return None
        return raw.get('data')
    # Old flat format (no 'success' key) -- return as-is
    return raw


def fetch_unison(video_id, title='', artist='', duration=0, via_node=None):
    """Fetch lyrics from Unison community API. via_node relays the GET through a
    connected node's outbound IP (same pattern as LRCLIB/Cubey) with a direct
    local fallback when the relay is unavailable."""
    try:
        headers = {
            'x-key-id': get_unison_key(),
            'Content-Type': 'application/json'
        }
        params = {'v': video_id}
        if title:
            params['song'] = title
        if artist:
            params['artist'] = artist
        if duration:
            params['duration'] = str(int(duration))

        raw = None
        if via_node:
            relayed = relay_http_request(via_node, 'GET',
                                         f'https://unison.boidu.dev/lyrics?{urlencode(params)}',
                                         headers=headers, timeout=8)
            if relayed is not None:
                status, text = relayed
                if status == 200:
                    try:
                        raw = json.loads(text)
                    except Exception:
                        pass
                else:
                    print(f"  [FAIL] Unison via node {via_node}: HTTP {status}")
            else:
                print(f"  [WARN] Node {via_node} relay failed, falling back to a direct request")
        if raw is None:
            resp = requests.get('https://unison.boidu.dev/lyrics',
                              params=params, headers=headers, timeout=8)
            if resp.status_code == 200:
                raw = resp.json()

        data = _unwrap_unison(raw)
        if data:
            fmt = data.get('format', '')
            lyrics_text = data.get('lyrics', '')

            if not lyrics_text:
                return None

            if fmt == 'lrc':
                return {
                    'synced': lyrics_text,
                    'plain': None,
                    'source': 'Unison',
                    'format': 'lrc'
                }
            elif fmt == 'plain':
                return {
                    'synced': None,
                    'plain': lyrics_text,
                    'source': 'Unison',
                    'format': 'plain'
                }
            elif fmt == 'ttml':
                # Parse TTML to extract lines
                ttml_lyrics = parse_ttml_basic(lyrics_text, duration)
                if ttml_lyrics:
                    return {
                        'parsed': ttml_lyrics,
                        'source': 'Unison',
                        'format': 'ttml'
                    }
    except Exception as e:
        print(f"[Unison] Error: {e}")
    return None


