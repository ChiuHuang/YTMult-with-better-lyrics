# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Library manager: cache scanning, unlyriced tracking, background rebase,
# and LLM-powered song retitling.
import json
import os
import re
import time as time_module
import threading
import concurrent.futures

from .cache import (
    get_cached, set_cached, is_not_found_result,
    _cache_key_from_filename, _cache_filename, sanitize_lyrics_parts,
)
from .rerace import _tier, _rerace_video
from .race import _wbw_line_count
from .translate import (
    COHERE_API_KEYS, get_cohere_key, rotate_cohere_key,
)

_UNLYRICED_PATH = 'cache/library_unlyriced.jsonl'
_UNLYRICED_SEEN = set()
_UNLYRICED_SEEN_LOCK = threading.Lock()
_UNLYRICED_DEDUP_WINDOW = 500

_RETITLE_MODEL = os.environ.get(
    'YTMU_RETITLE_MODEL', 'command-a-plus-05-2026')
_retitled_cache = {}

# Persistent manual title/artist override store: video_id -> {title, artist}.
# Written by the dashboard refetch flow (custom rename); read back by the
# same flow so a saved override is reused until it is explicitly replaced.
# The device provider menu (and dashboard) share this file for the saved
# lyric provider choice: video_id -> {provider, lang, ts}.
_PROVIDER_PATH = 'cache/provider.json'
_PROVIDER_CACHE = None
_PROVIDER_LOCK = threading.Lock()


def _load_provider_file():
    global _PROVIDER_CACHE
    try:
        if os.path.exists(_PROVIDER_PATH):
            with open(_PROVIDER_PATH, 'r', encoding='utf-8') as f:
                _PROVIDER_CACHE = json.load(f)
        else:
            _PROVIDER_CACHE = {}
    except Exception:
        _PROVIDER_CACHE = {}


def _save_provider_file():
    try:
        os.makedirs(os.path.dirname(_PROVIDER_PATH) or '.', exist_ok=True)
        with open(_PROVIDER_PATH, 'w', encoding='utf-8') as f:
            json.dump(_PROVIDER_CACHE, f, ensure_ascii=False, indent=1)
    except Exception as e:
        print(f"[LIBRARY] [FAIL] save provider file: {e}")


def get_provider(video_id):
    """Return the saved lyric provider choice {provider, lang, ts}, or None."""
    if not video_id:
        return None
    with _PROVIDER_LOCK:
        if _PROVIDER_CACHE is None:
            _load_provider_file()
        return _PROVIDER_CACHE.get(video_id)


def save_provider(video_id, provider, lang=''):
    """Persist a per-video lyric provider choice (device menu / dashboard)."""
    if not video_id or not provider:
        return
    with _PROVIDER_LOCK:
        if _PROVIDER_CACHE is None:
            _load_provider_file()
        _PROVIDER_CACHE[video_id] = {
            'provider': provider, 'lang': lang or '',
            'ts': time_module.time(),
        }
        _save_provider_file()


def clear_provider(video_id):
    """Remove a saved lyric provider choice for a video_id."""
    if not video_id:
        return
    with _PROVIDER_LOCK:
        if _PROVIDER_CACHE is None:
            _load_provider_file()
        if video_id in _PROVIDER_CACHE:
            del _PROVIDER_CACHE[video_id]
            _save_provider_file()


_RENAME_PATH = 'cache/rename.json'
_RENAME_CACHE = None
_RENAME_LOCK = threading.Lock()


def _load_rename_file():
    global _RENAME_CACHE
    try:
        if os.path.exists(_RENAME_PATH):
            with open(_RENAME_PATH, 'r', encoding='utf-8') as f:
                _RENAME_CACHE = json.load(f)
        else:
            _RENAME_CACHE = {}
    except Exception:
        _RENAME_CACHE = {}


def get_rename(video_id):
    """Return {title, artist} override for a video_id, or None."""
    if not video_id:
        return None
    with _RENAME_LOCK:
        if _RENAME_CACHE is None:
            _load_rename_file()
        return _RENAME_CACHE.get(video_id)


def save_rename(video_id, title, artist):
    """Persist a manual title/artist override for a video_id."""
    if not video_id:
        return
    with _RENAME_LOCK:
        if _RENAME_CACHE is None:
            _load_rename_file()
        _RENAME_CACHE[video_id] = {'title': title or '', 'artist': artist or ''}
        try:
            os.makedirs(os.path.dirname(_RENAME_PATH) or '.', exist_ok=True)
            with open(_RENAME_PATH, 'w', encoding='utf-8') as f:
                json.dump(_RENAME_CACHE, f, ensure_ascii=False, indent=1)
        except Exception as e:
            print(f"[LIBRARY] [FAIL] save_rename {video_id}: {e}")


def _tier_from_data(data):
    return _tier(data)


def clear_rename(video_id):
    """Remove a saved manual title/artist override for a video_id."""
    if not video_id:
        return
    with _RENAME_LOCK:
        if _RENAME_CACHE is None:
            _load_rename_file()
        if video_id in _RENAME_CACHE:
            del _RENAME_CACHE[video_id]
            try:
                os.makedirs(os.path.dirname(_RENAME_PATH) or '.', exist_ok=True)
                with open(_RENAME_PATH, 'w', encoding='utf-8') as f:
                    json.dump(_RENAME_CACHE, f, ensure_ascii=False, indent=1)
            except Exception as e:
                print(f"[LIBRARY] [FAIL] clear_rename {video_id}: {e}")


def apply_saved_rename(video_id, info):
    """Merge a saved manual rename into a song-info dict in place, return it.

    No-op when nothing is saved. Used by background fetch paths (rebase,
    playlist sync) so one manual rename improves every later refetch."""
    saved = get_rename(video_id) or {}
    t = (saved.get('title') or '').strip()
    a = (saved.get('artist') or '').strip()
    if t:
        info['title'] = t
    if a:
        info['artist'] = a
    return info


# ------------------------------------------------------------
# Cache scan
# ------------------------------------------------------------
def scan_cache():
    """Scan cache/lyrics, dedupe per video (prefer full key over :fast), and
    return a summary dict with per-tier bucket counts and a songs list."""
    lyrics_dir = 'cache/lyrics'
    buckets = {'wbw': 0, 'line': 0, 'plain': 0, 'none': 0, 'error': 0}
    by_vid = {}

    if not os.path.isdir(lyrics_dir):
        return {'total': 0, 'buckets': buckets, 'songs': []}

    for fname in os.listdir(lyrics_dir):
        key = _cache_key_from_filename(fname)
        if key is None:
            continue
        try:
            fpath = os.path.join(lyrics_dir, fname)
            with open(fpath, 'r', encoding='utf-8') as f:
                entry = json.load(f)
        except Exception:
            continue

        data = entry.get('data')
        parts = key.split(':')
        is_fast = len(parts) >= 3 and parts[-1] == 'fast'
        lang = parts[-2] if is_fast else parts[-1]
        vid = ':'.join(parts[:-2] if is_fast else parts[:-1])
        if not vid or not lang:
            continue

        tier_val = _tier_from_data(data)
        if tier_val >= 2:
            tier = 'wbw'
        elif tier_val == 1:
            tier = 'line'
        elif tier_val == 0:
            tier = 'plain'
        else:
            tier = 'none'

        if is_not_found_result(data):
            tier = 'none'

        # prefer the full key over :fast sibling of the same video
        cur = by_vid.get(vid)
        if cur is None or (is_fast and not cur['key'].endswith(':fast')):
            by_vid[vid] = {
                'video_id': vid,
                'lang': lang,
                'key': key,
                'song': (data or {}).get('song', ''),
                'artist': (data or {}).get('artist', ''),
                'source': (data or {}).get('source', ''),
                'tier': tier,
                'synced': bool((data or {}).get('synced', False)),
                'lines': len((data or {}).get('lyrics', [])),
                'ts': entry.get('ts', ''),
            }

    songs = sorted(by_vid.values(), key=lambda x: x['ts'], reverse=True)
    for s in songs:
        t = s['tier']
        if t in buckets:
            buckets[t] += 1

    return {'total': len(songs), 'buckets': buckets, 'songs': songs}


# ------------------------------------------------------------
# Unlyriced tracking (JSONL append-only log)
# ------------------------------------------------------------
def _ensure_unlyriced_seen():
    """Load existing JSONL into the dedup set on first use."""
    global _UNLYRICED_SEEN
    with _UNLYRICED_SEEN_LOCK:
        if _UNLYRICED_SEEN:
            return
        if not os.path.exists(_UNLYRICED_PATH):
            return
        try:
            with open(_UNLYRICED_PATH, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    rec = json.loads(line)
                    _UNLYRICED_SEEN.add(rec.get('video_id', ''))
        except Exception:
            pass


def record_unlyriced(video_id, song, artist, lang):
    """Append a record to the unlyriced JSONL file."""
    if not video_id:
        return
    _ensure_unlyriced_seen()
    with _UNLYRICED_SEEN_LOCK:
        if video_id in _UNLYRICED_SEEN:
            return
        _UNLYRICED_SEEN.add(video_id)

    try:
        os.makedirs(os.path.dirname(_UNLYRICED_PATH) or '.', exist_ok=True)
        rec = {
            'video_id': video_id,
            'song': song or '',
            'artist': artist or '',
            'lang': lang or '',
            'ts': time_module.time(),
        }
        with open(_UNLYRICED_PATH, 'a', encoding='utf-8') as f:
            f.write(json.dumps(rec, ensure_ascii=False) + '\n')
    except Exception as e:
        print(f"[LIBRARY] [FAIL] record_unlyriced {video_id}: {e}")


def list_unlyriced():
    """Return deduped unlyriced records (most recent per video_id wins),
    newest first."""
    if not os.path.exists(_UNLYRICED_PATH):
        return []
    by_vid = {}
    try:
        with open(_UNLYRICED_PATH, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                rec = json.loads(line)
                vid = rec.get('video_id', '')
                if vid:
                    by_vid[vid] = {
                        'video_id': vid,
                        'song': rec.get('song', ''),
                        'artist': rec.get('artist', ''),
                        'lang': rec.get('lang', ''),
                        'ts': rec.get('ts', 0),
                    }
    except Exception:
        return []
    return sorted(by_vid.values(), key=lambda x: x.get('ts', 0), reverse=True)


def remove_unlyriced(video_id):
    """Remove all records for video_id from the JSONL file."""
    if not os.path.exists(_UNLYRICED_PATH):
        return
    lines = []
    try:
        with open(_UNLYRICED_PATH, 'r', encoding='utf-8') as f:
            for line in f:
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    rec = json.loads(stripped)
                    if rec.get('video_id') != video_id:
                        lines.append(stripped)
                except Exception:
                    lines.append(stripped)
    except Exception:
        return
    try:
        with open(_UNLYRICED_PATH, 'w', encoding='utf-8') as f:
            for l in lines:
                f.write(l + '\n')
    except Exception:
        pass
    with _UNLYRICED_SEEN_LOCK:
        _UNLYRICED_SEEN.discard(video_id)


# ------------------------------------------------------------
# Background rebase
# ------------------------------------------------------------
def rebase_cached(job, on_result, cancel_event=None, max_workers=8,
                   sleep_between=0.5, target_vid=None):
    """Re-race non-wbw cache entries in parallel and upgrade when possible.

    *job* is a mutable dict that gets its counters mutated in-place.
    *on_result* is called with each per-video result dict.
    *cancel_event* -- if set, processing stops early.
    """
    try:
        candidates = _cache_candidates_for_rebase()
    except Exception as e:
        print(f"[REBASE] [FAIL] candidate scan: {e}")
        return

    if target_vid:
        candidates = [c for c in candidates if c['video_id'] == target_vid]

    total = len(candidates)
    job['total'] = total
    job['done'] = 0
    job['upgraded'] = 0
    job['same'] = 0
    job['failed'] = 0
    job['error'] = 0
    job['already'] = 0
    job['results'] = []
    print(f"[REBASE] starting: {total} candidate(s)")

    def _process_one(cand):
        if cancel_event and cancel_event.is_set():
            return None
        vid = cand['video_id']
        lang = cand['lang']
        old_tier = cand['tier']
        song = cand['song']
        artist = cand['artist']
        old_data = get_cached(f"{vid}:{lang}")
        if old_data is None:
            return {
                'video_id': vid, 'song': song, 'artist': artist,
                'from': old_tier, 'to': old_tier, 'status': 'error',
                'source': '', 'message': 'old cache miss',
            }
        try:
            upgraded = _rerace_video(vid, lang, old_data)
        except Exception as e:
            return {
                'video_id': vid, 'song': song, 'artist': artist,
                'from': old_tier, 'to': old_tier, 'status': 'error',
                'source': '', 'message': str(e),
            }
        new_tier_val = _tier(upgraded) if upgraded else -1
        tier_map = {2: 'wbw', 1: 'line', 0: 'plain'}
        new_tier = tier_map.get(new_tier_val, 'none')
        # If rerace got nothing better (same/plain/none), try LLM retitle
        # + fresh fetch -- cleaned metadata helps Portato/BLyrics match.
        if new_tier_val < 2 and new_tier_val <= _tier(old_data):
            llm_res = _try_llm_retitle_fetch(vid, lang, old_data)
            if llm_res is not None:
                llm_tier = _tier(llm_res)
                if llm_tier > _tier(old_data):
                    new_tier = tier_map.get(llm_tier, 'none')
                    upgraded = llm_res
                    new_tier_val = llm_tier
                    song = llm_res.get('song', song)
                    artist = llm_res.get('artist', artist)
        if new_tier_val <= _tier(old_data):
            return {
                'video_id': vid, 'song': song, 'artist': artist,
                'from': old_tier, 'to': new_tier, 'status': 'same',
                'source': (upgraded or old_data).get('source', ''),
                'message': 'result not better',
            }
        full_key = f"{vid}:{lang}"
        fast_key = f"{full_key}:fast"
        set_cached(full_key, upgraded)
        if get_cached(fast_key) is not None:
            set_cached(fast_key, upgraded)
        return {
            'video_id': vid, 'song': song, 'artist': artist,
            'from': old_tier, 'to': new_tier, 'status': 'upgraded',
            'source': upgraded.get('source', ''),
            'message': f"{old_tier}->{new_tier}",
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {}
        for cand in candidates:
            if cancel_event and cancel_event.is_set():
                break
            fut = pool.submit(_process_one, cand)
            futures[fut] = cand

        for fut in concurrent.futures.as_completed(futures):
            if cancel_event and cancel_event.is_set():
                break
            cand = futures[fut]
            try:
                res = fut.result()
            except Exception as e:
                res = {
                    'video_id': cand['video_id'],
                    'song': cand.get('song', ''),
                    'artist': cand.get('artist', ''),
                    'from': cand['tier'], 'to': cand['tier'],
                    'status': 'error', 'source': '',
                    'message': str(e),
                }
            if res is None:
                continue
            status = res.get('status', 'error')
            job['done'] = job.get('done', 0) + 1
            if status == 'upgraded':
                job['upgraded'] = job.get('upgraded', 0) + 1
            elif status == 'same':
                job['same'] = job.get('same', 0) + 1
            elif status == 'failed':
                job['failed'] = job.get('failed', 0) + 1
            elif status == 'error':
                job['error'] = job.get('error', 0) + 1
            elif status == 'already':
                job['already'] = job.get('already', 0) + 1
            job['results'].append(res)
            job['current'] = {
                'video_id': cand['video_id'],
                'song': cand.get('song', ''),
                'artist': cand.get('artist', ''),
            }
            if on_result:
                try:
                    on_result(res)
                except Exception:
                    pass
            if sleep_between > 0:
                time_module.sleep(sleep_between)

    print(f"[REBASE] [OK] done={job.get('done',0)} upgraded={job.get('upgraded',0)} "
          f"same={job.get('same',0)} failed={job.get('failed',0)} "
          f"error={job.get('error',0)}")


def _try_llm_retitle_fetch(vid, lang, old_data):
    """Try LLM retitle + fresh braccato fetch. Returns upgraded data or None.

    Called when rerace gives same/plain -- cleaned metadata can help
    Portato/BLyrics match a song the raw title missed."""
    song = old_data.get('song') or ''
    artist = old_data.get('artist') or ''
    if not song and not artist:
        return None
    saved = get_rename(vid) or {}
    saved_t = (saved.get('title') or '').strip()
    saved_a = (saved.get('artist') or '').strip()
    if saved_t or saved_a:
        # Manual rename wins over the LLM guess -- and skips the LLM call.
        new_song = saved_t or song
        new_artist = saved_a or artist
        print(f"[REBASE] [RENAME] {vid}: {song!r}->{new_song!r} | {artist!r}->{new_artist!r}")
    else:
        cleaned = retitle_song(song, artist)
        new_song = cleaned.get('title', song)
        new_artist = cleaned.get('artist', artist)
        print(f"[REBASE] [LLM] retitling {vid}: {song!r}->{new_song!r} | {artist!r}->{new_artist!r}")
    if new_song == song and new_artist == artist:
        return None  # nothing changed -- no point refetching
    from .pipeline import fetch_all_lyrics
    from .providers_yt import get_song_info
    try:
        info = get_song_info(vid)
        if not info:
            return None
        info['title'] = new_song
        info['artist'] = new_artist
        result = fetch_all_lyrics(vid, info, lang)
        if result and not is_not_found_result(result):
            result['song'] = new_song
            result['artist'] = new_artist
            if _tier(result) > _tier(old_data):
                return result
    except Exception as e:
        print(f"[REBASE] [LLM] fetch error {vid}: {e}")
    return None


def _cache_candidates_for_rebase():
    """Return all non-wbw cache entries, deduped per video (prefer full key)."""
    songs = scan_cache()
    candidates = []
    for s in songs['songs']:
        if s['tier'] == 'wbw':
            continue
        candidates.append(s)
    return candidates


# ------------------------------------------------------------
# LLM retitling
# ------------------------------------------------------------
_RETITLE_PROMPT_TEMPLATE = (
    "You are a song metadata cleaner. Given a YouTube video title and artist, "
    "return a JSON object with cleaned title and artist fields.\n"
    "Remove: official video, official audio, official lyric video, "
    "official mv, lyrics, mv, (cover ...), "
    "歌ってみた, self cover tags, and YouTube noise.\n"
    "If the title contains Title - Artist format, split them properly.\n"
    "Keep (feat. ...) in the artist field only.\n"
    "Remove duplicated artist name embedded in the title.\n"
    "Return ONLY valid JSON with keys title and artist.\n\n"
    "Title: {title}\nArtist: {artist}"
)

# Patterns used as regex fallback when LLM fails entirely
_OFFICIAL_NOISE_RE = re.compile(
    r'(?i)\b(?:official\s*(?:video|audio|music\s*video|mv|lyric\s*video)?|'
    r'lyric\s*video|official\b)')
_COVER_NOISE_RE = re.compile(
    r'(?i)[\(\[\{]?\s*(?:cover(?:ed)?(?:\s+by[^\)\]\}]*)?|歌ってみた|'
    r'self\s*cover)\s*[\)\]\}]?')
_YT_NOISE_RE = re.compile(
    r'(?i)\b(?:mv|audio|visualizer|visualiser|'
    r'full\s+ver\.?|full\s+version)\b')
_FEAT_TITLE_RE = re.compile(
    r'(?i)\s*[-–—/]\s*(?:feat\.?|ft\.?)\s+.*$')


def retitle_song(song, artist):
    """Clean a song title + artist using Cohere LLM. Returns {title, artist}.
    On any failure, falls back to regex-based cleaning. Never raises."""
    cache_key = f"{(song or '').lower()}|{(artist or '').lower()}".strip('|')
    if cache_key in _retitled_cache:
        return _retitled_cache[cache_key]

    result = _retitle_via_llm(song, artist)
    if result is None:
        result = _retitle_via_regex(song, artist)

    _retitled_cache[cache_key] = result
    return result


def _retitle_via_llm(song, artist):
    """Call Cohere for retitling. Returns {title, artist} or None."""
    prompt = _RETITLE_PROMPT_TEMPLATE.format(
        title=song or '', artist=artist or '')
    for attempt in range(len(COHERE_API_KEYS)):
        try:
            import requests as _requests
            api_key = get_cohere_key()
            resp = _requests.post(
                "https://api.cohere.com/v2/chat",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": _RETITLE_MODEL,
                    "messages": [{"role": "user", "content": prompt}],
                },
                timeout=30,
            )
            if resp.status_code == 429:
                print(f"  [RETITLE] [WARN] rate limited key {attempt}, rotating")
                rotate_cohere_key()
                continue
            if resp.status_code != 200:
                print(f"  [RETITLE] [WARN] HTTP {resp.status_code}")
                rotate_cohere_key()
                continue
            body = resp.json()
            text = body['message']['content'][0]['text']
            return _parse_json_from_text(text, song, artist)
        except Exception as e:
            print(f"  [RETITLE] [WARN] LLM error: {e}")
            rotate_cohere_key()
    print(f"  [RETITLE] [WARN] all LLM keys exhausted")
    return None


def _parse_json_from_text(text, fallback_title, fallback_artist):
    """Extract the first {...} JSON from LLM output. Returns {title, artist}."""
    # Try direct parse first
    try:
        obj = json.loads(text)
        if 'title' in obj:
            return {'title': obj['title'], 'artist': obj.get('artist', fallback_artist)}
    except Exception:
        pass
    # Regex: find first { ... }
    m = re.search(r'\{[^{}]*\}', text)
    if m:
        try:
            obj = json.loads(m.group(0))
            if 'title' in obj:
                return {'title': obj['title'], 'artist': obj.get('artist', fallback_artist)}
        except Exception:
            pass
    return None


def _retitle_via_regex(song, artist):
    """Regex-based fallback cleaning. Never raises."""
    t = song or ''
    a = artist or ''

    # strip official/cover/yt noise
    t = _OFFICIAL_NOISE_RE.sub('', t)
    t = _COVER_NOISE_RE.sub('', t)
    t = _YT_NOISE_RE.sub('', t)
    t = _FEAT_TITLE_RE.sub('', t)

    # "Song - Artist" split
    parts = re.split(r'\s*[-–—/]\s*', t, maxsplit=1)
    if len(parts) == 2 and parts[1].strip():
        cand_artist = parts[1].strip()
        # only adopt if it looks like a name (not noise)
        if len(cand_artist) < 80:
            t = parts[0].strip()
            if not a:
                a = cand_artist

    t = re.sub(r'\s+', ' ', t).strip(' -_./')
    a = re.sub(r'\s+', ' ', a).strip(' -_./')

    if not t:
        t = song or ''
    if not a:
        a = artist or ''

    return {'title': t, 'artist': a}
