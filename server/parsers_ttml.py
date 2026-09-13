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
                for idx, span in enumerate(spans):
                    span_begin = span.get('begin', '')
                    span_end = span.get('end', '')
                    span_text = (span.text or '')
                    tail_text = (span.tail or '')

                    # Preserving spacing between words
                    clean_word = span_text
                    if tail_text and ' ' in tail_text:
                        if not clean_word.endswith(' '):
                            clean_word += ' '
                    elif not is_cjk(clean_word) and idx < len(spans) - 1:
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
                            parts.append({
                                'startTimeMs': s_begin_ms,
                                'words': clean_word,
                                'durationMs': dur_ms
                            })
            else:
                p_text = (p.text or '').strip()
                if p_text:
                    text_parts = [p_text]

            full_text = re.sub(r' +', ' ', ''.join(text_parts)).strip()
            if not full_text:
                continue

            line_duration_ms = end_ms - start_ms
            if not parts or len(parts) == 0:
                parts = generate_interpolated_parts(full_text, start_ms, line_duration_ms)

            entry = {
                'time': round(start_ms / 1000.0, 3),
                'startTimeMs': start_ms,
                'text': full_text,
                'durationMs': line_duration_ms,
                'duration': round(line_duration_ms / 1000.0, 3)
            }
            if parts:
                entry['parts'] = parts
                entry['wordSynced'] = bool(spans)

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


