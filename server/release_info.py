# GitHub release info for the tweak builds (build-N tags with the IPA).
# Shared by /api/update (download links) and /api/app/altstore (AltStore
# source). GitHub API is cached 10 min (60/hr unauth limit on shared IPs);
# every failure degrades to None so endpoints stay up.
import os
import time as time_module

import requests

GH_REPO = os.environ.get('YTMU_GH_REPO', 'ChiuHuang/YTMult-with-better-lyrics')
# Worker prefix: prepended to the release asset URL for regions where
# github.com is slow. Trailing slash added automatically.
WORKER_PREFIX = os.environ.get(
    'YTMU_WORKER_PREFIX', 'http://workersproxy.codefoxy.workers.dev/')

_CACHE = {'at': 0.0, 'release': None}
_TTL = 600


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
        for a in j.get('assets') or []:
            if (a.get('name') or '').endswith('.ipa') and a.get('browser_download_url'):
                asset = a
                break
        if not asset:
            return None
        rel = {
            'tag': j.get('tag_name') or '',
            'published_at': j.get('published_at') or '',
            'size': asset.get('size') or 0,
            'download_url': asset.get('browser_download_url'),
        }
        _CACHE.update(at=now, release=rel)
        return rel
    except Exception as e:
        print(f"[Release] Could not check GitHub releases: {e}")
        return _CACHE['release']
