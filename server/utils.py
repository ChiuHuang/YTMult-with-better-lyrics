# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
import re

# video_id and translate_to both end up embedded directly in cache filenames
# (e.g. cache/lyrics/{video_id}:{translate_to}.json), so anything containing
# '/', '\', or '..' must never reach that point -- otherwise a crafted value
# could write or read outside the cache directory entirely.
_SAFE_CACHE_COMPONENT_RE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')


def _safe_cache_component(value):
    if not isinstance(value, str) or not _SAFE_CACHE_COMPONENT_RE.match(value):
        return None
    return value
