# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Per-video provider candidates (RAM-first) + same-line word-timing graft.
#
# probe_providers() / fetch_all_lyrics() find every provider's lyrics but only
# the winner ever reaches the lyrics cache. This module keeps the FULL snapshot
# per video (latest run wins) so re-race, the device provider switcher and
# anything else can reuse every provider without re-fetching:
#   save_candidates(video_id, song_info, candidates)  # probe + full-fetch path
#   load_candidates(video_id)                         # fresh snapshot or None
#
# Storage is IN MEMORY ONLY by default: the switcher, the re-race and the
# select path all read it straight out of the process, and the only thing
# that ever touches disk is the lyrics cache of the single provider actually
# serving. Writing per-provider snapshots to disk for every song is pure
# bloat, so it is opt-in via YTMU_PERSIST_CANDIDATES=1 (or persist=True).
#
# graft_wbw_parts() handles the "same lines, but word-timed elsewhere"
# case: when the winning candidate is line-sync/plain but another provider
# has real per-word timing for the same lines, the word parts are copied
# onto the winner instead of settling for the lesser tier.
import copy
import json
import os
import threading
import time as time_module
from collections import OrderedDict
from datetime import datetime

_CAND_DIR = 'cache/candidates'
# Snapshots older than this are ignored (probes overwrite on every full run
# anyway, so this only guards videos probed once long ago).
_CAND_MAX_AGE_S = 7 * 86400

# --- RAM store -------------------------------------------------------------
# Bounded LRU: enough room for a listening session (plus the prefetched queue),
# small enough that a long-running server never grows without limit.
_RAM_MAX_VIDEOS = 32
_ram_lock = threading.RLock()
_ram_snapshots = OrderedDict()  # video_id -> payload (same shape as on disk)
# Opt-in disk persistence (dashboard/analysis runs only).
_PERSIST_TO_DISK = os.environ.get('YTMU_PERSIST_CANDIDATES', '').strip().lower() in (
    '1', 'true', 'yes', 'on')


def _ram_put(video_id, payload):
    """Store a snapshot in RAM, evicting the least-recently-used video."""
    with _ram_lock:
        _ram_snapshots.pop(video_id, None)
        _ram_snapshots[video_id] = payload
        while len(_ram_snapshots) > _RAM_MAX_VIDEOS:
            _ram_snapshots.popitem(last=False)


def _ram_get(video_id):
    """Deep copy of the RAM snapshot (callers mutate what they get), or None."""
    with _ram_lock:
        payload = _ram_snapshots.get(video_id)
        if payload is None:
            return None
        _ram_snapshots.move_to_end(video_id)
    try:
        return copy.deepcopy(payload)
    except Exception:
        return payload


def ram_videos():
    """Video IDs currently held in RAM (newest last). Debug/dashboard aid."""
    with _ram_lock:
        return list(_ram_snapshots.keys())


def _cand_path(video_id):
    from .cache import _cache_filename
    return os.path.join(_CAND_DIR, _cache_filename(video_id) + '.json')


def save_candidates(video_id, song_info, candidates, only_source=None, outcomes=None,
                    persist=None):
    """Store a full probe snapshot. Latest wins. Skipped for partial
    (only_source) probes so a filtered re-probe never clobbers the full set.
    Stored lyrics are raw (translations stripped -- the select path
    re-translates into whatever lang the client asks for). Plain-tier
    entries are pruned when a line-or-better entry exists (wbw never prunes
    line -- line stays as the fallback switch option). outcomes maps
    provider -> {status: found|missed|error|skipped, tier?, ts} so later
    runs know what each provider gave without re-trying.

    The snapshot lands in RAM (bounded LRU). Disk is opt-in: pass
    persist=True, or set YTMU_PERSIST_CANDIDATES=1 for the whole process.
    Returns True when the snapshot was accepted (RAM or disk)."""
    if only_source or not video_id or (not candidates and not outcomes):
        return False
    try:
        slim = []
        for c in candidates:
            if not isinstance(c, dict):
                continue
            data = c.get('data') or {}
            lyrics = data.get('lyrics') or []
            if not lyrics:
                continue
            clean_lyrics = copy.deepcopy(lyrics)
            for l in clean_lyrics:
                if isinstance(l, dict):
                    l.pop('translated', None)
            slim.append({
                'provider': c.get('provider', ''),
                'source': c.get('source', ''),
                'synced': bool(c.get('synced')),
                'wordSynced': bool(c.get('wordSynced')),
                'tier': c.get('tier', ''),
                'lines': len(clean_lyrics),
                'score': c.get('score', 0),
                'data': {
                    'lyrics': clean_lyrics,
                    'source': data.get('source', ''),
                    'synced': bool(data.get('synced')),
                    'wordSynced': bool(data.get('wordSynced')),
                    'song': data.get('song', ''),
                    'artist': data.get('artist', ''),
                },
            })
        if not slim:
            return False
        # Prune: plain entries go when a line-or-better entry exists; line
        # entries always stay (wbw never deletes its fallback).
        tiers = {c.get('tier') for c in slim}
        if tiers & {'line', 'wbw'}:
            dropped = [c.get('provider') for c in slim if c.get('tier') == 'plain']
            slim = [c for c in slim if c.get('tier') != 'plain']
            if dropped:
                print(f"  [CAND] pruned plain provider(s) for {video_id}: {', '.join(dropped)}")
        if not slim and not outcomes:
            return False
        payload = {
            'v': 1,
            'video_id': video_id,
            'song': (song_info or {}).get('title', ''),
            'artist': (song_info or {}).get('artist', ''),
            'ts': datetime.now().isoformat(),
            'outcomes': outcomes or {},
            'candidates': slim,
        }
        _ram_put(video_id, payload)
        if persist is None:
            persist = _PERSIST_TO_DISK
        if persist:
            os.makedirs(_CAND_DIR, exist_ok=True)
            tmp = _cand_path(video_id) + '.tmp'
            with open(tmp, 'w', encoding='utf-8') as f:
                json.dump(payload, f, ensure_ascii=False)
            os.replace(tmp, _cand_path(video_id))
        print(f"  [CAND] {len(slim)} provider(s) for {video_id} in RAM"
              f"{' +disk' if persist else ''}")
        return True
    except Exception as e:
        print(f"  [CAND] [FAIL] save {video_id}: {e}")
        return False


def load_candidates(video_id, max_age_s=_CAND_MAX_AGE_S):
    """Return the latest snapshot's candidate list (best-first) or None when
    missing/stale/unreadable. Payloads are raw (no translations)."""
    snap = load_snapshot(video_id, max_age_s=max_age_s)
    if not snap:
        return None
    return snap.get('candidates') or None


def load_snapshot(video_id, max_age_s=_CAND_MAX_AGE_S):
    """Full snapshot payload (candidates + outcomes + song/artist/ts).
    RAM first (that is where every save lands now); on-disk files are only
    read when nothing is held for this video (legacy/opted-in snapshots)."""
    if not video_id:
        return None
    ram = _ram_get(video_id)
    if ram and _snapshot_usable(ram, max_age_s):
        return ram
    try:
        path = _cand_path(video_id)
        if not os.path.exists(path):
            return ram
        with open(path, 'r', encoding='utf-8') as f:
            payload = json.load(f)
        if not _snapshot_usable(payload, max_age_s):
            return ram
        return payload
    except Exception:
        return ram


def _snapshot_usable(payload, max_age_s=_CAND_MAX_AGE_S):
    cands = (payload or {}).get('candidates')
    if not cands and not (payload or {}).get('outcomes'):
        return False
    if max_age_s and payload.get('ts'):
        try:
            age = (datetime.now() - datetime.fromisoformat(payload['ts'])).total_seconds()
        except Exception:
            age = 0  # unparseable ts: keep the data, don't drop it
        if age > max_age_s:
            return False
    return True


def _norm_text(t):
    """Compare lyric lines across providers: ignore whitespace runs, case,
    and the [...] instrumental marker text (gaps align by position)."""
    if not isinstance(t, str):
        return ''
    out = []
    for ch in t:
        if ch.isspace():
            continue
        out.append(ch.lower())
    return ''.join(out)


def _line_is_wbw(line):
    parts = (line or {}).get('parts') or []
    return bool((line or {}).get('wordSynced')) and len(parts) > 1 and \
        len({p.get('startTimeMs') for p in parts}) > 1


def _is_gap_line(line):
    return bool((line or {}).get('isInstrumental')) or \
        _norm_text((line or {}).get('text')) == '[instrumental]'


def graft_wbw_parts(base_lyrics, donor_lyrics):
    """Copy real word timing from donor onto base when both carry the SAME
    lines. Strict all-or-nothing: every non-gap line must match by
    normalized text AND be genuinely word-timed in the donor, otherwise
    nothing is touched. Mutates base in place; returns True when grafted."""
    if not base_lyrics or not donor_lyrics or len(base_lyrics) != len(donor_lyrics):
        return False
    for b, d in zip(base_lyrics, donor_lyrics):
        if not isinstance(b, dict) or not isinstance(d, dict):
            return False
        b_gap = _is_gap_line(b)
        d_gap = _is_gap_line(d)
        if b_gap or d_gap:
            if not (b_gap and d_gap):
                return False
            continue
        if _norm_text(b.get('text')) != _norm_text(d.get('text')):
            return False
        if not _line_is_wbw(d):
            return False
    for b, d in zip(base_lyrics, donor_lyrics):
        if _is_gap_line(b) or _is_gap_line(d):
            continue
        b['parts'] = copy.deepcopy(d.get('parts'))
        b['wordSynced'] = True
    return True
