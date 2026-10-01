# Per-request accounting for the Cubey JWT pool, plus a ledger of retired
# tokens.
#
# Why this file exists: jwt_pool tracked `successes`, but that counter only ever
# moved for PROBES. Real traffic -- the thing that actually burns a token -- was
# invisible, so the two questions that decide how the pool should be operated
# could not be answered:
#
#   * how many requests did this token serve, and how is that spread across the
#     pool (is one token doing all the work while the rest idle?)
#   * how many requests did a token serve BEFORE it died -- i.e. what is a token
#     actually worth, and when should the dashboard warn the operator that the
#     pool is about to run dry?
#
# remove_jwt() used to pop the entry and that was the end of it: a dead token
# took its history with it. The ledger keeps the final counters, the reason and
# the lifetime, so the death distribution is a fact rather than a guess.
#
# Two rules the counters obey:
#   * a PROBE is not a request. Probes are the pool asking Cubey "still good?"
#     every 300s; counting them would make a token nobody used look busy. They
#     are counted separately (`probes`) and shown separately.
#   * only a DEFINITE auth rejection is death. A 429, a 5xx or a timeout is a
#     request that did not work, not a dead token -- jwt_pool._probe_token and
#     note_failure own that rule and this file does not second-guess it.
#
# Nothing here ever raises: this is called from the fetch path, and a metrics
# ledger must not be able to fail a lyrics request.
import json
import os
import threading
import time as time_module
from collections import deque
from datetime import datetime, timedelta

from .paths import JWT_LEDGER_FILE

_PATH = JWT_LEDGER_FILE

# 1000 retired tokens is a lot of history and a small file (~300KB). The ledger
# is for questions like "what did a token used to be worth", which are answered
# by recent history, not by the pool's first week.
_RETIRED_CAP = 1000
# Auth refusals that did not retire a token. Small on purpose: this is a
# recent-events feed for a warning badge, not an audit log, and the log file
# keeps the full history.
_AUTH_NOTES_CAP = 100
# 72 hourly buckets is three days of traffic: long enough to see a weekend, short
# enough that the file stays tiny.
_HOURS_KEPT = 72
# An hour bucket with no traffic yet is still emitted (as a zero) so a chart has
# a continuous axis instead of collapsing quiet hours.
_LEDGER_SAVE_EVERY = 20

_LOCK = threading.Lock()
_STATE = None
_DIRTY = 0
_LAST_SAVE = 0.0
_SAVE_EVERY_S = 30


def _blank():
    return {'hours': {}, 'retired': [], 'auth_notes': [], 'totals': {
        'requests': 0, 'ok': 0, 'auth_fail': 0, 'other_fail': 0,
        'probes': 0, 'probe_ok': 0, 'contributed': 0, 'auth_notes': 0,
        'auth_unknown': 0}}


def _hour_key(ts=None):
    ts = time_module.time() if ts is None else ts
    dt = datetime.fromtimestamp(ts)
    return dt.replace(minute=0, second=0, microsecond=0).isoformat()


def _load():
    global _STATE
    with _LOCK:
        if _STATE is not None:
            return _STATE
        try:
            with open(_PATH, 'r', encoding='utf-8') as f:
                d = json.load(f)
            if not isinstance(d, dict):
                raise ValueError('not an object')
            hours = d.get('hours') if isinstance(d.get('hours'), dict) else {}
            retired = d.get('retired') if isinstance(d.get('retired'), list) else []
            notes = d.get('auth_notes') if isinstance(d.get('auth_notes'), list) else []
            totals = d.get('totals') if isinstance(d.get('totals'), dict) else {}
            _STATE = _blank()
            _STATE['hours'] = {k: v for k, v in hours.items() if isinstance(v, dict)}
            _STATE['retired'] = [r for r in retired if isinstance(r, dict)][-_RETIRED_CAP:]
            _STATE['auth_notes'] = [r for r in notes if isinstance(r, dict)][-_AUTH_NOTES_CAP:]
            _STATE['totals'].update({k: v for k, v in totals.items()
                                     if isinstance(v, (int, float)) and not isinstance(v, bool)})
        except Exception:
            _STATE = _blank()
        return _STATE


def _save_locked():
    global _DIRTY, _LAST_SAVE
    try:
        os.makedirs(os.path.dirname(_PATH) or '.', exist_ok=True)
        tmp = _PATH + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(_STATE, f)
        os.replace(tmp, _PATH)
    except Exception as e:
        print(f"  [JWTSTATS] [WARN] save failed: {e}")
    _DIRTY = 0
    _LAST_SAVE = time_module.time()


def _maybe_save_locked():
    global _DIRTY
    _DIRTY += 1
    if _DIRTY >= _LEDGER_SAVE_EVERY or time_module.time() - _LAST_SAVE >= _SAVE_EVERY_S:
        _save_locked()


def _bump(st, key, ts=None):
    """Add one to an hour bucket, creating it if needed."""
    hk = _hour_key(ts)
    b = st['hours'].get(hk)
    if b is None:
        b = {'requests': 0, 'ok': 0, 'auth_fail': 0, 'other_fail': 0,
             'probes': 0, 'probe_ok': 0, 'contributed': 0, 'retired': 0}
        st['hours'][hk] = b
    b[key] = int(b.get(key, 0)) + 1
    st['totals'][key] = int(st['totals'].get(key, 0)) + 1
    # Drop hours outside the window, or the file grows forever.
    cutoff = _hour_key(time_module.time() - _HOURS_KEPT * 3600)
    for old in [k for k in st['hours'] if k < cutoff]:
        st['hours'].pop(old, None)
    return b


def note_request(token_id, outcome):
    """One real Cubey request made with a token.

    outcome: 'ok' | 'auth' | 'other'. Counted in the hour bucket and the running
    totals. token_id may be None (a token the pool never saw): the request
    happened and must still appear in the totals, it just cannot be attributed to
    a pool entry. Never raises."""
    if outcome not in ('ok', 'auth', 'other'):
        outcome = 'other'
    key = {'ok': 'ok', 'auth': 'auth_fail', 'other': 'other_fail'}[outcome]
    try:
        st = _load()
        with _LOCK:
            _bump(st, 'requests')
            _bump(st, key)
            _maybe_save_locked()
    except Exception as e:
        print(f"  [JWTSTATS] [WARN] note_request failed: {e}")


def note_probe(ok):
    """One pool probe (the 300s verifier), kept apart from real traffic."""
    try:
        st = _load()
        with _LOCK:
            _bump(st, 'probes')
            if ok:
                _bump(st, 'probe_ok')
            _maybe_save_locked()
    except Exception as e:
        print(f"  [JWTSTATS] [WARN] note_probe failed: {e}")


def note_contributed():
    """A token entered the pool."""
    try:
        st = _load()
        with _LOCK:
            _bump(st, 'contributed')
            _maybe_save_locked()
    except Exception:
        pass


def note_auth(reason, where, verdict):
    """A 401/403 whose `reason` did NOT retire a token.

    This is the file's early-warning channel. `verdict` is jwt_pool's
    classification: 'benign' for a reason we know is about the request
    (missing_token, malformed) and 'unknown' for one this build has never seen.
    'unknown' is the interesting one -- it means the provider's vocabulary moved
    under us, and the dashboard turns it into a visible warning instead of
    letting it pass silently. Never raises, never stores a token."""
    try:
        st = _load()
        now = datetime.now().isoformat()
        with _LOCK:
            notes = st.setdefault('auth_notes', [])
            notes.append({'reason': reason or 'none', 'where': where or '?',
                          'verdict': verdict or 'unknown', 'at': now})
            del notes[:-_AUTH_NOTES_CAP]
            st['totals']['auth_notes'] = int(st['totals'].get('auth_notes', 0)) + 1
            if verdict == 'unknown':
                st['totals']['auth_unknown'] = int(st['totals'].get('auth_unknown', 0)) + 1
            _maybe_save_locked()
    except Exception as e:
        print(f"  [JWTSTATS] [WARN] note_auth failed: {e}")


def retire(entry, reason):
    """Record a token that is leaving the pool, with its final counters.

    Called from every exit: evicted after two dead strikes, removed by an
    operator, dropped as past the TTL or pushed out by the pool cap. `reason` is
    the whole point of the ledger -- "died" and "operator deleted it" are very
    different facts and the chart labels them differently.

    Never raises. Idempotent per (id, retired_at) so a double remove cannot
    double-count a death."""
    try:
        if not entry or not entry.get('id'):
            return None
        now = datetime.now()
        rec = {
            'id': entry.get('id'),
            'node_id': entry.get('node_id'),
            'added': entry.get('added'),
            'retired_at': now.isoformat(),
            'reason': reason or 'unknown',
            'requests': int(entry.get('requests') or 0),
            'req_ok': int(entry.get('req_ok') or 0),
            'req_auth_fail': int(entry.get('req_auth_fail') or 0),
            'req_other_fail': int(entry.get('req_other_fail') or 0),
            'probes': int(entry.get('probes') or 0),
            'fails': int(entry.get('fails') or 0),
            'last_used': entry.get('last_used') or 0.0,
            'last_ok': entry.get('last_ok'),
        }
        # lifetime: contribution -> retirement, falling back to last use when the
        # contribution timestamp is unusable, so the chart shows real time-in-service
        added = entry.get('added')
        life = None
        try:
            life = (now - datetime.fromisoformat(added)).total_seconds()
        except Exception:
            try:
                life = (now - datetime.fromtimestamp(float(entry.get('last_used') or 0))).total_seconds()
            except Exception:
                life = None
        rec['lifetime_s'] = round(life, 1) if life and life >= 0 else None
        st = _load()
        with _LOCK:
            st['retired'].append(rec)
            if len(st['retired']) > _RETIRED_CAP:
                del st['retired'][:-_RETIRED_CAP]
            _bump(st, 'retired')
            _maybe_save_locked()
        print(f"  [JWT] retired {rec['id']} ({rec['reason']}) after {rec['requests']} request(s)")
        return rec
    except Exception as e:
        print(f"  [JWTSTATS] [WARN] retire failed: {e}")
        return None


def _pct(ordered, p):
    """Nearest-rank percentile over a sorted list (see latency_stats for why
    interpolation is wrong here too)."""
    if not ordered:
        return None
    import math
    n = len(ordered)
    idx = int(math.ceil((p / 100.0) * n)) - 1
    return ordered[max(0, min(n - 1, idx))]


# Buckets for "how many requests did a token serve before it died". Fixed edges,
# not data-derived: a histogram whose bins move with the data cannot be compared
# against last week's, and the low buckets are the interesting ones (a token that
# died after 3 requests is a very different problem from one that died after 3000).
DEATH_BUCKETS = [(0, 0), (1, 5), (6, 20), (21, 50), (51, 200), (201, 1000), (1001, None)]


def _bucket_label(lo, hi):
    if hi is None:
        return f'{lo}+'
    return f'{lo}' if lo == hi else f'{lo}-{hi}'


def _histogram(counts):
    out = [{'label': _bucket_label(lo, hi), 'count': 0, 'lo': lo, 'hi': hi}
           for lo, hi in DEATH_BUCKETS]
    for n in counts:
        for i, (lo, hi) in enumerate(DEATH_BUCKETS):
            if n >= lo and (hi is None or n <= hi):
                out[i]['count'] += 1
                break
    return out


def snapshot(now=None):
    """Everything the dashboard graphs need. Never raises.

    live_rows: one row per pool entry with its counters (jwt_pool adds them).
    retired rows and hour buckets come from here. Percentiles are over the
    requests-per-token population, so a token that served one request and a
    token that served nine thousand are both visible rather than averaged into
    one meaningless number."""
    now = time_module.time() if now is None else now
    try:
        st = _load()
        with _LOCK:
            hours = {k: dict(v) for k, v in st['hours'].items()}
            retired = [dict(r) for r in st['retired']]
            notes = [dict(n) for n in st.get('auth_notes', [])]
            totals = dict(st['totals'])
    except Exception:
        return {'live': [], 'retired': [], 'auth_notes': [], 'hourly': [],
                'death_histogram': [], 'summary': {}, 'totals': {}}

    # A continuous axis: every hour in the window, zeros included.
    now_hour = datetime.fromtimestamp(now).replace(minute=0, second=0, microsecond=0)
    hourly = []
    for i in range(_HOURS_KEPT - 1, -1, -1):
        hk = (now_hour - timedelta(hours=i)).isoformat()
        b = hours.get(hk) or {}
        hourly.append({'hour': hk,
                       'requests': int(b.get('requests', 0)),
                       'ok': int(b.get('ok', 0)),
                       'auth_fail': int(b.get('auth_fail', 0)),
                       'other_fail': int(b.get('other_fail', 0)),
                       'probes': int(b.get('probes', 0)),
                       'contributed': int(b.get('contributed', 0)),
                       'retired': int(b.get('retired', 0))})

    dead_counts = [int(r.get('requests') or 0) for r in retired
                   if r.get('reason') in ('dead', 'dead_twice')]
    lifetimes = [float(r['lifetime_s']) for r in retired if r.get('lifetime_s') is not None]
    reasons = {}
    for r in retired:
        reasons[r.get('reason') or 'unknown'] = reasons.get(r.get('reason') or 'unknown', 0) + 1

    day_ago = now - 86400
    req_24h = sum(h['requests'] for h in hourly if h['hour'] >= _hour_key(day_ago))
    died_24h = sum(1 for r in retired if (r.get('retired_at') or '') >= _hour_key(day_ago))

    return {
        'hourly': hourly,
        'retired': retired,
        'auth_notes': notes,
        'totals': totals,
        'death_histogram': _histogram(dead_counts),
        'summary': {
            'requests_total': int(totals.get('requests', 0)),
            'ok_total': int(totals.get('ok', 0)),
            'auth_fail_total': int(totals.get('auth_fail', 0)),
            'other_fail_total': int(totals.get('other_fail', 0)),
            'probes_total': int(totals.get('probes', 0)),
            # A NON-ZERO unknown count is the warning: it means Cubey answered
            # with a `reason` this build has never seen, so nobody can say
            # whether it retires a token -- and the rule is that it must not.
            'auth_notes_total': int(totals.get('auth_notes', 0)),
            'auth_unknown_total': int(totals.get('auth_unknown', 0)),
            'retired_total': len(retired),
            'dead_total': len(dead_counts),
            'requests_24h': req_24h,
            'died_24h': died_24h,
            # Per-token value, over every token ever seen (live + retired).
            'tokens_seen': int(totals.get('contributed', 0)) + len(retired),
            'death_requests_p50': _pct(sorted(dead_counts), 50),
            'death_requests_p95': _pct(sorted(dead_counts), 95),
            'death_requests_max': max(dead_counts) if dead_counts else None,
            'lifetime_s_p50': _pct(sorted(lifetimes), 50),
            'lifetime_s_p95': _pct(sorted(lifetimes), 95),
            'retire_reasons': reasons,
        },
    }


def clear():
    """Drop the history (dashboard action). The pool itself is untouched."""
    try:
        st = _load()
        with _LOCK:
            st['hours'] = {}
            st['retired'] = []
            st['auth_notes'] = []
            st['totals'] = _blank()['totals']
            _save_locked()
        return True
    except Exception:
        return False
