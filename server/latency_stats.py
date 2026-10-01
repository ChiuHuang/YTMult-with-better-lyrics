# Latency percentiles for the lyrics pipeline.
#
# Why percentiles and not averages: a lyrics fetch is bimodal. A cache hit is
# ~1ms, a cold Cubey + Cohere fetch is seconds, and a song nobody has lyrics
# for is slower than either. One mean over that population describes nothing
# you can act on; p50/p95/p99 do, which is also why the shape mirrors the
# metadata block the operator already knows from other services
# (route_latency / blocking_wait / sql_latency, p50+p95+p99 each).
#
# Two families are recorded, and they answer different questions:
#
#   per-song wall time -- how long one song takes end to end, plus the same
#                         number split by which tier won. Recorded inside
#                         fetch_all_lyrics, so every caller counts (device
#                         request, SSE stream, precache, playlist sync, bulk
#                         refetch, rebase) instead of only the one endpoint.
#   time to first tier -- how long until the FIRST line-synced candidate
#                         arrives, and until the FIRST word-by-word one does.
#                         This is what actually explains a slow song: a per-song
#                         p95 of 9s with ttf_line at 1.2s means the wait was the
#                         wbw second Cubey pass, not slow providers.
#
# Samples live in bounded RAM rings and are flushed to
# database/latency_stats.json on a throttle (the usage_stats pattern), so the
# dashboard keeps its history across a restart instead of starting at zero.
# Nothing here ever raises: a metrics file must never break a lyrics fetch.
import json
import math
import os
import threading
import time as time_module
from collections import deque

from .paths import LATENCY_STATS_FILE

_PATH = LATENCY_STATS_FILE

# Samples kept per metric. 1000 is the compromise: p99 is then the 10th-worst
# sample (still a real tail), and the whole file stays ~50KB so the dashboard
# can re-sort every refresh without noticing.
_MAX_SAMPLES = 1000

# Display order for the dashboard, primary metrics first. This is a UI order,
# NOT a whitelist: anything recorded under a key that is not listed here is
# still persisted and returned.
METRICS = (
    'song',        # per song, end to end (providers + translate)
    'ttf_line',    # time to the first line-synced candidate
    'ttf_wbw',     # time to the first word-by-word result
    'song_fetch',  # per song, providers only (stamped before translate)
    'song_wbw',    # per song, wbw winner
    'song_line',   # per song, line winner
    'song_plain',  # per song, plain winner
    'miss',        # per song, no provider found anything
    'cache',       # served from cache / node cache / in-flight wait
)

_LOCK = threading.Lock()
_S = None                 # {metric: deque([ms, ...])}
_DIRTY = 0
_LAST_SAVE = 0.0
_SAVE_EVERY_S = 30
_SAVE_EVERY_N = 25


def _blank():
    return {}


def _load():
    """Read the persisted rings once. A missing or corrupt file is empty, not
    an error -- metrics history is never worth failing a fetch over."""
    global _S
    with _LOCK:
        if _S is not None:
            return _S
        try:
            with open(_PATH, 'r', encoding='utf-8') as f:
                d = json.load(f)
            rings = {}
            if isinstance(d, dict):
                for k, vals in d.items():
                    if not isinstance(vals, list):
                        continue
                    clean = [float(v) for v in vals
                             if isinstance(v, (int, float)) and not isinstance(v, bool)]
                    if clean:
                        rings[str(k)] = deque(clean, maxlen=_MAX_SAMPLES)
            _S = rings
        except Exception:
            _S = _blank()
        return _S


def _save_locked():
    global _DIRTY, _LAST_SAVE
    try:
        os.makedirs(os.path.dirname(_PATH) or '.', exist_ok=True)
        tmp = _PATH + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump({k: list(v) for k, v in _S.items()}, f)
        os.replace(tmp, _PATH)
    except Exception as e:
        print(f"[LAT] [WARN] save failed: {e}")
    _DIRTY = 0
    _LAST_SAVE = time_module.time()


def record(metric, ms):
    """Add one millisecond sample. Never raises.

    NaN and negatives are dropped rather than stored: they would poison a
    percentile for every later read, and nothing legitimate produces them
    (every caller passes a perf_counter delta).
    """
    try:
        value = float(ms)
        if value != value or value < 0:  # NaN check first: NaN != NaN
            return
        s = _load()
        now = time_module.time()
        with _LOCK:
            global _DIRTY
            ring = s.get(metric)
            if not isinstance(ring, deque):
                ring = deque(maxlen=_MAX_SAMPLES)
                s[metric] = ring
            ring.append(round(value, 1))
            _DIRTY += 1
            if _DIRTY >= _SAVE_EVERY_N or now - _LAST_SAVE >= _SAVE_EVERY_S:
                _save_locked()
    except Exception as e:
        print(f"[LAT] [WARN] record failed: {e}")


def _percentile(ordered, p):
    """Nearest-rank percentile: the smallest sample at or above p% of them.

    Nearest-rank (not interpolation) because every number it returns is a
    measurement that really happened -- an interpolated p99 would invent a
    latency nobody ever saw, which is the wrong thing to show on a dashboard.
    """
    if not ordered:
        return None
    n = len(ordered)
    idx = int(math.ceil((p / 100.0) * n)) - 1
    return ordered[max(0, min(n - 1, idx))]


def _stats(values):
    """{n, min, p50, p95, p99, max, last} for one ring, ms, or None if empty."""
    if not values:
        return None
    ordered = sorted(values)
    return {
        'n': len(ordered),
        'min': round(ordered[0], 1),
        'p50': round(_percentile(ordered, 50), 1),
        'p95': round(_percentile(ordered, 95), 1),
        'p99': round(_percentile(ordered, 99), 1),
        'max': round(ordered[-1], 1),
        'last': round(values[-1], 1),
    }


def snapshot():
    """{'metrics': {...}, 'order': [...], 'updated_at': epoch}. Never raises.

    Empty metrics are present as None rather than missing, so the widget can
    render a metric with no samples yet instead of silently dropping a row.
    """
    try:
        s = _load()
        with _LOCK:
            # Listed order first, then anything recorded under a key this
            # version does not know (an older server's file, a renamed metric).
            keys = list(METRICS) + [k for k in s if k not in METRICS]
            metrics = {k: _stats(list(s.get(k) or ())) for k in keys}
            updated_at = max((v[-1] for v in s.values() if v), default=0.0)
        return {'metrics': metrics, 'order': keys, 'updated_at': updated_at}
    except Exception:
        return {'metrics': {}, 'order': list(METRICS), 'updated_at': 0.0}


def clear():
    """Drop every ring (dashboard "Clear"). Returns True if anything was
    dropped. Persists immediately so a restart cannot resurrect it."""
    try:
        s = _load()
        with _LOCK:
            global _DIRTY
            had = bool(s)
            s.clear()
            _DIRTY = 0
            _save_locked()
        return had
    except Exception:
        return False
