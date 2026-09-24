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
from .app import app, SERVER_INSTANCE_ID, _recent_requests, _sse_broadcast
from .utils import _safe_cache_component, lyrics_content_hash
from .cache import get_cached, set_cached, is_not_found_result, _cache_key_from_filename, _CACHE_FORMAT_VERSION, sanitize_lyrics_parts
from .nodes import ask_nodes_for_cache
from .jwt_pool import contribute_jwt as _pool_contribute
from .providers_yt import get_song_info
from .metadata import get_search_queries
from .pipeline import fetch_fast_lyrics, fetch_all_lyrics, _in_flight, _in_flight_lock
from .translate import apply_display_transforms
from .logging_util import _log_crash
from .playlist import _playlist_jobs, _playlist_jobs_lock

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
    auto_zh = request.args.get('az', '0') == '1'
    jwt_token = request.args.get('jwt')
    if jwt_token:
        # Auto opt-in: a real bootstrapped device carries a Turnstile-verified
        # Cubey JWT for this request -- share it with the pool so later requests
        # without one (other devices, nodes) can fall back on it. The pool
        # persists only a hash; contribution is cheap (dedup + probe evicts junk).
        _pool_contribute(jwt_token, node_id='device')
    fast_mode = request.args.get('fast', '0') == '1'
    force_mode = request.args.get('force', '0') == '1'
    # Device provider menu override: fetch this provider key now
    # ('Cubey/QQ', 'bLyrics', 'LRCLib', ...), cache it and remember it.
    only_provider = (request.args.get('provider') or '').strip() or None
    if only_provider and not re.fullmatch(r'[A-Za-z/]+', only_provider):
        return jsonify({"error": "Invalid provider"}), 400

    def serve(data):
        """Apply per-display transforms to an outgoing lyrics payload. Safe to
        mutate in place: primary results were already written to disk by
        `set_cached`, and cache-hit loads are fresh reads from disk."""
        if isinstance(data, dict) and isinstance(data.get('lyrics'), list):
            apply_display_transforms(data['lyrics'], translate_to, auto_zh)
        return jsonify(data)

    client_ip = request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-For') or request.remote_addr
    ua = request.headers.get('User-Agent', '')[:120]
    all_args = dict(request.args)
    if 'jwt' in all_args and all_args['jwt']:
        all_args['jwt'] = all_args['jwt'][:12] + '...'
    req_id = _secrets.token_hex(3)
    _recent_requests.append({'id': req_id, 'v': video_id, 'mode': 'fast' if fast_mode else 'full', 'ip': client_ip, 'ts': datetime.now().isoformat()})

    mode_str = 'FAST' if fast_mode else ('JWT+Cohere' if jwt_token else 'Normal')
    if force_mode: mode_str += ' [FORCE]'
    print(f"[REQ {req_id}] {video_id} [{mode_str}] lang={translate_to} jwt={bool(jwt_token)} ip={client_ip}")
    print(f"[REQ {req_id}] {all_args}")

    # Cache keys — fast and full are stored separately
    full_cache_key = f"{video_id}:{translate_to}"
    fast_cache_key = f"{video_id}:{translate_to}:fast"
    cache_key = fast_cache_key if fast_mode else full_cache_key

    # In-flight dedup key — SAME for fast and full so they share the gate.
    # This prevents the common case of 8+ simultaneous requests for the same song
    # (fast + full + multiple VC instances) all running the full pipeline in parallel.
    # Force and single-provider fetches bypass the gate (explicit user action).
    dedup_key = f"{video_id}:{translate_to}" if not (force_mode or only_provider) else None

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
            return serve(cached)
        # Fell through (timeout or no cache) — return empty
        print(f"[WARN] [REQ {req_id}] [In-Flight] No cache after wait (timeout or miss) - returning none")
        print(f"  [REQ {req_id}] elapsed={(time_module.time()-_req_start)*1000:.0f}ms (in-flight miss)")
        print("=" * 60)
        return jsonify({
            'lyrics': [{'time': 0, 'text': 'No lyrics found', 'translated': '找不到歌詞', 'duration': 0}],
            'source': 'none', 'synced': False
        })

    # --- Cache check (only for non-force, non-provider requests) ---
    if not force_mode and not only_provider:
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
            return serve(cached)
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
                return serve(node_data)
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

        if only_provider:
            print(f"  [REQ {req_id}] Single-provider fetch: {only_provider}")
            result, perr = _fetch_single_provider(video_id, translate_to, only_provider, jwt_token)
            print(f"  [REQ {req_id}] single-provider took {(time_module.time()-t_song)*1000:.0f}ms")
            if perr or not result:
                print(f"[FAIL] [REQ {req_id}] provider {only_provider}: {perr}")
                release_inflight()
                return jsonify({
                    'lyrics': [{'time': 0, 'text': f'No lyrics from {only_provider}', 'translated': perr or '找不到歌詞', 'duration': 0}],
                    'source': 'none', 'synced': False
                })
            print(f"[SEND] [REQ {req_id}] Returning {len(result.get('lyrics', []))} lines from {result.get('source', '?')} synced={result.get('synced')} elapsed={(time_module.time()-_req_start)*1000:.0f}ms")
            print("=" * 60)
            return serve(result)

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

    # Record unlyriced for library rebase
    if is_nf:
        try:
            from .library import record_unlyriced
            record_unlyriced(
                video_id,
                song_info.get('title', ''),
                song_info.get('artist', ''),
                translate_to,
            )
        except Exception:
            pass

    print(f"[SEND] [REQ {req_id}] Returning {len(result.get('lyrics', []))} lines from {result.get('source', '?')} synced={result.get('synced')} elapsed={(time_module.time()-_req_start)*1000:.0f}ms")
    print("=" * 60)

    return serve(result)


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
            (f for f in os.listdir(lyrics_dir) if _cache_key_from_filename(f) is not None),
            key=lambda f: os.path.getmtime(os.path.join(lyrics_dir, f)),
            reverse=True,
        )
        for fname in fnames:
            cache_key = _cache_key_from_filename(fname)
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


_TIER_RANK = {'raw': 0, 'line': 1, 'wbw': 2}


@app.route('/api/lyrics/check', methods=['GET'])
def api_lyrics_check():
    """Cheap version reconciliation. The client pings this even on a cache
    hit (it costs one tiny cache read, no provider calls) and compares the
    server's best tier against its own via `ct`: raw < line < wbw. Same tier
    -> upgrade=0 and the client ignores; strictly better -> upgrade=1 and the
    client does a normal (non-force) full fetch that serves the upgraded
    entry straight from the server cache -- which is how a background node
    re-race reaches a device whose lyrics were already shown."""
    video_id = request.args.get('v', '')
    translate_to = request.args.get('lang', '') or 'zh-TW'
    client_tier = request.args.get('ct', '')
    client_ver = request.args.get('cv', '0')
    if not _safe_cache_component(video_id) or not _safe_cache_component(translate_to):
        return jsonify({'error': 'Invalid video ID or lang'}), 400
    try:
        client_ver = max(int(client_ver), 0)
    except (TypeError, ValueError):
        client_ver = 0
    # A client cache stored under an older format (no real word durations /
    # last-word timing) is stale regardless of tier -- tell the client to
    # refetch so old on-device caches self-heal after the format bump.
    format_stale = client_ver < _CACHE_FORMAT_VERSION

    from .race import _lyrics_score, _wbw_line_count
    data = get_cached(f"{video_id}:{translate_to}") or get_cached(f"{video_id}:{translate_to}:fast")
    if not data:
        print(f"[CHECK] v={video_id} lang={translate_to} ct={client_tier} cv={client_ver} -> found=0 cv_stale={format_stale}")
        return jsonify({'found': False, 'upgrade': format_stale, 'formatVersion': _CACHE_FORMAT_VERSION})

    if _wbw_line_count(data) > 0:
        srv_tier = 'wbw'
    elif data.get('synced'):
        srv_tier = 'line'
    else:
        srv_tier = 'raw'
    if client_tier not in _TIER_RANK:
        client_tier = 'raw'
    upgrade = (_TIER_RANK[srv_tier] > _TIER_RANK[client_tier]) or format_stale
    print(f"[CHECK] v={video_id} lang={translate_to} ct={client_tier} cv={client_ver} -> found=1 tier={srv_tier} upgrade={int(upgrade)}")
    return jsonify({
        'found': True,
        'tier': srv_tier,
        'source': data.get('source', ''),
        'synced': bool(data.get('synced')),
        'wordSynced': srv_tier == 'wbw',
        'score': _lyrics_score(data),
        'upgrade': upgrade,
        'formatVersion': _CACHE_FORMAT_VERSION,
        'clientFormatVersion': client_ver,
    })


@app.route('/api/lyrics/precache', methods=['POST'])
def api_lyrics_precache():
    """Precache lyrics for upcoming queue tracks.
    
    Accepts a list of video IDs and pre-fetches lyrics in the background.
    Uses fast pipeline by default for speed; can use full pipeline with full=1.
    Returns immediately with job status - check /api/lyrics/precache/status/<job_id>.
    """
    body = request.get_json(silent=True) or {}
    video_ids = body.get('video_ids', [])
    if not isinstance(video_ids, list) or not video_ids:
        return jsonify({'error': 'video_ids list required'}), 400
    
    # Validate and limit
    valid_vids = [v for v in video_ids if isinstance(v, str) and _safe_cache_component(v)][:20]
    if not valid_vids:
        return jsonify({'error': 'No valid video IDs'}), 400
    
    translate_to = (body.get('lang') or 'zh-TW').strip()
    if not _safe_cache_component(translate_to):
        return jsonify({'error': 'Invalid lang'}), 400
    
    use_full = body.get('full', False)
    jwt_token = body.get('jwt')
    if jwt_token:
        from .jwt_pool import contribute_jwt as _pool_contribute
        _pool_contribute(jwt_token, node_id='device')
    
    job_id = _secrets.token_hex(8)
    job = {
        'status': 'queued',
        'total': len(valid_vids),
        'done': 0,
        'cached': 0,
        'failed': 0,
        'video_ids': valid_vids,
        'lang': translate_to,
        'full': use_full,
        'started': datetime.now().isoformat(),
    }
    
    with _playlist_jobs_lock:
        _playlist_jobs[job_id] = job
    
    threading.Thread(
        target=_run_precache_job,
        args=(job_id, valid_vids, translate_to, use_full, jwt_token),
        daemon=True
    ).start()
    
    return jsonify({
        'job_id': job_id,
        'status_url': f'/api/lyrics/precache/status/{job_id}',
        'queued': len(valid_vids)
    })


def _run_precache_job(job_id, video_ids, translate_to, use_full, jwt_token):
    job = _playlist_jobs.get(job_id)
    if not job:
        return
    
    job['status'] = 'running'
    
    for video_id in video_ids:
        full_cache_key = f"{video_id}:{translate_to}"
        
        # Skip if already cached
        if get_cached(full_cache_key):
            job['cached'] += 1
            job['done'] += 1
            continue
        
        # Try node cache first
        node_data = ask_nodes_for_cache(full_cache_key, timeout=2.0)
        if node_data:
            set_cached(full_cache_key, node_data)
            job['cached'] += 1
            job['done'] += 1
            continue
        
        # Fetch song info
        try:
            song_info = get_song_info(video_id)
            if not song_info:
                job['failed'] += 1
                job['done'] += 1
                continue
        except Exception as e:
            job['failed'] += 1
            job['done'] += 1
            print(f"  [PRECACHE] {video_id} song info failed: {e}")
            continue
        
        # Fetch lyrics
        try:
            if use_full:
                result = fetch_all_lyrics(video_id, song_info, translate_to, jwt_token)
            else:
                result = fetch_fast_lyrics(video_id, song_info, translate_to)
            
            if result and not is_not_found_result(result):
                set_cached(full_cache_key, result)
                job['cached'] += 1
            else:
                job['failed'] += 1
        except Exception as e:
            job['failed'] += 1
            print(f"  [PRECACHE] {video_id} fetch failed: {e}")
        
        job['done'] += 1
    
    job['status'] = 'complete'
    job['finished'] = datetime.now().isoformat()


@app.route('/api/lyrics/precache/status/<job_id>', methods=['GET'])
def api_precache_status(job_id):
    with _playlist_jobs_lock:
        job = _playlist_jobs.get(job_id)
    if not job:
        return jsonify({'error': 'not found'}), 404
    return jsonify(job)


# ============================================================
# Device provider menu: probe-as-a-job, pollable status, select-and-save
# ============================================================
# The iOS lyrics sheet cannot hold an SSE stream open easily, so probing
# runs as a background job here: POST .../providers/start, poll
# GET .../providers/status/<job_id> (candidates arrive progressively via
# the probe's on_candidate hook), then POST .../providers/select to cache
# one provider's lyrics and remember the choice per video. Live
# `probe_progress` SSE events (run_id=job_id) still broadcast for the
# dashboard, which can watch the same race.
_provider_jobs = {}
_provider_jobs_lock = threading.Lock()


def _fetch_single_provider(video_id, lang, provider, jwt_token=None):
    """Probe one provider key (exact 'Cubey/QQ' or base 'QQ'/legacy 'Cubey'),
    translate, cache, remember the choice, and return (entry, error). Entry
    is the full song-shape payload ready to serve."""
    from .jwt_pool import pick_jwt
    from .pipeline import probe_providers
    from .library import save_provider, remove_unlyriced
    from .translate import cohere_translate

    try:
        song_info = get_song_info(video_id)
    except Exception as e:
        return None, f'get_song_info failed: {e}'
    if not song_info:
        return None, 'Video not found on YouTube Music'

    jwt = jwt_token or pick_jwt()
    if jwt_token:
        _pool_contribute(jwt_token, node_id='device')
    try:
        candidates = probe_providers(video_id, song_info, jwt_token=jwt,
                                     only_source=provider)
    except Exception as e:
        return None, str(e)
    if not candidates:
        return None, f'Provider {provider} returned no lyrics'

    # Prefer the exact key the menu sent; otherwise take the best found.
    chosen = None
    for cand in candidates:
        if cand.get('provider', '').lower() == provider.lower():
            chosen = cand
            break
    if chosen is None:
        chosen = candidates[0]

    out = dict(chosen.get('data') or {})
    out['song'] = song_info.get('title', out.get('song', ''))
    out['artist'] = song_info.get('artist', out.get('artist', ''))
    lyrics = out.get('lyrics') or []
    sanitize_lyrics_parts(lyrics)
    if lang and lyrics and not any(l.get('translated') for l in lyrics):
        texts = [l['text'] for l in lyrics if l.get('text')]
        translations = cohere_translate(texts, lang)
        for i, lyric in enumerate(lyrics):
            if i < len(translations) and translations[i]:
                lyric['translated'] = translations[i]
    out['wordSynced'] = any(l.get('wordSynced') for l in lyrics)
    set_cached(f"{video_id}:{lang}", out)
    save_provider(video_id, chosen.get('provider', provider), lang)
    try:
        remove_unlyriced(video_id)
    except Exception:
        pass
    _sse_broadcast('rebase', {'state': 'done', 'applied': video_id})
    return out, None


def _run_provider_probe_job(job_id, video_id, lang, jwt_token):
    from .jwt_pool import pick_jwt
    from .pipeline import probe_providers
    from .library import get_provider
    with _provider_jobs_lock:
        job = _provider_jobs.get(job_id)
    if not job:
        return
    try:
        song_info = get_song_info(video_id)
    except Exception as e:
        job['state'] = 'error'
        job['error'] = f'get_song_info failed: {e}'
        _sse_broadcast('probe_progress', {'run_id': job_id, 'video_id': video_id,
                                          'provider': '', 'status': 'error',
                                          'detail': job['error']})
        return
    if not song_info:
        job['state'] = 'error'
        job['error'] = 'Video not found on YouTube Music'
        return
    job['song'] = song_info.get('title', '')
    job['artist'] = song_info.get('artist', '')
    job['duration'] = song_info.get('duration', 0)
    job['state'] = 'running'
    jwt = jwt_token or pick_jwt()
    if jwt_token:
        _pool_contribute(jwt_token, node_id='device')

    def on_candidate(entry):
        slim = {k: entry.get(k) for k in
                ('provider', 'source', 'synced', 'wordSynced', 'tier', 'lines', 'score')}
        job['candidates'].append(slim)
        job['candidates'].sort(key=lambda c: c.get('score', 0), reverse=True)
        job['done'] = len(job['candidates'])

    try:
        notes = []
        probe_providers(video_id, song_info, jwt_token=jwt, notes=notes,
                        run_id=job_id, on_candidate=on_candidate)
        job['notes'] = notes
        job['state'] = 'complete'
    except Exception as e:
        job['state'] = 'error'
        job['error'] = str(e)
    job['finished'] = datetime.now().isoformat()
    _sse_broadcast('probe_progress', {'run_id': job_id, 'video_id': video_id,
                                      'provider': '', 'status': job['state'],
                                      'detail': job.get('error', '')})


@app.route('/api/lyrics/providers/start', methods=['POST'])
def api_providers_start():
    """Start an async provider probe for the device menu. Body (or query):
    {video_id, lang?, jwt?}. Returns {job_id, status_url} to poll."""
    body = request.get_json(silent=True) or {}
    video_id = ((body.get('video_id') or request.args.get('v') or '').strip())
    lang = (body.get('lang') or request.args.get('lang') or 'zh-TW').strip()
    jwt_token = body.get('jwt') or request.args.get('jwt')
    if not video_id or not _safe_cache_component(video_id):
        return jsonify({'ok': False, 'error': 'Missing or invalid video_id'}), 400
    if not _safe_cache_component(lang):
        return jsonify({'ok': False, 'error': 'Invalid lang'}), 400
    from .library import get_provider
    job_id = _secrets.token_hex(8)
    job = {
        'job_id': job_id, 'state': 'queued', 'video_id': video_id,
        'lang': lang, 'song': '', 'artist': '', 'duration': 0,
        'candidates': [], 'done': 0, 'notes': [],
        'saved': (get_provider(video_id) or {}).get('provider', ''),
        'started': datetime.now().isoformat(),
    }
    with _provider_jobs_lock:
        _provider_jobs[job_id] = job
    threading.Thread(target=_run_provider_probe_job,
                     args=(job_id, video_id, lang, jwt_token), daemon=True).start()
    return jsonify({'ok': True, 'job_id': job_id,
                    'status_url': f'/api/lyrics/providers/status/{job_id}'})


@app.route('/api/lyrics/providers/status/<job_id>', methods=['GET'])
def api_providers_status(job_id):
    """Poll a provider probe job: {state, song, artist, saved, candidates[]."""
    with _provider_jobs_lock:
        job = _provider_jobs.get(job_id)
    if not job:
        return jsonify({'ok': False, 'error': 'not found'}), 404
    return jsonify({'ok': True, **job})


@app.route('/api/lyrics/providers/select', methods=['POST'])
def api_providers_select():
    """Cache one provider's lyrics now and remember the choice per video.
    Body: {video_id, lang?, provider, jwt?}. Returns the full lyrics payload
    so the client can render instantly without a second fetch."""
    body = request.get_json(silent=True) or {}
    video_id = (body.get('video_id') or '').strip()
    lang = (body.get('lang') or 'zh-TW').strip()
    provider = (body.get('provider') or '').strip()
    jwt_token = body.get('jwt')
    if not video_id or not _safe_cache_component(video_id):
        return jsonify({'ok': False, 'error': 'Missing or invalid video_id'}), 400
    if not _safe_cache_component(lang):
        return jsonify({'ok': False, 'error': 'Invalid lang'}), 400
    if not provider:
        return jsonify({'ok': False, 'error': 'Missing provider'}), 400
    entry, err = _fetch_single_provider(video_id, lang, provider, jwt_token)
    if err or not entry:
        return jsonify({'ok': False, 'error': err or 'No lyrics'}), 502
    from .translate import apply_display_transforms
    auto_zh = bool(body.get('auto_zh', False))
    if isinstance(entry.get('lyrics'), list):
        apply_display_transforms(entry['lyrics'], lang, auto_zh)
    return jsonify({'ok': True, 'video_id': video_id, 'lang': lang,
                    'provider': provider, 'data': entry})


# ============================================================
# Batch Sync: hash reconciliation + download + optional regen
# ============================================================
_sync_jobs = {}
_sync_jobs_lock = threading.Lock()
_sync_job_counter = 0


def _next_sync_job_id():
    global _sync_job_counter
    with _sync_jobs_lock:
        _sync_job_counter += 1
        return f"sync_{int(time_module.time() * 1000)}_{_sync_job_counter}"


def _compute_server_hash_for_vid_lang(video_id, translate_to, auto_zh):
    """Load server cache entry (full key), apply display transforms, return hash."""
    full_key = f"{video_id}:{translate_to}"
    data = get_cached(full_key)
    if not data:
        return None
    # Apply same transforms as serve() so hash matches client's stored data
    if isinstance(data, dict) and isinstance(data.get('lyrics'), list):
        apply_display_transforms(data['lyrics'], translate_to, auto_zh)
    return lyrics_content_hash(data.get('lyrics', []))


def _prepare_entry_for_download(data, video_id, translate_to):
    """Apply transforms and return a dict ready for client to store."""
    if not data:
        return None
    entry = dict(data)
    if isinstance(entry.get('lyrics'), list):
        apply_display_transforms(entry['lyrics'], translate_to, True)
    # Ensure required fields for client cache
    entry['videoID'] = video_id
    entry['cv'] = _CACHE_FORMAT_VERSION
    entry['ts'] = datetime.now().isoformat()
    return entry


@app.route('/api/lyrics/sync', methods=['POST'])
def api_lyrics_sync():
    """Batch hash reconciliation.
    Request: {lang, auto_zh?, entries: [{video_id, hash, cv, tier}], max_items?, regenerate?, jwt?}
    Response: {processed, ok_count, need: [{video_id, data, hash}], missing: [], job_id?, compression?}
    """
    body = request.get_json(silent=True) or {}
    translate_to = (body.get('lang') or 'zh-TW').strip()
    auto_zh = body.get('auto_zh', False)
    entries = body.get('entries', [])
    max_items = min(int(body.get('max_items', 500)), 2000)
    regenerate = bool(body.get('regenerate', True))
    jwt_token = body.get('jwt')
    if jwt_token:
        _pool_contribute(jwt_token, node_id='device')

    if not _safe_cache_component(translate_to) or not entries:
        return jsonify({'error': 'Invalid lang or empty entries'}), 400

    req_id = _secrets.token_hex(3)
    print(f"[SYNC {req_id}] {len(entries)} entries lang={translate_to} auto_zh={auto_zh} regen={regenerate}")

    need = []
    missing = []
    ok_count = 0
    regen_vids = []

    for entry in entries:
        vid = entry.get('video_id', '').strip()
        client_hash = entry.get('hash', '').strip()
        client_cv = int(entry.get('cv', 0))
        if not _safe_cache_component(vid) or not client_hash:
            continue

        # Stale format version forces upgrade regardless of hash
        if client_cv < _CACHE_FORMAT_VERSION:
            server_hash = _compute_server_hash_for_vid_lang(vid, translate_to, auto_zh)
            if server_hash:
                need.append({'video_id': vid, 'hash': server_hash})
            else:
                missing.append(vid)
                if regenerate:
                    regen_vids.append(vid)
            continue

        server_hash = _compute_server_hash_for_vid_lang(vid, translate_to, auto_zh)
        if server_hash is None:
            missing.append(vid)
            if regenerate:
                regen_vids.append(vid)
        elif server_hash != client_hash:
            need.append({'video_id': vid, 'hash': server_hash})
        else:
            ok_count += 1

    # Prepare downloadable payload for needed entries (up to max_items)
    download = []
    for item in need[:max_items]:
        vid = item['video_id']
        full_key = f"{vid}:{translate_to}"
        data = get_cached(full_key)
        if data:
            entry_data = _prepare_entry_for_download(data, vid, translate_to)
            if entry_data:
                download.append(entry_data)

    # Start background regen job if there are missing videos to regenerate
    job_id = None
    if regen_vids:
        job_id = _next_sync_job_id()
        job = {
            'job_id': job_id,
            'state': 'running',
            'total': len(regen_vids),
            'done': 0,
            'succeeded': 0,
            'failed': 0,
            'results': [],
            'lang': translate_to,
            'auto_zh': auto_zh,
            'jwt': jwt_token,
            'started': datetime.now().isoformat(),
        }
        with _sync_jobs_lock:
            _sync_jobs[job_id] = job
        threading.Thread(target=_run_sync_regen_job, args=(job_id, regen_vids, translate_to, auto_zh, jwt_token), daemon=True).start()

    return jsonify({
        'processed': len(entries),
        'ok_count': ok_count,
        'need': download,
        'missing': missing,
        'regenerating': regen_vids,
        'job_id': job_id,
        'compression': 'none',
    })


def _run_sync_regen_job(job_id, video_ids, translate_to, auto_zh, jwt_token):
    job = _sync_jobs.get(job_id)
    if not job:
        return

    for vid in video_ids:
        if job.get('state') == 'stopped':
            break
        full_key = f"{vid}:{translate_to}"
        # Re-check cache in case it appeared while job was queued
        if get_cached(full_key):
            job['done'] = job.get('done', 0) + 1
            job['succeeded'] = job.get('succeeded', 0) + 1
            job['results'].append({'video_id': vid, 'status': 'already_cached'})
            _sse_broadcast('sync_progress', {'job_id': job_id, 'video_id': vid, 'status': 'already_cached', 'done': job['done'], 'total': job['total']})
            continue

        try:
            song_info = get_song_info(vid)
            if not song_info:
                raise ValueError('get_song_info returned None')
            result = fetch_all_lyrics(vid, song_info, translate_to, jwt_token)
            if result and not is_not_found_result(result):
                set_cached(full_key, result)
                job['succeeded'] = job.get('succeeded', 0) + 1
                job['results'].append({'video_id': vid, 'status': 'regenerated', 'source': result.get('source', '')})
                _sse_broadcast('sync_progress', {'job_id': job_id, 'video_id': vid, 'status': 'regenerated', 'source': result.get('source', ''), 'done': job['done'] + 1, 'total': job['total']})
            else:
                job['failed'] = job.get('failed', 0) + 1
                job['results'].append({'video_id': vid, 'status': 'no_lyrics'})
                _sse_broadcast('sync_progress', {'job_id': job_id, 'video_id': vid, 'status': 'no_lyrics', 'done': job['done'] + 1, 'total': job['total']})
        except Exception as e:
            job['failed'] = job.get('failed', 0) + 1
            job['results'].append({'video_id': vid, 'status': 'error', 'error': str(e)})
            _sse_broadcast('sync_progress', {'job_id': job_id, 'video_id': vid, 'status': 'error', 'error': str(e), 'done': job['done'] + 1, 'total': job['total']})
            print(f"  [SYNC REGEN] {vid} failed: {e}")

        job['done'] = job.get('done', 0) + 1
        time_module.sleep(0.3)

    job['state'] = 'complete'
    job['finished'] = datetime.now().isoformat()
    _sse_broadcast('sync_progress', {'job_id': job_id, 'state': 'complete', 'succeeded': job.get('succeeded', 0), 'failed': job.get('failed', 0)})


@app.route('/api/lyrics/sync/status/<job_id>', methods=['GET'])
def api_sync_status(job_id):
    with _sync_jobs_lock:
        job = _sync_jobs.get(job_id)
    if not job:
        return jsonify({'error': 'not found'}), 404
    return jsonify(job)


@app.route('/api/lyrics/sync/stop/<job_id>', methods=['POST'])
def api_sync_stop(job_id):
    with _sync_jobs_lock:
        job = _sync_jobs.get(job_id)
        if job and job.get('state') == 'running':
            job['state'] = 'stopped'
    return jsonify({'ok': True})



