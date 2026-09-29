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
from .parsers_lrc import is_cjk

def parse_ttml_basic(ttml_text, duration_sec=0):
    """Basic TTML parser - extracts timed lines from TTML/AMLL XML."""
    try:
        import xml.etree.ElementTree as ET

        # Fix common namespace issues
        ttml_text = re.sub(r'xmlns:amll="[^"]*"', '', ttml_text)
        ttml_text = re.sub(r'amll:', '', ttml_text)

        # Remove default namespace for easier parsing
        ttml_text = re.sub(r'xmlns="[^"]*"', '', ttml_text)

        root = ET.fromstring(ttml_text)

        # ---------------------------------------------------------------
        # Authoritative line text, when the file provides it.
        #
        # Some TTML (lrc.red / BiniLyrics) keeps the real line text in a
        # <translation><text for="L3">Here's a ticket</text></translation>
        # block, keyed to each <p> by an lrc:key attribute, and puts only
        # timed <span>s in the line itself. Those spans are the romanised
        # source and are split FINER than words, so joining them mangles the
        # text ("Here's a" + "tic" + "ket" -> "Here's a tic ket"), and for a
        # Korean track the spans are the Korean original while the <text>
        # block is the English line. Rebuilding `text` from spans therefore
        # produced a wrong line on 24 of 53 lines in the file that prompted
        # this. Prefer the declared text; fall back to the span join.
        # ---------------------------------------------------------------
        line_texts = {}
        for t in root.iter('text'):
            ref = t.get('for')
            if not ref:
                continue
            val = ''.join(t.itertext()).strip() if list(t) else (t.text or '').strip()
            if val:
                # First writer wins: a later <translation> block must not
                # clobber the first one that actually had text.
                line_texts.setdefault(ref, val)

        def _line_key(node):
            for k, v in node.attrib.items():
                if k == 'key' or k.endswith('}key'):
                    return v
            return None

        results = []

        # Find all <p> elements (lines)
        for p in root.iter('p'):
            begin = p.get('begin', p.get('{http://www.w3.org/ns/ttml}begin', ''))
            end = p.get('end', p.get('{http://www.w3.org/ns/ttml}end', ''))

            if not begin:
                continue

            start_ms = parse_ttml_time(begin)
            end_ms = parse_ttml_time(end) if end else start_ms + 5000

            # Get text content
            text_parts = []
            parts = []

            # Check for spans (word-level sync)
            spans = list(p.iter('span'))
            if spans:
                # Spacing belongs to the source, not to us. Apple splits a held
                # word down the middle ("foll" + "ow" for "follow") and writes NO
                # whitespace between the two spans, while a real word gap always
                # carries one. Inventing a space at every join turned those into
                # "foll ow" -- 6 lines of Die With A Smile -- and the device
                # rebuilds the display text from parts, so it showed the mangled
                # line even when the server text was already right. A line whose
                # spans carry no inter-span whitespace at all keeps the old
                # space-after-each-word join: there a missing tail tells us
                # nothing, and the file may simply be one that never uses them.
                tails = [(span.tail or '') for span in spans]
                has_gap = any(ch.isspace() for tail in tails for ch in tail)
                glued = False
                for idx, span in enumerate(spans):
                    span_begin = span.get('begin', '')
                    span_end = span.get('end', '')
                    span_text = (span.text or '')

                    # Preserving spacing between words
                    clean_word = span_text
                    this_glued = glued
                    glued = False
                    if any(ch.isspace() for ch in tails[idx]):
                        if not clean_word.endswith(' '):
                            clean_word += ' '
                    elif idx < len(spans) - 1:
                        if has_gap:
                            # Mid-word split: the source glued these two spans.
                            glued = True
                        elif not is_cjk(span_text):
                            if not clean_word.endswith(' '):
                                clean_word += ' '

                    if clean_word.strip():
                        text_parts.append(clean_word)
                        if span_begin:
                            s_begin_ms = parse_ttml_time(span_begin)
                            # Handle relative timestamp (e.g. begin="0.5s" in a line starting at 40s)
                            if s_begin_ms < start_ms:
                                s_begin_ms = start_ms + s_begin_ms
                            s_end_ms = parse_ttml_time(span_end) if span_end else 0
                            if s_end_ms > 0 and s_end_ms < start_ms:
                                s_end_ms = start_ms + s_end_ms
                            dur_ms = s_end_ms - s_begin_ms if s_end_ms > s_begin_ms else 0
                            part = {
                                'startTimeMs': s_begin_ms,
                                'words': clean_word,
                                'durationMs': dur_ms
                            }
                            # The device joins parts with a space unless a part
                            # says otherwise, so a mid-word split has to say so.
                            if this_glued:
                                part['space'] = False
                            parts.append(part)
            else:
                p_text = (p.text or '').strip()
                if p_text:
                    text_parts = [p_text]

            full_text = re.sub(r' +', ' ', ''.join(text_parts)).strip()
            # The declared line text wins over the span join. Keep the join
            # only as the fallback for files with no <text for> block.
            declared = line_texts.get(_line_key(p))
            if declared:
                full_text = declared
            if not full_text:
                continue

            line_duration_ms = end_ms - start_ms

            entry = {
                'time': round(start_ms / 1000.0, 3),
                'startTimeMs': start_ms,
                'text': full_text,
                'durationMs': line_duration_ms,
                'duration': round(line_duration_ms / 1000.0, 3),
                'wordSynced': False
            }
            # Only genuine word-by-word timestamps count; never fabricate fake wbw from line-by-line
            if parts and len(parts) > 1 and len({p.get('startTimeMs') for p in parts}) > 1:
                entry['parts'] = parts
                entry['wordSynced'] = True

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


