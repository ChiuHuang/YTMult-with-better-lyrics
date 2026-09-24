# CPU-bound lyrics normalize/score offload onto real OS processes (multicore).
#
# IMPORTANT: this module must import NOTHING from the server package (stdlib
# only). ProcessPoolExecutor on Windows spawns fresh interpreters that import
# this module; importing server.* there would boot the whole Flask app
# (background threads, file locks) inside every worker. The pure helpers
# below are exact mirrors of the canonical implementations -- keep in sync:
#   _pool_sanitize  <- cache.sanitize_lyrics_parts
#   _pool_last_part_duration_ms <- parsers_lrc.last_part_duration_ms
#   _pool_wbw_line_count / _pool_lyrics_score <- race._wbw_line_count / _lyrics_score
#   _POOL_PROVIDER_RANK <- race._PROVIDER_RANK
# A test should cross-check mirror vs canonical on sample data.
import concurrent.futures
import os
import threading

_POOL_PROVIDER_RANK = {
    'Musixmatch': 40,
    'bLyrics': 38,
    'BiniLyrics': 37,
    'AMLL': 37,
    'QQ': 36,
    'KuGou': 35,
    'NetEase': 33,
    'LRCLib': 30,
    'Unison': 20,
    'YouTube Music': 10,
}


def _pool_last_part_duration_ms(part_start, line_start, line_duration_ms,
                                next_line_start=None, prior_parts=None):
    max_gap = None
    if next_line_start is not None and next_line_start > part_start:
        max_gap = next_line_start - part_start
    elif line_duration_ms > 0:
        max_gap = max((line_start + line_duration_ms) - part_start, 150)
    durs = [p.get('durationMs', 0) for p in (prior_parts or []) if (p.get('durationMs') or 0) > 0]
    if durs:
        avg_dur = sum(durs) / len(durs)
        estimated = int(min(max(avg_dur * 1.25, 350), 1200))
    elif prior_parts:
        elapsed = part_start - line_start
        if elapsed > 0:
            avg_dur = elapsed / len(prior_parts)
            estimated = int(min(max(avg_dur * 1.25, 350), 1200))
        else:
            estimated = 500
    else:
        estimated = 500
    if max_gap is not None:
        estimated = min(estimated, max_gap)
    return max(estimated, 150)


def _pool_sanitize(lyrics):
    if not lyrics:
        return
    for l in lyrics:
        if not l.get('text'):
            continue
        l_ms = int(l.get('startTimeMs', l.get('time', 0) * 1000))
        l_dur = int(l.get('durationMs', l.get('duration', 0) * 1000))
        parts = l.get('parts')
        if not l.get('wordSynced') or not parts or len(parts) <= 1:
            l.pop('parts', None)
            l['wordSynced'] = False
            continue
        prev_ms = l_ms
        for pi, p in enumerate(parts):
            if not p.get('startTimeMs') or p['startTimeMs'] < l_ms:
                p['startTimeMs'] = prev_ms + (0 if pi == 0 else 200)
            prev_ms = p['startTimeMs']
        for pi in range(len(parts)):
            if pi < len(parts) - 1:
                if not parts[pi].get('durationMs'):
                    dur = parts[pi + 1]['startTimeMs'] - parts[pi]['startTimeMs']
                    parts[pi]['durationMs'] = max(dur, 0)
            else:
                raw_dur = parts[pi].get('durationMs', 0)
                prior_durs = [p.get('durationMs', 0) for p in parts[:-1] if (p.get('durationMs') or 0) > 0]
                avg_prior = (sum(prior_durs) / len(prior_durs)) if prior_durs else 400
                if raw_dur <= 0 or (raw_dur > 2000 and raw_dur > avg_prior * 2.0):
                    parts[pi]['durationMs'] = _pool_last_part_duration_ms(
                        parts[pi]['startTimeMs'], l_ms, l_dur, prior_parts=parts[:-1])


def _pool_wbw_line_count(res):
    n = 0
    for l in (res.get('lyrics') or []):
        parts = l.get('parts') or []
        if l.get('wordSynced') and len(parts) > 1:
            if len({p.get('startTimeMs') for p in parts}) > 1:
                n += 1
    return n


def _pool_lyrics_score(res):
    if not res or not res.get('lyrics'):
        return -1
    wbw = _pool_wbw_line_count(res)
    if wbw > 0:
        base = 2000
    elif res.get('synced'):
        base = 100
    else:
        base = 0
    prov = _POOL_PROVIDER_RANK.get(res.get('source', ''), 0)
    return base + prov + min(len(res.get('lyrics', [])), 50) * 0.01 + min(wbw, 100) * 0.1


def _normalize_job(payload):
    """Module-level so spawn pickles it. payload: {lyrics, synced, source}.
    Returns plain picklable metrics + normalized lyrics."""
    lyrics = payload.get('lyrics') or []
    synced = bool(payload.get('synced'))
    source = payload.get('source', '')
    try:
        _pool_sanitize(lyrics)
        res = {'lyrics': lyrics, 'synced': synced, 'source': source}
        wbw_count = _pool_wbw_line_count(res)
        word_synced = wbw_count > 0
        tier = 'wbw' if word_synced else ('line' if synced else 'plain')
        score = _pool_lyrics_score(res)
        return {'ok': True, 'lyrics': lyrics, 'synced': synced,
                'wordSynced': word_synced, 'tier': tier,
                'score': round(float(score), 3), 'lines': len(lyrics)}
    except Exception as e:
        return {'ok': False, 'error': str(e)}


def _normalize_in_process(payload):
    return _normalize_job(payload)


_POOL = None
_POOL_WORKERS = 0
_POOL_LOCK = threading.Lock()


def cpu_count():
    try:
        return max(1, os.cpu_count() or 1)
    except Exception:
        return 1


def _get_pool(workers):
    global _POOL, _POOL_WORKERS
    workers = max(1, min(int(workers or 1), cpu_count()))
    with _POOL_LOCK:
        if _POOL is None or _POOL_WORKERS != workers:
            if _POOL is not None:
                try:
                    _POOL.shutdown(wait=True)
                except Exception:
                    pass
            _POOL = concurrent.futures.ProcessPoolExecutor(max_workers=workers)
            _POOL_WORKERS = workers
        return _POOL


def normalize_many(payloads, workers=2):
    """Sanitize+score a list of {lyrics, synced, source} payloads on worker
    processes, preserving input order. Falls back to in-process on any pool
    error (locked-down Windows boxes, pickling edge cases)."""
    payloads = list(payloads or [])
    if not payloads:
        return []
    if len(payloads) == 1 or int(workers or 1) <= 1:
        return [_normalize_in_process(p) for p in payloads]
    try:
        pool = _get_pool(workers)
        return list(pool.map(_normalize_job, payloads, chunksize=1))
    except Exception as e:
        print(f"[PARSEPOOL] [WARN] process pool failed ({e}); using in-process fallback")
        return [_normalize_in_process(p) for p in payloads]


def shutdown_pool():
    global _POOL, _POOL_WORKERS
    with _POOL_LOCK:
        if _POOL is not None:
            try:
                _POOL.shutdown(wait=True)
            except Exception:
                pass
            _POOL = None
            _POOL_WORKERS = 0
