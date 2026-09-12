from flask import Flask, request, jsonify, render_template, session, redirect, url_for, Response, stream_with_context
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

app = Flask(__name__)

# ============================================================
# Admin config -- persisted to config/admin_config.json
# ============================================================
import secrets as _secrets

_ADMIN_CONFIG_FILE = os.path.join('config', 'admin_config.json')

def _load_admin_config():
    if os.path.exists(_ADMIN_CONFIG_FILE):
        with open(_ADMIN_CONFIG_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    cfg = {'secret_key': _secrets.token_hex(32), 'password_hash': None}
    _save_admin_config(cfg)
    return cfg

def _save_admin_config(cfg):
    os.makedirs('config', exist_ok=True)
    with open(_ADMIN_CONFIG_FILE, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2)

_admin_cfg = _load_admin_config()
app.secret_key = _admin_cfg['secret_key']


def login_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('admin_logged_in'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated


import logging
import uuid
import traceback
import atexit
logging.getLogger('werkzeug').setLevel(logging.ERROR)

# Server instance identity - regenerated on each start
SERVER_INSTANCE_ID = str(uuid.uuid4())
SERVER_START_TIME = datetime.now()
SERVER_START_TS = SERVER_START_TIME.isoformat()

_recent_logs = deque(maxlen=800)
_structured_logs = deque(maxlen=500)
_recent_requests = deque(maxlen=100)
_crash_logs = deque(maxlen=100)

# Persistent log files
LOG_DIR = "logs"
SERVER_LOG_FILE = os.path.join(LOG_DIR, "server.log")
CRASH_LOG_FILE = os.path.join(LOG_DIR, "crash.log")
UI_DUMP_DIR = LOG_DIR

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
    # Plain tag mapping (no emoji literals per style)
    tag_map = {
        '[OK]': ('success', 'check_circle'),
        '[FAIL]': ('error', 'cancel'),
        '[WARN]': ('warning', 'warning'),
        '[WAIT]': ('pending', 'hourglass_empty'),
        '[SEARCH]': ('info', 'person_search'),
        '[TRANS]': ('translate', 'translate'),
        '[SEND]': ('response', 'upload'),
        '[REQ': ('request', 'search'),
        '[CLEAN]': ('info', 'delete_sweep'),
        '[DUMP]': ('info', 'upload_file'),
        '[MUSIC]': ('info', 'music_note'),
        '[iOS': ('device', 'phone_iphone'),
        '[ALERT]': ('warning', 'notification_important'),
        '[CRASH]': ('error', 'error'),
        '[EXC]': ('error', 'error'),
    }
    for tag, (level, icon) in tag_map.items():
        if tag in stripped:
            return level, icon
    kw_map = [
        ('[iOS Tweak]', 'device', 'phone_iphone'),
        ('[REQ', 'request', 'search'),
        ('[UI_DUMP]', 'device', 'phone_iphone'),
        ('[CRASH]', 'error', 'error'),
        ('[EXC]', 'error', 'error'),
        ('Cache hit', 'success', 'cached'),
        ('Cache miss', 'warning', 'cached'),
        ('Got result from in-flight', 'success', 'cached'),
        ('Returning', 'response', 'upload'),
        ('Waiting for in-flight', 'pending', 'hourglass_empty'),
        ('Looking up', 'info', 'person_search'),
        ('Trying Cubey', 'info', 'cloud'),
        ('Trying LRCLIB', 'info', 'cloud'),
        ('Trying Unison', 'info', 'cloud'),
        ('Trying YouTube', 'info', 'cloud'),
        ('Translating', 'translate', 'translate'),
        ('Cohere', 'translate', 'translate'),
        ('Cleaned', 'info', 'delete_sweep'),
        ('Saved to', 'success', 'save'),
        ('Rate limited', 'warning', 'speed'),
        ('All keys failed', 'error', 'vpn_key_off'),
        ('[In-Flight]', 'pending', 'hourglass_empty'),
        ('[Provider]', 'info', 'cloud'),
        ('[Cache]', 'success', 'cached'),
    ]
    for keyword, level, icon in kw_map:
        if keyword in stripped:
            return level, icon
    if stripped.startswith('  '):
        return 'detail', 'subdirectory_arrow_right'
    return 'info', 'info'


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
                    _structured_logs.append({
                        'ts': datetime.now().strftime('%H:%M:%S'),
                        'level': level,
                        'icon': icon or 'info',
                        'msg': stripped,
                    })

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
    _structured_logs.append({'ts': datetime.now().strftime('%H:%M:%S'), 'level': 'error', 'icon': 'error', 'msg': f"[CRASH] {entry['type']}: {entry['msg']}"})

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

# ============================================================
# Self-Update (server file) — supports any filename like app.py / main.py / bot.py
# ============================================================
SELF_UPDATE_REPO = "ChiuHuang/ytmusicultimate"
SELF_UPDATE_BRANCH = "main"
# Remote path is always proxy_server.py in repo; local target is auto-detected via __file__
# but user can override via config/admin_config.json -> {"main_file": "app.py"} or env MAIN_FILE
SELF_UPDATE_REMOTE_PATH = "proxy_server.py"

def _get_main_file():
    # Priority: admin_config main_file > env MAIN_FILE > current __file__
    try:
        cfg = _admin_cfg.get('main_file')
        if cfg:
            # allow relative or absolute
            if os.path.isabs(cfg):
                return cfg
            # relative to workspace root
            base = os.path.dirname(os.path.abspath(__file__))
            cand = os.path.join(base, cfg)
            return cand
    except: pass
    env = os.environ.get('MAIN_FILE')
    if env:
        if os.path.isabs(env):
            return env
        base = os.path.dirname(os.path.abspath(__file__))
        return os.path.join(base, env)
    return os.path.abspath(__file__)

def _get_local_sha():
    # Try git first, fallback to file hash
    try:
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], stderr=subprocess.DEVNULL, text=True).strip()
        if sha:
            return sha
    except: pass
    try:
        # file hash
        p = _get_main_file()
        if os.path.exists(p):
            h = hashlib.sha256(open(p, 'rb').read()).hexdigest()[:12]
            return h
    except: pass
    return "unknown"

def _get_remote_sha():
    try:
        r = requests.get(f"https://api.github.com/repos/{SELF_UPDATE_REPO}/commits/{SELF_UPDATE_BRANCH}", headers={'Accept': 'application/vnd.github+json'}, timeout=8)
        r.raise_for_status()
        j = r.json()
        sha = j.get('sha')
        # also get parent sha for info
        parents = j.get('parents', [])
        parent_sha = parents[0].get('sha') if parents else None
        return sha, parent_sha, j
    except Exception as e:
        print(f"[SELF-UPDATE] remote sha fetch failed: {e}")
        return None, None, None

def _fetch_remote_file(sha=None):
    # Fetch raw file content for given sha or branch
    try:
        # Use raw.githubusercontent with branch
        url = f"https://raw.githubusercontent.com/{SELF_UPDATE_REPO}/{SELF_UPDATE_BRANCH}/{SELF_UPDATE_REMOTE_PATH}"
        # If sha provided, use cdn with sha
        if sha:
            url = f"https://raw.githubusercontent.com/{SELF_UPDATE_REPO}/{sha}/{SELF_UPDATE_REMOTE_PATH}"
        r = requests.get(url, timeout=15)
        if r.status_code == 200:
            return r.text
        print(f"[SELF-UPDATE] fetch failed {r.status_code}")
    except Exception as e:
        print(f"[SELF-UPDATE] fetch error: {e}")
    return None

def _perform_self_update():
    local_file = _get_main_file()
    local_sha = _get_local_sha()
    remote_sha, parent_sha, remote_meta = _get_remote_sha()
    if not remote_sha:
        return False, "Could not fetch remote SHA"
    if local_sha == remote_sha:
        return False, "Already up to date"
    content = _fetch_remote_file(remote_sha)
    if not content:
        content = _fetch_remote_file(None)
    if not content:
        return False, "Could not fetch remote file"
    # Basic sanity: must contain Flask app and not be empty
    if "Flask" not in content or len(content) < 5000:
        return False, "Remote file looks invalid"
    # Backup
    try:
        backup = local_file + f".backup.{int(time_module.time())}"
        if os.path.exists(local_file):
            import shutil
            shutil.copy2(local_file, backup)
            print(f"[SELF-UPDATE] backup saved to {backup} (parent={parent_sha})")
    except Exception as e:
        print(f"[SELF-UPDATE] backup failed: {e}")
    # Write new file
    try:
        # Ensure LF and no BOM
        content = content.replace("\r\n", "\n")
        if content.startswith("\ufeff"):
            content = content[1:]
        with open(local_file, 'w', encoding='utf-8', newline='\n') as f:
            f.write(content)
        print(f"[SELF-UPDATE] updated {local_file} from {local_sha} -> {remote_sha} parent={parent_sha}")
        # Write update meta for web UI
        try:
            meta_path = os.path.join(LOG_DIR, "self_update.json")
            with open(meta_path, 'w', encoding='utf-8') as mf:
                json.dump({"local_before": local_sha, "remote": remote_sha, "parent": parent_sha, "file": local_file, "ts": datetime.now().isoformat()}, mf, indent=2)
        except: pass
        return True, f"Updated {os.path.basename(local_file)} {local_sha[:7]} -> {remote_sha[:7]} parent {parent_sha[:7] if parent_sha else 'none'}"
    except Exception as e:
        print(f"[SELF-UPDATE] write failed: {e}")
        _log_crash(type(e), e, e.__traceback__)
        return False, str(e)

# ============================================================
# LRC Parser & Karaoke Interpolation
# ============================================================

def is_cjk(text):
    for c in text:
        if '\u4e00' <= c <= '\u9fff' or '\u3040' <= c <= '\u30ff':
            return True
    return False

def generate_interpolated_parts(text, start_ms, duration_ms):
    """Generate proportional word/character timestamps across line duration when provider lacks word-sync."""
    if not text or duration_ms <= 200:
        return []
    text = text.strip()
    if is_cjk(text):
        tokens = [c for c in text if c.strip()]
        if not tokens: return []
        parts = []
        for c in tokens:
            parts.append({'words': c, 'weight': 1})
    else:
        words = text.split()
        if not words: return []
        parts = []
        for i, w in enumerate(words):
            display = w + (' ' if i < len(words) - 1 else '')
            parts.append({'words': display, 'weight': max(len(w), 1)})

    total_weight = sum(p['weight'] for p in parts)
    sung_dur = max(duration_ms * 0.88, duration_ms - 400) if duration_ms > 800 else duration_ms
    curr_ms = start_ms
    res = []
    for p in parts:
        p_dur = max(100, int(sung_dur * (p['weight'] / total_weight)))
        res.append({
            'startTimeMs': curr_ms,
            'words': p['words'],
            'durationMs': p_dur
        })
        curr_ms += p_dur
    return res

def parse_lrc(lrc_text, duration_sec=0):
    """Parse LRC format into structured JSON array.
    Supports standard [mm:ss.xx] and enhanced <mm:ss.xx> word-sync tags.
    """
    lines = lrc_text.strip().split('\n')
    result = []
    offset_ms = 0

    time_regex = re.compile(r'\[(\d+):(\d+)\.(\d+)\]')
    word_regex = re.compile(r'<(\d+):(\d+)\.(\d+)>')
    id_tag_regex = re.compile(r'^\[(\w+):(.*)\]$')

    def parse_time_tag(m, s, cs):
        minutes = int(m)
        seconds = int(s)
        cs_str = str(cs)
        if len(cs_str) == 2:
            ms = int(cs_str) * 10
        elif len(cs_str) == 1:
            ms = int(cs_str) * 100
        else:
            ms = int(cs_str[:3])
        return minutes * 60000 + seconds * 1000 + ms

    for line in lines:
        line = line.strip()
        if not line:
            continue

        # Check for offset tag
        id_match = id_tag_regex.match(line)
        if id_match and id_match.group(1) == 'offset':
            try:
                offset_ms = int(id_match.group(2))
            except:
                pass
            continue
        if id_match and id_match.group(1) in ['ti', 'ar', 'al', 'au', 'lr', 'length', 'by', 're', 'tool', 've', '#']:
            continue

        # Extract time tags
        time_matches = list(time_regex.finditer(line))
        if not time_matches:
            continue

        text = time_regex.sub('', line).strip()
        if not text:
            continue

        # Parse word-level sync if present (<mm:ss.xx>word)
        parts = []
        word_matches = list(word_regex.finditer(text))
        if word_matches:
            plain_text = re.sub(r'\s+', ' ', word_regex.sub('', text)).strip()

            # Check for leading text before first tag
            first_match = word_matches[0]
            current_parts = []
            if first_match.start() > 0:
                lead = text[:first_match.start()].strip()
                if lead:
                    current_parts.append({
                        'startTimeMs': 0, # Will be set to line start_ms
                        'words': lead + (' ' if not is_cjk(lead) else ''),
                        'durationMs': 0
                    })

            # Find tokens: (<time>) followed by chars up to next tag
            tokens = re.findall(r'<(\d+):(\d+)\.(\d+)>([^<]*)', text)
            for tm_min, tm_sec, tm_cs, word_str in tokens:
                w_ms = parse_time_tag(tm_min, tm_sec, tm_cs) + offset_ms
                clean_word = word_str
                if clean_word:
                    current_parts.append({
                        'startTimeMs': w_ms,
                        'words': clean_word,
                        'durationMs': 0
                    })

            # Calculate durations for each word part
            for pi in range(len(current_parts)):
                if pi < len(current_parts) - 1:
                    dur = current_parts[pi+1]['startTimeMs'] - current_parts[pi]['startTimeMs']
                    current_parts[pi]['durationMs'] = max(dur, 0)
                else:
                    current_parts[pi]['durationMs'] = 500

            parts = current_parts
            text = plain_text

        for tm in time_matches:
            start_ms = parse_time_tag(tm.group(1), tm.group(2), tm.group(3)) + offset_ms

            entry_parts = []
            if parts:
                import copy
                entry_parts = copy.deepcopy(parts)
                # If first part was leading text with 0, bind to start_ms
                if entry_parts and entry_parts[0]['startTimeMs'] == 0:
                    entry_parts[0]['startTimeMs'] = start_ms

            entry = {
                'time': round(start_ms / 1000.0, 3),
                'startTimeMs': start_ms,
                'text': text,
                'durationMs': 0
            }
            if entry_parts:
                entry['parts'] = entry_parts
                # Enhanced LRC carries real per-word timestamps. Generated
                # timings must never be treated as karaoke data by clients.
                entry['wordSynced'] = True

            result.append(entry)

    # Sort by time
    result.sort(key=lambda x: x['startTimeMs'])

    # Calculate durations
    duration_ms = duration_sec * 1000
    for i in range(len(result)):
        if i < len(result) - 1:
            result[i]['durationMs'] = result[i+1]['startTimeMs'] - result[i]['startTimeMs']
        else:
            result[i]['durationMs'] = max(int(duration_ms - result[i]['startTimeMs']), 3000)
        result[i]['duration'] = round(result[i]['durationMs'] / 1000.0, 3)

        # Keep generated parts for layout consumers, but mark them as
        # non-authoritative so clients do not fake word-by-word highlighting.
        if not result[i].get('parts') or len(result[i]['parts']) == 0:
            result[i]['parts'] = generate_interpolated_parts(result[i]['text'], result[i]['startTimeMs'], result[i]['durationMs'])
            result[i]['wordSynced'] = False
        else:
            # Sanitize existing parts
            p_list = result[i]['parts']
            l_start = result[i]['startTimeMs']
            prev_ms = l_start
            for pi, p in enumerate(p_list):
                if not p.get('startTimeMs') or p['startTimeMs'] < l_start:
                    p['startTimeMs'] = prev_ms + (0 if pi == 0 else 200)
                prev_ms = p['startTimeMs']
            for pi in range(len(p_list)):
                if pi < len(p_list) - 1:
                    dur = p_list[pi+1]['startTimeMs'] - p_list[pi]['startTimeMs']
                    p_list[pi]['durationMs'] = max(dur, 0)
                else:
                    p_list[pi]['durationMs'] = max(result[i]['startTimeMs'] + result[i]['durationMs'] - p_list[pi]['startTimeMs'], 200)

    return result


def parse_plain(plain_text):
    """Parse plain (unsynced) lyrics."""
    lines = plain_text.strip().split('\n')
    result = []
    for line in lines:
        text = line.strip()
        if text:
            result.append({
                'time': 0,
                'startTimeMs': 0,
                'text': text,
                'durationMs': 0,
                'duration': 0
            })
    return result


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

_QRC_CREDIT_RE = re.compile(r'\b(lyrics|composed|arranged|produced|written|vocals?|chorus|mixed|mastered)\s*by\b', re.I)

def _qrc_tag(ms, bracket=True):
    ms = max(int(ms), 0)
    tag = f"{ms // 60000:02d}:{(ms % 60000) // 1000:02d}.{(ms % 1000) // 10:02d}"
    return f"[{tag}]" if bracket else f"<{tag}>"

def _qrc_clean_text(text):
    text = re.sub(r'\s+([.,!?;:\'")\]}])', r'\1', text)
    text = re.sub(r'([(\["\'])\s+', r'\1', text)
    return re.sub(r'\s+', ' ', text).strip()

def parse_qrc_to_lrc(blob):
    """Convert QQ QRC payload to enhanced LRC. Returns LRC string or None."""
    if isinstance(blob, dict):
        blob = blob.get('lyrics', '')
    if not isinstance(blob, str) or not blob:
        return None
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
        return None
    # Tolerate partially-decoded escapes
    if '\\n' in s and '\n' not in s:
        s = s.replace('\\n', '\n')
    # Title text (ti:) marks the header line to drop (it carries timed words)
    ti_match = re.search(r'\[ti:(.*?)\]', s)
    ti_text = _qrc_clean_text(ti_match.group(1)) if ti_match else ''

    out_lines = []
    for m in re.finditer(r'\[(\d+),(\d+)\]([^\[]*)', s):
        line_start, seg = int(m.group(1)), m.group(3)
        els = re.split(r'\((\d+),(\d+)\)', seg)
        n = (len(els) - 1) // 3
        if n <= 0:
            continue  # metadata ([ti:]/[ar:]/[offset:]) or wordless line
        words = []
        for k in range(1, n + 1):
            txt = els[3 * k - 3].strip()
            if not txt:
                continue
            off, dur = int(els[3 * k - 2]), int(els[3 * k - 1])
            start = off if off >= line_start else line_start + off
            words.append((txt, start, max(dur, 1)))
        if not words:
            continue
        text = _qrc_clean_text(' '.join(w for w, _, _ in words))
        if not text:
            continue
        if ti_text and ti_text in text:
            continue
        if _QRC_CREDIT_RE.search(text):
            continue
        line = _qrc_tag(line_start)
        for w, start, dur in words:
            line += _qrc_tag(start, bracket=False) + w + ' '
        out_lines.append(line.rstrip())
    if not out_lines:
        return None
    return '\n'.join(out_lines)


# ============================================================
# Provider 1: LRCLIB (free, no auth)
# ============================================================

def fetch_lrclib(title, artist, album='', duration=0):
    """Fetch lyrics from LRCLIB. Tries exact match, then search with strict validation."""
    headers = {'User-Agent': 'YTMusicUltimate/1.0 (https://github.com/user/ytmusicultimate)'}

    # Exact match
    try:
        params = {'track_name': title, 'artist_name': artist}
        if album:
            params['album_name'] = album
        if duration:
            params['duration'] = duration

        resp = requests.get('https://lrclib.net/api/get', params=params, timeout=8, headers=headers)
        if resp.status_code == 200:
            data = resp.json()
            if data.get('syncedLyrics') or data.get('plainLyrics'):
                return {
                    'synced': data.get('syncedLyrics'),
                    'plain': data.get('plainLyrics', ''),
                    'source': 'LRCLib',
                    'instrumental': data.get('instrumental', False)
                }
    except Exception as e:
        pass

    # Search fallback with strict verification
    try:
        q_str = f"{artist} {title}".strip() if artist else title.strip()
        resp = requests.get('https://lrclib.net/api/search',
                          params={'q': q_str},
                          timeout=8, headers=headers)
        if resp.status_code == 200:
            results = resp.json()
            if isinstance(results, list):
                # First pass: find synced lyrics that match duration & artist
                for r in results:
                    r_dur = float(r.get('duration', 0) or 0)
                    r_artist = (r.get('artistName') or '').lower()
                    a_lower = (artist or '').lower()

                    # If duration is known, reject anything differing by > 5 seconds
                    if duration > 0 and r_dur > 0 and abs(r_dur - duration) > 5:
                        continue

                    # If artist is specified, ensure match unless duration is identical
                    if a_lower and a_lower not in r_artist and r_artist not in a_lower:
                        if duration > 0 and abs(r_dur - duration) > 2:
                            continue

                    if r.get('syncedLyrics'):
                        return {
                            'synced': r['syncedLyrics'],
                            'plain': r.get('plainLyrics', ''),
                            'source': 'LRCLib',
                            'instrumental': r.get('instrumental', False)
                        }

                # Second pass: plain lyrics with same strict match
                for r in results:
                    r_dur = float(r.get('duration', 0) or 0)
                    r_artist = (r.get('artistName') or '').lower()
                    a_lower = (artist or '').lower()

                    if duration > 0 and r_dur > 0 and abs(r_dur - duration) > 5:
                        continue
                    if a_lower and a_lower not in r_artist and r_artist not in a_lower:
                        if duration > 0 and abs(r_dur - duration) > 2:
                            continue

                    if r.get('plainLyrics'):
                        return {
                            'synced': None,
                            'plain': r['plainLyrics'],
                            'source': 'LRCLib',
                            'instrumental': r.get('instrumental', False)
                        }
    except Exception as e:
        print(f"[LRCLIB search] Error: {e}")

    return None


# ============================================================
# Provider 2: YouTube Music Lyrics (via ytmusicapi)
# ============================================================

_ytm = None
_ytm_ja = None

def get_ytmusic():
    global _ytm
    if _ytm is None:
        from ytmusicapi import YTMusic
        _ytm = YTMusic()
    return _ytm

def get_ytmusic_ja():
    global _ytm_ja
    if _ytm_ja is None:
        from ytmusicapi import YTMusic
        _ytm_ja = YTMusic(language='ja')
    return _ytm_ja


def get_song_info(video_id):
    """Get song metadata from YT Music with dual-language lookup (EN & JA)."""
    try:
        ytm = get_ytmusic()
        info = ytm.get_song(video_id)
        if not info or 'videoDetails' not in info:
            return None

        d = info['videoDetails']
        title = d.get('title', '')
        artist = d.get('author', '')
        duration = int(d.get('lengthSeconds', 0))

        album = ''
        try:
            album = info.get('microformat', {}).get('microformatDataRenderer', {}).get('tags', [''])[0]
        except:
            pass

        ja_title = ''
        ja_artist = ''
        try:
            ytm_ja = get_ytmusic_ja()
            info_ja = ytm_ja.get_song(video_id)
            if info_ja and 'videoDetails' in info_ja:
                d_ja = info_ja['videoDetails']
                ja_title = d_ja.get('title', '')
                ja_artist = d_ja.get('author', '')
        except:
            pass

        return {
            'title': title,
            'artist': artist,
            'ja_title': ja_title,
            'ja_artist': ja_artist,
            'album': album,
            'duration': duration
        }
    except Exception as e:
        print(f"[ytmusicapi] get_song error: {e}")
        return None


def fetch_yt_lyrics(video_id):
    try:
        ytm = get_ytmusic()
        watch_playlist = ytm.get_watch_playlist(video_id)
        lyrics_browse_id = watch_playlist.get('lyrics') if watch_playlist else None

        if lyrics_browse_id:
            lyrics = ytm.get_lyrics(lyrics_browse_id)
            if lyrics and lyrics.get('lyrics'):
                return {'plain': lyrics['lyrics'], 'source': 'YouTube Music'}
    except Exception as e:
        print(f"  [FAIL] ytmusicapi error: {e}")
    return None

# ============================================================
# Cubey API (Turnstile bypassed)
# ============================================================

def fetch_cubey(jwt_token, video_id, title, artist, duration_sec):
    url = "https://lyrics.api.dacubeking.com/v2/lyrics"
    data = {
        "videoId": video_id,
        "song": title,
        "artist": artist,
        "duration": str(int(duration_sec)),
        "alwaysFetchMetadata": "false",
        "token": jwt_token
    }

    try:
        response = requests.post(url, data=data, stream=True, timeout=15)
        if response.status_code != 200:
            print(f"  [FAIL] Cubey API error: {response.status_code}")
            return None

        best_lyrics = None
        best_is_wbw = False

        for line in response.iter_lines():
            if not line:
                continue
            line = line.decode('utf-8').strip()
            if line.startswith("data:"):
                data_str = line[5:].strip()
                if data_str == "[DONE]":
                    break
                try:
                    event_data = json.loads(data_str)
                    provider = event_data.get("provider")
                    results = event_data.get("results")

                    if not results: continue

                    # We prefer synced LRC. QQ/KuGou often return raw JSON strings in "lyrics".
                    if provider == "musixmatch":
                        if results.get("wordByWord"):
                            return {"synced": results["wordByWord"], "source": "Musixmatch"}
                        if results.get("synced") and not best_is_wbw:
                            best_lyrics = {"synced": results["synced"], "source": "Musixmatch"}

                    elif provider == "qq" and results.get("lyrics"):
                        # QRC carries true word-by-word timing: outranks any
                        # line-sync best collected so far (e.g. Musixmatch LRC)
                        qrc_lrc = parse_qrc_to_lrc(results["lyrics"])
                        if qrc_lrc:
                            print(f"  [OK] Cubey: QQ word-sync lyrics found!")
                            best_lyrics = {"synced": qrc_lrc, "source": "QQ"}
                            best_is_wbw = True

                    elif provider == "netease" and results.get("synced"):
                        if not best_lyrics:
                            best_lyrics = {"synced": results["synced"], "source": "NetEase"}

                    elif provider == "kugou" and results.get("lyrics"):
                        try:
                            k_json = json.loads(results["lyrics"])
                            if k_json.get("lyrics") and not best_lyrics:
                                best_lyrics = {"synced": k_json["lyrics"], "source": "KuGou"}
                        except: pass

                except Exception as e:
                    pass

        return best_lyrics
    except Exception as e:
        print(f"  [FAIL] Cubey API request failed: {e}")
        return None


# ============================================================
# Provider 3: Unison (community lyrics, free with x-key-id)
# ============================================================

def generate_unison_key():
    """Generate a unique key ID for Unison API."""
    import uuid
    return hashlib.sha256(str(uuid.uuid4()).encode()).hexdigest()[:32]

_unison_key = None

def get_unison_key():
    global _unison_key
    if _unison_key is None:
        _unison_key = generate_unison_key()
    return _unison_key


def fetch_unison(video_id, title='', artist='', duration=0):
    """Fetch lyrics from Unison community API."""
    try:
        headers = {
            'x-key-id': get_unison_key(),
            'Content-Type': 'application/json'
        }
        params = {'v': video_id}
        if title:
            params['song'] = title
        if artist:
            params['artist'] = artist
        if duration:
            params['duration'] = str(int(duration))

        resp = requests.get('https://unison.boidu.dev/lyrics',
                          params=params, headers=headers, timeout=8)

        if resp.status_code == 200:
            data = resp.json()
            fmt = data.get('format', '')
            lyrics_text = data.get('lyrics', '')

            if not lyrics_text:
                return None

            if fmt == 'lrc':
                return {
                    'synced': lyrics_text,
                    'plain': None,
                    'source': 'Unison',
                    'format': 'lrc'
                }
            elif fmt == 'plain':
                return {
                    'synced': None,
                    'plain': lyrics_text,
                    'source': 'Unison',
                    'format': 'plain'
                }
            elif fmt == 'ttml':
                # Parse TTML to extract lines
                ttml_lyrics = parse_ttml_basic(lyrics_text, duration)
                if ttml_lyrics:
                    return {
                        'parsed': ttml_lyrics,
                        'source': 'Unison',
                        'format': 'ttml'
                    }
    except Exception as e:
        print(f"[Unison] Error: {e}")
    return None


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

def cohere_translate(texts, target_lang='zh-TW'):
    """Translate a list of text lines using Cohere Command A Translate."""
    if not texts:
        return []

    # Filter out lines that are already the target language or empty
    # Simple heuristic: if all chars are CJK and target is zh, skip
    non_empty = [t for t in texts if t.strip()]
    if not non_empty:
        return texts

    cache_key = f"cohere:{target_lang}:{hashlib.md5('|'.join(texts).encode()).hexdigest()}"
    cached = get_translate_cached(cache_key)
    if cached is not None:
        return cached

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
            results = [result_map.get(i+1, texts[i]) for i in range(len(texts))]
            set_translate_cached(cache_key, results)
            return results

        except Exception as e:
            print(f"  [Cohere] Exception: {e}")
            rotate_cohere_key()

    # Fallback: return originals
    print(f"  [Cohere] All keys failed, returning originals")
    return texts


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

    set_translate_cached(cache_key, all_translations)
    return all_translations


# ============================================================
# Metadata Cleaning & Variants
# ============================================================

def get_search_queries(title, artist, ja_title='', ja_artist=''):
    """Generate search variations: raw original, with/without cover tags, and Japanese/English variants."""
    queries = []
    seen = set()

    def add_q(t, a):
        t_clean = re.sub(r'\s+', ' ', t or '').strip(' -_./')
        a_clean = re.sub(r'\s+', ' ', a or '').strip(' -_./')
        if not t_clean or not a_clean:
            return
        key = (t_clean.lower(), a_clean.lower())
        if key not in seen:
            seen.add(key)
            queries.append({'title': t_clean, 'artist': a_clean})

    def clean_title(t):
        if not t: return ''
        c = t
        c = re.sub(r'(?i)[/／]\s*(?:covered\s+by|cover\s+by|cover|歌ってみた).*$', '', c)
        c = re.sub(r'(?i)[/／]\s*[^/／]+$', '', c)
        c = re.sub(r'(?i)[\(\[\{【「『（［]\s*(?:official\s*(?:video|audio|music\s*video|mv|lyric\s*video)?|full\s*ver\.?|cover(?:ed)?(?:\s+by[^\)\]\}】」』）］]*)?|remix|mv|audio|feat\.?[^\)\]\}】」』）］]*|ft\.?[^\)\]\}】」』）］]*|歌ってみた|self\s*cover|[^\)\]\}】」』）］]*ver\.?)\s*[\)\]\}】」』）］]', '', c)
        c = re.sub(r'(?i)\b(?:feat\.?|ft\.?)\s+.*$', '', c)
        c = re.sub(r'(?i)\s*-\s*(?:cover|official|remix|mv).*$', '', c)
        return c.strip(' -_./')

    def clean_artist(a):
        if not a: return ''
        c = a
        c = re.sub(r'(?i)[\(\[\{【「『（［]\s*(?:official|topic|channel|vevo)\s*[\)\]\}】」』）］]', '', c)
        c = re.sub(r'(?i)\s*-\s*topic$', '', c)
        return c.strip(' -_./')

    c_t = clean_title(title)
    c_a = clean_artist(artist)

    # 1. Clean title + clean artist
    add_q(c_t, c_a)
    # 2. Raw title + clean artist (with cover tags)
    if title != c_t:
        add_q(title, c_a)
    if artist != c_a:
        add_q(title, artist)

    # 3. Japanese title/artist variants if available
    if ja_title or ja_artist:
        c_ja_t = clean_title(ja_title) or c_t
        c_ja_a = clean_artist(ja_artist) or c_a
        add_q(c_ja_t, c_ja_a)
        if ja_title and ja_title != c_ja_t:
            add_q(ja_title, c_ja_a)
        # Cross-language (e.g. English title + Japanese artist: Spiral - 明透)
        add_q(c_t, c_ja_a)
        # Japanese title + English artist (e.g. アバウト - GIRLS REVOLUTION PROJECT)
        add_q(c_ja_t, c_a)

    # 4. Extract possible original artist embedded in title (e.g. "アバウト / NAGI" -> artist: NAGI)
    for t_cand in [title, ja_title]:
        if not t_cand: continue
        parts = re.split(r'[/／\-–—]\s*', t_cand)
        if len(parts) >= 2:
            p0 = clean_title(parts[0])
            p1 = clean_title(parts[1])
            if p0 and p1:
                add_q(p0, p1)
                add_q(p1, p0)

    return queries


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

def sanitize_lyrics_parts(lyrics):
    """Ensure every line has valid, monotonically increasing parts with proper durations and spaces."""
    if not lyrics:
        return
    for l in lyrics:
        if not l.get('text'):
            continue
        l_ms = int(l.get('startTimeMs', l.get('time', 0) * 1000))
        l_dur = int(l.get('durationMs', l.get('duration', 0) * 1000))
        parts = l.get('parts')
        if not parts or len(parts) == 0:
            if l_dur > 0:
                l['parts'] = generate_interpolated_parts(l['text'], l_ms, l_dur)
        else:
            prev_ms = l_ms
            for pi, p in enumerate(parts):
                if not p.get('startTimeMs') or p['startTimeMs'] < l_ms:
                    p['startTimeMs'] = prev_ms + (0 if pi == 0 else 200)
                prev_ms = p['startTimeMs']
            for pi in range(len(parts)):
                if pi < len(parts) - 1:
                    dur = parts[pi+1]['startTimeMs'] - parts[pi]['startTimeMs']
                    parts[pi]['durationMs'] = max(dur, 0)
                else:
                    parts[pi]['durationMs'] = max(l_ms + l_dur - parts[pi]['startTimeMs'], 200)

def get_cached(video_id):
    path = f"cache/lyrics/{video_id}.json"
    if os.path.exists(path):
        try:
            with open(path, 'r', encoding='utf-8') as f:
                entry = json.load(f)
            data = entry.get('data')
            if is_not_found_result(data):
                return None
            if data and data.get('lyrics'):
                sanitize_lyrics_parts(data['lyrics'])
            ts = datetime.fromisoformat(entry['ts'])
            if (datetime.now() - ts).total_seconds() < 86400 * 3:
                return data
        except:
            pass
    return None

def set_cached(video_id, data):
    # Do not cache not-found or error records so future attempts or new lyrics can be resolved
    if is_not_found_result(data):
        return
    path = f"cache/lyrics/{video_id}.json"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump({'data': data, 'ts': datetime.now().isoformat()}, f, ensure_ascii=False)
    except:
        pass

def clear_not_found_caches():
    lyrics_dir = 'cache/lyrics'
    if not os.path.exists(lyrics_dir):
        return
    removed = 0
    for fname in os.listdir(lyrics_dir):
        if fname.endswith('.json'):
            fpath = os.path.join(lyrics_dir, fname)
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
    for q in queries:
        q_title = q['title']
        q_artist = q['artist']
        lrc = fetch_lrclib(q_title, q_artist, album, duration)
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

def fetch_all_lyrics(video_id, song_info, translate_to=None, jwt_token=None):
    """Try all providers in priority order, return best result."""

    title = song_info['title']
    artist = song_info['artist']
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    queries = get_search_queries(title, artist, song_info.get('ja_title', ''), song_info.get('ja_artist', ''))

    result = None

    # Priority 0: Cubey API (if we have JWT)
    if jwt_token:
        print(f"  [0/4] Trying Cubey API (with JWT)...")
        for q in queries:
            q_title = q['title']
            q_artist = q['artist']
            cubey = fetch_cubey(jwt_token, video_id, q_title, q_artist, duration)
            if cubey and cubey.get('synced'):
                print(f"  [OK] Cubey: synced LRC lyrics found from {cubey.get('source')}! (query: {q_title} - {q_artist})")
                parsed = parse_lrc(cubey['synced'], duration)
                result = {'lyrics': parsed, 'source': cubey.get('source'), 'synced': True}
                # Skip other providers - we already have the best
                result['song'] = title
                result['artist'] = artist
                if translate_to and result.get('lyrics'):
                    print(f"  [TRANS] Translating {len(result['lyrics'])} lines with Cohere...")
                    texts = [l['text'] for l in result['lyrics'] if l.get('text')]
                    translations = cohere_translate(texts, translate_to)
                    for i, lyric in enumerate(result['lyrics']):
                        if i < len(translations):
                            lyric['translated'] = translations[i]
                if result and result.get('lyrics'):
                    sanitize_lyrics_parts(result['lyrics'])
                return result

    # Priority 1: LRCLIB (best for synced lyrics)
    print(f"  [1/3] Trying LRCLIB...")
    for q in queries:
        q_title = q['title']
        q_artist = q['artist']
        lrc = fetch_lrclib(q_title, q_artist, album, duration)
        if lrc:
            if lrc.get('instrumental'):
                result = {
                    'lyrics': [{'time': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'duration': 0}],
                    'source': 'LRCLib', 'synced': False
                }
                break
            elif lrc.get('synced'):
                print(f"  [OK] LRCLIB: synced lyrics found! (query: {q_title} - {q_artist})")
                parsed = parse_lrc(lrc['synced'], duration)
                result = {'lyrics': parsed, 'source': 'LRCLib', 'synced': True}
                break
            elif lrc.get('plain') and not result:
                print(f"  [WARN]️ LRCLIB: plain lyrics only (query: {q_title} - {q_artist})")
                parsed = parse_plain(lrc['plain'])
                result = {'lyrics': parsed, 'source': 'LRCLib', 'synced': False}

    # Priority 2: Unison (community)
    if not result or not result.get('synced'):
        print(f"  [2/3] Trying Unison...")
        for q in queries:
            uni = fetch_unison(video_id, q['title'], q['artist'], duration)
            if uni:
                if uni.get('parsed'):
                    print(f"  [OK] Unison: TTML lyrics found! (query: {q['title']})")
                    if not result or not result.get('synced'):
                        result = {'lyrics': uni['parsed'], 'source': 'Unison', 'synced': True}
                        break
                elif uni.get('synced'):
                    print(f"  [OK] Unison: synced LRC lyrics found! (query: {q['title']})")
                    parsed = parse_lrc(uni['synced'], duration)
                    if not result or not result.get('synced'):
                        result = {'lyrics': parsed, 'source': 'Unison', 'synced': True}
                        break
                elif uni.get('plain') and not result:
                    print(f"  [WARN]️ Unison: plain lyrics only (query: {q['title']})")
                    parsed = parse_plain(uni['plain'])
                    result = {'lyrics': parsed, 'source': 'Unison', 'synced': False}

    # Priority 3: YouTube Music lyrics
    if not result:
        print(f"  [3/3] Trying YouTube Music lyrics...")
        yt = fetch_yt_lyrics(video_id)
        if yt and yt.get('plain'):
            print(f"  [OK] YouTube: plain lyrics found!")
            parsed = parse_plain(yt['plain'])
            result = {'lyrics': parsed, 'source': yt.get('source', 'YouTube Music'), 'synced': False}

    # No lyrics found
    if not result:
        print(f"  [FAIL] No lyrics found from any provider")
        result = {
            'lyrics': [{'time': 0, 'text': f'No lyrics found', 'translated': f'找不到歌詞: {title}', 'duration': 0}],
            'source': 'none', 'synced': False
        }

    # Add song metadata
    result['song'] = title
    result['artist'] = artist

    # Translation
    if translate_to and result.get('lyrics'):
        print(f"  [TRANS] Translating {len(result['lyrics'])} lines with Cohere...")
        texts = [l['text'] for l in result['lyrics'] if l.get('text')]
        translations = cohere_translate(texts, translate_to)

        for i, lyric in enumerate(result['lyrics']):
            if i < len(translations):
                lyric['translated'] = translations[i]

    if result and result.get('lyrics'):
        sanitize_lyrics_parts(result['lyrics'])

    return result


# ============================================================
# Parallel provider race + SSE streaming
# Same providers as fetch_all_lyrics, but raced concurrently so the
# client gets the first hit fast, then upgrades when a better result
# (synced beats plain) arrives. Raw synced lines are pushed BEFORE
# translation runs, so Cohere latency never blocks first paint.
# ============================================================

_PROVIDER_RANK = {
    'Musixmatch': 40,
    'QQ': 36,
    'KuGou': 35,
    'NetEase': 33,
    'LRCLib': 30,
    'Unison': 20,
    'YouTube Music': 10,
}

_STAGE_RANK = {'raw': 0, 'machine': 1, 'final': 2, 'cached': 3}


def _wbw_line_count(res):
    """Count lines carrying real provider word timestamps (not interpolated)."""
    n = 0
    for l in (res.get('lyrics') or []):
        parts = l.get('parts') or []
        if l.get('wordSynced') and len(parts) > 1:
            if len({p.get('startTimeMs') for p in parts}) > 1:
                n += 1
    return n


def _lyrics_score(res):
    """Higher is better. Word-by-word sync beats everything; if both sides
    have it (or neither does), provider weight decides, then coverage."""
    if not res or not res.get('lyrics'):
        return -1
    wbw = _wbw_line_count(res)
    if wbw > 0:
        base = 2000
    elif res.get('synced'):
        base = 100
    else:
        base = 0
    prov = _PROVIDER_RANK.get(res.get('source', ''), 0)
    return base + prov + min(len(res.get('lyrics', [])), 50) * 0.01 + min(wbw, 100) * 0.1


def _race_cubey(queries, video_id, duration, jwt_token, req_id='?'):
    t0 = time_module.time()
    try:
        for q in queries:
            try:
                cubey = fetch_cubey(jwt_token, video_id, q['title'], q['artist'], duration)
            except Exception as e:
                print(f"  [REQ {req_id}] [Race] Cubey query error: {e}")
                continue
            if cubey and cubey.get('synced'):
                parsed = parse_lrc(cubey['synced'], duration)
                sanitize_lyrics_parts(parsed)
                print(f"  [REQ {req_id}] [Race] Cubey hit from {cubey.get('source')} ({(time_module.time()-t0)*1000:.0f}ms)")
                return {'lyrics': parsed, 'source': cubey.get('source'), 'synced': True}
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] Cubey worker error: {e}")
    print(f"  [REQ {req_id}] [Race] Cubey miss ({(time_module.time()-t0)*1000:.0f}ms)")
    return None


def _race_lrclib(queries, album, duration, req_id='?'):
    t0 = time_module.time()
    plain_fallback = None
    try:
        for q in queries:
            try:
                lrc = fetch_lrclib(q['title'], q['artist'], album, duration)
            except Exception as e:
                print(f"  [REQ {req_id}] [Race] LRCLIB query error: {e}")
                continue
            if not lrc:
                continue
            if lrc.get('instrumental'):
                parsed = [{'time': 0, 'startTimeMs': 0, 'text': '[MUSIC] Instrumental', 'translated': '純音樂', 'durationMs': 0, 'duration': 0}]
                return {'lyrics': parsed, 'source': 'LRCLib', 'synced': False}
            if lrc.get('synced'):
                parsed = parse_lrc(lrc['synced'], duration)
                sanitize_lyrics_parts(parsed)
                print(f"  [REQ {req_id}] [Race] LRCLIB synced hit ({(time_module.time()-t0)*1000:.0f}ms)")
                return {'lyrics': parsed, 'source': 'LRCLib', 'synced': True}
            if lrc.get('plain') and plain_fallback is None:
                parsed = parse_plain(lrc['plain'])
                sanitize_lyrics_parts(parsed)
                plain_fallback = {'lyrics': parsed, 'source': 'LRCLib', 'synced': False}
        if plain_fallback:
            print(f"  [REQ {req_id}] [Race] LRCLIB plain fallback ({(time_module.time()-t0)*1000:.0f}ms)")
        else:
            print(f"  [REQ {req_id}] [Race] LRCLIB miss ({(time_module.time()-t0)*1000:.0f}ms)")
        return plain_fallback
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] LRCLIB worker error: {e}")
        return plain_fallback


def _race_unison(queries, video_id, duration, req_id='?'):
    t0 = time_module.time()
    plain_fallback = None
    try:
        for q in queries:
            try:
                uni = fetch_unison(video_id, q['title'], q['artist'], duration)
            except Exception as e:
                print(f"  [REQ {req_id}] [Race] Unison query error: {e}")
                continue
            if not uni:
                continue
            if uni.get('parsed'):
                sanitize_lyrics_parts(uni['parsed'])
                print(f"  [REQ {req_id}] [Race] Unison TTML hit ({(time_module.time()-t0)*1000:.0f}ms)")
                return {'lyrics': uni['parsed'], 'source': 'Unison', 'synced': True}
            if uni.get('synced'):
                parsed = parse_lrc(uni['synced'], duration)
                sanitize_lyrics_parts(parsed)
                print(f"  [REQ {req_id}] [Race] Unison synced hit ({(time_module.time()-t0)*1000:.0f}ms)")
                return {'lyrics': parsed, 'source': 'Unison', 'synced': True}
            if uni.get('plain') and plain_fallback is None:
                parsed = parse_plain(uni['plain'])
                sanitize_lyrics_parts(parsed)
                plain_fallback = {'lyrics': parsed, 'source': 'Unison', 'synced': False}
        if plain_fallback:
            print(f"  [REQ {req_id}] [Race] Unison plain fallback ({(time_module.time()-t0)*1000:.0f}ms)")
        else:
            print(f"  [REQ {req_id}] [Race] Unison miss ({(time_module.time()-t0)*1000:.0f}ms)")
        return plain_fallback
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] Unison worker error: {e}")
        return plain_fallback


def _race_yt(video_id, req_id='?'):
    t0 = time_module.time()
    try:
        yt = fetch_yt_lyrics(video_id)
        if yt and yt.get('plain'):
            parsed = parse_plain(yt['plain'])
            sanitize_lyrics_parts(parsed)
            print(f"  [REQ {req_id}] [Race] YouTube plain hit ({(time_module.time()-t0)*1000:.0f}ms)")
            return {'lyrics': parsed, 'source': yt.get('source', 'YouTube Music'), 'synced': False}
    except Exception as e:
        print(f"  [REQ {req_id}] [Race] YouTube worker error: {e}")
    print(f"  [REQ {req_id}] [Race] YouTube miss ({(time_module.time()-t0)*1000:.0f}ms)")
    return None


def _sse_event(name, payload):
    return f"event: {name}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"


# ============================================================
# API Endpoints
# ============================================================

_update_cache = {'commit': None, 'checked_at': 0.0}


def latest_tweak_commit():
    """Fetch the current public build revision, caching it for five minutes."""
    now = time_module.time()
    if _update_cache['commit'] and now - _update_cache['checked_at'] < 300:
        return _update_cache['commit']
    try:
        response = requests.get(
            'https://api.github.com/repos/ChiuHuang/ytmusicultimate/commits/main',
            headers={'Accept': 'application/vnd.github+json'}, timeout=5)
        response.raise_for_status()
        commit = response.json().get('sha')
        if commit:
            _update_cache.update(commit=commit, checked_at=now)
            return commit
    except requests.RequestException as exc:
        print(f"[Update] Could not check GitHub: {exc}")
    try:
        return subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


@app.route('/api/update', methods=['GET'])
def api_update():
    client_commit = (request.args.get('commit') or '').strip().lower()
    if client_commit and not re.fullmatch(r'[0-9a-f]{7,64}', client_commit):
        return jsonify({'error': 'Invalid commit hash'}), 400
    latest_commit = latest_tweak_commit()
    if not latest_commit:
        return jsonify({'error': 'Update service unavailable'}), 503
    is_current = bool(client_commit) and latest_commit.lower().startswith(client_commit)
    return jsonify({
        'current_commit': client_commit or None,
        'latest_commit': latest_commit,
        'update_available': bool(client_commit) and not is_current,
        'repository': 'https://github.com/ChiuHuang/ytmusicultimate'
    })

@app.route('/api/lyrics', methods=['GET'])
def api_lyrics():
    _req_start = time_module.time()
    video_id = request.args.get('v')
    if not video_id:
        return jsonify({"error": "Missing video ID"}), 400

    if video_id.startswith('DEBUG_'):
        debug_msg = video_id[6:]
        client_ip = request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-For') or request.remote_addr
        ua = request.headers.get('User-Agent', '')[:120]
        print(f"[iOS] [iOS Tweak] {debug_msg} | ip={client_ip} ua={ua}")
        return jsonify({"ok": True, "source": "debug"})

    translate_to = request.args.get('lang', 'zh-TW')
    jwt_token = request.args.get('jwt')
    fast_mode = request.args.get('fast', '0') == '1'
    force_mode = request.args.get('force', '0') == '1'

    client_ip = request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-For') or request.remote_addr
    ua = request.headers.get('User-Agent', '')[:120]
    all_args = dict(request.args)
    if 'jwt' in all_args and all_args['jwt']:
        all_args['jwt'] = all_args['jwt'][:12] + '...'
    req_id = _secrets.token_hex(3)
    _recent_requests.append({'id': req_id, 'v': video_id, 'mode': 'fast' if fast_mode else 'full', 'ip': client_ip, 'ts': datetime.now().isoformat()})

    print("=" * 60)
    mode_str = 'FAST' if fast_mode else ('JWT+Cohere' if jwt_token else 'Normal')
    if force_mode: mode_str += ' [FORCE]'
    print(f"[REQ] [REQ {req_id}] Lyrics request: {video_id} [{mode_str}] lang={translate_to}")
    print(f"  [REQ {req_id}] ip={client_ip} ua={ua}")
    print(f"  [REQ {req_id}] args={all_args} has_jwt={bool(jwt_token)}")
    print("=" * 60)

    # Cache keys — fast and full are stored separately
    full_cache_key = f"{video_id}:{translate_to}"
    fast_cache_key = f"{video_id}:{translate_to}:fast"
    cache_key = fast_cache_key if fast_mode else full_cache_key

    # In-flight dedup key — SAME for fast and full so they share the gate.
    # This prevents the common case of 8+ simultaneous requests for the same song
    # (fast + full + multiple VC instances) all running the full pipeline in parallel.
    dedup_key = f"{video_id}:{translate_to}" if not force_mode else None

    # --- Atomic check-and-register (fixes TOCTOU race) ---
    wait_event = None
    if dedup_key:
        with _in_flight_lock:
            if dedup_key in _in_flight:
                # Another request is already doing the work — grab its event to wait on
                wait_event = _in_flight[dedup_key]
            else:
                # First request for this video — register ourselves as in-flight
                event = threading.Event()
                _in_flight[dedup_key] = event

    if wait_event is not None:
        # We're a duplicate — wait for the primary request to finish
        print(f"[WAIT] [REQ {req_id}] [In-Flight] Waiting for primary request dedup_key={dedup_key}...")
        t0 = time_module.time()
        wait_event.wait(timeout=30)
        waited = time_module.time() - t0
        print(f"  [REQ {req_id}] [In-Flight] Wait done after {waited:.2f}s")
        # Check full cache first (might be better than fast), then fast
        cached = get_cached(full_cache_key) or get_cached(fast_cache_key)
        if cached:
            print(f"[OK] [REQ {req_id}] Got result from in-flight wait source={cached.get('source')} lines={len(cached.get('lyrics',[]))} synced={cached.get('synced')}")
            print(f"  [REQ {req_id}] elapsed={(time_module.time()-_req_start)*1000:.0f}ms (in-flight)")
            print("=" * 60)
            return jsonify(cached)
        # Fell through (timeout or no cache) — return empty
        print(f"[WARN] [REQ {req_id}] [In-Flight] No cache after wait (timeout or miss) - returning none")
        print(f"  [REQ {req_id}] elapsed={(time_module.time()-_req_start)*1000:.0f}ms (in-flight miss)")
        print("=" * 60)
        return jsonify({
            'lyrics': [{'time': 0, 'text': 'No lyrics found', 'translated': '找不到歌詞', 'duration': 0}],
            'source': 'none', 'synced': False
        })

    # --- Cache check (only for non-force requests) ---
    if not force_mode:
        # Fast mode: accept full result too (full is strictly better)
        cached = get_cached(full_cache_key) if fast_mode else get_cached(full_cache_key)
        cache_source = 'full'
        if not cached:
            cached = get_cached(cache_key)
            cache_source = 'mode-specific' if cached else 'none'
        if cached:
            age_info = ''
            try:
                path = f"cache/lyrics/{(fast_cache_key if cache_source=='mode-specific' else full_cache_key)}.json"
                import os as _os
                if _os.path.exists(path):
                    with open(path,'r',encoding='utf-8') as f:
                        entry = json.load(f)
                        ts = datetime.fromisoformat(entry['ts'])
                        age = (datetime.now()-ts).total_seconds()
                        age_info = f" age={age/3600:.1f}h"
            except: pass
            print(f"[OK] [REQ {req_id}] [Cache] hit! key={cache_source} source={cached.get('source')} lines={len(cached.get('lyrics',[]))} synced={cached.get('synced')}{age_info}")
            print(f"  [REQ {req_id}] elapsed={(time_module.time()-_req_start)*1000:.0f}ms (cache)")
            # Release in-flight slot immediately (no work needed)
            if dedup_key:
                with _in_flight_lock:
                    if dedup_key in _in_flight:
                        _in_flight[dedup_key].set()
                        del _in_flight[dedup_key]
            print("=" * 60)
            return jsonify(cached)
        else:
            print(f"  [REQ {req_id}] [Cache] miss for both full and fast keys")
    else:
        print(f"  [REQ {req_id}] [Cache] bypassed (force mode)")

    # --- We are the primary request: do the actual work ---
    def release_inflight():
        if dedup_key:
            with _in_flight_lock:
                if dedup_key in _in_flight:
                    _in_flight[dedup_key].set()
                    del _in_flight[dedup_key]

    try:
        print(f"[SEARCH] [REQ {req_id}] Looking up song info via ytmusicapi...")
        t_song = time_module.time()
        song_info = get_song_info(video_id)
        print(f"  [REQ {req_id}] get_song_info took {(time_module.time()-t_song)*1000:.0f}ms")

        if not song_info:
            print(f"[FAIL] [REQ {req_id}] Could not identify song (get_song_info returned None)")
            release_inflight()
            return jsonify({
                'lyrics': [{'time': 0, 'text': 'Could not identify song', 'translated': 'Unable to identify song', 'duration': 0}],
                'source': 'error', 'synced': False
            })

        print(f"[MUSIC] [REQ {req_id}] {song_info['title']} - {song_info['artist']} ({song_info['duration']}s) album='{song_info.get('album','')}' ja_title='{song_info.get('ja_title','')}' ja_artist='{song_info.get('ja_artist','')}'")
        queries = get_search_queries(song_info['title'], song_info['artist'], song_info.get('ja_title',''), song_info.get('ja_artist',''))
        print(f"  [REQ {req_id}] Generated {len(queries)} search queries: {queries}")

        if fast_mode:
            print(f"  [REQ {req_id}] Fast mode pipeline start")
            result = fetch_fast_lyrics(video_id, song_info, translate_to)
            if not result:
                print(f"  [REQ {req_id}] Fast pipeline returned None -> none")
                result = {
                    'lyrics': [{'time': 0, 'text': 'No lyrics found', 'translated': 'No lyrics found', 'duration': 0}],
                    'source': 'none', 'synced': False
                }
            else:
                print(f"  [REQ {req_id}] Fast pipeline success source={result.get('source')} lines={len(result.get('lyrics',[]))}")
        else:
            print(f"  [REQ {req_id}] Full pipeline start (jwt={'yes' if jwt_token else 'no'})")
            result = fetch_all_lyrics(video_id, song_info, translate_to, jwt_token)

    except Exception as e:
        _log_crash(type(e), e, e.__traceback__)
        release_inflight()
        return jsonify({'error': str(e), 'instance': SERVER_INSTANCE_ID}), 500
    finally:
        release_inflight()

    # Cache result
    is_nf = is_not_found_result(result)
    print(f"  [REQ {req_id}] Caching result to {cache_key} is_not_found={is_nf}")
    set_cached(cache_key, result)

    print(f"[SEND] [REQ {req_id}] Returning {len(result.get('lyrics', []))} lines from {result.get('source', '?')} synced={result.get('synced')} elapsed={(time_module.time()-_req_start)*1000:.0f}ms")
    print("=" * 60)

    return jsonify(result)


@app.route('/api/lyrics/stream', methods=['GET'])
def api_lyrics_stream():
    """SSE stream: parallel provider race with progressive upgrades.

    Event flow (client replaces lyrics when stage rank or score improves):
      meta    -> {song, artist, duration} once song_info resolves
      status  -> per-provider finish {provider, ok, synced, elapsed_ms}
      lyrics  -> {stage: raw|machine|final|cached, source, synced, lyrics, song, artist}
                 raw = untranslated lines pushed FIRST (never blocked on Cohere)
                 machine = Google fast translation interim
                 final = Cohere quality translation (pro/JWT path: sync pushed
                         as raw first, then re-pushed as final with translated)
      done    -> {ok, source, synced, stages} terminal event
    """
    _req_start = time_module.time()
    video_id = request.args.get('v')
    if not video_id:
        return jsonify({"error": "Missing video ID"}), 400
    translate_to = request.args.get('lang', 'zh-TW')
    jwt_token = request.args.get('jwt')
    force_mode = request.args.get('force', '0') == '1'
    full_cache_key = f"{video_id}:{translate_to}"
    req_id = _secrets.token_hex(3)

    print("=" * 60)
    print(f"[REQ] [REQ {req_id}] Lyrics STREAM: {video_id} [{'JWT' if jwt_token else 'Normal'}] lang={translate_to}")
    print("=" * 60)

    def generate():
        # --- Fast path: full cache hit closes the stream immediately ---
        if not force_mode:
            cached = get_cached(full_cache_key)
            if cached:
                print(f"[OK] [REQ {req_id}] [Stream] cache hit source={cached.get('source')} lines={len(cached.get('lyrics', []))}")
                payload = dict(cached)
                payload['stage'] = 'cached'
                yield _sse_event('lyrics', payload)
                yield _sse_event('done', {'ok': True, 'source': cached.get('source'), 'synced': cached.get('synced'), 'stages': ['cached']})
                return

        # --- Song lookup (required by all providers) ---
        t_song = time_module.time()
        try:
            song_info = get_song_info(video_id)
        except Exception as e:
            yield _sse_event('done', {'ok': False, 'error': f'song lookup failed: {e}'})
            return
        if not song_info:
            yield _sse_event('done', {'ok': False, 'error': 'Could not identify song'})
            return
        title, artist = song_info['title'], song_info['artist']
        duration = song_info.get('duration', 0)
        album = song_info.get('album', '')
        print(f"[MUSIC] [REQ {req_id}] [Stream] {title} - {artist} ({duration}s) lookup={(time_module.time()-t_song)*1000:.0f}ms")
        yield _sse_event('meta', {'song': title, 'artist': artist, 'duration': duration,
                                  'lookup_ms': int((time_module.time()-t_song)*1000)})

        queries = get_search_queries(title, artist, song_info.get('ja_title', ''), song_info.get('ja_artist', ''))

        # --- Race all providers concurrently ---
        jobs = {}
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=4)
        try:
            if jwt_token:
                jobs[pool.submit(_race_cubey, queries, video_id, duration, jwt_token, req_id)] = 'Cubey'
            jobs[pool.submit(_race_lrclib, queries, album, duration, req_id)] = 'LRCLIB'
            jobs[pool.submit(_race_unison, queries, video_id, duration, req_id)] = 'Unison'
            jobs[pool.submit(_race_yt, video_id, req_id)] = 'YouTube'

            best = None
            best_score = -1
            stages = []
            deadline = time_module.time() + 15
            pending = set(jobs.keys())
            while pending:
                remaining = max(deadline - time_module.time(), 0.1)
                try:
                    done, pending = concurrent.futures.wait(pending, timeout=remaining,
                                                            return_when=concurrent.futures.FIRST_COMPLETED)
                except Exception:
                    break
                for fut in done:
                    name = jobs.get(fut, '?')
                    try:
                        res = fut.result()
                    except Exception as e:
                        print(f"  [REQ {req_id}] [Stream] {name} worker crashed: {e}")
                        res = None
                    elapsed = int((time_module.time()-_req_start)*1000)
                    score = _lyrics_score(res)
                    yield _sse_event('status', {'provider': name, 'ok': res is not None,
                                                'synced': bool(res and res.get('synced')),
                                                'wbw_lines': _wbw_line_count(res) if res else 0,
                                                'score': round(score, 2), 'elapsed_ms': elapsed})
                    if score > best_score:
                        best_score = score
                        best = res
                        best['song'] = title
                        best['artist'] = artist
                        best['wbw_lines'] = _wbw_line_count(best)
                        payload = dict(best)
                        payload['stage'] = 'raw'
                        payload['elapsed_ms'] = elapsed
                        stages.append(f"raw:{best.get('source')}")
                        print(f"[SEND] [REQ {req_id}] [Stream] push RAW {best.get('source')} synced={best.get('synced')} lines={len(best.get('lyrics', []))} elapsed={elapsed}ms")
                        yield _sse_event('lyrics', payload)
                if time_module.time() >= deadline:
                    for fut in pending:
                        fut.cancel()
                    break

            if best is None:
                print(f"[FAIL] [REQ {req_id}] [Stream] no provider hit")
                yield _sse_event('lyrics', {'stage': 'raw', 'source': 'none', 'synced': False, 'song': title,
                                            'artist': artist, 'lyrics': [{'time': 0, 'startTimeMs': 0, 'text': 'No lyrics found', 'translated': f'找不到歌詞: {title}', 'durationMs': 0, 'duration': 0}]})
                yield _sse_event('done', {'ok': True, 'source': 'none', 'synced': False, 'stages': stages})
                return

            # --- Translation upgrades: machine interim, then Cohere final ---
            if translate_to and best.get('lyrics'):
                texts = [l.get('text', '') for l in best['lyrics'] if l.get('text')]
                # Interim: Google fast (~1s) so UI shows translation before Cohere finishes
                try:
                    machine = google_translate_fast(texts, translate_to)
                    if any(m for m in machine):
                        for i, lyric in enumerate(best['lyrics']):
                            if i < len(machine) and machine[i]:
                                lyric['translated'] = machine[i]
                        payload = dict(best)
                        payload['stage'] = 'machine'
                        payload['elapsed_ms'] = int((time_module.time()-_req_start)*1000)
                        stages.append('machine:google')
                        print(f"[SEND] [REQ {req_id}] [Stream] push MACHINE google elapsed={payload['elapsed_ms']}ms")
                        yield _sse_event('lyrics', payload)
                except Exception as e:
                    print(f"  [REQ {req_id}] [Stream] google interim failed: {e}")

                # Final: Cohere quality translation, with keepalive pings so the
                # connection survives the ~7s gap
                print(f"  [TRANS] [REQ {req_id}] [Stream] Cohere final for {len(texts)} lines...")
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as tex:
                    tf = tex.submit(cohere_translate, texts, translate_to)
                    while True:
                        try:
                            final_trans = tf.result(timeout=2)
                            break
                        except concurrent.futures.TimeoutError:
                            yield ": ping\n\n"
                    for i, lyric in enumerate(best['lyrics']):
                        if i < len(final_trans):
                            lyric['translated'] = final_trans[i]
                sanitize_lyrics_parts(best['lyrics'])
                payload = dict(best)
                payload['stage'] = 'final'
                payload['elapsed_ms'] = int((time_module.time()-_req_start)*1000)
                stages.append('final:cohere')
                print(f"[SEND] [REQ {req_id}] [Stream] push FINAL cohere lines={len(best.get('lyrics', []))} elapsed={payload['elapsed_ms']}ms")
                yield _sse_event('lyrics', payload)

            set_cached(full_cache_key, best)
            yield _sse_event('done', {'ok': True, 'source': best.get('source'), 'synced': best.get('synced'), 'stages': stages})
        finally:
            pool.shutdown(wait=False, cancel_futures=True)
        print(f"  [REQ {req_id}] [Stream] closed elapsed={(time_module.time()-_req_start)*1000:.0f}ms")
        print("=" * 60)

    return Response(stream_with_context(generate()), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no', 'Connection': 'keep-alive'})


@app.route('/login', methods=['GET', 'POST'])
def login():
    if not _admin_cfg.get('password_hash'):
        return redirect(url_for('setup'))
    error = None
    if request.method == 'POST':
        pw = request.form.get('password', '')
        if hashlib.sha256(pw.encode()).hexdigest() == _admin_cfg['password_hash']:
            session['admin_logged_in'] = True
            return redirect(url_for('dashboard'))
        error = 'Wrong password.'
    return render_template('login.html', error=error)


@app.route('/setup', methods=['GET', 'POST'])
def setup():
    # Only accessible when no password is configured yet
    if _admin_cfg.get('password_hash'):
        return redirect(url_for('login'))
    error = None
    if request.method == 'POST':
        pw = request.form.get('password', '').strip()
        pw2 = request.form.get('password2', '').strip()
        if not pw:
            error = 'Password cannot be empty.'
        elif pw != pw2:
            error = 'Passwords do not match.'
        else:
            _admin_cfg['password_hash'] = hashlib.sha256(pw.encode()).hexdigest()
            _save_admin_config(_admin_cfg)
            session['admin_logged_in'] = True
            return redirect(url_for('dashboard'))
    return render_template('setup.html', error=error)


@app.route('/logout', methods=['POST'])
def logout():
    session.clear()
    return jsonify({'ok': True})


@app.route('/')
@login_required
def dashboard():
    return render_template('index.html')


@app.route('/api/admin/logs', methods=['GET'])
@login_required
def admin_logs():
    after_idx = request.args.get('after', type=int, default=-1)
    logs_list = list(_structured_logs)
    if after_idx >= 0 and after_idx < len(logs_list):
        logs_list = logs_list[after_idx + 1:]
    return jsonify({'logs': logs_list, 'total': len(_structured_logs)})


@app.route('/api/admin/logs/clear', methods=['POST'])
@login_required
def admin_logs_clear():
    _recent_logs.clear()
    _structured_logs.clear()
    return jsonify({'ok': True})


@app.route('/api/admin/caches', methods=['GET'])
@login_required
def admin_caches():
    lyrics_dir = 'cache/lyrics'
    items = []
    if os.path.exists(lyrics_dir):
        for fname in sorted(os.listdir(lyrics_dir),
                            key=lambda f: os.path.getmtime(os.path.join(lyrics_dir, f)),
                            reverse=True):
            if not fname.endswith('.json'):
                continue
            fpath = os.path.join(lyrics_dir, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    entry = json.load(f)
                data = entry.get('data', {})
                ts_str = entry.get('ts', '')
                try:
                    ts = datetime.fromisoformat(ts_str)
                    diff = (datetime.now() - ts).total_seconds()
                    if diff < 3600:
                        time_ago = f"{int(diff // 60)}m ago"
                    elif diff < 86400:
                        time_ago = f"{int(diff // 3600)}h ago"
                    else:
                        time_ago = f"{int(diff // 86400)}d ago"
                except Exception:
                    time_ago = 'unknown'
                cache_key = fname[:-5]
                video_id = cache_key.split(':')[0]
                items.append({
                    'video_id': video_id,
                    'cache_key': cache_key,
                    'song': data.get('song', ''),
                    'artist': data.get('artist', ''),
                    'source': data.get('source', '?'),
                    'synced': data.get('synced', False),
                    'lines': len(data.get('lyrics', [])),
                    'time_ago': time_ago,
                })
            except Exception:
                pass
    return jsonify(items)


@app.route('/api/admin/caches/clear_empty', methods=['POST'])
@login_required
def admin_clear_empty_caches():
    lyrics_dir = 'cache/lyrics'
    removed = 0
    if os.path.exists(lyrics_dir):
        for fname in os.listdir(lyrics_dir):
            if fname.endswith('.json'):
                fpath = os.path.join(lyrics_dir, fname)
                try:
                    with open(fpath, 'r', encoding='utf-8') as f:
                        entry = json.load(f)
                    if is_not_found_result(entry.get('data')):
                        os.remove(fpath)
                        removed += 1
                except Exception:
                    pass
    return jsonify({'cleared': removed})


@app.route('/api/admin/server_info', methods=['GET'])
@login_required
def admin_server_info():
    uptime = (datetime.now() - SERVER_START_TIME).total_seconds()
    # count log files
    log_files = []
    if os.path.exists(LOG_DIR):
        for fname in os.listdir(LOG_DIR):
            fpath = os.path.join(LOG_DIR, fname)
            try:
                sz = os.path.getsize(fpath)
                mt = datetime.fromtimestamp(os.path.getmtime(fpath)).isoformat()
                log_files.append({'name': fname, 'size': sz, 'modified': mt})
            except: pass
    return jsonify({
        'instance_id': SERVER_INSTANCE_ID,
        'start_time': SERVER_START_TS,
        'uptime_seconds': int(uptime),
        'uptime_human': f"{int(uptime//3600)}h {int((uptime%3600)//60)}m {int(uptime%60)}s",
        'structured_logs': len(_structured_logs),
        'recent_logs': len(_recent_logs),
        'crash_logs': len(_crash_logs),
        'recent_requests': list(_recent_requests)[-20:],
        'log_files': sorted(log_files, key=lambda x: x['modified'], reverse=True)[:20],
    })

@app.route('/api/admin/logs/download', methods=['GET'])
@login_required
def admin_logs_download():
    # Bundle structured + recent + crash into downloadable text
    from flask import Response
    lines = []
    lines.append(f"# Server instance {SERVER_INSTANCE_ID} start {SERVER_START_TS}")
    lines.append(f"# Generated {datetime.now().isoformat()}")
    lines.append("="*60)
    lines.append("## Structured logs")
    for e in list(_structured_logs):
        lines.append(f"[{e.get('ts')}] [{e.get('level')}] {e.get('msg')}")
    lines.append("="*60)
    lines.append("## Recent raw logs")
    for l in list(_recent_logs):
        lines.append(l.rstrip())
    lines.append("="*60)
    lines.append("## Crash logs")
    for c in list(_crash_logs):
        lines.append(f"[{c.get('ts')}] {c.get('type')}: {c.get('msg')}")
        lines.append(c.get('trace','')[:2000])
    content = "\n".join(lines)
    return Response(content, mimetype="text/plain", headers={"Content-Disposition": f"attachment; filename=server_logs_{SERVER_INSTANCE_ID[:8]}.txt"})

@app.route('/api/admin/crash_logs', methods=['GET'])
@login_required
def admin_crash_logs():
    return jsonify({'logs': list(_crash_logs), 'total': len(_crash_logs)})

@app.route('/api/admin/crash_logs/clear', methods=['POST'])
@login_required
def admin_crash_clear():
    _crash_logs.clear()
    # also truncate crash file
    try:
        open(CRASH_LOG_FILE, 'w').close()
    except: pass
    return jsonify({'ok': True})

@app.route('/api/admin/files', methods=['GET'])
@login_required
def admin_files():
    result = []
    if os.path.exists(LOG_DIR):
        for fname in sorted(os.listdir(LOG_DIR), key=lambda f: os.path.getmtime(os.path.join(LOG_DIR, f)), reverse=True):
            fpath = os.path.join(LOG_DIR, fname)
            if not os.path.isfile(fpath): continue
            try:
                stat = os.stat(fpath)
                result.append({
                    'name': fname,
                    'size': stat.st_size,
                    'size_human': f"{stat.st_size/1024:.1f}KB" if stat.st_size < 1024*1024 else f"{stat.st_size/1024/1024:.1f}MB",
                    'modified': datetime.fromtimestamp(stat.st_mtime).isoformat(),
                    'is_log': fname.endswith('.log') or fname.startswith('UI_DUMP') or fname.endswith('.txt'),
                })
            except: pass
    # also include cache dir stats
    cache_info = {}
    try:
        if os.path.exists('cache/lyrics'):
            cache_info['lyrics_count'] = len([f for f in os.listdir('cache/lyrics') if f.endswith('.json')])
        if os.path.exists('cache/translate'):
            cache_info['translate_count'] = len([f for f in os.listdir('cache/translate') if f.endswith('.json')])
    except: pass
    return jsonify({'files': result, 'cache': cache_info})

@app.route('/api/admin/files/download', methods=['GET'])
@login_required
def admin_files_download():
    fname = request.args.get('file','')
    # sanitize
    if not fname or '/' in fname or '\\' in fname or '..' in fname:
        return jsonify({'error': 'Invalid file'}), 400
    fpath = os.path.join(LOG_DIR, fname)
    if not os.path.exists(fpath):
        return jsonify({'error': 'Not found'}), 404
    from flask import send_file
    return send_file(fpath, as_attachment=True)

@app.route('/api/admin/self_update/check', methods=['GET'])
@login_required
def admin_self_update_check():
    local = _get_local_sha()
    remote, parent, meta = _get_remote_sha()
    main_file = _get_main_file()
    # Also compute file hashes for accurate comparison when not in git repo
    local_file_hash = None
    remote_file_hash = None
    try:
        if os.path.exists(main_file):
            local_file_hash = hashlib.sha256(open(main_file, 'rb').read()).hexdigest()[:12]
    except: pass
    try:
        # fetch remote file to compute hash (quick, cached by GitHub)
        content = _fetch_remote_file(remote) if remote else None
        if content:
            remote_file_hash = hashlib.sha256(content.encode('utf-8')).hexdigest()[:12]
    except: pass
    # Determine update availability: prefer git sha if both are 40-char, else file hash
    up_to_date = None
    update_available = False
    if local and remote:
        if len(local) == 40 and len(remote) == 40:
            up_to_date = (local == remote)
            update_available = (local != remote)
        elif local_file_hash and remote_file_hash:
            up_to_date = (local_file_hash == remote_file_hash)
            update_available = (local_file_hash != remote_file_hash)
        else:
            up_to_date = (local == remote)
            update_available = (local != remote)
    return jsonify({
        'local_sha': local,
        'remote_sha': remote,
        'parent_sha': parent,
        'local_file_hash': local_file_hash,
        'remote_file_hash': remote_file_hash,
        'main_file': main_file,
        'main_file_name': os.path.basename(main_file),
        'up_to_date': up_to_date,
        'update_available': update_available,
        'repo': SELF_UPDATE_REPO,
        'branch': SELF_UPDATE_BRANCH,
        'remote_path': SELF_UPDATE_REMOTE_PATH,
    })

@app.route('/api/admin/self_update/config', methods=['GET', 'POST'])
@login_required
def admin_self_update_config():
    if request.method == 'GET':
        return jsonify({'main_file': _admin_cfg.get('main_file'), 'detected': _get_main_file(), 'repo': SELF_UPDATE_REPO, 'branch': SELF_UPDATE_BRANCH})
    data = request.get_json(force=True) or {}
    # Allow user to set target filename like app.py / main.py / bot.py
    new_name = (data.get('main_file') or '').strip()
    if not new_name:
        _admin_cfg.pop('main_file', None)
    else:
        # sanitize: no path traversal, must end with .py, simple basename or relative path
        if '..' in new_name or new_name.startswith('/'):
            return jsonify({'error': 'Invalid filename'}), 400
        if not new_name.endswith('.py'):
            return jsonify({'error': 'Must be .py file'}), 400
        _admin_cfg['main_file'] = new_name
    _save_admin_config(_admin_cfg)
    return jsonify({'ok': True, 'main_file': _admin_cfg.get('main_file'), 'detected': _get_main_file()})

@app.route('/api/admin/self_update/perform', methods=['POST'])
@login_required
def admin_self_update_perform():
    # Optional param to force even if up to date
    force = request.args.get('force') == '1' or (request.get_json(silent=True) or {}).get('force')
    local = _get_local_sha()
    remote, parent, meta = _get_remote_sha()
    if not remote:
        return jsonify({'ok': False, 'error': 'Could not fetch remote SHA'}), 502
    if not force:
        # Check file hash as well
        try:
            lf = hashlib.sha256(open(_get_main_file(), 'rb').read()).hexdigest()[:12] if os.path.exists(_get_main_file()) else None
            rf_content = _fetch_remote_file(remote)
            rf = hashlib.sha256(rf_content.encode('utf-8')).hexdigest()[:12] if rf_content else None
            if lf and rf and lf == rf:
                return jsonify({'ok': False, 'error': 'Already up to date (file hash)', 'local': local, 'remote': remote}), 200
        except: pass
        if local == remote:
            return jsonify({'ok': False, 'error': 'Already up to date', 'local': local, 'remote': remote}), 200
    ok, msg = _perform_self_update()
    if ok:
        # Log and schedule restart after response
        print(f"[SELF-UPDATE] {msg} - restarting in 1s")
        def _restart():
            time_module.sleep(1)
            try:
                # Try to restart via execv (preserves args)
                py = sys.executable
                os.execv(py, [py] + sys.argv)
            except Exception as e:
                print(f"[SELF-UPDATE] restart failed: {e}")
                os._exit(0)
        threading.Thread(target=_restart, daemon=True).start()
        return jsonify({'ok': True, 'message': msg, 'local': local, 'remote': remote, 'parent': parent, 'restarting': True})
    else:
        return jsonify({'ok': False, 'error': msg, 'local': local, 'remote': remote}), 500

@app.errorhandler(404)
def handle_404(e):
    # log but not crash
    print(f"[WARN] 404 {request.path} from {request.remote_addr}")
    return jsonify({'error': 'Not found'}), 404

@app.errorhandler(500)
def handle_500(e):
    _log_crash(type(e), e, getattr(e, '__traceback__', None))
    return jsonify({'error': 'Internal error', 'instance': SERVER_INSTANCE_ID}), 500

@app.route('/log', methods=['POST'])
def proxy_log():
    try:
        data = request.get_json(force=True)
        req_type = data.get('type', '')

        if req_type == "APP_LOG":
            event = data.get('event', 'unknown')
            level = data.get('level', 'info')
            message = data.get('message', '')
            payload = data.get('payload', {})
            timestamp = data.get('timestamp') or datetime.now().isoformat(timespec='milliseconds')
            vid = payload.get('videoId') or payload.get('videoID') or ''
            client_ip = request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-For') or request.remote_addr
            if vid:
                print(f"[iOS] [iOS Tweak] [{timestamp}] [{level.upper()}] {event}: {message} | payload={payload} ip={client_ip}")
            else:
                print(f"[iOS] [iOS Tweak] [{timestamp}] [{level.upper()}] {event}: {message}")
                if payload:
                    print(f"  [iOS] payload={payload} ip={client_ip}")
            return jsonify({"status": "ok"})

        if req_type == "UI_DUMP":
            os.makedirs("logs", exist_ok=True)
            timestamp = datetime.now().strftime("%H-%M-%S")
            dump_content = data.get('request_body', '')
            vc_count = dump_content.count('ViewController')
            win_count = dump_content.count('[WINDOW:')
            has_9999 = 'tag = 9999' in dump_content
            has_engagement = 'Engagement' in dump_content
            has_lyrics_chip = 'No lyrics found' in dump_content or 'lyric' in dump_content.lower()
            hidden_yes = dump_content.count('hidden = YES')
            hidden_no = dump_content.count('hidden = NO')
            video_id_match = re.search(r'Current VideoID:\s*(\S+)', dump_content)
            playback_match = re.search(r'Playback Time:\s*([\d\.]+)', dump_content)
            tweak_match = re.search(r'Tweak Build:\s*(\S+)', dump_content)
            vid = video_id_match.group(1) if video_id_match else '?'
            ptime = playback_match.group(1) if playback_match else '?'
            tweak_sha = tweak_match.group(1) if tweak_match else '?'
            try:
                srv_sha = (_get_local_sha() or '?')[:7]
            except Exception:
                srv_sha = '?'
            print(f"\n[ALERT] [UI_DUMP {timestamp}] [DUMP] UI Dump received! video={vid} t={ptime}s tweak={tweak_sha} srv={srv_sha} vc={vc_count} win={win_count} has9999={has_9999} hasEngagement={has_engagement} hasLyricsChip={has_lyrics_chip} hiddenYES={hidden_yes} hiddenNO={hidden_no}")
            if not has_9999:
                print(f"  [WARN] [UI_DUMP] Modded lyrics view tag 9999 NOT found - panel will show official!")
            if not has_engagement:
                print(f"  [WARN] [UI_DUMP] No Engagement panel detected - user may not have opened lyrics panel")
            if not has_lyrics_chip:
                print(f"  [WARN] [UI_DUMP] No lyrics chip text detected - button may be hidden/locked or ASDisplayView (unlock failed)")

            filepath = f"logs/UI_DUMP_{timestamp}.txt"
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(dump_content)
            print(f"[OK] [UI_DUMP] Saved to {filepath} ({len(dump_content)} bytes)")
            return jsonify({"status": "ok"})

        if req_type == "CRASH":
            # iOS tweak crash report
            payload = data.get('payload', {})
            msg = data.get('message', 'iOS crash')
            print(f"[CRASH] [iOS] {msg} payload={payload}")
            _crash_logs.append({'ts': datetime.now().isoformat(), 'type': 'iOS_Crash', 'msg': msg, 'trace': str(payload)[:3000], 'instance': SERVER_INSTANCE_ID})
            try:
                with open(CRASH_LOG_FILE, 'a', encoding='utf-8') as f:
                    f.write(f"\n[{datetime.now().isoformat()}] [CRASH] iOS: {msg} {payload}\n")
            except: pass
            return jsonify({"status": "ok"})

        print(f"[WARN] Unknown log type: {req_type} payload={data}")
        return jsonify({"status": "ok"})

    except Exception as e:
        print(f"[FAIL] [LOG] error: {e}")
        import traceback as _tb; _tb.print_exc()
        _log_crash(type(e), e, e.__traceback__)
        return jsonify({"status": "error", "message": str(e)}), 500


if __name__ == '__main__':
    print("=" * 60)
    print("[MUSIC] YTMusic Ultimate - Lyrics API Server")
    print(f"Instance: {SERVER_INSTANCE_ID} started {SERVER_START_TS}")
    print("=" * 60)
    print("Providers (priority order):")
    print("  0. Cubey API  (Musixmatch/QQ/KuGou/NetEase, requires JWT)")
    print("  1. LRCLIB     (synced + plain, free)")
    print("  2. Unison     (community, free)")
    print("  3. YT Music   (plain, via ytmusicapi)")
    print("Translation: Cohere Command A Translate")
    print("Auth: Cloudflare Turnstile via in-app WKWebView")
    print("=" * 60)
    print("Server: http://0.0.0.0:20016")
    print(f"Logs: {SERVER_LOG_FILE} | Crash: {CRASH_LOG_FILE}")
    print("=" * 60)
    # Log startup to files
    try:
        with open(SERVER_LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(f"\n{'='*60}\n[{SERVER_START_TS}] START instance {SERVER_INSTANCE_ID}\n{'='*60}\n")
    except: pass

    clear_not_found_caches()
    try:
        app.run(host='0.0.0.0', port=20016, debug=False, use_reloader=False, threaded=True)
    except Exception as e:
        _log_crash(type(e), e, e.__traceback__)
        raise

