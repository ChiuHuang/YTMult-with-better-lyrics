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
from .app import (app, login_required, _admin_cfg, SERVER_INSTANCE_ID,
    SERVER_START_TIME, SERVER_START_TS, LOG_DIR,
    _recent_logs, _structured_logs, _recent_requests, _crash_logs)
from .nodes import (_load_nodes, _save_nodes, _hash_node_key,
    connected_nodes, _connected_nodes_lock)
from .self_update import SELF_UPDATE_REPO, SELF_UPDATE_BRANCH, SELF_UPDATE_REMOTE_PATH
from .cache import clear_not_found_caches
from .self_update import (_get_local_sha, _get_remote_sha, _fetch_remote_file,
    _perform_self_update, _get_main_file)
from .logging_util import _log_crash

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
    return render_template('index.html')


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


@app.route('/api/admin/caches', methods=['GET'])
@login_required
def admin_caches():
    lyrics_dir = 'cache/lyrics'
    items = []
    if os.path.exists(lyrics_dir):
        for fname in sorted(os.listdir(lyrics_dir),
                            key=lambda f: os.path.getmtime(os.path.join(lyrics_dir, f)),
                            reverse=True):
            if not fname.endswith('.json'):
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
                cache_key = fname[:-5]
                video_id = cache_key.split(':')[0]
                items.append({
                    'video_id': video_id,
                    'cache_key': cache_key,
                    'song': data.get('song', ''),
                    'artist': data.get('artist', ''),
                    'source': data.get('source', '?'),
                    'synced': data.get('synced', False),
                    'lines': len(data.get('lyrics', [])),
                    'time_ago': time_ago,
                })
            except Exception:
                pass
    return jsonify(items)


@app.route('/api/admin/caches/clear_empty', methods=['POST'])
@login_required
def admin_clear_empty_caches():
    lyrics_dir = 'cache/lyrics'
    removed = 0
    if os.path.exists(lyrics_dir):
        for fname in os.listdir(lyrics_dir):
            if fname.endswith('.json'):
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
    items = []
    for node_id, rec in nodes.items():
        items.append({
            'node_id': node_id,
            'label': rec.get('label', ''),
            'created': rec.get('created', ''),
            'last_seen': rec.get('last_seen'),
            'online': node_id in online_ids,
        })
    items.sort(key=lambda x: x['created'], reverse=True)
    return jsonify({'nodes': items})


@app.route('/api/admin/nodes/generate', methods=['POST'])
@login_required
def admin_nodes_generate():
    body = request.get_json(silent=True) or {}
    label = body.get('label') or request.form.get('label', '') or ''

    node_id = _secrets.token_hex(8)
    node_key = _secrets.token_hex(32)
    nodes = _load_nodes()
    nodes[node_id] = {
        'key_hash': _hash_node_key(node_key),
        'label': label,
        'created': datetime.now().isoformat(),
        'last_seen': None,
    }
    _save_nodes(nodes)

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

    # The raw key exists only in this response and in the node's own copy of
    # the script from here on -- the server only ever stores its hash. If
    # this download is lost, revoke the node and generate a new one; it
    # can't be regenerated with the same key.
    resp = Response(script, mimetype='text/x-python')
    resp.headers['Content-Disposition'] = f'attachment; filename="node_{node_id}.py"'
    return resp


@app.route('/api/admin/nodes/<node_id>/revoke', methods=['POST'])
@login_required
def admin_nodes_revoke(node_id):
    nodes = _load_nodes()
    if node_id not in nodes:
        return jsonify({'error': 'not found'}), 404
    del nodes[node_id]
    _save_nodes(nodes)
    with _connected_nodes_lock:
        entry = connected_nodes.pop(node_id, None)
    if entry:
        try:
            entry['ws'].close()
        except Exception:
            pass
    return jsonify({'ok': True})


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
    return jsonify({
        'instance_id': SERVER_INSTANCE_ID,
        'start_time': SERVER_START_TS,
        'uptime_seconds': int(uptime),
        'uptime_human': f"{int(uptime//3600)}h {int((uptime%3600)//60)}m {int(uptime%60)}s",
        'structured_logs': len(_structured_logs),
        'recent_logs': len(_recent_logs),
        'crash_logs': len(_crash_logs),
        'recent_requests': list(_recent_requests)[-20:],
        'log_files': sorted(log_files, key=lambda x: x['modified'], reverse=True)[:20],
    })

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
        if os.path.exists('cache/lyrics'):
            cache_info['lyrics_count'] = len([f for f in os.listdir('cache/lyrics') if f.endswith('.json')])
        if os.path.exists('cache/translate'):
            cache_info['translate_count'] = len([f for f in os.listdir('cache/translate') if f.endswith('.json')])
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
    if not os.path.exists(fpath):
        return jsonify({'error': 'Not found'}), 404
    from flask import send_file
    return send_file(fpath, as_attachment=True)

@app.route('/api/admin/self_update/check', methods=['GET'])
@login_required
def admin_self_update_check():
    local = _get_local_sha()
    remote, parent, meta = _get_remote_sha()
    main_file = _get_main_file()
    # Also compute file hashes for accurate comparison when not in git repo
    local_file_hash = None
    remote_file_hash = None
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

