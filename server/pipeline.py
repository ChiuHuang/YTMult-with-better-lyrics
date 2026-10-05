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
from .candidates import (save_candidates, graft_wbw_parts,
                          snapshot_provider as _snapshot_provider)
from .nodes import pick_node
from .jwt_pool import pick_jwt
from .latency_stats import record as _latency_record


def _wbw_retry_cubey():
    """Server switch for the not-wbw second Cubey pass. Default ON.

    Read from app_settings rather than an env var because this is an operator
    decision with a per-request cost (one extra Cubey call per song that comes
    back without word timing), not a deployment detail. Fail-open: a settings
    read that raises leaves the feature on, because the pass can only upgrade
    a result."""
    try:
        from .app_settings import flag
        return flag('fetch.wbw_retry_cubey')
    except Exception:
        return True


def _log_wbw_retry(video_id, status, detail=''):
    """One line per song so the dashboard log shows WHY a fetch made two
    Cubey calls; without it a doubled request count is untraceable."""
    print(f"  [wbw-retry] {video_id}: {status}{(' - ' + detail) if detail else ''}")

# ============================================================
# Main Lyrics Pipeline
# ============================================================

# Server-side in-flight dedup
_in_flight = {}  # dedup_key -> threading.Event
_in_flight_lock = threading.Lock()  # protects atomic check-and-register

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
        # Every stage reports through here, so this is the one place that can
        # record an outcome without touching the six provider stages: they
        # already call _stage('X', 'found'|'missed'|'done'|'error'|'skipped').
        # 'done' deliberately does NOT overwrite 'found' -- Cubey calls both,
        # and the later 'done' would otherwise erase the finding.
        if name and status in ('found', 'missed', 'error', 'skipped'):
            try:
                with _fetch_lock:
                    _outcomes[name] = {'status': status, 'detail': detail or ''}
            except Exception:
                pass
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

    from .race import _lyrics_score, _wbw_line_count

    # Latency clock. One clock for the whole fetch, read at three points: the
    # per-song samples at the end, and the time-to-first-tier stamps inside
    # consider() / after the graft. Percentiles live in latency_stats, so the
    # dashboard can answer "how slow is a slow song" without grepping the log.
    _t0 = time_module.perf_counter()
    _ttf = {'line': None, 'wbw': None}  # ms from _t0 to the first hit of each tier

    result = None  # best across providers, decided by score
    considered = []  # every (label, candidate) tried, for wbw graft + saving
    # provider name -> stage outcome. Fed to save_candidates so a later
    # rerace knows which provider gave what WITHOUT re-hitting it: the
    # snapshot's `outcomes` is what makes "skip the known misses" work, and
    # until now only probe_providers wrote it, so every song fetched through
    # this path had its snapshot re-try all four providers that missed.
    _outcomes = {}
    _fetch_lock = threading.Lock()
    _fetch_stages = []  # stage thunks; all run concurrently below

    def consider(candidate, label):
        nonlocal result
        if not candidate or not candidate.get('lyrics'):
            return
        sanitize_lyrics_parts(candidate['lyrics'])
        # Time to first tier, stamped on the FIRST candidate of each kind, not
        # on the winner: the winner is often decided much later (the wbw second
        # Cubey pass, or a graft onto a line-sync result), and it is the arrival
        # time of usable timing that explains the wait. wbw counts as wbw only
        # and not as line -- a song that lands word timing at 4s must not also
        # report ttf_line=4s, or the "how fast do we get line-sync" number
        # silently inherits the slow path it was supposed to measure around.
        try:
            _ms = (time_module.perf_counter() - _t0) * 1000.0
            if _wbw_line_count(candidate) > 0:
                if _ttf['wbw'] is None:
                    _ttf['wbw'] = _ms
            elif candidate.get('synced') and _ttf['line'] is None:
                _ttf['line'] = _ms
        except Exception:
            pass
        with _fetch_lock:
            considered.append((label, candidate))
            if result is None or _lyrics_score(candidate) > _lyrics_score(result):
                result = candidate
                print(f"  [rank] {label}: {candidate.get('source')} now best (score={_lyrics_score(result):.2f})")

    # Priority 0: Cubey API (if we have JWT) -- one pass covers Musixmatch
    # wordByWord/synced, QQ QRC, KuGou LRC, NetEase and the bLyrics/BiniLyrics
    # TTML events, with word-by-word always preferred inside the stream.
    # No request JWT? Fall back to the contributed pool before giving up: the
    # device is not required to wait for its own Turnstile token, so this is
    # the normal path and it says which credential it used (exactly one line
    # per full fetch, never the token itself). pick_jwt only reads RAM -- it
    # cannot block on a probe here.
    jwt_src = 'device'
    _jwt_meta = {}
    if not jwt_token:
        _picked = pick_jwt(with_meta=True)
        # Tolerate a legacy/stubbed pick_jwt that returns the bare token
        # instead of the (token, meta) pair: a bad unpack here would take
        # down every provider stage, not just Cubey.
        if isinstance(_picked, tuple):
            jwt_token = _picked[0] if _picked else None
            _jwt_meta = _picked[1] if len(_picked) > 1 else {}
        else:
            jwt_token = _picked
        jwt_src = 'pool' if jwt_token else 'none'
    try:
        if jwt_src == 'device':
            print(f"  [JWT] device token for {video_id} (pool not consulted)")
        elif jwt_src == 'pool':
            _m = _jwt_meta if isinstance(_jwt_meta, dict) else {}
            _age = int(_m['age_s']) if _m.get('age_s', -1) >= 0 else '?'
            _extra = ' probation=1' if _m.get('probation') else ''
            print(f"  [JWT] pool token for {video_id} (id={_m.get('id') or '?'} age={_age}s "
                  f"successes={_m.get('successes', 0)} fails={_m.get('fails', 0)} "
                  f"last_ok={_m.get('last_ok') or 'never'} "
                  f"verdict={_m.get('verdict') or 'unverified'} "
                  f"pool={_m.get('pool_size', 0)}{_extra})")
        else:
            print(f"  [JWT] no token in pool, Cubey skipped for {video_id}")
    except Exception as e:
        # Logging must never break a fetch.
        print(f"  [JWT] source line failed (continuing): {e}")

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
        # The [JWT] line above already said Cubey is out; keep the stage
        # event (it reaches the device's `status` list) and nothing else.
        _stage('Cubey', 'skipped', 'no JWT in pool and none from the device')

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
                try:
                    amll = fetch_amll(q['title'], q['artist'], duration)
                except Exception as e:
                    print(f"  [FAIL] AMLL query error (continuing): {e}")
                    continue
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
                # Word timing exists now, so this is the real time-to-wbw for a
                # song whose wbw came from a graft rather than from a provider
                # that won on its own. Only filled when nothing was stamped
                # already: consider() runs first and its stamp is the honest
                # arrival time, so overwriting it here would move the number to
                # whenever the graft happened to be tried.
                if _ttf['wbw'] is None:
                    try:
                        _ttf['wbw'] = (time_module.perf_counter() - _t0) * 1000.0
                    except Exception:
                        pass
                print(f"  [graft] {result.get('source')} + word timing from {cand.get('source')} "
                      f"(score={_lyrics_score(result):.2f})")
                break

    # ---- second Cubey pass: two attempts per song, never more ----
    # The first Cubey leg asks for ONE merged answer (fetch_cubey), and
    # _collect_cubey_lines keeps a single best per query. Cubey actually
    # carries SIX independent inner providers, three of which carry real word
    # timing (Musixmatch wordByWord, QQ QRC, bLyrics/BiniLyrics TTML). So a
    # merged best can hide a word-timed inner result that lost on line count
    # or score, and the song lands on line-sync forever. fetch_cubey_all
    # returns them separately, so the second pass can find the wbw result the
    # merge discarded -- and because it also runs on a rotated credential
    # after a short delay, it recovers the transient cases too (one 429, one
    # 15s stream timeout). Every candidate it produces goes through
    # consider(), which re-ranks by the same _lyrics_score and keeps the
    # incumbent unless the newcomer is strictly better -- so this can only
    # improve the tier, and whatever it finds is snapshotted like any other
    # provider (that is the "all providers in the DB" half).
    # race._maybe_cubey_second_pass is the same gate for the SSE race and the
    # background re-race loop, so all three Cubey callers stop at two.
    if (result and result.get('lyrics') and _wbw_line_count(result) == 0
            and _wbw_retry_cubey()):
        try:
            from .providers_cubey import (fetch_cubey_all, cubey_candidate,
                                          second_pass_token, second_pass_delay)
            # A DIFFERENT credential when the pool has one: a device JWT is
            # passed straight in and never demoted, so reusing the token that
            # just answered (or 401'd) is not a second try.
            _jwt2 = second_pass_token(jwt_token)
            if not _jwt2:
                _log_wbw_retry(video_id, 'skipped', 'no JWT in pool')
            else:
                _stage('Cubey-wbw', 'started')
                _node2 = pick_node()
                # Not in the same millisecond as pass 1 -- see
                # providers_cubey.second_pass_delay() (and its setting).
                time_module.sleep(second_pass_delay())
                found = 0
                for q in queries:
                    try:
                        got = fetch_cubey_all(_jwt2, video_id, q['title'],
                                              q['artist'], duration, via_node=_node2)
                    except Exception as e:
                        print(f"  [wbw-retry] Cubey query error (continuing): {e}")
                        continue
                    for inner, raw in (got or {}).items():
                        cand = cubey_candidate(raw, duration, inner)
                        if not cand:
                            continue
                        before = result
                        consider(cand, f'Cubey/{inner}')
                        if result is not before:
                            found += 1
                if found:
                    print(f"  [wbw-retry] {video_id}: adopted a better Cubey "
                          f"result ({result.get('source')})")
                    _log_wbw_retry(video_id, 'done',
                                   f'{found} better candidate(s)')
                else:
                    _log_wbw_retry(video_id, 'done', 'no better Cubey result')
                _stage('Cubey-wbw', 'found' if found else 'missed')
        except Exception as e:
            print(f"  [wbw-retry] {video_id} failed (winner kept): {e}")
            _log_wbw_retry(video_id, 'error', str(e))

    # Snapshot every tried provider (latest wins) so re-race, the device
    # switcher, and later probes reuse all of them without re-fetching.
    # Saved pre-translation (raw lyrics, like probe snapshots); the cached
    # winner above stays the translated/upgraded source of truth.
    try:
        _snap_cands = []
        for _label, _cand in considered:
            _ly = _cand.get('lyrics') or []
            if not _ly:
                continue
            _is_wbw = _wbw_line_count(_cand) > 0
            _src = _cand.get('source', '') or ''
            _prov = _snapshot_provider(_label, _src)
            _snap_cands.append({
                'provider': _prov, 'source': _src,
                'synced': bool(_cand.get('synced')), 'wordSynced': _is_wbw,
                'tier': 'wbw' if _is_wbw else ('line' if _cand.get('synced') else 'plain'),
                'lines': len(_ly), 'score': round(_lyrics_score(_cand), 3),
                'data': {'lyrics': _ly, 'source': _src,
                         'synced': bool(_cand.get('synced')), 'wordSynced': _is_wbw,
                         'song': title, 'artist': artist},
            })
        if _snap_cands:
            _snap_cands.sort(key=lambda c: c['score'], reverse=True)
            # All providers go in, including the ones that lost: the device
            # switcher offers every one of them, and save_candidates only
            # prunes plain entries when db.keep_all_providers is off.
            save_candidates(video_id, {'title': title, 'artist': artist},
                            _snap_cands, outcomes=_outcomes or None)
    except Exception as e:
        print(f"  [fetch] [FAIL] snapshot save: {e}")

    # Add song metadata
    result['song'] = title
    result['artist'] = artist
    # Providers are done: stamp the fetch-only elapsed time HERE, so
    # song_fetch (this) and song (end of function) differ by exactly the
    # translation tail, and not by whatever the snapshot save happened to cost.
    _fetch_ms = (time_module.perf_counter() - _t0) * 1000.0
    # Translation (shared helper -- the background queue uses the same one)
    if translate_to and result.get('lyrics'):
        print(f"  [TRANS] Translating {len(result['lyrics'])} lines with Cohere...")
        from .translate import translate_result_in_place, _detect_song_lang
        translate_result_in_place(result, translate_to,
                                  song_lang=_detect_song_lang(song_info))

    if result and result.get('lyrics'):
        sanitize_lyrics_parts(result['lyrics'])

    result['wordSynced'] = any(l.get('wordSynced') for l in (result.get('lyrics') or []))

    # ---- latency samples ----
    # _fetch_ms was stamped above, right after the last provider did its work;
    # `song` is measured here, so the difference between the two is exactly the
    # translate + sanitize tail. Without that split one number has to describe
    # both "the providers are slow" and "the model is slow", which are different
    # problems with different fixes.
    # Recording happens in this function, not in a route, so the device, the
    # SSE stream, precache, playlist sync, bulk refetch and rebase all land in
    # the same percentiles instead of only the endpoint someone instrumented.
    try:
        _total_ms = (time_module.perf_counter() - _t0) * 1000.0
        _is_wbw = bool(result.get('wordSynced'))
        _tier = 'wbw' if _is_wbw else ('line' if result.get('synced') else 'plain')
        _latency_record('song_fetch', _fetch_ms)
        if is_not_found_result(result):
            # Kept OUT of `song`: a miss is a different population (nothing has
            # these lyrics anywhere) and folding it in would drag the per-song
            # p95 up for every song that did resolve fine.
            _latency_record('miss', _fetch_ms)
        else:
            _latency_record('song', _total_ms)
            _latency_record(f'song_{_tier}', _total_ms)
        if _ttf['line'] is not None:
            _latency_record('ttf_line', _ttf['line'])
        if _ttf['wbw'] is not None:
            _latency_record('ttf_wbw', _ttf['wbw'])
        # One line per fetch so a slow song is traceable from the log alone,
        # not just from the aggregate. Every value is rounded to whole ms -- a
        # perf_counter delta is 55.73279999998704 and nobody reads that. The
        # ttf_* ones carry no unit so a `-` (never reached) does not read as
        # "-ms". ASCII only (the console is cp950).
        _line_t = '-' if _ttf['line'] is None else f"{_ttf['line']:.0f}"
        _wbw_t = '-' if _ttf['wbw'] is None else f"{_ttf['wbw']:.0f}"
        print(f"  [lat] {video_id} tier={_tier} fetch={_fetch_ms:.0f}ms "
              f"total={_total_ms:.0f}ms "
              f"ttf_line={_line_t} ttf_wbw={_wbw_t} "
              f"lines={len(result.get('lyrics') or [])} source={result.get('source', '')}")
    except Exception as e:
        print(f"  [lat] {video_id} sample failed (continuing): {e}")

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
        if status != 'started' and status != 'found':
            # 'found' outcomes (with tier) are recorded by emit() itself;
            # recording here would clobber the tier with a tier-less entry.
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
            _just_emitted = candidates[-1]
        # on_candidate fires outside the lock: a slow consumer must never
        # stall the other probe groups.
        if on_candidate is not None:
            try:
                on_candidate(_just_emitted)
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
                    try:
                        got = fetch_cubey_all(_jwt, video_id, q['title'], q['artist'], duration, via_node=cubey_node)
                    except Exception as e:
                        print(f"  [probe] Cubey query error (continuing): {e}")
                        continue
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
                try:
                    amll = fetch_amll(q['title'], q['artist'], duration)
                except Exception as e:
                    print(f"  [probe] AMLL query error (continuing): {e}")
                    continue
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


