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
# Basic TTML Parser
# ============================================================

# ===========================================================================
# Per-line singer attribution (TTML `ttm:agent`) and section (`itunes:songPart`)
# ===========================================================================
# Why this exists. A duet TTML declares its voices ONCE, in <head><metadata>,
# and then POINTS AT them from the line and section elements:
#
#   <ttm:agent type="person" xml:id="v1"/>
#   <ttm:agent type="person" xml:id="v2"/>
#   <ttm:agent type="group"  xml:id="v1000"/>
#   <body ttm:agent="v2">
#     <div itunes:songPart="Verse">
#       <p ttm:agent="v1">a line</p>
#
# Scope is nearest-wins: the <p> beats its <div>, the <div> beats <body>. This
# is real data, not decoration -- in Die With A Smile (kPa7bsKwL-c) the 50 lines
# split v2/v1000/v1 = 22/18/10, the whole first verse AND first chorus are one
# voice, verse 2 flips per line, and v1000 marks exactly the lines where both
# voices sing. The parser walked root.iter('p') and read only begin/end/span, so
# none of it ever left the file: the phone was not ignoring a singers tag, it
# was never sent one.
#
# THE AGENTS CARRY NO NAME. <ttm:agent> is an xml:id reference and the elements
# are empty -- there is no "Lady Gaga" anywhere in these files, only <songwriters>,
# which is a different (5-name, unsorted-by-voice) list. So `singer` below is an
# INDEX into the person agents in declaration order, never a name. Resolving
# index -> artist name needs the track's credit order and is the caller's job
# (see ttml_voice_count); guessing it here would bake a wrong mapping into every
# cached entry.
#
# Emitted per line, and only when the file actually says something:
#   'singer'  int   0-based index into the person agents, in <head> order
#   'duet'    True  the line's agent is a type="group" agent (both voices)
#   'section' str   nearest itunes:songPart -- 'Verse', 'Chorus', 'Bridge', ...
# A solo track has one person agent, so every line gets singer 0 and there is
# nothing to show; consumers must treat a uniform run as "no attribution".
#
# Invisible to the cache hash on purpose: server/utils.py _canonical_lyrics_bytes
# packs only start/dur/text/translated/wordSynced/parts, so adding these keys
# cannot invalidate an entry that is already on disk, and cannot make the server
# and device hashes disagree.
_NS_TTM = '{http://www.w3.org/ns/ttml#metadata}'
_NS_XML = '{http://www.w3.org/XML/1998/namespace}'

# Whitespace runs are collapsed, not just runs of literal spaces: a tab or a
# newline inside a <span> used to survive into the line text verbatim.
_MULTI_SPACE_RE = re.compile(r'\s+')

# Undeclared-prefix repair (see _declare_missing_prefixes). The attribute
# pattern is deliberately loose -- a false positive only adds an unused
# xmlns declaration, which is harmless, whereas a missed one loses the file.
_ROOT_TT_RE = re.compile(r'<tt\b[^>]*>')
_DECLARED_PREFIX_RE = re.compile(r'xmlns:([A-Za-z][\w.-]*)\s*=')
_ELEMENT_PREFIX_RE = re.compile(r'</?([A-Za-z][\w.-]*):')
_ATTR_PREFIX_RE = re.compile(r'\s([A-Za-z][\w.-]*):[\w.-]+\s*=')


def _line_key(node):
    """The itunes:key a sidecar <text for=...> names this line by."""
    for k, v in node.attrib.items():
        if k == 'key' or k.endswith('}key'):
            return v
    return None


def _ttm_attr(node, local):
    """Attribute whose LOCAL NAME is `local`, whatever namespace it is in.

    This cannot look for one fixed namespace, because the two attributes live in
    two different ones: `agent` is ttm (http://www.w3.org/ns/ttml#metadata) and
    `songPart` is the vendor's own (http://music.apple.com/lyric-ttml-internal
    for Apple, http://lrc.red/lyric-ttml-internal for lrc.red). ElementTree hands
    back the expanded '{uri}local' form when the prefix is declared and the
    literal 'prefix:local' when it is not, and the parser above has already
    stripped some declarations by regex -- so all three spellings have to match.

    Ordered so a namespaced attribute always beats a bare one: a file with both
    `ttm:agent` and some unrelated bare `agent` must not depend on dict order.
    """
    if node is None:
        return ''
    bare = None
    for key, val in node.attrib.items():
        if val is None:
            continue
        local_part = key.rsplit('}', 1)[-1].rsplit(':', 1)[-1]
        if local_part != local:
            continue
        if key.startswith('{'):
            return str(val).strip()
        if ':' in key:
            return str(val).strip()
        if not bare:
            bare = str(val).strip()
    return bare or ''


def ttml_agent_table(root):
    """({xml:id: type}, {xml:id: person index}, {group xml:id}) from the head.

    Declaration order is the file's own voice order and is what `singer` counts,
    so this must preserve document order -- a plain dict does (3.7+).
    """
    types, persons, groups = {}, {}, set()
    for el in root.iter():
        tag = el.tag
        if not isinstance(tag, str):
            continue
        # '{uri}agent' when the prefix was declared, 'ttm:agent' when it was not.
        local = tag.rsplit('}', 1)[-1].rsplit(':', 1)[-1]
        if local != 'agent':
            continue
        aid = el.get(_NS_XML + 'id') or el.get('id') or ''
        aid = str(aid).strip()
        if not aid:
            continue
        kind = (el.get('type') or 'person').strip().lower()
        types[aid] = kind
        if kind == 'group':
            groups.add(aid)
        elif aid not in persons:
            persons[aid] = len(persons)
    return types, persons, groups


def ttml_voice_count(lyrics):
    """How many distinct person voices a parsed lyric list attributes to.

    Derived from the lines themselves, so no extra payload key is needed for it.
    Returns 0 when the file said nothing, 1 for a solo track.
    """
    best = -1
    for line in (lyrics or []):
        s = line.get('singer')
        if isinstance(s, int) and not isinstance(s, bool) and s > best:
            best = s
    return best + 1 if best >= 0 else 0


def _declare_missing_prefixes(xml_text):
    """Give every undeclared namespace prefix a synthetic declaration.

    ElementTree RAISES on an undeclared prefix, and this function's caller
    turns any exception into None -- so one file that uses `tts:` or `itunes:`
    without declaring it used to lose every line in it, silently. AMLL's own
    exporter writes undeclared prefixes, so this is not hypothetical; braccato
    carries the same repair (declareMissingNamespaces) for the same reason.

    A prefix is only ever ADDED, never removed or renamed, so a well-formed
    document comes back byte-identical.
    """
    m = _ROOT_TT_RE.search(xml_text)
    if not m:
        return xml_text
    root_tag = m.group(0)
    declared = {'xml', 'xmlns'}
    for name in _DECLARED_PREFIX_RE.findall(root_tag):
        declared.add(name)
    used = set(_ELEMENT_PREFIX_RE.findall(xml_text))
    used |= set(_ATTR_PREFIX_RE.findall(xml_text))
    missing = sorted(p for p in used if p not in declared)
    if not missing:
        return xml_text
    adds = ''.join(' xmlns:%s="urn:ytmu:unbound:%s"' % (p, p) for p in missing)
    return xml_text.replace(root_tag, root_tag[:-1] + adds + '>', 1)


def _subtree_text(el):
    """Every character under `el`, tails included, in document order.

    Apple puts a word straight inside its timed span; some exporters wrap it in
    one more untimed span. Reading the whole subtree means both spellings give
    the same word.
    """
    out = [el.text or '']
    for child in list(el):
        out.append(_subtree_text(child))
        out.append(child.tail or '')
    return ''.join(out)


def _local(el):
    tag = el.tag
    if not isinstance(tag, str):
        return ''
    return tag.rsplit('}', 1)[-1].rsplit(':', 1)[-1]


def _new_acc():
    """One node's collected content. `bg`/`roman`/`trans` mirror AMLL's
    IParsedState so the roles land somewhere a consumer can tell apart."""
    return {'text': '', 'parts': [], 'bg': None, 'roman': None, 'trans': []}


def _append_text(acc, raw):
    """Add a run of character data.

    A whitespace-only run is the gap BETWEEN two words, and that is the whole
    point: the previous parser guessed inter-word spacing from `has_gap` plus an
    is_cjk() probe, which is what printed "foll ow" for Apple's mid-word span
    splits. The source already says where the spaces are, so read them.
    """
    if not raw:
        return
    norm = _MULTI_SPACE_RE.sub(' ', raw)
    if not norm:
        return
    acc['text'] += norm
    if not norm.strip() and acc['parts']:
        acc['parts'][-1]['spaceAfter'] = True


def _amll_flags(el):
    """(obscure, empty_beat) from amll:obscene / amll:empty-beat.

    The name is `obscure` on purpose, to match every call site: the first
    version of this function initialised `obscene` and assigned `obscure`, so
    the flag was silently False forever and no error was ever raised.
    """
    obscure = False
    empty_beat = None
    o = _ttm_attr(el, 'obscene')
    if o and o.strip().lower() == 'true':
        obscure = True
    b = _ttm_attr(el, 'empty-beat') or _ttm_attr(el, 'emptyBeat')
    if b:
        try:
            empty_beat = int(str(b).strip())
        except (TypeError, ValueError):
            empty_beat = None
    return obscure, empty_beat


def _word_element(acc, el):
    """A plain timed span: one syllable/word with its own window."""
    txt = _MULTI_SPACE_RE.sub(' ', _subtree_text(el))
    if txt[:1].isspace() and acc['parts']:
        # A leading space belongs to the gap after the PREVIOUS word, same as a
        # tail. Both spellings occur; both mean the same thing.
        acc['parts'][-1]['spaceAfter'] = True
    _append_text(acc, txt)

    begin = _ttm_attr(el, 'begin')
    end = _ttm_attr(el, 'end')
    clean = txt.strip()
    if not (begin and end and clean):
        return
    s_ms = parse_ttml_time(begin)
    e_ms = parse_ttml_time(end)
    if e_ms <= s_ms:
        return
    part = {'startTimeMs': s_ms, 'words': clean,
            'durationMs': e_ms - s_ms, 'spaceAfter': False}
    obscure, beat = _amll_flags(el)
    if obscure:
        part['obscene'] = True
    if beat is not None:
        part['emptyBeat'] = beat
    acc['parts'].append(part)


def _ruby_element(acc, el):
    """<span tts:ruby="container"> with a base and timed ruby text.

    Furigana with its own timings: the base becomes one word spanning the ruby
    window and the readings ride along on it, so a Japanese line with readings
    no longer renders doubled (the readings used to arrive as extra WORDS).
    Mirrors AMLL's processRubyElement, including its one limitation: a base
    that itself holds timed spans collapses to a single word.
    """
    base_text = ''
    base_el = None
    ruby_tags = []
    for child in list(el):
        kind = (_ttm_attr(child, 'ruby') or '').strip().lower()
        if kind == 'base':
            base_text = _MULTI_SPACE_RE.sub(' ', _subtree_text(child))
            base_el = child
        elif kind == 'textcontainer':
            for t in child.iter():
                if (_ttm_attr(t, 'ruby') or '').strip().lower() != 'text':
                    continue
                b, e = _ttm_attr(t, 'begin'), _ttm_attr(t, 'end')
                val = _MULTI_SPACE_RE.sub(' ', _subtree_text(t)).strip()
                if val and b and e:
                    ruby_tags.append({'text': val,
                                      'startTimeMs': parse_ttml_time(b),
                                      'durationMs': max(parse_ttml_time(e)
                                                        - parse_ttml_time(b), 0)})
    if not base_text.strip():
        return
    if base_text[:1].isspace() and acc['parts']:
        acc['parts'][-1]['spaceAfter'] = True
    _append_text(acc, base_text)

    if ruby_tags:
        s_ms = min(t['startTimeMs'] for t in ruby_tags)
        e_ms = max(t['startTimeMs'] + t['durationMs'] for t in ruby_tags)
    elif base_el is not None:
        s_ms = parse_ttml_time(_ttm_attr(base_el, 'begin'))
        e_ms = parse_ttml_time(_ttm_attr(base_el, 'end'))
    else:
        s_ms = e_ms = 0
    if e_ms <= s_ms:
        return
    part = {'startTimeMs': s_ms, 'words': base_text.strip(),
            'durationMs': e_ms - s_ms, 'spaceAfter': False}
    if ruby_tags:
        part['ruby'] = ruby_tags
    obscure, beat = _amll_flags(el)
    if obscure:
        part['obscene'] = True
    if beat is not None:
        part['emptyBeat'] = beat
    acc['parts'].append(part)


def _bg_text(raw):
    """A background cue's own text, unwrapped from its brackets.

    `(ちーん)` is a stage direction, not part of the sung line; both references
    strip the wrapping parens so it renders as `ちーん`.
    """
    return re.sub(r'^[(（]+', '', re.sub(r'[)）]+$', '', raw)).strip()


def _content(el, acc, depth=0):
    """Walk `el`'s children in document order, dispatching on ttm:role.

    The old parser called p.iter('span'), which is RECURSIVE: a wrapper
    <span ttm:role="x-bg"> and the cue nested inside it both became karaoke
    words of the vocal line, so the wipe lit the cue up and the translation
    swallowed it. Roles are dispatched here instead, so each one lands in its
    own field.
    """
    if depth > 8:
        _append_text(acc, _subtree_text(el))
        return acc
    _append_text(acc, el.text)
    for child in list(el):
        local = _local(child)
        role = (_ttm_attr(child, 'role') or '').strip().lower()
        ruby_kind = (_ttm_attr(child, 'ruby') or '').strip().lower()

        if role == 'x-bg':
            sub = _new_acc()
            _content(child, sub, depth + 1)
            if acc['bg'] is None and (sub['text'].strip() or sub['parts']):
                acc['bg'] = sub
            else:
                # A second background run on one line: keep it as text rather
                # than dropping it, but never as a word of the vocal line.
                _append_text(acc, sub['text'])
        elif role == 'x-translation':
            sub = _new_acc()
            _content(child, sub, depth + 1)
            if sub['text'].strip():
                acc['trans'].append(sub['text'].strip())
        elif role == 'x-roman':
            sub = _new_acc()
            _content(child, sub, depth + 1)
            if acc['roman'] is None and (sub['text'].strip() or sub['parts']):
                acc['roman'] = sub
        elif local == 'span' and ruby_kind == 'container':
            _ruby_element(acc, child)
        elif local == 'span':
            _word_element(acc, child)
        else:
            # Not a span (a <br>, or an element shape we do not know): keep the
            # characters, invent no timing for them.
            _append_text(acc, _subtree_text(child))
        _append_text(acc, child.tail)
    return acc


def _finish_parts(acc):
    """Trim the edges, drop a lone 0/0 placeholder, and convert the internal
    gap flags into the `space` key the device already reads.

    `space: false` means THE SOURCE GLUED THIS WORD TO THE PREVIOUS ONE, which
    is what the device reads as "join without a separator" (LyricsSheet's
    wbwDisplayTextForLyric). Note the shift: the parser records the gap AFTER a
    word, because that is where a space physically lives in the document (it is
    the previous span's tail), while `space` describes the gap BEFORE a word.
    Reading one as the other is what put a separator on the wrong side of every
    word -- `赤 ずっと` came out as `赤ずっと` with a stray space at the end.

    `space` is emitted only when it is False, so a document whose spacing we now
    read correctly produces the same payload the old heuristic produced."""
    parts = [p for p in acc['parts'] if p.get('words')]
    if len(parts) == 1 and parts[0]['startTimeMs'] == 0 and parts[0]['durationMs'] == 0:
        # A single word with no timing at all is a placeholder, not karaoke.
        parts = []
    prev_had_gap = False
    for p in parts:
        p['words'] = p['words'].strip()
        had_gap = bool(p.pop('spaceAfter', False))
        if prev_had_gap:
            p.pop('space', None)
        else:
            p['space'] = False
        prev_had_gap = had_gap
    return [p for p in parts if p['words']]


def _sub_line(acc, bg=False):
    """The shape of a background cue / romanization: same as a line, minus the
    attribution. Returns None when there is nothing to show."""
    parts = _finish_parts(acc)
    text = _MULTI_SPACE_RE.sub(' ', acc['text']).strip()
    if bg:
        text = _bg_text(text)
    if not text and not parts:
        return None
    # Timing comes from the parts whenever there are any, including a single
    # one: a one-word cue like `(ちーん)` still has to know when to show.
    span = [(p['startTimeMs'], p['startTimeMs'] + p['durationMs'])
            for p in parts]
    start = min((s for s, _ in span), default=0)
    end = max((e for _, e in span), default=0)
    out = {'text': text, 'startTimeMs': start,
           'durationMs': max(end - start, 0)}
    out['duration'] = round(out['durationMs'] / 1000.0, 3)
    if len(parts) > 1 and len({p['startTimeMs'] for p in parts}) > 1:
        out['parts'] = parts
        out['wordSynced'] = True
    return out


def parse_ttml_basic(ttml_text, duration_sec=0):
    """Parse TTML into timed lines, with the roles the format actually defines.

    Handles what both references handle and we did not: ttm:role (x-bg / x-translation
    / x-roman), tts:ruby, amll:obscene + amll:empty-beat, <translations> and
    <transliterations> sidecars, ttm:agent names, itunes:song-part (kebab), a
    <p> with no begin/end, and undeclared namespace prefixes. Every one of those
    used to arrive as extra WORDS on the vocal line or as a dropped file.

    New keys are only written when the file says something, so a document that
    uses none of this produces byte-identical entries to before.
    """
    try:
        import xml.etree.ElementTree as ET

        ttml_text = _declare_missing_prefixes(ttml_text)
        # Remove default namespace for easier parsing. The amll: prefix is NOT
        # stripped any more: that regex deleted amll:obscene and
        # amll:empty-beat along with the namespace.
        ttml_text = re.sub(r'xmlns="[^"]*"', '', ttml_text)
        ttml_text = ttml_text.replace('\\"', '"')

        root = ET.fromstring(ttml_text)

        # -------------------------------------------------------------------
        # Voice + section attribution tables (see the block comment above).
        # Built once per file. `parent` is needed because ElementTree has no
        # parent pointers and the agent scope is nearest-wins along the
        # <p> -> <div> -> <body> chain.
        # -------------------------------------------------------------------
        _a_types, _a_persons, _a_groups = ttml_agent_table(root)
        _a_names = {}
        for _el in root.iter():
            if _local(_el) != 'agent':
                continue
            _aid = _el.get(_NS_XML + 'id') or _el.get('id') or ''
            _nm = ''
            for _ch in list(_el):
                if _local(_ch) == 'name':
                    _nm = (_ch.text or '').strip()
                    if not _nm and list(_ch):
                        _nm = _subtree_text(_ch).strip()
                    break
            if _aid and _nm:
                _a_names[str(_aid).strip()] = _nm
        parent = {}
        for _el in root.iter():
            for _ch in list(_el):
                parent[_ch] = _el

        def _scope_attr(node, local):
            """Nearest value of `local` walking node -> ... -> root."""
            while node is not None:
                v = _ttm_attr(node, local)
                if v:
                    return v
                node = parent.get(node)
            return ''

        # ---------------------------------------------------------------
        # Sidecar text blocks, keyed by the line key they name.
        #
        # <translation> and <transliteration> are SEPARATE channels, and the
        # old parser merged both into one map keyed only by `for` -- so a
        # romanisation could become the sung text.
        #
        # The lang attribute is what separates Apple's TRANSLATION from
        # lrc.red / BiniLyrics' LINE TEXT, and getting that wrong is not a
        # nicety: an Apple file carrying an English <translations> block had
        # its original lyrics overwritten by the translation, because every
        # <text for> was treated as the authoritative line text. Both
        # references require a lang before they will accept one as a
        # translation (AMLL: `if (!lang || !text || !forKey) continue`), and a
        # langless <text for> is exactly the lrc.red shape that made the
        # declared text authoritative in the first place. So:
        #   lang in scope  -> translation / romanization side channel
        #   no lang        -> the line text itself (lrc.red, BiniLyrics)
        #
        # The transliteration is parsed, not stringified, because the block can
        # carry its own timed spans -- braccato's timedRomanization, and the
        # only way a romaji row can be wiped in step with its vocal.
        # ---------------------------------------------------------------
        line_texts = {}
        line_trans = {}
        line_romans = {}

        def _lang_of(node):
            """xml:lang nearest-wins walking node -> ... -> root. The dialect
            that hangs it off <translations> and the one that hangs it off
            <translation> are both read, same as both references do."""
            while node is not None:
                v = _ttm_attr(node, 'lang')
                if v:
                    return v
                node = parent.get(node)
            return ''

        for _container in root.iter():
            _c_local = _local(_container)
            if _c_local not in ('translation', 'transliteration'):
                continue
            _is_roman = _c_local == 'transliteration'
            for _text_el in _container.iter():
                if _local(_text_el) != 'text':
                    continue
                ref = _ttm_attr(_text_el, 'for') or _ttm_attr(_text_el, 'key')
                if not ref:
                    ref = _ttm_attr(_container, 'for')
                if not ref:
                    continue
                lang = _lang_of(_text_el) or _lang_of(_container)
                if _is_roman:
                    if ref in line_romans:
                        continue
                    _acc = _new_acc()
                    _content(_text_el, _acc)
                    _sub = _sub_line(_acc)
                    if _sub:
                        if lang:
                            _sub['lang'] = lang
                        line_romans[ref] = _sub
                elif lang:
                    val = (_MULTI_SPACE_RE.sub(' ', _subtree_text(_text_el))).strip()
                    if val:
                        line_trans.setdefault(ref, {'text': val, 'lang': lang})
                else:
                    val = (_MULTI_SPACE_RE.sub(' ', _subtree_text(_text_el))).strip()
                    if val:
                        line_texts.setdefault(ref, val)

        results = []

        # Find all <p> elements (lines)
        for p in root.iter('p'):
            acc = _new_acc()
            _content(p, acc)

            begin = _ttm_attr(p, 'begin')
            end = _ttm_attr(p, 'end')
            start_ms = parse_ttml_time(begin) if begin else 0
            end_ms = parse_ttml_time(end) if end else 0

            parts = _finish_parts(acc)
            bg_parts = _finish_parts(acc['bg']) if acc['bg'] else []

            # The line's own window, derived from its children when the <p>
            # says nothing. A file that only times its spans used to lose the
            # whole line here (`if not begin: continue`).
            timed = [(q['startTimeMs'], q['startTimeMs'] + q['durationMs'])
                     for q in parts] + [
                (q['startTimeMs'], q['startTimeMs'] + q['durationMs'])
                for q in bg_parts]
            if timed:
                c_min = min(s for s, _ in timed)
                c_max = max(e for _, e in timed)
                if start_ms == 0 or (0 < c_min < start_ms):
                    start_ms = c_min
                if end_ms == 0 or c_max > end_ms:
                    end_ms = c_max
            if start_ms == 0:
                continue

            full_text = _MULTI_SPACE_RE.sub(' ', acc['text']).strip()

            # The declared line text wins over the span join, but ONLY when the
            # file declared no language for it -- i.e. only the lrc.red /
            # BiniLyrics shape, where the spans are a romanised source and
            # joining them mangles it. A <text for> that carries xml:lang is a
            # translation and goes to `translated` below, never to `text`.
            _key = _line_key(p)
            declared = line_texts.get(_key) if _key else None
            if declared:
                full_text = declared
            if not full_text and not acc['bg']:
                continue

            if end_ms <= start_ms:
                end_ms = start_ms
            line_duration_ms = end_ms - start_ms

            entry = {
                'time': round(start_ms / 1000.0, 3),
                'startTimeMs': start_ms,
                'text': full_text,
                'durationMs': line_duration_ms,
                'duration': round(line_duration_ms / 1000.0, 3),
                'wordSynced': False
            }
            # Only genuine word-by-word timestamps count; never fabricate fake
            # wbw from line-by-line. A single timed part is deliberately NOT
            # synthesized here (AMLL's applyFallbackWord does): our own
            # cache.sanitize_lyrics_parts drops any line with <=1 part, so it
            # would be stripped again before anything could use it. The bg /
            # romanization sub-lines below are the ones that needed it, and they
            # keep their own window.
            if len(parts) > 1 and len({q['startTimeMs'] for q in parts}) > 1:
                entry['parts'] = parts
                entry['wordSynced'] = True

            # ---- ttm:role side channels --------------------------------
            bg_line = _sub_line(acc['bg'], bg=True) if acc['bg'] else None
            if bg_line:
                entry['bg'] = bg_line
            # An inline x-roman span wins over the sidecar block: it is on the
            # line itself, so it is the more specific statement.
            roman = None
            if acc['roman'] is not None:
                roman = _sub_line(acc['roman'])
            if not roman:
                _k = _line_key(p)
                roman = line_romans.get(_k) if _k else None
            if roman:
                entry['romanization'] = roman
            if not entry.get('translated'):
                # Sidecar first, then an inline x-translation span: the span
                # sits on the line itself, so it is the more specific claim.
                _tr = line_trans.get(_key) if _key else None
                if _tr:
                    entry['translated'] = _tr['text']
                elif acc['trans']:
                    entry['translated'] = ' '.join(acc['trans'])

            # ---- attribution -------------------------------------------
            # Voice + section, resolved nearest-wins down the p/div/body chain.
            # Only written when the file actually carries the attribute, so a
            # file with no agents produces byte-identical entries to before.
            _aid = _scope_attr(p, 'agent')
            if _aid:
                if _aid in _a_groups or (_a_types.get(_aid) or '') == 'group':
                    entry['duet'] = True
                elif _aid in _a_persons:
                    entry['singer'] = _a_persons[_aid]
                    # <ttm:agent><ttm:name> is real: both references read it.
                    if _aid in _a_names:
                        entry['singerName'] = _a_names[_aid]
            # itunes:songPart, and the kebab spelling itunes:song-part, which
            # is the one Apple actually writes and the one we were dropping.
            _part = _scope_attr(p, 'song-part') or _scope_attr(p, 'songPart')
            if _part:
                entry['section'] = _part

            results.append(entry)

        return results if results else None
    except Exception as e:
        print(f"[TTML Parser] Error: {e}")
        return None


def parse_ttml_time(time_str):
    """Parse TTML time format (HH:MM:SS.mmm, MM:SS.mmm, seconds with 's', or milliseconds with 'ms') to milliseconds."""
    if not time_str:
        return 0
    time_str = str(time_str).strip().replace(',', '.')

    # Check for milliseconds suffix: e.g. "1234ms"
    if time_str.endswith('ms'):
        try:
            return int(float(time_str[:-2]))
        except:
            return 0

    # Check for seconds suffix: e.g. "12.34s"
    if time_str.endswith('s'):
        try:
            return int(float(time_str[:-1]) * 1000)
        except:
            return 0

    # Check for HH:MM:SS.mmm or MM:SS.mmm
    parts = time_str.split(':')
    try:
        if len(parts) == 3:
            h, m, s = int(parts[0]), int(parts[1]), float(parts[2])
            return int((h * 3600 + m * 60 + s) * 1000)
        elif len(parts) == 2:
            m, s = int(parts[0]), float(parts[1])
            return int((m * 60 + s) * 1000)
        else:
            return int(float(parts[0]) * 1000)
    except:
        return 0


