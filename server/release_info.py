# GitHub release info for the tweak builds (build-N tags with the IPA).
# Shared by /api/update (download links) and /api/app/altstore (AltStore
# source). Two sources: polled GitHub API (cached 10 min, 60/hr unauth
# limit on shared IPs) or instant webhook push from Actions after release
# (POST /api/app/release-hook, secret-gated). Every failure degrades to
# the last known value so endpoints stay up.
import json
import os
import re
import time as time_module

import requests

from .paths import MIRROR_FILE

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

# The Asia file-CDN URL of a build is not derivable: the workflow uploads the
# IPA, gets an opaque /dl/pub/<uuid>/<hash> path back and hands it to us. It
# used to live only in the webhook payload, so the first restart sent every
# AltStore user the Cloudflare link and /api/update reported asia_url null.
# Two ways to get it back, both cheap:
#   1. the release body already carries it ("- **Asia Mirror** (<url>)"), and
#      that link belongs to exactly the release we just fetched, so it is the
#      one source that cannot go stale;
#   2. the webhook persists it to database/release_mirror.json, which also
#      covers a build whose body format ever changes.
# A stored mirror is only honoured for the tag it was stored with -- handing
# last build's URL to today's build is a 404, not a mirror.
_ASIA_URL_RE = re.compile(r'https://file\.chiuhuang\.dev/dl/[^\s)>\]]+')


def _asia_from_body(body):
    """Asia mirror URL out of a raw release body, or ''."""
    m = _ASIA_URL_RE.search(body or '')
    return m.group(0) if m else ''


def _read_mirror():
    try:
        with open(MIRROR_FILE, 'r', encoding='utf-8') as f:
            d = json.load(f)
        if isinstance(d, dict):
            return d
    except Exception:
        pass
    return {}


def _write_mirror(tag, url):
    """Durable copy of the webhook's Asia URL. Never raises."""
    try:
        os.makedirs(os.path.dirname(MIRROR_FILE) or '.', exist_ok=True)
        tmp = MIRROR_FILE + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump({'tag': tag or '', 'asia_url': url}, f)
        os.replace(tmp, MIRROR_FILE)
    except Exception as e:
        print(f"[Release] [WARN] Asia mirror not persisted: {e}")


def asia_url_for(tag, body=''):
    """Asia file-CDN URL for `tag`, or None. Release body first, then the
    persisted webhook value for the same tag."""
    url = _asia_from_body(body)
    if url:
        return url
    m = _read_mirror()
    if tag and m.get('tag') == tag and m.get('asia_url'):
        return m['asia_url']
    return None

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

        tag = j.get('tag_name') or ''
        rel = {
            'tag': tag,
            'published_at': j.get('published_at') or '',
            'size': asset.get('size') or 0,
            'download_url': asset.get('browser_download_url'),
            'icon_url': (icon_asset or {}).get('browser_download_url'),
            'notes': _clean_notes(j.get('body') or ''),
            # From the body, not the webhook: this is the path that runs on
            # every restart, and it is the only one that is on disk forever.
            'asia_url': asia_url_for(tag, j.get('body') or ''),
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
        # The Asia URL is the one field the GitHub API cannot give back, so it
        # is the one field worth putting on disk. Without this the mirror is
        # gone on the next restart and /api/update answers asia_url null.
        asia = (payload.get('asia_url') or '').strip()
        if asia:
            _write_mirror(payload['tag'], asia)
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
