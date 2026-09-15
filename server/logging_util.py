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
from flask import Flask, request, jsonify, render_template, session, redirect, url_for, Response, stream_with_context
from .app import (_recent_logs, _structured_logs, _crash_logs,
    SERVER_INSTANCE_ID, SERVER_START_TIME, SERVER_START_TS,
    LOG_DIR, SERVER_LOG_FILE, CRASH_LOG_FILE, UI_DUMP_DIR)

def _classify_log(msg):
    """Classify a log message into (level, icon) based on content."""
    stripped = msg.strip()
    if not stripped:
        return None, None
    # Filter out HTTP polling noise / Werkzeug access logs
    if 'HTTP/1.' in stripped or 'GET /api/admin/' in stripped or 'POST /api/admin/' in stripped:
        return None, None
    if re.search(r'\d+\.\d+\.\d+\.\d+ - - \[.*\] ".*" \d+', stripped):
        return None, None
    if stripped.startswith(('Error', 'error', 'Traceback')):
        return 'error', 'error'
    # Plain tag mapping (FontAwesome solid icons, no emoji literals per style)
    tag_map = {
        '[OK]': ('success', 'fa-circle-check'),
        '[FAIL]': ('error', 'fa-circle-xmark'),
        '[WARN]': ('warning', 'fa-triangle-exclamation'),
        '[WAIT]': ('pending', 'fa-hourglass-half'),
        '[SEARCH]': ('info', 'fa-magnifying-glass'),
        '[TRANS]': ('translate', 'fa-language'),
        '[SEND]': ('response', 'fa-paper-plane'),
        '[REQ': ('request', 'fa-search'),
        '[CLEAN]': ('info', 'fa-broom'),
        '[DUMP]': ('info', 'fa-file-arrow-up'),
        '[MUSIC]': ('info', 'fa-music'),
        '[iOS': ('device', 'fa-mobile-screen'),
        '[ALERT]': ('warning', 'fa-bell'),
        '[CRASH]': ('error', 'fa-circle-exclamation'),
        '[EXC]': ('error', 'fa-circle-exclamation'),
    }
    for tag, (level, icon) in tag_map.items():
        if tag in stripped:
            return level, icon
    kw_map = [
        ('[iOS Tweak]', 'device', 'fa-mobile-screen'),
        ('[REQ', 'request', 'fa-search'),
        ('[UI_DUMP]', 'device', 'fa-mobile-screen'),
        ('[CRASH]', 'error', 'fa-circle-exclamation'),
        ('[EXC]', 'error', 'fa-circle-exclamation'),
        ('Cache hit', 'success', 'fa-database'),
        ('Cache miss', 'warning', 'fa-database'),
        ('Got result from in-flight', 'success', 'fa-database'),
        ('Returning', 'response', 'fa-upload'),
        ('Waiting for in-flight', 'pending', 'fa-hourglass-half'),
        ('Looking up', 'info', 'fa-magnifying-glass'),
        ('Trying Cubey', 'info', 'fa-cloud'),
        ('Trying LRCLIB', 'info', 'fa-cloud'),
        ('Trying Unison', 'info', 'fa-cloud'),
        ('Trying YouTube', 'info', 'fa-cloud'),
        ('Translating', 'translate', 'fa-language'),
        ('Cohere', 'translate', 'fa-language'),
        ('Cleaned', 'info', 'fa-broom'),
        ('Saved to', 'success', 'fa-floppy-disk'),
        ('Rate limited', 'warning', 'fa-gauge'),
        ('All keys failed', 'error', 'fa-key'),
        ('[In-Flight]', 'pending', 'fa-hourglass-half'),
        ('[Provider]', 'info', 'fa-cloud'),
        ('[Cache]', 'success', 'fa-database'),
    ]
    for keyword, level, icon in kw_map:
        if keyword in stripped:
            return level, icon
    if stripped.startswith('  '):
        return 'detail', 'fa-arrow-right'
    return 'info', 'fa-circle-info'


class LogTee:
    def __init__(self, original_stream, log_file=None):
        self.original_stream = original_stream
        self.log_file = log_file

    def write(self, message):
        # Handle bytes from click/flask (e.g. show_server_banner)
        if isinstance(message, bytes):
            try:
                message = message.decode('utf-8', errors='replace')
            except:
                message = str(message)
        try:
            self.original_stream.write(message)
        except:
            # If original expects bytes, try bytes
            try:
                self.original_stream.write(message.encode('utf-8', errors='replace'))
            except: pass
        # Persist to file
        if self.log_file and message and message.strip():
            try:
                with open(self.log_file, 'a', encoding='utf-8') as f:
                    f.write(message if message.endswith('\n') else message + '\n')
            except: pass
        if message:
            stripped = message.strip()
            if 'HTTP/1.' in stripped or 'GET /api/admin/' in stripped or 'POST /api/admin/' in stripped:
                return
            _recent_logs.append(message)
            if stripped and stripped != '=' * 60:
                level, icon = _classify_log(stripped)
                if level:
                    entry = {
                        'ts': datetime.now().strftime('%H:%M:%S'),
                        'level': level,
                        'icon': icon or 'info',
                        'msg': stripped,
                    }
                    _structured_logs.append(entry)
                    try:
                        from .app import _sse_broadcast
                        _sse_broadcast('log', entry)
                    except Exception:
                        pass

    def flush(self):
        try: self.original_stream.flush()
        except: pass
        if self.log_file:
            try:
                with open(self.log_file, 'a', encoding='utf-8'): pass
            except: pass

if not os.path.exists('logs'):
    os.makedirs('logs')
# Rotate server.log if too large (>5MB)
try:
    if os.path.exists(SERVER_LOG_FILE) and os.path.getsize(SERVER_LOG_FILE) > 5*1024*1024:
        os.rename(SERVER_LOG_FILE, SERVER_LOG_FILE + ".1")
except: pass

sys.stdout = LogTee(sys.stdout, log_file=SERVER_LOG_FILE)
sys.stderr = LogTee(sys.stderr, log_file=CRASH_LOG_FILE)

def _log_crash(exc_type, exc_val, exc_tb):
    msg = ''.join(traceback.format_exception(exc_type, exc_val, exc_tb))
    entry = {
        'ts': datetime.now().isoformat(),
        'type': exc_type.__name__ if exc_type else 'Unknown',
        'msg': str(exc_val)[:500],
        'trace': msg[:4000],
        'instance': SERVER_INSTANCE_ID,
    }
    _crash_logs.append(entry)
    # also write to crash file and structured logs
    try:
        with open(CRASH_LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(f"\n[{entry['ts']}] [CRASH] {entry['type']}: {entry['msg']}\n{msg}\n")
    except: pass
    try: print(f"[CRASH] {entry['type']}: {entry['msg']}")
    except: pass
    # also push to structured for UI
    crash_entry = {'ts': datetime.now().strftime('%H:%M:%S'), 'level': 'error', 'icon': 'fa-circle-exclamation', 'msg': f"[CRASH] {entry['type']}: {entry['msg']}"}
    _structured_logs.append(crash_entry)
    try:
        from .app import _sse_broadcast
        _sse_broadcast('log', crash_entry)
        _sse_broadcast('crash', entry)
    except Exception:
        pass

# Global crash handlers - prevent silent death
_old_excepthook = sys.excepthook
def _global_excepthook(exc_type, exc_val, exc_tb):
    _log_crash(exc_type, exc_val, exc_tb)
    try: _old_excepthook(exc_type, exc_val, exc_tb)
    except: pass
sys.excepthook = _global_excepthook

_old_thread_excepthook = getattr(threading, 'excepthook', None)
def _thread_excepthook(args):
    _log_crash(args.exc_type, args.exc_value, args.exc_traceback)
    if _old_thread_excepthook:
        try: _old_thread_excepthook(args)
        except: pass
threading.excepthook = _thread_excepthook

def _handle_uncaught_exception(e):
    _log_crash(type(e), e, e.__traceback__)
    return jsonify({'error': 'Internal server error', 'instance': SERVER_INSTANCE_ID}), 500

