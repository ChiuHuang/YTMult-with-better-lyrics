# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
import functools
import json
import os
import re
import sys
import queue
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
from .app import (app, login_required, _admin_cfg, _save_admin_config,
    SERVER_INSTANCE_ID,
    SERVER_START_TIME, SERVER_START_TS, LOG_DIR, CRASH_LOG_FILE,
    _recent_logs, _structured_logs, _recent_requests, _crash_logs,
    _sse_subscribers, _sse_subscribers_lock)
from .nodes import (_load_nodes, _mutate_nodes, _hash_node_key,
    connected_nodes, _connected_nodes_lock)
from .jwt_pool import contribute_jwt, list_jwt, remove_jwt, check_all as jwt_check_all
from .jwt_push import push as _jwt_push, ensure_key as _jwt_push_key, key_ok as _push_key_ok
from .self_update import SELF_UPDATE_REPO, SELF_UPDATE_BRANCH, SELF_UPDATE_REMOTE_PATH
from .cache import clear_not_found_caches
from .cache import _cache_key_from_filename
from .paths import LYRICS_DIR, TRANSLATE_DIR
from .library import get_rename, apply_lyrics_payload
from .self_update import (_get_local_sha, _get_remote_sha, _fetch_remote_file,
    _perform_self_update, _get_main_file)
from .logging_util import _log_crash
from .latency_stats import snapshot as latency_snapshot

@app.route('/login', methods=['GET', 'POST'])
def login():
    if not _admin_cfg.get('password_hash'):
        return redirect(url_for('setup'))
    error = None
    if request.method == 'POST':
        pw = request.form.get('password', '')
        if hashlib.sha256(pw.encode()).hexdigest() == _admin_cfg['password_hash']:
            session['admin_logged_in'] = True
            return redirect(url_for('dashboard'))
        error = 'Wrong password.'
    return render_template('login.html', error=error)


@app.route('/setup', methods=['GET', 'POST'])
def setup():
    # Only accessible when no password is configured yet
    if _admin_cfg.get('password_hash'):
        return redirect(url_for('login'))
    error = None
    if request.method == 'POST':
        pw = request.form.get('password', '').strip()
        pw2 = request.form.get('password2', '').strip()
        if not pw:
            error = 'Password cannot be empty.'
        elif pw != pw2:
            error = 'Passwords do not match.'
        else:
            _admin_cfg['password_hash'] = hashlib.sha256(pw.encode()).hexdigest()
            _save_admin_config(_admin_cfg)
            session['admin_logged_in'] = True
            return redirect(url_for('dashboard'))
    return render_template('setup.html', error=error)


@app.route('/logout', methods=['POST'])
def logout():
    session.clear()
    return jsonify({'ok': True})


@app.route('/')
@login_required
def dashboard():
    # instance_id cache-busts dash.js (?v=) so a deploy/restart always runs
    # the matching frontend (stale cached JS = missing SSE listeners).
    return render_template('index.html', instance_id=SERVER_INSTANCE_ID)


@app.route('/api/admin/logs', methods=['GET'])
@login_required
def admin_logs():
    after_idx = request.args.get('after', type=int, default=-1)
    logs_list = list(_structured_logs)
    if after_idx >= 0 and after_idx < len(logs_list):
        logs_list = logs_list[after_idx + 1:]
    return jsonify({'logs': logs_list, 'total': len(_structured_logs)})


@app.route('/api/admin/logs/clear', methods=['POST'])
@login_required
def admin_logs_clear():
    _recent_logs.clear()
    _structured_logs.clear()
    return jsonify({'ok': True})


# ---------------------------------------------------------------
# App settings (tweak remote config): dashboard CRUD, values served
# publicly at GET /api/app/settings (routes_misc).
# ---------------------------------------------------------------
@app.route('/api/admin/app/settings', methods=['GET'])
@login_required
def admin_app_settings():
    """The typed view: schema + effective value + override flags. One payload
    so the dashboard never has to reconcile two responses."""
    from .app_settings import describe
    return jsonify({'ok': True, **describe()})


@app.route('/api/admin/app/settings/raw', methods=['GET'])
@login_required
def admin_app_settings_raw():
    """The flat merged map, for scripts. No schema, no override flags."""
    from .app_settings import get_all
    return jsonify({'ok': True, 'settings': get_all()})


@app.route('/api/admin/app/settings', methods=['POST'])
@login_required
def admin_app_settings_set():
    """Set one key. Body: {key, value: string|number|boolean}.

    Accepts either a single {key, value} or a bulk {values: {key: value, ...}}
    so the dashboard can save a whole group in one request. Every response
    returns the same describe() payload the GET does, so the UI re-renders
    from one round trip."""
    from .app_settings import set_one, set_many, describe
    body = request.get_json(silent=True) or {}
    bulk = body.get('values')
    try:
        if isinstance(bulk, dict):
            set_many(bulk)
        else:
            set_one(body.get('key'), body.get('value'))
    except (ValueError, TypeError) as e:
        return jsonify({'ok': False, 'error': str(e)}), 400
    return jsonify({'ok': True, **describe()})


@app.route('/api/admin/app/settings', methods=['DELETE'])
@login_required
def admin_app_settings_del():
    """Delete one override key (defaults still apply). Body: {key}."""
    from .app_settings import delete_one, describe
    body = request.get_json(silent=True) or {}
    try:
        removed = delete_one(body.get('key') or '')
    except (ValueError, TypeError) as e:
        # Same 400 as POST: a malformed key is a client error, and the 500
        # handler would report it as a crash.
        return jsonify({'ok': False, 'error': str(e)}), 400
    return jsonify({'ok': True, 'removed': removed, **describe()})


@app.route('/api/admin/app/settings/reset', methods=['POST'])
@login_required
def admin_app_settings_reset():
    """Drop every override. There is no undo, so the dashboard confirms first."""
    from .app_settings import reset_defaults, describe
    reset_defaults()
    return jsonify({'ok': True, **describe()})


# ---------------------------------------------------------------
# Targeted kill switch (build sha -> action). The flat keys above are
# "every device, every build"; these are "these builds, these keys".
# Rules live in server/kill_switch.py and are folded into the map at serve
# time, so GET /api/app/settings?sha=... returns an already-resolved verdict.
# ---------------------------------------------------------------
@app.route('/api/admin/kill/targets', methods=['GET'])
@login_required
def admin_kill_targets():
    """Active targets + the build picker data, in one payload: the counts shown
    next to each build have to come from the same instant as the list, and two
    round trips let them disagree."""
    from .kill_switch import describe_targets, options
    return jsonify({'ok': True, 'targets': describe_targets(), **options()})


@app.route('/api/admin/kill/targets', methods=['POST'])
@login_required
def admin_kill_target_add():
    """Create one target.

    Body: exactly one selector, plus an action.
      selector  {sha} | {tag} | {from_sha, to_sha} | {} for every build
      action    scope 'lg' (every V2 surface) | 'tweak' (the whole glass
                stack) | 'surface' (+ key, one of the schema's device keys)
      note      free text, shown in the list, max 200 chars
    A selector that resolves to nothing is a 400, not a stored row that looks
    armed: a tag or range endpoint that is not in the history kills nobody and
    would sit in the UI doing nothing."""
    from .kill_switch import add_target, describe_targets, options
    try:
        target = add_target(request.get_json(silent=True) or {})
    except (ValueError, TypeError) as e:
        return jsonify({'ok': False, 'error': str(e)}), 400
    print(f"[KILL] [OK] target {target['id']} scope={target['scope']} "
          f"selector={target.get('sha') or target.get('tag') or (target.get('from_sha'), target.get('to_sha'))}")
    return jsonify({'ok': True, 'targets': describe_targets(), **options()})


@app.route('/api/admin/kill/targets', methods=['DELETE'])
@login_required
def admin_kill_target_del():
    """Remove one target by id. Body: {id}."""
    from .kill_switch import describe_targets, options, remove_target
    body = request.get_json(silent=True) or {}
    try:
        removed = remove_target(body.get('id'))
    except (ValueError, TypeError) as e:
        return jsonify({'ok': False, 'error': str(e)}), 400
    if not removed:
        return jsonify({'ok': False, 'error': 'no such target'}), 404
    print(f"[KILL] target removed: {body.get('id')}")
    return jsonify({'ok': True, 'removed': True, 'targets': describe_targets(), **options()})


@app.route('/api/admin/kill/preview', methods=['GET'])
@login_required
def admin_kill_preview():
    """Dry run for one build: which targets fire and which keys end up off.
    The dashboard calls this as the operator picks a build, because the whole
    cost of a wrong target is discovered by users rather than by us.
    Query: sha=<build sha>"""
    from .kill_switch import preview
    return jsonify({'ok': True, **preview(request.args.get('sha') or '')})


@app.route('/api/admin/caches', methods=['GET'])
@login_required
def admin_caches():
    lyrics_dir = LYRICS_DIR
    items = []
    if os.path.exists(lyrics_dir):
        for fname in sorted(os.listdir(lyrics_dir),
                            key=lambda f: os.path.getmtime(os.path.join(lyrics_dir, f)),
                            reverse=True):
            cache_key = _cache_key_from_filename(fname)
            if cache_key is None:
                continue
            fpath = os.path.join(lyrics_dir, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    entry = json.load(f)
                data = entry.get('data', {})
                ts_str = entry.get('ts', '')
                try:
                    ts = datetime.fromisoformat(ts_str)
                    diff = (datetime.now() - ts).total_seconds()
                    if diff < 3600:
                        time_ago = f"{int(diff // 60)}m ago"
                    elif diff < 86400:
                        time_ago = f"{int(diff // 3600)}h ago"
                    else:
                        time_ago = f"{int(diff // 86400)}d ago"
                except Exception:
                    time_ago = 'unknown'
                parts = cache_key.split(':')
                video_id = parts[0]
                lang = parts[1] if len(parts) > 1 else ''
                is_fast = cache_key.endswith(':fast')
                _rn = get_rename(video_id) or {}
                _rn_t = (_rn.get('title') or '').strip()
                _rn_a = (_rn.get('artist') or '').strip()
                items.append({
                    'video_id': video_id,
                    'lang': lang,
                    'cache_key': cache_key,
                    'song': data.get('song', ''),
                    'artist': data.get('artist', ''),
                    'source': data.get('source', '?'),
                    'synced': data.get('synced', False),
                    'lines': len(data.get('lyrics', [])),
                    'time_ago': time_ago,
                    'rename': {'title': _rn_t, 'artist': _rn_a} if (_rn_t or _rn_a) else None,
                    '_is_fast': is_fast,
                })
            except Exception:
                pass
    best = {}
    for item in items:
        vid = item['video_id']
        if vid not in best:
            best[vid] = item
            continue
        prev = best[vid]
        if prev['_is_fast'] and not item['_is_fast']:
            best[vid] = item
        elif prev['_is_fast'] == item['_is_fast'] and item['lines'] > prev['lines']:
            best[vid] = item
    result = [{k: v for k, v in item.items() if not k.startswith('_')} for item in best.values()]
    return jsonify(result)


@app.route('/api/admin/caches/clear_empty', methods=['POST'])
@login_required
def admin_clear_empty_caches():
    lyrics_dir = LYRICS_DIR
    removed = 0
    if os.path.exists(lyrics_dir):
        for fname in os.listdir(lyrics_dir):
            if _cache_key_from_filename(fname) is None:
                continue
            fpath = os.path.join(lyrics_dir, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    entry = json.load(f)
                if is_not_found_result(entry.get('data')):
                    os.remove(fpath)
                    removed += 1
            except Exception:
                pass
    return jsonify({'cleared': removed})


@app.route('/api/admin/nodes', methods=['GET'])
@login_required
def admin_nodes_list():
    nodes = _load_nodes()
    with _connected_nodes_lock:
        online_ids = set(connected_nodes.keys())
        live_ips = {nid: entry.get('ip', '') for nid, entry in connected_nodes.items()}
    items = []
    for node_id, rec in nodes.items():
        items.append({
            'node_id': node_id,
            'label': rec.get('label', ''),
            'created': rec.get('created', ''),
            'last_seen': rec.get('last_seen'),
            'ip': live_ips.get(node_id) or rec.get('last_ip', ''),
            'online': node_id in online_ids,
            'jwt_sync': rec.get('jwt_sync', True) is not False,
        })
    items.sort(key=lambda x: x['created'], reverse=True)
    return jsonify({'nodes': items})


def _render_node_script(node_id, node_key):
    """Personalize the node.py template for one node. The node_key here is the
    RAW key -- it only exists in the response and in the node's own copy of the
    script; the server persists only its hash. Never store the key server-side."""
    template_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'node.py')
    with open(template_path, 'r', encoding='utf-8') as f:
        script = f.read()

    # Behind an HTTPS reverse proxy (pterodactyl/nginx) Flask's is_secure is
    # False, so plain ws:// URLs get 301'd to wss:// and websocket-client
    # rejects the scheme switch. Trust X-Forwarded-Proto too.
    xfp = request.headers.get('X-Forwarded-Proto', '')
    scheme = 'wss' if (request.is_secure or xfp == 'https') else 'ws'
    ws_url = f"{scheme}://{request.host}/ws/node"
    script = script.replace('__SERVER_WS_URL__', ws_url)
    script = script.replace('__NODE_ID__', node_id)
    script = script.replace('__NODE_KEY__', node_key)
    return script


@app.route('/api/admin/nodes/generate', methods=['POST'])
@login_required
def admin_nodes_generate():
    body = request.get_json(silent=True) or {}
    label = body.get('label') or request.form.get('label', '') or ''

    node_id = _secrets.token_hex(8)
    node_key = _secrets.token_hex(32)

    def _add(nd):
        nd[node_id] = {
            'key_hash': _hash_node_key(node_key),
            'label': label,
            'created': datetime.now().isoformat(),
            'last_seen': None,
        }
        return True

    # One lock + fresh read: a concurrent pong / generate used to save its own
    # stale copy of the registry and erase this record, so the node.py we are
    # about to hand out was rejected with "(bad key)" forever.
    _mutate_nodes(_add)

    script = _render_node_script(node_id, node_key)

    xfp = request.headers.get('X-Forwarded-Proto', '')
    scheme = 'wss' if (request.is_secure or xfp == 'https') else 'ws'
    ws_url = f"{scheme}://{request.host}/ws/node"
    http_url = f"{'https' if (request.is_secure or xfp == 'https') else 'http'}://{request.host}"

    import base64
    script_b64 = base64.b64encode(script.encode()).decode()

    # No admin password needed: the node authenticates with its node_id +
    # node_key via the keyed /generate endpoint (same as self-update does).
    deploy_one_liner = (
        f'curl -fsSL "{http_url}/deploy.sh" | bash -s -- '
        f'--server="{http_url}" --label="{label or "node"}" '
        f'--node-id="{node_id}" --node-key="{node_key}"'
    )

    return jsonify({
        'ok': True,
        'node_id': node_id,
        'node_key': node_key,
        'ws_url': ws_url,
        'server_url': http_url,
        'script_b64': script_b64,
        'filename': f'node_{node_id}.py',
        'deploy_one_liner': deploy_one_liner,
    })


# Backwards-compat with node builds before 6b2ab34: they derived the
# self-update URL from SERVER_WS_URL, producing /ws/node/api/admin/nodes/
# generate/<id>. Mapping both paths to the same handler lets an outdated node
# refetch the fixed script itself; after that its _http_base() drops the
# /ws/node prefix and only ever uses the canonical /api/... path.
@app.route('/api/admin/nodes/generate/<node_id>', methods=['GET'])
@app.route('/ws/node/api/admin/nodes/generate/<node_id>', methods=['GET'])
def admin_nodes_regenerate(node_id):
    key = request.args.get('key', '')
    record = _load_nodes().get(node_id)
    if not record or not key or record.get('key_hash') != _hash_node_key(key):
        return jsonify({'error': 'invalid node_id or key'}), 403
    _mutate_nodes(lambda nd: nd[node_id].__setitem__(
        'last_seen', datetime.now().isoformat()) if node_id in nd else False)
    script = _render_node_script(node_id, key)
    resp = Response(script, mimetype='text/x-python')
    resp.headers['Content-Disposition'] = f'attachment; filename="node_{node_id}.py"'
    return resp


@app.route('/api/admin/nodes/<node_id>/jwt_sync', methods=['POST'])
@login_required
def admin_nodes_jwt_sync(node_id):
    """Per-node opt-out for the Cubey pool push. Turning it ON for a node that
    is already connected pushes immediately instead of waiting for the next
    60s tick; turning it OFF stops the next push but does NOT erase what the
    node already stored (revoke the node if that matters)."""
    body = request.get_json(silent=True) or {}
    enable = bool(body.get('enabled', True))

    def _set(nd):
        if node_id not in nd:
            return False
        nd[node_id]['jwt_sync'] = enable
        return True

    if _mutate_nodes(_set) is None:
        return jsonify({'error': 'not found'}), 404
    with _connected_nodes_lock:
        entry = connected_nodes.get(node_id)
        if entry is not None:
            entry['jwt_sync'] = enable
    if enable and entry is not None:
        from .nodes import _live_jwt_tokens, _push_jwt_sync
        threading.Thread(target=_push_jwt_sync,
                         args=(node_id, _live_jwt_tokens()), daemon=True).start()
    return jsonify({'ok': True, 'node_id': node_id, 'jwt_sync': enable})


@app.route('/api/admin/nodes/<node_id>/revoke', methods=['POST'])
@login_required
def admin_nodes_revoke(node_id):
    if _mutate_nodes(lambda nd: nd.pop(node_id, None) is not None) is None:
        return jsonify({'error': 'not found'}), 404
    with _connected_nodes_lock:
        entry = connected_nodes.pop(node_id, None)
    if entry:
        try:
            entry['ws'].close()
        except Exception:
            pass
    return jsonify({'ok': True})


@app.route('/api/admin/jwt/contribute', methods=['POST'])
@login_required
def admin_jwt_contribute():
    """Manually add a Cubey JWT to the shared pool (e.g. pasted from a device,
    a curl, or forwarded from a node)."""
    body = request.get_json(silent=True) or request.form.to_dict() or {}
    token = (body.get('token') or '').strip()
    if not token:
        return jsonify({'ok': False, 'error': 'missing token'}), 400
    node_id = (body.get('node_id') or '').strip() or None
    res = contribute_jwt(token, node_id=node_id)
    return jsonify(res)


@app.route('/api/jwt/push', methods=['POST'])
def api_jwt_push():
    """Key-authenticated pool contribution for browser clients (the userscript in
    tools/jwt-uploader). No session: the caller presents the push key, so this
    route sends no CORS headers and answers no preflight -- a random web page
    cannot make a browser send the key, only a userscript manager can."""
    body = request.get_json(silent=True) or request.form.to_dict() or {}
    key = request.headers.get('X-YTMU-Key') or body.get('key') or ''
    token = body.get('token') or ''
    source = body.get('source') or body.get('node_id') or 'push'
    res = _jwt_push(key, token, source)
    resp = jsonify(res)
    resp.headers['Cache-Control'] = 'no-store'
    if res.get('auth') is False:
        return resp, 401
    if not res.get('ok'):
        return resp, 400
    return resp


@app.route('/api/lyrics/contribute', methods=['POST'])
def api_lyrics_contribute():
    """Key-authenticated lyrics upgrade from the better-lyrics browser
    extension. Same trust level and the same key as /api/jwt/push: the caller
    presents the push key, so this route sends no CORS headers and answers no
    preflight.

    The extension races MORE providers than we do and sometimes ends up with a
    better result than the one we served it (a word-synced line where our pool
    only had line-sync, a provider we do not carry at all). It posts that here
    and we store it -- but only when it strictly beats the tier already on
    disk, because this fires on every song change and a browser that keeps
    re-offering its plain fallback must not walk a word-synced entry back down.

    Body: {video_id, lang?, source?, data?, song?, artist?, node_id?}.
    `data.lyrics` may be either our line shape or braccato's (`words`,
    `translations[lang]`); see library._coerce_push_lyrics.
    """
    body = request.get_json(silent=True) or request.form.to_dict() or {}
    key = request.headers.get('X-YTMU-Key') or body.get('key') or ''
    if not _push_key_ok(key):
        resp = jsonify({'ok': False, 'auth': False, 'error': 'bad key'})
        resp.headers['Cache-Control'] = 'no-store'
        return resp, 401

    video_id = (body.get('video_id') or body.get('v') or '').strip()
    lang = (body.get('lang') or 'zh-TW').strip()
    source = (body.get('source') or '').strip()[:64]
    data = body.get('data')
    node_id = (body.get('node_id') or '').strip()[:32]
    # force is the extension's "send what is on screen" BUTTON: an explicit press
    # replaces the entry instead of being measured against it. It is logged as a
    # force so it is never mistaken for an automatic upgrade, and the automatic
    # path can never set it.
    force = body.get('force') in (True, 'true', '1', 1)
    if not video_id or not isinstance(data, dict):
        resp = jsonify({'ok': False, 'error': 'missing video_id or data'})
        resp.headers['Cache-Control'] = 'no-store'
        return resp, 400

    try:
        res = apply_lyrics_payload(
            video_id, lang, source, data,
            title=(body.get('song') or body.get('title') or '').strip(),
            artist=(body.get('artist') or '').strip(),
            require_better=not force,
            origin=(f'ext {node_id}' + (' FORCE' if force else '')) if node_id else ('ext FORCE' if force else 'ext'),
        )
    except Exception as e:
        print(f"  [CONTRIB] [FAIL] {video_id}: {e}")
        res = {'ok': False, 'error': str(e)}

    resp = jsonify(res)
    resp.headers['Cache-Control'] = 'no-store'
    if not res.get('ok') and not res.get('skipped'):
        return resp, 400
    return resp


@app.route('/api/admin/jwt/push_key', methods=['GET'])
@login_required
def admin_jwt_push_key():
    """Reveal (creating on first call) the key the browser userscript uses."""
    return jsonify({'key': _jwt_push_key()})


@app.route('/api/admin/jwt/list', methods=['GET'])
@login_required
def admin_jwt_list():
    """Pool state for the dashboard; raw tokens are never exposed."""
    return jsonify({'count': len(list_jwt()), 'jwt': list_jwt()})


@app.route('/api/admin/jwt/remove', methods=['POST'])
@login_required
def admin_jwt_remove():
    """Drop a single pooled token by its hash id.

    reason is recorded in the ledger next to the death, so an operator delete is
    never counted as a token that died on its own -- those are different facts
    and the chart labels them differently."""
    body = request.get_json(silent=True) or request.form.to_dict() or {}
    jid = (body.get('id') or '').strip()
    if not jid:
        return jsonify({'ok': False, 'error': 'missing id'}), 400
    removed = remove_jwt(jid, reason=(body.get('reason') or 'removed'))
    return jsonify({'ok': True, 'removed': removed, 'count': len(list_jwt())})


@app.route('/api/admin/jwt/stats', methods=['GET'])
@login_required
def admin_jwt_stats():
    """Per-request accounting and the retirement ledger, for the graphs.

    Separate from /api/admin/jwt/list on purpose: the list is the current pool,
    this is the history (how many requests each token served, how many it served
    before it died, when). Raw tokens are never in either."""
    from .jwt_stats import snapshot as jwt_snapshot
    live = list_jwt()
    snap = jwt_snapshot()
    # Attach the pool's live counters to the snapshot in one place, so the chart
    # and the table cannot disagree about what a token has served.
    by_id = {e['id']: e for e in live}
    snap['live'] = live
    snap['live_requests'] = sum(int(e.get('requests') or 0) for e in live)
    snap['live_by_id'] = by_id
    return jsonify({'ok': True, **snap})


@app.route('/api/admin/jwt/stats/clear', methods=['POST'])
@login_required
def admin_jwt_stats_clear():
    """Drop the request history and the ledger. The live pool is untouched --
    a token keeps working, its counters just start from zero again."""
    from .jwt_stats import clear as jwt_clear
    jwt_clear()
    return jsonify({'ok': True})


@app.route('/api/admin/jwt/check', methods=['POST'])
@login_required
def admin_jwt_check():
    """Force a re-probe of every live token against Cubey now; dead tokens get
    evicted. Returns {ok, dead, unknown, total}."""
    summary = jwt_check_all(evict=True)
    return jsonify({'ok': True, **summary})


@app.route('/api/admin/server_info', methods=['GET'])
@login_required
def admin_server_info():
    uptime = (datetime.now() - SERVER_START_TIME).total_seconds()
    # count log files
    log_files = []
    if os.path.exists(LOG_DIR):
        for fname in os.listdir(LOG_DIR):
            fpath = os.path.join(LOG_DIR, fname)
            try:
                sz = os.path.getsize(fpath)
                mt = datetime.fromtimestamp(os.path.getmtime(fpath)).isoformat()
                log_files.append({'name': fname, 'size': sz, 'modified': mt})
            except: pass
    # cache dir stats
    lyrics_count = 0
    translate_count = 0
    try:
        if os.path.exists(LYRICS_DIR):
            lyrics_count = len([f for f in os.listdir(LYRICS_DIR) if f.endswith('.json')])
        if os.path.exists(TRANSLATE_DIR):
            translate_count = len([f for f in os.listdir(TRANSLATE_DIR) if f.endswith('.json')])
    except: pass
    return jsonify({
        'instance_id': SERVER_INSTANCE_ID,
        'start_time': SERVER_START_TS,
        'uptime_seconds': int(uptime),
        'uptime_human': f"{int(uptime//3600)}h {int((uptime%3600)//60)}m {int(uptime%60)}s",
        'structured_logs': len(_structured_logs),
        'recent_logs': len(_recent_logs),
        'crash_logs': len(_crash_logs),
        'lyrics_count': lyrics_count,
        'translate_count': translate_count,
        'recent_requests': list(_recent_requests)[-20:],
        'log_files': sorted(log_files, key=lambda x: x['modified'], reverse=True)[:20],
        # Free with the payload the Overview page already fetches, so the
        # latency widget costs no extra request on every refresh.
        'latency': latency_snapshot(),
    })


# Standalone read of the same payload, for anything that wants the percentiles
# without the rest of server_info. Admin-gated like the dashboard itself: the
# numbers are harmless, but they describe the server's traffic.
@app.route('/api/admin/latency', methods=['GET'])
@login_required
def admin_latency():
    return jsonify(latency_snapshot())


@app.route('/api/admin/latency/clear', methods=['POST'])
@login_required
def admin_latency_clear():
    """Drop every latency ring. There is no undo: the history is only
    rebuildable from the fetches that happen after this."""
    from .latency_stats import clear as _lat_clear
    had = _lat_clear()
    return jsonify({'ok': True, 'cleared': bool(had), **latency_snapshot()})

@app.route('/api/admin/logs/download', methods=['GET'])
@login_required
def admin_logs_download():
    # Bundle structured + recent + crash into downloadable text
    from flask import Response
    lines = []
    lines.append(f"# Server instance {SERVER_INSTANCE_ID} start {SERVER_START_TS}")
    lines.append(f"# Generated {datetime.now().isoformat()}")
    lines.append("="*60)
    lines.append("## Structured logs")
    for e in list(_structured_logs):
        lines.append(f"[{e.get('ts')}] [{e.get('level')}] {e.get('msg')}")
    lines.append("="*60)
    lines.append("## Recent raw logs")
    for l in list(_recent_logs):
        lines.append(l.rstrip())
    lines.append("="*60)
    lines.append("## Crash logs")
    for c in list(_crash_logs):
        lines.append(f"[{c.get('ts')}] {c.get('type')}: {c.get('msg')}")
        lines.append(c.get('trace','')[:2000])
    content = "\n".join(lines)
    return Response(content, mimetype="text/plain", headers={"Content-Disposition": f"attachment; filename=server_logs_{SERVER_INSTANCE_ID[:8]}.txt"})

@app.route('/api/admin/crash_logs', methods=['GET'])
@login_required
def admin_crash_logs():
    return jsonify({'logs': list(_crash_logs), 'total': len(_crash_logs)})

@app.route('/api/admin/crash_logs/clear', methods=['POST'])
@login_required
def admin_crash_clear():
    _crash_logs.clear()
    # also truncate crash file
    try:
        open(CRASH_LOG_FILE, 'w').close()
    except: pass
    return jsonify({'ok': True})

@app.route('/api/admin/files', methods=['GET'])
@login_required
def admin_files():
    result = []
    if os.path.exists(LOG_DIR):
        for fname in sorted(os.listdir(LOG_DIR), key=lambda f: os.path.getmtime(os.path.join(LOG_DIR, f)), reverse=True):
            fpath = os.path.join(LOG_DIR, fname)
            if not os.path.isfile(fpath): continue
            try:
                stat = os.stat(fpath)
                result.append({
                    'name': fname,
                    'size': stat.st_size,
                    'size_human': f"{stat.st_size/1024:.1f}KB" if stat.st_size < 1024*1024 else f"{stat.st_size/1024/1024:.1f}MB",
                    'modified': datetime.fromtimestamp(stat.st_mtime).isoformat(),
                    'is_log': fname.endswith('.log') or fname.startswith('UI_DUMP') or fname.endswith('.txt'),
                })
            except: pass
    # also include cache dir stats
    cache_info = {}
    try:
        if os.path.exists(LYRICS_DIR):
            cache_info['lyrics_count'] = len([f for f in os.listdir(LYRICS_DIR) if f.endswith('.json')])
        if os.path.exists(TRANSLATE_DIR):
            cache_info['translate_count'] = len([f for f in os.listdir(TRANSLATE_DIR) if f.endswith('.json')])
    except: pass
    return jsonify({'files': result, 'cache': cache_info})

@app.route('/api/admin/files/download', methods=['GET'])
@login_required
def admin_files_download():
    fname = request.args.get('file','')
    # sanitize
    if not fname or '/' in fname or '\\' in fname or '..' in fname:
        return jsonify({'error': 'Invalid file'}), 400
    fpath = os.path.join(LOG_DIR, fname)
    if not os.path.isfile(fpath):
        return jsonify({'error': 'File not found', 'path': fpath}), 404
    from flask import send_file
    return send_file(fpath, as_attachment=True)

@app.route('/api/admin/self_update/check', methods=['GET'])
@login_required
def admin_self_update_check():
    local = _get_local_sha()
    remote, parent, meta = _get_remote_sha()
    main_file = _get_main_file()
    # The file-hash pair is only a real comparison when the file we track locally
    # IS the file the remote path names. main_file is user-configurable
    # (admin_config.json -> main_file, or $MAIN_FILE) while
    # SELF_UPDATE_REMOTE_PATH is hardcoded, so on a deploy that tracks app.py
    # these hashed two DIFFERENT files: they could never match, and the pair sat
    # on the card looking exactly like a genuine mismatch. Nothing was wrong --
    # the two numbers were not comparable, and a red-looking pair trains you to
    # ignore the card. Omit them unless they are comparable, and name the file
    # being tracked so a misconfigured main_file is visible instead of implied.
    local_file_hash = None
    remote_file_hash = None
    if os.path.basename(main_file) == SELF_UPDATE_REMOTE_PATH:
        try:
            if os.path.exists(main_file):
                local_file_hash = hashlib.sha256(open(main_file, 'rb').read()).hexdigest()[:12]
        except: pass
        try:
            # fetch remote file to compute hash (quick, cached by GitHub)
            content = _fetch_remote_file(remote) if remote else None
            if content:
                remote_file_hash = hashlib.sha256(content.encode('utf-8')).hexdigest()[:12]
        except: pass
    # Determine update availability: prefer git sha if both are 40-char, else file hash
    up_to_date = None
    update_available = False
    if local and remote:
        if len(local) == 40 and len(remote) == 40:
            up_to_date = (local == remote)
            update_available = (local != remote)
        elif local_file_hash and remote_file_hash:
            up_to_date = (local_file_hash == remote_file_hash)
            update_available = (local_file_hash != remote_file_hash)
        else:
            up_to_date = (local == remote)
            update_available = (local != remote)
    return jsonify({
        'local_sha': local,
        'remote_sha': remote,
        'parent_sha': parent,
        'local_file_hash': local_file_hash,
        'remote_file_hash': remote_file_hash,
        'main_file': main_file,
        'main_file_name': os.path.basename(main_file),
        'up_to_date': up_to_date,
        'update_available': update_available,
        'repo': SELF_UPDATE_REPO,
        'branch': SELF_UPDATE_BRANCH,
        'remote_path': SELF_UPDATE_REMOTE_PATH,
    })

@app.route('/api/admin/self_update/config', methods=['GET', 'POST'])
@login_required
def admin_self_update_config():
    if request.method == 'GET':
        return jsonify({'main_file': _admin_cfg.get('main_file'), 'detected': _get_main_file(), 'repo': SELF_UPDATE_REPO, 'branch': SELF_UPDATE_BRANCH})
    data = request.get_json(force=True) or {}
    # Allow user to set target filename like app.py / main.py / bot.py
    new_name = (data.get('main_file') or '').strip()
    if not new_name:
        _admin_cfg.pop('main_file', None)
    else:
        # sanitize: no path traversal, must end with .py, simple basename or relative path
        if '..' in new_name or new_name.startswith('/'):
            return jsonify({'error': 'Invalid filename'}), 400
        if not new_name.endswith('.py'):
            return jsonify({'error': 'Must be .py file'}), 400
        _admin_cfg['main_file'] = new_name
    _save_admin_config(_admin_cfg)
    return jsonify({'ok': True, 'main_file': _admin_cfg.get('main_file'), 'detected': _get_main_file()})

@app.route('/api/admin/self_update/perform', methods=['POST'])
@login_required
def admin_self_update_perform():
    # Optional param to force even if up to date
    force = request.args.get('force') == '1' or (request.get_json(silent=True) or {}).get('force')
    local = _get_local_sha()
    remote, parent, meta = _get_remote_sha()
    if not remote:
        return jsonify({'ok': False, 'error': 'Could not fetch remote SHA'}), 502
    if not force:
        # Check file hash as well
        try:
            lf = hashlib.sha256(open(_get_main_file(), 'rb').read()).hexdigest()[:12] if os.path.exists(_get_main_file()) else None
            rf_content = _fetch_remote_file(remote)
            rf = hashlib.sha256(rf_content.encode('utf-8')).hexdigest()[:12] if rf_content else None
            if lf and rf and lf == rf:
                return jsonify({'ok': False, 'error': 'Already up to date (file hash)', 'local': local, 'remote': remote}), 200
        except: pass
        if local == remote:
            return jsonify({'ok': False, 'error': 'Already up to date', 'local': local, 'remote': remote}), 200
    ok, msg = _perform_self_update()
    if ok:
        # Log and schedule restart after response
        print(f"[SELF-UPDATE] {msg} - restarting in 1s")
        def _restart():
            time_module.sleep(1)
            try:
                # Try to restart via execv (preserves args)
                py = sys.executable
                os.execv(py, [py] + sys.argv)
            except Exception as e:
                print(f"[SELF-UPDATE] restart failed: {e}")
                os._exit(0)
        threading.Thread(target=_restart, daemon=True).start()
        return jsonify({'ok': True, 'message': msg, 'local': local, 'remote': remote, 'parent': parent, 'restarting': True})
    else:
        return jsonify({'ok': False, 'error': msg, 'local': local, 'remote': remote}), 500


# ============================================================
# SSE: real-time push for dashboard
# ============================================================
@app.route('/api/admin/events')
@login_required
def admin_events():
    """SSE stream that pushes log, crash, cache, and node events. Accepts
    ?interval=<seconds> (5..300, default 30): the client heartbeat cadence.
    Each cadence emits a `ping` event (so pages refresh server-driven with
    zero polling) plus a comment keepalive for proxies."""
    try:
        interval = float(request.args.get('interval', 30))
    except (TypeError, ValueError):
        interval = 30
    import math as _math
    if not _math.isfinite(interval):
        interval = 30
    interval = min(max(interval, 5.0), 300.0)
    q = queue.Queue(maxsize=200)
    with _sse_subscribers_lock:
        _sse_subscribers.append(q)

    def generate():
        try:
            # Send initial snapshot so the client can render immediately
            import json as _json
            import time as _time
            yield f"event: snapshot\ndata: {_json.dumps({'logs': list(_structured_logs)[-80:], 'total': len(_structured_logs), 'interval': interval})}\n\n"
            yield f"event: ping\ndata: {_json.dumps({'ts': _time.time(), 'interval': interval})}\n\n"
            while True:
                try:
                    msg = q.get(timeout=interval)
                    yield msg
                except queue.Empty:
                    yield f"event: ping\ndata: {_json.dumps({'ts': _time.time(), 'interval': interval})}\n\n"
                    yield ": keepalive\n\n"
        except GeneratorExit:
            pass
        finally:
            with _sse_subscribers_lock:
                if q in _sse_subscribers:
                    _sse_subscribers.remove(q)

    return Response(stream_with_context(generate()), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})

