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
from flask import Flask, request, jsonify, render_template, session, redirect, url_for, Response, stream_with_context
from .app import app
from .utils import _safe_cache_component
from .cache import get_cached, set_cached, is_not_found_result
from .nodes import ask_nodes_for_cache
from .providers_yt import get_ytmusic, get_song_info
from .pipeline import fetch_all_lyrics

# ============================================================
# Playlist background caching
#
# Warms the cache for an entire playlist without blocking on it -- runs in
# a background thread and is checked via a status endpoint. Each track goes
# through the exact same "check own cache -> check nodes -> fetch" path a
# normal request would, so it automatically benefits from (and contributes
# to) the node mesh above with no special-casing.
# ============================================================

_playlist_jobs = {}
_playlist_jobs_lock = threading.Lock()


def _extract_playlist_id(playlist_input):
    """Accept either a bare playlist ID or a full YouTube/YouTube Music
    playlist URL."""
    playlist_input = (playlist_input or '').strip()
    m = re.search(r'[?&]list=([A-Za-z0-9_-]+)', playlist_input)
    if m:
        return m.group(1)
    if re.match(r'^[A-Za-z0-9_-]{10,64}$', playlist_input):
        return playlist_input
    return None


def _run_playlist_cache_job(job_id, playlist_id, translate_to):
    job = _playlist_jobs[job_id]
    try:
        ytm = get_ytmusic()
        pl = ytm.get_playlist(playlist_id, limit=None)
        tracks = [t for t in (pl.get('tracks') or []) if t.get('videoId')]
    except Exception as e:
        job['status'] = 'failed'
        job['error'] = str(e)
        return

    job['total'] = len(tracks)
    job['status'] = 'running'

    for t in tracks:
        video_id = t.get('videoId')
        if not video_id or not _safe_cache_component(video_id):
            job['failed'] += 1
            job['done'] += 1
            continue

        cache_key = f"{video_id}:{translate_to}"
        if get_cached(cache_key):
            job['already_cached'] += 1
            job['done'] += 1
            continue

        node_data = ask_nodes_for_cache(cache_key, timeout=2.0)
        if node_data:
            set_cached(cache_key, node_data)
            job['already_cached'] += 1
            job['done'] += 1
            continue

        try:
            song_info = get_song_info(video_id)
            if not song_info:
                job['failed'] += 1
                job['done'] += 1
                continue
            result = fetch_all_lyrics(video_id, song_info, translate_to, jwt_token=None)
            if result and not is_not_found_result(result):
                set_cached(cache_key, result)
                job['newly_cached'] += 1
            else:
                job['failed'] += 1
        except Exception as e:
            job['failed'] += 1
            print(f"  [PLAYLIST] {video_id} failed: {e}")
        job['done'] += 1

    job['status'] = 'complete'


@app.route('/api/playlist/cache', methods=['POST'])
def api_playlist_cache():
    """Public: warm the cache for a playlist in the background. Returns
    immediately with a job id -- no lyrics are returned here, this just
    makes sure every track is cached so a later /api/lyrics call for any of
    them is instant."""
    body = request.get_json(silent=True) or {}
    playlist_input = body.get('playlist') or request.form.get('playlist') or request.args.get('playlist')
    playlist_id = _extract_playlist_id(playlist_input)
    if not playlist_id:
        return jsonify({'error': 'Invalid or missing playlist URL/ID'}), 400

    translate_to = body.get('lang') or request.args.get('lang', 'zh-TW')
    if not _safe_cache_component(translate_to):
        return jsonify({'error': 'Invalid lang'}), 400

    job_id = _secrets.token_hex(8)
    with _playlist_jobs_lock:
        _playlist_jobs[job_id] = {
            'status': 'queued', 'total': 0, 'done': 0,
            'newly_cached': 0, 'already_cached': 0, 'failed': 0,
            'playlist_id': playlist_id, 'lang': translate_to,
            'started': datetime.now().isoformat(),
        }
    threading.Thread(target=_run_playlist_cache_job, args=(job_id, playlist_id, translate_to), daemon=True).start()
    return jsonify({'job_id': job_id, 'status_url': f'/api/playlist/cache/status/{job_id}'})


@app.route('/api/playlist/cache/status/<job_id>', methods=['GET'])
def api_playlist_cache_status(job_id):
    with _playlist_jobs_lock:
        job = _playlist_jobs.get(job_id)
    if not job:
        return jsonify({'error': 'not found'}), 404
    return jsonify(job)

