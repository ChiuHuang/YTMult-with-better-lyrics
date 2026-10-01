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
# ============================================================
# QQ QRC Parser (word-by-word, ms precision)
# QRC lines: [lineStartMs,lineDurMs]word (offMs,durMs)word (offMs,durMs)...
# Each word's text PRECEDES its timing group; offsets are absolute ms in
# practice (treated as relative when below the line start). Cubey
# double-encodes the payload: results["lyrics"] is a JSON string holding
# {"lyrics": "<QrcInfos.../>", "provider": "qq"}.
# Output is enhanced LRC so the standard parse_lrc path (wordSynced=True)
# handles parts/timing downstream with no special cases.
# ============================================================

from .parsers_credits import is_credit_role, string_similarity

# Kept because it catches one shape the credit recognizer deliberately does
# not: a credit with no colon at all ("Lyrics by Someone" on its own line),
# which is not a credit LINE by the colon rule.
_QRC_CREDIT_RE = re.compile(r'\b(lyrics|composed|arranged|produced|written|vocals?|chorus|mixed|mastered)\s*by\b', re.I)

# QQ Music serves QRC inside an XML envelope with the body hidden in a
# LyricContent attribute. A bare body passes through untouched, which is what a
# caller holding an already-unwrapped document has.
_QRC_ENVELOPE_RE = re.compile(r'LyricContent="([\s\S]*?)"\s*(?:/?>|[a-zA-Z]+=)')

# QQ prefixes a line with the singer's name and a colon, and that name is the
# ONLY voice attribution a QQ lyric carries. `合` / `ALL` / `合唱` mean every
# voice at once, which maps onto our `duet` flag.
_QRC_GROUP_SINGERS = ('合', 'ALL', '合唱')


def _unwrap_qrc_envelope(blob):
    """Peel `<QrcInfos LyricContent="..."/>` and unescape it.

    The previous version handled Cubey's JSON envelope and a bare `{...}`, but
    not this one, so a provider that returns the real QQ XML lost every line.
    """
    if not isinstance(blob, str):
        return blob
    m = _QRC_ENVELOPE_RE.search(blob)
    if not m:
        return blob
    return (m.group(1).replace('&quot;', '"').replace('&amp;', '&')
            .replace('&lt;', '<').replace('&gt;', '>'))


def _qrc_singer_agent(name, alias_map, state):
    """xml:id for a singer name, allocating v1..vN or the group id v1000."""
    if name not in alias_map:
        group = name.upper() in _QRC_GROUP_SINGERS
        alias_map[name] = 'v1000' if group else 'v%d' % state['next_voice']
        if not group:
            state['next_voice'] += 1
    return alias_map[name]

def _qrc_tag(ms, bracket=True):
    ms = max(int(ms), 0)
    tag = f"{ms // 60000:02d}:{(ms % 60000) // 1000:02d}.{(ms % 1000) // 10:02d}"
    return f"[{tag}]" if bracket else f"<{tag}>"

def _is_cjk_char(c):
    # Mirrors is_cjk() in parsers_lrc.py, extended with Katakana Phonetic
    # Extensions (31F0-31FF), Halfwidth Katakana (FF61-FF9F), CJK
    # Symbols/Punctuation (3000-303F) and CJK Extension A (3400-4DBF).
    o = ord(c)
    return ((0x4E00 <= o <= 0x9FFF) or (0x3040 <= o <= 0x30FF) or
            (0x31F0 <= o <= 0x31FF) or (0xFF61 <= o <= 0xFF9F) or
            (0x3000 <= o <= 0x303F) or (0x3400 <= o <= 0x4DBF))


def _qrc_join_words(words):
    """CJK-aware join: no space when both boundary chars are CJK."""
    out = ''
    for i, w in enumerate(words):
        if i > 0:
            prev = out[-1] if out else ''
            nxt = w[0] if w else ''
            if not (prev and nxt and _is_cjk_char(prev) and _is_cjk_char(nxt)):
                out += ' '
        out += w
    return out


def _qrc_strip_cjk_spaces(text):
    """Drop spaces sitting between two CJK chars; keep other spacing."""
    res = []
    n = len(text)
    for i, ch in enumerate(text):
        if ch == ' ':
            prev = res[-1] if res else ''
            nxt = text[i + 1] if i + 1 < n else ''
            if prev and nxt and _is_cjk_char(prev) and _is_cjk_char(nxt):
                continue
        res.append(ch)
    return ''.join(res)


def _qrc_clean_text(text):
    text = re.sub(r'\s+([.,!?;:\'")\]}])', r'\1', text)
    text = re.sub(r'([(\["\'])\s+', r'\1', text)
    text = re.sub(r'\s+', ' ', text)
    return _qrc_strip_cjk_spaces(text).strip()

def _qrc_split_words(line_start, seg):
    """Extract (text, start_ms, dur_ms) triples from a QRC line segment."""
    els = re.split(r'\((\d+),(\d+)\)', seg)
    n = (len(els) - 1) // 3
    words = []
    for k in range(1, n + 1):
        txt = els[3 * k - 3].strip()
        if not txt:
            continue
        off, dur = int(els[3 * k - 2]), int(els[3 * k - 1])
        start = off if off >= line_start else line_start + off
        words.append((txt, start, max(dur, 1)))
    return words


def _qrc_take_singer_prefix(words, text, alias_map, state):
    """Strip a leading `Name:` off a QRC line and record who is singing.

    QQ Music is the only attribution a QQ lyric carries, and we were dropping it
    on the floor: a duet came out with every line marked as one voice, so the
    duet alignment feature had nothing to align. Two shapes exist and both have
    to work:

      `[start,dur]周杰伦(0,300)hello(300,300)`     the whole line is a name tag
      `[start,dur]周杰伦(0,300)：(300,200)你(500,300)好`  the colon lands mid-syllable

    The name is taken from the accumulated syllables rather than from the joined
    text, because in the second shape the colon falls inside a syllable and a
    regex over the text would either miss it or cut a word in half.

    Returns (words, text). `state['current']` carries the singer onto the lines
    that follow, which is what QQ means by naming them once.
    """
    if not words:
        return words, text

    acc = ''
    consumed = 0
    for syl in words:
        acc += syl[0]
        consumed += 1
        if ':' in acc or '：' in acc:
            break
        if len(acc) > 40:
            return words, text

    # Whole line is `Name:` and nothing else.
    whole = re.match(r'^([^:：]+)\s*[:：]\s*$', acc)
    if whole:
        name = whole.group(1).strip()
        if is_credit_role(name):
            return None, None          # a credit line, not a lyric
        if len(name) > 30:
            return words, text         # too long to be a name; leave it alone
        rest = words[consumed:]
        if not rest:
            return None, None
        state['current'] = _qrc_singer_agent(name, alias_map, state)
        return rest, _qrc_clean_text(_qrc_join_words([w for w, _, _ in rest]))

    # `Name: lyrics...` with content after the colon.
    prefix = re.match(r'^([^:：]+)\s*[:：]\s*([\s\S]*)$', acc)
    if not prefix:
        if state['current']:
            pass                      # keep the carried singer; nothing to strip
        return words, text
    name = prefix.group(1).strip()
    after_colon = prefix.group(2) or ''
    if is_credit_role(name):
        return None, None
    if len(name) > 20:
        return words, text

    colon_idx = consumed - 1
    colon_syl = words[colon_idx]
    tail = re.search(r'[:：]\s*([\s\S]*)$', colon_syl[0])
    remainder = tail.group(1) if tail else ''
    if remainder:
        trimmed = list(words)
        trimmed[colon_idx] = (remainder, colon_syl[1], colon_syl[2])
        rest = trimmed[colon_idx:]
    else:
        rest = words[consumed:]

    state['current'] = _qrc_singer_agent(name, alias_map, state)
    return rest, _qrc_clean_text(after_colon or
                                 _qrc_join_words([w for w, _, _ in rest]))


def parse_qrc_structured(blob):
    """Convert QQ QRC payload straight to structured lyric entries, keeping
    the real per-word durations and the real line duration so the last word
    of every line ends where the line itself ends -- never stretched to the
    next line's start.

    Returns a list of entries shaped like parse_lrc output on success, or [].
    Each entry: {time, startTimeMs, text, durationMs, duration, parts, wordSynced}\n    parts: [{startTimeMs, words, durationMs}, ...]
    """
    if isinstance(blob, dict):
        blob = blob.get('lyrics', '')
    if not isinstance(blob, str) or not blob:
        return []
    # Peel Cubey's inner JSON envelope when present
    s = blob.strip()
    if s.startswith('{'):
        try:
            inner = json.loads(s)
            if isinstance(inner, dict) and inner.get('lyrics'):
                s = inner['lyrics']
        except Exception:
            pass
    if not isinstance(s, str) or not s:
        return []
    s = _unwrap_qrc_envelope(s)
    # Tolerate partially-decoded escapes
    if '\\n' in s and '\n' not in s:
        s = s.replace('\\n', '\n')
    # Title text (ti:) marks the header line to drop (it carries timed words)
    ti_match = re.search(r'\[ti:(.*?)\]', s)
    ti_text = _qrc_clean_text(ti_match.group(1)) if ti_match else ''

    # Voice attribution state, carried across lines the same way braccato does
    # it: QQ names the singer once and every line after it belongs to them
    # until the next name appears.
    alias_map = {}
    singer_state = {'next_voice': 1, 'current': None}

    out = []
    for m in re.finditer(r'\[(\d+),(\d+)\]([^\[]*)', s):
        line_start, line_dur = int(m.group(1)), int(m.group(2))
        seg = m.group(3)
        words = _qrc_split_words(line_start, seg)
        if not words:
            continue  # metadata ([ti:]/[ar:]/[offset:]) or wordless line
        text = _qrc_clean_text(_qrc_join_words([w for w, _, _ in words]))
        if not text:
            continue
        if ti_text and ti_text in text:
            continue
        if _QRC_CREDIT_RE.search(text) or is_credit_role(text.split(':', 1)[0]
                                                          if ':' in text else ''):
            continue
        # A line that just echoes the song title is a header, not a lyric. The
        # ti: containment test above only catches an exact repeat; QQ routinely
        # prepends the title plus a word or two, which is what the similarity
        # test is for. Only the opening lines are considered, because a chorus
        # that repeats the title later is a real line.
        if len(out) < 5 and ti_text and string_similarity(text, ti_text) > 0.5:
            continue
        # `Name:` prefix -> voice attribution, and the prefix leaves the text.
        words, text = _qrc_take_singer_prefix(words, text, alias_map, singer_state)
        if not words or not text:
            continue        # the line was only a credit or only a name tag
        line_ms = max(line_dur, 1)
        parts = []
        prev_end = line_start
        for i, (w, start, dur) in enumerate(words):
            s_ms = max(start, prev_end)
            dur_ms = max(dur, 1)
            is_last = (i == len(words) - 1)
            # Keep the word inside the line's own sung span. Only the last
            # word gets shrunk to the line end (never stretched to the next
            # line); earlier words just yield to the next word's start.
            if is_last:
                if s_ms + dur_ms > line_start + line_ms:
                    dur_ms = max(line_start + line_ms - s_ms, 150)
            else:
                nxt_s = words[i + 1][1]
                if s_ms + dur_ms > nxt_s:
                    dur_ms = max(nxt_s - s_ms, 1)
            # Carry inter-word spacing inside the part itself, mirroring the
            # TTML parser (trailing space on non-last Latin words). The
            # braccato preview renderer splits parts on whitespace and drops
            # bare space tokens, so spaceless parts render concatenated
            # ("Flashdrivesawayallsorrows"). iOS trims + rejoins CJK-aware,
            # so trailing spaces are safe there.
            display = w
            if not is_last:
                nxt_w = words[i + 1][0]
                if nxt_w and not (_is_cjk_char(w[-1]) and _is_cjk_char(nxt_w[0])):
                    display = w + ' '
            parts.append({'startTimeMs': s_ms, 'words': display, 'durationMs': dur_ms})
            prev_end = s_ms + dur_ms
        entry = {
            'time': round(line_start / 1000.0, 3),
            'startTimeMs': line_start,
            'text': text,
            'durationMs': line_ms,
            'duration': round(line_ms / 1000.0, 3),
            'parts': parts,
            'wordSynced': True,
        }
        # Voice attribution, in the same vocabulary the TTML parser emits, so
        # the device has one duet code path: `singer` is an index into the
        # voices this document names, `duet` marks the everyone-at-once agent.
        agent = singer_state.get('current')
        if agent:
            if agent == 'v1000':
                entry['duet'] = True
            else:
                try:
                    entry['singer'] = int(agent[1:]) - 1
                except (ValueError, IndexError):
                    pass
        out.append(entry)
    if not out:
        return []
    return out


def parse_qrc_to_lrc(blob):
    """Convert QQ QRC payload to enhanced LRC. Returns LRC string or None.
    Legacy wrapper over parse_qrc_structured kept for callers that need a
    plain string; prefer parse_qrc_structured for real timing."""
    entries = parse_qrc_structured(blob)
    if not entries:
        return None
    out_lines = []
    for e in entries:
        line = _qrc_tag(e['startTimeMs'])
        parts = e['parts']
        for i, p in enumerate(parts):
            w = (p['words'] or '').strip()
            if not w:
                continue
            line += _qrc_tag(p['startTimeMs'], bracket=False) + w
            if i < len(parts) - 1:
                nxt = (parts[i + 1]['words'] or '').strip()
                if nxt and not (_is_cjk_char(w[-1]) and _is_cjk_char(nxt[0])):
                    line += ' '
        out_lines.append(line.rstrip())
    return '\n'.join(out_lines)


