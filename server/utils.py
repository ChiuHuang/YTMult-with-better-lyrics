# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
import re
import hashlib
import struct


# video_id and translate_to both end up embedded directly in cache filenames
# (e.g. cache/lyrics/{video_id}:{translate_to}.json), so anything containing
# '/', '\', or '..' must never reach that point -- otherwise a crafted value
# could write or read outside the cache directory entirely.
_SAFE_CACHE_COMPONENT_RE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')


def _safe_cache_component(value):
    if not isinstance(value, str) or not _SAFE_CACHE_COMPONENT_RE.match(value):
        return None
    return value


def _canonical_lyrics_bytes(lyrics):
    """Serialize lyrics to a canonical byte representation for stable hashing.
    Mutates nothing; returns bytes suitable for SHA-256.
    Order: lines sorted by startTimeMs; within each line: fields in fixed order.
    Uses big-endian integers for cross-platform determinism.
    """
    if not lyrics:
        return b''
    # Sort lines by start time (ms)
    def line_start_ms(l):
        return int(l.get('startTimeMs') or l.get('time', 0) * 1000)
    sorted_lines = sorted(lyrics, key=line_start_ms)
    buf = bytearray()
    for line in sorted_lines:
        start = int(line.get('startTimeMs') or line.get('time', 0) * 1000)
        dur = int(line.get('durationMs') or line.get('duration', 0) * 1000)
        text = (line.get('text') or '').encode('utf-8')
        trans = (line.get('translated') or '').encode('utf-8')
        ws = 1 if line.get('wordSynced') else 0
        parts = line.get('parts') or []
        buf += struct.pack('>iii', start, dur, len(text))
        buf += text
        buf += struct.pack('>i', len(trans))
        buf += trans
        buf += struct.pack('>bi', ws, len(parts))
        for p in parts:
            words = (p.get('words') or '').encode('utf-8')
            p_start = int(p.get('startTimeMs', 0))
            p_dur = int(p.get('durationMs', 0))
            buf += struct.pack('>iii', len(words), p_start, p_dur)
            buf += words
    return bytes(buf)


def lyrics_content_hash(lyrics):
    """Return SHA-256 hex digest of the canonical lyrics representation."""
    data = _canonical_lyrics_bytes(lyrics)
    return hashlib.sha256(data).hexdigest()
