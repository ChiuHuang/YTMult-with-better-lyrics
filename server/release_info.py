# GitHub release info for the tweak builds (build-N tags with the IPA).
# Shared by /api/update (download links) and /api/app/altstore (AltStore
# source). GitHub API is cached 10 min (60/hr unauth limit on shared IPs);
# every failure degrades to None so endpoints stay up.
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
    """Release body minus markdown image lines (they render as raw text in
    the in-app alert). Capped for the update dialog."""
    lines = [l for l in (body or '').splitlines()
             if not re.match(r'\s*!\[.*?\]\(.*?\)\s*$', l)]
    return '\n'.join(lines).strip()[:1500]


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
    """{tag, published_at, size, download_url} for the newest release with
    an .ipa asset, or None. Never raises."""
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
        }
        _CACHE.update(at=now, release=rel)
        return rel
    except Exception as e:
        print(f"[Release] Could not check GitHub releases: {e}")
        return _CACHE['release']
