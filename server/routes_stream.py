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
from .cache import get_cached, set_cached, sanitize_lyrics_parts
from .jwt_pool import contribute_jwt as _pool_contribute
from .providers_yt import get_song_info
from .metadata import get_search_queries
from .race import (_lyrics_score, _race_cubey, _race_lrclib,
    _race_unison, _race_yt, _race_boidu, _race_binimum, _sse_event)
from .translate import cohere_translate, google_translate_fast

@app.route('/api/lyrics/stream', methods=['GET'])
def api_lyrics_stream():
    """SSE stream: parallel provider race with progressive upgrades.

    Event flow (client replaces lyrics when stage rank or score improves):
      meta    -> {song, artist, duration} once song_info resolves
      status  -> per-provider finish {provider, ok, synced, elapsed_ms}
      lyrics  -> {stage: raw|machine|final|cached, source, synced, lyrics, song, artist}
                 raw = untranslated lines pushed FIRST (never blocked on Cohere)
                 machine = Google fast translation interim
                 final = Cohere quality translation (pro/JWT path: sync pushed
                         as raw first, then re-pushed as final with translated)
      done    -> {ok, source, synced, stages} terminal event
    """
    _req_start = time_module.time()
    video_id = request.args.get('v')
    if not video_id:
        return jsonify({"error": "Missing video ID"}), 400
    translate_to = request.args.get('lang', 'zh-TW')
    if not _safe_cache_component(video_id) or not _safe_cache_component(translate_to):
        return jsonify({"error": "Invalid video ID or lang"}), 400
    jwt_token = request.args.get('jwt')
    if jwt_token:
        _pool_contribute(jwt_token, node_id='device')
    force_mode = request.args.get('force', '0') == '1'
    full_cache_key = f"{video_id}:{translate_to}"
    req_id = _secrets.token_hex(3)

    print("=" * 60)
    print(f"[REQ] [REQ {req_id}] Lyrics STREAM: {video_id} [{'JWT' if jwt_token else 'Normal'}] lang={translate_to}")
    print("=" * 60)

    def generate():
        # --- Fast path: full cache hit closes the stream immediately ---
        if not force_mode:
            cached = get_cached(full_cache_key)
            if cached:
                print(f"[OK] [REQ {req_id}] [Stream] cache hit source={cached.get('source')} lines={len(cached.get('lyrics', []))}")
                payload = dict(cached)
                payload['stage'] = 'cached'
                yield _sse_event('lyrics', payload)
                yield _sse_event('done', {'ok': True, 'source': cached.get('source'), 'synced': cached.get('synced'), 'stages': ['cached']})
                return

        # --- Song lookup (required by all providers) ---
        t_song = time_module.time()
        try:
            song_info = get_song_info(video_id)
        except Exception as e:
            yield _sse_event('done', {'ok': False, 'error': f'song lookup failed: {e}'})
            return
        if not song_info:
            yield _sse_event('done', {'ok': False, 'error': 'Could not identify song'})
            return
        title, artist = song_info['title'], song_info['artist']
        duration = song_info.get('duration', 0)
        album = song_info.get('album', '')
        print(f"[MUSIC] [REQ {req_id}] [Stream] {title} - {artist} ({duration}s) lookup={(time_module.time()-t_song)*1000:.0f}ms")
        yield _sse_event('meta', {'song': title, 'artist': artist, 'duration': duration,
                                  'lookup_ms': int((time_module.time()-t_song)*1000)})

        queries = get_search_queries(title, artist, song_info.get('ja_title', ''), song_info.get('ja_artist', ''))

        # --- Race all providers concurrently ---
        jobs = {}
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)
        try:
            if jwt_token:
                jobs[pool.submit(_race_cubey, queries, video_id, duration, jwt_token, req_id)] = 'Cubey'
            jobs[pool.submit(_race_lrclib, queries, album, duration, req_id)] = 'LRCLIB'
            jobs[pool.submit(_race_boidu, queries, album, duration, req_id)] = 'boidu'
            jobs[pool.submit(_race_binimum, queries, album, duration, req_id)] = 'Binimum'
            jobs[pool.submit(_race_unison, queries, video_id, duration, req_id)] = 'Unison'
            jobs[pool.submit(_race_yt, video_id, req_id)] = 'YouTube'

            best = None
            best_score = -1
            stages = []
            deadline = time_module.time() + 15
            pending = set(jobs.keys())
            while pending:
                remaining = max(deadline - time_module.time(), 0.1)
                try:
                    done, pending = concurrent.futures.wait(pending, timeout=remaining,
                                                            return_when=concurrent.futures.FIRST_COMPLETED)
                except Exception:
                    break
                for fut in done:
                    name = jobs.get(fut, '?')
                    try:
                        res = fut.result()
                    except Exception as e:
                        print(f"  [REQ {req_id}] [Stream] {name} worker crashed: {e}")
                        res = None
                    elapsed = int((time_module.time()-_req_start)*1000)
                    score = _lyrics_score(res)
                    yield _sse_event('status', {'provider': name, 'ok': res is not None,
                                                'synced': bool(res and res.get('synced')),
                                                'wbw_lines': _wbw_line_count(res) if res else 0,
                                                'score': round(score, 2), 'elapsed_ms': elapsed})
                    if score > best_score:
                        best_score = score
                        best = res
                        best['song'] = title
                        best['artist'] = artist
                        best['wbw_lines'] = _wbw_line_count(best)
                        payload = dict(best)
                        payload['stage'] = 'raw'
                        payload['elapsed_ms'] = elapsed
                        stages.append(f"raw:{best.get('source')}")
                        print(f"[SEND] [REQ {req_id}] [Stream] push RAW {best.get('source')} synced={best.get('synced')} lines={len(best.get('lyrics', []))} elapsed={elapsed}ms")
                        yield _sse_event('lyrics', payload)
                if time_module.time() >= deadline:
                    for fut in pending:
                        fut.cancel()
                    break

            if best is None:
                print(f"[FAIL] [REQ {req_id}] [Stream] no provider hit")
                yield _sse_event('lyrics', {'stage': 'raw', 'source': 'none', 'synced': False, 'song': title,
                                            'artist': artist, 'lyrics': [{'time': 0, 'startTimeMs': 0, 'text': 'No lyrics found', 'translated': f'找不到歌詞: {title}', 'durationMs': 0, 'duration': 0}]})
                yield _sse_event('done', {'ok': True, 'source': 'none', 'synced': False, 'stages': stages})
                return

            # --- Translation upgrades: machine interim, then Cohere final ---
            if translate_to and best.get('lyrics'):
                texts = [l.get('text', '') for l in best['lyrics'] if l.get('text')]
                # Interim: Google fast (~1s) so UI shows translation before Cohere finishes
                try:
                    machine = google_translate_fast(texts, translate_to)
                    if any(m for m in machine):
                        for i, lyric in enumerate(best['lyrics']):
                            if i < len(machine) and machine[i]:
                                lyric['translated'] = machine[i]
                        payload = dict(best)
                        payload['stage'] = 'machine'
                        payload['elapsed_ms'] = int((time_module.time()-_req_start)*1000)
                        stages.append('machine:google')
                        print(f"[SEND] [REQ {req_id}] [Stream] push MACHINE google elapsed={payload['elapsed_ms']}ms")
                        yield _sse_event('lyrics', payload)
                except Exception as e:
                    print(f"  [REQ {req_id}] [Stream] google interim failed: {e}")

                # Final: Cohere quality translation, with keepalive pings so the
                # connection survives the ~7s gap
                print(f"  [TRANS] [REQ {req_id}] [Stream] Cohere final for {len(texts)} lines...")
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as tex:
                    tf = tex.submit(cohere_translate, texts, translate_to)
                    while True:
                        try:
                            final_trans = tf.result(timeout=2)
                            break
                        except concurrent.futures.TimeoutError:
                            yield ": ping\n\n"
                    for i, lyric in enumerate(best['lyrics']):
                        if i < len(final_trans):
                            lyric['translated'] = final_trans[i]
                sanitize_lyrics_parts(best['lyrics'])
                payload = dict(best)
                payload['stage'] = 'final'
                payload['elapsed_ms'] = int((time_module.time()-_req_start)*1000)
                stages.append('final:cohere')
                print(f"[SEND] [REQ {req_id}] [Stream] push FINAL cohere lines={len(best.get('lyrics', []))} elapsed={payload['elapsed_ms']}ms")
                yield _sse_event('lyrics', payload)

            set_cached(full_cache_key, best)
            yield _sse_event('done', {'ok': True, 'source': best.get('source'), 'synced': best.get('synced'), 'stages': stages})
        finally:
            pool.shutdown(wait=False, cancel_futures=True)
        print(f"  [REQ {req_id}] [Stream] closed elapsed={(time_module.time()-_req_start)*1000:.0f}ms")
        print("=" * 60)

    return Response(stream_with_context(generate()), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no', 'Connection': 'keep-alive'})


