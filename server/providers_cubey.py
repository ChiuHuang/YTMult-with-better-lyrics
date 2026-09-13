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
from .nodes import relay_http_request
from .parsers_qrc import parse_qrc_to_lrc

# ============================================================
# Cubey API (Turnstile bypassed)
# ============================================================

def _apply_cubey_event(event_data, state):
    """Handle one parsed SSE event from Cubey, updating `state` in place.
    Returns a result dict to short-circuit immediately (perfect match), or
    None to keep scanning for a better one."""
    provider = event_data.get("provider")
    results = event_data.get("results")
    if not results:
        return None

    if provider == "musixmatch":
        if results.get("wordByWord"):
            return {"synced": results["wordByWord"], "source": "Musixmatch"}
        if results.get("synced") and not state['best_is_wbw']:
            state['best_lyrics'] = {"synced": results["synced"], "source": "Musixmatch"}
    elif provider == "qq" and results.get("lyrics"):
        # QRC carries true word-by-word timing: outranks any
        # line-sync best collected so far (e.g. Musixmatch LRC)
        qrc_lrc = parse_qrc_to_lrc(results["lyrics"])
        if qrc_lrc:
            print(f"  [OK] Cubey: QQ word-sync lyrics found!")
            state['best_lyrics'] = {"synced": qrc_lrc, "source": "QQ"}
            state['best_is_wbw'] = True
    elif provider == "netease" and results.get("synced"):
        if not state['best_lyrics']:
            state['best_lyrics'] = {"synced": results["synced"], "source": "NetEase"}
    elif provider == "kugou" and results.get("lyrics"):
        try:
            k_json = json.loads(results["lyrics"])
            if k_json.get("lyrics") and not state['best_lyrics']:
                state['best_lyrics'] = {"synced": k_json["lyrics"], "source": "KuGou"}
        except Exception:
            pass
    return None


def _parse_cubey_lines(line_iter):
    state = {'best_lyrics': None, 'best_is_wbw': False}
    for line in line_iter:
        if not line:
            continue
        if isinstance(line, bytes):
            line = line.decode('utf-8', errors='ignore')
        line = line.strip()
        if not line.startswith("data:"):
            continue
        data_str = line[5:].strip()
        if data_str == "[DONE]":
            break
        try:
            event_data = json.loads(data_str)
        except Exception:
            continue
        early = _apply_cubey_event(event_data, state)
        if early:
            return early
    return state['best_lyrics']


def fetch_cubey(jwt_token, video_id, title, artist, duration_sec, via_node=None):
    url = "https://lyrics.api.dacubeking.com/v2/lyrics"
    data = {
        "videoId": video_id,
        "song": title,
        "artist": artist,
        "duration": str(int(duration_sec)),
        "alwaysFetchMetadata": "false",
        "token": jwt_token
    }

    if via_node:
        # Route through a connected node's outbound IP for diversity against
        # provider rate limits. Buffers the whole response instead of
        # streaming it (unavoidable when relaying a full HTTP response back
        # over a JSON WebSocket message), so this trades a little of the
        # streaming early-exit speed for that IP diversity -- acceptable
        # since low latency here was explicitly not a priority.
        relayed = relay_http_request(via_node, method="POST", url=url, data=data, timeout=15)
        if relayed is not None:
            status, text = relayed
            if status == 200:
                return _parse_cubey_lines(text.splitlines())
            print(f"  [FAIL] Cubey via node {via_node}: HTTP {status}")
            return None
        print(f"  [WARN] Node {via_node} relay failed, falling back to a direct request")

    try:
        response = requests.post(url, data=data, stream=True, timeout=15)
        if response.status_code != 200:
            print(f"  [FAIL] Cubey API error: {response.status_code}")
            return None
        return _parse_cubey_lines(response.iter_lines())
    except Exception as e:
        print(f"  [FAIL] Cubey API request failed: {e}")
        return None


