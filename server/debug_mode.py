# Debug device mode: a device may only push captured traffic after the
# operator hands it a one-time code.
#
# Why an OTP and not a plain shared key: the capture channel is per-device and
# opt-in. The operator generates a 6-digit code on the dashboard, reads it to
# the person holding that phone, and only then does the server accept anything
# from that device. A code is single use, dies after 10 minutes and dies after
# 5 wrong guesses, so the OPEN enroll route cannot be used to fish for a token.
#
# Tokens are stored HASHED (same reasoning as nodes.json's key_hash): the
# server can verify a device, never replay it. The raw token exists only in the
# response that enroll hands back, and on the device.
#
# Nothing in the lyrics pipeline imports this module, so the worst a bug here
# can do is refuse a debug upload.
import hashlib
import json
import os
import re
import secrets
import threading
import time
from datetime import datetime

_PATH = 'config/debug_tokens.json'
_LOCK = threading.Lock()
_OTP_TTL = 600          # seconds a code stays valid
_OTP_MAX_TRIES = 5      # wrong guesses before the code is discarded
_PENDING_MAX = 20       # live codes one dashboard session can hold

_pending = {}           # code -> {'exp': ts, 'tries': n}; RAM only by design
_pending_lock = threading.Lock()

_CTRL_RE = re.compile(r'[\x00-\x1f\x7f]')


def _now():
    return time.time()


def _iso():
    return datetime.now().isoformat(timespec='seconds')


def _txt(value, limit):
    """Free text from the wire: no control characters, hard length cap."""
    if not isinstance(value, str):
        return ''
    return _CTRL_RE.sub(' ', value).strip()[:limit]


def _hash_token(token):
    return hashlib.sha256(token.encode('utf-8')).hexdigest()


def _load():
    try:
        with open(_PATH, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}
    if not isinstance(data.get('devices'), dict):
        data['devices'] = {}
    return data


def _save(data):
    os.makedirs(os.path.dirname(_PATH), exist_ok=True)
    tmp = _PATH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.replace(tmp, _PATH)


def new_otp():
    """A fresh single-use code for the dashboard to show the operator."""
    with _pending_lock:
        now = _now()
        for code in [c for c, e in _pending.items() if e['exp'] <= now]:
            _pending.pop(code, None)
        while True:
            code = '%06d' % secrets.randbelow(1000000)
            if code not in _pending:
                break
        if len(_pending) >= _PENDING_MAX:
            oldest = min(_pending.items(), key=lambda kv: kv[1]['exp'])[0]
            _pending.pop(oldest, None)
        _pending[code] = {'exp': now + _OTP_TTL, 'tries': 0}
    return {'otp': code, 'expires_in': _OTP_TTL}


def pending_count():
    with _pending_lock:
        now = _now()
        return len([1 for e in _pending.values() if e['exp'] > now])


def enroll(otp, info=None):
    """Exchange a code for a device token. Single use, one shot either way."""
    code = ''.join(ch for ch in (otp or '') if ch.isdigit())
    if len(code) != 6:
        return {'ok': False, 'error': 'code must be 6 digits'}
    with _pending_lock:
        entry = _pending.get(code)
        if not entry:
            return {'ok': False, 'error': 'unknown or expired code'}
        if entry['exp'] <= _now():
            _pending.pop(code, None)
            return {'ok': False, 'error': 'code expired'}
        if entry['tries'] >= _OTP_MAX_TRIES:
            _pending.pop(code, None)
            return {'ok': False, 'error': 'too many attempts'}
        entry['tries'] += 1
        # Consumed on the first correct answer, so a leaked code cannot be used
        # twice; a wrong guess only counts against the attempt budget.
        _pending.pop(code, None)

    info = info if isinstance(info, dict) else {}
    token = secrets.token_urlsafe(24)
    device_id = 'dev' + secrets.token_hex(4)
    record = {
        'id': device_id,
        'token_hash': _hash_token(token),
        'name': _txt(info.get('name'), 40) or 'device',
        'ios': _txt(info.get('ios'), 20),
        'build': _txt(info.get('build'), 40),
        'created_at': _iso(),
        'last_seen': None,
        'uploads': 0,
        'records': 0,
        'revoked': False,
    }
    with _LOCK:
        data = _load()
        data['devices'][device_id] = record
        _save(data)
    return {'ok': True, 'id': device_id, 'token': token}


def verify(token, count=0):
    """Device record for a valid, unrevoked token; None otherwise.

    Bumps last_seen/uploads on every accepted call -- that counter is the only
    way to tell "enrolled and silent" from "enrolled and uploading".
    """
    if not token or not isinstance(token, str):
        return None
    digest = _hash_token(token)
    with _LOCK:
        data = _load()
        for record in data['devices'].values():
            if record.get('revoked'):
                continue
            if secrets.compare_digest(record.get('token_hash') or '', digest):
                record['last_seen'] = _iso()
                record['uploads'] = int(record.get('uploads') or 0) + 1
                record['records'] = int(record.get('records') or 0) + max(0, int(count or 0))
                _save(data)
                public = {k: v for k, v in record.items() if k != 'token_hash'}
                return public
    return None


def verify_read(token):
    """Device record for a valid, unrevoked token; None otherwise. The READ
    half of verify: no counters bump, no save happens, because the fetch
    channel must not be indistinguishable from the upload channel in stats."""
    if not token or not isinstance(token, str):
        return None
    digest = _hash_token(token)
    with _LOCK:
        data = _load()
        for record in data['devices'].values():
            if record.get('revoked'):
                continue
            if secrets.compare_digest(record.get('token_hash') or '', digest):
                return {k: v for k, v in record.items() if k != 'token_hash'}
    return None


def list_devices():
    """Dashboard view. The token hash never leaves this module."""
    with _LOCK:
        data = _load()
        return [{k: v for k, v in rec.items() if k != 'token_hash'}
                for rec in data['devices'].values()]


def revoke(device_id):
    with _LOCK:
        data = _load()
        record = data['devices'].get(device_id or '')
        if not record:
            return False
        record['revoked'] = True
        record['revoked_at'] = _iso()
        _save(data)
        return True
