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
from urllib.parse import quote, unquote
import secrets as _secrets
import uuid
import traceback
import atexit
import logging
from .parsers_lrc import last_part_duration_ms
from .paths import LYRICS_DIR, ensure_data_dir

# ============================================================
# Cache
# ============================================================

def is_not_found_result(data):
    """Check if result represents an empty or not found state."""
    if not data:
        return True
    source = data.get('source')
    lyrics = data.get('lyrics', [])
    if source in ['none', 'error'] or not lyrics:
        return True
    if len(lyrics) == 1 and 'No lyrics found' in lyrics[0].get('text', ''):
        return True
    return False

# Bump when parser/postprocess output format changes so stale on-disk
# entries (mojibake, wrong last-word timing, fake wbw) are invalidated once.
#
# v4: the TTML parser started preferring the declared `<text for>` line over a
# join of the timed spans (19c5d2c), because those spans are split FINER than
# words and joined into "Through the sha dow s of de s pair". Every entry on
# disk from before that still carries the pre-fix `text`, and get_cached only
# ever compared `v`, so the fix never reached a cached song. This bump is what
# makes it reach one.
#
# A bump is NOT sufficient on its own: the provider snapshots in
# `database/candidates` hold the same raw text and are written back into the
# main cache by /providers/select, so they carry their own version
# (`_SNAPSHOT_VERSION` in candidates.py) which must be bumped in the same change.
_CACHE_FORMAT_VERSION = 4

# THE OTHER HALF OF THE VERSION, and the one a bump cannot fake.
#
# `_CACHE_FORMAT_VERSION` says "the shape of the stored record changed".
# `_PARSER_EPOCH` says "the TEXT was derived by a different set of parsers".
# They are not interchangeable: postprocess_lyrics/sanitize_lyrics_parts below
# are pure functions of already-parsed lyrics, so a postprocess fix can be
# replayed over every entry on disk with no network and no source file. A
# parser fix cannot -- the entry holds the parser's OUTPUT, and the only other
# copy on disk (`database/candidates`) holds the same parsed output.
#
# So every entry written by this build stamps the current epoch, and an entry
# whose epoch is missing or older is parser-stale: the offline sweep in
# db_migrate.py may repair and re-stamp it, but it must NOT claim the epoch,
# or the one gate that says "this text still needs a refetch" goes blind --
# exactly the failure nodes.py just had.
#
# Bump this whenever a file in parsers_*.py changes its output.
# 2: parsers_ttml.py stopped calling p.iter('span') and started walking direct
#    children by ttm:role. Every TTML line's text and parts can change: an
#    x-bg cue leaves the vocal line and arrives as `bg`, spacing now comes from
#    the real whitespace text nodes instead of the has_gap/is_cjk guess, ruby
#    stops arriving as extra words, and a <p> with no begin is no longer
#    dropped. None of that is replayable offline -- the entry holds the parser's
#    output -- so every TTML-derived entry is parser-stale and wants a refetch.
# 3: parsers_lrc.py learned the LySy `[bg:...]` background group and drops CJK
#    credit lines; parsers_qrc.py learned the `Name:` singer prefix (voice
#    attribution, which the duet feature had zero data for), the
#    <QrcInfos LyricContent="..."> envelope, CJK credit roles and the
#    title-echo drop. Every QRC line from QQ can now carry `singer`/`duet`, and
#    an LRC line with a second voice no longer has it sung by the first.
# 4: sanitize_lyrics_parts takes a reading out of a trailing `base（reading）`,
#    in the line text AND in every part's `words` -- which is the copy the device
#    rebuilds the display string from. Rubies written inline were being drawn as
#    a second copy of the line in brackets and, because the wipe indexes by part,
#    the bracket run became karaoke words of its own. The reading is kept as
#    `ruby` / `inlineReading`. Replayable offline, but bumped anyway: the epoch
#    is what makes every stored entry refetch, and a stale entry is exactly what
#    the device was drawing.
_PARSER_EPOCH = 4

# ---------------------------------------------------------------------------
# A reading written inline, in parentheses: ぎゅって抱いた空（ぎゅたて抱いた空）
# ---------------------------------------------------------------------------
# Why this is here and not in a parser. The device REBUILDS the display string
# from `parts` (LyricsSheet's -wbwDisplayTextForLyric), so whatever a provider
# writes inside a part's `words` is what the phone draws, character for character.
# Files that cannot typeset furigana write it inline instead, and the device
# screenshots showed the result: the line printed its own reading a second time in
# brackets, and -- because the wipe indexes by part -- the bracket run became
# karaoke words of their own, so the highlight ran backwards through the line
# (white, grey, then white again) and lit the reading before the base.
#
# The rules are deliberately narrow, because a trailing parenthesis is ordinary
# text in a song title and eating it would be worse than the bug:
#   * the group has to be TRAILING and balanced (one pair, nothing after it);
#   * the base has to contain a kanji/kana syllable it could be read for;
#   * the reading has to be kana only (kanji readings do exist, but those are
#     alternative WORDINGS, e.g. 空（から）, and are kept -- see below).
# A reading made of kanji, or one that repeats the base, is left alone.

_TRAILING_PAREN_RE = re.compile(r'^(?P<base>.*?)[（(]\s*(?P<reading>[^（()（）]+?)\s*[)）]\s*$')
# Kana only -- hiragana, katakana, the small-kana extension, the prolonged sound
# mark, the katakana middle dot, and spaces. Nothing else, and in particular no
# Latin, no digits and NO kanji: a hanzi in the group means it is not a reading.
_READING_CHARS_RE = re.compile(r'^[\u3040-\u30ff\u31f0-\u31ff\u00b7\s]+$')
_HAS_KANJI_RE = re.compile(r'[\u3400-\u9fff]')


def _is_reading_of(base, reading):
    """True when `reading` is a reading OF `base`, by one of two shapes.

    (a) kana only -- `空（そら）`, the ordinary syllabic reading;
    (b) the base with its kanji readings spelled out in kana --
        `ぎゅって抱いた空（ぎゅたて抱いた空）`, which is what a file writes when it
        cannot typeset furigana over a whole phrase rather than over syllables.
        For (b) every kanji in the group must be one the base already has, and
        there cannot be more of them than the base has: a group that ADDS a kanji
        is a gloss or a different phrase, which is the case that must survive.
    """
    if _READING_CHARS_RE.match(reading):
        return True
    base_kanji = [c for c in base if _HAS_KANJI_RE.match(c)]
    if not base_kanji:
        return False
    group_kanji = [c for c in reading if _HAS_KANJI_RE.match(c)]
    if len(group_kanji) > len(base_kanji):
        return False
    return all(c in base_kanji for c in group_kanji)


def split_inline_reading(text):
    """`base（reading）` -> ('base', 'reading'). Anything else -> (text, None).

    Returns the pair unchanged when the parentheses are not a reading: a group
    with characters the base does not have, a group that repeats the base
    verbatim, or a base with no kanji in it (you cannot read らららん, and
    `らららん（啦啦啦啦）` is a translation, not a reading).
    """
    if not text:
        return text, None
    m = _TRAILING_PAREN_RE.match(text)
    if not m:
        return text, None
    base = m.group('base').strip()
    reading = m.group('reading').strip()
    if not reading:
        return text, None
    if not base:
        # Nothing to read it FOR: a part that is nothing but a reading (a hum, a
        # doubled syllable) or a bracketed kana sound. The parentheses were never
        # content, so unwrap rather than claim a ruby with no base.
        if _READING_CHARS_RE.match(reading):
            return reading, None
        return text, None
    if reading == base:
        return text, None
    if not _HAS_KANJI_RE.search(base):
        return text, None
    if not _is_reading_of(base, reading):
        return text, None
    # A reading is never longer than what it reads, by more than the marks that
    # stretch a syllable out (ー, っ). Anything longer is a gloss.
    if len(reading) > len(base) + 2:
        return text, None
    return base, reading


def sanitize_lyrics_parts(lyrics):
    """Ensure every line has valid, monotonically increasing parts with proper durations and spaces.
    Never interpolate fake wbw parts from line-by-line (LBL) lyrics."""
    if not lyrics:
        return
    for l in lyrics:
        if not l.get('text'):
            continue
        # The line text first, and for EVERY line including the non-word-synced
        # ones: an LBL file carries the same inline reading with no parts at all,
        # and the phone draws `text` verbatim when there are no parts. Cleaning it
        # here also means the translator is never handed the brackets -- the
        # duplicated reading in the Chinese line was the model copying them.
        _base, _reading = split_inline_reading(l['text'])
        if _base != l['text']:
            l['text'] = _base
        if _reading:
            l['inlineReading'] = _reading
        l_ms = int(l.get('startTimeMs', l.get('time', 0) * 1000))
        l_dur = int(l.get('durationMs', l.get('duration', 0) * 1000))
        parts = l.get('parts')
        # If line is not genuinely word-synced, do not attach or retain parts
        if not l.get('wordSynced') or not parts or len(parts) <= 1:
            l.pop('parts', None)
            l['wordSynced'] = False
            continue

        prev_ms = l_ms
        for pi, p in enumerate(parts):
            # Same reading-out of every part's own text, for the reason above: the
            # device rebuilds the line from these strings, so this is the copy the
            # phone actually draws. The reading is kept on the part as `ruby`, the
            # shape _ruby_element already emits, so the two spellings of furigana
            # arrive at the device as one thing.
            _pbase, _preading = split_inline_reading(p.get('words') or '')
            if _pbase != p.get('words'):
                p['words'] = _pbase
            if _preading:
                p['ruby'] = [{'text': _preading,
                              'startTimeMs': p.get('startTimeMs', 0),
                              'durationMs': p.get('durationMs', 0)}]
            if not p.get('startTimeMs') or p['startTimeMs'] < l_ms:
                p['startTimeMs'] = prev_ms + (0 if pi == 0 else 200)
            prev_ms = p['startTimeMs']
        # A part can be left with nothing but a reading, i.e. no drawable text at
        # all. Drop those and re-apply the >=2 rule, because one word is not
        # karaoke -- the device's wipe has no second word to move to.
        parts = [p for p in parts if (p.get('words') or '').strip()]
        if len(parts) <= 1:
            l.pop('parts', None)
            l['wordSynced'] = False
            continue
        l['parts'] = parts
        # Preserve real provider durations; only synthesize missing ones
        # or clamp bloated last-word durations that stretch into the inter-line gap.
        for pi in range(len(parts)):
            if pi < len(parts) - 1:
                if not parts[pi].get('durationMs'):
                    dur = parts[pi+1]['startTimeMs'] - parts[pi]['startTimeMs']
                    parts[pi]['durationMs'] = max(dur, 0)
            else:
                raw_dur = parts[pi].get('durationMs', 0)
                prior_durs = [p.get('durationMs', 0) for p in parts[:-1] if (p.get('durationMs') or 0) > 0]
                avg_prior = (sum(prior_durs) / len(prior_durs)) if prior_durs else 400
                if raw_dur <= 0 or (raw_dur > 2000 and raw_dur > avg_prior * 2.0):
                    parts[pi]['durationMs'] = last_part_duration_ms(
                        parts[pi]['startTimeMs'], l_ms, l_dur, prior_parts=parts[:-1])

def _cache_filename(key):
    """Windows-safe on-disk name for a logical cache key. Logical keys are
    "vid:lang" / "vid:lang:fast"; colons are illegal to *enumerate* on NTFS
    (they become alternate-data-stream names, so os.listdir/glob only see a
    bare base file). Percent-encoding keeps every file listable and is fully
    reversible for the dashboard/list nodes."""
    return quote(key, safe='')


def _cache_key_from_filename(fname):
    """Reverse of _cache_filename: 'dQw%3Azh-TW.json' -> 'dQw:zh-TW'."""
    if not fname.endswith('.json'):
        return None
    return unquote(fname[:-5])


def get_cached(video_id):
    path = os.path.join(LYRICS_DIR, _cache_filename(video_id) + '.json')
    if os.path.exists(path):
        try:
            with open(path, 'r', encoding='utf-8') as f:
                entry = json.load(f)
            if entry.get('v') != _CACHE_FORMAT_VERSION:
                return None
            # The SECOND gate, and the one the epoch bookkeeping exists for.
            # db_migrate.py re-stamps a parser-stale entry with the current
            # format version but deliberately does NOT claim the current epoch
            # (see stamp_entry's parser_epoch=None, and its header: "re-stamped
            # WITHOUT claiming the epoch, so the gate that produced this list
            # stays true after the sweep instead of going blind"). That is only
            # true if something refuses a stale epoch on the serving path, and
            # until now nothing did: `v` matched, so the entry was served with
            # the exact pre-fix text the bump was meant to retire, permanently.
            # Candidates already gated on pv (candidates.py); the lyrics path
            # did not, so the two stores disagreed about what "current" means.
            #
            # A MISSING pv counts as stale, deliberately. Every entry written
            # before the epoch split lacks the field, and there is no way to
            # tell from disk whether its text came from the parsers we have
            # since fixed -- so it gets refetched. That is the honest cost of a
            # parser fix, and it is why the sweep reports needs_refetch instead
            # of claiming an epoch it cannot prove.
            if entry.get('pv') != _PARSER_EPOCH:
                return None
            data = entry.get('data')
            if is_not_found_result(data):
                return None
            if data and data.get('lyrics'):
                sanitize_lyrics_parts(data['lyrics'])
                postprocess_lyrics(data['lyrics'], data.get('duration', 0))
            ts = datetime.fromisoformat(entry['ts'])
            if (datetime.now() - ts).total_seconds() < 86400 * 3:
                return data
        except:
            pass
    return None

def is_parser_stale(key):
    """True when a cache FILE exists for `key` but get_cached() refuses it.

    The distinction matters and nothing else in the tree can make it. "There is
    no cache for this song" and "there is a cache whose text an older
    parsers_*.py produced" both look identical to every caller, because
    get_cached() returns None for both -- and they need OPPOSITE handling: the
    first is normal (fetch fresh), the second is what a parser bump creates and
    re-racing cannot repair, because re-racing needs the old payload to compare
    against and that is precisely what was withheld.

    Reads the file rather than asking the gate, so it stays correct if the gate
    ever grows a third reason to refuse.
    """
    path = os.path.join(LYRICS_DIR, _cache_filename(key) + '.json')
    if not os.path.exists(path):
        return False
    try:
        with open(path, 'r', encoding='utf-8') as f:
            entry = json.load(f)
    except Exception:
        return False
    return entry.get('pv') != _PARSER_EPOCH


def set_cached(video_id, data):
    if is_not_found_result(data):
        return
    if data and data.get('lyrics'):
        postprocess_lyrics(data['lyrics'], data.get('duration', 0))
    path = os.path.join(LYRICS_DIR, _cache_filename(video_id) + '.json')
    try:
        os.makedirs(LYRICS_DIR, exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            # `pv` is stamped HERE, not by the caller: everything reaching this
            # function was parsed by the parsers in THIS build, including a
            # node's payload (nodes.py only forwards one after checking its
            # `cv` is our exact int, so it carries the same trust as `v`).
            json.dump({'v': _CACHE_FORMAT_VERSION, 'pv': _PARSER_EPOCH,
                       'data': data, 'ts': datetime.now().isoformat()},
                      f, ensure_ascii=False)
        try:
            from .app import _sse_broadcast
            _sse_broadcast('cache', {'video_id': video_id, 'song': data.get('song', ''), 'artist': data.get('artist', ''), 'source': data.get('source', ''), 'synced': data.get('synced', False)})
        except Exception:
            pass
    except:
        pass


def read_entry(key):
    """Raw on-disk entry {v, pv, data, ts} for a cache key.

    Deliberately bypasses BOTH gates in get_cached (the version check and the
    3-day TTL), because the sweep in db_migrate.py exists to read exactly the
    entries those two hide: `get_cached` returning None for a stale version is
    the same None it returns for "never fetched", so a migration could not tell
    them apart. Returns None when the file is missing or unreadable.
    """
    path = os.path.join(LYRICS_DIR, _cache_filename(key) + '.json')
    try:
        with open(path, 'r', encoding='utf-8') as f:
            entry = json.load(f)
    except Exception:
        return None
    if not isinstance(entry, dict):
        return None
    return entry


def stamp_entry(key, data, ts=None, parser_epoch=None):
    """Write a migrated entry: current format version, an optional PRESERVED
    ts, and an explicit parser epoch.

    Preserving ts matters: a migration that stamps `now` makes every song in
    the library look freshly fetched, which resets the TTL on entries nobody
    verified and rewrites the recency order the Library page is sorted by.
    `parser_epoch=None` means "leave it alone" -- pass the OLD value when the
    text was not re-derived, so needs-refetch stays true after the sweep.
    Returns True on write. Never raises."""
    path = os.path.join(LYRICS_DIR, _cache_filename(key) + '.json')
    if data and data.get('lyrics'):
        postprocess_lyrics(data['lyrics'], data.get('duration', 0))
    prev = read_entry(key) or {}
    epoch = prev.get('pv', 0) if parser_epoch is None else parser_epoch
    try:
        os.makedirs(LYRICS_DIR, exist_ok=True)
        tmp = path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump({'v': _CACHE_FORMAT_VERSION, 'pv': epoch, 'data': data,
                       'ts': ts or prev.get('ts') or datetime.now().isoformat()},
                      f, ensure_ascii=False)
        os.replace(tmp, path)
        return True
    except Exception:
        return False

def clear_not_found_caches():
    if not os.path.exists(LYRICS_DIR):
        return
    removed = 0
    for fname in os.listdir(LYRICS_DIR):
        if _cache_key_from_filename(fname) is not None:
            fpath = os.path.join(LYRICS_DIR, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    entry = json.load(f)
                if is_not_found_result(entry.get('data')):
                    os.remove(fpath)
                    removed += 1
            except Exception:
                pass
    if removed > 0:
        print(f"[CLEAN] Cleaned {removed} empty/not-found cache files at startup.")


# -------------------------------------------------------------------
# Lyrics post-processing (mirrors iOS tweak n_ pipeline)
# -------------------------------------------------------------------
def postprocess_lyrics(lyrics, duration_s=0):
    if not lyrics:
        return lyrics
    duration_ms = int(duration_s * 1000) if duration_s > 0 else 0
    _merge_spaces(lyrics)
    _fudge_short_durations(lyrics)
    _fix_zero_durations(lyrics, duration_ms)
    _fix_last_word_durations(lyrics)
    _insert_instrumental_gaps(lyrics, duration_ms)
    return lyrics


def _merge_spaces(lyrics):
    """Merge tiny-duration spaces into adjacent words."""
    for line in lyrics:
        parts = line.get('parts')
        if not parts or len(parts) < 2:
            continue
        i = 1
        while i < len(parts):
            cur = parts[i]
            prev = parts[i - 1]
            if cur.get('words') == ' ' and prev.get('words') != ' ':
                diff = abs((cur.get('durationMs') or 0) - (prev.get('durationMs') or 0))
                cur_dur = cur.get('durationMs') or 0
                if diff <= 15 or cur_dur <= 100:
                    prev['durationMs'] = (prev.get('durationMs') or 0) + cur_dur
                    cur['durationMs'] = 0
                    cur['startTimeMs'] = (cur.get('startTimeMs') or 0) + cur_dur
                    parts.pop(i)
                    continue
            i += 1


def _fudge_short_durations(lyrics):
    """If >50% of non-space words have duration <=100ms, redistribute."""
    for line in lyrics:
        parts = line.get('parts')
        if not parts:
            continue
        non_space = [p for p in parts if p.get('words') != ' ']
        if len(non_space) < 3:
            continue
        short = sum(1 for p in non_space if (p.get('durationMs') or 0) <= 100)
        if short / len(non_space) <= 0.5:
            continue
        for p in parts:
            dur = p.get('durationMs') or 0
            if p.get('words') != ' ' and dur <= 400:
                idx = parts.index(p)
                nxt = parts[idx + 1] if idx + 1 < len(parts) else None
                if nxt and nxt.get('words') == ' ':
                    p['durationMs'] = dur + (nxt.get('durationMs') or 0)
                    nxt['startTimeMs'] = (nxt.get('startTimeMs') or 0) + (nxt.get('durationMs') or 0)
                    nxt['durationMs'] = 0
                elif nxt:
                    gap = (nxt.get('startTimeMs') or 0) - (p.get('startTimeMs') or 0)
                    p['durationMs'] = max(gap, 300) if gap > 0 else 300
                else:
                    p['durationMs'] = 300


def _fix_zero_durations(lyrics, duration_ms):
    """Fix lines with 0 total duration."""
    for i, line in enumerate(lyrics):
        d = line.get('durationMs') or 0
        if d > 0:
            continue
        if i + 1 < len(lyrics):
            next_start = lyrics[i + 1].get('startTimeMs') or 0
            line_start = line.get('startTimeMs') or 0
            line['durationMs'] = max(next_start - line_start, 3000)
        elif duration_ms > 0:
            line_start = line.get('startTimeMs') or 0
            line['durationMs'] = max(duration_ms - line_start, 3000)


def _fix_last_word_durations(lyrics):
    """Fix 0-duration or bloated last words in each line (end at natural singing duration,
    never stretched to the next line's start)."""
    for i, line in enumerate(lyrics):
        parts = line.get('parts')
        if not parts:
            continue
        last = parts[-1]
        raw_dur = last.get('durationMs') or 0
        prior_durs = [p.get('durationMs', 0) for p in parts[:-1] if (p.get('durationMs') or 0) > 0]
        avg_prior = (sum(prior_durs) / len(prior_durs)) if prior_durs else 400
        if raw_dur > 0 and not (raw_dur > 2000 and raw_dur > avg_prior * 2.0):
            continue
        line_start = line.get('startTimeMs') or 0
        if i + 1 < len(lyrics):
            next_start = lyrics[i + 1].get('startTimeMs') or 0
        else:
            next_start = None
        line_dur = line.get('durationMs') or 0
        if line_dur <= 0 and next_start is not None:
            line_dur = max(next_start - line_start, 3000)
        last_start = last.get('startTimeMs') or 0
        if line_dur <= 0:
            last['durationMs'] = 150
        else:
            last['durationMs'] = last_part_duration_ms(last_start, line_start, line_dur, next_start, prior_parts=parts[:-1])


def _insert_instrumental_gaps(lyrics, duration_ms):
    """Insert instrumental markers for gaps >5s between lines."""
    if len(lyrics) < 2:
        return
    instrumental = lambda start, dur: {
        'startTimeMs': start, 'durationMs': dur, 'text': '[instrumental]',
        'parts': [{'startTimeMs': start, 'durationMs': dur, 'words': '[instrumental]'}],
        'isInstrumental': True
    }
    i = 0
    while i < len(lyrics) - 1:
        end = (lyrics[i].get('startTimeMs') or 0) + (lyrics[i].get('durationMs') or 0)
        nxt_start = lyrics[i + 1].get('startTimeMs') or 0
        gap = nxt_start - end
        if gap > 5000:
            lyrics.insert(i + 1, instrumental(end, gap))
            i += 2
        else:
            i += 1


