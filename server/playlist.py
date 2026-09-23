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
from .app import app, _sse_broadcast
from .utils import _safe_cache_component
from .cache import get_cached, set_cached, is_not_found_result
from .nodes import ask_nodes_for_cache
from .providers_yt import get_ytmusic, get_song_info
from .pipeline import fetch_all_lyrics
from .library import record_unlyriced, apply_saved_rename
from .jwt_pool import contribute_jwt as _pool_contribute

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
            song_info = apply_saved_rename(video_id, song_info)
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


# ============================================================
# Playlist Sync: fetch lyrics for entire playlist with tagging
# ============================================================
_playlist_sync_jobs = {}
_playlist_sync_jobs_lock = threading.Lock()


def _next_playlist_sync_job_id():
    return _secrets.token_hex(8)


@app.route('/api/playlist/sync', methods=['POST'])
def api_playlist_sync():
    """Sync lyrics for an entire YouTube Music playlist.
    Request: {playlist, lang, regenerate?, jwt?}
    Response: {job_id, status_url, total_tracks}
    """
    body = request.get_json(silent=True) or {}
    playlist_input = (body.get('playlist_id') or body.get('playlist')
                      or request.form.get('playlist') or request.args.get('playlist'))
    playlist_id = _extract_playlist_id(playlist_input)
    if not playlist_id:
        return jsonify({'error': 'Invalid or missing playlist URL/ID'}), 400

    translate_to = body.get('lang') or request.args.get('lang', 'zh-TW')
    if not _safe_cache_component(translate_to):
        return jsonify({'error': 'Invalid lang'}), 400

    regenerate = bool(body.get('regenerate', True))
    jwt_token = body.get('jwt')
    if jwt_token:
        _pool_contribute(jwt_token, node_id='device')

    job_id = _next_playlist_sync_job_id()
    with _playlist_sync_jobs_lock:
        _playlist_sync_jobs[job_id] = {
            'job_id': job_id,
            'state': 'queued',
            'total': 0,
            'done': 0,
            'found': 0,
            'unlyriced': 0,
            'error_count': 0,
            'current': '',
            'playlist_id': playlist_id,
            'lang': translate_to,
            'tracks': [],
            'started': datetime.now().isoformat(),
        }

    threading.Thread(target=_run_playlist_sync_job, args=(job_id, playlist_id, translate_to, regenerate, jwt_token), daemon=True).start()
    return jsonify({'job_id': job_id, 'status_url': f'/api/playlist/sync/status/{job_id}'})


def _run_playlist_sync_job(job_id, playlist_id, translate_to, regenerate, jwt_token):
    job = _playlist_sync_jobs.get(job_id)
    if not job:
        return

    try:
        ytm = get_ytmusic()
        pl = ytm.get_playlist(playlist_id, limit=None)
        tracks = [t for t in (pl.get('tracks') or []) if t.get('videoId')]
    except Exception as e:
        job['state'] = 'failed'
        job['error'] = str(e)
        return

    job['total'] = len(tracks)
    job['state'] = 'running'

    for idx, t in enumerate(tracks):
        video_id = t.get('videoId')
        song = t.get('title', '')
        artist = t.get('artist', '')
        if not video_id or not _safe_cache_component(video_id):
            job['done'] += 1
            job['error_count'] += 1
            job['tracks'].append({'video_id': video_id or '', 'tag': 'invalid_id', 'status': 'invalid_id', 'title': song, 'song': song, 'artist': artist, 'index': idx})
            _sse_broadcast('playlist_sync_progress', {'job_id': job_id, 'video_id': video_id, 'song': song, 'artist': artist, 'status': 'invalid_id', 'done': job['done'], 'total': job['total']})
            continue

        cache_key = f"{video_id}:{translate_to}"
        cached_data = get_cached(cache_key)
        job['current'] = f"{song} - {artist}"
        track_result = {'video_id': video_id, 'title': song, 'song': song, 'artist': artist, 'index': idx}

        if cached_data:
            job['found'] += 1
            track_result['status'] = 'found'
            track_result['tag'] = 'found'
            track_result['source'] = cached_data.get('source', '')
            track_result['synced'] = bool(cached_data.get('synced', False))
            track_result['tier'] = 'wbw' if any(l.get('wordSynced') for l in cached_data.get('lyrics', [])) else ('line' if cached_data.get('synced') else 'plain')
        else:
            # Not cached - try to fetch if regenerate
            if regenerate:
                try:
                    song_info = get_song_info(video_id)
                    if not song_info:
                        raise ValueError('get_song_info returned None')
                    song_info = apply_saved_rename(video_id, song_info)
                    result = fetch_all_lyrics(video_id, song_info, translate_to, jwt_token)
                    if result and not is_not_found_result(result):
                        set_cached(cache_key, result)
                        job['found'] += 1
                        track_result['status'] = 'found'
                        track_result['tag'] = 'found'
                        track_result['source'] = result.get('source', '')
                        track_result['synced'] = bool(result.get('synced', False))
                        track_result['tier'] = 'wbw' if any(l.get('wordSynced') for l in result.get('lyrics', [])) else ('line' if result.get('synced') else 'plain')
                    else:
                        job['unlyriced'] += 1
                        track_result['status'] = 'unlyriced'
                        track_result['tag'] = 'unlyriced'
                        record_unlyriced(video_id, song, artist, translate_to)
                except Exception as e:
                    job['error_count'] += 1
                    track_result['status'] = 'error'
                    track_result['tag'] = 'error'
                    track_result['error'] = str(e)
                    print(f"  [PLAYLIST SYNC] {video_id} failed: {e}")
            else:
                job['unlyriced'] += 1
                track_result['status'] = 'unlyriced'
                track_result['tag'] = 'unlyriced'

        job['tracks'].append(track_result)
        job['done'] += 1
        _sse_broadcast('playlist_sync_progress', {
            'job_id': job_id, 'video_id': video_id, 'song': song, 'artist': artist,
            'status': track_result['status'], 'source': track_result.get('source', ''),
            'done': job['done'], 'total': job['total']
        })
        time_module.sleep(0.2)

    job['state'] = 'complete'
    job['finished'] = datetime.now().isoformat()
    _sse_broadcast('playlist_sync_progress', {'job_id': job_id, 'state': 'complete'})


@app.route('/api/playlist/sync/status/<job_id>', methods=['GET'])
def api_playlist_sync_status(job_id):
    with _playlist_sync_jobs_lock:
        job = _playlist_sync_jobs.get(job_id)
    if not job:
        return jsonify({'error': 'not found'}), 404
    return jsonify(job)


@app.route('/api/playlist/sync/stop/<job_id>', methods=['POST'])
def api_playlist_sync_stop(job_id):
    with _playlist_sync_jobs_lock:
        job = _playlist_sync_jobs.get(job_id)
        if job and job.get('state') == 'running':
            job['state'] = 'stopped'
    return jsonify({'ok': True})

