# Usage counter: lyrics served, distinct devices, last song + status.
# Recorded on every successful /api/lyrics serve, persisted to
# database/usage_stats.json (throttled flush), read by GET /api/app/stats and
# embedded into release notes by Actions. Never raises.
import json
import os
import threading
import time as time_module

from .paths import USAGE_STATS_FILE

_PATH = USAGE_STATS_FILE
_LOCK = threading.Lock()
_S = None
_DIRTY = 0
_LAST_SAVE = 0.0
_SAVE_EVERY_S = 20
_SAVE_EVERY_N = 50
_MAX_USERS = 5000


def _blank():
    return {'served': 0, 'users': {}, 'last': {}}


def _load():
    global _S
    with _LOCK:
        if _S is not None:
            return _S
        try:
            with open(_PATH, 'r', encoding='utf-8') as f:
                d = json.load(f)
            _S = {
                'served': int(d.get('served', 0)),
                'users': d.get('users', {}) if isinstance(d.get('users'), dict) else {},
                'last': d.get('last', {}) if isinstance(d.get('last'), dict) else {},
            }
        except Exception:
            _S = _blank()
        return _S


def _save_locked():
    global _DIRTY, _LAST_SAVE
    try:
        os.makedirs(os.path.dirname(_PATH) or '.', exist_ok=True)
        tmp = _PATH + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(_S, f, ensure_ascii=False)
        os.replace(tmp, _PATH)
    except Exception as e:
        print(f"[STATS] [WARN] save failed: {e}")
    _DIRTY = 0
    _LAST_SAVE = time_module.time()


def record_serve(video_id, song, artist, lang, tier, source, client_ip):
    """Count one successful lyric serve. Never raises."""
    try:
        s = _load()
        now = time_module.time()
        with _LOCK:
            global _DIRTY
            s['served'] += 1
            s['last'] = {
                'video_id': video_id or '',
                'song': (song or '')[:120],
                'artist': (artist or '')[:120],
                'lang': lang or '',
                'tier': tier or '',
                'source': source or '',
                'status': 'served',
                'ts': now,
            }
            if client_ip:
                s['users'][client_ip] = now
                if len(s['users']) > _MAX_USERS:
                    old = sorted(s['users'], key=s['users'].get)
                    for k in old[:len(s['users']) - _MAX_USERS]:
                        del s['users'][k]
            _DIRTY += 1
            if _DIRTY >= _SAVE_EVERY_N or now - _LAST_SAVE >= _SAVE_EVERY_S:
                _save_locked()
    except Exception as e:
        print(f"[STATS] [WARN] record failed: {e}")


def _fmt(n):
    return f"{n:,}"


def _md_cell(s):
    return (s or '').replace('|', '/').replace('\n', ' ').strip()[:80]


def stats_markdown(snap):
    """Release-notes stats block. Pure function of a snapshot."""
    last = snap.get('last') or {}
    song = _md_cell(last.get('song'))
    artist = _md_cell(last.get('artist'))
    title = f"{song} - {artist}" if (song or artist) else '-'
    detail = ' '.join(x for x in [
        f"`{last.get('tier')}`" if last.get('tier') else '',
        f"via {last.get('source')}" if last.get('source') else '',
    ] if x)
    return (
        '<div align="center">\n\n'
        '| Lyrics served | Devices | Last song |\n'
        '|---|---|---|\n'
        f"| **{_fmt(snap.get('served', 0))}** "
        f"| **{_fmt(snap.get('users', 0))}** "
        f"| {title} {detail} |\n"
        '\n</div>'
    )


def snapshot():
    """{served, users, last, stats_md}. Never raises."""
    try:
        s = _load()
        with _LOCK:
            snap = {
                'served': s['served'],
                'users': len(s['users']),
                'last': dict(s['last']),
            }
        snap['stats_md'] = stats_markdown(snap)
        return snap
    except Exception:
        return {'served': 0, 'users': 0, 'last': {},
                'stats_md': stats_markdown({})}
