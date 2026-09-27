# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
import functools
import json
import os
import queue as queue_module
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
# Cohere Translate (Command A Translate - free tier)
# ============================================================

# Keys are NEVER hardcoded here: they load from config/ai_providers.json
# (gitignored; see config/ai_providers.example.json) plus env vars.
# server/ai_providers.py owns file/env merging.
from .ai_providers import load_cohere_keys, load_chat_providers

COHERE_API_KEYS = []  # compat mirror, refreshed in place on every access
_cohere_key_idx = 0
_cohere_key_lock = threading.RLock()
_TLS = threading.local()


def _refresh_cohere_keys():
    keys = load_cohere_keys()
    with _cohere_key_lock:
        COHERE_API_KEYS[:] = keys
    return keys


def cohere_key_list():
    """Fresh snapshot of all Cohere keys. Never raises."""
    try:
        return _refresh_cohere_keys()
    except Exception:
        return list(COHERE_API_KEYS)


_refresh_cohere_keys()


# ------------------------------------------------------------
# OpenAI-compatible chat fallback (e.g. OrcaRouter):
# providers come from config/ai_providers.json + ORCAROUTER_API_KEY env.
# Each entry carries its own url (base_url), headers, key, and model,
# so a new provider is one JSON object (or one dashboard submit) away.
# ------------------------------------------------------------
def _chat_provider(use):
    try:
        providers = load_chat_providers(use)
    except Exception:
        return None
    return providers[0] if providers else None


def orca_enabled():
    return _chat_provider('translate') is not None


def translate_last_error():
    """Failure reason of the last translate call on THIS thread:
    None (ok/skipped), 'rate_limited' (429), or 'error'."""
    return getattr(_TLS, 'last_error', None)


def orca_chat(messages, timeout=60, max_tokens=4000):
    """Raw OpenAI-compatible chat call via the first translate provider.
    Returns text or None. Never raises."""
    p = _chat_provider('translate')
    if not p:
        return None
    key = (p.get('api_key') or '').strip()
    base = (p.get('base_url') or '').strip().rstrip('/')
    if not key or not base:
        return None
    headers = {'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}
    for hk, hv in (p.get('headers') or {}).items():
        if isinstance(hk, str) and isinstance(hv, str):
            headers[hk] = hv
    try:
        resp = requests.post(
            base + '/chat/completions',
            headers=headers,
            json={'model': p.get('model') or 'orcarouter/free',
                  'messages': messages,
                  'temperature': 0.2, 'max_tokens': max_tokens},
            timeout=timeout,
        )
        if resp.status_code == 429:
            _TLS.last_error = 'rate_limited'
            print(f"  [Chat:{p.get('name', '?')}] Rate limited (429)")
            return None
        if resp.status_code != 200:
            _TLS.last_error = 'error'
            print(f"  [Chat:{p.get('name', '?')}] Error {resp.status_code}: {resp.text[:200]}")
            return None
        return resp.json()['choices'][0]['message']['content']
    except Exception as e:
        _TLS.last_error = 'error'
        print(f"  [Chat:{p.get('name', '?')}] Exception: {e}")
        return None


def _parse_numbered_lines(translated_text, texts):
    """Parse '[1] ...' lines back into an order-aligned list."""
    result_map = {}
    for line in (translated_text or '').split('\n'):
        line = line.strip()
        if line.startswith('['):
            try:
                bracket_end = line.index(']')
                idx = int(line[1:bracket_end])
                result_map[idx] = line[bracket_end + 1:].strip()
            except Exception:
                pass
    return [result_map.get(i + 1, texts[i]) for i in range(len(texts))]


def _translate_prompt(texts, target_lang):
    """Strict numbered-translation prompt shared by Cohere + Orca. The
    contract matters more than the wording: exactly one output line per
    input line, translation only, never echoing the original or adding
    romanization (mixed-script karaoke lines otherwise come back as
    original + romaji + translation glued together)."""
    lang_name = LANG_NAMES.get(target_lang, target_lang)
    numbered = [f"[{i+1}] {t}" for i, t in enumerate(texts)]
    return (
        f"Translate the following song lyrics into {lang_name}. "
        f"Keep the same numbered format [1], [2], etc., exactly one output line per input line. "
        f"These are song lyrics, so keep the poetic style and meaning intact. "
        f"IMPORTANT: Do not translate onomatopoeia, scat singing, or nonsense words (like 'ba ba', 'la la') literally. Leave them as-is or transliterate them. "
        f"If a line is already in {lang_name} or is romanization/gibberish, keep it as-is. "
        f"STRICT OUTPUT RULES: output ONLY the translated lines with their numbers. "
        f"Never repeat the original text. Never add romanization, transliteration, "
        f"or explanations. Never merge lines. Never add extra lines.\n\n"
        f"{chr(10).join(numbered)}"
    )


def orca_chat_translate(texts, target_lang='zh-TW'):
    """Translate lines via OrcaRouter. Returns list or None. Never raises."""
    if not texts:
        return []
    text = orca_chat([{'role': 'user', 'content': _translate_prompt(texts, target_lang)}], timeout=90)
    if not text:
        return None
    try:
        return _parse_numbered_lines(text, texts)
    except Exception as e:
        _TLS.last_error = 'error'
        print(f'  [Orca] Parse failed: {e}')
        return None

import os
os.makedirs('cache/lyrics', exist_ok=True)
os.makedirs('cache/translate', exist_ok=True)

def get_translate_cached(cache_key):
    path = f"cache/translate/{hashlib.md5(cache_key.encode()).hexdigest()}.json"
    if os.path.exists(path):
        try:
            with open(path, 'r', encoding='utf-8') as f:
                return json.load(f)
        except:
            pass
    return None

def set_translate_cached(cache_key, data):
    path = f"cache/translate/{hashlib.md5(cache_key.encode()).hexdigest()}.json"
    try:
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False)
    except:
        pass

def get_cohere_key():
    global _cohere_key_idx
    keys = _refresh_cohere_keys()
    if not keys:
        return None
    with _cohere_key_lock:
        key = keys[_cohere_key_idx % len(keys)]
    return key

def rotate_cohere_key():
    global _cohere_key_idx
    with _cohere_key_lock:
        n = len(COHERE_API_KEYS) or 1
        _cohere_key_idx += 1
        idx = _cohere_key_idx % n
    print(f"  [Cohere] Rotated to key index {idx}")

LANG_NAMES = {
    'zh-TW': 'Traditional Chinese',
    'zh-CN': 'Simplified Chinese',
    'ja': 'Japanese',
    'ko': 'Korean',
    'en': 'English',
}

# ------------------------------------------------------------
# Chinese script detection / conversion
#
# Cohere is a general-purpose translator, not a script converter: asking it
# to "translate" a line that is already Chinese wastes a request and can
# subtly reword lyrics that didn't need touching (and it doesn't reliably
# stick to Traditional characters even when told to). So for zh-TW/zh-CN
# targets we split lines into two buckets before calling Cohere:
#   - lines that are already Han-script Chinese (Mandarin/Cantonese lyrics,
#     Simplified or Traditional) -> never sent to Cohere, just script-
#     converted with OpenCC
#   - everything else (Japanese kana, Hangul, Latin/romanized lyrics, etc.)
#     -> still goes through Cohere for real translation
# The OpenCC pass is then re-applied to the merged, final result so any
# Simplified characters Cohere still slips in get normalized too.
# ------------------------------------------------------------
try:
    import opencc
    _opencc_s2t = opencc.OpenCC('s2t')  # Simplified -> Traditional
    _opencc_t2s = opencc.OpenCC('t2s')  # Traditional -> Simplified
except Exception as _e:
    opencc = None
    _opencc_s2t = None
    _opencc_t2s = None
    print(f"  [OpenCC] not available ({_e}); install 'opencc-python-reimplemented' to enable "
          f"Simplified<->Traditional conversion. Falling back to Cohere for all Chinese lines.")

_HIRAGANA_KATAKANA_RE = re.compile(r'[\u3040-\u30FF\uFF66-\uFF9F]')
_HANGUL_RE = re.compile(r'[\uAC00-\uD7A3]')
_HAN_RE = re.compile(r'[\u4E00-\u9FFF\u3400-\u4DBF]')


def _is_chinese_target(target_lang):
    return (target_lang or '').lower().replace('_', '-') in ('zh-tw', 'zh-hant', 'zh-cn', 'zh-hans', 'zh')


# video_id and translate_to both end up embedded directly in cache filenames
# (e.g. cache/lyrics/{video_id}:{translate_to}.json), so anything containing
# '/', '\', or '..' must never reach that point -- otherwise a crafted value
# could write or read outside the cache directory entirely.
_SAFE_CACHE_COMPONENT_RE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')


def _safe_cache_component(value):
    if not isinstance(value, str) or not _SAFE_CACHE_COMPONENT_RE.match(value):
        return None
    return value



def _line_is_already_chinese(text):
    """True if a line is Han-script lyrics (any variant of Chinese) that only
    ever needs a script pass, never a real translation. Japanese lines with
    kana or Korean lines with Hangul still need translation even though they
    may also contain Han/Hanja characters."""
    if not text or not text.strip():
        return True
    if _HIRAGANA_KATAKANA_RE.search(text) or _HANGUL_RE.search(text):
        return False
    return bool(_HAN_RE.search(text))


def _apply_zh_script(texts, target_lang):
    """Normalize every line to the requested Chinese script. No-op (and
    cheap) for lines already in that script; also a no-op if OpenCC isn't
    installed."""
    norm = (target_lang or '').lower().replace('_', '-')
    if norm in ('zh-tw', 'zh-hant') and _opencc_s2t:
        return [_opencc_s2t.convert(t) if t else t for t in texts]
    if norm in ('zh-cn', 'zh-hans') and _opencc_t2s:
        return [_opencc_t2s.convert(t) if t else t for t in texts]
    return texts


def _detect_song_lang(info):
    """Best-effort song language from metadata: 'ja' when Japanese fields
    or kana are present, else '' (unknown). Used to decide whether
    Han-script lines are really Chinese (skip) or Japanese kanji (translate)."""
    try:
        info = info or {}
        if info.get('ja_title') or info.get('ja_artist'):
            return 'ja'
        text = f"{info.get('title', '')} {info.get('artist', '')}"
        if re.search(r'[\u3040-\u30FF\uFF66-\uFF9F]', text):
            return 'ja'
    except Exception:
        pass
    return ''


def cohere_translate(texts, target_lang='zh-TW', song_lang=''):
    """Translate a list of text lines using Cohere Command A Translate.
    song_lang (e.g. 'ja' from _detect_song_lang): for a non-Chinese song,
    Han-script lines are kanji, not Chinese -- translate them instead of
    skipping as already-Chinese."""
    if not texts:
        return []

    non_empty = [t for t in texts if t.strip()]
    if not non_empty:
        return texts

    cache_key = f"cohere:{target_lang}:{hashlib.md5('|'.join(texts).encode()).hexdigest()}"
    cached = get_translate_cached(cache_key)
    if cached is not None:
        return cached

    # Chinese target: lines that are already Chinese script skip Cohere
    # entirely and only get a script conversion pass at the end -- UNLESS
    # the song itself is not Chinese (Japanese kanji looks Han but isn't).
    chinese_target = _is_chinese_target(target_lang)
    skip_han = chinese_target and song_lang in ('', 'zh', 'zh-TW', 'zh-CN', 'zh-HK')
    if chinese_target and skip_han:
        to_translate_idx = [i for i, t in enumerate(texts) if not _line_is_already_chinese(t)]
    else:
        to_translate_idx = list(range(len(texts)))

    results = list(texts)  # default: keep original line

    if to_translate_idx:
        subset = [texts[i] for i in to_translate_idx]
        translated_subset = _cohere_translate_raw(subset, target_lang)
        used_orca = False
        if translated_subset is None and orca_enabled():
            print('  [Cohere] all keys failed, trying chat-provider fallback...')
            translated_subset = orca_chat_translate(subset, target_lang)
            used_orca = translated_subset is not None
        if translated_subset is None:
            # Total API failure: serve originals but do NOT cache them, or
            # every later lookup would serve the failure as a translation.
            if chinese_target:
                results = _apply_zh_script(results, target_lang)
            return results
        # Redo once: a translated line that still embeds its original
        # (model echoed original + romanization + translation as one blob,
        # common on mixed-script karaoke lines) gets one strict retry.
        bad = [i for i in range(len(subset))
               if _echoes_original(subset[i], translated_subset[i])]
        if bad:
            print(f"  [Cohere] {len(bad)} line(s) echo the original, retrying once...")
            fn = orca_chat_translate if used_orca else _cohere_translate_raw
            retry = fn([subset[i] for i in bad], target_lang)
            if retry is not None:
                for k, i in enumerate(bad):
                    translated_subset[i] = retry[k]
        for local_i, global_i in enumerate(to_translate_idx):
            results[global_i] = translated_subset[local_i]
    else:
        print(f"  [Cohere] All {len(texts)} line(s) already {LANG_NAMES.get(target_lang, target_lang)}, skipping API call")

    if chinese_target:
        results = _apply_zh_script(results, target_lang)

    set_translate_cached(cache_key, results)
    return results


def _echoes_original(orig, trans):
    """True when a translation embeds its whole original line (model echoed
    original + romanization + translation as one blob). Short originals
    (interjections, proper nouns kept as-is) don't count."""
    if not orig or not trans or trans == orig:
        return False
    o = orig.strip()
    if len(o) < 4:
        return False
    return o in trans


def _cohere_translate_raw(texts, target_lang):
    """Send exactly these lines to Cohere and return them translated, in order.
    Returns None when every key failed (caller serves originals uncached).
    Records the failure reason on translate_last_error() for this thread."""
    _TLS.last_error = None
    if not texts:
        return []
    keys = cohere_key_list()
    saw_429 = False

    lang_name = LANG_NAMES.get(target_lang, target_lang)

    prompt = _translate_prompt(texts, target_lang)

    for attempt in range(len(keys)):
        try:
            api_key = get_cohere_key()
            if not api_key:
                break
            resp = requests.post(
                "https://api.cohere.com/v2/chat",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": "command-a-translate-08-2025",
                    "messages": [{"role": "user", "content": prompt}],
                },
                timeout=30
            )

            if resp.status_code == 429:  # Rate limited
                print(f"  [Cohere] Rate limited on key {attempt}, rotating...")
                saw_429 = True
                rotate_cohere_key()
                continue

            if resp.status_code != 200:
                print(f"  [Cohere] Error {resp.status_code}: {resp.text[:200]}")
                rotate_cohere_key()
                continue

            data = resp.json()
            translated_text = data['message']['content'][0]['text']

            # Parse numbered lines back
            result_map = {}
            for line in translated_text.split('\n'):
                line = line.strip()
                if line.startswith('['):
                    try:
                        bracket_end = line.index(']')
                        idx = int(line[1:bracket_end])
                        content = line[bracket_end+1:].strip()
                        result_map[idx] = content
                    except:
                        pass

            # Reconstruct in order
            _TLS.last_error = None
            return [result_map.get(i+1, texts[i]) for i in range(len(texts))]

        except Exception as e:
            print(f"  [Cohere] Exception: {e}")
            rotate_cohere_key()

    # Total failure: signal the caller (None) instead of returning
    # originals that would be cached as translations.
    print("  [Cohere] All keys failed")
    _TLS.last_error = 'rate_limited' if saw_429 else 'error'
    return None


# ------------------------------------------------------------
# Streaming translate
#
# cohere_translate() above hands the whole numbered prompt to the model and
# waits for the last token, so a 40-line song shows nothing for ~7s and then
# pops every translation in at once. The functions below do the same job with
# `stream: true`, yielding each numbered line as the model finishes writing it
# (and, throttled, the line still being written) so a UI can paint the raw
# line first and type the translation in.
#
# Same contract as the blocking path, deliberately: the same cache key, the
# same "Han-script lines for a Chinese target never hit the API" bucketing,
# the same echo-original retry, the same "never negative-cache a total
# failure" rule. translate_stream() is a superset -- it falls back to the
# blocking call whenever streaming cannot deliver, so callers can always use
# it instead.
# ------------------------------------------------------------

_COHERE_CHAT_URL = 'https://api.cohere.com/v2/chat'
_COHERE_TRANSLATE_MODEL = 'command-a-translate-08-2025'
# Providers stream one token (or one character) at a time; pushing every
# single delta down an SSE channel would be pure overhead, so in-progress
# lines are reported at most this often. Completed lines always go through.
_TSTREAM_MIN_PARTIAL = 0.045

_LINE_NUM_RE = re.compile(r'^\s*\[(\d{1,4})\]\s?(.*)$', re.S)


class _NumberedStreamParser:
    """Incremental parser for the numbered translation format.

    feed(chunk) returns a list of {'i': <1-based prompt line>, 'text': str,
    'done': bool}. 'done' marks a line the model terminated with a newline;
    a line still being written is reported (throttled) with 'done' False so a
    UI can grow it character by character. Lines that don't parse as
    '[n] ...' are dropped, exactly like _parse_numbered_lines does.
    flush() returns the final line when the stream ended without a trailing
    newline.
    """

    def __init__(self):
        self._buf = ''
        self._last_partial = 0.0

    @staticmethod
    def _parse(raw):
        m = _LINE_NUM_RE.match(raw)
        if not m:
            return None
        try:
            return int(m.group(1)), m.group(2)
        except Exception:
            return None

    def feed(self, chunk):
        if not chunk:
            return []
        self._buf += chunk
        out = []
        while True:
            nl = self._buf.find('\n')
            if nl < 0:
                break
            line = self._buf[:nl]
            self._buf = self._buf[nl + 1:]
            parsed = self._parse(line.strip())
            if parsed:
                out.append({'i': parsed[0], 'text': parsed[1].strip(), 'done': True})
        partial = self._parse(self._buf.strip())
        if partial and partial[1].strip():
            now = time_module.monotonic()
            if (now - self._last_partial) >= _TSTREAM_MIN_PARTIAL:
                self._last_partial = now
                out.append({'i': partial[0], 'text': partial[1], 'done': False})
        return out

    def flush(self):
        tail = self._buf.strip()
        self._buf = ''
        parsed = self._parse(tail) if tail else None
        if not parsed or not parsed[1].strip():
            return []
        return [{'i': parsed[0], 'text': parsed[1].strip(), 'done': True}]


def _iter_numbered_events(deltas):
    """Turn a raw text-delta stream into numbered-line events."""
    parser = _NumberedStreamParser()
    for chunk in deltas:
        for ev in parser.feed(chunk):
            yield ev
    for ev in parser.flush():
        yield ev


def _sse_data_lines(resp):
    """Yield (event_name, data_string) for an SSE response, stopping at the
    `[DONE]` sentinel both providers send.

    Forces UTF-8 explicitly: Cohere and the OpenAI-compatible chat providers
    answer with `text/event-stream` and NO charset, so requests falls back to
    ISO-8859-1 and every CJK delta arrives as mojibake (the same trap
    node.py hit). `resp.encoding` is what iter_lines decodes with, so setting
    it here is the fix.
    """
    resp.encoding = 'utf-8'
    event = ''
    for raw in resp.iter_lines(decode_unicode=True):
        if not raw:
            event = ''
            continue
        if raw.startswith(':'):
            continue  # comment / keepalive
        if raw.startswith('event:'):
            event = raw[6:].strip()
        elif raw.startswith('data:'):
            data = raw[5:].strip()
            if data == '[DONE]':
                return
            yield event, data


def _cohere_translate_stream(texts, target_lang):
    """Stream the numbered translation out of Cohere, yielding raw text
    deltas (str). Rotates keys on 429 like the batch path, records the failure
    reason on translate_last_error(), and raises RuntimeError when every key
    failed so the caller can fall back. The HTTP response is always closed,
    including when the consumer abandons the generator (client disconnect)."""
    _TLS.last_error = None
    if not texts:
        return
    keys = cohere_key_list()
    if not keys:
        _TLS.last_error = 'error'
        raise RuntimeError('no Cohere keys configured')
    saw_429 = False
    body = {
        "model": _COHERE_TRANSLATE_MODEL,
        "messages": [{"role": "user", "content": _translate_prompt(texts, target_lang)}],
        "stream": True,
    }
    for attempt in range(len(keys)):
        resp = None
        try:
            api_key = get_cohere_key()
            if not api_key:
                break
            resp = requests.post(
                _COHERE_CHAT_URL,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                    "Accept": "text/event-stream",
                },
                json=body,
                stream=True,
                timeout=(10, 60),
            )
            if resp.status_code == 429:
                print(f"  [Cohere] Stream rate limited on key {attempt}, rotating...")
                saw_429 = True
                rotate_cohere_key()
                continue
            if resp.status_code != 200:
                print(f"  [Cohere] Stream error {resp.status_code}")
                rotate_cohere_key()
                continue
            for event, data in _sse_data_lines(resp):
                if event and event != 'content-delta':
                    continue
                try:
                    payload = json.loads(data)
                except Exception:
                    continue
                content = ((payload.get('delta') or {}).get('message') or {}).get('content') or {}
                text = content.get('text')
                if text:
                    yield text
            _TLS.last_error = None
            return
        except Exception as e:
            print(f"  [Cohere] Stream exception: {e}")
            rotate_cohere_key()
        finally:
            if resp is not None:
                try:
                    resp.close()
                except Exception:
                    pass
    _TLS.last_error = 'rate_limited' if saw_429 else 'error'
    raise RuntimeError('Cohere stream failed on every key')


def _chat_stream_deltas(messages, max_tokens=4000):
    """Stream text deltas from the first 'translate' chat provider
    (OpenAI-compatible: `stream: true` -> choices[].delta.content).
    Raises RuntimeError when the provider is missing or the call fails."""
    p = _chat_provider('translate')
    if not p:
        raise RuntimeError('no chat provider configured')
    key = (p.get('api_key') or '').strip()
    base = (p.get('base_url') or '').strip().rstrip('/')
    if not key or not base:
        raise RuntimeError('chat provider missing key/base_url')
    headers = {'Authorization': f'Bearer {key}',
               'Content-Type': 'application/json',
               'Accept': 'text/event-stream'}
    for hk, hv in (p.get('headers') or {}).items():
        if isinstance(hk, str) and isinstance(hv, str):
            headers[hk] = hv
    resp = None
    try:
        resp = requests.post(
            base + '/chat/completions',
            headers=headers,
            json={'model': p.get('model') or 'orcarouter/free',
                  'messages': messages, 'temperature': 0.2,
                  'max_tokens': max_tokens, 'stream': True},
            stream=True,
            timeout=(10, 60),
        )
        if resp.status_code == 429:
            _TLS.last_error = 'rate_limited'
            raise RuntimeError('chat stream rate limited')
        if resp.status_code != 200:
            _TLS.last_error = 'error'
            raise RuntimeError(f'chat stream HTTP {resp.status_code}')
        for event, data in _sse_data_lines(resp):
            try:
                payload = json.loads(data)
            except Exception:
                continue
            for choice in (payload.get('choices') or []):
                content = (choice.get('delta') or {}).get('content')
                if isinstance(content, list):
                    content = ''.join(part.get('text') or ''
                                       for part in content
                                       if isinstance(part, dict))
                if content:
                    yield content
        _TLS.last_error = None
    finally:
        if resp is not None:
            try:
                resp.close()
            except Exception:
                pass


def translate_stream(texts, target_lang='zh-TW', song_lang=''):
    """Streaming counterpart of cohere_translate.

    Yields {'i': <0-based index into texts>, 'text': str, 'done': bool} as the
    model writes. 'done' means that line is final; a partial event means the
    line is still growing (clients should overwrite the same index, not
    append). Always terminates with every line delivered: streaming failures
    (no key, 429 on every key, a provider that ignores `stream`) fall back to
    the blocking call, which is also how a total API failure ends up serving
    the originals -- uncached, exactly like cohere_translate.
    """
    if not texts:
        return
    if not any(t.strip() for t in texts):
        for i, t in enumerate(texts):
            yield {'i': i, 'text': t, 'done': True}
        return

    cache_key = f"cohere:{target_lang}:{hashlib.md5('|'.join(texts).encode()).hexdigest()}"
    cached = get_translate_cached(cache_key)
    if cached is not None:
        print(f"  [Cohere] Stream cache hit ({len(texts)} lines)")
        for i, t in enumerate(texts):
            yield {'i': i, 'text': cached[i] if i < len(cached) else t, 'done': True}
        return

    # Same zh bucketing as cohere_translate: lines already in Han script for a
    # Chinese target need a script pass, never an API call -- so they are
    # handed over immediately and for free.
    chinese_target = _is_chinese_target(target_lang)
    skip_han = chinese_target and song_lang in ('', 'zh', 'zh-TW', 'zh-CN', 'zh-HK')
    results = list(texts)
    if chinese_target and skip_han:
        to_translate_idx = [i for i, t in enumerate(texts) if not _line_is_already_chinese(t)]
    else:
        to_translate_idx = list(range(len(texts)))

    if chinese_target and to_translate_idx != list(range(len(texts))):
        for i, t in enumerate(_apply_zh_script(results, target_lang)):
            results[i] = t
            yield {'i': i, 'text': t, 'done': True}

    if to_translate_idx:
        subset = [texts[i] for i in to_translate_idx]

        # Fold the events into the final per-line text. Last event wins, so a
        # line that streamed partials ends up with its completed text.
        latest = {}

        def _run(deltas):
            """Feed a delta iterator through a fresh parser, yielding every
            event it produces and recording the last one per line. Line numbers
            outside the prompt's range are dropped: models occasionally append
            a bonus line, and a bogus index must never reach a client.

            The prompt numbers lines from 1 over `subset`, but the wire
            contract is a 0-based index into `texts` (every other yield in
            this function uses it, and callers paint by index). Those are only
            the same when nothing was bucketed out, so re-map here: with the
            Han-script bucket active `subset` is a strict subset and the
            model's `[1]` is not lyric row 0."""
            for ev in _iter_numbered_events(deltas):
                prompt_i = ev['i']
                if not (1 <= prompt_i <= len(subset)):
                    continue
                latest[prompt_i] = ev['text']
                out = dict(ev)
                out['i'] = to_translate_idx[prompt_i - 1]
                yield out

        engine = 'cohere'
        try:
            for ev in _run(_cohere_translate_stream(subset, target_lang)):
                yield ev
        except Exception as e:
            print(f"  [Cohere] {e}; trying chat-provider stream fallback...")
            latest.clear()
            engine = 'chat'
            try:
                for ev in _run(_chat_stream_deltas(
                        [{'role': 'user', 'content': _translate_prompt(subset, target_lang)}])):
                    yield ev
            except Exception as e2:
                print(f"  [Chat] stream failed too: {e2}")
        produced = bool(latest)

        if not produced:
            # Nothing came back at all: hand the job to the blocking path
            # (it retries the keys, the chat provider, and keeps the
            # originals uncached when the API is simply down).
            print("  [Cohere] Stream produced nothing, falling back to blocking translate")
            blocking = cohere_translate(texts, target_lang, song_lang=song_lang)
            for i, t in enumerate(blocking):
                results[i] = t
                yield {'i': i, 'text': t, 'done': True}
            return

        for prompt_i, text in latest.items():
            if 1 <= prompt_i <= len(to_translate_idx):
                results[to_translate_idx[prompt_i - 1]] = text

        # A translated line that still embeds its original (model echoed
        # original + romanization + translation as one blob) gets one strict
        # retry, same as the blocking path -- the client sees the corrected
        # line land as a second `done` event.
        bad = [k for k in range(len(subset))
               if _echoes_original(subset[k], results[to_translate_idx[k]])]
        if bad:
            print(f"  [Cohere] {len(bad)} line(s) echo the original, retrying once...")
            retry_fn = orca_chat_translate if engine == 'chat' else _cohere_translate_raw
            retry = retry_fn([subset[k] for k in bad], target_lang)
            if retry is not None:
                for j, k in enumerate(bad):
                    gi = to_translate_idx[k]
                    results[gi] = retry[j]
                    yield {'i': gi, 'text': retry[j], 'done': True}

        if chinese_target:
            converted = _apply_zh_script(results, target_lang)
            for i, t in enumerate(converted):
                if t != results[i]:
                    results[i] = t
                    yield {'i': i, 'text': t, 'done': True}

        # Never cache a run that translated nothing: later lookups would serve
        # the originals as if they were translations.
        if any(results[i] and results[i] != texts[i]
               for i in to_translate_idx):
            set_translate_cached(cache_key, results)


def apply_display_transforms(lyrics, target_lang='zh-TW', auto_zh=False):
    """Presentation-only, response-time post-processing (never applied to what
    gets persisted). Two rules:

      1. Always: a 'translated' row identical to the line 'text' is redundant
         -- the line already reads in (or collapsed onto) the user's preferred
         language, e.g. a zh-TW song served with lang=zh-TW. Drop the row so
         the client stops showing a duplicate translate line.

      2. auto_zh only: with a Chinese target and OpenCC installed, a Han-script
         line from the other script variant (zh-CN -> zh-TW etc.) gets the
         script-converted string inlined as the main 'text' (plus its per-word
         parts converted), dropping the translate row. Non-Chinese lines
         (Japanese kana, Hangul, Latin scat) keep their real translation.

    Mutates the lyric dicts in place; callers must not hand in the exact object
    they are about to cache.
    """
    if not lyrics:
        return
    chinese_target = _is_chinese_target(target_lang)
    norm = (target_lang or '').lower().replace('_', '-')
    converter = None
    if norm in ('zh-tw', 'zh-hant'):
        converter = _opencc_s2t
    elif norm in ('zh-cn', 'zh-hans'):
        converter = _opencc_t2s
    for line in lyrics:
        if not isinstance(line, dict):
            continue
        text = line.get('text') or ''
        translated = line.get('translated')
        if not translated:
            continue
        if translated == text:
            line.pop('translated', None)
            continue
        if (auto_zh and chinese_target and converter
                and text.strip() and _line_is_already_chinese(text)):
            line['text'] = translated
            for part in (line.get('parts') or []):
                if isinstance(part, dict) and part.get('words'):
                    part['words'] = converter.convert(part['words'])
            line.pop('translated', None)


def google_translate_fast(texts, target_lang='zh-TW'):
    """Fast Google translate - no API key needed, for immediate results."""
    if not texts:
        return []

    cache_key = f"gtx:{target_lang}:{hashlib.md5('|'.join(texts).encode()).hexdigest()}"
    cached = get_translate_cached(cache_key)
    if cached is not None:
        return cached

    delimiter = '\n\n;\n\n'
    batches, current_batch, current_len = [], [], 0
    for text in texts:
        if current_len + len(text) > 3500:
            batches.append(current_batch)
            current_batch, current_len = [], 0
        current_batch.append(text)
        current_len += len(text)
    if current_batch:
        batches.append(current_batch)

    all_translations = []
    batch_ok = True
    for batch in batches:
        joined = delimiter.join(batch)
        try:
            url = f"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl={target_lang}&dt=t&q={quote(joined)}"
            resp = requests.get(url, timeout=8, headers={'User-Agent': 'Mozilla/5.0'})
            if resp.status_code == 200:
                data = resp.json()
                translated = ''.join(part[0] for part in data[0] if part[0])
                # Split on the exact delimiter first: a bare ';' split
                # misaligns the batch whenever a translation itself
                # contains a semicolon.
                if delimiter in translated:
                    parts = [p.strip() for p in translated.split(delimiter)]
                else:
                    parts = translated.split(';')
                    parts = [p.strip() for p in parts]
                if len(parts) == len(batch):
                    all_translations.extend(parts)
                else:
                    lines = [t.strip() for t in translated.split('\n') if t.strip()]
                    while len(lines) < len(batch): lines.append('')
                    all_translations.extend(lines[:len(batch)])
            else:
                batch_ok = False
                all_translations.extend(['' for _ in batch])
        except Exception as e:
            batch_ok = False
            all_translations.extend(['' for _ in batch])

    if _is_chinese_target(target_lang):
        all_translations = _apply_zh_script(all_translations, target_lang)

    # Never negative-cache a total failure (HTTP error/exception on every
    # batch): later lookups would serve the blanks as if translated.
    if batch_ok or any(t for t in all_translations):
        set_translate_cached(cache_key, all_translations)
    return all_translations


def translate_result_in_place(result, target_lang, song_lang=''):
    """Fill lyric['translated'] for every text line of a fetched result.

    Same index-aligned mapping the sequential pipeline uses, factored out so
    the background translate queue behaves identically. Alignment runs over
    text-bearing lines only, so textless/gap rows never shift later
    translations. Returns the number of lines filled."""
    if not target_lang or not result or not result.get('lyrics'):
        return 0
    texts = [l['text'] for l in result['lyrics'] if l.get('text')]
    if not texts:
        return 0
    translations = cohere_translate(texts, target_lang, song_lang=song_lang)
    filled = 0
    ti = 0
    for lyric in result['lyrics']:
        if not lyric.get('text'):
            continue
        if ti < len(translations) and translations[ti]:
            lyric['translated'] = translations[ti]
            filled += 1
        ti += 1
    return filled


# ------------------------------------------------------------
# Silent background translate queue: fetch threads never block on
# translation. They cache the untranslated result, enqueue it here, and
# move on; daemon workers translate + rewrite the cache entry. Only
# counters are exposed (no UI of its own).
# ------------------------------------------------------------
_TQ_QUEUE = queue_module.Queue()
_TQ_STATS = {'queued': 0, 'done': 0, 'errors': 0}
_TQ_LOCK = threading.Lock()
_TQ_WORKERS = 2
_TQ_STARTED = False
# On 429 the worker waits and retries instead of dropping the item, so the
# queue eventually completes once quota resets. Bounds are env-tunable.
_TQ_MAX_RETRIES = max(0, int(os.environ.get('YTMU_TQ_MAX_RETRIES', '40')))
_TQ_RETRY_SLEEP = max(5, int(os.environ.get('YTMU_TQ_RETRY_SLEEP', '60')))


def _translate_queue_worker():
    from .cache import set_cached
    while True:
        item = _TQ_QUEUE.get()
        try:
            retries = item.get('retries', 0)
            n = translate_result_in_place(item.get('data'), item.get('lang'))
            err = translate_last_error()
            if err == 'rate_limited':
                if retries >= _TQ_MAX_RETRIES:
                    print(f"[TRANSQ] [FAIL] {item.get('key', '?')}: "
                          f"rate-limited x{retries}, dropping")
                    with _TQ_LOCK:
                        _TQ_STATS['errors'] += 1
                else:
                    wait = _TQ_RETRY_SLEEP
                    print(f"[TRANSQ] [WAIT] {item.get('key', '?')}: 429, "
                          f"retry {retries + 1}/{_TQ_MAX_RETRIES} in {wait}s")
                    time_module.sleep(wait)
                    item['retries'] = retries + 1
                    _TQ_QUEUE.put(item)
                continue
            if err is None and n:
                set_cached(item['key'], item['data'])
            with _TQ_LOCK:
                if err is None:
                    _TQ_STATS['done'] += 1
                else:
                    _TQ_STATS['errors'] += 1
        except Exception as e:
            print(f"[TRANSQ] [FAIL] {item.get('key', '?')}: {e}")
            with _TQ_LOCK:
                _TQ_STATS['errors'] += 1
        finally:
            _TQ_QUEUE.task_done()


def _ensure_translate_queue():
    global _TQ_STARTED
    with _TQ_LOCK:
        if _TQ_STARTED:
            return
        _TQ_STARTED = True
    for i in range(_TQ_WORKERS):
        t = threading.Thread(target=_translate_queue_worker, daemon=True,
                             name=f'translate-q-{i}')
        t.start()


def translate_queue_enqueue(cache_key, lang, data):
    """Enqueue one fetched (untranslated) result for background translation.
    Returns True when enqueued, False when there is nothing to translate."""
    if not cache_key or not lang or not data or not data.get('lyrics'):
        return False
    if not any(l.get('text') and not l.get('translated') for l in data['lyrics']):
        return False
    _ensure_translate_queue()
    _TQ_QUEUE.put({'key': cache_key, 'lang': lang, 'data': data})
    with _TQ_LOCK:
        _TQ_STATS['queued'] += 1
    return True


def _needs_translation(data, lang):
    """True when at least one text line still lacks a translation.
    Lines already in the target Chinese script are intentionally
    untranslated (script-converted instead), so they don't count."""
    if not data or not data.get('lyrics'):
        return False
    zh = _is_chinese_target(lang or '')
    for l in data['lyrics']:
        if not isinstance(l, dict) or not l.get('text') or l.get('translated'):
            continue
        if zh and _line_is_already_chinese(l['text']):
            continue
        return True
    return False


def find_untranslated(lang=''):
    """Scan cache/lyrics for entries with lines still missing translations.
    Returns [{key, lang, data}]. Expired entries included (re-caching them
    revives the TTL). Never raises."""
    from .cache import _cache_key_from_filename
    out = []
    lyrics_dir = 'cache/lyrics'
    try:
        names = os.listdir(lyrics_dir)
    except Exception:
        return out
    for fname in names:
        try:
            key = _cache_key_from_filename(fname)
            if key is None or key.endswith(':fast'):
                continue
            parts = key.split(':')
            klang = parts[-1]
            if lang and klang != lang:
                continue
            with open(os.path.join(lyrics_dir, fname), 'r',
                      encoding='utf-8') as f:
                entry = json.load(f)
            data = entry.get('data')
            if not data or 'not_found' in data:
                continue
            if _needs_translation(data, klang):
                out.append({'key': key, 'lang': klang, 'data': data})
        except Exception:
            continue
    return out


def translate_queue_stats():
    with _TQ_LOCK:
        s = dict(_TQ_STATS)
    s['pending'] = s['queued'] - s['done'] - s['errors']
    return s


