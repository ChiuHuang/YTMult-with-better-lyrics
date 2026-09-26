# AI provider config: keys live in a gitignored JSON file (or env vars),
# never in the repo. Any provider can be added from anywhere: edit
# config/ai_providers.json, use the dashboard AI panel, or set env vars.
#
# File schema:
# {
#   "cohere_keys": ["<cohere-trial-key>", ...],
#   "chat": [
#     {"name": "orcarouter",
#      "base_url": "https://api.orcarouter.ai/v1",
#      "api_key": "<key-here>",
#      "model": "orcarouter/free",
#      "headers": {"X-Title": "optional"},
#      "use_for": ["translate", "retitle"]}
#   ]
# }
# Env (merged with the file, same priority):
#   YTMU_COHERE_KEYS="k1,k2"  ORCAROUTER_API_KEY="<key-here>"
#   YTMU_ORCA_BASE=...  YTMU_ORCA_MODEL=...
import json
import os
import re
import threading

_PATH = 'config/ai_providers.json'
_LOCK = threading.Lock()


def _env_list(name):
    out = []
    for part in re.split(r'[,\s]+', os.environ.get(name, '')):
        part = (part or '').strip().strip('"\'')
        if part and part not in out:
            out.append(part)
    return out


def _blank():
    return {'cohere_keys': [], 'chat': []}


def _load_file():
    try:
        with open(_PATH, 'r', encoding='utf-8') as f:
            d = json.load(f)
        if not isinstance(d, dict):
            return _blank()
        d.setdefault('cohere_keys', [])
        d.setdefault('chat', [])
        if not isinstance(d['cohere_keys'], list):
            d['cohere_keys'] = []
        if not isinstance(d['chat'], list):
            d['chat'] = []
        return d
    except Exception:
        return _blank()


def _save_file(d):
    os.makedirs(os.path.dirname(_PATH) or '.', exist_ok=True)
    tmp = _PATH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    os.replace(tmp, _PATH)


def _env_chat_provider():
    key = os.environ.get('ORCAROUTER_API_KEY', '').strip()
    if not key:
        return None
    return {
        'name': 'orcarouter',
        'base_url': os.environ.get(
            'YTMU_ORCA_BASE', 'https://api.orcarouter.ai/v1').rstrip('/'),
        'api_key': key,
        'model': os.environ.get('YTMU_ORCA_MODEL', 'orcarouter/free'),
        'headers': {},
        'use_for': ['translate', 'retitle'],
    }


def load_cohere_keys():
    """All Cohere keys: file + YTMU_COHERE_KEYS env, deduped, non-empty."""
    with _LOCK:
        d = _load_file()
        keys = [k for k in d.get('cohere_keys', [])
                if isinstance(k, str) and k.strip()]
    for k in _env_list('YTMU_COHERE_KEYS'):
        if k not in keys:
            keys.append(k)
    return keys


def load_chat_providers(use=None):
    """OpenAI-compatible chat providers: file + ORCAROUTER_API_KEY env.
    use filters by 'translate'/'retitle'. Never raises."""
    with _LOCK:
        d = _load_file()
        providers = [dict(p) for p in d.get('chat', [])
                     if isinstance(p, dict) and p.get('api_key')]
    env_p = _env_chat_provider()
    if env_p and not any(p.get('name') == env_p['name'] for p in providers):
        providers.append(env_p)
    if use:
        providers = [p for p in providers
                     if use in (p.get('use_for') or ['translate', 'retitle'])]
    return providers


def mask_key(k):
    k = k or ''
    if len(k) <= 8:
        return '***'
    return k[:3] + '...' + k[-4:]


def list_masked():
    """Dashboard-safe view: keys masked. Never raises."""
    try:
        keys = load_cohere_keys()
        chats = load_chat_providers()
    except Exception:
        return {'cohere': [], 'chat': []}
    return {
        'cohere': [{'masked': mask_key(k), 'len': len(k)} for k in keys],
        'chat': [{'name': p.get('name', ''), 'model': p.get('model', ''),
                  'base_url': p.get('base_url', ''),
                  'use_for': p.get('use_for') or [],
                  'masked': mask_key(p.get('api_key', '')),
                  'from_env': p.get('name') == 'orcarouter'
                  and bool(os.environ.get('ORCAROUTER_API_KEY'))}
                 for p in chats],
    }


def add_cohere_key(key):
    key = (key or '').strip()
    if not key:
        raise ValueError('empty key')
    with _LOCK:
        d = _load_file()
        if key in d['cohere_keys']:
            return False
        d['cohere_keys'].append(key)
        _save_file(d)
    return True


def remove_cohere_key(masked_or_key):
    """Remove by full key or masked form. Returns removals."""
    with _LOCK:
        d = _load_file()
        before = len(d['cohere_keys'])
        d['cohere_keys'] = [
            k for k in d['cohere_keys']
            if k != masked_or_key and mask_key(k) != masked_or_key]
        _save_file(d)
        return before - len(d['cohere_keys'])


def add_chat_provider(p):
    """Add {name, api_key, base_url?, model?, headers?, use_for?}."""
    if not isinstance(p, dict):
        raise ValueError('provider must be an object')
    name = (p.get('name') or '').strip()
    api_key = (p.get('api_key') or '').strip()
    if not name or not api_key:
        raise ValueError('name and api_key required')
    entry = {
        'name': name,
        'base_url': (p.get('base_url') or '').strip().rstrip('/'),
        'api_key': api_key,
        'model': (p.get('model') or '').strip(),
        'headers': p.get('headers') if isinstance(p.get('headers'), dict)
        else {},
        'use_for': [u for u in (p.get('use_for') or ['translate', 'retitle'])
                    if u in ('translate', 'retitle')] or ['translate', 'retitle'],
    }
    with _LOCK:
        d = _load_file()
        d['chat'] = [q for q in d['chat'] if q.get('name') != name]
        d['chat'].append(entry)
        _save_file(d)
    return entry['name']


def remove_chat_provider(name):
    name = (name or '').strip()
    with _LOCK:
        d = _load_file()
        before = len(d['chat'])
        d['chat'] = [q for q in d['chat'] if q.get('name') != name]
        _save_file(d)
        return before - len(d['chat'])
