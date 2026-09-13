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
from .app import app, SERVER_INSTANCE_ID, _recent_requests
from .utils import _safe_cache_component
from .cache import get_cached, set_cached, is_not_found_result
from .nodes import ask_nodes_for_cache
from .jwt_pool import contribute_jwt as _pool_contribute
from .providers_yt import get_song_info
from .metadata import get_search_queries
from .pipeline import fetch_fast_lyrics, fetch_all_lyrics, _in_flight, _in_flight_lock
from .logging_util import _log_crash

# ============================================================
# API Endpoints
# ============================================================

_update_cache = {'commit': None, 'checked_at': 0.0}


def latest_tweak_commit():
    """Fetch the current public build revision, caching it for five minutes."""
    now = time_module.time()
    if _update_cache['commit'] and now - _update_cache['checked_at'] < 300:
        return _update_cache['commit']
    try:
        response = requests.get(
            'https://api.github.com/repos/ChiuHuang/ytmusicultimate/commits/main',
            headers={'Accept': 'application/vnd.github+json'}, timeout=5)
        response.raise_for_status()
        commit = response.json().get('sha')
        if commit:
            _update_cache.update(commit=commit, checked_at=now)
            return commit
    except requests.RequestException as exc:
        print(f"[Update] Could not check GitHub: {exc}")
    try:
        return subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


@app.route('/api/update', methods=['GET'])
def api_update():
    client_commit = (request.args.get('commit') or '').strip().lower()
    if client_commit and not re.fullmatch(r'[0-9a-f]{7,64}', client_commit):
        return jsonify({'error': 'Invalid commit hash'}), 400
    latest_commit = latest_tweak_commit()
    if not latest_commit:
        return jsonify({'error': 'Update service unavailable'}), 503
    is_current = bool(client_commit) and latest_commit.lower().startswith(client_commit)
    return jsonify({
        'current_commit': client_commit or None,
        'latest_commit': latest_commit,
        'update_available': bool(client_commit) and not is_current,
        'repository': 'https://github.com/ChiuHuang/ytmusicultimate'
    })

@app.route('/api/lyrics', methods=['GET'])
def api_lyrics():
    _req_start = time_module.time()
    video_id = request.args.get('v')
    if not video_id:
        return jsonify({"error": "Missing video ID"}), 400

    if video_id.startswith('DEBUG_'):
        debug_msg = video_id[6:]
        client_ip = request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-For') or request.remote_addr
        ua = request.headers.get('User-Agent', '')[:120]
        print(f"[iOS] [iOS Tweak] {debug_msg} | ip={client_ip} ua={ua}")
        return jsonify({"ok": True, "source": "debug"})

    translate_to = request.args.get('lang', 'zh-TW')
    if not _safe_cache_component(video_id) or not _safe_cache_component(translate_to):
        return jsonify({"error": "Invalid video ID or lang"}), 400
    jwt_token = request.args.get('jwt')
    if jwt_token:
        # Auto opt-in: a real bootstrapped device carries a Turnstile-verified
        # Cubey JWT for this request -- share it with the pool so later requests
        # without one (other devices, nodes) can fall back on it. The pool
        # persists only a hash; contribution is cheap (dedup + probe evicts junk).
        _pool_contribute(jwt_token, node_id='device')
    fast_mode = request.args.get('fast', '0') == '1'
    force_mode = request.args.get('force', '0') == '1'

    client_ip = request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-For') or request.remote_addr
    ua = request.headers.get('User-Agent', '')[:120]
    all_args = dict(request.args)
    if 'jwt' in all_args and all_args['jwt']:
        all_args['jwt'] = all_args['jwt'][:12] + '...'
    req_id = _secrets.token_hex(3)
    _recent_requests.append({'id': req_id, 'v': video_id, 'mode': 'fast' if fast_mode else 'full', 'ip': client_ip, 'ts': datetime.now().isoformat()})

    print("=" * 60)
    mode_str = 'FAST' if fast_mode else ('JWT+Cohere' if jwt_token else 'Normal')
    if force_mode: mode_str += ' [FORCE]'
    print(f"[REQ] [REQ {req_id}] Lyrics request: {video_id} [{mode_str}] lang={translate_to}")
    print(f"  [REQ {req_id}] ip={client_ip} ua={ua}")
    print(f"  [REQ {req_id}] args={all_args} has_jwt={bool(jwt_token)}")
    print("=" * 60)

    # Cache keys — fast and full are stored separately
    full_cache_key = f"{video_id}:{translate_to}"
    fast_cache_key = f"{video_id}:{translate_to}:fast"
    cache_key = fast_cache_key if fast_mode else full_cache_key

    # In-flight dedup key — SAME for fast and full so they share the gate.
    # This prevents the common case of 8+ simultaneous requests for the same song
    # (fast + full + multiple VC instances) all running the full pipeline in parallel.
    dedup_key = f"{video_id}:{translate_to}" if not force_mode else None

    # --- Atomic check-and-register (fixes TOCTOU race) ---
    wait_event = None
    if dedup_key:
        with _in_flight_lock:
            if dedup_key in _in_flight:
                # Another request is already doing the work — grab its event to wait on
                wait_event = _in_flight[dedup_key]
            else:
                # First request for this video — register ourselves as in-flight
                event = threading.Event()
                _in_flight[dedup_key] = event

    if wait_event is not None:
        # We're a duplicate — wait for the primary request to finish
        print(f"[WAIT] [REQ {req_id}] [In-Flight] Waiting for primary request dedup_key={dedup_key}...")
        t0 = time_module.time()
        wait_event.wait(timeout=30)
        waited = time_module.time() - t0
        print(f"  [REQ {req_id}] [In-Flight] Wait done after {waited:.2f}s")
        # Check full cache first (might be better than fast), then fast
        cached = get_cached(full_cache_key) or get_cached(fast_cache_key)
        if cached:
            print(f"[OK] [REQ {req_id}] Got result from in-flight wait source={cached.get('source')} lines={len(cached.get('lyrics',[]))} synced={cached.get('synced')}")
            print(f"  [REQ {req_id}] elapsed={(time_module.time()-_req_start)*1000:.0f}ms (in-flight)")
            print("=" * 60)
            return jsonify(cached)
        # Fell through (timeout or no cache) — return empty
        print(f"[WARN] [REQ {req_id}] [In-Flight] No cache after wait (timeout or miss) - returning none")
        print(f"  [REQ {req_id}] elapsed={(time_module.time()-_req_start)*1000:.0f}ms (in-flight miss)")
        print("=" * 60)
        return jsonify({
            'lyrics': [{'time': 0, 'text': 'No lyrics found', 'translated': '找不到歌詞', 'duration': 0}],
            'source': 'none', 'synced': False
        })

    # --- Cache check (only for non-force requests) ---
    if not force_mode:
        # Fast mode: accept full result too (full is strictly better)
        cached = get_cached(full_cache_key) if fast_mode else get_cached(full_cache_key)
        cache_source = 'full'
        if not cached:
            cached = get_cached(cache_key)
            cache_source = 'mode-specific' if cached else 'none'
        if cached:
            age_info = ''
            try:
                path = f"cache/lyrics/{(fast_cache_key if cache_source=='mode-specific' else full_cache_key)}.json"
                import os as _os
                if _os.path.exists(path):
                    with open(path,'r',encoding='utf-8') as f:
                        entry = json.load(f)
                        ts = datetime.fromisoformat(entry['ts'])
                        age = (datetime.now()-ts).total_seconds()
                        age_info = f" age={age/3600:.1f}h"
            except: pass
            print(f"[OK] [REQ {req_id}] [Cache] hit! key={cache_source} source={cached.get('source')} lines={len(cached.get('lyrics',[]))} synced={cached.get('synced')}{age_info}")
            print(f"  [REQ {req_id}] elapsed={(time_module.time()-_req_start)*1000:.0f}ms (cache)")
            # Release in-flight slot immediately (no work needed)
            if dedup_key:
                with _in_flight_lock:
                    if dedup_key in _in_flight:
                        _in_flight[dedup_key].set()
                        del _in_flight[dedup_key]
            print("=" * 60)
            return jsonify(cached)
        else:
            print(f"  [REQ {req_id}] [Cache] miss for both full and fast keys")
            node_data = ask_nodes_for_cache(full_cache_key, timeout=2.0)
            if node_data:
                print(f"[OK] [REQ {req_id}] [Node cache] hit -- pulled from a connected node")
                set_cached(full_cache_key, node_data)
                if dedup_key:
                    with _in_flight_lock:
                        if dedup_key in _in_flight:
                            _in_flight[dedup_key].set()
                            del _in_flight[dedup_key]
                print(f"  [REQ {req_id}] elapsed={(time_module.time()-_req_start)*1000:.0f}ms (node cache)")
                print("=" * 60)
                return jsonify(node_data)
    else:
        print(f"  [REQ {req_id}] [Cache] bypassed (force mode)")

    # --- We are the primary request: do the actual work ---
    def release_inflight():
        if dedup_key:
            with _in_flight_lock:
                if dedup_key in _in_flight:
                    _in_flight[dedup_key].set()
                    del _in_flight[dedup_key]

    try:
        print(f"[SEARCH] [REQ {req_id}] Looking up song info via ytmusicapi...")
        t_song = time_module.time()
        song_info = get_song_info(video_id)
        print(f"  [REQ {req_id}] get_song_info took {(time_module.time()-t_song)*1000:.0f}ms")

        if not song_info:
            print(f"[FAIL] [REQ {req_id}] Could not identify song (get_song_info returned None)")
            release_inflight()
            return jsonify({
                'lyrics': [{'time': 0, 'text': 'Could not identify song', 'translated': 'Unable to identify song', 'duration': 0}],
                'source': 'error', 'synced': False
            })

        print(f"[MUSIC] [REQ {req_id}] {song_info['title']} - {song_info['artist']} ({song_info['duration']}s) album='{song_info.get('album','')}' ja_title='{song_info.get('ja_title','')}' ja_artist='{song_info.get('ja_artist','')}'")
        queries = get_search_queries(song_info['title'], song_info['artist'], song_info.get('ja_title',''), song_info.get('ja_artist',''))
        print(f"  [REQ {req_id}] Generated {len(queries)} search queries: {queries}")

        if fast_mode:
            print(f"  [REQ {req_id}] Fast mode pipeline start")
            result = fetch_fast_lyrics(video_id, song_info, translate_to)
            if not result:
                print(f"  [REQ {req_id}] Fast pipeline returned None -> none")
                result = {
                    'lyrics': [{'time': 0, 'text': 'No lyrics found', 'translated': 'No lyrics found', 'duration': 0}],
                    'source': 'none', 'synced': False
                }
            else:
                print(f"  [REQ {req_id}] Fast pipeline success source={result.get('source')} lines={len(result.get('lyrics',[]))}")
        else:
            print(f"  [REQ {req_id}] Full pipeline start (jwt={'yes' if jwt_token else 'no'})")
            result = fetch_all_lyrics(video_id, song_info, translate_to, jwt_token)

    except Exception as e:
        _log_crash(type(e), e, e.__traceback__)
        release_inflight()
        return jsonify({'error': str(e), 'instance': SERVER_INSTANCE_ID}), 500
    finally:
        release_inflight()

    # Cache result
    is_nf = is_not_found_result(result)
    print(f"  [REQ {req_id}] Caching result to {cache_key} is_not_found={is_nf}")
    set_cached(cache_key, result)

    print(f"[SEND] [REQ {req_id}] Returning {len(result.get('lyrics', []))} lines from {result.get('source', '?')} synced={result.get('synced')} elapsed={(time_module.time()-_req_start)*1000:.0f}ms")
    print("=" * 60)

    return jsonify(result)


@app.route('/api/cache/list', methods=['GET'])
def api_cache_list():
    """Public, lightweight listing of what this server already has cached, so
    a client can bulk-sync its local on-device cache without re-running the
    full fetch+translate pipeline per song. Pair this with GET /api/lyrics
    (force=0) for each returned video_id: that already serves straight from
    this same cache almost instantly, so no new fetch endpoint is needed."""
    lang_filter = (request.args.get('lang') or '').strip()
    try:
        limit = min(max(int(request.args.get('limit', 500)), 1), 2000)
    except (TypeError, ValueError):
        limit = 500

    lyrics_dir = 'cache/lyrics'
    items = []
    if os.path.exists(lyrics_dir):
        fnames = sorted(
            (f for f in os.listdir(lyrics_dir) if f.endswith('.json')),
            key=lambda f: os.path.getmtime(os.path.join(lyrics_dir, f)),
            reverse=True,
        )
        for fname in fnames:
            cache_key = fname[:-5]
            # cache_key on disk is "<video_id>:<lang>" or "<video_id>:<lang>:fast"
            parts = cache_key.split(':')
            if len(parts) < 2:
                continue
            video_id, lang = parts[0], parts[1]
            if len(parts) > 2 and parts[2] == 'fast':
                continue  # skip rough first-pass results; only sync full ones
            if lang_filter and lang != lang_filter:
                continue
            fpath = os.path.join(lyrics_dir, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    entry = json.load(f)
                data = entry.get('data', {})
                if is_not_found_result(data):
                    continue
                items.append({
                    'video_id': video_id,
                    'lang': lang,
                    'song': data.get('song', ''),
                    'artist': data.get('artist', ''),
                    'lines': len(data.get('lyrics', [])),
                    'synced': bool(data.get('synced', False)),
                    'ts': entry.get('ts', ''),
                })
            except Exception:
                continue
            if len(items) >= limit:
                break
    return jsonify({'count': len(items), 'items': items})



