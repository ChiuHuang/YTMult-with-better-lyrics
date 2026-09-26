# Bulk refetch-all job: the admin picks scope/mode/lang/workers up front.
#
# Threads do network fetch (ThreadPoolExecutor), worker processes do the
# CPU-bound normalize+score (parse_pool), and translations go to the silent
# background queue (translate_queue) so fetching never blocks on Cohere.
# Only one bulk job runs at a time; progress is polled via status().
import os
import threading
import time as time_module
import concurrent.futures

from .cache import get_cached, set_cached, is_not_found_result
from .library import (
    scan_cache, list_unlyriced, remove_unlyriced, apply_saved_rename,
    _try_llm_retitle_fetch,
)
from .rerace import _tier, _rerace_video
from .parse_pool import normalize_many, cpu_count
from .translate import translate_queue_enqueue, translate_queue_stats

_TIER_ORDER = {'none': -1, 'plain': 0, 'line': 1, 'wbw': 2}
_TIER_NAME = {2: 'wbw', 1: 'line', 0: 'plain', -1: 'none'}
_RESULTS_CAP = 300

_JOB = {}
_JOB_LOCK = threading.Lock()
_CANCEL = threading.Event()
# A running job with no heartbeat for this long is presumed dead (crashed
# worker, killed thread): a new start takes over instead of 409ing forever.
_STALE_AFTER = int(os.environ.get('YTMU_BULK_STALE_S', '600'))


class BulkBusy(Exception):
    pass


def _beat(job):
    try:
        with _JOB_LOCK:
            job['beat'] = time_module.time()
    except Exception:
        pass


def _broadcast(job, payload):
    """Push a bulk_progress SSE event (start/row/stage/done). Never raises."""
    try:
        from .app import _sse_broadcast
        base = {'job_id': job.get('job_id'), 'done': job.get('done', 0),
                'total': job.get('total', 0)}
        base.update(payload or {})
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


def _push_result(job, row):
    job['results'].append(row)
    if len(job['results']) > _RESULTS_CAP:
        del job['results'][:-_RESULTS_CAP]


def _finish_video(job, opts, vid, lang, old_tier, song, artist, result,
                  via, old_data=None):
    """Normalize on the process pool, tier-compare, cache, enqueue
    translation. Returns the result row dict."""
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
    try:
        norms = normalize_many([{'lyrics': result.get('lyrics') or [],
                                 'synced': bool(result.get('synced')),
                                 'source': result.get('source', '')}],
                               workers=opts['cpu_workers'])
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
    if opts['translate']:
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


def _fresh_one(job, opts, cancel, target):
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
        with _JOB_LOCK:
            job['done'] += 1
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
    _finish_video(job, opts, vid, lang, old_tier, song, artist, result, 'fresh')


def _rerace_one(job, opts, cancel, target):
    vid, lang, old_tier, song, artist = (target['video_id'], target['lang'],
                                         target['old_tier'], target['song'],
                                         target['artist'])
    with _JOB_LOCK:
        job['current'] = {'video_id': vid, 'song': song, 'artist': artist}
    _beat(job)
    _broadcast(job, {'type': 'start', 'video_id': vid, 'song': song, 'artist': artist})
    if cancel.is_set():
        with _JOB_LOCK:
            job['done'] += 1
        return
    if old_tier == 'none':
        # Unlyriced entries have no cache to re-race -- fresh fetch instead.
        t2 = dict(target)
        _fresh_one(job, opts, cancel, t2)
        return
    try:
        old_data = get_cached(f"{vid}:{lang}")
        if old_data is None:
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
    _finish_video(job, opts, vid, lang, old_tier, song, artist, result, 'rerace')


def _run(job, opts, cancel):
    one = _fresh_one if opts['mode'] == 'fresh' else _rerace_one
    workers = max(1, min(int(opts['workers']), 32))
    _beat(job)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers,
                                                   thread_name_prefix='bulkfetch') as pool:
            futs = [pool.submit(one, job, opts, cancel, t) for t in job['targets']]
            for f in concurrent.futures.as_completed(futs):
                try:
                    f.result()
                except Exception as e:
                    print(f"[BULK] [FAIL] worker: {e}")
                _beat(job)
    finally:
        with _JOB_LOCK:
            job['state'] = 'stopped' if cancel.is_set() else 'done'
            job['current'] = None
        print(f"[BULK] [{job['state'].upper()}] done={job['done']}/{job['total']} "
              f"upgraded={job['upgraded']} kept={job['kept']} "
              f"failed={job['failed']} errors={job['errors']} "
              f"tq_queued={job['tq_queued']}")
        _broadcast(job, {'type': 'done', 'state': job.get('state'),
                         'upgraded': job.get('upgraded', 0), 'kept': job.get('kept', 0),
                         'failed': job.get('failed', 0), 'errors': job.get('errors', 0)})


def start(opts):
    """Start a bulk refetch job. opts: {scope, mode, lang, workers,
    cpu_workers, translate}. Raises BulkBusy when one is already running."""
    global _JOB, _CANCEL
    scope = (opts.get('scope') or 'non-wbw').strip()
    mode = (opts.get('mode') or 'fresh').strip()
    lang = (opts.get('lang') or 'zh-TW').strip()
    workers = max(1, min(int(opts.get('workers') or 8), 32))
    cpu_workers = max(1, min(int(opts.get('cpu_workers') or 2), cpu_count()))
    translate = bool(opts.get('translate', True))
    if scope not in ('all', 'non-wbw', 'unlyriced'):
        raise ValueError('scope must be all|non-wbw|unlyriced')
    if mode not in ('fresh', 'rerace'):
        raise ValueError('mode must be fresh|rerace')

    with _JOB_LOCK:
        if _JOB.get('state') == 'running':
            idle = time_module.time() - _JOB.get('beat', 0)
            if idle < _STALE_AFTER:
                raise BulkBusy('a bulk refetch is already running')
            # Stale heartbeat: the old thread is presumed dead. Stop it via
            # the old cancel event, then rebind BOTH globals so the orphan
            # thread's writes land on the abandoned dict (status() keys the
            # new job by job_id) and stop() targets the new run.
            print(f"[BULK] taking over stale job {_JOB.get('job_id')} (no beat for {idle:.0f}s)")
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
        else:
            songs = scan_cache().get('songs', [])
            for s in songs:
                tier = s.get('tier', 'plain')
                if scope == 'non-wbw' and tier == 'wbw':
                    continue
                targets.append({'video_id': s['video_id'],
                                'lang': s.get('lang') or lang,
                                'old_tier': tier,
                                'song': s.get('song', ''),
                                'artist': s.get('artist', '')})
        base = translate_queue_stats()
        _JOB.update({
            'job_id': str(int(time_module.time() * 1000)),
            'state': 'running',
            'scope': scope, 'mode': mode, 'lang': lang,
            'workers': workers, 'cpu_workers': cpu_workers,
            'translate': translate,
            'total': len(targets), 'done': 0,
            'upgraded': 0, 'kept': 0, 'failed': 0, 'errors': 0,
            'current': None, 'targets': targets,
            'tq_queued': 0, 'tq_done_base': base['done'], 'tq_err_base': base['errors'],
            'results': [], 'beat': time_module.time(),
        })
        job_id = _JOB['job_id']
        job_opts = {'mode': mode, 'workers': workers,
                    'cpu_workers': cpu_workers, 'translate': translate}

    threading.Thread(target=_run, args=(_JOB, job_opts, _CANCEL),
                     daemon=True, name='bulk-refetch').start()
    return {'job_id': job_id, 'total': len(targets)}


def status(job_id=None):
    with _JOB_LOCK:
        if not _JOB or (job_id and _JOB.get('job_id') != job_id):
            return None
        snap = {k: v for k, v in _JOB.items() if k != 'targets'}
        snap['results'] = list(snap.get('results', []))
    cur = translate_queue_stats()
    snap['tq_done'] = max(0, cur['done'] - snap.pop('tq_done_base', 0))
    snap['tq_errors'] = max(0, cur['errors'] - snap.pop('tq_err_base', 0))
    return snap


def stop():
    with _JOB_LOCK:
        running = _JOB.get('state') == 'running'
    if running:
        _CANCEL.set()
    return running
