# Debug device mode routes.
#
# Two of these are device-facing and both are locked:
#   POST /api/debug/enroll   needs an OTP the operator generated on the dashboard
#   POST /api/debug/upload   needs the token that enroll handed out
# Everything else is dashboard-session only.
#
# Split from routes_admin.py on purpose: this is the only place a device can
# push data the lyrics pipeline never sees, and keeping it in its own module is
# what makes that auditable.
import json
import os
import threading
import time
from urllib.parse import urlsplit

from flask import request, jsonify

from .app import app, login_required, LOG_DIR
from . import debug_mode

# Enroll is the one route a stranger can reach, and the only thing standing
# between them and a token is a 6-digit code. Ten tries per IP per five minutes
# makes guessing one impractical while never getting in the operator's way.
_ENROLL_WINDOW = 300
_ENROLL_MAX = 10
_attempts = {}
_attempts_lock = threading.Lock()

_RECORD_MAX = 200       # per upload
_URL_MAX = 900          # a videoplayback URL is long; it is the point of this


def _rate_limited(ip):
    now = time.time()
    with _attempts_lock:
        hits = [t for t in _attempts.get(ip, []) if now - t < _ENROLL_WINDOW]
        hits.append(now)
        _attempts[ip] = hits
        if len(_attempts) > 512:      # keep the table bounded on a busy host
            for key in [k for k, v in _attempts.items() if not v or now - v[-1] > _ENROLL_WINDOW]:
                _attempts.pop(key, None)
        return len(hits) > _ENROLL_MAX


def _txt(value, limit):
    if not isinstance(value, str):
        return ''
    cleaned = ''.join(ch if 32 <= ord(ch) < 127 or ord(ch) > 159 else ' ' for ch in value)
    return cleaned.strip()[:limit]


def _clean_record(raw, device_id):
    if not isinstance(raw, dict):
        return None
    url = _txt(raw.get('u'), _URL_MAX)
    if not url:
        return None
    host = path = ''
    try:
        parts = urlsplit(url)
        host = parts.hostname or ''
        path = (parts.path or '') + (('?' + parts.query[:300]) if parts.query else '')
    except Exception:
        pass
    return {
        'ts': _txt(raw.get('t'), 40),
        'device': device_id,
        'm': _txt(raw.get('m'), 10) or 'GET',
        'host': host,
        'path': path,
        'vid': _txt(raw.get('vid'), 20),
        'u': url,
    }


@app.route('/api/debug/enroll', methods=['POST'])
def debug_enroll():
    ip = (request.headers.get('CF-Connecting-IP')
          or request.headers.get('X-Forwarded-For')
          or request.remote_addr or '?')
    if _rate_limited(ip):
        print(f"[WARN] [DEBUG-ENROLL] rate limited ip={ip}")
        return jsonify({'ok': False, 'error': 'too many attempts, wait a few minutes'}), 429
    body = request.get_json(silent=True) or {}
    result = debug_mode.enroll(body.get('otp'), body)
    if not result.get('ok'):
        print(f"[WARN] [DEBUG-ENROLL] refused ip={ip}: {result.get('error')}")
        return jsonify(result), 403
    print(f"[OK] [DEBUG-ENROLL] {result['id']} enrolled ip={ip} "
          f"name={_txt(body.get('name'), 40) or '?'} build={_txt(body.get('build'), 40) or '?'}")
    return jsonify(result)


@app.route('/api/debug/upload', methods=['POST'])
def debug_upload():
    token = request.headers.get('X-YTMU-Debug-Token', '')
    body = request.get_json(silent=True) or {}
    records = body.get('records')
    if not isinstance(records, list):
        return jsonify({'ok': False, 'error': 'records must be a list'}), 400
    records = records[:_RECORD_MAX]
    device = debug_mode.verify(token, count=len(records))
    if not device:
        # 401 for "unknown device" so the tweak can drop its token and stop
        # retrying; a 403 would mean "known device, not allowed" and it does not
        # exist on this route yet.
        return jsonify({'ok': False, 'error': 'unknown or revoked token'}), 401

    device_id = device['id']
    folder = os.path.join(LOG_DIR, 'debug')
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f'{device_id}.ndjson')
    kept = 0
    with open(path, 'a', encoding='utf-8') as f:
        for raw in records:
            line = _clean_record(raw, device_id)
            if not line:
                continue
            f.write(json.dumps(line, ensure_ascii=False) + '\n')
            kept += 1
            if kept <= 20:
                print(f"[DEBUG-CAP] {device_id} {line['m']} {line['host']}{line['path'][:160]}")
    print(f"[OK] [DEBUG-CAP] {device_id} {kept}/{len(records)} record(s) -> {path}")
    return jsonify({'ok': True, 'accepted': kept})


@app.route('/api/admin/debug/otp', methods=['POST'])
@login_required
def admin_debug_otp():
    otp = debug_mode.new_otp()
    print(f"[OK] [DEBUG-OTP] generated (expires in {otp['expires_in']}s)")
    return jsonify(otp)


@app.route('/api/admin/debug/devices', methods=['GET'])
@login_required
def admin_debug_devices():
    devices = debug_mode.list_devices()
    # Newest first: the one you just enrolled is the one you are looking at.
    devices.sort(key=lambda d: d.get('created_at') or '', reverse=True)
    return jsonify({'devices': devices, 'pending': debug_mode.pending_count()})


@app.route('/api/admin/debug/devices/<device_id>/revoke', methods=['POST'])
@login_required
def admin_debug_revoke(device_id):
    ok = debug_mode.revoke(device_id)
    if ok:
        print(f"[WARN] [DEBUG-TOKEN] {device_id} revoked")
    return jsonify({'ok': ok})
