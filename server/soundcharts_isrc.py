"""Server-side Soundcharts ISRC lookup with a durable, shared response cache.

API credentials are read only from the server environment. The tweak never
receives or stores them. Positive results live for 30 days; a missing song or
ISRC is retried after 12 hours so Soundcharts can populate newly added data.
"""
import hashlib
import os
import re
import sqlite3
import threading
import time
from collections import deque
from contextlib import closing
from datetime import datetime, timezone

import requests

from .paths import DATA_DIR

_DB = os.path.join(DATA_DIR, 'soundcharts_isrc.sqlite3')
_POSITIVE_TTL = 30 * 24 * 60 * 60
_NEGATIVE_TTL = 12 * 60 * 60
_ERROR_TTL = 60
_CLIENT_HOURLY_LIMIT = 90
_VIDEO_ID = re.compile(r'^[A-Za-z0-9_-]{11}$')
_ISRC = re.compile(r'^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$')
_LOCK = threading.Lock()
_IN_FLIGHT = {}
_CREDENTIAL_LOCK = threading.Lock()
_CREDENTIAL_CURSOR = 0
_DIAGNOSTIC_LOCK = threading.Lock()
_DIAGNOSTIC_LOGS = deque(maxlen=100)
_DIAGNOSTIC_CURRENT = None


def record_diagnostic(video_id, title='', artist='', source='unknown', state='unknown', isrc=None):
    """Keep a bounded, in-memory ISRC trace for the authenticated dashboard."""
    global _DIAGNOSTIC_CURRENT
    entry = {
        'at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'video_id': (video_id or '')[:32] if isinstance(video_id, str) else '',
        'title': (title or '')[:180] if isinstance(title, str) else '',
        'artist': (artist or '')[:180] if isinstance(artist, str) else '',
        'source': (source or 'unknown')[:48] if isinstance(source, str) else 'unknown',
        'state': (state or 'unknown')[:120] if isinstance(state, str) else 'unknown',
        'isrc': isrc if isinstance(isrc, str) and _ISRC.fullmatch(isrc) else None,
    }
    with _DIAGNOSTIC_LOCK:
        _DIAGNOSTIC_LOGS.append(entry)
        if (_DIAGNOSTIC_CURRENT and entry['video_id'] and
                entry['video_id'] == _DIAGNOSTIC_CURRENT.get('video_id')):
            entry['title'] = entry['title'] or _DIAGNOSTIC_CURRENT.get('title', '')
            entry['artist'] = entry['artist'] or _DIAGNOSTIC_CURRENT.get('artist', '')
        if (_DIAGNOSTIC_CURRENT is None or
                entry['state'] == 'lookup started' or
                entry['state'] == 'client lookup started' or
                entry['state'] == 'playback ISRC available' or
                not entry['video_id'] or
                entry['video_id'] == _DIAGNOSTIC_CURRENT.get('video_id')):
            _DIAGNOSTIC_CURRENT = entry


def diagnostics_snapshot():
    with _DIAGNOSTIC_LOCK:
        return {
            'current': dict(_DIAGNOSTIC_CURRENT) if _DIAGNOSTIC_CURRENT else None,
            'logs': [dict(entry) for entry in _DIAGNOSTIC_LOGS],
        }


def _db():
    os.makedirs(DATA_DIR, exist_ok=True)
    conn = sqlite3.connect(_DB, timeout=5)
    conn.execute('''CREATE TABLE IF NOT EXISTS soundcharts_isrc_cache (
        video_id TEXT PRIMARY KEY,
        isrc TEXT,
        expires_at REAL NOT NULL,
        updated_at REAL NOT NULL
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS soundcharts_isrc_client_budget (
        client_key TEXT NOT NULL,
        hour INTEGER NOT NULL,
        count INTEGER NOT NULL,
        PRIMARY KEY(client_key, hour)
    )''')
    conn.commit()
    return conn


def _read_cache(video_id):
    try:
        with closing(_db()) as conn:
            row = conn.execute(
                'SELECT isrc, expires_at FROM soundcharts_isrc_cache WHERE video_id=?',
                (video_id,),
            ).fetchone()
        if row and row[1] > time.time():
            return {'isrc': row[0] or None, 'source': 'cache'}
        if row:
            with closing(_db()) as conn, conn:
                conn.execute('DELETE FROM soundcharts_isrc_cache WHERE video_id=?', (video_id,))
    except Exception as exc:
        print(f'[ISRC] cache read failed ({type(exc).__name__})')
    return None


def _write_cache(video_id, isrc, ttl):
    now = time.time()
    try:
        with closing(_db()) as conn, conn:
            conn.execute(
                '''INSERT INTO soundcharts_isrc_cache(video_id,isrc,expires_at,updated_at)
                   VALUES(?,?,?,?) ON CONFLICT(video_id) DO UPDATE SET
                   isrc=excluded.isrc, expires_at=excluded.expires_at, updated_at=excluded.updated_at''',
                (video_id, isrc or '', now + ttl, now),
            )
    except Exception as exc:
        print(f'[ISRC] cache write failed ({type(exc).__name__})')


def _consume_client_budget(client_id):
    """Allow at most 90 uncached requests per client in an hour bucket."""
    key = hashlib.sha256((client_id or 'unknown').encode('utf-8')).hexdigest()
    hour = int(time.time() // 3600)
    try:
        with closing(_db()) as conn, conn:
            conn.execute('BEGIN IMMEDIATE')
            row = conn.execute(
                'SELECT count FROM soundcharts_isrc_client_budget WHERE client_key=? AND hour=?',
                (key, hour),
            ).fetchone()
            count = int(row[0]) if row else 0
            if count >= _CLIENT_HOURLY_LIMIT:
                return False
            conn.execute(
                '''INSERT INTO soundcharts_isrc_client_budget(client_key,hour,count) VALUES(?,?,?)
                   ON CONFLICT(client_key,hour) DO UPDATE SET count=excluded.count''',
                (key, hour, count + 1),
            )
            if hour % 24 == 0:
                conn.execute('DELETE FROM soundcharts_isrc_client_budget WHERE hour < ?', (hour - 48,))
        return True
    except Exception as exc:
        print(f'[ISRC] rate-limit storage failed ({type(exc).__name__})')
        return False


def _credentials():
    """Load paired credentials, preferring server env over admin_config."""
    raw = (os.environ.get('YTMU_SOUNDCHARTS_CREDENTIALS_JSON') or '').strip()
    if raw:
        try:
            import json
            entries = json.loads(raw)
            if isinstance(entries, list):
                return _clean_credentials(entries)
        except (ValueError, TypeError, KeyError):
            print('[ISRC] Soundcharts credential list is invalid JSON')
            return []

    # Keep the older single-pair environment variables as an override too.
    app_id = (os.environ.get('YTMU_SOUNDCHARTS_APP_ID') or '').strip()
    api_key = (os.environ.get('YTMU_SOUNDCHARTS_API_KEY') or '').strip()
    if app_id or api_key:
        return [{'app_id': app_id, 'api_key': api_key}] if app_id and api_key else []

    # admin_config is gitignored runtime secret storage. Import lazily so this
    # module remains safe to import while app.py is still initializing.
    try:
        from .app import _admin_cfg
        entries = _admin_cfg.get('soundcharts_credentials', [])
    except Exception as exc:
        print(f'[ISRC] admin config read failed ({type(exc).__name__})')
        return []
    if isinstance(entries, str):
        try:
            import json
            entries = json.loads(entries)
        except (ValueError, TypeError):
            print('[ISRC] Soundcharts credentials in admin_config are invalid JSON')
            return []
    if not isinstance(entries, list):
        return []
    return _clean_credentials(entries)


def _clean_credentials(entries):
    """Keep only non-empty app/key pairs from an untrusted config value."""
    return [
        {'app_id': item['app_id'].strip(), 'api_key': item['api_key'].strip()}
        for item in entries
        if isinstance(item, dict)
        and isinstance(item.get('app_id'), str) and item['app_id'].strip()
        and isinstance(item.get('api_key'), str) and item['api_key'].strip()
    ]


def _credential_order(credentials):
    """Rotate the first credential used; return the rest as ordered fallbacks."""
    global _CREDENTIAL_CURSOR
    with _CREDENTIAL_LOCK:
        start = _CREDENTIAL_CURSOR % len(credentials)
        _CREDENTIAL_CURSOR = (_CREDENTIAL_CURSOR + 1) % len(credentials)
    return credentials[start:] + credentials[:start]


def lookup(video_id, client_id=None, title='', artist=''):
    """Return a Soundcharts ISRC, using shared persistent cache first."""
    video_id = (video_id or '').strip()
    if not _VIDEO_ID.fullmatch(video_id):
        record_diagnostic(video_id, title, artist, 'server', 'invalid video ID')
        return {'isrc': None, 'source': 'invalid'}

    cached = _read_cache(video_id)
    if cached:
        record_diagnostic(video_id, title, artist, 'server cache',
                          'cache hit' if cached.get('isrc') else 'cached miss', cached.get('isrc'))
        return cached

    # Coalesce simultaneous requests for the same uncached track in this worker.
    with _LOCK:
        event = _IN_FLIGHT.get(video_id)
        owner = event is None
        if owner:
            event = threading.Event()
            _IN_FLIGHT[video_id] = event
    if not owner:
        event.wait(7.0)
        result = _read_cache(video_id) or {'isrc': None, 'source': 'busy'}
        record_diagnostic(video_id, title, artist, result.get('source', 'server'),
                          'coalesced result' if result.get('isrc') else 'request still in flight', result.get('isrc'))
        return result

    try:
        record_diagnostic(video_id, title, artist, 'Soundcharts', 'lookup started')
        credentials = _credentials()
        if not credentials:
            record_diagnostic(video_id, title, artist, 'Soundcharts', 'not configured')
            return {'isrc': None, 'source': 'unconfigured'}
        if not _consume_client_budget(client_id):
            record_diagnostic(video_id, title, artist, 'Soundcharts', 'client rate limited')
            return {'isrc': None, 'source': 'rate_limited'}
        url = f'https://customer.api.soundcharts.com/api/v2.25/song/by-platform/youtube/{video_id}'
        response = None
        for credential in _credential_order(credentials):
            try:
                response = requests.get(
                    url,
                    headers={
                        'x-app-id': credential['app_id'],
                        'x-api-key': credential['api_key'],
                        'Accept': 'application/json',
                    },
                    timeout=(2.5, 4.0),
                )
            except requests.RequestException as exc:
                print(f'[ISRC] Soundcharts request failed ({type(exc).__name__})')
                _write_cache(video_id, None, _ERROR_TTL)
                record_diagnostic(video_id, title, artist, 'Soundcharts', f'request failed ({type(exc).__name__})')
                return {'isrc': None, 'source': 'error'}
            if response.status_code not in (401, 403, 429):
                break
            print(f'[ISRC] Soundcharts credential rejected or rate limited (HTTP {response.status_code}); rotating')

        if response is None:
            _write_cache(video_id, None, _ERROR_TTL)
            record_diagnostic(video_id, title, artist, 'Soundcharts', 'no provider response')
            return {'isrc': None, 'source': 'error'}
        if response.status_code == 404:
            _write_cache(video_id, None, _NEGATIVE_TTL)
            record_diagnostic(video_id, title, artist, 'Soundcharts', 'song not found')
            return {'isrc': None, 'source': 'not_found'}
        if response.status_code != 200:
            print(f'[ISRC] Soundcharts credentials unavailable (HTTP {response.status_code})')
            _write_cache(video_id, None, _ERROR_TTL)
            record_diagnostic(video_id, title, artist, 'Soundcharts', f'HTTP {response.status_code}')
            return {'isrc': None, 'source': 'error'}

        try:
            body = response.json()
        except ValueError:
            _write_cache(video_id, None, _ERROR_TTL)
            record_diagnostic(video_id, title, artist, 'Soundcharts', 'invalid JSON response')
            return {'isrc': None, 'source': 'error'}
        item = body.get('object') if isinstance(body, dict) else None
        isrc_obj = item.get('isrc') if isinstance(item, dict) else None
        isrc = isrc_obj.get('value') if isinstance(isrc_obj, dict) else None
        isrc = isrc.strip().upper() if isinstance(isrc, str) else None
        if isrc and not _ISRC.fullmatch(isrc):
            isrc = None
        _write_cache(video_id, isrc, _POSITIVE_TTL if isrc else _NEGATIVE_TTL)
        record_diagnostic(video_id, title, artist, 'Soundcharts', 'ISRC found' if isrc else 'no ISRC in response', isrc)
        return {'isrc': isrc, 'source': 'soundcharts' if isrc else 'no_isrc'}
    finally:
        with _LOCK:
            event = _IN_FLIGHT.pop(video_id, None)
            if event:
                event.set()
