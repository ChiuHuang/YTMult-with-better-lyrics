# Serving counter for the public badges, without re-reading the whole log.
#
# Why this file exists: the badge needs "lyrics served" and the only durable
# record of a serve is a line in logs/server.log. The first implementation
# re-read the ENTIRE log (server.log + server.log.1) every 30 seconds. That
# log is ~6 MB, so a badge on a README re-read 6 MB of disk every 30 s --
# about 767 MB/hr to produce one integer, and a restart or a redeploy paid it
# again from byte 0.
#
# Instead: count ONCE, remember the byte offset reached, and thereafter read
# only the bytes appended since. The total is the sum of the per-file counts,
# so it is a plain sum of small numbers and never needs the log again.
#
# The subtle part is ROTATION. server.log is renamed to server.log.1 at
# startup when it passes 5 MB (logging_util). Offset-per-path would
# double-count there: the new server.log.1 is the old server.log, whose tail
# was already counted, so a plain "size > offset" check would re-add the last
# megabyte. So each file is tracked by IDENTITY (st_dev:st_ino), not by path.
# The rotated file keeps its identity and its offset, the new server.log is a
# new identity starting at 0, and nothing is counted twice.
#
# A file that disappears (the old .1 being overwritten) is pruned, so the
# total drops its contribution -- exactly what the old re-read-the-world
# version did too. The number is not monotonic across log generations, by
# design: it is a count of the serves still recorded on disk, not a lifetime
# ledger. usage_stats.json is the process-lifetime counter and is used as the
# fallback when there is no log at all.
#
# State file: database/badge_stats.json (database/ is gitignored).
import json
import os
import threading
import time

from .paths import BADGE_STATS_FILE

_STATE_VERSION = 1
_STATS_PATH = BADGE_STATS_FILE
_TTL = 30.0

# One serve = one lyrics response. 'Returning ' is the /api/lyrics response
# line; a stream request logs three pushes (RAW/MACHINE/FINAL) and only the
# FINAL one is a completed serve. Matched as bytes, not text: these files are
# multi-MB and decoding them is pure waste for a substring test.
_SERVE_MARKS = (b' Returning ', b'[Stream] push FINAL')
_TAG = b'[SEND] [REQ '

_lock = threading.Lock()
_memo = {'at': 0.0, 'served': None}
_state = None          # {'files': {identity: {'off': int, 'count': int}}}


def _load():
    global _state
    try:
        with open(_STATS_PATH, 'r', encoding='utf-8') as f:
            data = json.load(f)
        if int(data.get('version', 0)) == _STATE_VERSION and isinstance(data.get('files'), dict):
            _state = data
            return
    except Exception:
        pass
    _state = {'version': _STATE_VERSION, 'files': {}}


def _save():
    try:
        os.makedirs(os.path.dirname(_STATS_PATH), exist_ok=True)
        tmp = _STATS_PATH + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(_state, f)
        os.replace(tmp, _STATS_PATH)     # atomic: never a half-written file
    except Exception:
        pass                            # a stats file is never worth an outage


def _count_tail(path, off, size=None):
    """Serves in path[off:]. Returns (count, new_off).

    Bytes are read, not decoded, and the offset only advances to the last
    newline. A torn final line (the tee can be mid-write) is therefore left
    for the next pass instead of being counted twice or dropped.

    `size` is passed in because the caller has already stat'd the file. When
    nothing has been appended the file is not opened at all -- on a warm pass
    that is the difference between touching the 6MB rotated generation and
    not touching it.
    """
    if size is None:
        try:
            size = os.path.getsize(path)
        except OSError:
            return 0, off
    if size <= off:
        return 0, off
    try:
        with open(path, 'rb') as f:
            f.seek(off)
            chunk = f.read(size - off)
    except OSError:
        return 0, off
    cut = chunk.rfind(b'\n')
    if cut < 0:
        return 0, off                     # no complete line yet
    usable = chunk[:cut + 1]
    n = 0
    for line in usable.split(b'\n'):
        if _TAG in line:
            for mark in _SERVE_MARKS:
                if mark in line:
                    n += 1
                    break
    return n, off + len(usable)


def _refresh():
    """One pass over whatever is new. Cheap once the log has been read once."""
    from .app import SERVER_LOG_FILE
    if _state is None:
        _load()
    live = {}
    for path in (SERVER_LOG_FILE, SERVER_LOG_FILE + '.1'):
        try:
            st = os.stat(path)
        except OSError:
            continue
        ident = f'{st.st_dev}:{st.st_ino}'
        live[ident] = path
        prev = _state['files'].get(ident) or {'off': 0, 'count': 0}
        # A shrunk file under the SAME identity is a truncate, not a rotation;
        # re-read it rather than skipping the rewritten bytes.
        off = int(prev.get('off', 0))
        if off > st.st_size:
            off = 0
        n, new_off = _count_tail(path, off, st.st_size)
        _state['files'][ident] = {'off': new_off,
                                  'count': int(prev.get('count', 0)) + n,
                                  'path': os.path.basename(path)}
    # Drop identities that are gone: their generation was overwritten.
    for ident in [i for i in _state['files'] if i not in live]:
        _state['files'].pop(ident, None)
    if _state['files'] != _memo.get('files'):
        _save()
    return sum(int(v.get('count', 0)) for v in _state['files'].values())


def served_count(force=False):
    """Total serves recorded on disk. Cached for _TTL seconds."""
    now = time.time()
    with _lock:
        if not force and _memo['served'] is not None and now - _memo['at'] < _TTL:
            return _memo['served']
        try:
            total = _refresh()
        except Exception:
            # Never let a badge be the thing that 500s. Fall back to the
            # process-lifetime counter, which is always readable.
            from .usage_stats import snapshot
            total = int(snapshot().get('served', 0))
        _memo['at'] = now
        _memo['served'] = total
        return total


def stats():
    """Diagnostics for the dashboard: where the number came from."""
    served_count()
    files = sorted((_state or {'files': {}})['files'].values(),
                   key=lambda v: -int(v.get('count', 0)))
    return {
        'served': _memo['served'],
        'source': 'log',
        'file': _STATS_PATH.replace('\\', '/'),
        'scanned_at': _memo['at'],
        'files': files,
    }


if __name__ == '__main__':
    import sys
    # `python -m server.badge_stats` rebuilds the file from scratch, which is
    # what you want after editing the marker patterns.
    if '--rebuild' in sys.argv:
        _state = None
        _memo['served'] = None
        try:
            os.remove(_STATS_PATH)
        except OSError:
            pass
    print('served:', f'{served_count(force=True):,}')
    print(json.dumps(stats(), indent=1))
