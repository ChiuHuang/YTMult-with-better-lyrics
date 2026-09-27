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
from .app import app, SERVER_INSTANCE_ID, CRASH_LOG_FILE, _crash_logs, LOG_DIR
from .logging_util import _log_crash
from .self_update import _get_local_sha

@app.route('/deploy.sh')
def serve_deploy_sh():
    deploy_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'deploy.sh')
    try:
        with open(deploy_path, 'r', encoding='utf-8') as f:
            script = f.read()
        return Response(script, mimetype='text/x-shellscript', headers={
            'Content-Disposition': 'inline; filename="deploy.sh"',
            'Cache-Control': 'no-cache',
        })
    except FileNotFoundError:
        return jsonify({'error': 'deploy.sh not found on server'}), 404


@app.errorhandler(404)
def handle_404(e):
    # log but not crash
    print(f"[WARN] 404 {request.path} from {request.remote_addr}")
    return jsonify({'error': 'Not found'}), 404

@app.errorhandler(500)
def handle_500(e):
    _log_crash(type(e), e, getattr(e, '__traceback__', None))
    return jsonify({'error': 'Internal error', 'instance': SERVER_INSTANCE_ID}), 500


@app.route('/api/app/settings', methods=['GET'])
def api_app_settings():
    """Public remote config for the tweak. Open by design (values are
    non-secret); managed from the dashboard App tab."""
    from .app_settings import get_all
    return jsonify({'ok': True, 'settings': get_all()})


@app.route('/api/app/altstore', methods=['GET'])
def api_app_altstore():
    """AltStore source JSON, always pointing at the newest build-N release
    (download via the worker proxy for Asia). Submit this URL on
    altdirect.app to get direct-install links."""
    from .release_info import ALTSTORE_ICON, latest_release, worker_url
    rel = latest_release()
    if not rel or not rel.get('download_url'):
        return jsonify({'error': 'No release with an IPA asset found'}), 503
    tag = rel.get('tag') or 'build-?'
    version = tag[6:] if tag.startswith('build-') else tag
    icon_url = (rel.get('icon_url') or ALTSTORE_ICON or
                'https://raw.githubusercontent.com/ChiuHuang/YTMult-with-better-lyrics/main/Resources/icon.png')
    return jsonify({
        'name': 'YTMusicUltimate',
        'identifier': 'dev.chiuhuang.ytmult',
        'apps': [{
            'name': 'YouTube Music',
            'bundleIdentifier': 'com.google.ios.youtubemusic',
            'developerName': 'ChiuHuang',
            'version': version,
            'versionDate': rel.get('published_at') or '',
            'versionDescription': f'YTMusicUltimate ({tag})',
            'downloadURL': worker_url(rel['download_url']),
            'localizedDescription': 'YouTube Music with Ultimate tweak + synced lyrics.',
            'iconURL': icon_url,
            'size': rel.get('size') or 0,
        }],
    })

def _dump_screen_name(dump_content):
    """Topmost screen from the VC hierarchy section (presented wins, else deepest child)."""
    try:
        start = dump_content.index('--- VIEW CONTROLLER HIERARCHY ---')
    except ValueError:
        start = 0
    try:
        end = dump_content.index('--- WINDOWS & VIEW HIERARCHY ---', start)
    except ValueError:
        end = len(dump_content)
    section = dump_content[start:end]
    vc_pat = re.compile(r'<([A-Za-z0-9_]+(?:ViewController|SheetController|DialogViewController))\b')
    if '[Presented]' in section:
        tail = section.rsplit('[Presented]', 1)[1]
        m = vc_pat.findall(tail)
        if m:
            return m[-1]
    m = vc_pat.findall(section)
    if m:
        return m[-1]
    return 'UnknownScreen'


def _safe_dump_component(s, default='novideo'):
    s = re.sub(r'[^A-Za-z0-9_-]+', '_', (s or '').strip()).strip('_')
    return s or default


@app.route('/log', methods=['POST'])
def proxy_log():
    try:
        data = request.get_json(force=True)
        req_type = data.get('type', '')

        if req_type == "APP_LOG":
            event = data.get('event', 'unknown')
            level = data.get('level', 'info')
            message = data.get('message', '')
            payload = data.get('payload', {})
            timestamp = data.get('timestamp') or datetime.now().isoformat(timespec='milliseconds')
            vid = payload.get('videoId') or payload.get('videoID') or ''
            client_ip = request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-For') or request.remote_addr
            if vid:
                print(f"[iOS] [iOS Tweak] [{timestamp}] [{level.upper()}] {event}: {message} | payload={payload} ip={client_ip}")
            else:
                print(f"[iOS] [iOS Tweak] [{timestamp}] [{level.upper()}] {event}: {message}")
                if payload:
                    print(f"  [iOS] payload={payload} ip={client_ip}")
            return jsonify({"status": "ok"})

        if req_type == "UI_DUMP":
            os.makedirs(LOG_DIR, exist_ok=True)
            timestamp = datetime.now().strftime("%H-%M-%S")
            dump_content = data.get('request_body', '')
            vc_count = dump_content.count('ViewController')
            win_count = dump_content.count('[WINDOW:')
            has_9999 = 'tag = 9999' in dump_content
            has_engagement = 'Engagement' in dump_content
            has_lyrics_chip = 'No lyrics found' in dump_content or 'lyric' in dump_content.lower()
            hidden_yes = dump_content.count('hidden = YES')
            hidden_no = dump_content.count('hidden = NO')
            video_id_match = re.search(r'Current VideoID:\s*(\S+)', dump_content)
            playback_match = re.search(r'Playback Time:\s*([\d\.]+)', dump_content)
            tweak_match = re.search(r'Tweak Build:\s*(\S+)', dump_content)
            vid = video_id_match.group(1) if video_id_match else '?'
            ptime = playback_match.group(1) if playback_match else '?'
            tweak_sha = tweak_match.group(1) if tweak_match else '?'
            try:
                srv_sha = (_get_local_sha() or '?')[:7]
            except Exception:
                srv_sha = '?'
            print(f"\n[ALERT] [UI_DUMP {timestamp}] [DUMP] UI Dump received! video={vid} t={ptime}s tweak={tweak_sha} srv={srv_sha} vc={vc_count} win={win_count} has9999={has_9999} hasEngagement={has_engagement} hasLyricsChip={has_lyrics_chip} hiddenYES={hidden_yes} hiddenNO={hidden_no}")
            if not has_9999:
                print(f"  [WARN] [UI_DUMP] Modded lyrics view tag 9999 NOT found - panel will show official!")
            if not has_engagement:
                print(f"  [WARN] [UI_DUMP] No Engagement panel detected - user may not have opened lyrics panel")
            if not has_lyrics_chip:
                print(f"  [WARN] [UI_DUMP] No lyrics chip text detected - button may be hidden/locked or ASDisplayView (unlock failed)")

            filepath = os.path.join(LOG_DIR, f"UI_DUMP_{timestamp}_{_safe_dump_component(_dump_screen_name(dump_content), 'UnknownScreen')}_{_safe_dump_component(vid if vid != '?' else '', 'novideo')}.txt")
            _dup = 1
            _base, _ext = os.path.splitext(filepath)
            while os.path.exists(filepath):
                _dup += 1
                filepath = f"{_base}_{_dup}{_ext}"
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(dump_content)
            print(f"[OK] [UI_DUMP] Saved to {filepath} ({len(dump_content)} bytes)")
            return jsonify({"status": "ok"})

        if req_type == "CRASH":
            # iOS tweak crash report
            payload = data.get('payload', {})
            msg = data.get('message', 'iOS crash')
            print(f"[CRASH] [iOS] {msg} payload={payload}")
            _crash_logs.append({'ts': datetime.now().isoformat(), 'type': 'iOS_Crash', 'msg': msg, 'trace': str(payload)[:3000], 'instance': SERVER_INSTANCE_ID})
            try:
                with open(CRASH_LOG_FILE, 'a', encoding='utf-8') as f:
                    f.write(f"\n[{datetime.now().isoformat()}] [CRASH] iOS: {msg} {payload}\n")
            except: pass
            return jsonify({"status": "ok"})

        print(f"[WARN] Unknown log type: {req_type} payload={data}")
        return jsonify({"status": "ok"})

    except Exception as e:
        print(f"[FAIL] [LOG] error: {e}")
        import traceback as _tb; _tb.print_exc()
        _log_crash(type(e), e, e.__traceback__)
        return jsonify({"status": "error", "message": str(e)}), 500

