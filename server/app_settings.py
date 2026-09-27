# App settings: remote config for the tweak, managed from the dashboard
# App tab. Lives in config/app_settings.json (gitignored, runtime-edited;
# see config/app_settings.example.json). Read by any device via public
# GET /api/app/settings -- open by design, values are non-secret.
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


def _check_key(key):
    key = (key or '').strip()
    if not _KEY_RE.match(key):
        raise ValueError('bad key (a-z 0-9 _ . - , max 64)')
    return key


def _check_value(value):
    if not isinstance(value, (str, bool, int, float)) or isinstance(value, list):
        raise ValueError('value must be string/number/boolean')
    if isinstance(value, str) and len(value) > 4000:
        raise ValueError('string too long (max 4000)')
    return value


def set_one(key, value):
    key = _check_key(key)
    value = _check_value(value)
    with _LOCK:
        d = _load_file()
        d[key] = value
        _save_file(d)
    return {key: value}


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
