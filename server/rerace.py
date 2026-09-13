# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Background re-race: when the fast/regular race only landed line-sync (or
# plain) lyrics -- typically Musixmatch via LRCLIB -- the word-by-word
# sources (Portato QRC on boidu, bLyrics TTML, BiniLyrics syllable TTML,
# and Cubey golyrics) may still have real per-word timing for that song.
# A quiet background loop re-races those sources and, when a strictly better
# tier turns up, upgrades BOTH cache keys (the full key and the shared
# :fast key) so the next client request -- fast or full -- serves the wbw
# result. Requests egress through idle nodes (via_node) exactly like live
# requests, so a node's different residential IP does the probing; a dead
# node falls back to a direct request.
import json
import os
import threading
import time as time_module

from .cache import get_cached, set_cached, sanitize_lyrics_parts, _cache_key_from_filename
from .metadata import get_search_queries
from .race import _lyrics_score, _wbw_line_count, _race_cubey
from .providers_braccato import fetch_direct_best
from .translate import google_translate_fast
from .nodes import pick_node

_RERACE_INTERVAL = int(os.environ.get('YTMU_RERACE_INTERVAL', '300'))
_RERACE_BATCH = int(os.environ.get('YTMU_RERACE_BATCH', '15'))
_RERACE_COOLDOWN = int(os.environ.get('YTMU_RERACE_COOLDOWN', '21600'))

_rerace_last_attempt = {}
_rerace_lock = threading.Lock()


def _tier(data):
    """0 plain, 1 line-synced, 2 word-by-word. Upgrade only when the new
    result strictly beats the old tier -- 'same -> ignore'."""
    if not data:
        return -1
    if _wbw_line_count(data) > 0:
        return 2
    if data.get('synced'):
        return 1
    return 0


def _cache_candidates(limit, cooldown):
    """Oldest-first, not-yet-wbw cache entries that haven't been attempted
    within the cooldown. One entry per video (favoring the full key; a lone
    'fast' entry is fine when there's no full key for it)."""
    now = time_module.time()
    by_vid = {}
    lyrics_dir = 'cache/lyrics'
    if not os.path.isdir(lyrics_dir):
        return []
    for fname in os.listdir(lyrics_dir):
        key = _cache_key_from_filename(fname)
        if key is None:
            continue
        try:
            entry = json.load(open(os.path.join(lyrics_dir, fname), 'r', encoding='utf-8'))
            data = entry.get('data')
            if _tier(data) >= 2:
                continue
            parts = key.split(':')
            is_fast = parts[-1] == 'fast'
            lang = parts[-2] if is_fast else parts[-1]
            vid = ':'.join(parts[:-2] if is_fast else parts[:-1])
            if not vid or not lang:
                continue
            last = _rerace_last_attempt.get(vid, 0)
            if now - last < cooldown:
                continue
            cand = (key, vid, lang, entry.get('ts', ''), _tier(data))
            cur = by_vid.get(vid)
            # prefer the full key over the :fast sibling of the same video
            if cur is None or cur[0].endswith(':fast'):
                by_vid[vid] = cand
        except Exception:
            continue
    out = sorted(by_vid.values(), key=lambda x: x[3])
    return out[:limit]


def _rerace_video(video_id, lang, old_data):
    """Try to find a strictly-better word-by-word result. Returns the
    upgraded payload or None. Never raises to the caller."""
    title = old_data.get('song') or ''
    artist = old_data.get('artist') or ''
    if not title and not artist:
        return None
    queries = get_search_queries(title, artist, '', '')
    if not queries:
        return None
    duration = int(old_data.get('duration', 0) or 0)
    album = old_data.get('album', '') or ''
    node = pick_node()

    best = None
    for name, sources in (('boidu', ('ttml', 'qq', 'kugou')), ('binimum', ('binimum',))):
        try:
            cand = fetch_direct_best(queries, album, duration, sources=sources, via_node=node)
            if cand:
                sanitize_lyrics_parts(cand['lyrics'])
                if best is None or _lyrics_score(cand) > _lyrics_score(best):
                    best = cand
        except Exception as e:
            print(f"  [RERACE] {name} worker error: {e}")
            continue

    try:
        cubey = _race_cubey(queries, video_id, duration, None)
        if cubey:
            sanitize_lyrics_parts(cubey['lyrics'])
            if best is None or _lyrics_score(cubey) > _lyrics_score(best):
                best = cubey
    except Exception as e:
        print(f"  [RERACE] Cubey error: {e}")

    if not best:
        return None
    if _tier(best) <= _tier(old_data):
        return None
    if not best.get('lyrics'):
        return None

    best['song'] = old_data.get('song', '') or title
    best['artist'] = old_data.get('artist', '') or artist
    if lang:
        texts = [l['text'] for l in best['lyrics'] if l.get('text')]
        try:
            translations = google_translate_fast(texts, lang)
            for i, l in enumerate(best['lyrics']):
                if i < len(translations) and translations[i] and not l.get('translated'):
                    l['translated'] = translations[i]
        except Exception as e:
            print(f"  [RERACE] inline translation skipped: {e}")
    sanitize_lyrics_parts(best['lyrics'])
    return best


def rerace_pass():
    """One cooldown-gated pass over the cache. Logs every upgrade so the
    dashboard timeline shows old -> new without re-reading the file."""
    try:
        candidates = _cache_candidates(_RERACE_BATCH, _RERACE_COOLDOWN)
    except Exception as e:
        print(f"  [RERACE] candidate scan error: {e}")
        return
    if not candidates:
        return
    print(f"  [RERACE] pass: {len(candidates)} candidate(s)")
    for key, vid, lang, _ts, old_tier in candidates:
        old_data = get_cached(key)
        if old_data is None:
            continue
        try:
            upgraded = _rerace_video(vid, lang, old_data)
            with _rerace_lock:
                _rerace_last_attempt[vid] = time_module.time()
            if not upgraded:
                continue
            full_key = f"{vid}:{lang}"
            fast_key = f"{full_key}:fast"
            new_tier = _tier(upgraded)
            set_cached(full_key, upgraded)
            if get_cached(fast_key) is not None or key.endswith(':fast'):
                set_cached(fast_key, upgraded)
            print(f"  [RERACE] [OK] {vid} upgraded tier {old_tier}->{new_tier} "
                  f"source={upgraded.get('source')} lines={len(upgraded.get('lyrics', []))}")
        except Exception as e:
            print(f"  [RERACE] pass item error {vid}: {e}")
    print("  [RERACE] pass done")


def _rerace_loop():
    while True:
        time_module.sleep(_RERACE_INTERVAL)
        try:
            rerace_pass()
        except Exception as e:
            print(f"  [RERACE] pass error: {e}")


def start_rerace():
    threading.Thread(target=_rerace_loop, args=(), daemon=True).start()
    print(f"  [RERACE] background re-race loop started (interval={_RERACE_INTERVAL}s, batch={_RERACE_BATCH})")