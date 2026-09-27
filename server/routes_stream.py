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
import queue as queue_module
from flask import Flask, request, jsonify, render_template, session, redirect, url_for, Response, stream_with_context
from .app import app
from .utils import _safe_cache_component
from .cache import get_cached, set_cached, sanitize_lyrics_parts, is_not_found_result
from .jwt_pool import contribute_jwt as _pool_contribute
from .nodes import ask_nodes_for_cache
from .providers_yt import get_song_info, yt_cover_url
from .metadata import get_search_queries
from .pipeline import fetch_all_lyrics
from .logging_util import _log_crash
from .race import (_lyrics_score, _wbw_line_count, _race_cubey, _race_lrclib,
    _race_unison, _race_yt, _race_boidu, _race_binimum, _race_amll, _sse_event)
from .translate import (cohere_translate, translate_stream,
                        google_translate_fast, apply_display_transforms,
                        _detect_song_lang)

# How long the translate worker may stay silent before the SSE connection
# gets a keepalive comment. Proxies (and Cloudflare) drop idle streams well
# before the model finishes a long song.
_TRANSLATE_PING_SECONDS = 1.5
# Bounded queue: a device that vanished mid-translation must not leave the
# worker blocked forever on put().
_TRANSLATE_QUEUE_MAX = 256


def _stream_translate(texts, target_lang, song_lang='', streaming=True, stop=None):
    """Translate `texts` on a worker thread and yield the lines as they land.

    Yields {'kind': 'line', 'i': <index into texts>, 'text': str,
    'done': bool} plus {'kind': 'ping'} keepalives, and stops after the
    worker's terminal event. The worker never outlives the consumer: `stop`
    is set in the finally block, so a disconnected client releases it.
    """
    stop = stop or threading.Event()
    q = queue_module.Queue(maxsize=_TRANSLATE_QUEUE_MAX)

    def _put(kind, payload):
        """Non-blocking put with a bounded retry: a slow client throttles the
        worker instead of stalling it, and a dead one is caught by `stop`."""
        while not stop.is_set():
            try:
                q.put_nowait((kind, payload))
                return True
            except queue_module.Full:
                time_module.sleep(0.05)
        return False

    def _worker():
        try:
            if streaming:
                for ev in translate_stream(texts, target_lang, song_lang):
                    if not _put('line', ev):
                        return
            else:
                # Blocking mode: still one event per line so the client path
                # is identical, just without the partial updates.
                for i, t in enumerate(cohere_translate(texts, target_lang, song_lang)):
                    if not _put('line', {'i': i, 'text': t, 'done': True}):
                        return
        except Exception as e:
            print(f"  [TRANS] translate worker failed: {e}")
        finally:
            try:
                q.put_nowait(('end', None))
            except queue_module.Full:
                pass

    th = threading.Thread(target=_worker, daemon=True, name='ytmu-tstream')
    th.start()
    try:
        while True:
            try:
                kind, ev = q.get(timeout=_TRANSLATE_PING_SECONDS)
            except queue_module.Empty:
                yield {'kind': 'ping'}
                continue
            if kind == 'end':
                return
            out = {'kind': 'line'}
            out.update(ev)
            yield out
    finally:
        stop.set()


def _tline_payload(lyrics, ev, text_rows, elapsed_ms):
    """Translate-line event for the wire: `i` indexes the text-bearing lines,
    `row` the real position in the lyrics array (gap rows have no text)."""
    idx = ev.get('i', -1)
    row = text_rows[idx] if 0 <= idx < len(text_rows) else -1
    return {'i': idx, 'row': row, 'text': ev.get('text', ''),
            'done': bool(ev.get('done')), 'elapsed_ms': elapsed_ms}


def _text_rows(lyrics):
    """Positions of the text-bearing lines, in the order the translator sees
    them (translate_result_in_place aligns over exactly these)."""
    return [i for i, l in enumerate(lyrics) if l.get('text')]


def _record_serve(data, video_id, translate_to, client_ip):
    """Usage stats, same tier classification /api/lyrics uses."""
    try:
        from .usage_stats import record_serve
        if is_not_found_result(data):
            return
        lyrics = data.get('lyrics') or []
        tier = ('wbw' if any(isinstance(l, dict) and l.get('wordSynced') for l in lyrics)
                else ('line' if data.get('synced') else 'plain'))
        record_serve(video_id, data.get('song', ''), data.get('artist', ''),
                     translate_to, tier, data.get('source', ''), client_ip)
    except Exception:
        pass


def _with_provider_meta(payload, video_id):
    """Arm the device switcher with the provider list (slim rows, no lyrics).
    Applied to the outgoing copy only, so the cached object stays canonical."""
    try:
        from .routes_lyrics import _provider_meta
        meta = _provider_meta(video_id)
        if meta and not payload.get('providers'):
            payload.update(meta)
    except Exception:
        pass
    return payload


@app.route('/api/lyrics/tstream', methods=['GET'])
def api_lyrics_tstream():
    """SSE: the /api/lyrics pipeline with the translation streamed line by line.

    Same work as the blocking route -- full cache gate, node cache,
    fetch_all_lyrics (which snapshots every provider it tried), disk cache,
    unlyriced record, provider meta, usage stats -- except nothing waits for
    the translator. The ranked winner is pushed as `lyrics` stage=raw the
    moment the pipeline returns, then every translated line arrives as `tline`
    while the model writes it, and `lyrics` stage=final closes the stream with
    the complete payload the device caches (identical to what /api/lyrics
    would have returned).

    Deliberately NOT registered in the in-flight gate: the device's fast
    request shares that gate with the blocking full request, so waiting on it
    would stall this stream behind a fast-grade result. Duplicate work is
    covered by the cache gate below.

    Events:
      meta    -> {song, artist, duration, lookup_ms, art, art_maxres}
                 `art` is the hq thumbnail URL, `art_maxres` the (optional,
                 404-prone) 1280x720 one; both are built from the video id
                 with no network call
      status  -> {providers: [...]} the pipeline's per-provider outcome
      lyrics  -> {stage: raw|cached|final, source, synced, lyrics, ...}
      tline   -> {i, row, text, done, elapsed_ms} one translated line
      done    -> {ok, source, synced, stages, translated} terminal event

    Query: v, lang, az, jwt, force=1, tstream=0 (blocking translate + the
    Google interim instead of the streamed one).
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
    auto_zh = request.args.get('az', '0') == '1'
    force_mode = request.args.get('force', '0') == '1'
    tstream = request.args.get('tstream', '1') == '1'
    full_cache_key = f"{video_id}:{translate_to}"
    req_id = _secrets.token_hex(3)
    client_ip = request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-IP') or request.remote_addr

    import copy as _copy

    def stream_payload(data, **extra):
        """Deep-copied payload with the per-display transforms applied, so the
        canonical object is never mutated by them."""
        payload = dict(data)
        if isinstance(payload.get('lyrics'), list):
            payload['lyrics'] = _copy.deepcopy(payload['lyrics'])
            apply_display_transforms(payload['lyrics'], translate_to, auto_zh)
        payload.update(extra)
        return _with_provider_meta(payload, video_id)

    def elapsed_ms():
        return int((time_module.time() - _req_start) * 1000)

    print("=" * 60)
    print(f"[REQ] [REQ {req_id}] Lyrics T-STREAM: {video_id} [{'JWT' if jwt_token else 'Normal'}] "
          f"lang={translate_to} tstream={int(tstream)}")
    print("=" * 60)

    def generate():
        # --- Cache gate: a full-key hit closes the stream immediately. The
        # fast key is deliberately NOT consulted here (the blocking full route
        # doesn't either: a fast-grade result would be a downgrade). ---
        if not force_mode:
            cached = get_cached(full_cache_key)
            if not cached:
                cached = ask_nodes_for_cache(full_cache_key, timeout=2.0)
                if cached:
                    set_cached(full_cache_key, cached)
                    print(f"[OK] [REQ {req_id}] [TStream] node cache hit")
            if cached:
                print(f"[OK] [REQ {req_id}] [TStream] cache hit source={cached.get('source')} "
                      f"lines={len(cached.get('lyrics', []))}")
                _record_serve(cached, video_id, translate_to, client_ip)
                yield _sse_event('lyrics', stream_payload(cached, stage='cached', elapsed_ms=elapsed_ms()))
                yield _sse_event('done', {'ok': True, 'source': cached.get('source'),
                                          'synced': cached.get('synced'),
                                          'stages': ['cached'], 'translated': True})
                return

        # --- Song lookup (required by the pipeline) ---
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
        # Art is a pure string build from the (already validated) video id, so
        # it costs nothing and adds no second metadata lookup. `art` is the
        # always-present hq frame; `art_maxres` is the 1280x720 one that 404s
        # on low-res uploads, so the client tries it and falls back.
        yield _sse_event('meta', {'song': title, 'artist': artist,
                                  'duration': song_info.get('duration', 0),
                                  'lookup_ms': int((time_module.time() - t_song) * 1000),
                                  'art': yt_cover_url(video_id, 'hq'),
                                  'art_maxres': yt_cover_url(video_id, 'max')})

        # --- The pipeline, untranslated: it used to block on Cohere here ---
        stage_log = []

        def _on_stage(name, status, detail=''):
            stage_log.append({'provider': name, 'status': status, 'detail': detail or ''})

        try:
            result = fetch_all_lyrics(video_id, song_info, None, jwt_token, on_stage=_on_stage)
        except Exception as e:
            _log_crash(type(e), e, e.__traceback__)
            yield _sse_event('done', {'ok': False, 'error': str(e)})
            return
        if not result or not result.get('lyrics'):
            yield _sse_event('done', {'ok': False, 'error': 'no lyrics'})
            return
        yield _sse_event('status', {'providers': stage_log})
        print(f"[MUSIC] [REQ {req_id}] [TStream] {title} - {artist} raw="
              f"{result.get('source')} lines={len(result['lyrics'])} elapsed={elapsed_ms()}ms")

        is_nf = is_not_found_result(result)
        if is_nf:
            try:
                from .library import record_unlyriced
                record_unlyriced(video_id, title, artist, translate_to)
            except Exception:
                pass
        yield _sse_event('lyrics', stream_payload(result, stage='raw', elapsed_ms=elapsed_ms()))

        # --- Translation, streamed ---
        stages = ['raw:' + str(result.get('source', ''))]
        translated = 0
        rows = _text_rows(result['lyrics'])
        if translate_to and rows and not is_nf:
            texts = [result['lyrics'][r]['text'] for r in rows]
            song_lang = _detect_song_lang(song_info)
            print(f"  [TRANS] [REQ {req_id}] [TStream] streaming {len(texts)} lines "
                  f"-> {translate_to} (song_lang={song_lang or '?'})")
            stop = threading.Event()
            for ev in _stream_translate(texts, translate_to, song_lang, streaming=tstream, stop=stop):
                if ev['kind'] == 'ping':
                    yield ": ping\n\n"
                    continue
                idx = ev.get('i', -1)
                if 0 <= idx < len(rows):
                    result['lyrics'][rows[idx]]['translated'] = ev.get('text', '')
                yield _sse_event('tline', _tline_payload(result['lyrics'], ev, rows, elapsed_ms()))
            # Repair: a line the stream never delivered (provider died between
            # lines) gets one blocking call, so the final payload is never
            # missing a translation the device is about to cache. "Never
            # delivered" means no text at all -- a line that came back identical
            # to its source is a real answer (Chinese lines are only
            # script-converted), not a gap.
            missing = [i for i in range(len(texts))
                       if not result['lyrics'][rows[i]].get('translated')]
            if missing:
                print(f"  [TRANS] [REQ {req_id}] [TStream] repairing {len(missing)} line(s)")
                try:
                    repair = cohere_translate([texts[i] for i in missing], translate_to, song_lang)
                    for j, i in enumerate(missing):
                        if j < len(repair) and repair[j]:
                            result['lyrics'][rows[i]]['translated'] = repair[j]
                            yield _sse_event('tline', _tline_payload(
                                result['lyrics'],
                                {'i': i, 'text': repair[j], 'done': True}, rows, elapsed_ms()))
                except Exception as e:
                    print(f"  [TRANS] [REQ {req_id}] [TStream] repair failed: {e}")
            translated = sum(1 for r in rows if result['lyrics'][r].get('translated'))
            stages.append(('stream:' if tstream else 'blocking:') + 'translate')
            print(f"[SEND] [REQ {req_id}] [TStream] push FINAL lines={translated}/{len(rows)} "
                  f"elapsed={elapsed_ms()}ms")

        sanitize_lyrics_parts(result['lyrics'])
        set_cached(full_cache_key, result)
        _record_serve(result, video_id, translate_to, client_ip)
        yield _sse_event('lyrics', stream_payload(result, stage='final', elapsed_ms=elapsed_ms()))
        yield _sse_event('done', {'ok': True, 'source': result.get('source'),
                                  'synced': result.get('synced'), 'stages': stages,
                                  'translated': translated})
        print(f"  [REQ {req_id}] [TStream] closed elapsed={elapsed_ms()}ms")
        print("=" * 60)

    return Response(stream_with_context(generate()), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no',
                             'Connection': 'keep-alive'})


@app.route('/api/lyrics/stream', methods=['GET'])
def api_lyrics_stream():
    """SSE stream: parallel provider race with progressive upgrades.

    Event flow (client replaces lyrics when stage rank or score improves):
      meta    -> {song, artist, duration, lookup_ms, art, art_maxres} once
                 song_info resolves (art = hq thumbnail URL, art_maxres the
                 404-prone 1280x720 variant; no network call)
      status  -> per-provider finish {provider, ok, synced, elapsed_ms}
      lyrics  -> {stage: raw|machine|final|cached, source, synced, lyrics, song, artist}
                 raw = untranslated lines pushed FIRST (never blocked on Cohere)
                 machine = Google fast translation interim (tstream=0 only)
                 final = complete payload (pro/JWT path: sync pushed as raw
                         first, then re-pushed as final with translated)
      tline   -> {i, row, text, done} one translated line, streamed as the
                 model writes it (tstream=1, the default)
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
    auto_zh = request.args.get('az', '0') == '1'
    full_cache_key = f"{video_id}:{translate_to}"
    req_id = _secrets.token_hex(3)

    import copy as _copy

    def stream_payload(data):
        """Deep-copied payload with per-display transforms applied, so the
        canonical `best`/cached object is never mutated by the transform."""
        payload = dict(data)
        if isinstance(payload.get('lyrics'), list):
            payload['lyrics'] = _copy.deepcopy(payload['lyrics'])
            apply_display_transforms(payload['lyrics'], translate_to, auto_zh)
        return payload

    print("=" * 60)
    print(f"[REQ] [REQ {req_id}] Lyrics STREAM: {video_id} [{'JWT' if jwt_token else 'Normal'}] lang={translate_to}")
    print("=" * 60)

    def generate():
        # --- Fast path: full cache hit closes the stream immediately ---
        if not force_mode:
            cached = get_cached(full_cache_key)
            if cached:
                print(f"[OK] [REQ {req_id}] [Stream] cache hit source={cached.get('source')} lines={len(cached.get('lyrics', []))}")
                payload = stream_payload(cached)
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
                                  'lookup_ms': int((time_module.time()-t_song)*1000),
                                  'art': yt_cover_url(video_id, 'hq'),
                                  'art_maxres': yt_cover_url(video_id, 'max')})

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
            jobs[pool.submit(_race_amll, queries, duration, req_id)] = 'AMLL'
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
                        best['wordSynced'] = best['wbw_lines'] > 0
                        payload = stream_payload(best)
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

            # --- Translation upgrades ---
            # tstream=1 (default): Cohere's own token stream, one `tline` per
            # line as the model writes it. tstream=0 restores the old shape --
            # Google interim first, then one blocking Cohere pass -- which is
            # also why the interim is skipped while streaming: two overlapping
            # fills of the same rows read as a flicker, not a speed-up.
            if translate_to and best.get('lyrics'):
                tstream = request.args.get('tstream', '1') == '1'
                rows = _text_rows(best['lyrics'])
                texts = [best['lyrics'][r]['text'] for r in rows]
                if not tstream:
                    # Interim: Google fast (~1s) so UI shows translation before Cohere finishes
                    try:
                        machine = google_translate_fast(texts, translate_to)
                        if any(m for m in machine):
                            for i, row in enumerate(rows):
                                if i < len(machine) and machine[i]:
                                    best['lyrics'][row]['translated'] = machine[i]
                            payload = stream_payload(best)
                            payload['stage'] = 'machine'
                            payload['elapsed_ms'] = int((time_module.time()-_req_start)*1000)
                            stages.append('machine:google')
                            print(f"[SEND] [REQ {req_id}] [Stream] push MACHINE google elapsed={payload['elapsed_ms']}ms")
                            yield _sse_event('lyrics', payload)
                    except Exception as e:
                        print(f"  [REQ {req_id}] [Stream] google interim failed: {e}")

                print(f"  [TRANS] [REQ {req_id}] [Stream] {'streaming' if tstream else 'blocking'} "
                      f"translate for {len(texts)} lines...")
                stop = threading.Event()
                for ev in _stream_translate(texts, translate_to, streaming=tstream, stop=stop):
                    if ev['kind'] == 'ping':
                        yield ": ping\n\n"
                        continue
                    idx = ev.get('i', -1)
                    if 0 <= idx < len(rows):
                        best['lyrics'][rows[idx]]['translated'] = ev.get('text', '')
                    yield _sse_event('tline', _tline_payload(
                        best['lyrics'], ev, rows, int((time_module.time()-_req_start)*1000)))
                sanitize_lyrics_parts(best['lyrics'])
                payload = stream_payload(best)
                payload['stage'] = 'final'
                payload['elapsed_ms'] = int((time_module.time()-_req_start)*1000)
                stages.append(('stream:' if tstream else 'final:') + 'translate')
                print(f"[SEND] [REQ {req_id}] [Stream] push FINAL lines={len(best.get('lyrics', []))} elapsed={payload['elapsed_ms']}ms")
                yield _sse_event('lyrics', payload)

            set_cached(full_cache_key, best)
            yield _sse_event('done', {'ok': True, 'source': best.get('source'), 'synced': best.get('synced'), 'stages': stages})
        finally:
            pool.shutdown(wait=False, cancel_futures=True)
        print(f"  [REQ {req_id}] [Stream] closed elapsed={(time_module.time()-_req_start)*1000:.0f}ms")
        print("=" * 60)

    return Response(stream_with_context(generate()), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no', 'Connection': 'keep-alive'})


# ============================================================
# Cover art + light metadata (no lyric providers, no race)
# ============================================================

# Art URLs are immutable for a video id, so the answer is cacheable for a day.
# The metadata half (meta=1) is a title/artist/duration lookup -- also stable
# for a given video -- so the header is the same either way.
_IMAGE_CACHE_CONTROL = 'public, max-age=86400'


@app.route('/api/lyrics/image', methods=['GET'])
def api_lyrics_image():
    """Thumbnail URLs (and optionally song/artist/duration) for one video.

    The next track has no lyrics yet when the device wants to paint it, so
    this exists to answer "what does the next song look like" WITHOUT waiting
    for -- or queueing behind -- the lyrics pipeline. Thumbnail URLs are a
    pure string build from the video id, so the default answer costs zero
    network calls and no ytmusicapi round trip.

    Query:
      v    video id (required, validated with the cache-component guard)
      q    thumbnail quality for `art`: 'hq' (default, 480x360) or 'max'
           (1280x720). Unknown values fall back to 'hq'.
      meta '1' to also run the YT Music song lookup and fill song / artist /
           duration. Optional and slow (a real ytmusicapi call, uncached --
           /api/lyrics/song is the cached variant); a failure still returns
           200 with the art URLs and empty strings, because artwork is the
           point and a 5xx would make the client retry it pointlessly.

    Response:
      {video_id, art, art_maxres, song, artist, duration}
      `art` is the URL for the requested quality; `art_maxres` is always the
      1280x720 URL, so a client that got hq can still try the upgrade itself
      (maxres 404s on low-res uploads) without asking again.
    """
    video_id = (request.args.get('v') or '').strip()
    if not video_id:
        return jsonify({"error": "Missing video ID"}), 400
    if not _safe_cache_component(video_id):
        return jsonify({"error": "Invalid video ID"}), 400
    quality = (request.args.get('q') or 'hq').strip().lower()
    if quality not in ('hq', 'max'):
        quality = 'hq'
    art = yt_cover_url(video_id, quality)
    payload = {
        'video_id': video_id,
        'art': art,
        'art_maxres': yt_cover_url(video_id, 'max'),
        'song': '',
        'artist': '',
        'duration': 0,
    }
    if request.args.get('meta', '0') == '1':
        try:
            info = get_song_info(video_id)
        except Exception as e:
            info = None
            print(f"[WARN] [Image] song lookup failed for {video_id}: {e}")
        if info:
            payload['song'] = info.get('title', '') or ''
            payload['artist'] = info.get('artist', '') or ''
            try:
                payload['duration'] = int(info.get('duration') or 0)
            except (TypeError, ValueError):
                payload['duration'] = 0
    resp = jsonify(payload)
    resp.headers['Cache-Control'] = _IMAGE_CACHE_CONTROL
    return resp


