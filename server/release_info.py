# GitHub release info for the tweak builds (build-N tags with the IPA).
# Shared by /api/update (download links) and /api/app/altstore (AltStore
# source). Two sources: polled GitHub API (cached 10 min, 60/hr unauth
# limit on shared IPs) or instant webhook push from Actions after release
# (POST /api/app/release-hook, secret-gated). Every failure degrades to
# the last known value so endpoints stay up.
import os
import re
import time as time_module

import requests

GH_REPO = os.environ.get('YTMU_GH_REPO', 'ChiuHuang/YTMult-with-better-lyrics')
# Stable AltStore icon (Asia file CDN). Release-asset icon.png is preferred
# when present; this is the fallback for older builds.
ALTSTORE_ICON = os.environ.get(
    'YTMU_ALTSTORE_ICON',
    'https://file.chiuhuang.dev/dl/pub/8ff6dc29-6cc0-4371-be7a-47f8390b4cf6/723b6e53-89dd-49af-b5a0-323d5da5a2a0')
# Worker prefix: prepended to the release asset URL for regions where
# github.com is slow (Cloudflare CDN). Trailing slash added automatically.
WORKER_PREFIX = os.environ.get(
    'YTMU_WORKER_PREFIX', 'https://proxy.chiuhuang.dev/')

_CACHE = {'at': 0.0, 'release': None}
_TTL = 600

def _clean_notes(body):
    """Release body readable in the plain-text in-app alert: drop markdown
    image lines and HTML tags/lines, unwrap [text](url) links. Capped."""
    out = []
    for l in (body or '').splitlines():
        if re.match(r'\s*!\[.*?\]\(.*?\)\s*$', l):
            continue
        l = re.sub(r'<[^>]+>', '', l)
        l = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'\1 (\2)', l)
        l = re.sub(r'[*_`#]+', '', l).strip()
        if l:
            out.append(l)
    return '\n'.join(out).strip()[:1500]

def worker_url(url):
    prefix = (WORKER_PREFIX or '').strip()
    if not prefix or not url:
        return url
    if not prefix.endswith('/'):
        prefix += '/'
    if url.startswith(prefix):
        return url
    return prefix + url

def latest_release():
    """Newest release with an .ipa asset, webhook push preferred, GitHub
    API fallback. Returns dict or None. Never raises."""
    now = time_module.time()
    if _CACHE['release'] and now - _CACHE['at'] < _TTL:
        return _CACHE['release']
    try:
        r = requests.get(
            f'https://api.github.com/repos/{GH_REPO}/releases/latest',
            headers={'Accept': 'application/vnd.github+json'}, timeout=8)
        r.raise_for_status()
        j = r.json()
        asset = None
        icon_asset = None
        for a in j.get('assets') or []:
            name = a.get('name') or ''
            if name.endswith('.ipa') and a.get('browser_download_url') and not asset:
                asset = a
            if name.lower() == 'icon.png' and a.get('browser_download_url'):
                icon_asset = a
        if not asset:
            return None

        rel = {
            'tag': j.get('tag_name') or '',
            'published_at': j.get('published_at') or '',
            'size': asset.get('size') or 0,
            'download_url': asset.get('browser_download_url'),
            'icon_url': (icon_asset or {}).get('browser_download_url'),
            'notes': _clean_notes(j.get('body') or ''),
            'asia_url': None, # Webhook will inject this!
        }
        _CACHE.update(at=now, release=rel)
        return rel
    except Exception as e:
        print(f"[Release] Could not check GitHub releases: {e}")
        return _CACHE['release']

def update_cache(payload=None):
    """Webhook entry: replace the cached release with Actions data.
    Needs {tag, download_url}; returns True when stored."""
    global _CACHE
    if payload and payload.get('tag') and payload.get('download_url'):
        _CACHE['release'] = {
            'tag': payload['tag'],
            'published_at': payload.get('published_at', ''),
            'size': payload.get('size', 0),
            'download_url': payload['download_url'],
            'icon_url': payload.get('icon_url'),
            'notes': _clean_notes(payload.get('notes', '')),
            'asia_url': payload.get('asia_url'),
        }
        _CACHE['at'] = time_module.time()
        return True
    _CACHE['at'] = 0.0
    return False


def hook_secret():
    """Shared webhook secret: env wins, else admin_config. None = unconfigured."""
    env = (os.environ.get('YTMU_HOOK_SECRET') or '').strip()
    if env:
        return env
    try:
        from .app import _admin_cfg
        v = (_admin_cfg.get('hook_secret') or '').strip()
        return v or None
    except Exception:
        return None
