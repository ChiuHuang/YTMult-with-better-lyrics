# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Admin API routes for the library manager: cache scan, unlyriced list,
# background rebase, retitling, and cache preview.
import os
import threading
import time as time_module

from flask import request, jsonify
from .app import app, login_required
from .library import (
    scan_cache, list_unlyriced, remove_unlyriced, rebase_cached,
    retitle_song,
)
from .cache import get_cached, _cache_filename, _cache_key_from_filename, sanitize_lyrics_parts, is_not_found_result

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
                _run_rebase_unlyriced()
            else:
                _run_rebase_cached()
        finally:
            with _rebase_lock:
                _rebase_job['state'] = 'done'
                _rebase_job['current'] = None

    threading.Thread(target=_run, daemon=True).start()
    return jsonify({'ok': True, 'job_id': _rebase_job['job_id'], 'mode': mode})


def _on_rebase_result(res):
    tag = res.get('status', '?').upper()
    vid = res.get('video_id', '?')
    print(f"[REBASE] [{tag}] {vid} {res.get('from','?')}->{res.get('to','?')} "
          f"src={res.get('source','')} msg={res.get('message','')}")


def _run_rebase_cached():
    rebase_cached(
        _rebase_job, _on_rebase_result,
        cancel_event=_rebase_cancel, max_workers=8, sleep_between=0.5)


def _run_rebase_unlyriced():
    from .providers_yt import get_song_info
    from .pipeline import fetch_all_lyrics
    from .cache import set_cached, is_not_found_result

    items = list_unlyriced()
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
                _rebase_job['results'].append({
                    'video_id': vid, 'song': song, 'artist': artist,
                    'from': 'none', 'to': 'none', 'status': 'failed',
                    'source': '', 'message': 'get_song_info returned None',
                })
                continue

            result = fetch_all_lyrics(vid, info, lang)
            _rebase_job['done'] = _rebase_job.get('done', 0) + 1

            if result and not is_not_found_result(result):
                full_key = f"{vid}:{lang}"
                set_cached(full_key, result)
                remove_unlyriced(vid)
                _rebase_job['upgraded'] = _rebase_job.get('upgraded', 0) + 1
                _rebase_job['results'].append({
                    'video_id': vid, 'song': song, 'artist': artist,
                    'from': 'none', 'to': 'line' if result.get('synced') else 'plain',
                    'status': 'upgraded', 'source': result.get('source', ''),
                    'message': f"fresh fetch: {result.get('source','')}",
                })
            else:
                _rebase_job['failed'] = _rebase_job.get('failed', 0) + 1
                _rebase_job['results'].append({
                    'video_id': vid, 'song': song, 'artist': artist,
                    'from': 'none', 'to': 'none', 'status': 'failed',
                    'source': '', 'message': 'fetch_all_lyrics returned no lyrics',
                })
        except Exception as e:
            _rebase_job['done'] = _rebase_job.get('done', 0) + 1
            _rebase_job['error'] = _rebase_job.get('error', 0) + 1
            _rebase_job['results'].append({
                'video_id': vid, 'song': song, 'artist': artist,
                'from': 'none', 'to': 'none', 'status': 'error',
                'source': '', 'message': str(e),
            })
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


@app.route('/api/admin/library/retitle', methods=['POST'])
@login_required
def api_retitle():
    body = request.get_json(silent=True) or {}
    video_id = body.get('video_id')
    song = body.get('song', '')
    artist = body.get('artist', '')

    from .pipeline import fetch_all_lyrics
    from .providers_yt import get_song_info as yt_get_song_info
    from .cache import set_cached, is_not_found_result

    retitled = []

    if video_id:
        items = [i for i in list_unlyriced() if i['video_id'] == video_id]
        if not items:
            items = [{'video_id': video_id, 'song': song, 'artist': artist, 'lang': 'zh-TW'}]
    else:
        items = list_unlyriced()

    for item in items:
        vid = item['video_id']
        orig_song = song or item.get('song', '')
        orig_artist = artist or item.get('artist', '')
        lang = item.get('lang', 'zh-TW')

        cleaned = retitle_song(orig_song, orig_artist)
        new_title = cleaned.get('title', orig_song)
        new_artist = cleaned.get('artist', orig_artist)

        entry = {
            'video_id': vid,
            'old': {'title': orig_song, 'artist': orig_artist},
            'new': {'title': new_title, 'artist': new_artist},
            'status': 'retitle_only',
        }

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

        retitled.append(entry)
        time_module.sleep(0.5)

    return jsonify({'ok': True, 'retitled': retitled})


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
