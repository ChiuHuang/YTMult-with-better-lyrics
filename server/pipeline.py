# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
import functools
import json
import os
import re
import sys
import requests
import hashlib
import time as time_module
import subprocess
import threading
import concurrent.futures
from collections import deque
from datetime import datetime
from urllib.parse import quote
import secrets as _secrets
import uuid
import traceback
import atexit
import logging
from .metadata import get_search_queries
from .providers_lrclib import fetch_lrclib
from .providers_yt import fetch_yt_lyrics, get_song_info
from .providers_cubey import fetch_cubey
from .providers_unison import fetch_unison
from .providers_braccato import fetch_direct_best
from .parsers_lrc import parse_lrc, parse_plain
from .translate import google_translate_fast
from .cache import is_not_found_result, sanitize_lyrics_parts
from .candidates import save_candidates, graft_wbw_parts
from .nodes import pick_node
from .jwt_pool import pick_jwt

# ============================================================
# Main Lyrics Pipeline
# ============================================================

# Server-side in-flight dedup
_in_flight = {}  # dedup_key -> threading.Event
_in_flight_lock = threading.Lock()  # protects atomic check-and-register
import threading

def fetch_fast_lyrics(video_id, song_info, translate_to='zh-TW'):
    """Fast path: LRCLIB only + Google translate. Returns in ~1-2s."""
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    result = None

    queries = get_search_queries(song_info['title'], song_info['artist'], song_info.get('ja_title', ''), song_info.get('ja_artist', ''))
    node = pick_node()
    for q in queries:
        q_title = q['title']
        q_artist = q['artist']
        lrc = fetch_lrclib(q_title, q_artist, album, duration, via_node=node)
        if lrc:
            if lrc.get('instrumental'):
                result = {'lyrics': [{'time': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'duration': 0}], 'source': 'LRCLib', 'synced': False}
                break
            elif lrc.get('synced'):
                print(f"  [fast] [OK] LRCLIB synced! (query: {q_title} - {q_artist})")
                result = {'lyrics': parse_lrc(lrc['synced'], duration), 'source': 'LRCLib', 'synced': True}
                break
            elif lrc.get('plain') and not result:
                print(f"  [fast] [WARN]️ LRCLIB plain (query: {q_title} - {q_artist})")
                result = {'lyrics': parse_plain(lrc['plain']), 'source': 'LRCLib', 'synced': False}

    if not result:
        yt = fetch_yt_lyrics(video_id)
        if yt and yt.get('plain'):
            print(f"  [fast] [OK] YouTube plain!")
            result = {'lyrics': parse_plain(yt['plain']), 'source': 'YouTube Music', 'synced': False}

    if not result:
        return None

    result['song'] = song_info['title']
    result['artist'] = song_info['artist']

    if translate_to and result.get('lyrics'):
        texts = [l['text'] for l in result['lyrics'] if l.get('text')]
        translations = google_translate_fast(texts, translate_to)
        for i, lyric in enumerate(result['lyrics']):
            if i < len(translations) and translations[i]:
                lyric['translated'] = translations[i]

    if result and result.get('lyrics'):
        sanitize_lyrics_parts(result['lyrics'])

    return result

def fetch_all_lyrics(video_id, song_info, translate_to=None, jwt_token=None, on_stage=None):
    """Try all providers and keep the single best result, ranked by the same
    word-by-word-first score the stream race uses (_lyrics_score), so the
    sequential endpoint and the SSE endpoint agree on what 'best' means.
    A plain hit never outranks a synced one, and a syllable/word-timed hit
    outranks everything else. on_stage(name, status, detail) optionally
    reports each provider stage (started/found/missed/error) for live UIs."""

    def _stage(name, status, detail=''):
        if on_stage is None:
            return
        try:
            on_stage(name, status, detail)
        except Exception:
            pass

    title = song_info['title']
    artist = song_info['artist']
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    queries = get_search_queries(title, artist, song_info.get('ja_title', ''), song_info.get('ja_artist', ''))

    from .race import _lyrics_score

    result = None  # best across providers, decided by score
    considered = []  # every (label, candidate) tried, for wbw graft + saving
    _fetch_lock = threading.Lock()
    _fetch_stages = []  # stage thunks; all run concurrently below

    def consider(candidate, label):
        nonlocal result
        if not candidate or not candidate.get('lyrics'):
            return
        sanitize_lyrics_parts(candidate['lyrics'])
        with _fetch_lock:
            considered.append((label, candidate))
            if result is None or _lyrics_score(candidate) > _lyrics_score(result):
                result = candidate
                print(f"  [rank] {label}: {candidate.get('source')} now best (score={_lyrics_score(result):.2f})")

    # Priority 0: Cubey API (if we have JWT) -- one pass covers Musixmatch
    # wordByWord/synced, QQ QRC, KuGou LRC, NetEase and the bLyrics/BiniLyrics
    # TTML events, with word-by-word always preferred inside the stream.
    # No request JWT? Fall back to the contributed pool before giving up.
    if not jwt_token:
        jwt_token = pick_jwt()
        if jwt_token:
            print(f"  [0/5] No request JWT -- using a contributed token from the pool")
    def _s_cubey():
        print(f"  [fetch] Trying Cubey API (with JWT)...")
        _stage('Cubey', 'started')
        try:
            cubey_node = pick_node()
            for q in queries:
                try:
                    cubey = fetch_cubey(jwt_token, video_id, q['title'], q['artist'], duration, via_node=cubey_node)
                except Exception as e:
                    print(f"  [FAIL] Cubey query error: {e}")
                    continue
                if not cubey:
                    continue
                if cubey.get('parsed'):
                    print(f"  [OK] Cubey: {cubey.get('source')} TTML lyrics found (wordSynced={cubey.get('wordSynced')}) (query: {q['title']})")
                    consider({'lyrics': cubey['parsed'], 'source': cubey.get('source'), 'synced': True}, 'Cubey TTML')
                elif cubey.get('synced'):
                    print(f"  [OK] Cubey: synced LRC lyrics found from {cubey.get('source')}! (query: {q['title']})")
                    consider({'lyrics': parse_lrc(cubey['synced'], duration), 'source': cubey.get('source'), 'synced': True}, 'Cubey synced')
            _stage('Cubey', 'done')
        except Exception as e:
            print(f"  [FAIL] Cubey stage error (continuing): {e}")
            _stage('Cubey', 'error', str(e))
    if jwt_token:
        _fetch_stages.append(_s_cubey)
    else:
        _stage('Cubey', 'skipped', 'no JWT')
        print(f"  [fetch] Cubey skipped (no JWT)")

    # Priority 1: direct braccato providers (no JWT) -- bLyrics TTML (often
    # syllable-timed), Portato QQ QRC (word-by-word), Legato KuGou LRC.
    def _s_direct():
        _stage('braccato-direct', 'started')
        try:
            direct = fetch_direct_best(queries, album, duration)
            if direct:
                print(f"  [OK] direct boidu/Binimum: {direct.get('source')} (wordSynced={direct.get('wordSynced')})")
                consider(direct, 'braccato direct')
                _stage('braccato-direct', 'found', direct.get('source', ''))
            else:
                _stage('braccato-direct', 'missed')
        except Exception as e:
            print(f"  [FAIL] braccato-direct stage error (continuing): {e}")
            _stage('braccato-direct', 'error', str(e))
    _fetch_stages.append(_s_direct)

    # Priority 2: LRCLIB (best general line-sync source)
    def _s_lrclib():
        print(f"  [fetch] Trying LRCLIB...")
        _stage('LRCLib', 'started')
        try:
            lrclib_node = pick_node()
            for q in queries:
                try:
                    lrc = fetch_lrclib(q['title'], q['artist'], album, duration, via_node=lrclib_node)
                except Exception as e:
                    print(f"  [FAIL] LRCLIB query error (continuing): {e}")
                    continue
                if not lrc:
                    continue
                if lrc.get('instrumental'):
                    consider({'lyrics': [{'time': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'duration': 0}], 'source': 'LRCLib', 'synced': False}, 'LRCLib instrumental')
                    break
                if lrc.get('synced'):
                    print(f"  [OK] LRCLIB: synced lyrics found! (query: {q['title']})")
                    consider({'lyrics': parse_lrc(lrc['synced'], duration), 'source': 'LRCLib', 'synced': True}, 'LRCLib synced')
                elif lrc.get('plain'):
                    print(f"  [WARN] LRCLIB: plain lyrics only (query: {q['title']})")
                    consider({'lyrics': parse_plain(lrc['plain']), 'source': 'LRCLib', 'synced': False}, 'LRCLib plain')
            _stage('LRCLib', 'done')
        except Exception as e:
            print(f"  [FAIL] LRCLIB stage error (continuing): {e}")
            _stage('LRCLib', 'error', str(e))
    _fetch_stages.append(_s_lrclib)

    # Priority 3: Unison (community; TTML can carry word timing)
    def _s_unison():
        print(f"  [fetch] Trying Unison...")
        _stage('Unison', 'started')
        try:
            unison_node = pick_node()
            for q in queries:
                try:
                    uni = fetch_unison(video_id, q['title'], q['artist'], duration, via_node=unison_node)
                except Exception as e:
                    print(f"  [FAIL] Unison query error (continuing): {e}")
                    continue
                if not uni:
                    continue
                if uni.get('parsed'):
                    print(f"  [OK] Unison: TTML lyrics found! (query: {q['title']})")
                    consider({'lyrics': uni['parsed'], 'source': 'Unison', 'synced': True}, 'Unison TTML')
                elif uni.get('synced'):
                    print(f"  [OK] Unison: synced LRC lyrics found! (query: {q['title']})")
                    consider({'lyrics': parse_lrc(uni['synced'], duration), 'source': 'Unison', 'synced': True}, 'Unison synced')
                elif uni.get('plain'):
                    print(f"  [WARN] Unison: plain lyrics only (query: {q['title']})")
                    consider({'lyrics': parse_plain(uni['plain']), 'source': 'Unison', 'synced': False}, 'Unison plain')
            _stage('Unison', 'done')
        except Exception as e:
            print(f"  [FAIL] Unison stage error (continuing): {e}")
            _stage('Unison', 'error', str(e))
    _fetch_stages.append(_s_unison)

    # Priority 4: AMLL TTML DB (no JWT) -- word-synced TTML via title
    # search + raw-lyrics fetch (beautiful-lyrics-reborn amlldb path).
    def _s_amll():
        print(f"  [fetch] Trying AMLL...")
        _stage('AMLL', 'started')
        try:
            from .providers_amll import fetch_amll
            for q in queries:
                amll = fetch_amll(q['title'], q['artist'], duration)
                if not amll or not amll.get('parsed'):
                    continue
                print(f"  [OK] AMLL: word-synced TTML found! (query: {q['title']})")
                consider({'lyrics': amll['parsed'], 'source': 'AMLL', 'synced': True}, 'AMLL TTML')
                break
            _stage('AMLL', 'done')
        except Exception as e:
            print(f"  [FAIL] AMLL error: {e}")
            _stage('AMLL', 'error', str(e))
    _fetch_stages.append(_s_amll)

    # Priority 5: YouTube Music lyrics
    def _s_youtube():
        print(f"  [fetch] Trying YouTube Music lyrics...")
        _stage('YouTube', 'started')
        try:
            yt = fetch_yt_lyrics(video_id)
            if yt and yt.get('plain'):
                print(f"  [OK] YouTube: plain lyrics found!")
                consider({'lyrics': parse_plain(yt['plain']), 'source': yt.get('source', 'YouTube Music'), 'synced': False}, 'YouTube')
            _stage('YouTube', 'done')
        except Exception as e:
            print(f"  [FAIL] YouTube error: {e}")
            _stage('YouTube', 'error', str(e))
    _fetch_stages.append(_s_youtube)

    # Run every stage concurrently and wait for all of them. Wall time is
    # the slowest stage, not the sum -- no more [1/5]..[4/5] stepping.
    print(f"  [fetch] {len(_fetch_stages)} stages in parallel")
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(_fetch_stages)),
                                               thread_name_prefix='fetch') as _fexec:
        _ffuts = [_fexec.submit(_fn) for _fn in _fetch_stages]
        for _f in concurrent.futures.as_completed(_ffuts):
            try:
                _f.result()
            except Exception as e:
                print(f"  [fetch] stage error: {e}")

    # No lyrics found
    if not result:
        print(f"  [FAIL] No lyrics found from any provider")
        result = {
            'lyrics': [{'time': 0, 'text': f'No lyrics found', 'translated': f'找不到歌詞: {title}', 'duration': 0}],
            'source': 'none', 'synced': False
        }

    # Same lines, better timing: when the winner is line-sync/plain but
    # another tried provider has real word timing for the same lines, graft
    # the word parts onto the winner instead of settling for the lesser tier.
    from .race import _wbw_line_count
    if result and result.get('lyrics') and _wbw_line_count(result) == 0:
        for _label, cand in considered:
            if cand is result or _wbw_line_count(cand) == 0:
                continue
            import copy as _copy
            working = _copy.deepcopy(result['lyrics'])
            if graft_wbw_parts(working, cand.get('lyrics') or []):
                result['lyrics'] = working
                result['synced'] = True
                result['wordSynced'] = True
                result['graftedFrom'] = cand.get('source', '')
                print(f"  [graft] {result.get('source')} + word timing from {cand.get('source')} "
                      f"(score={_lyrics_score(result):.2f})")
                break

    # Add song metadata
    result['song'] = title
    result['artist'] = artist
    # Translation (shared helper -- the background queue uses the same one)
    if translate_to and result.get('lyrics'):
        print(f"  [TRANS] Translating {len(result['lyrics'])} lines with Cohere...")
        from .translate import translate_result_in_place
        translate_result_in_place(result, translate_to)

    if result and result.get('lyrics'):
        sanitize_lyrics_parts(result['lyrics'])

    result['wordSynced'] = any(l.get('wordSynced') for l in (result.get('lyrics') or []))
    _stage('best', 'done', f"{result.get('source', '')} tier="
            f"{'wbw' if result.get('wordSynced') else ('line' if result.get('synced') else 'plain')}")

    return result


def probe_providers(video_id, song_info, jwt_token=None, only_source=None, notes=None, run_id=None, on_candidate=None):
    """Fetch each provider independently and return one candidate per
    provider/format so the dashboard can show every finding and let the admin
    pick which one to cache (not just the default best). Each entry is
    self-contained: {'provider', 'source', 'synced', 'wordSynced', 'tier',
    'lines', 'score', 'data'} where data is the full song-shape dict
    {lyrics, source, synced, wordSynced, song, artist} ready to cache. Sorted
    best-first by the same _lyrics_score used by the race, so the winner that
    fetch_all_lyrics would pick is index 0 -- but nothing is excluded.
    When run_id is given, every provider group also broadcasts a live
    `probe_progress` SSE event (started/found/missed/error/skipped) so the
    dashboard can stream the race. New providers only need their own
    report() calls -- the event shape is fixed.
    Cubey is NOT listed as one provider: its SSE stream is split into its
    inner providers (Musixmatch, QQ, bLyrics, BiniLyrics, NetEase, KuGou),
    each emitted as 'Cubey/<inner>'. only_source accepts an exact key, a
    base name ('qq' matches direct QQ and Cubey/QQ), or legacy 'Cubey' for
    all inner providers. on_candidate(entry) fires per emitted candidate so
    async jobs can stream partial results."""
    from .race import _lyrics_score
    from .providers_braccato import _DIRECT_FETCHERS, _candidate_dict
    from .app import _sse_broadcast

    def report(provider, status, detail=''):
        """Live race line for the dashboard (no-op without run_id). Also
        records the per-provider outcome so later runs know what each
        provider gave (found tier / missed / error / skipped) without
        re-trying. Thread-safe: groups run in parallel."""
        if status != 'started':
            with _probe_lock:
                outcomes[provider] = {'status': status, 'detail': detail or '',
                                      'ts': datetime.now().isoformat()}
        if not run_id:
            return
        try:
            _sse_broadcast('probe_progress', {
                'run_id': run_id, 'video_id': video_id,
                'provider': provider, 'status': status, 'detail': detail or '',
            })
        except Exception:
            pass

    title = song_info['title']
    artist = song_info['artist']
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    queries = get_search_queries(title, artist, song_info.get('ja_title', ''), song_info.get('ja_artist', ''))

    candidates = []
    outcomes = {}
    _probe_lock = threading.Lock()
    print(f"  [probe] {video_id} probing (parallel groups)")

    def emit(logical_provider, label, cand):
        if not cand or not cand.get('lyrics'):
            report(logical_provider, 'missed')
            return
        try:
            sanitize_lyrics_parts(cand['lyrics'])
            lyrics = cand['lyrics']
            synced = bool(cand.get('synced'))
            wbw = bool(cand.get('wordSynced')) or any(l.get('wordSynced') for l in lyrics)
            tier = 'wbw' if wbw else ('line' if synced else 'plain')
            score = _lyrics_score(cand)
        except Exception as e:
            print(f"  [probe] emit {logical_provider} error: {e}")
            report(logical_provider, 'error', str(e))
            return
        with _probe_lock:
            candidates.append({
                'provider': logical_provider,
                'source': cand.get('source') or label,
                'synced': synced,
                'wordSynced': wbw,
                'tier': tier,
                'lines': len(lyrics),
                'score': round(score, 3),
                'data': {
                    'lyrics': lyrics, 'source': cand.get('source') or label,
                    'synced': synced, 'wordSynced': wbw,
                    'song': title, 'artist': artist,
                },
            })
            outcomes[logical_provider] = {'status': 'found', 'tier': tier,
                                          'ts': datetime.now().isoformat()}
            if on_candidate is not None:
                try:
                    on_candidate(candidates[-1])
                except Exception:
                    pass
        report(logical_provider, 'found',
               f"{len(lyrics)} lines {tier} score={round(float(score), 2)}")

    def wants(name):
        if only_source is None:
            return True
        want = only_source.lower()
        low = name.lower()
        if want == low:
            return True
        # 'Cubey' alone means all inner Cubey providers; a base name like
        # 'qq' matches both the direct group and Cubey/<inner>.
        if '/' in low:
            origin, base = low.split('/', 1)
            if want == origin or want == base:
                return True
        return False

    _CUBEY_INNERS = ('Musixmatch', 'QQ', 'bLyrics', 'BiniLyrics', 'NetEase', 'KuGou')

    # Every wanted provider group below runs in parallel (ThreadPoolExecutor
    # at the end); each group owns its exceptions and reports
    # started/found/missed/error/skipped live via report().
    probe_groups = []

    # Cubey API (needs JWT): split into its inner providers, one candidate
    # each -- never a single opaque 'Cubey' entry.
    def _group_cubey():
        _jwt = jwt_token
        try:
            from .providers_cubey import fetch_cubey_all
            if not _jwt:
                _jwt = pick_jwt()
            if not _jwt:
                if notes is not None:
                    with _probe_lock:
                        notes.append('Cubey skipped (no JWT in pool)')
                for inner in _CUBEY_INNERS:
                    if wants(f'Cubey/{inner}'):
                        report(f'Cubey/{inner}', 'skipped', 'no JWT in pool')
            else:
                for inner in _CUBEY_INNERS:
                    if wants(f'Cubey/{inner}'):
                        report(f'Cubey/{inner}', 'started')
                cubey_node = pick_node()
                inner_best = {}
                for q in queries:
                    got = fetch_cubey_all(_jwt, video_id, q['title'], q['artist'], duration, via_node=cubey_node)
                    if not got:
                        continue
                    for inner, raw in got.items():
                        if not wants(f'Cubey/{inner}'):
                            continue
                        if raw.get('parsed'):
                            cand = {'lyrics': raw['parsed'], 'source': raw.get('source', inner), 'synced': True}
                        elif raw.get('synced'):
                            cand = {'lyrics': parse_lrc(raw['synced'], duration), 'source': raw.get('source', inner), 'synced': True}
                        else:
                            continue
                        cur = inner_best.get(inner)
                        if cur is None or _lyrics_score(cand) > _lyrics_score(cur):
                            inner_best[inner] = cand
                for inner in _CUBEY_INNERS:
                    if wants(f'Cubey/{inner}'):
                        emit(f'Cubey/{inner}', inner, inner_best.get(inner))
        except Exception as e:
            print(f"  [probe] Cubey error: {e}")
            for inner in _CUBEY_INNERS:
                if wants(f'Cubey/{inner}'):
                    report(f'Cubey/{inner}', 'error', str(e))
    if any(wants(f'Cubey/{inner}') for inner in _CUBEY_INNERS):
        probe_groups.append(_group_cubey)

    # Direct braccato providers: keep each sub-source visible separately --
    # this is exactly the "check each provider and choose" case (bLyrics TTML,
    # Portato QQ QRC, Legato KuGou LRC, BiniLyrics syllable TTML).
    _LOGICAL = {'ttml': 'bLyrics', 'qq': 'QQ', 'kugou': 'KuGou', 'binimum': 'BiniLyrics'}
    def _direct_one(name, logical):
        report(logical, 'started')
        best = None
        for q in queries:
            fetcher = _DIRECT_FETCHERS[name]
            try:
                raw = fetcher(q['title'], q['artist'], duration, album)
                cand = _candidate_dict(raw, duration, priority=0)
                if cand and (best is None or _lyrics_score(cand) > _lyrics_score(best)):
                    best = cand
            except Exception:
                continue
        emit(logical, logical, best)
    for _dname in list(_DIRECT_FETCHERS.keys()):
        _dlogical = _LOGICAL.get(_dname, _dname)
        if wants(_dlogical):
            probe_groups.append(functools.partial(_direct_one, _dname, _dlogical))

    # LRCLib: one entry (synced beats plain).
    def _group_lrclib():
        report('LRCLib', 'started')
        try:
            from .providers_lrclib import fetch_lrclib
            lrclib_node = pick_node()
            best = None
            for q in queries:
                lrc = fetch_lrclib(q['title'], q['artist'], album, duration, via_node=lrclib_node)
                if not lrc:
                    continue
                if lrc.get('instrumental'):
                    cand = {'lyrics': [{'time': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'duration': 0}], 'source': 'LRCLib', 'synced': False}
                elif lrc.get('synced'):
                    cand = {'lyrics': parse_lrc(lrc['synced'], duration), 'source': 'LRCLib', 'synced': True}
                else:
                    cand = {'lyrics': parse_plain(lrc.get('plain', '')), 'source': 'LRCLib', 'synced': False}
                if best is None or _lyrics_score(cand) > _lyrics_score(best):
                    best = cand
            emit('LRCLib', 'LRCLib', best)
        except Exception as e:
            print(f"  [probe] LRCLib error: {e}")
            report('LRCLib', 'error', str(e))
    if wants('LRCLib'):
        probe_groups.append(_group_lrclib)

    # Unison: one entry (TTML/synced preferred over plain).
    def _group_unison():
        report('Unison', 'started')
        try:
            from .providers_unison import fetch_unison
            unison_node = pick_node()
            best = None
            for q in queries:
                uni = fetch_unison(video_id, q['title'], q['artist'], duration, via_node=unison_node)
                if not uni:
                    continue
                if uni.get('parsed'):
                    cand = {'lyrics': uni['parsed'], 'source': 'Unison', 'synced': True}
                elif uni.get('synced'):
                    cand = {'lyrics': parse_lrc(uni['synced'], duration), 'source': 'Unison', 'synced': True}
                else:
                    cand = {'lyrics': parse_plain(uni.get('plain', '')), 'source': 'Unison', 'synced': False}
                if best is None or _lyrics_score(cand) > _lyrics_score(best):
                    best = cand
            emit('Unison', 'Unison', best)
        except Exception as e:
            print(f"  [probe] Unison error: {e}")
            report('Unison', 'error', str(e))
    if wants('Unison'):
        probe_groups.append(_group_unison)

    # AMLL TTML DB: one entry (word-synced TTML, no JWT).
    def _group_amll():
        report('AMLL', 'started')
        try:
            from .providers_amll import fetch_amll
            best = None
            for q in queries:
                amll = fetch_amll(q['title'], q['artist'], duration)
                if not amll or not amll.get('parsed'):
                    continue
                cand = {'lyrics': amll['parsed'], 'source': 'AMLL', 'synced': True}
                if best is None or _lyrics_score(cand) > _lyrics_score(best):
                    best = cand
                if best and best.get('lyrics') and any(l.get('wordSynced') for l in best['lyrics']):
                    break
            emit('AMLL', 'AMLL', best)
        except Exception as e:
            print(f"  [probe] AMLL error: {e}")
            report('AMLL', 'error', str(e))
    if wants('AMLL'):
        probe_groups.append(_group_amll)

    # YouTube Music: plain only.
    def _group_youtube():
        report('YouTube', 'started')
        try:
            yt = fetch_yt_lyrics(video_id)
            if yt and yt.get('plain'):
                emit('YouTube', yt.get('source', 'YouTube Music'),
                     {'lyrics': parse_plain(yt['plain']), 'source': yt.get('source', 'YouTube Music'), 'synced': False})
            else:
                report('YouTube', 'missed')
        except Exception as e:
            print(f"  [probe] YouTube error: {e}")
            report('YouTube', 'error', str(e))
    if wants('YouTube'):
        probe_groups.append(_group_youtube)

    # Run every wanted group in parallel and wait for all of them. Live
    # started/found/missed/error/skipped events stream per group, so the
    # dashboard shows exactly which provider is probing right now.
    if probe_groups:
        with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(len(probe_groups), 8),
                thread_name_prefix='probe') as _pexec:
            _pfuts = [_pexec.submit(_fn) for _fn in probe_groups]
            for _f in concurrent.futures.as_completed(_pfuts):
                try:
                    _f.result()
                except Exception as e:
                    print(f"  [probe] group error: {e}")

    candidates.sort(key=lambda c: c['score'], reverse=True)
    # Persist the full snapshot (latest wins) so re-race, the device
    # provider switcher, and the dashboard can reuse every provider without
    # re-fetching. Partial (only_source) probes never clobber the full set.
    # outcomes tags each provider (found tier / missed / error / skipped) so
    # the next run skips known misses instead of re-trying them.
    try:
        save_candidates(video_id, song_info, candidates, only_source=only_source,
                        outcomes=outcomes)
    except Exception as e:
        print(f"  [probe] [FAIL] candidate save: {e}")
    return candidates


