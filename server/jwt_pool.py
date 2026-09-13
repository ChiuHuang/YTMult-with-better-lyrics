# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Cubey JWT pool.
#
# Cubey requests need a Turnstile-generated bearer token that only lives on
# the iOS device (or on contributing nodes/people). Instead of relying on the
# single token a request happens to carry, this module keeps a shared pool of
# contributed tokens so any request can fall back to a known-good one when no
# JWT was passed, and so a dead token gets evicted instead of wedging fetches.
#
# Tokens arrive three ways:
#   - ws_node 'jwt_contribute' messages from connected nodes
#   - POST /api/admin/jwt/contribute (dashboard / manual curl)
#   - inline 'jwt' query args still work unchanged (pool is a fallback)
#
# Raw tokens only ever live in memory. cache/jwt.json persists a token hash
# plus bookkeeping per contribution, so the admin list survives restarts while
# the secrets themselves do not get written to disk. A background thread
# re-probes each live token against Cubey on a timer, marks dead ones, and
# evicts them; pick_jwt() round-robins the survivors.
import json
import os
import threading
import hashlib
import time as time_module
from datetime import datetime

from .nodes import pick_node

JWT_FILE = os.path.join('cache', 'jwt.json')
VERIFY_INTERVAL = 300       # seconds between full pool probes
POOL_MAX = 32               # newest-first cap; oldest evicted
_VERIFY_VIDEO_ID = 'dQw4w9WgXcQ'
_VERIFY_SONG = 'Never Gonna Give You Up'
_VERIFY_ARTIST = 'Rick Astley'

_lock = threading.Lock()
# jwt_id -> entry. A usable entry always carries the raw 'token'; entries
# reloaded from disk on startup have token=None until the same token is
# contributed again (nodes re-contribute on connect).
_pool = {}
_rr_counter = 0
_ttl = 86400 * 7            # a year-old contribution is stale, drop it


def _token_id(token):
    return hashlib.sha256(token.encode('utf-8')).hexdigest()[:12]


def _token_hash(token):
    return hashlib.sha256(token.encode('utf-8')).hexdigest()


def _persist():
    os.makedirs('cache', exist_ok=True)
    try:
        records = [{
            'id': e['id'],
            'token_hash': e.get('token_hash'),
            'node_id': e.get('node_id'),
            'added': e.get('added'),
            'last_checked': e.get('last_checked'),
            'ok': bool(e.get('ok')),
        } for e in _pool.values()]
        with open(JWT_FILE, 'w', encoding='utf-8') as f:
            json.dump({'jwt_pool': records, 'updated': datetime.now().isoformat()}, f, indent=2)
    except Exception as e:
        print(f"  [JWT] persist failed: {e}")


def _load_persisted():
    if not os.path.exists(JWT_FILE):
        return 0
    try:
        with open(JWT_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        return 0
    loaded = 0
    for rec in (data.get('jwt_pool') or []):
        jid = rec.get('id')
        if not jid:
            continue
        _pool[jid] = {
            'id': jid,
            'token': None,
            'token_hash': rec.get('token_hash'),
            'node_id': rec.get('node_id'),
            'added': rec.get('added'),
            'last_checked': rec.get('last_checked'),
            'ok': bool(rec.get('ok')),
        }
        loaded += 1
    return loaded


def contribute_jwt(token, node_id=None):
    """Add (or refresh) a token in the pool. Returns {'ok', 'id', 'num_pool'}."""
    if not isinstance(token, str) or len(token) < 20:
        return {'ok': False, 'error': 'token too short or missing'}
    jid = _token_id(token)
    now = datetime.now().isoformat()
    with _lock:
        prev = _pool.get(jid)
        was_ok = bool(prev and prev.get('ok')) if prev else None
        entry = {
            'id': jid,
            'token': token,
            'token_hash': _token_hash(token),
            'node_id': node_id,
            'added': (prev or {}).get('added', now),
            'last_checked': now,
            'ok': was_ok,
        }
        _pool[jid] = entry
        if len(_pool) > POOL_MAX:
            # drop the oldest-added entries past the cap
            for old in sorted(_pool.values(), key=lambda e: e.get('added', ''))[:len(_pool) - POOL_MAX]:
                _pool.pop(old['id'], None)
        n = len(_pool)
    _persist()
    print(f"  [JWT] contributed {jid} node={node_id or '-'} pool={n}")
    return {'ok': True, 'id': jid, 'num_pool': n}


def remove_jwt(jid):
    with _lock:
        was = _pool.pop(jid, None)
    if was:
        _persist()
        return True
    return False


def list_jwt():
    """Safe listing for the admin panel: never exposes raw tokens."""
    with _lock:
        items = []
        for e in _pool.values():
            items.append({
                'id': e['id'],
                'token_hash': (e.get('token_hash') or '')[:16],
                'node_id': e.get('node_id'),
                'added': e.get('added'),
                'last_checked': e.get('last_checked'),
                'ok': bool(e.get('ok')),
                'live': bool(e.get('token')),
            })
        items.sort(key=lambda x: x['added'] or '', reverse=True)
        return items


def pick_jwt():
    """Best available token, or None. Prefers tokens already verified good,
    then unverified fresh ones, rotating across survivors round-robin."""
    global _rr_counter
    now = time_module.time()
    with _lock:
        candidates = [e for e in _pool.values() if e.get('token')]
        if not candidates:
            return None
        candidates.sort(key=lambda e: (0 if e.get('ok') else 1, e.get('last_used', 0.0)))
        chosen = candidates[_rr_counter % len(candidates)]
        _rr_counter += 1
        chosen['last_used'] = now
        return chosen['token']


def _probe_token(token, via_node=None):
    """Ask Cubey whether a token still works. Returns True/False for a
    definite verdict, or None when the probe itself failed (rate limited,
    timeout...) -- None must NOT be treated as "dead"."""
    url = "https://lyrics.api.dacubeking.com/v2/lyrics"
    data = {
        "videoId": _VERIFY_VIDEO_ID,
        "song": _VERIFY_SONG,
        "artist": _VERIFY_ARTIST,
        "duration": "212",
        "alwaysFetchMetadata": "false",
        "token": token,
    }
    try:
        if via_node:
            from .nodes import relay_http_request
            relayed = relay_http_request(via_node, 'POST', url, data=data, timeout=20)
            if relayed is None:
                return None
            status, text = relayed
        else:
            import requests as _requests
            resp = _requests.post(url, data=data, timeout=20)
            status, text = resp.status_code, resp.text
    except Exception as e:
        print(f"  [JWT] probe error: {e}")
        return None
    if status in (401, 403):
        return False
    if status == 200:
        return True
    return None


def check_all(evict=True):
    """Re-probe every live token, update ok/last_checked, evict the dead.
    Returns a short summary dict for the admin endpoint."""
    with _lock:
        live = [dict(e) for e in _pool.values() if e.get('token')]
    ok_n = dead_n = unknown_n = 0
    for entry in live:
        verdict = _probe_token(entry['token'], via_node=pick_node())
        entry['last_checked'] = datetime.now().isoformat()
        if verdict is True:
            ok_n += 1
            entry['ok'] = True
            with _lock:
                if entry['id'] in _pool:
                    _pool[entry['id']]['ok'] = True
                    _pool[entry['id']]['last_checked'] = entry['last_checked']
        elif verdict is False:
            dead_n += 1
            entry['ok'] = False
            print(f"  [JWT] {entry['id']} probed DEAD, evicting")
            if evict:
                remove_jwt(entry['id'])
        else:
            unknown_n += 1
    _persist()
    return {'ok': ok_n, 'dead': dead_n, 'unknown': unknown_n, 'total': len(_pool)}


def _check_loop():
    while True:
        time_module.sleep(VERIFY_INTERVAL)
        try:
            check_all(evict=True)
        except Exception as e:
            print(f"  [JWT] check loop error: {e}")

_started = False
_start_lock = threading.Lock()


def start_jwt_pool():
    """Load persisted records and launch the background verifier once."""
    global _started
    with _start_lock:
        if _started:
            return
        n = _load_persisted()
        if n:
            print(f"  [JWT] loaded {n} persisted token record(s) from cache/jwt.json")
        t = threading.Thread(target=_check_loop, daemon=True, name='jwt-pool-checker')
        t.start()
        _started = True