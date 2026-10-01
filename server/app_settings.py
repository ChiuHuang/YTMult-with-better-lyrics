# App settings: remote config for the tweak, managed from the dashboard
# App tab. Lives in config/app_settings.json (gitignored, runtime-edited;
# see config/app_settings.example.json). Read by any device via public
# GET /api/app/settings -- open by design, values are non-secret.
#
# The dashboard used to render a free-form key/value bag, which made the ~20
# keys the device actually reads undiscoverable: only `upload_logs` had a
# server-side default, so every `ui.*` switch existed only in the tweak and
# an operator had to know the exact name to type it. _SCHEMA below is the
# one list both sides render from, and it is deliberately the ONLY place a
# setting is described.
import json
import os
import re
import threading

_PATH = 'config/app_settings.json'
_LOCK = threading.Lock()
_KEY_RE = re.compile(r'^[A-Za-z0-9_.-]{1,64}$')

_DEFAULTS = {
    # Gate for device log-upload calls (POST /log + DEBUG_ pings).
    'upload_logs': True,
}

# --------------------------------------------------------------------------
# Schema: key -> typed, described, grouped. `scope` is what the dashboard uses
# to decide whether a key is a deliberate operator switch:
#   'remote'   the device acts on it (a real switch)
#   'advanced' free-form escape hatch, rendered under a collapsed heading
# Semantics for every 'remote' key: the server can only turn it OFF. The
# device ANDs it with the user's local pref, so a remote key can never
# enable something the user disabled, and the default is fail-open.
# --------------------------------------------------------------------------
_U = 'ui.'


def _ui(key):
    return _U + key


_SCHEMA = [
    # ---- group: server ----
    {
        'key': 'ui.remote_control',
        'type': 'bool',
        'default': True,
        'group': 'server',
        'scope': 'remote',
        'label': 'Remote feature control',
        'desc': ('Master switch for the whole feature. Off means the server '
                 'stops being able to disable anything on devices; the user '
                 'still controls their own toggles.'),
    },
    {
        'key': 'ui.liquid_glass',
        'type': 'bool',
        'default': True,
        'group': 'server',
        'scope': 'remote',
        'label': 'Liquid Glass kill switch',
        'desc': ('Off disables every Liquid Glass surface on every device at '
                 'once. Individual switches below are finer grained.'),
    },
    {
        'key': 'ui.tweak',
        'type': 'bool',
        'default': True,
        'group': 'server',
        'scope': 'remote',
        'label': 'Whole glass stack kill switch',
        'desc': ('Off turns off the material system itself -- the same switch '
                 'as "YTMusicUltimate" off in the tweak settings -- so both '
                 'Liquid Glass generations and every surface go with it. '
                 'Stricter than the switch above, which only turns off the V2 '
                 'surfaces. This is the action the per-build kill switch uses '
                 'when you target a build as broken outright.'),
    },
    # ---- group: fetch (server-side fetch behaviour) ----
    # Server-only keys: no device_key, so they are absent from the device's
    # YTMUAppSettingBool lookup entirely. Read by db_migrate.py and
    # pipeline._wbw_retry_cubey on the server.
    {
        'key': 'db.auto_sweep',
        'type': 'bool',
        'default': True,
        'group': 'database',
        'scope': 'server',
        'label': 'Sweep the database on startup',
        'desc': ('When the server starts and finds entries written by an older '
                 'parser or an older record format, replay the offline fixes '
                 'over them and re-stamp. No network. Songs whose text needs a '
                 'real refetch are counted and left for the dashboard.'),
    },
    {
        'key': 'db.keep_all_providers',
        'type': 'bool',
        'default': True,
        'group': 'database',
        'scope': 'server',
        'label': 'Keep every provider in the snapshots',
        'desc': ('Store each provider\'s lyrics for a song, not just the ones '
                 'that beat the current tier, so the device provider switcher '
                 'can offer a plain provider as a last fallback. Off prunes '
                 'plain entries whenever a line-or-better one exists.'),
    },
    {
        'key': 'fetch.wbw_retry_cubey',
        'type': 'bool',
        'default': True,
        'group': 'fetch',
        'scope': 'server',
        'label': 'Second Cubey pass when not word-by-word',
        'desc': ('If a fetch ends without word-level timing, ask Cubey once '
                 'more -- two tries per song, never more. The first pass takes '
                 'one merged answer and can hide a word-timed source that lost '
                 'the merge, so the second pass asks for the inner providers '
                 'separately, on a rotated token, after a short delay. Covers '
                 'every Cubey caller: the full fetch, the SSE race and the '
                 'background re-race. Costs one extra request per '
                 'non-word-by-word song.'),
    },
    {
        'key': 'fetch.wbw_retry_delay_s',
        # float, not int: the default is 0.8s, and an int-typed key rounded it
        # to 1s -- silently making every second pass half a second later than
        # the constant it replaced.
        'type': 'float',
        'default': 0.8,
        'min': 0,
        'max': 30,
        'group': 'fetch',
        'scope': 'server',
        'label': 'Delay before that second pass (seconds)',
        'desc': ('The two attempts are deliberately not in the same millisecond: '
                 'a repeat of the same JWT in the same instant is the same '
                 'request, so a 429 or a stream timeout just happens twice. '
                 'Raise it when the second pass keeps landing on rate limits, '
                 'lower it when you would rather spend the quota sooner. 0 '
                 'means no wait at all (the retry is still a real second call).'),
    },
    # ---- group: bulk (defaults for a NEW bulk job) ----
    # These are DEFAULTS, not a cap: the bulk panel can still change every one
    # of them while a job runs, and whatever it was last set to is what the next
    # Start sends. They exist so a job started by anything other than the panel
    # (the stale-refetch button, a script) uses the operator's chosen numbers.
    {
        'key': 'bulk.workers',
        'type': 'int',
        'default': 8,
        'min': 1,
        'max': 32,
        'group': 'bulk',
        'scope': 'server',
        'label': 'Fetch threads',
        'desc': 'Network fetch threads per bulk job. The panel can raise or lower this mid-job.',
    },
    {
        'key': 'bulk.cpu_workers',
        'type': 'int',
        'default': 2,
        'min': 1,
        'max': 64,
        'group': 'bulk',
        'scope': 'server',
        'label': 'CPU workers',
        'desc': ('Worker processes for the normalize+score step. Capped by the '
                 'real core count. Pure CPU work, so raising it past the cores '
                 'buys nothing.'),
    },
    {
        'key': 'bulk.tq_workers',
        'type': 'int',
        'default': 2,
        'min': 1,
        'max': 16,
        'group': 'bulk',
        'scope': 'server',
        'label': 'Translate workers',
        'desc': ('Threads translating in the background while the fetch threads '
                 'keep working. Raise it when the job spends its last minutes '
                 'waiting on translations; watch for rate limits before going '
                 'high.'),
    },
    {
        'key': 'bulk.batch',
        'type': 'int',
        'default': 25,
        'min': 1,
        'max': 500,
        'group': 'bulk',
        'scope': 'server',
        'label': 'Songs per batch',
        'desc': ('How many songs are dispatched before the job reports a batch '
                 'and re-reads its knobs. Smaller batches show progress sooner '
                 'and make Stop more responsive; bigger batches spend less time '
                 'between boundaries.'),
    },
    {
        'key': 'upload_logs',
        'type': 'bool',
        'default': True,
        'group': 'diagnostics',
        'scope': 'remote',
        'label': 'Device log uploads',
        'desc': ('Master switch for every device->server debug upload: /log '
                 'posts, DEBUG_ pings and screenshot dumps. The Debug page on '
                 'the device shows this as "off".'),
    },
]

# The per-feature Liquid Glass keys are all the same shape, so they are
# generated rather than typed out 18 times -- and a key that drifts out of
# existence can only ever be missing in one place.
_UI_FEATURES = [
    ('liquidGlassV2Enabled', 'Mini player', 'Glass mini player surface.'),
    ('fullPlayerV2Enabled', 'Full player', 'Artwork card and transport glass.'),
    ('lyricsV2Enabled', 'Lyrics', 'Blurred-cover background behind the lyrics.'),
    ('queueV2Enabled', 'Queue', 'Glass Up Next list and queue header.'),
    ('sheetsV2Enabled', 'Sheets', 'Rounded glass action and bottom sheets.'),
    ('homeV2Enabled', 'Home', 'Rounded artwork and transparent shelves.'),
    ('pivotBarV2Enabled', 'Bottom navigation', 'Floating material navigation bar.'),
    ('searchV2Enabled', 'Search', 'Rounded search field and result rows.'),
    ('libraryV2Enabled', 'Library', 'Transparent Library pages.'),
    ('entityPagesV2Enabled', 'Album, Artist, Playlist', 'Shared glass shell.'),
    ('albumV2Enabled', 'Album', 'Album page shell and artwork.'),
    ('artistV2Enabled', 'Artist', 'Artist page shell and artwork.'),
    ('playlistV2Enabled', 'Playlist', 'Playlist page shell and reorder row.'),
    ('downloadsV2Enabled', 'Downloads', 'Offline and download surfaces.'),
    ('statusOverlaysV2Enabled', 'Status overlays', 'Glass toasts, alerts, progress.'),
    ('globalStatesV2Enabled', 'Global states', 'Glass loading, empty, error states.'),
    ('wholeAppSongThemeEnabled', 'Whole-app song theme', 'Artwork colours across the app.'),
    ('playerSongThemeEnabled', 'Player song theme', 'Artwork colours behind the full player.'),
]
for _k, _label, _desc in _UI_FEATURES:
    _SCHEMA.append({
        'key': _ui(_k),
        'type': 'bool',
        'default': True,
        'group': 'ui',
        'scope': 'remote',
        'label': _label,
        'desc': _desc,
        'device_key': _k,
    })

_SCHEMA_BY_KEY = {e['key']: e for e in _SCHEMA}


def _load_file():
    try:
        with open(_PATH, 'r', encoding='utf-8') as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _save_file(d):
    os.makedirs(os.path.dirname(_PATH) or '.', exist_ok=True)
    tmp = _PATH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    os.replace(tmp, _PATH)


def _merged():
    d = dict(_DEFAULTS)
    d.update(_load_file())
    return d


def get_all():
    """Full settings dict (defaults + overrides). Never raises."""
    try:
        with _LOCK:
            return _merged()
    except Exception:
        return dict(_DEFAULTS)


def flag(key, default=True):
    """One schema bool for a caller on a request path.

    get_all() already merges the schema default in, so `default` only matters
    for a key that is not in _SCHEMA at all -- which is why it is spelled out
    at the call site: a typo must not read as 'off'. Fails OPEN, because every
    caller here is a feature that can only improve a result (see
    pipeline._wbw_retry_cubey)."""
    try:
        return bool(get_all().get(key, default))
    except Exception:
        return default


def number(key, default, lo=None, hi=None):
    """One schema number for a caller on a request path.

    The type decides the return: an `int` key comes back int, a `float` key
    comes back float with three decimals. That is not fussiness -- the wbw retry
    delay defaults to 0.8s, and rounding it to 1s because the key happened to be
    declared as an integer is exactly the kind of change nobody notices until
    they wonder why every second pass is slower.

    The schema's own min/max win over the caller's, because the schema is what
    the dashboard renders bounds from -- a control that promises 1..32 and then
    stores 99 is worse than no control at all. Clamps rather than refuses, so a
    stale setting from an older schema cannot wedge a caller, and a missing key
    (a typo, or a setting file written before this key existed) falls back to
    the caller's default rather than to 0."""
    spec = _SCHEMA_BY_KEY.get(key) or {}
    lo = spec.get('min', lo)
    hi = spec.get('max', hi)
    is_float = spec.get('type') == 'float'
    try:
        val = get_all().get(key, default)
        if isinstance(val, bool):
            val = default
        val = float(val)
        val = round(val, 3) if is_float else float(round(val))
    except Exception:
        val = float(default) if not is_float else float(default)
    if lo is not None:
        val = max(float(lo), val)
    if hi is not None:
        val = min(float(hi), val)
    return val if is_float else int(val)


def _check_key(key):
    # Not `key or ''`: a non-string key ({"key": 123}) has no .strip(), and the
    # resulting AttributeError escaped the routes' (ValueError, TypeError)
    # handler and landed in the 500 crash handler instead of a 400.
    if not isinstance(key, str):
        raise ValueError('bad key (a-z 0-9 _ . - , max 64)')
    key = key.strip()
    if not _KEY_RE.match(key):
        raise ValueError('bad key (a-z 0-9 _ . - , max 64)')
    return key


def _check_value(value, key=None):
    if not isinstance(value, (str, bool, int, float)) or isinstance(value, list):
        raise ValueError('value must be string/number/boolean')
    if isinstance(value, str) and len(value) > 4000:
        raise ValueError('string too long (max 4000)')
    # A known key knows its own type, so a schema key is checked instead of
    # trusted: the device reads these through YTMUAppSettingBool, where the
    # string "false" happens to work but the string "off" silently reads as
    # the default (fail-open), i.e. a typo would look like "no change".
    spec = _SCHEMA_BY_KEY.get(key)
    if spec and spec.get('type') == 'bool':
        if isinstance(value, bool):
            return value
        if isinstance(value, str) and value.strip().lower() in ('true', 'false', '1', '0'):
            return value.strip().lower() in ('true', '1')
        raise ValueError(f"{key} is a boolean: send true or false")
    if spec and spec.get('type') in ('int', 'float'):
        # bool is an int subclass, so `True` would silently become 1 and look
        # like a real value; a numeric string is accepted because the dashboard
        # sends what the number field held.
        if isinstance(value, bool):
            raise ValueError(f"{key} is a number, not a boolean")
        if isinstance(value, str):
            value = value.strip()
            if not value:
                raise ValueError(f"{key} needs a number")
        try:
            num = float(value)
        except Exception:
            raise ValueError(f"{key} needs a number")
        if num != num or num in (float('inf'), float('-inf')):
            raise ValueError(f"{key} needs a finite number")
        num = round(num) if spec['type'] == 'int' else round(num, 3)
        lo, hi = spec.get('min'), spec.get('max')
        if lo is not None and num < lo:
            num = lo
        if hi is not None and num > hi:
            num = hi
        return num
    return value


def set_one(key, value):
    key = _check_key(key)
    value = _check_value(value, key)
    with _LOCK:
        d = _load_file()
        d[key] = value
        _save_file(d)
    return {key: value}


def set_many(values):
    """Bulk set, all-or-nothing: validate everything first so a typo in the
    last key cannot leave the first five written."""
    if not isinstance(values, dict) or not values:
        raise ValueError('no values')
    checked = [(_check_key(k), _check_value(v, k)) for k, v in values.items()]
    with _LOCK:
        d = _load_file()
        for k, v in checked:
            d[k] = v
        _save_file(d)
    return dict(checked)


def delete_one(key):
    key = _check_key(key)
    with _LOCK:
        d = _load_file()
        removed = d.pop(key, None) is not None
        _save_file(d)
    return removed


def reset_defaults():
    with _LOCK:
        _save_file({})
    return get_all()


# --------------------------------------------------------------------------
# Schema-aware read for the dashboard
# --------------------------------------------------------------------------
GROUPS = [
    ('server', 'Server'),
    ('ui', 'Liquid Glass surfaces'),
    ('fetch', 'Lyrics fetching'),
    ('bulk', 'Bulk refetch defaults'),
    ('database', 'Database'),
    ('diagnostics', 'Diagnostics'),
]

# Which groups belong to which dashboard page. The App page is remote config
# for devices; the Settings page is this server's own behaviour. The split used
# to be absent, so a server-only switch (the wbw second pass) sat inside the
# page framed as "remote config for the tweak", where it read like a device
# setting it was never going to reach.
GROUPS_REMOTE = ('server', 'ui', 'diagnostics')
GROUPS_SERVER = ('fetch', 'bulk', 'database')


def get_overrides():
    """Just the on-disk overrides. The merged map cannot tell an operator
    whether a value they see is their own setting or the default, which is
    why the plain GET is not enough to render the UI."""
    with _LOCK:
        return _load_file()


def describe():
    """Everything the dashboard needs to render typed controls, in one
    payload: the schema, the current effective value per key, whether that
    value is an override, and any keys that exist but are not in the schema.
    Never raises."""
    try:
        with _LOCK:
            merged = _merged()
            overrides = _load_file()
    except Exception:
        merged, overrides = dict(_DEFAULTS), {}
    entries = []
    for e in _SCHEMA:
        row = dict(e)
        row['value'] = merged.get(e['key'], e['default'])
        row['is_override'] = e['key'] in overrides
        entries.append(row)
    known = {e['key'] for e in _SCHEMA}
    extra = [{'key': k, 'value': v, 'scope': 'advanced', 'is_override': True}
             for k, v in sorted(overrides.items()) if k not in known]
    return {'schema': entries, 'groups': GROUPS, 'extra': extra,
            'groups_remote': list(GROUPS_REMOTE),
            'groups_server': list(GROUPS_SERVER),
            'overrides': sorted(overrides)}
