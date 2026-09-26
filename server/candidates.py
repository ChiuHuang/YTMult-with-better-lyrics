# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Persisted per-video provider candidates + same-line word-timing graft.
#
# probe_providers() finds every provider's lyrics but only the winner used
# to survive (everything else was discarded). This module persists the FULL
# snapshot per video (latest probe wins) so re-race, the device provider
# switcher, and anything else can reuse all providers without re-fetching:
#   save_candidates(video_id, song_info, candidates)  # called by probe_providers
#   load_candidates(video_id)                         # fresh snapshot or None
#
# graft_wbw_parts() handles the "same lines, but word-timed elsewhere"
# case: when the winning candidate is line-sync/plain but another provider
# has real per-word timing for the same lines, the word parts are copied
# onto the winner instead of settling for the lesser tier.
import copy
import json
import os
import time as time_module
from datetime import datetime

_CAND_DIR = 'cache/candidates'
# Snapshots older than this are ignored (probes overwrite on every full run
# anyway, so this only guards videos probed once long ago).
_CAND_MAX_AGE_S = 7 * 86400


def _cand_path(video_id):
    from .cache import _cache_filename
    return os.path.join(_CAND_DIR, _cache_filename(video_id) + '.json')


def save_candidates(video_id, song_info, candidates, only_source=None):
    """Persist a full probe snapshot. Latest wins. Skipped for partial
    (only_source) probes so a filtered re-probe never clobbers the full set.
    Stored lyrics are raw (translations stripped -- the select path
    re-translates into whatever lang the client asks for). Returns True when
    written."""
    if only_source or not video_id or not candidates:
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
        os.makedirs(_CAND_DIR, exist_ok=True)
        payload = {
            'v': 1,
            'video_id': video_id,
            'song': (song_info or {}).get('title', ''),
            'artist': (song_info or {}).get('artist', ''),
            'ts': datetime.now().isoformat(),
            'candidates': slim,
        }
        tmp = _cand_path(video_id) + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, _cand_path(video_id))
        print(f"  [CAND] saved {len(slim)} provider(s) for {video_id}")
        return True
    except Exception as e:
        print(f"  [CAND] [FAIL] save {video_id}: {e}")
        return False


def load_candidates(video_id, max_age_s=_CAND_MAX_AGE_S):
    """Return the latest snapshot's candidate list (best-first) or None when
    missing/stale/unreadable. Payloads are raw (no translations)."""
    if not video_id:
        return None
    try:
        path = _cand_path(video_id)
        if not os.path.exists(path):
            return None
        with open(path, 'r', encoding='utf-8') as f:
            payload = json.load(f)
        cands = payload.get('candidates')
        if not cands:
            return None
        if max_age_s and payload.get('ts'):
            age = (datetime.now() - datetime.fromisoformat(payload['ts'])).total_seconds()
            if age > max_age_s:
                return None
        return cands
    except Exception:
        return None


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
        b_inst = b.get('isInstrumental') or _norm_text(b.get('text')) == '[instrumental]'
        d_inst = d.get('isInstrumental') or _norm_text(d.get('text')) == '[instrumental]'
        if b_inst or d_inst:
            if not (b_inst and d_inst):
                return False
            continue
        if _norm_text(b.get('text')) != _norm_text(d.get('text')):
            return False
        if not _line_is_wbw(d):
            return False
    for b, d in zip(base_lyrics, donor_lyrics):
        if b.get('isInstrumental') or d.get('isInstrumental'):
            continue
        b['parts'] = copy.deepcopy(d.get('parts'))
        b['wordSynced'] = True
    return True
