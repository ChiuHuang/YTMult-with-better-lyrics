"""Raw provider lyrics, archived as one LZMA file per song.

Every provider that hands us text (TTML, LRC, QRC, plain) saves the original
text here BEFORE parsing. The parsed cache can then be rebuilt offline when a
parser changes, and a full-provider probe can be answered from disk instead
of re-fetching all providers for the same song.

Format: database/raw/<video_id>.lzma containing UTF-8 JSON:

    {"v": 1, "video_id": "...", "sources": {
        "Unison:ttml": {"provider": "Unison", "format": "ttml",
                        "text": "...", "hash": "sha256...", "ts": "iso...",
                        "meta": {...}},
        ...
    }}

Writes are atomic (tmp + os.replace). A source is only rewritten when its
text changes, so re-fetching the same answer does not churn the archive.
"""
import hashlib
import json
import lzma
import os
import threading
from datetime import datetime

from .paths import RAW_DIR

_ARCHIVE_VERSION = 1
_write_lock = threading.Lock()


def _path(video_id):
    return os.path.join(RAW_DIR, f"{video_id}.lzma")


def _load(video_id):
    path = _path(video_id)
    if not os.path.exists(path):
        return {"v": _ARCHIVE_VERSION, "video_id": video_id, "sources": {}}
    try:
        with lzma.open(path, "rt", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or not isinstance(data.get("sources"), dict):
            raise ValueError("bad raw archive shape")
        return data
    except Exception as e:
        print(f"[RAW] load failed {video_id}: {e}")
        return {"v": _ARCHIVE_VERSION, "video_id": video_id, "sources": {}}


def save(video_id, provider, fmt, text, meta=None):
    """Archive a raw source. Returns True when anything was written."""
    if not video_id or not provider or not fmt or not isinstance(text, str) or not text.strip():
        return False
    key = f"{provider}:{fmt}"
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    with _write_lock:
        doc = _load(video_id)
        old = doc["sources"].get(key)
        if old and old.get("hash") == digest:
            return False
        doc["sources"][key] = {
            "provider": provider,
            "format": fmt,
            "text": text,
            "hash": digest,
            "ts": datetime.now().isoformat(),
            "meta": meta or {},
        }
        doc["v"] = _ARCHIVE_VERSION
        doc["video_id"] = video_id
        try:
            os.makedirs(RAW_DIR, exist_ok=True)
            tmp = _path(video_id) + ".tmp"
            with lzma.open(tmp, "wt", encoding="utf-8", preset=6) as f:
                json.dump(doc, f, ensure_ascii=False)
            os.replace(tmp, _path(video_id))
            print(f"[RAW] saved {key} for {video_id} ({len(text)} chars)")
            return True
        except Exception as e:
            print(f"[RAW] save failed {video_id}/{key}: {e}")
            return False


def sources(video_id):
    """Return the list of raw source entries for a song, newest first."""
    doc = _load(video_id)
    entries = list(doc["sources"].values())
    entries.sort(key=lambda e: e.get("ts", ""), reverse=True)
    return entries


def archive_size(video_id):
    path = _path(video_id)
    return os.path.getsize(path) if os.path.exists(path) else 0


def parse_entry(entry, duration=0):
    """Reparse one raw entry with the CURRENT parsers.

    Returns a list of lyric lines, or None when the format is unknown or the
    parser refuses the text. Keeping this dispatch in one place is the whole
    point of the archive: a parser fix changes this function and every stored
    source benefits.
    """
    fmt = (entry.get("format") or "").lower()
    text = entry.get("text") or ""
    if not text:
        return None
    try:
        if fmt == "ttml":
            from .parsers_ttml import parse_ttml_basic
            return parse_ttml_basic(text, duration)
        if fmt == "lrc":
            from .parsers_lrc import parse_lrc
            return parse_lrc(text, duration)
        if fmt == "plain":
            from .parsers_lrc import parse_plain
            return parse_plain(text)
        if fmt == "qrc":
            from .parsers_qrc import parse_qrc_structured
            return parse_qrc_structured(text)
        if fmt == "srt":
            from .parsers_srt import parse_synced_text
            return parse_synced_text(text, duration)
    except Exception as e:
        print(f"[RAW] parse failed {entry.get('provider')}/{fmt}: {e}")
    return None


def candidates(video_id, duration=0):
    """Reparse every stored source into race-compatible candidates.

    Each candidate: {lyrics, source, format, synced, wordSynced, raw}.
    `raw` is kept attached so a caller can reparse it again without touching
    the archive file.
    """
    out = []
    for entry in sources(video_id):
        lyrics = parse_entry(entry, duration)
        if not lyrics:
            continue
        wbw = any(l.get("wordSynced") for l in lyrics)
        synced = bool(wbw) or any(l.get("startTimeMs") is not None for l in lyrics)
        out.append({
            "lyrics": lyrics,
            "source": entry.get("provider", ""),
            "format": entry.get("format", ""),
            "synced": synced,
            "wordSynced": wbw,
            "raw": entry.get("text", ""),
            "ts": entry.get("ts", ""),
        })
    return out


def rebuild_cache(video_id, lang='zh-TW', duration=0):
    """Reparse every archived source with the CURRENT parsers and write the
    best result to the lyrics cache. This is how a parser fix is applied to
    an existing database without re-fetching any provider."""
    try:
        from .cache import set_cached
        from .race import _lyrics_score
    except Exception as e:
        print(f"[RAW] rebuild import failed: {e}")
        return None
    cands = candidates(video_id, duration)
    if not cands:
        return None
    best = max(cands, key=lambda c: _lyrics_score(c))
    payload = {
        'lyrics': best['lyrics'],
        'source': best['source'],
        'synced': best['synced'],
        'wordSynced': best['wordSynced'],
        'song': '', 'artist': '',
        'duration': duration,
        'from_raw': True,
    }
    try:
        from .providers_yt import get_song_info_cached
        info = get_song_info_cached(video_id)
        if info:
            payload['song'] = info.get('title', '')
            payload['artist'] = info.get('artist', '')
            payload['duration'] = info.get('duration', 0) or duration
    except Exception:
        pass
    set_cached(f"{video_id}:{lang}", payload)
    print(f"[RAW] rebuilt {video_id} from {len(cands)} archived source(s): "
          f"{best['source']}/{best['format']}")
    return payload
