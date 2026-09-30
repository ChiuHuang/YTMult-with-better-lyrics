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
# Raw tokens persist in database/jwt.json (explicit admin tradeoff: without it
# every restart/update wipes the pool and Cubey goes dark until devices
# re-contribute). Only hashes are ever served to clients. A background
# thread re-probes each live token on a timer; a token is evicted only
# after two consecutive dead verdicts (twice rule). pick_jwt() is the
# primary credential for a request that carried no JWT of its own: it
# round-robins the survivors (never a token a probe already called dead,
# unless every one is), and with_meta=True hands back log-safe metadata so
# the caller can print which token it used without printing the token.
import json
import os
import threading
import hashlib
import time as time_module
from datetime import datetime

from .nodes import pick_node
from .paths import JWT_FILE, ensure_data_dir
VERIFY_INTERVAL = 300       # seconds between full pool probes
POOL_MAX = 32               # newest-first cap; oldest evicted
_VERIFY_VIDEO_ID = 'dQw4w9WgXcQ'
_VERIFY_SONG = 'Never Gonna Give You Up'
_VERIFY_ARTIST = 'Rick Astley'

_lock = threading.Lock()
# jwt_id -> entry. A usable entry always carries the raw 'token' (persisted
# to disk, restored on startup); legacy hash-only records have token=None
# until the same token is contributed again.
_pool = {}
_rr_counter = 0
_ttl = 86400 * 7            # contributions older than this are dropped on load


def _token_id(token):
    return hashlib.sha256(token.encode('utf-8')).hexdigest()[:12]


def _token_hash(token):
    return hashlib.sha256(token.encode('utf-8')).hexdigest()


def _persist():
    ensure_data_dir()
    try:
        records = [{
            'id': e['id'],
            # Raw tokens ARE persisted (explicit admin choice): without this
            # every restart/update wipes the pool and Cubey goes dark until
            # devices re-contribute. Only hashes are ever served to clients.
            'token': e.get('token'),
            'token_hash': e.get('token_hash'),
            'node_id': e.get('node_id'),
            'added': e.get('added'),
            'last_checked': e.get('last_checked'),
            'last_used': e.get('last_used'),
            'last_ok': e.get('last_ok'),
            'ok': bool(e.get('ok')),
            'successes': int(e.get('successes', 0)),
            'fails': int(e.get('fails', 0)),
            'verdict': e.get('verdict', 'unverified'),
        } for e in _pool.values()]
        with open(JWT_FILE, 'w', encoding='utf-8') as f:
            json.dump({'jwt_pool': records, 'updated': datetime.now().isoformat()}, f, indent=2)
    except Exception as e:
        print(f"  [JWT] persist failed: {e}")


def _safe_int(v, dflt=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return dflt


def _load_persisted():
    if not os.path.exists(JWT_FILE):
        return 0
    try:
        with open(JWT_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        return 0
    now_ts = time_module.time()
    loaded = 0
    for rec in (data.get('jwt_pool') or []):
        try:
            jid = rec.get('id')
            if not jid:
                continue
            added = rec.get('added') or ''
            try:
                added_age = now_ts - datetime.fromisoformat(added).timestamp()
            except Exception:
                added_age = 0
            if added_age > _ttl:
                continue  # ancient contribution, drop
            _pool[jid] = {
                'id': jid,
                'token': rec.get('token'),
                'token_hash': rec.get('token_hash'),
                'node_id': rec.get('node_id'),
                'added': added,
                'last_checked': rec.get('last_checked'),
                'last_used': rec.get('last_used') or 0.0,
                'last_ok': rec.get('last_ok'),
                'ok': bool(rec.get('ok')),
                'successes': _safe_int(rec.get('successes')),
                'fails': _safe_int(rec.get('fails')),
                'verdict': rec.get('verdict') or 'unverified',
            }
            loaded += 1
        except Exception:
            continue
    return loaded


def contribute_jwt(token, node_id=None):
    """Add (or refresh) a token in the pool. Returns {'ok', 'id', 'num_pool'}."""
    if not isinstance(token, str) or len(token) < 20:
        return {'ok': False, 'error': 'token too short or missing'}
    jid = _token_id(token)
    now = datetime.now().isoformat()
    with _lock:
        prev = _pool.get(jid)
        # Fast path: identical token already contributed by this same source
        # (e.g. every device lyric request re-sends its JWT) -- avoid the disk
        # write churn. A legacy hash-only record (token=None) still falls
        # through so we re-populate the raw token on this live contribution.
        if prev is not None and prev.get('token') == token and (prev.get('node_id') or '') == (node_id or ''):
            return {'ok': True, 'id': jid, 'num_pool': len(_pool)}
        was_ok = bool(prev and prev.get('ok')) if prev else None
        entry = {
            'id': jid,
            'token': token,
            'token_hash': _token_hash(token),
            'node_id': node_id,
            'added': (prev or {}).get('added', now),
            'last_checked': now,
            'last_used': (prev or {}).get('last_used', 0.0),
            'last_ok': (prev or {}).get('last_ok'),
            'ok': was_ok,
            'successes': int((prev or {}).get('successes', 0)),
            'fails': 0,
            'verdict': 'unverified',
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
                'last_used': e.get('last_used'),
                'last_ok': e.get('last_ok'),
                'ok': bool(e.get('ok')),
                'live': bool(e.get('token')),
                'successes': int(e.get('successes', 0)),
                'fails': int(e.get('fails', 0)),
                'verdict': e.get('verdict', 'unverified'),
            })
        items.sort(key=lambda x: x['added'] or '', reverse=True)
        return items


def _entry_age_s(entry, now=None):
    """Seconds since the contribution, or -1.0 when 'added' is unusable."""
    now = time_module.time() if now is None else now
    try:
        return max(0.0, now - datetime.fromisoformat(entry.get('added') or '').timestamp())
    except Exception:
        return -1.0


def _entry_meta(entry, now=None, pool_size=0, probation=False):
    """Log-safe view of one entry -- id/counters/verdict only, never the raw
    token, so a caller can print it without leaking a credential."""
    now = time_module.time() if now is None else now
    return {
        'id': entry.get('id'),
        'age_s': _entry_age_s(entry, now),
        'successes': _safe_int(entry.get('successes')),
        'fails': _safe_int(entry.get('fails')),
        'last_ok': entry.get('last_ok'),
        'ok': bool(entry.get('ok')),
        'verdict': entry.get('verdict') or 'unverified',
        'pool_size': pool_size,
        # True when the served token itself carries an unevicted dead strike
        # (every live token did) -- the caller should say so out loud.
        'probation': bool(probation),
    }


def _pick_sort_key(e):
    return (0 if e.get('ok') else 1,
            _safe_int(e.get('fails')),
            float(e.get('last_used') or 0.0))


def pick_jwt(with_meta=False):
    """Best available token, or None -- the server's primary Cubey credential,
    so a device request no longer has to wait for its own Turnstile token.

    Selection: verified-good first, then unverified/fresh, then fewest fails,
    then least recently used; round-robin over that order so the pool spreads
    load instead of hammering one token. with_meta=True returns
    (token, meta) where meta is _entry_meta() (no token) so the caller can log
    which one it used; the default return stays the bare token.

    Fix vs the first version: a token a probe already declared dead
    (fails >= 1, verdict 'dead xN') is no longer handed out while a healthier
    one exists -- rotation used to walk the whole sorted list, so a known-dead
    token served 1-in-N requests and burned a whole Cubey stage on 401s. The
    twice rule still owns eviction; if EVERY live token is dead-once we serve
    the least-bad of them (probation=True) rather than skipping Cubey, so a
    stale pool degrades instead of blacking out the best provider. Purely
    in-memory: never probes the network, so it cannot stall a lyrics request.
    """
    global _rr_counter
    now = time_module.time()
    with _lock:
        live = [e for e in _pool.values() if e.get('token')]
        if not live:
            return (None, {'id': None, 'pool_size': 0}) if with_meta else None
        live.sort(key=_pick_sort_key)
        best_fails = _safe_int(live[0].get('fails'))
        survivors = [e for e in live if _safe_int(e.get('fails')) <= best_fails]
        chosen = survivors[_rr_counter % len(survivors)]
        _rr_counter += 1
        chosen['last_used'] = now
        if not with_meta:
            return chosen['token']
        # probation = the token we are handing out still carries an unevicted
        # dead strike (true only when every live token did).
        return chosen['token'], _entry_meta(chosen, now=now, pool_size=len(live),
                                           probation=_safe_int(chosen.get('fails')) > 0)


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


def _strike_dead(jid, now_iso, via, evict=True):
    """Book ONE definite-dead (401/403) strike against a pool entry: fails
    += 1, ok False, verdict 'dead xN'. The TWICE rule still owns removal --
    evict only once the second consecutive strike lands, exactly as the
    prober has always done. An entry that vanished meanwhile is left alone.

    Shared by check_all and note_failure so a live Cubey 401 counts with
    identical semantics to a probe verdict. Returns (fails, known); an entry
    that is not in the pool (unknown token, or one that vanished mid-sweep)
    is a silent no-op -- there is nothing to strike.
    """
    with _lock:
        cur = _pool.get(jid)
        known = cur is not None
        fails = int(cur.get('fails', 0)) + 1 if known else 1
        if known:
            cur['fails'] = fails
            cur['ok'] = False
            cur['verdict'] = f'dead x{fails}'
            cur['last_checked'] = now_iso
    if not known:
        return fails, False
    # Only remove when proven unusable twice in a row.
    if fails >= 2:
        print(f"  [JWT] {jid} {via} DEAD twice, evicting")
        if evict:
            remove_jwt(jid)
    else:
        print(f"  [JWT] {jid} {via} DEAD once, keeping (twice rule)")
    return fails, known


def note_failure(token, reason=''):
    """Report a definite Cubey auth failure (401/403) seen by a LIVE request,
    so a dead token leaves rotation immediately instead of staying the pool's
    first pick until the next 300s probe sweep -- each request in the meantime
    burned a whole Cubey stage on it. Same bookkeeping as the prober
    (_strike_dead): one strike only demotes, the second consecutive one
    evicts, and the pick policy/threshold are untouched.

    Only a definite 401/403 may be reported. A 429, a timeout or any other
    unknown outcome must NOT be reported here: the pool's own rule is that
    only proven-dead verdicts count (see _probe_token), and a rate limit
    would otherwise evict a perfectly good token.

    Never raises, never logs the raw token, no-op for a None/unknown token.
    Returns True when the token was known to the pool."""
    try:
        if not isinstance(token, str) or not token:
            return False
        jid = _token_id(token)
        # Reason is caller text that lands in a log line: collapse it to one
        # short single-line token so a weird value cannot inject log lines.
        tag = ' '.join((reason or '').split())[:40] or 'api'
        fails, known = _strike_dead(jid, datetime.now().isoformat(),
                                   f'note_failure({tag})')
        if known and fails < 2:
            _persist()
        return known
    except Exception as e:
        print(f"  [JWT] note_failure error: {e}")
        return False


def check_all(evict=True):
    """Re-probe every live token, update metadata, evict the twice-dead.
    Twice rule: a token is removed only after TWO consecutive definite-dead
    verdicts (401/403). Unknown outcomes (timeout/rate-limit) never count.
    Returns a short summary dict for the admin endpoint."""
    with _lock:
        live = [dict(e) for e in _pool.values() if e.get('token')]
    ok_n = dead_n = unknown_n = 0
    now_iso = datetime.now().isoformat()
    for entry in live:
        verdict = _probe_token(entry['token'], via_node=pick_node())
        entry['last_checked'] = now_iso
        if verdict is True:
            ok_n += 1
            with _lock:
                if entry['id'] in _pool:
                    cur = _pool[entry['id']]
                    cur['ok'] = True
                    cur['verdict'] = 'ok'
                    cur['fails'] = 0
                    cur['successes'] = int(cur.get('successes', 0)) + 1
                    cur['last_ok'] = now_iso
                    cur['last_checked'] = now_iso
        elif verdict is False:
            fails, _known = _strike_dead(entry['id'], now_iso, 'probe', evict=evict)
            if fails >= 2:
                dead_n += 1
            else:
                unknown_n += 1
        else:
            unknown_n += 1
            with _lock:
                if entry['id'] in _pool:
                    # Keep a probation label ('dead x1') so the table still
                    # shows the pending second strike.
                    if int(_pool[entry['id']].get('fails', 0)) == 0:
                        _pool[entry['id']]['verdict'] = 'unknown'
                    _pool[entry['id']]['last_checked'] = now_iso
    _persist()
    try:
        from .app import _sse_broadcast
        _sse_broadcast('jwt', {'ok': ok_n, 'dead': dead_n, 'unknown': unknown_n,
                               'total': len(_pool)})
    except Exception:
        pass
    return {'ok': ok_n, 'dead': dead_n, 'unknown': unknown_n, 'total': len(_pool)}


def live_jwt_tokens():
    """Raw live tokens, best-first, for the node JWT sync. Same ordering as
    pick_jwt so the token a node hands back is the one this server would have
    served. Never logged, never persisted here -- it only travels over an
    already-authenticated node WebSocket."""
    with _lock:
        live = [e for e in _pool.values() if e.get('token')]
        live.sort(key=_pick_sort_key)
        return [e['token'] for e in live]


def _top_up_from_nodes():
    """Called when the pool has no usable token: ask the connected nodes for
    one they are holding (see nodes._jwt_sync_loop for the push side) and
    contribute it so it persists and takes part in normal rotation. Background
    only -- never called from a lyrics request."""
    with _lock:
        has_live = any(e.get('token') for e in _pool.values())
    if has_live:
        return False
    from .nodes import ask_nodes_for_jwt
    node_id, token = ask_nodes_for_jwt(timeout=2.0)
    if not token:
        return False
    res = contribute_jwt(token, node_id=None)
    print(f"  [JWT] topped up from node {node_id}: ok={res.get('ok')} pool={res.get('num_pool')}")
    return bool(res.get('ok'))


def _check_loop():
    while True:
        time_module.sleep(VERIFY_INTERVAL)
        try:
            _top_up_from_nodes()
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
            print(f"  [JWT] loaded {n} persisted token record(s) from {JWT_FILE}")
        t = threading.Thread(target=_check_loop, daemon=True, name='jwt-pool-checker')
        t.start()
        _started = True
