# Device-count statistics from the tweak's ping.
#
# Privacy shape (docs/ownership-and-debug.md): the device generates ONE
# random UUID itself and sends it ONLY to POST /api/app/ping. We store a
# SALTED HASH of it -- never the raw uid -- plus the channel and timestamps.
# The salt is a server-local random hex blob; without it the hash is not
# reversible, so a leaked instances.json is not a device list.
import hashlib
import json
import os
import secrets
import threading
import time

from .paths import INSTANCES_FILE, PING_SALT_FILE

_LOCK = threading.Lock()
_STATE = {'loaded': False, 'devices': {}, 'salt': ''}


def _load():
    if _STATE['loaded']:
        return
    _STATE['loaded'] = True
    try:
        with open(INSTANCES_FILE, 'r', encoding='utf-8') as f:
            d = json.load(f)
        if isinstance(d.get('devices'), dict):
            _STATE['devices'] = d['devices']
    except Exception:
        pass
    try:
        with open(PING_SALT_FILE, 'r', encoding='utf-8') as f:
            _STATE['salt'] = f.read().strip()
    except Exception:
        pass
    if not _STATE['salt']:
        _STATE['salt'] = secrets.token_hex(32)
        try:
            os.makedirs(os.path.dirname(PING_SALT_FILE) or '.', exist_ok=True)
            with open(PING_SALT_FILE, 'w', encoding='utf-8') as f:
                f.write(_STATE['salt'])
        except Exception:
            pass


def _save():
    try:
        tmp = INSTANCES_FILE + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump({'devices': _STATE['devices']}, f)
        os.replace(tmp, INSTANCES_FILE)
    except Exception as e:
        print(f"[Ping] [WARN] instance state not persisted: {e}")


def record_ping(uid, channel):
    """One ping from one install. Returns the masked hash id or None."""
    if not uid or len(uid) > 128:
        return None
    _load()
    h = hashlib.sha256((_STATE['salt'] + ':' + uid).encode('utf-8')).hexdigest()
    now = int(time.time())
    with _LOCK:
        rec = _STATE['devices'].get(h) or {}
        rec.update({
            'channel': 'debug' if channel == 'debug' else 'stable',
            'last_seen': now,
            'first_seen': rec.get('first_seen') or now,
        })
        _STATE['devices'][h] = rec
        _save()
    return h[:12]


def instances_state():
    """What the dashboard shows. Two counters (stable / debug) plus the
    recent list, masked ids only."""
    _load()
    with _LOCK:
        devices = [dict(v, id=h[:12]) for h, v in _STATE['devices'].items()]
    devices.sort(key=lambda d: d.get('last_seen') or 0, reverse=True)
    stable = sum(1 for d in devices if d['channel'] == 'stable')
    debug = sum(1 for d in devices if d['channel'] == 'debug')
    return {'ok': True, 'stable': stable, 'debug': debug, 'total': len(devices), 'devices': devices}
