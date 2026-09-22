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
# Cohere Translate (Command A Translate - free tier)
# ============================================================

COHERE_API_KEYS = [
    "XlQ23B0II2OEgSO1sNa1mWXgiuMsuYcGWBAblLfX",
    "8SNdZXeGNQwTLaZQz6bpHWKW5SnnujUbMBgpi1jJ",
    "ZpSlGaleZDIWf5WnzJrxxz2fAEv26Xc7vdZgyqiz",
    "gGIDUA29FUdmauU7rden49bWXRurTThqzbbBEqNy",
]
_cohere_key_idx = 0

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
    key = COHERE_API_KEYS[_cohere_key_idx % len(COHERE_API_KEYS)]
    return key

def rotate_cohere_key():
    global _cohere_key_idx
    _cohere_key_idx += 1
    print(f"  [Cohere] Rotated to key index {_cohere_key_idx % len(COHERE_API_KEYS)}")

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


def cohere_translate(texts, target_lang='zh-TW'):
    """Translate a list of text lines using Cohere Command A Translate."""
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
    # entirely and only get a script conversion pass at the end.
    chinese_target = _is_chinese_target(target_lang)
    if chinese_target:
        to_translate_idx = [i for i, t in enumerate(texts) if not _line_is_already_chinese(t)]
    else:
        to_translate_idx = list(range(len(texts)))

    results = list(texts)  # default: keep original line

    if to_translate_idx:
        subset = [texts[i] for i in to_translate_idx]
        translated_subset = _cohere_translate_raw(subset, target_lang)
        for local_i, global_i in enumerate(to_translate_idx):
            results[global_i] = translated_subset[local_i]
    else:
        print(f"  [Cohere] All {len(texts)} line(s) already {LANG_NAMES.get(target_lang, target_lang)}, skipping API call")

    if chinese_target:
        results = _apply_zh_script(results, target_lang)

    set_translate_cached(cache_key, results)
    return results


def _cohere_translate_raw(texts, target_lang):
    """Send exactly these lines to Cohere and return them translated, in order.
    Falls back to returning the originals if every key fails."""
    if not texts:
        return []

    lang_name = LANG_NAMES.get(target_lang, target_lang)

    # Join all lines with a numbered marker for reliable splitting
    numbered = [f"[{i+1}] {t}" for i, t in enumerate(texts)]
    joined = '\n'.join(numbered)

    prompt = (
        f"Translate the following song lyrics into {lang_name}. "
        f"Keep the same numbered format [1], [2], etc. "
        f"These are song lyrics, so keep the poetic style and meaning intact. "
        f"IMPORTANT: Do not translate onomatopoeia, scat singing, or nonsense words (like 'ba ba', 'la la') literally. Leave them as-is or transliterate them. "
        f"If a line is already in {lang_name} or is romanization/gibberish, keep it as-is. "
        f"Return ONLY the translated lines with their numbers, nothing else.\n\n"
        f"{joined}"
    )

    for attempt in range(len(COHERE_API_KEYS)):
        try:
            api_key = get_cohere_key()
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
            return [result_map.get(i+1, texts[i]) for i in range(len(texts))]

        except Exception as e:
            print(f"  [Cohere] Exception: {e}")
            rotate_cohere_key()

    # Fallback: return originals
    print(f"  [Cohere] All keys failed, returning originals")
    return texts


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
    for batch in batches:
        joined = delimiter.join(batch)
        try:
            url = f"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl={target_lang}&dt=t&q={quote(joined)}"
            resp = requests.get(url, timeout=8, headers={'User-Agent': 'Mozilla/5.0'})
            if resp.status_code == 200:
                data = resp.json()
                translated = ''.join(part[0] for part in data[0] if part[0])
                parts = translated.split(';')
                if len(parts) == len(batch):
                    all_translations.extend([p.strip() for p in parts])
                else:
                    lines = [t.strip() for t in translated.split('\n') if t.strip()]
                    while len(lines) < len(batch): lines.append('')
                    all_translations.extend(lines[:len(batch)])
            else:
                all_translations.extend(['' for _ in batch])
        except Exception as e:
            all_translations.extend(['' for _ in batch])

    if _is_chinese_target(target_lang):
        all_translations = _apply_zh_script(all_translations, target_lang)

    set_translate_cached(cache_key, all_translations)
    return all_translations


