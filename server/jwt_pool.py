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
            # Per-REQUEST counters (jwt_stats.note_request). 'successes' above is
            # probe successes only, so it says nothing about real traffic.
            'requests': int(e.get('requests', 0)),
            'req_ok': int(e.get('req_ok', 0)),
            'req_auth_fail': int(e.get('req_auth_fail', 0)),
            'req_other_fail': int(e.get('req_other_fail', 0)),
            'probes': int(e.get('probes', 0)),
            'first_used': e.get('first_used'),
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
                # Past the contribution TTL: it is leaving the pool, so it gets a
                # ledger record like any other departure (reason 'ttl'), otherwise
                # the chart would show a pool that shrank with no explanation.
                _retire({**rec, 'token': rec.get('token')}, 'ttl')
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
                'requests': _safe_int(rec.get('requests')),
                'req_ok': _safe_int(rec.get('req_ok')),
                'req_auth_fail': _safe_int(rec.get('req_auth_fail')),
                'req_other_fail': _safe_int(rec.get('req_other_fail')),
                'probes': _safe_int(rec.get('probes')),
                'first_used': rec.get('first_used'),
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
            # A re-contribution is a REFRESH, not a new token: the request
            # counters carry over, because they describe the same credential and
            # a graph that reset to zero on every device poll would be a lie.
            # Only the strike state and the verdict start clean.
            'requests': int((prev or {}).get('requests', 0)),
            'req_ok': int((prev or {}).get('req_ok', 0)),
            'req_auth_fail': int((prev or {}).get('req_auth_fail', 0)),
            'req_other_fail': int((prev or {}).get('req_other_fail', 0)),
            'probes': int((prev or {}).get('probes', 0)),
            'first_used': (prev or {}).get('first_used'),
            'verdict': 'unverified',
        }
        _pool[jid] = entry
        if len(_pool) > POOL_MAX:
            # drop the oldest-added entries past the cap
            for old in sorted(_pool.values(), key=lambda e: e.get('added', ''))[:len(_pool) - POOL_MAX]:
                _retire(_pool.pop(old['id'], None), 'pool_cap')
        n = len(_pool)
    try:
        from .jwt_stats import note_contributed
        note_contributed()
    except Exception:
        pass
    _persist()
    print(f"  [JWT] contributed {jid} node={node_id or '-'} pool={n}")
    return {'ok': True, 'id': jid, 'num_pool': n}


def remove_jwt(jid, reason='removed'):
    """Take a token out of the pool.

    `reason` is what the ledger shows next to the death, so it is not a detail:
    'dead_twice' (two proven 401/403 strikes) is a different fact from 'removed'
    (an operator deleted it) or 'ttl'. The retirement record is written even when
    the id was not in the pool, because a double remove must not count as two
    deaths -- but it is a no-op when nothing was known, so there is no record to
    write."""
    with _lock:
        was = _pool.pop(jid, None)
    if was:
        _retire(was, reason)
        _persist()
        return True
    return False


def _retire(entry, reason):
    """Write the ledger record for a departing token. Never raises."""
    try:
        from .jwt_stats import retire
        retire(entry, reason)
    except Exception as e:
        print(f"  [JWT] retire bookkeeping failed: {e}")


def note_request(token, outcome, reason=''):
    """One real Cubey request made with this token -- the single bookkeeping
    entry point for it.

    outcome: 'ok' (200), 'auth' (401/403), 'other' (429/5xx/timeout).

    'auth' ALSO strikes the token, because this is the only place the pool
    learns that a credential was rejected. It used to be two calls at every HTTP
    site (`note_request` to count, `note_failure` to strike), which is a trap:
    forget the second and a dead token keeps serving requests forever with no
    error anywhere. One call site, one meaning.

    Only a DEFINITE auth rejection strikes. A 429, a 5xx or a timeout is a
    request that did not work, not a dead token, and the pool's rule has always
    been that unknown verdicts never count (see _probe_token).

    Never raises, never stores the token. Returns True when the token was known
    to the pool (i.e. when the counters had somewhere to go)."""
    try:
        known = False
        jid = None
        field = {'ok': 'req_ok', 'auth': 'req_auth_fail',
                 'other': 'req_other_fail'}.get(outcome, 'req_other_fail')
        if isinstance(token, str) and token:
            jid = _token_id(token)
            with _lock:
                e = _pool.get(jid)
                if e is not None:
                    known = True
                    e['requests'] = int(e.get('requests', 0)) + 1
                    e[field] = int(e.get(field, 0)) + 1
                    if not e.get('first_used'):
                        e['first_used'] = datetime.now().isoformat()
        # Counted even for an unknown token: the request happened and must show
        # up in the totals, it just cannot be attributed to a pool entry.
        from .jwt_stats import note_request as _nr
        _nr(jid if known else None, outcome)
        if outcome == 'auth' and known:
            tag = ' '.join((reason or 'api').split())[:40]
            _strike_dead(jid, datetime.now().isoformat(), f'note_request({tag})')
            _persist()
        return known
    except Exception as ex:
        print(f"  [JWT] note_request error: {ex}")
        return False


def list_jwt():
    """Safe listing for the admin panel: never exposes raw tokens."""
    now = time_module.time()
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
                'requests': int(e.get('requests', 0)),
                'req_ok': int(e.get('req_ok', 0)),
                'req_auth_fail': int(e.get('req_auth_fail', 0)),
                'req_other_fail': int(e.get('req_other_fail', 0)),
                'probes': int(e.get('probes', 0)),
                'first_used': e.get('first_used'),
                'idle_s': round(now - float(e.get('last_used') or 0), 1)
                          if e.get('last_used') else None,
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
            # 'dead_twice' is the reason the death chart groups on; a probe and a
            # live request that both landed the second strike are the same fact.
            remove_jwt(jid, reason='dead_twice')
    else:
        print(f"  [JWT] {jid} {via} DEAD once, keeping (twice rule)")
    return fails, known


def note_failure(token, reason=''):
    """Deprecated alias. It is kept because it names the one thing callers care
    about ("tell the pool this token died"), but the counting AND the strike now
    live in one function (note_request) -- two entry points for a single HTTP
    outcome is exactly how a strike goes missing without an error.

    Only a definite 401/403 may be reported. A 429, a timeout or any other
    unknown outcome must NOT be reported here: the pool's own rule is that
    only proven-dead verdicts count (see _probe_token), and a rate limit
    would otherwise evict a perfectly good token.

    Never raises, never logs the raw token, no-op for a None/unknown token.
    Returns True when the token was known to the pool."""
    # Reason is caller text that lands in a log line: note_request collapses
    # it to one short single-line token so a weird value cannot inject lines.
    return note_request(token, 'auth', reason=reason)


def _note_probe(ok):
    """Count one verifier probe. Separate from requests on purpose: the probe is
    the pool asking Cubey 'still good?', and folding it into the traffic counters
    would make a token nobody used look busy."""
    try:
        from .jwt_stats import note_probe
        note_probe(ok)
    except Exception as e:
        print(f"  [JWT] probe bookkeeping failed: {e}")


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
                    cur['probes'] = int(cur.get('probes', 0)) + 1
                    cur['last_ok'] = now_iso
                    cur['last_checked'] = now_iso
            _note_probe(True)
        elif verdict is False:
            fails, _known = _strike_dead(entry['id'], now_iso, 'probe', evict=evict)
            _note_probe(False)
            if fails >= 2:
                dead_n += 1
            else:
                unknown_n += 1
        else:
            unknown_n += 1
            _note_probe(False)
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
