# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Admin API routes for the library manager: cache scan, unlyriced list,
# background rebase, retitling, and cache preview.
import os
import re
import threading
import time as time_module

from flask import request, jsonify
from .app import app, login_required, _sse_broadcast
from .library import (
    scan_cache, list_unlyriced, remove_unlyriced, rebase_cached,
    retitle_song, get_rename, save_rename,
)
from .cache import get_cached, set_cached, _cache_filename, _cache_key_from_filename, sanitize_lyrics_parts, is_not_found_result
from .utils import _safe_cache_component
from .pipeline import probe_providers
from .providers_yt import get_song_info
from .translate import cohere_translate

# Module-level rebase job state
_rebase_job = {
    'job_id': None,
    'state': 'idle',
    'total': 0,
    'done': 0,
    'upgraded': 0,
    'same': 0,
    'failed': 0,
    'error': 0,
    'already': 0,
    'current': None,
    'results': [],
}
_rebase_lock = threading.Lock()
_rebase_cancel = threading.Event()

# Module-level retitle job state
_retitle_job = {
    'job_id': None,
    'state': 'idle',
    'total': 0,
    'done': 0,
    'current': None,
    'results': [],
}
_retitle_lock = threading.Lock()
_retitle_cancel = threading.Event()


@app.route('/api/admin/library/scan', methods=['GET'])
@login_required
def api_library_scan():
    try:
        result = scan_cache()
        return jsonify({'ok': True, **result})
    except Exception as e:
        print(f"[LIBRARY] [FAIL] scan: {e}")
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/admin/library/unlyriced', methods=['GET'])
@login_required
def api_library_unlyriced():
    try:
        items = list_unlyriced()
        return jsonify({'ok': True, 'count': len(items), 'items': items})
    except Exception as e:
        print(f"[LIBRARY] [FAIL] list_unlyriced: {e}")
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/admin/library/rebase/start', methods=['POST'])
@login_required
def api_rebase_start():
    with _rebase_lock:
        if _rebase_job.get('state') == 'running':
            return jsonify({'ok': False, 'error': 'already running'})
        body = request.get_json(silent=True) or {}
        mode = body.get('mode', 'cached')
        target_vid = body.get('video_id')
        _rebase_job['state'] = 'running'
        _rebase_job['job_id'] = str(int(time_module.time() * 1000))
        _rebase_job['total'] = 0
        _rebase_job['done'] = 0
        _rebase_job['upgraded'] = 0
        _rebase_job['same'] = 0
        _rebase_job['failed'] = 0
        _rebase_job['error'] = 0
        _rebase_job['already'] = 0
        _rebase_job['current'] = None
        _rebase_job['results'] = []
        _rebase_cancel.clear()

    def _run():
        try:
            if mode == 'unlyriced':
                _run_rebase_unlyriced(target_vid)
            else:
                _run_rebase_cached(target_vid)
        finally:
            with _rebase_lock:
                _rebase_job['state'] = 'done'
                _rebase_job['current'] = None
            _sse_broadcast('rebase', {'state': 'done', 'job_id': _rebase_job['job_id']})

    threading.Thread(target=_run, daemon=True).start()
    return jsonify({'ok': True, 'job_id': _rebase_job['job_id'], 'mode': mode})


def _on_rebase_result(res):
    tag = res.get('status', '?').upper()
    vid = res.get('video_id', '?')
    print(f"[REBASE] [{tag}] {vid} {res.get('from','?')}->{res.get('to','?')} "
          f"src={res.get('source','')} msg={res.get('message','')}")
    _sse_broadcast('rebase_progress', {
        'video_id': vid,
        'song': res.get('song', ''),
        'artist': res.get('artist', ''),
        'from_tier': res.get('from', ''),
        'to_tier': res.get('to', ''),
        'status': res.get('status', ''),
        'source': res.get('source', ''),
        'message': res.get('message', ''),
        'done': _rebase_job.get('done', 0),
        'total': _rebase_job.get('total', 0),
        'upgraded': _rebase_job.get('upgraded', 0),
        'same': _rebase_job.get('same', 0),
        'failed': _rebase_job.get('failed', 0),
    })


def _run_rebase_cached(target_vid=None):
    rebase_cached(
        _rebase_job, _on_rebase_result,
        cancel_event=_rebase_cancel, max_workers=8, sleep_between=0.5,
        target_vid=target_vid)


def _run_rebase_unlyriced(target_vid=None):
    from .providers_yt import get_song_info
    from .pipeline import fetch_all_lyrics
    from .cache import set_cached, is_not_found_result

    items = list_unlyriced()
    if target_vid:
        items = [i for i in items if i['video_id'] == target_vid]
    total = len(items)
    _rebase_job['total'] = total

    for item in items:
        if _rebase_cancel.is_set():
            break
        vid = item['video_id']
        song = item.get('song', '')
        artist = item.get('artist', '')
        lang = item.get('lang', 'zh-TW')
        _rebase_job['current'] = {'video_id': vid, 'song': song, 'artist': artist}

        try:
            info = get_song_info(vid)
            if not info:
                _rebase_job['done'] = _rebase_job.get('done', 0) + 1
                _rebase_job['failed'] = _rebase_job.get('failed', 0) + 1
                res = {
                    'video_id': vid, 'song': song, 'artist': artist,
                    'from': 'none', 'to': 'none', 'status': 'failed',
                    'source': '', 'message': 'get_song_info returned None',
                }
                _rebase_job['results'].append(res)
                _on_rebase_result(res)
                continue

            _sse_broadcast('rebase_progress', {
                'video_id': vid, 'song': song, 'artist': artist,
                'status': 'trying', 'message': 'fetching lyrics...',
                'done': _rebase_job.get('done', 0), 'total': total,
            })

            result = fetch_all_lyrics(vid, info, lang)
            _rebase_job['done'] = _rebase_job.get('done', 0) + 1

            if result and not is_not_found_result(result):
                full_key = f"{vid}:{lang}"
                set_cached(full_key, result)
                remove_unlyriced(vid)
                _rebase_job['upgraded'] = _rebase_job.get('upgraded', 0) + 1
                res = {
                    'video_id': vid, 'song': song, 'artist': artist,
                    'from': 'none', 'to': 'line' if result.get('synced') else 'plain',
                    'status': 'upgraded', 'source': result.get('source', ''),
                    'message': f"fresh fetch: {result.get('source','')}",
                }
            else:
                _rebase_job['failed'] = _rebase_job.get('failed', 0) + 1
                res = {
                    'video_id': vid, 'song': song, 'artist': artist,
                    'from': 'none', 'to': 'none', 'status': 'failed',
                    'source': '', 'message': 'fetch_all_lyrics returned no lyrics',
                }
            _rebase_job['results'].append(res)
            _on_rebase_result(res)
        except Exception as e:
            _rebase_job['done'] = _rebase_job.get('done', 0) + 1
            _rebase_job['error'] = _rebase_job.get('error', 0) + 1
            res = {
                'video_id': vid, 'song': song, 'artist': artist,
                'from': 'none', 'to': 'none', 'status': 'error',
                'source': '', 'message': str(e),
            }
            _rebase_job['results'].append(res)
            _on_rebase_result(res)
            print(f"[REBASE] [FAIL] unlyriced {vid}: {e}")

        time_module.sleep(0.5)

    print(f"[REBASE] [OK] unlyriced pass done: "
          f"upgraded={_rebase_job.get('upgraded',0)} "
          f"failed={_rebase_job.get('failed',0)} "
          f"error={_rebase_job.get('error',0)}")


@app.route('/api/admin/library/rebase/status', methods=['GET'])
@login_required
def api_rebase_status():
    with _rebase_lock:
        return jsonify({
            'ok': True,
            'job_id': _rebase_job.get('job_id'),
            'state': _rebase_job.get('state', 'idle'),
            'total': _rebase_job.get('total', 0),
            'done': _rebase_job.get('done', 0),
            'upgraded': _rebase_job.get('upgraded', 0),
            'same': _rebase_job.get('same', 0),
            'failed': _rebase_job.get('failed', 0),
            'error': _rebase_job.get('error', 0),
            'already': _rebase_job.get('already', 0),
            'current': _rebase_job.get('current'),
            'results': _rebase_job.get('results', []),
        })


@app.route('/api/admin/library/rebase/stop', methods=['POST'])
@login_required
def api_rebase_stop():
    _rebase_cancel.set()
    with _rebase_lock:
        if _rebase_job.get('state') == 'running':
            _rebase_job['state'] = 'stopped'
    return jsonify({'ok': True})


# ---------------------------------------------------------------
# Retitle: background job with SSE progress
# ---------------------------------------------------------------
@app.route('/api/admin/library/retitle', methods=['POST'])
@login_required
def api_retitle():
    with _retitle_lock:
        if _retitle_job.get('state') == 'running':
            return jsonify({'ok': False, 'error': 'already running'})
        body = request.get_json(silent=True) or {}
        video_id = body.get('video_id')
        song = body.get('song', '')
        artist = body.get('artist', '')
        _retitle_job['state'] = 'running'
        _retitle_job['job_id'] = str(int(time_module.time() * 1000))
        _retitle_job['total'] = 0
        _retitle_job['done'] = 0
        _retitle_job['current'] = None
        _retitle_job['results'] = []
        _retitle_cancel.clear()

    def _run():
        try:
            _run_retitle(video_id, song, artist)
        finally:
            with _retitle_lock:
                _retitle_job['state'] = 'done'
                _retitle_job['current'] = None
            _sse_broadcast('retitle', {'state': 'done', 'job_id': _retitle_job['job_id']})

    threading.Thread(target=_run, daemon=True).start()
    return jsonify({'ok': True, 'job_id': _retitle_job['job_id']})


@app.route('/api/admin/library/retitle/status', methods=['GET'])
@login_required
def api_retitle_status():
    with _retitle_lock:
        return jsonify({
            'ok': True,
            'job_id': _retitle_job.get('job_id'),
            'state': _retitle_job.get('state', 'idle'),
            'total': _retitle_job.get('total', 0),
            'done': _retitle_job.get('done', 0),
            'current': _retitle_job.get('current'),
            'results': _retitle_job.get('results', []),
        })


def _run_retitle(video_id, song, artist):
    from .pipeline import fetch_all_lyrics
    from .providers_yt import get_song_info as yt_get_song_info
    from .cache import set_cached, is_not_found_result

    if video_id:
        items = [i for i in list_unlyriced() if i['video_id'] == video_id]
        if not items:
            items = [{'video_id': video_id, 'song': song, 'artist': artist, 'lang': 'zh-TW'}]
    else:
        items = list_unlyriced()

    total = len(items)
    _retitle_job['total'] = total

    for item in items:
        if _retitle_cancel.is_set():
            break
        vid = item['video_id']
        orig_song = song or item.get('song', '')
        orig_artist = artist or item.get('artist', '')
        lang = item.get('lang', 'zh-TW')
        _retitle_job['current'] = {'video_id': vid, 'song': orig_song, 'artist': orig_artist}

        _sse_broadcast('retitle_progress', {
            'video_id': vid, 'song': orig_song, 'artist': orig_artist,
            'status': 'retitling', 'message': 'calling LLM...',
            'done': _retitle_job.get('done', 0), 'total': total,
        })

        cleaned = retitle_song(orig_song, orig_artist)
        new_title = cleaned.get('title', orig_song)
        new_artist = cleaned.get('artist', orig_artist)

        entry = {
            'video_id': vid,
            'old': {'title': orig_song, 'artist': orig_artist},
            'new': {'title': new_title, 'artist': new_artist},
            'status': 'retitle_only',
        }

        _sse_broadcast('retitle_progress', {
            'video_id': vid, 'song': orig_song, 'artist': orig_artist,
            'new_title': new_title, 'new_artist': new_artist,
            'status': 'fetching', 'message': f"trying with cleaned title...",
            'done': _retitle_job.get('done', 0), 'total': total,
        })

        try:
            fake_info = {
                'title': new_title,
                'artist': new_artist,
                'album': '',
                'duration': 0,
                'ja_title': '',
                'ja_artist': '',
            }
            result = fetch_all_lyrics(vid, fake_info, lang)
            if result and not is_not_found_result(result):
                full_key = f"{vid}:{lang}"
                set_cached(full_key, result)
                remove_unlyriced(vid)
                entry['status'] = 'retitled_and_cached'
                entry['source'] = result.get('source', '')
            else:
                entry['status'] = 'retitled_no_lyrics'
        except Exception as e:
            entry['status'] = 'retitled_fetch_error'
            entry['error'] = str(e)
            print(f"[LIBRARY] [FAIL] retitle fetch {vid}: {e}")

        _retitle_job['done'] = _retitle_job.get('done', 0) + 1
        _retitle_job['results'].append(entry)
        _sse_broadcast('retitle_progress', {
            'video_id': vid, 'song': orig_song, 'artist': orig_artist,
            'new_title': new_title, 'new_artist': new_artist,
            'status': entry['status'], 'source': entry.get('source', ''),
            'done': _retitle_job.get('done', 0), 'total': total,
        })

        time_module.sleep(0.5)

    print(f"[LIBRARY] [OK] retitle done: {len(_retitle_job.get('results',[]))} processed")


@app.route('/api/admin/cache/preview', methods=['GET'])
@login_required
def api_cache_preview():
    video_id = request.args.get('v', '')
    lang = request.args.get('lang') or 'zh-TW'
    if not video_id:
        return jsonify({'error': 'Missing v or lang'}), 400

    full_key = f"{video_id}:{lang}"
    fast_key = f"{full_key}:fast"

    data = get_cached(full_key)
    if data is None:
        data = get_cached(fast_key)
    if data is None:
        # Try reading raw file even if expired (for preview)
        for key in [full_key, fast_key]:
            fpath = f"cache/lyrics/{_cache_filename(key)}.json"
            if os.path.exists(fpath):
                try:
                    import json as _json
                    with open(fpath, 'r', encoding='utf-8') as f:
                        entry = _json.load(f)
                    cand = entry.get('data', {})
                    if is_not_found_result(cand):
                        continue
                    if cand and cand.get('lyrics'):
                        sanitize_lyrics_parts(cand['lyrics'])
                    data = cand
                    print(f"[LIBRARY] [OK] cache preview raw fallback key={key}")
                    break
                except Exception as e:
                    print(f"[LIBRARY] [FAIL] cache preview fallback {key}: {e}")

    if data is None:
        # On-demand fetch: try pipeline if not cached
        try:
            from .pipeline import fetch_all_lyrics
            from .jwt_pool import pick_jwt
            jwt_token = pick_jwt()
            print(f"[LIBRARY] [OK] cache preview on-demand fetch v={video_id} lang={lang}")
            data = fetch_all_lyrics(video_id, lang=lang, jwt_token=jwt_token)
            if data and data.get('lyrics') and not is_not_found_result(data):
                from .cache import set_cached
                set_cached(f"{video_id}:{lang}", data)
                print(f"[LIBRARY] [OK] cache preview on-demand cached v={video_id}")
            elif data is None or is_not_found_result(data):
                return jsonify({'error': 'Not found for this video'}), 404
        except Exception as e:
            print(f"[LIBRARY] [FAIL] cache preview on-demand fetch v={video_id}: {e}")
            return jsonify({'error': 'Not cached'}), 404

    lyrics = data.get('lyrics', []) or []
    wbw = any(l.get('wordSynced') for l in lyrics)
    if wbw:
        tier = 'wbw'
    elif data.get('synced'):
        tier = 'line'
    else:
        tier = 'plain'
    resp = dict(data)
    if resp.get('wordSynced') is None:
        resp['wordSynced'] = wbw
    resp['tier'] = tier
    return jsonify(resp)


# ===============================================================
# Refetch from URL / custom rename: probe every provider, pick one
# ===============================================================
_VIDEO_ID_RE = re.compile(r'(?:youtube(?:-nocookie)?\.com/(?:watch\?(?:.*&)?v=|embed/|v/|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})')
_VIDEO_ID_PARAM_RE = re.compile(r'[?&]v=([A-Za-z0-9_-]{11})')


def _extract_video_id(text):
    """Accept a full YouTube/YouTube Music URL or a bare 11-char video ID."""
    text = (text or '').strip()
    if not text:
        return None
    m = _VIDEO_ID_RE.search(text)
    if m:
        return m.group(1)
    m = _VIDEO_ID_PARAM_RE.search(text)
    if m:
        return m.group(1)
    if re.fullmatch(r'[A-Za-z0-9_-]{11}', text):
        return text
    return None


def _info_with_rename(video_id, info, custom_title=None, custom_artist=None):
    """Apply a manual rename (custom beats saved beats fetched) and persist a
    new override only when the user explicitly typed title/artist."""
    saved = get_rename(video_id) or {}
    t = (custom_title or saved.get('title') or '').strip() or info.get('title', '')
    a = (custom_artist or saved.get('artist') or '').strip() or info.get('artist', '')
    if custom_title or custom_artist:
        save_rename(video_id, t, a)
    info['title'] = t
    info['artist'] = a
    return info


def _candidate_tier(cand):
    if cand.get('wordSynced'):
        return 'wbw'
    if cand.get('synced'):
        return 'line'
    return 'plain'


@app.route('/api/admin/library/probe', methods=['POST'])
@login_required
def api_probe():
    """Refetch lyrics for one video, showing every provider's best result so
    the admin can check each one and pick. Body: {url? or video_id?, lang?,
    title?, artist?, source?} -- title/artist are the custom rename override;
    source limits the probe to a single provider name. Returns {ok, video_id,
    song, artist, duration, renamed, candidates:[...]} sorted best-first."""
    body = request.get_json(silent=True) or {}
    video_id = _extract_video_id(body.get('url') or body.get('video_id') or '')
    if not video_id:
        return jsonify({'ok': False, 'error': 'Missing or invalid video URL/ID'}), 400
    lang = body.get('lang') or 'zh-TW'
    if not _safe_cache_component(lang):
        return jsonify({'ok': False, 'error': 'Invalid lang'}), 400
    only_source = (body.get('source') or '').strip() or None

    try:
        info = get_song_info(video_id)
    except Exception as e:
        return jsonify({'ok': False, 'error': f'get_song_info failed: {e}'}), 502
    if not info:
        return jsonify({'ok': False, 'error': 'Video not found on YouTube Music'}), 404

    saved = get_rename(video_id) or {}
    info = _info_with_rename(video_id, info,
                             custom_title=(body.get('title') or '').strip(),
                             custom_artist=(body.get('artist') or '').strip())
    renamed = bool(saved) or bool((body.get('title') or '').strip() or (body.get('artist') or '').strip())

    try:
        from .jwt_pool import pick_jwt
        candidates = probe_providers(video_id, info, jwt_token=pick_jwt(), only_source=only_source)
    except Exception as e:
        print(f"[LIBRARY] [FAIL] probe {video_id}: {e}")
        return jsonify({'ok': False, 'error': str(e)}), 500

    return jsonify({
        'ok': True,
        'video_id': video_id,
        'song': info.get('title', ''),
        'artist': info.get('artist', ''),
        'duration': info.get('duration', 0),
        'lang': lang,
        'renamed': renamed,
        'candidates': candidates,
    })


@app.route('/api/admin/library/probe/apply', methods=['POST'])
@login_required
def api_probe_apply():
    """Cache one chosen probe candidate. Body: {video_id, lang, source, data,
    title?, artist?}. Translates for the target lang (unless already
    translated), persists a manual rename when title/artist are given, writes
    the cache, and drops the video from the unlyriced list."""
    body = request.get_json(silent=True) or {}
    video_id = (body.get('video_id') or '').strip()
    lang = body.get('lang') or 'zh-TW'
    source = (body.get('source') or '').strip()
    data = body.get('data')
    if not video_id or not isinstance(data, dict) or not data.get('lyrics'):
        return jsonify({'ok': False, 'error': 'Missing video_id or candidate data'}), 400
    if not _safe_cache_component(lang):
        return jsonify({'ok': False, 'error': 'Invalid lang'}), 400

    try:
        info = get_song_info(video_id)
    except Exception:
        info = None
    base = dict(info or {})
    base = _info_with_rename(video_id, base,
                             custom_title=(body.get('title') or '').strip(),
                             custom_artist=(body.get('artist') or '').strip())

    out = dict(data)
    out['song'] = base.get('title', out.get('song', ''))
    out['artist'] = base.get('artist', out.get('artist', ''))
    if source:
        out['source'] = source
    lyrics = out.get('lyrics') or []
    sanitize_lyrics_parts(lyrics)

    has_translated = any(l.get('translated') for l in lyrics)
    if lang and lyrics and not has_translated:
        print(f"  [APPLY] translating {len(lyrics)} lines for {lang}...")
        texts = [l['text'] for l in lyrics if l.get('text')]
        translations = cohere_translate(texts, lang)
        for i, lyric in enumerate(lyrics):
            if i < len(translations) and translations[i]:
                lyric['translated'] = translations[i]

    out['wordSynced'] = any(l.get('wordSynced') for l in lyrics)
    set_cached(f"{video_id}:{lang}", out)
    remove_unlyriced(video_id)
    _sse_broadcast('rebase', {'state': 'done', 'applied': video_id})

    return jsonify({
        'ok': True,
        'video_id': video_id,
        'song': out['song'],
        'artist': out['artist'],
        'source': out.get('source', ''),
        'tier': _candidate_tier(out),
        'lines': len(lyrics),
        'lang': lang,
        'renamed': bool((body.get('title') or '').strip() or (body.get('artist') or '').strip()),
        'data': out,
    })
