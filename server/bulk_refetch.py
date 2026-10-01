# Bulk refetch-all job: the admin picks scope/mode/lang/workers up front, and
# every knob (fetch threads, CPU processes, translate workers, batch size, the
# translate switch itself) stays editable WHILE it runs.
#
# Threads do network fetch, worker processes do the CPU-bound normalize+score
# (parse_pool), and translations go to the silent background queue
# (translate_queue) so fetching never blocks on Cohere -- but the job is not
# finished until that queue has drained, because a bulk run whose rows are
# still untranslated has not delivered lyrics.
#
# The work goes in BATCHES, dispatched by a loop that re-reads the live worker
# count on every tick. That is what makes "edit threads in time" mean something:
# raising the cap starts more songs within a tick, lowering it stops starting
# new ones once the in-flight work drains (a fetch that already spent the API
# call is never thrown away).
#
# Only one bulk job runs at a time; progress is pushed as bulk_progress SSE.
import os
import threading
import time as time_module
import concurrent.futures

from .cache import (get_cached, set_cached, is_not_found_result,
                    _cache_filename, read_entry, is_parser_stale)
from .library import (
    scan_cache, list_unlyriced, remove_unlyriced, apply_saved_rename,
    _try_llm_retitle_fetch,
)
from .rerace import _tier, _rerace_video
from .parse_pool import normalize_many, cpu_count
from .translate import (translate_queue_enqueue, translate_queue_stats,
                        set_translate_queue_workers)

_TIER_ORDER = {'none': -1, 'plain': 0, 'line': 1, 'wbw': 2}
_TIER_NAME = {2: 'wbw', 1: 'line', 0: 'plain', -1: 'none'}
_RESULTS_CAP = 300

_JOB = {}
_JOB_LOCK = threading.Lock()
_CANCEL = threading.Event()
# A running job with no heartbeat for this long is presumed dead (crashed
# worker, killed thread): a new start takes over instead of 409ing forever.
# Short, because _heartbeat_loop beats on a timer now -- the old value only had
# to be long enough to cover a slow row, and a slow row no longer stops the
# heartbeat at all.
_STALE_AFTER = int(os.environ.get('YTMU_BULK_STALE_S', '180'))
# How often the heartbeat thread beats while a job runs.
_BEAT_EVERY_S = 10
# Hard ceilings. The live knobs move inside these; the pools are built once at
# the ceiling so raising a knob never has to build an executor mid-flight.
_MAX_WORKERS = 32
_MAX_TQ_WORKERS = 16
_MAX_BATCH = 500
_MIN_BATCH = 1
# How long the job stays in 'translating' waiting for the queue to drain before
# it gives up waiting and reports what is still pending. A bulk job that must
# translate 4000 songs cannot block forever on one stuck key.
_TQ_DRAIN_MAX_S = 1800


class BulkBusy(Exception):
    """A job is already running. Carries that job's state so the 409 can tell
    the operator WHAT is running instead of a bare refusal -- the dashboard used
    to show 'idle' next to a Start button that could only ever answer 409."""

    def __init__(self, message, running=None):
        super().__init__(message)
        self.running = running or {}


def _clamp(job, key, dflt, lo, hi):
    """Read a LIVE knob off the running job. Every consumer goes through here,
    so a dashboard change takes effect without restarting anything."""
    with _JOB_LOCK:
        try:
            raw = job.get(key, dflt)
        except Exception:
            raw = dflt
    try:
        v = int(raw)
    except Exception:
        v = dflt
    return max(lo, min(hi, v))


def _flag(job, key, dflt=True):
    with _JOB_LOCK:
        v = job.get(key, dflt)
    return bool(v)


def _beat(job):
    try:
        with _JOB_LOCK:
            job['beat'] = time_module.time()
    except Exception:
        pass


def _broadcast(job, payload):
    """Push a bulk_progress SSE event (start/row/stage/batch/tune/done).
    Never raises."""
    try:
        from .app import _sse_broadcast
        base = {'job_id': job.get('job_id'), 'done': job.get('done', 0),
                'total': job.get('total', 0)}
        base.update(payload or {})
        if base.get('type') in ('row', 'done', 'batch'):
            try:
                cur = translate_queue_stats()
                base['tq_queued'] = job.get('tq_queued', 0)
                base['tq_done'] = max(0, cur['done'] - job.get('tq_done_base', 0))
                # Pending is the number that says whether the job is actually
                # finished. Without it the panel reads "done" while a thousand
                # songs are still waiting on Cohere.
                base['tq_pending'] = cur.get('pending', 0)
                base['tq_workers'] = cur.get('workers', 0)
            except Exception:
                pass
        if base.get('type') == 'tune':
            # The knobs the dashboard just changed, echoed so every open tab
            # moves its sliders instead of only the one that sent the request.
            with _JOB_LOCK:
                base.update({'workers': job.get('workers'),
                             'cpu_workers': job.get('cpu_workers'),
                             'tq_workers': job.get('tq_workers'),
                             'batch': job.get('batch'),
                             'translate': job.get('translate')})
        _sse_broadcast('bulk_progress', base)
    except Exception:
        pass


def _norm_tier(result):
    lyrics = result.get('lyrics') or []
    if any(l.get('wordSynced') for l in lyrics):
        return 'wbw'
    if result.get('synced'):
        return 'line'
    if lyrics:
        return 'plain'
    return 'none'


def _tier_of(data):
    """Tier name of a payload, for a target's old_tier where the cached value
    is read outside _finish_video (the `stale` scope). Same shape as
    scan_cache's tier so the dashboard's from->to reads consistently."""
    if not data or is_not_found_result(data):
        return 'none'
    return _norm_tier(data)


def _push_result(job, row):
    job['results'].append(row)
    if len(job['results']) > _RESULTS_CAP:
        del job['results'][:-_RESULTS_CAP]


def _finish_video(job, vid, lang, old_tier, song, artist, result,
                  via, old_data=None):
    """Normalize on the process pool, tier-compare, cache, enqueue
    translation. Returns the result row dict.

    Every knob is read from `job` at the moment it is used, not from a snapshot
    taken at start: the pool size and the translate switch are editable while
    the job runs, and a worker that read them once would ignore every change
    made after it started."""
    key = f"{vid}:{lang}"
    if not result or is_not_found_result(result):
        row = {'video_id': vid, 'lang': lang, 'song': song, 'artist': artist,
               'from': old_tier, 'to': old_tier, 'status': 'failed',
               'source': (result or {}).get('source', '') if result else '',
               'message': f'{via}: no lyrics found'}
        with _JOB_LOCK:
            job['failed'] += 1
            job['done'] += 1
            _push_result(job, row)
        _beat(job)
        _broadcast(job, {'type': 'row', 'row': row})
        return row

    # CPU-bound normalize+score on worker processes (threads keep fetching).
    # cpu_workers is read per song, so the dashboard can resize it mid-run.
    try:
        norms = normalize_many([{'lyrics': result.get('lyrics') or [],
                                 'synced': bool(result.get('synced')),
                                 'source': result.get('source', '')}],
                               workers=_clamp(job, 'cpu_workers', 2, 1,
                                              max(1, cpu_count())))
        norm = norms[0] if norms else None
    except Exception:
        norm = None
    if norm and norm.get('ok'):
        result['lyrics'] = norm['lyrics']
        result['synced'] = norm['synced']
        result['wordSynced'] = norm['wordSynced']
        new_tier = norm['tier']
    else:
        new_tier = _norm_tier(result)

    if _TIER_ORDER.get(new_tier, -1) < _TIER_ORDER.get(old_tier, -1):
        # Never silently downgrade a cache entry.
        row = {'video_id': vid, 'lang': lang, 'song': song, 'artist': artist,
               'from': old_tier, 'to': new_tier, 'status': 'kept',
               'source': result.get('source', ''),
               'message': f'{via}: new {new_tier} worse than {old_tier}; kept old'}
        with _JOB_LOCK:
            job['kept'] += 1
            job['done'] += 1
            _push_result(job, row)
        _beat(job)
        _broadcast(job, {'type': 'row', 'row': row})
        return row

    result.setdefault('song', song)
    result.setdefault('artist', artist)
    try:
        set_cached(key, result)
        # Keep a stale :fast sibling from shadowing this upgrade in scans:
        # mirror the upgraded payload so both keys agree on tier.
        try:
            from .paths import LYRICS_DIR
            if os.path.exists(os.path.join(LYRICS_DIR, _cache_filename(key + ':fast') + '.json')):
                set_cached(key + ':fast', result)
        except Exception:
            pass
    except Exception as e:
        row = {'video_id': vid, 'lang': lang, 'song': song, 'artist': artist,
               'from': old_tier, 'to': new_tier, 'status': 'error',
               'source': result.get('source', ''), 'message': f'cache write: {e}'}
        with _JOB_LOCK:
            job['errors'] += 1
            job['done'] += 1
            _push_result(job, row)
        _beat(job)
        _broadcast(job, {'type': 'row', 'row': row})
        return row

    status = 'upgraded' if _TIER_ORDER.get(new_tier, -1) > _TIER_ORDER.get(old_tier, -1) else 'kept'
    if old_tier == 'none' and status == 'upgraded':
        try:
            remove_unlyriced(vid)
        except Exception:
            pass
    tq = False
    if _flag(job, 'translate', True):
        try:
            if translate_queue_enqueue(key, lang, result):
                tq = True
        except Exception:
            pass
    row = {'video_id': vid, 'lang': lang, 'song': result.get('song', song),
           'artist': result.get('artist', artist),
           'from': old_tier, 'to': new_tier, 'status': status,
           'source': result.get('source', ''),
           'message': f'{via}: {result.get("source", "")}'}
    with _JOB_LOCK:
        job['upgraded' if status == 'upgraded' else 'kept'] += 1
        if tq:
            job['tq_queued'] += 1
        job['done'] += 1
        _push_result(job, row)
    _beat(job)
    _broadcast(job, {'type': 'row', 'row': row,
                     'upgraded': job.get('upgraded', 0), 'kept': job.get('kept', 0),
                     'failed': job.get('failed', 0), 'errors': job.get('errors', 0)})
    return row


def _fresh_one(job, cancel, target):
    from .providers_yt import get_song_info
    from .pipeline import fetch_all_lyrics
    vid, lang, old_tier, song, artist = (target['video_id'], target['lang'],
                                         target['old_tier'], target['song'],
                                         target['artist'])
    with _JOB_LOCK:
        job['current'] = {'video_id': vid, 'song': song, 'artist': artist}
    _beat(job)
    _broadcast(job, {'type': 'start', 'video_id': vid, 'song': song, 'artist': artist})

    def _stage(name, status, detail=''):
        _broadcast(job, {'type': 'stage', 'video_id': vid, 'song': song,
                         'artist': artist, 'provider': name, 'status': status,
                         'detail': detail or ''})

    if cancel.is_set():
        _row = {'video_id': vid, 'lang': lang, 'song': song, 'artist': artist,
                'from': old_tier, 'to': old_tier, 'status': 'cancelled',
                'source': '', 'message': 'bulk stop requested'}
        with _JOB_LOCK:
            job['done'] += 1
            # counted as skipped, not just done: this song was never attempted,
            # and without it the panel's numbers did not add up to the total
            # (up=3 skipped=8 for a 12-song job).
            job['skipped'] = job.get('skipped', 0) + 1
            _push_result(job, _row)
        _beat(job)
        _broadcast(job, {'type': 'row', 'row': _row, 'skipped': job.get('skipped', 0)})
        return
    try:
        info = get_song_info(vid)
        if not info:
            raise ValueError('get_song_info returned None')
        info = apply_saved_rename(vid, info)
        # No inline translation -- the silent queue handles it.
        result = fetch_all_lyrics(vid, info, translate_to=None, on_stage=_stage)
        if result:
            result['song'] = info.get('title', song)
            result['artist'] = info.get('artist', artist)
    except Exception as e:
        row = {'video_id': vid, 'lang': lang, 'song': song, 'artist': artist,
               'from': old_tier, 'to': old_tier, 'status': 'error',
               'source': '', 'message': f'fresh fetch: {e}'}
        with _JOB_LOCK:
            job['errors'] += 1
            job['done'] += 1
            _push_result(job, row)
        _beat(job)
        _broadcast(job, {'type': 'row', 'row': row})
        return
    _finish_video(job, vid, lang, old_tier, song, artist, result, 'fresh')


def _rerace_one(job, cancel, target):
    vid, lang, old_tier, song, artist = (target['video_id'], target['lang'],
                                         target['old_tier'], target['song'],
                                         target['artist'])
    with _JOB_LOCK:
        job['current'] = {'video_id': vid, 'song': song, 'artist': artist}
    _beat(job)
    _broadcast(job, {'type': 'start', 'video_id': vid, 'song': song, 'artist': artist})
    if cancel.is_set():
        _row = {'video_id': vid, 'lang': lang, 'song': song, 'artist': artist,
                'from': old_tier, 'to': old_tier, 'status': 'cancelled',
                'source': '', 'message': 'bulk stop requested'}
        with _JOB_LOCK:
            job['done'] += 1
            job['skipped'] = job.get('skipped', 0) + 1  # see _fresh_one
            _push_result(job, _row)
        _beat(job)
        _broadcast(job, {'type': 'row', 'row': _row, 'skipped': job.get('skipped', 0)})
        return
    if old_tier == 'none':
        # Unlyriced entries have no cache to re-race -- fresh fetch instead.
        t2 = dict(target)
        _fresh_one(job, cancel, t2)
        return
    try:
        old_data = get_cached(f"{vid}:{lang}")
        if old_data is None:
            # A file that EXISTS but will not load is parser-stale: get_cached
            # refuses it on purpose because its text came from an older
            # parsers_*.py, so there is nothing to re-race against -- re-racing
            # needs the old payload to compare against, and withholding that is
            # the whole point of the gate. A fresh fetch is the only repair, and
            # it is the SAME situation as an unlyriced row, which the branch
            # above already sends to _fresh_one. Verified: before this, a job
            # run after a parser bump reported "old cache miss" on every row,
            # which reads as a broken tool rather than as "pick the stale
            # scope", and `all` + `rerace` was unusable for the same reason.
            if is_parser_stale(f"{vid}:{lang}"):
                t2 = dict(target)
                _fresh_one(job, cancel, t2)
                return
            raise ValueError('old cache miss')
        upgraded = _rerace_video(vid, lang, old_data)
        new_val = _tier(upgraded) if upgraded else -1
        old_val = _tier(old_data)
        if new_val < 2 and new_val <= old_val:
            llm_res = _try_llm_retitle_fetch(vid, lang, old_data)
            if llm_res is not None and _tier(llm_res) > old_val:
                upgraded = llm_res
        result = upgraded or old_data
    except Exception as e:
        row = {'video_id': vid, 'lang': lang, 'song': song, 'artist': artist,
               'from': old_tier, 'to': old_tier, 'status': 'error',
               'source': '', 'message': f'rerace: {e}'}
        with _JOB_LOCK:
            job['errors'] += 1
            job['done'] += 1
            _push_result(job, row)
        _beat(job)
        _broadcast(job, {'type': 'row', 'row': row})
        return
    _finish_video(job, vid, lang, old_tier, song, artist, result, 'rerace')


def _heartbeat_loop(job, cancel):
    """Beat on a TIMER for as long as the job runs.

    This exists because _beat only fired when a row finished: a job whose
    workers were all stuck (a provider socket with no read timeout, the wbw
    second Cubey pass sleeping, a wedged process pool) produced no heartbeat at
    all, so after _STALE_AFTER it looked dead while it was very much alive --
    and every new Start answered 409 for ten minutes with nothing on screen.
    Now a job proves it is alive whether or not it is making progress, and
    status() can show the age instead of guessing."""
    while not cancel.wait(_BEAT_EVERY_S):
        with _JOB_LOCK:
            if _JOB.get('job_id') != job.get('job_id'):
                return
            if job.get('state') != 'running':
                return
        _beat(job)


def _run_batch(pool, job, one, cancel, batch):
    """Run one batch against a LIVE worker count.

    The cap is re-read on every tick, so raising it on the dashboard starts more
    songs within a tick and lowering it stops starting new ones once the
    in-flight work drains -- it never kills a fetch that already spent the API
    call, because throwing that away buys nothing and costs the quota."""
    queue = list(batch)
    qidx = 0
    inflight = {}
    last_beat = 0.0
    while queue or inflight:
        want = _clamp(job, 'workers', 8, 1, _MAX_WORKERS)
        while qidx < len(queue) and len(inflight) < want:
            t = queue[qidx]
            qidx += 1
            inflight[pool.submit(one, job, cancel, t)] = t
        with _JOB_LOCK:
            job['in_flight'] = len(inflight)
            job['queued_in_batch'] = len(queue) - qidx
        if not inflight:
            # cancel arrived with an empty batch: nothing to wait for.
            break
        finished, _pending = concurrent.futures.wait(
            list(inflight), timeout=0.25,
            return_when=concurrent.futures.FIRST_COMPLETED)
        for f in finished:
            inflight.pop(f, None)
            try:
                f.result()
            except Exception as e:
                print(f"[BULK] [FAIL] worker: {e}")
        now = time_module.time()
        if now - last_beat > _BEAT_EVERY_S / 2:
            last_beat = now
            _beat(job)
    with _JOB_LOCK:
        job['in_flight'] = 0


def _drain_translations(job, cancel):
    """Keep the job alive until the translate queue has drained.

    A bulk run is judged by the lyrics it leaves behind, and lyrics with no
    translation are not the deliverable the operator asked for -- so the job
    sits in 'translating' while the queue works instead of announcing 'done'
    with a thousand songs still waiting. Bounded by _TQ_DRAIN_MAX_S: one stuck
    key must not hold a finished job open forever, and whatever is still
    pending at the cut is reported, not hidden."""
    if not _flag(job, 'translate', True):
        return
    t0 = time_module.time()
    while not cancel.is_set() and (time_module.time() - t0) < _TQ_DRAIN_MAX_S:
        cur = translate_queue_stats()
        pending = max(0, int(cur.get('pending', 0)))
        with _JOB_LOCK:
            job['tq_pending'] = pending
            if pending <= 0:
                job['state'] = 'stopped' if cancel.is_set() else 'done'
                return
            job['state'] = 'translating'
        _broadcast(job, {'type': 'drain', 'tq_pending': pending,
                         'waited_s': round(time_module.time() - t0, 1)})
        if cancel.wait(2.0):
            break
    cur = translate_queue_stats()
    with _JOB_LOCK:
        job['tq_pending'] = max(0, int(cur.get('pending', 0)))
        job['state'] = 'stopped' if cancel.is_set() else 'done'


def _run(job, cancel):
    one = _fresh_one if job.get('mode') == 'fresh' else _rerace_one
    targets = job.get('targets') or []
    total = len(targets)
    # One executor at the CEILING, not at the starting worker count: a knob
    # raised mid-run has to be able to add threads without building a pool
    # inside the dispatcher.
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=_MAX_WORKERS,
                                                thread_name_prefix='bulkfetch')
    threading.Thread(target=_heartbeat_loop, args=(job, cancel), daemon=True,
                     name='bulk-beat').start()
    try:
        set_translate_queue_workers(_clamp(job, 'tq_workers', 2, 1, _MAX_TQ_WORKERS))
    except Exception:
        pass
    idx = 0
    batch_no = 0
    _beat(job)
    try:
        while idx < total:
            if cancel.is_set():
                break
            batch_size = _clamp(job, 'batch', 25, _MIN_BATCH, _MAX_BATCH)
            batch = targets[idx:idx + batch_size]
            idx += len(batch)
            batch_no += 1
            batches_total = max(1, (total + batch_size - 1) // batch_size)
            with _JOB_LOCK:
                job['batch_index'] = batch_no
                job['batch_total'] = batches_total
                job['batch_size'] = len(batch)
            _broadcast(job, {'type': 'batch', 'batch': batch_no,
                             'batches': batches_total, 'size': len(batch),
                             'queued': max(0, total - idx)})
            _run_batch(pool, job, one, cancel, batch)
            _broadcast(job, {'type': 'batch_done', 'batch': batch_no,
                             'batches': batches_total,
                             'upgraded': job.get('upgraded', 0),
                             'kept': job.get('kept', 0),
                             'failed': job.get('failed', 0),
                             'errors': job.get('errors', 0)})
        # Stop pressed (or the target list ran out): close the books on what was
        # never attempted as ONE row, so done reaches total and the progress bar
        # finishes instead of sitting at 92% forever.
        left = total - idx
        if left > 0:
            with _JOB_LOCK:
                job['skipped'] = job.get('skipped', 0) + left
                job['done'] = job.get('done', 0) + left
                _push_result(job, {'video_id': '', 'lang': job.get('lang', ''),
                                   'song': f'{left} song(s)', 'artist': '',
                                   'from': '-', 'to': '-', 'status': 'cancelled',
                                   'source': '',
                                   'message': 'not attempted (stop requested)'})
            _broadcast(job, {'type': 'row', 'row': {
                'video_id': '', 'lang': job.get('lang', ''), 'song': f'{left} song(s)',
                'artist': '', 'from': '-', 'to': '-', 'status': 'cancelled',
                'source': '', 'message': 'not attempted (stop requested)'},
                'skipped': job.get('skipped', 0)})
        _drain_translations(job, cancel)
    finally:
        pool.shutdown(wait=False)
        with _JOB_LOCK:
            if job.get('state') != 'translating':
                job['state'] = 'stopped' if cancel.is_set() else 'done'
            job['current'] = None
            job['in_flight'] = 0
        cur = translate_queue_stats()
        print(f"[BULK] [{job['state'].upper()}] done={job['done']}/{job['total']} "
              f"upgraded={job['upgraded']} kept={job['kept']} "
              f"failed={job['failed']} errors={job['errors']} "
              f"skipped={job.get('skipped', 0)} "
              f"tq_queued={job['tq_queued']} tq_pending={cur.get('pending', 0)} "
              f"tq_done={cur['done'] - job.get('tq_done_base', 0)} "
              f"tq_errors={cur['errors'] - job.get('tq_err_base', 0)}")
        _broadcast(job, {'type': 'done', 'state': job.get('state'),
                         'upgraded': job.get('upgraded', 0), 'kept': job.get('kept', 0),
                         'failed': job.get('failed', 0), 'errors': job.get('errors', 0),
                         'skipped': job.get('skipped', 0),
                         'tq_pending': job.get('tq_pending', 0)})


def _running_brief(job):
    """The state a 409 has to carry. A bare 'already running' tells the operator
    nothing they can act on -- this is what the dashboard renders next to a
    disabled Start button and what 'Take over' confirms against."""
    if not isinstance(job, dict) or not job.get('job_id'):
        return {}
    now = time_module.time()
    try:
        beat = float(job.get('beat') or 0)
        started = float(job.get('started_ts') or 0)
    except Exception:
        beat = started = 0.0
    return {
        'job_id': job.get('job_id'), 'state': job.get('state'),
        'scope': job.get('scope'), 'mode': job.get('mode'),
        'lang': job.get('lang'),
        'done': job.get('done', 0), 'total': job.get('total', 0),
        'upgraded': job.get('upgraded', 0), 'kept': job.get('kept', 0),
        'failed': job.get('failed', 0), 'errors': job.get('errors', 0),
        'workers': job.get('workers'), 'cpu_workers': job.get('cpu_workers'),
        'tq_workers': job.get('tq_workers'), 'batch': job.get('batch'),
        'translate': job.get('translate'),
        'batch_index': job.get('batch_index', 0), 'batch_total': job.get('batch_total', 0),
        'in_flight': job.get('in_flight', 0),
        'tq_pending': job.get('tq_pending', 0),
        'elapsed_s': round(now - started, 1) if started else None,
        'beat_age_s': round(now - beat, 1) if beat else None,
        'stale': bool(beat and (now - beat) >= _STALE_AFTER),
        'current': job.get('current'),
    }


def start(opts):
    """Start a bulk refetch job. opts: {scope, mode, lang, workers,
    cpu_workers, tq_workers, batch, translate, force}.

    Raises BulkBusy when a job is already running, unless force is set -- then
    the running one is cancelled and its slot taken, which is the escape hatch
    for the operator staring at "already running" at a job they cannot see.
    Every knob stays editable after the start; see tune()."""
    global _JOB, _CANCEL
    scope = (opts.get('scope') or 'non-wbw').strip()
    mode = (opts.get('mode') or 'fresh').strip()
    if scope == 'stale' and mode != 'fresh':
        # Forcing it here rather than trusting the caller: rerace reads the
        # old payload through get_cached, which returns None for exactly the
        # entries this scope selects, so every row would fail with
        # "old cache miss" and the job would report errors instead of work.
        mode = 'fresh'
    lang = (opts.get('lang') or 'zh-TW').strip()
    workers = max(1, min(int(opts.get('workers') or 8), _MAX_WORKERS))
    cpu_workers = max(1, min(int(opts.get('cpu_workers') or 2), max(1, cpu_count())))
    tq_workers = max(1, min(int(opts.get('tq_workers') or 2), _MAX_TQ_WORKERS))
    batch = max(_MIN_BATCH, min(int(opts.get('batch') or 25), _MAX_BATCH))
    translate = bool(opts.get('translate', True))
    force = bool(opts.get('force', False))
    if scope not in ('all', 'non-wbw', 'unlyriced', 'plain', 'stale'):
        raise ValueError('scope must be all|non-wbw|unlyriced|plain|stale')
    if mode not in ('fresh', 'rerace'):
        raise ValueError('mode must be fresh|rerace')

    with _JOB_LOCK:
        if _JOB.get('state') in ('running', 'translating'):
            idle = time_module.time() - _JOB.get('beat', 0)
            if idle < _STALE_AFTER and not force:
                raise BulkBusy(
                    f'a bulk refetch is already running (job {_JOB.get("job_id")}, '
                    f'{_JOB.get("done", 0)}/{_JOB.get("total", 0)}, '
                    f'last beat {idle:.0f}s ago)',
                    running=_running_brief(_JOB))
            # Either the heartbeat went stale or the operator forced it. Stop it
            # via the old cancel event, then rebind BOTH globals so the orphan
            # thread's writes land on the abandoned dict (status() keys the new
            # job by job_id) and stop() targets the new run.
            why = 'forced' if force and idle < _STALE_AFTER else f'no beat for {idle:.0f}s'
            print(f"[BULK] taking over job {_JOB.get('job_id')} ({why})")
            _CANCEL.set()
            _CANCEL = threading.Event()
            _JOB = {}
        else:
            _CANCEL.clear()
        targets = []
        if scope == 'unlyriced':
            for it in list_unlyriced():
                targets.append({'video_id': it['video_id'],
                                'lang': it.get('lang') or lang,
                                'old_tier': 'none',
                                'song': it.get('song', ''),
                                'artist': it.get('artist', '')})
        elif scope == 'stale':
            # Exactly the songs the offline sweep could not fix: their text
            # was parsed by an older parsers_*.py, so only a refetch can
            # re-derive it. The list comes from db_migrate rather than a
            # second copy of the epoch rule here, so the two halves of the
            # version-bump feature cannot disagree about what "stale" means.
            from .db_migrate import needs_refetch_keys
            seen = set()
            for it in needs_refetch_keys():
                # needs_refetch_keys walks FILES, so a video with both a full
                # key and a :fast sibling appears twice. One refetch fixes
                # both (_finish_video mirrors onto the sibling), so fetching
                # it twice is pure duplicate API spend.
                sig = (it['video_id'], it['key'].rsplit(':', 1)[-1])
                if sig in seen or sig[1] == 'fast':
                    continue
                seen.add(sig)
                targets.append({'video_id': it['video_id'],
                                'lang': it['key'].rsplit(':', 1)[-1] or lang,
                                # read_entry, NOT get_cached: a stale entry is
                                # exactly the case where get_cached returns
                                # None, and reporting its tier as 'none' would
                                # disable the never-downgrade guard on the one
                                # scope that is replacing wbw entries.
                                'old_tier': _tier_of(
                                    (read_entry(it['key']) or {}).get('data')),
                                'song': it.get('song', ''),
                                'artist': it.get('artist', '')})
        else:
            songs = scan_cache().get('songs', [])
            for s in songs:
                tier = s.get('tier', 'plain')
                if scope == 'non-wbw' and tier == 'wbw':
                    continue
                if scope == 'plain' and tier != 'plain':
                    continue
                targets.append({'video_id': s['video_id'],
                                'lang': s.get('lang') or lang,
                                'old_tier': tier,
                                'song': s.get('song', ''),
                                'artist': s.get('artist', '')})
        base = translate_queue_stats()
        now = time_module.time()
        _JOB.update({
            'job_id': str(int(now * 1000)),
            'state': 'running',
            'scope': scope, 'mode': mode, 'lang': lang,
            'workers': workers, 'cpu_workers': cpu_workers,
            'tq_workers': tq_workers, 'batch': batch,
            'translate': translate,
            'total': len(targets), 'done': 0,
            'upgraded': 0, 'kept': 0, 'failed': 0, 'errors': 0, 'skipped': 0,
            'current': None, 'targets': targets,
            'batch_index': 0, 'batch_total': 0, 'batch_size': 0,
            'in_flight': 0, 'queued_in_batch': 0, 'tq_pending': 0,
            'tq_queued': 0, 'tq_done_base': base['done'], 'tq_err_base': base['errors'],
            'results': [], 'beat': now, 'started_ts': now,
        })
        job_id = _JOB['job_id']

    # The translate pool is resized BEFORE the worker thread starts, so the first
    # song does not race the knob the operator just set. _run repeats this
    # harmlessly (a grow is idempotent).
    try:
        set_translate_queue_workers(tq_workers)
    except Exception:
        pass
    threading.Thread(target=_run, args=(_JOB, _CANCEL),
                     daemon=True, name='bulk-refetch').start()
    return {'job_id': job_id, 'total': len(targets),
            'workers': workers, 'cpu_workers': cpu_workers,
            'tq_workers': tq_workers, 'batch': batch,
            'batches': max(1, (len(targets) + batch - 1) // batch)}


def tune(**knobs):
    """Change the live knobs of the running job. Every key is optional;
    unknown keys are ignored. Raises BulkBusy when no job is running.

    This is the "edit threads in time" path: the dispatcher re-reads `workers`
    on every tick and the per-song path re-reads cpu_workers/translate, so a
    change lands without restarting the job or losing in-flight work."""
    limits = {
        'workers': (1, _MAX_WORKERS),
        'cpu_workers': (1, max(1, cpu_count())),
        'tq_workers': (1, _MAX_TQ_WORKERS),
        'batch': (_MIN_BATCH, _MAX_BATCH),
    }
    changed = {}
    with _JOB_LOCK:
        if _JOB.get('state') not in ('running', 'translating') or not _JOB.get('job_id'):
            raise BulkBusy('no bulk refetch is running', running={})
        job = _JOB
        for key, (lo, hi) in limits.items():
            if knobs.get(key) is None:
                continue
            try:
                v = int(knobs[key])
            except Exception:
                continue
            v = max(lo, min(hi, v))
            if job.get(key) != v:
                job[key] = v
                changed[key] = v
        if knobs.get('translate') is not None:
            v = bool(knobs['translate'])
            if bool(job.get('translate')) != v:
                job['translate'] = v
                changed['translate'] = v
    if not changed:
        # Not an error: the dashboard fires this on every keystroke of a number
        # field, and re-sending the same value must be silent, not a 400.
        return {'changed': {}, **_running_brief(job)}
    print(f"[BULK] tune {job_id_of(job)}: {changed}")
    if 'tq_workers' in changed:
        try:
            set_translate_queue_workers(changed['tq_workers'])
        except Exception as e:
            print(f"[BULK] [WARN] translate worker tune failed: {e}")
    _beat(job)
    _broadcast(job, {'type': 'tune', 'changed': changed})
    return {'changed': changed, **_running_brief(job)}


def job_id_of(job):
    try:
        return job.get('job_id', '?')
    except Exception:
        return '?'


def stop():
    with _JOB_LOCK:
        running = _JOB.get('state') in ('running', 'translating')
    if running:
        _CANCEL.set()
    return running


def status(job_id=None):
    """The current job (or the one named), with the live knobs, batch counters,
    heartbeat age and translate queue state folded in. job_id=None means
    "whatever is running" -- that is what makes the dashboard able to ADOPT a
    job it did not start, instead of showing 'idle' above a Start button that
    can only answer 409. Never raises."""
    with _JOB_LOCK:
        if not _JOB or (job_id and _JOB.get('job_id') != job_id):
            return None
        snap = {k: v for k, v in _JOB.items() if k != 'targets'}
        snap['results'] = list(snap.get('results', []))
        snap.pop('tq_done_base', None)
        tq_done_base = _JOB.get('tq_done_base', 0)
        tq_err_base = _JOB.get('tq_err_base', 0)
    cur = translate_queue_stats()
    snap['tq_done'] = max(0, cur['done'] - tq_done_base)
    snap['tq_errors'] = max(0, cur['errors'] - tq_err_base)
    snap['tq_pending'] = max(0, int(cur.get('pending', 0)))
    snap['tq_live_workers'] = cur.get('workers', 0)
    snap['tq_target_workers'] = cur.get('target', 0)
    now = time_module.time()
    try:
        beat = float(snap.get('beat') or 0)
        started = float(snap.get('started_ts') or 0)
    except Exception:
        beat = started = 0.0
    snap['beat_age_s'] = round(now - beat, 1) if beat else None
    snap['elapsed_s'] = round(now - started, 1) if started else None
    snap['stale'] = bool(beat and (now - beat) >= _STALE_AFTER)
    # Rough ETA from the songs that have actually finished, and only once
    # there is enough signal to mean anything (two songs is not a rate).
    done = int(snap.get('done') or 0)
    total = int(snap.get('total') or 0)
    elapsed = (now - started) if started else 0.0
    snap['eta_s'] = round(elapsed / done * (total - done), 1) if done >= 2 and elapsed > 1 else None
    return snap
