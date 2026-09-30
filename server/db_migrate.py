# Version-bump migration for the whole database.
#
# WHY THIS EXISTS. cache.py has two gates. `_CACHE_FORMAT_VERSION` says the
# SHAPE of a record changed; `_PARSER_EPOCH` says the TEXT was derived by
# different parsers. Bumping either makes get_cached return None, and a None
# from get_cached is indistinguishable from "never fetched" -- so a bump used
# to mean "throw away the library and hope the providers still answer". The
# sub-word span bug (19c5d2c) is what that costs: the fix landed, the version
# moved, every entry was invalidated, and the song came back with the SAME
# broken text because nothing ever re-derived it.
#
# WHAT IT DOES. Two halves, deliberately separated:
#
#   offline  postprocess_lyrics + sanitize_lyrics_parts are PURE functions of
#            already-parsed lyrics, so they replay over every entry on disk
#            with no network and no source file. Broken translations are
#            repaired the same way (apply_display_transforms is response-time
#            by design, so nothing had ever written its repair back). Entries
#            whose epoch is current get stamped current and are DONE.
#   network  an entry whose text came from a parser we have since fixed cannot
#            be fixed here -- the database holds the parser's OUTPUT, and the
#            only other copy (database/candidates) holds the same output. Those
#            are counted as `needs_refetch` and re-stamped WITHOUT claiming the
#            epoch, so the gate that produced this list stays true after the
#            sweep instead of going blind.
#
# The tier rule: an entry is rewritten whenever the migration does not make it
# WORSE. A dropped tier is not a failure -- sanitize_lyrics_parts stripping a
# line that claimed wordSynced with one part IS the fake-wbw fix, and refusing
# to write it would preserve the lie -- so it is written and reported as
# `demoted` with the line count, which is the one number a reviewer needs.
# The much worse direction, an entry becoming EMPTY, is refused.
import copy
import json
import os
import threading
import time as time_module

from .paths import LYRICS_DIR, CANDIDATES_DIR
from .cache import (
    _CACHE_FORMAT_VERSION, _PARSER_EPOCH,
    sanitize_lyrics_parts, postprocess_lyrics,
    read_entry, stamp_entry, is_not_found_result, _cache_filename,
)
from .candidates import (
    read_snapshot_raw, rewrite_snapshot, _SNAPSHOT_VERSION,
)

# `from .rerace import _tier` is deliberately NOT done at module level: rerace
# imports cache, library and candidates, and db_migrate is imported by
# server/__init__ between them. _tier is 4 lines of pure logic, and a second
# copy that cannot drift is worth more than the indirection. It is verified
# against rerace._tier by tmp/test_db_migrate.py.
def _wsv(data):
    """0 plain, 1 line-synced, 2 word-by-word.

    A verbatim copy of race._wbw_line_count's wbw test, including the part
    that is easy to omit: two word parts with the SAME startTimeMs are not
    word timing (that is what an interpolated fake looks like), so they do not
    make the tier. The two functions must agree, because rerace decides
    whether to keep a cached entry and this decides whether the sweep reports
    a demotion -- a copy that scored those lines as wbw would report
    'demoted' for an entry the rest of the server considers perfectly good.
    """
    if not data:
        return -1
    for l in (data.get('lyrics') or []):
        if not isinstance(l, dict) or not l.get('wordSynced'):
            continue
        parts = l.get('parts') or []
        if len(parts) > 1 and len({p.get('startTimeMs') for p in parts}) > 1:
            return 2
    return 1 if data.get('synced') else 0


_TIER_NAME = {2: 'wbw', 1: 'line', 0: 'plain', -1: 'none'}
_RESULTS_CAP = 300
_LOG_EVERY = 25

# Offline postprocess is pure CPU on small dicts and writes one file at a time,
# so the whole library is seconds, not minutes: no thread pool, no lock, and
# crucially no progress SSE that could interleave with a live fetch.
_JOB_LOCK = threading.Lock()
_JOB = {}


def _log(msg):
    print(f"[MIGRATE] {msg}")


def _repair_translations(lyrics, lang):
    """Salvage or drop a broken translation in place, without any API call.

    apply_display_transforms is documented as "never applied to what gets
    persisted" -- it is a response-time pass, so every entry written before the
    echo guard existed still carries the un-repaired row and the device
    re-applies the same repair on every play. Writing the repair back once is
    the whole point of this function.

    Returns (rows_shortened, rows_dropped): a salvage that keeps part of the
    translation keeps the row, and one with nothing recognizable left is
    DROPPED -- which is what makes it show up in find_untranslated() and in the
    retranslate job instead of being served from disk forever.
    """
    from .translate import apply_display_transforms
    rows = [l for l in lyrics if isinstance(l, dict)]
    before = [l.get('translated') for l in rows]
    try:
        # auto_zh stays off: inlining a script conversion into `text` is a
        # DISPLAY decision (it drops the translate row entirely), and this
        # function is allowed to touch translations only.
        apply_display_transforms(lyrics, lang or 'zh-TW')
    except Exception:
        return (0, 0)
    shortened = dropped = 0
    for l, b in zip(rows, before):
        a = l.get('translated')
        if a == b:
            continue
        if not a:
            dropped += 1
        else:
            shortened += 1
    return (shortened, dropped)


def _join_parts(parts):
    """Rebuild display text from word parts the way the device does
    (Source/LyricsSheet.x wbwDisplayTextForLyric: trim each part, no separator
    where the source declared `space: false`, no separator between two CJK
    chars). Kept here as the corroborating oracle for the repair below, so the
    server and the phone cannot disagree about what a parts list says.
    """
    out = []
    for p in parts or []:
        if not isinstance(p, dict):
            continue
        w = (p.get('words') or '').strip()
        if not w:
            continue
        if out and not (p.get('space') is False):
            prev, nxt = out[-1][-1], w[0]
            if not (_is_cjk_char(prev) and _is_cjk_char(nxt)):
                out.append(' ')
        out.append(w)
    return ''.join(out)


def _is_cjk_char(ch):
    return ('\u3040' <= ch <= '\u30ff' or '\u3400' <= ch <= '\u4dbf'
            or '\u4e00' <= ch <= '\u9fff' or '\uff00' <= ch <= '\uffef'
            or '\u3000' <= ch <= '\u303f')


def _repeated_head_unit(text, max_unit=16):
    """Length of an immediately-repeated head fragment, or 0.

    "痛いの痛いのどっちに弱い" -> 3. "BITE BITE" -> 0, because the space breaks
    the prefix comparison, which is the same accident that protects every
    space-separated chorus repeat from this rule.
    """
    n = len(text or '')
    for p in range(2, min(max_unit, n // 2) + 1):
        if text[:p] == text[p:2 * p]:
            return p
    return 0


def _fix_duplicated_head(lyrics):
    """Repair a line whose declared text repeats its own head, but ONLY when
    the word parts independently corroborate the shorter reading.

    Returns (repaired, uncorroborated).

    Why the corroboration is mandatory: "痛いの痛いの" and "はいはい" and
    "yeah yeah" are indistinguishable from a parser artifact by looking at the
    text alone, and collapsing a real repeat destroys a lyric. What is NOT
    ambiguous is a disagreement between the two independent copies of the same
    line -- the file's declared text and the timed word spans. When the spans
    spell the line WITHOUT the repetition, one of them is wrong, and the spans
    are the copy the phone actually draws, so the text is the side to correct.

    So:
      text repeats, parts do not  -> repair the text (provable)
      text repeats, parts repeat  -> both agree; leave it and report it. That
        is either a genuinely sung repeat or a source-side artifact, and the
        two are not separable without the file. Those are refetch work.
      text repeats, no parts     -> no second opinion exists. Not touched.

    The parts are never modified, so a word-synced row stays word-synced and
    the phone keeps parsing it exactly as before; only `text` changes, which is
    the field a non-word-synced row draws from.
    """
    repaired = uncorroborated = 0
    for l in lyrics or []:
        if not isinstance(l, dict):
            continue
        text = l.get('text') or ''
        p = _repeated_head_unit(text)
        if not p:
            continue
        parts = l.get('parts') or []
        if not parts:
            uncorroborated += 1
            continue
        joined = _join_parts(parts)
        if _repeated_head_unit(joined) or not joined:
            uncorroborated += 1
            continue
        if joined == text[p:]:
            l['text'] = joined
            repaired += 1
        else:
            uncorroborated += 1
    return repaired, uncorroborated


def _migrate_lyrics(lyrics, duration_s):
    """The offline fix pass. Returns True when anything actually changed, so
    the caller can tell "re-stamped a stale file" from "repaired something"
    and report the difference -- those are different facts and only one of
    them is worth a user's attention."""
    before = _canonical(lyrics)
    # Order matters and is not interchangeable: postprocess folds space parts
    # into their neighbour, and it is sanitize that then decides whether a line
    # still has enough parts to be word-synced. Running them the other way
    # round leaves `parts: [word]` with `wordSynced: true` -- the exact fake
    # this pass exists to remove. pipeline.fetch_all_lyrics ends the same way
    # (sanitize last), so the sweep and a fresh fetch agree.
    postprocess_lyrics(lyrics, duration_s or 0)
    sanitize_lyrics_parts(lyrics)
    return _canonical(lyrics) != before


def _canonical(lyrics):
    """A comparable fingerprint of the parts of a lyric that the offline pass
    can change: which lines exist, their text, their timing and their word
    parts. `translated` is excluded on purpose -- translation repair is
    counted separately by _repair_translations, and folding it in here would
    make one changed number hide the other."""
    out = []
    for l in lyrics or []:
        if not isinstance(l, dict):
            continue
        out.append((
            l.get('startTimeMs'), l.get('durationMs'), l.get('text'),
            bool(l.get('wordSynced')), bool(l.get('isInstrumental')),
            tuple((p.get('startTimeMs'), p.get('durationMs'), p.get('words'))
                  for p in (l.get('parts') or []) if isinstance(p, dict)),
        ))
    return tuple(out)


def _iter_keys():
    """Every cache key on disk, full and :fast alike, decoded from the
    percent-encoded filename. The :fast sibling is migrated too and not
    skipped: a fast entry is what the device gets for the first 10s of a
    play, and a stale-version fast file shadows the full key in the paths
    that read it directly (routes_stream:233, playlist:87) -- that is how a
    stale payload got stamped with our version in the first place."""
    try:
        names = os.listdir(LYRICS_DIR)
    except Exception:
        return
    for fname in names:
        if not fname.endswith('.json') or fname.endswith('.tmp'):
            continue
        from .cache import _cache_key_from_filename
        key = _cache_key_from_filename(fname)
        if key:
            yield key


def scan():
    """What a sweep would do, without touching anything.

    Returns counts plus a sample of the stale keys, which is what the
    dashboard renders before the operator commits to rewriting the database.
    `entries` counts FILES (full + :fast), `songs` counts distinct
    (video_id, lang) pairs, because those are the two numbers a person
    actually reasons about: "2700 files" is a directory listing, "812 songs"
    is a library."""
    from .candidates import _cand_path
    out = {'entries': 0, 'songs': 0, 'stale_entries': 0, 'stale_songs': 0,
           'needs_refetch': 0, 'needs_refetch_songs': 0,
           'candidates': 0, 'stale_candidates': 0,
           'format_version': _CACHE_FORMAT_VERSION,
           'parser_epoch': _PARSER_EPOCH,
           'sample': []}
    songs = set()
    stale_songs = set()
    try:
        names = list(_iter_keys())
    except Exception:
        names = []
    for key in names:
        entry = read_entry(key)
        if not entry:
            continue
        out['entries'] += 1
        parts = key.split(':')
        is_fast = parts[-1] == 'fast'
        song = ':'.join(parts[:-2] if is_fast else parts[:-1])
        songs.add(song)
        stale = (entry.get('v') != _CACHE_FORMAT_VERSION
                 or entry.get('pv') != _PARSER_EPOCH)
        if not stale:
            continue
        out['stale_entries'] += 1
        stale_songs.add(song)
        if entry.get('pv') != _PARSER_EPOCH:
            out['needs_refetch'] += 1
            out['needs_refetch_songs'] += 1
        if len(out['sample']) < 40:
            data = entry.get('data') or {}
            out['sample'].append({
                'key': key,
                'song': data.get('song', ''),
                'artist': data.get('artist', ''),
                'v': entry.get('v'),
                'pv': entry.get('pv', 0),
                'tier': _TIER_NAME.get(_wsv(data), 'none'),
                'needs_refetch': entry.get('pv') != _PARSER_EPOCH,
            })
    out['songs'] = len(songs)
    out['stale_songs'] = len(stale_songs)
    try:
        for fname in os.listdir(CANDIDATES_DIR):
            if not fname.endswith('.json'):
                continue
            out['candidates'] += 1
            path = os.path.join(CANDIDATES_DIR, fname)
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    payload = json.load(f)
            except Exception:
                continue
            if payload.get('v') != _SNAPSHOT_VERSION or payload.get('pv') != _PARSER_EPOCH:
                out['stale_candidates'] += 1
    except Exception:
        pass
    return out


def _sweep_one(key, repair_translations=True, write=None):
    """Migrate one lyrics entry. Returns a result row, or None when the file
    was not migratable (missing, unparseable, or an empty/no-lyrics result
    that must not be resurrected).

    `write` defaults to cache.stamp_entry and is the seam the dry run
    overrides. The migration itself always runs on the real dict, because the
    report below is derived from the migrated state -- a dry run that skipped
    the work would have nothing to report."""
    write = write or stamp_entry
    entry = read_entry(key)
    if not entry:
        return None
    data = entry.get('data')
    if not isinstance(data, dict):
        return None
    row = {'key': key, 'song': data.get('song', ''), 'artist': data.get('artist', ''),
           'source': data.get('source', ''), 'status': 'error', 'message': '',
           'from': _TIER_NAME.get(_wsv(data), 'none'), 'to': '', 'lines': 0,
           'repaired': 0}
    if is_not_found_result(data):
        row['status'] = 'skipped'
        row['message'] = 'empty/not-found entry'
        return row

    lang = key.split(':')[-1]
    if lang == 'fast':
        lang = key.split(':')[-2] if key.count(':') >= 2 else lang

    stale_v = entry.get('v') != _CACHE_FORMAT_VERSION
    stale_pv = entry.get('pv') != _PARSER_EPOCH
    old_tier = _wsv(data)
    old_lines = len(data.get('lyrics') or [])
    row['lines'] = old_lines

    repaired_lines = 0
    dup_fixed = dup_unproven = 0
    try:
        changed = _migrate_lyrics(data.get('lyrics') or [], data.get('duration', 0))
        # AFTER postprocess: `_merge_spaces` folds space parts away and
        # sanitize may then drop a line's parts entirely, so a line that had
        # the corroboration when it was read can have none by now. Running the
        # repair on the post-processed shape is also what the device will see,
        # since it never sees the pre-postprocess one.
        dup_fixed, dup_unproven = _fix_duplicated_head(data.get('lyrics') or [])
        if repair_translations:
            shortened, dropped = _repair_translations(data.get('lyrics') or [], lang)
            repaired_lines = shortened + dropped
        else:
            shortened = dropped = 0
    except Exception as e:
        row['message'] = f'migrate: {e}'
        return row

    new_tier = _wsv(data)
    new_lines = len(data.get('lyrics') or [])
    row['to'] = _TIER_NAME.get(new_tier, 'none')
    row['repaired'] = repaired_lines

    if not data.get('lyrics'):
        row['status'] = 'skipped'
        row['message'] = 'migration emptied the lyrics; kept the old file'
        return row
    if new_tier == -1:
        row['status'] = 'skipped'
        row['message'] = 'lost its tier; kept the old file'
        return row

    if not (stale_v or stale_pv) and not changed and not repaired_lines and not dup_fixed:
        row['status'] = 'current'
        # Still report an uncorroborated doubled line here. Returning with an
        # empty message made it invisible: the entry is current, so nothing
        # about it appears in a scan, and the defect that made the user send a
        # screenshot would have been silently dropped by the one feature whose
        # job is to find exactly this.
        if dup_unproven:
            row['message'] = f'{dup_unproven} doubled line(s) unproven, need a refetch'
        return row

    # The epoch is stamped ONLY when the entry's text was parsed by the
    # parsers in this build. Claiming it for a parser-stale entry is the one
    # way this sweep could make things permanently worse: needs_refetch would
    # go empty, load_snapshot would start serving pre-fix text again, and
    # nothing would ever come back to fix it.
    epoch = None if stale_pv else _PARSER_EPOCH
    if not write(key, data, ts=entry.get('ts'), parser_epoch=epoch):
        row['status'] = 'error'
        row['message'] = 'write failed'
        return row

    bits = []
    if stale_v:
        bits.append(f'v{entry.get("v")}->{_CACHE_FORMAT_VERSION}')
    if new_lines != old_lines:
        bits.append(f'lines {old_lines}->{new_lines}')
    if dup_fixed:
        bits.append(f'{dup_fixed} doubled line(s) repaired')
    if dup_unproven:
        bits.append(f'{dup_unproven} doubled line(s) unproven, need a refetch')
    if repaired_lines:
        bits.append(f'{repaired_lines} translation(s) repaired')
    if new_tier != old_tier:
        bits.append(f'tier {row["from"]}->{row["to"]}')
    if stale_pv:
        bits.append('text still needs a refetch')
    row['message'] = '; '.join(bits) or 're-stamped'

    if stale_pv:
        row['status'] = 'needs_refetch'
    elif new_tier < old_tier:
        # Not a failure: stripping the word parts off a line that CLAIMED
        # wordSynced with a single part is the fake-wbw fix. Written on
        # purpose, surfaced as its own status because a tier going DOWN is
        # the one number here a human has to look at.
        row['status'] = 'demoted'
    elif changed or repaired_lines or dup_fixed:
        row['status'] = 'fixed'
    else:
        row['status'] = 'restamped'
    return row


def _sweep_snapshot(video_id, write=None):
    """Migrate one candidate snapshot: postprocess every provider's lyrics and
    re-stamp the format version. Same epoch rule as the lyrics entries -- a
    parser-stale snapshot is upgraded but not marked current, so
    load_snapshot keeps refusing it instead of feeding pre-fix text to
    /providers/select. Returns (written, providers)."""
    write = write or rewrite_snapshot
    payload = read_snapshot_raw(video_id)
    if payload is None:
        return (False, 0)
    stale_v = payload.get('v') != _SNAPSHOT_VERSION
    stale_pv = payload.get('pv') != _PARSER_EPOCH
    cands = payload.get('candidates') or []
    before = tuple(_canonical((c.get('data') or {}).get('lyrics') or []) for c in cands)

    def _mutate(p):
        for c in (p.get('candidates') or []):
            d = c.get('data') or {}
            if not d.get('lyrics'):
                continue
            # postprocess FIRST: it folds the space parts, and sanitize is
            # what then strips the wordSynced claim from a line left with one
            # part. Reverse order leaves the fake in place.
            postprocess_lyrics(d['lyrics'], 0)
            sanitize_lyrics_parts(d['lyrics'])
            # `lines` is shown in the switcher menu; leaving it stale would
            # make the row count disagree with the row it opens.
            c['lines'] = len(d['lyrics'])
        return True

    def _apply(p):
        _mutate(p)

    if not (stale_v or stale_pv) and _snapshot_unchanged(payload, before):
        return (False, len(cands))
    ok = write(video_id, _apply, parser_epoch=(None if stale_pv else _PARSER_EPOCH))
    return (ok, len(cands))


def _snapshot_unchanged(payload, before):
    """True when the postprocess pass would be a no-op for this snapshot.

    The mutation has to be trialled on a COPY: reading the file again after the
    write to compare would mean the dry run had already written it, which is
    the whole thing a dry run must not do."""
    working = copy.deepcopy(payload.get('candidates') or [])
    for c in working:
        d = c.get('data') or {}
        if d.get('lyrics'):
            # Same order as _migrate_lyrics, for the same reason.
            postprocess_lyrics(d['lyrics'], 0)
            sanitize_lyrics_parts(d['lyrics'])
    after = tuple(_canonical((c.get('data') or {}).get('lyrics') or []) for c in working)
    return before == after


def _snapshot_ids():
    ids = []
    try:
        for fname in os.listdir(CANDIDATES_DIR):
            if not fname.endswith('.json') or fname.endswith('.tmp'):
                continue
            from urllib.parse import unquote
            ids.append(unquote(fname[:-5]))
    except Exception:
        pass
    return ids


def sweep(dry_run=False, force=False, repair_translations=True,
          migrate_candidates=True):
    """Migrate the whole database to the current format version + parser epoch.

    dry_run   report what would change, write nothing.
    force     migrate EVERY entry, not just the stale ones (the fix pass is
              idempotent, so this is how you re-apply a fix that did not come
              with a version bump).
    Returns the job dict, which is also what status() serves.

    dry_run is enforced at the WRITE, not at the top of the loop: `_sweep_one`
    is also what decides the report (which rows changed, which were demoted),
    so a dry run that skipped the function would report nothing at all. It
    therefore runs the real pass over a deep copy and drops the write.
    """
    _write = (lambda key, data, ts=None, parser_epoch=None: True) if dry_run else stamp_entry
    _write_snap = ((lambda vid, fn, parser_epoch=None: True) if dry_run else rewrite_snapshot)
    with _JOB_LOCK:
        _JOB.clear()
        _JOB.update({
            'job_id': str(int(time_module.time() * 1000)),
            'state': 'running', 'dry_run': bool(dry_run), 'force': bool(force),
            'started': time_module.time(),
            'entries': 0, 'fixed': 0, 'restamped': 0, 'demoted': 0,
            'needs_refetch': 0, 'current': 0, 'skipped': 0, 'errors': 0,
            'translations_repaired': 0,
            'candidates': 0, 'candidates_written': 0,
            'results': [],
        })
        job = _JOB

    keys = list(_iter_keys())
    job['entries'] = len(keys)
    t0 = time_module.time()
    for i, key in enumerate(keys, 1):
        try:
            if not force:
                entry = read_entry(key)
                if not entry or (entry.get('v') == _CACHE_FORMAT_VERSION
                                 and entry.get('pv') == _PARSER_EPOCH):
                    job['current'] += 1
                    continue
            row = _sweep_one(key, repair_translations=repair_translations,
                         write=_write)
        except Exception as e:
            row = {'key': key, 'song': '', 'artist': '', 'source': '',
                   'status': 'error', 'message': str(e), 'from': '?', 'to': '',
                   'lines': 0, 'repaired': 0}
        if row is None:
            job['skipped'] += 1
            continue
        if row['status'] in job:
            job[row['status']] += 1
        if row['status'] == 'error':
            job['errors'] += 1
        job['translations_repaired'] += row.get('repaired', 0)
        if len(job['results']) < _RESULTS_CAP:
            job['results'].append(row)
        if i % _LOG_EVERY == 0:
            _log(f"{i}/{len(keys)} fixed={job['fixed']} demoted={job['demoted']} "
                 f"needs_refetch={job['needs_refetch']} errors={job['errors']}")

    if migrate_candidates:
        ids = _snapshot_ids()
        job['candidates'] = len(ids)
        for i, vid in enumerate(ids, 1):
            try:
                written, n = _sweep_snapshot(vid, write=_write_snap)
                if written:
                    job['candidates_written'] += 1
            except Exception as e:
                _log(f"snapshot {vid} failed: {e}")
                job['errors'] += 1
            if i % _LOG_EVERY == 0:
                _log(f"snapshots {i}/{len(ids)}")

    job['state'] = 'done'
    job['elapsed'] = round(time_module.time() - t0, 1)
    _log(f"[{('DRY ' if dry_run else '')}DONE] entries={job['entries']} "
         f"fixed={job['fixed']} restamped={job['restamped']} "
         f"demoted={job['demoted']} needs_refetch={job['needs_refetch']} "
         f"skipped={job['skipped']} errors={job['errors']} "
         f"snapshots={job['candidates_written']}/{job['candidates']} "
         f"translations_repaired={job['translations_repaired']} "
         f"in {job['elapsed']}s")
    try:
        from .app import _sse_broadcast
        _sse_broadcast('migrate', job_id=job['job_id'], state='done',
                       fixed=job['fixed'], needs_refetch=job['needs_refetch'],
                       demoted=job['demoted'])
    except Exception:
        pass
    return job


def status(job_id=None):
    with _JOB_LOCK:
        if not _JOB or (job_id and _JOB.get('job_id') != job_id):
            return None
        snap = dict(_JOB)
    return snap


def needs_refetch_keys(limit=0):
    """The exact work list for the refetch leg: cache keys whose text is
    parser-stale. bulk_refetch's `stale` scope is built from this, so the two
    halves of the feature agree on what "stale" means instead of each keeping
    its own copy of the rule."""
    out = []
    for key in _iter_keys():
        entry = read_entry(key)
        if not entry or entry.get('pv') == _PARSER_EPOCH:
            continue
        data = entry.get('data') or {}
        out.append({'key': key, 'video_id': key.rsplit(':', 2)[0]
                    if key.count(':') >= 2 else key.split(':')[0],
                    'song': data.get('song', ''), 'artist': data.get('artist', '')})
        if limit and len(out) >= limit:
            break
    return out


def run_startup_sweep():
    """Called from main() on a daemon thread. Offline only, and only when
    something is actually stale -- a clean start must not open every file in
    the database for nothing."""
    try:
        from .app_settings import get_all
        if not get_all().get('db.auto_sweep', True):
            _log("auto-sweep disabled by db.auto_sweep")
            return
        info = scan()
        if not info['stale_entries'] and not info['stale_candidates']:
            _log(f"database current: {info['songs']} song(s), "
                 f"v{_CACHE_FORMAT_VERSION}/epoch {_PARSER_EPOCH}, nothing to do")
            return
        _log(f"version bump detected: {info['stale_songs']}/{info['songs']} song(s) "
             f"stale ({info['needs_refetch']} file(s) need a real refetch), "
             f"{info['stale_candidates']} snapshot(s) stale")
        _log("running the offline sweep; the refetch leg stays manual "
             "(Library -> Database version)")
        job = sweep()
        if job['needs_refetch']:
            _log(f"[NEXT] {job['needs_refetch']} file(s) still hold pre-fix text. "
                 f"Run Library -> Database version -> Refetch stale to get them.")
    except Exception as e:
        _log(f"auto-sweep failed: {e}")
