# Retranslate the BROKEN translations, not the whole library.
#
# `translate/retry` (routes_library.py) covers rows with NO translation at
# all. This covers rows that HAVE one and are wrong: the model echoed the
# original back, glued the original and the translation into one string
# ("Every single morning ((Huh) （哈）每一個清晨"), or returned a slice of the
# original with nothing added. Those are the rows a user sees as a duplicated
# or half-English line and no amount of re-fetching the lyrics will change,
# because the lyrics are fine -- the cached TRANSLATION is not.
#
# Two things make this job different from a plain re-translate, and both are
# load-bearing:
#
#   1. The translate cache must be busted per song. Its key is
#      `cohere:<lang>:md5(joined source texts)` (translate.py), so the same
#      song with unchanged lyrics hashes to the SAME key and the bad row comes
#      straight back. Worse, the read-side echo sanitiser rewrites a cached
#      echo into the ORIGINAL text, so what is on disk may no longer even look
#      like an echo -- it is a duplicate of the lyric, which the display pass
#      then drops and the user sees as an untranslated row forever. Deleting
#      the entry (delete_translate_cached) is the only thing that forces a real
#      API call.
#
#   2. A broken row is only re-fetched when it is provably broken. The
#      detector deliberately does not guess: it reuses the same
#      `_echoes_original` the serving path uses, plus the two mechanical
#      defects (empty, identical). Anything it cannot prove is left alone, so
#      a run of this can never damage a good translation. The trade is that it
#      misses subtle quality problems -- those are not detectable without a
#      second opinion, and a second opinion that can overwrite a good row is
#      worse than a missed row.
import copy
import os
import threading
import time as time_module
import concurrent.futures

from .paths import LYRICS_DIR
from .cache import read_entry, set_cached, _cache_key_from_filename
from .translate import (
    _echoes_original, _is_chinese_target, _line_is_already_chinese,
    translate_result_in_place, translate_last_error,
    delete_translate_cached, translate_cache_key,
)

_WORKERS = 3
_RESULTS_CAP = 300
_RATE_LIMIT_BACKOFF_S = 20

_JOB = {}
_JOB_LOCK = threading.Lock()
_CANCEL = threading.Event()


def _log(msg):
    print(f"[RETRANS] {msg}")


def _norm(s):
    """Case- and space-insensitive form, for identity comparisons."""
    return ''.join(ch for ch in (s or '') if not ch.isspace()).lower()


def translation_defect(text, translated):
    """Why this translated row is broken, or '' when it is fine.

    Returns one of: 'empty', 'identical', 'echo', 'substring'.
    """
    if not isinstance(translated, str):
        return 'empty'
    t = translated.strip()
    if not t:
        return 'empty'
    o = (text or '').strip()
    if not o:
        return ''
    no, nt = _norm(o), _norm(t)
    if not nt:
        return 'empty'
    if no == nt:
        return 'identical'
    if _echoes_original(o, t):
        return 'echo'
    # A translation that is a proper slice of the original and adds nothing:
    # a real translation can quote the original, but only if it also carries
    # text that is NOT in the original. This catches the half-returned line
    # that _echoes_original's prefix test cannot see.
    if len(nt) >= 4 and nt in no and len(nt) < len(no):
        return 'substring'
    return ''


def _row_broken(row):
    if not isinstance(row, dict):
        return ''
    tr = row.get('translated')
    if tr is None:
        return ''
    return translation_defect(row.get('text') or '', tr)


def broken_rows(data):
    """[(index, defect, text, translated)] for every provably broken row."""
    out = []
    for i, l in enumerate(data.get('lyrics') or []):
        d = _row_broken(l)
        if d:
            out.append((i, d, (l.get('text') or '')[:60], (l.get('translated') or '')[:60]))
    return out


def _should_check(row, lang):
    """Rows that are ALREADY in the target language by design never went
    through the API (translate.py's already-Chinese skip), so their
    `translated` is a script conversion, not a model output. Re-sending them
    is pure cost."""
    if _is_chinese_target(lang or '') and _line_is_already_chinese(row.get('text') or ''):
        return False
    return True


def _one(key, lang, dry_run=False):
    """Retranslate one cache key if it has a broken row. Returns a result row."""
    entry = read_entry(key)
    if not entry:
        return None
    data = entry.get('data')
    if not isinstance(data, dict) or not data.get('lyrics'):
        return None
    defects = [(i, d) for i, d, _t, _tr in broken_rows(data)
               if _should_check(data['lyrics'][i], lang)]
    row = {'key': key, 'lang': lang, 'song': data.get('song', ''),
           'artist': data.get('artist', ''), 'source': data.get('source', ''),
           'status': 'ok', 'defects': len(defects),
           'detail': ', '.join(sorted({d for _i, d in defects}))}
    if not defects:
        row['status'] = 'clean'
        return row
    if dry_run:
        row['status'] = 'would_fix'
        return row

    # Work on a copy: a mid-flight failure must not leave the entry with its
    # broken rows deleted and nothing to show for it.
    work = copy.deepcopy(data)
    for i, _d in defects:
        work['lyrics'][i].pop('translated', None)

    # Bust the cache for THIS song only (see module docstring). The key is
    # built by the same helper cohere_translate uses, over the same
    # text-bearing lines -- dropping the broken rows first does not change
    # that list, since a broken row still has its `text`.
    bust = delete_translate_cached(translate_cache_key(
        [l['text'] for l in work['lyrics'] if l.get('text')], lang))

    try:
        translate_result_in_place(work, lang)
    except Exception as e:
        row['status'] = 'error'
        row['detail'] = f'translate failed: {e}'
        return row
    err = translate_last_error()
    if err == 'rate_limited':
        row['status'] = 'rate_limited'
        row['detail'] = 'Cohere 429; cache entry already dropped, retry later'
        return row
    if err:
        row['status'] = 'error'
        row['detail'] = f'translate error: {err}'
        return row

    still = [i for i, _t, _d, _tr in broken_rows(work)
             if _should_check(work['lyrics'][i], lang)]
    row['fixed'] = len(defects) - len(still)
    row['remaining'] = len(still)
    if still:
        row['status'] = 'partial'
    if not set_cached(key, work):
        row['status'] = 'error'
        row['detail'] = 'cache write failed'
    if bust:
        row['detail'] = (row['detail'] + '; ' if row['detail'] else '') + 'cache busted'
    return row


def _iter_keys(lang=''):
    try:
        names = os.listdir(LYRICS_DIR)
    except Exception:
        return
    for fname in names:
        if not fname.endswith('.json') or fname.endswith('.tmp'):
            continue
        key = _cache_key_from_filename(fname)
        if not key or key.endswith(':fast'):
            # :fast siblings are shadows of a full key; retranslate both is
            # wasted API spend and the full write mirrors over (bulk_refetch
            # does the same mirroring).
            continue
        parts = key.split(':')
        klang = parts[-1]
        if lang and klang != lang:
            continue
        yield key, klang


def start(lang='', dry_run=False, limit=0, workers=_WORKERS):
    """Scan for broken translations and (unless dry_run) fix them.

    lang   limit to one target lang ('' = every lang on disk).
    limit  stop after N songs (0 = no limit).
    Raises RuntimeError when a run is already in flight."""
    global _JOB
    lang = (lang or '').strip()
    with _JOB_LOCK:
        if _JOB.get('state') == 'running':
            raise RuntimeError('a retranslate is already running')
        _CANCEL.clear()
        _JOB = {}
        _JOB.update({
            'job_id': str(int(time_module.time() * 1000)),
            'state': 'running', 'lang': lang, 'dry_run': bool(dry_run),
            'started': time_module.time(),
            'total': 0, 'done': 0, 'clean': 0, 'fixed': 0, 'partial': 0,
            'errors': 0, 'rate_limited': 0, 'rows_fixed': 0, 'rows_remaining': 0,
            'defects': 0, 'current': None, 'results': [],
        })
        job = _JOB
    threading.Thread(target=_run, args=(job, lang, dry_run, limit,
                                        max(1, min(int(workers or _WORKERS), 8))),
                     daemon=True, name='retranslate').start()
    return {'job_id': job['job_id']}


def _push(job, row):
    with _JOB_LOCK:
        job['results'].append(row)
        if len(job['results']) > _RESULTS_CAP:
            del job['results'][:-_RESULTS_CAP]
        job['done'] += 1
        if row['status'] == 'clean':
            job['clean'] += 1
        elif row['status'] in ('ok', 'partial'):
            job['fixed'] += 1
            job['rows_fixed'] += row.get('fixed', 0)
            job['rows_remaining'] += row.get('remaining', 0)
        elif row['status'] == 'rate_limited':
            job['rate_limited'] += 1
            job['errors'] += 1
        elif row['status'] == 'error':
            job['errors'] += 1
        if row['status'] == 'partial':
            job['partial'] += 1
        job['defects'] += row.get('defects', 0)
        job['current'] = None
        snap = dict(job)


def _run(job, lang, dry_run, limit, workers):
    keys = list(_iter_keys(lang))
    if limit:
        keys = keys[:limit]
    job['total'] = len(keys)
    try:
        with concurrent.futures.ThreadPoolExecutor(
                max_workers=workers, thread_name_prefix='retrans') as pool:
            futs = [pool.submit(_guard, job, k, l, dry_run) for k, l in keys]
            for f in concurrent.futures.as_completed(futs):
                try:
                    f.result()
                except Exception as e:
                    _log(f"worker: {e}")
    finally:
        job['state'] = 'stopped' if _CANCEL.is_set() else 'done'
        job['elapsed'] = round(time_module.time() - job['started'], 1)
        _log(f"[{job['state'].upper()}] {job['done']}/{job['total']} "
             f"fixed={job['fixed']} partial={job['partial']} "
             f"errors={job['errors']} rows_fixed={job['rows_fixed']} "
             f"rows_still_broken={job['rows_remaining']} in {job['elapsed']}s")
        try:
            from .app import _sse_broadcast
            _sse_broadcast('retranslate', job_id=job['job_id'],
                           state=job['state'], done=job['done'],
                           total=job['total'], fixed=job['fixed'],
                           errors=job['errors'])
        except Exception:
            pass


def _guard(job, key, lang, dry_run):
    """Per-song wrapper: cancel check, 429 backoff, and never let one bad
    song stop the pool."""
    if _CANCEL.is_set():
        return
    for attempt in range(3):
        try:
            row = _one(key, lang, dry_run=dry_run)
        except Exception as e:
            row = {'key': key, 'lang': lang, 'song': '', 'artist': '',
                   'source': '', 'status': 'error', 'defects': 0,
                   'detail': str(e), 'fixed': 0, 'remaining': 0}
        if row is None:
            return
        if row['status'] == 'rate_limited' and attempt < 2 and not _CANCEL.is_set():
            # Back off INSIDE the worker slot instead of spinning the whole
            # pool: a 429 is global, so every worker is about to hit it too,
            # and three threads sleeping 20s beats 50 songs failing.
            time_module.sleep(_RATE_LIMIT_BACKOFF_S * (attempt + 1))
            continue
        _push(job, row)
        return


def status(job_id=None):
    with _JOB_LOCK:
        if not _JOB or (job_id and _JOB.get('job_id') != job_id):
            return None
        snap = dict(_JOB)
    return snap


def stop():
    with _JOB_LOCK:
        running = _JOB.get('state') == 'running'
    if running:
        _CANCEL.set()
    return running


def scan(lang=''):
    """Broken-translation census, no writes. Returns
    {songs, songs_broken, rows_broken, defects: {...}, sample: [...]}."""
    lang = (lang or '').strip()
    out = {'songs': 0, 'songs_broken': 0, 'rows_broken': 0,
           'defects': {}, 'sample': []}
    for key, klang in _iter_keys(lang):
        entry = read_entry(key)
        if not entry:
            continue
        data = entry.get('data')
        if not isinstance(data, dict) or not data.get('lyrics'):
            continue
        out['songs'] += 1
        hits = broken_rows(data)
        if not hits:
            continue
        out['songs_broken'] += 1
        out['rows_broken'] += len(hits)
        for _i, d, _t, _tr in hits:
            out['defects'][d] = out['defects'].get(d, 0) + 1
        if len(out['sample']) < 50:
            out['sample'].append({
                'key': key, 'song': data.get('song', ''),
                'artist': data.get('artist', ''), 'rows': len(hits),
                'defects': sorted({d for _i, d, _t, _tr in hits}),
            })
    return out
