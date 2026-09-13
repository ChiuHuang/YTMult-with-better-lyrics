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
from .app import _admin_cfg, LOG_DIR
from .logging_util import _log_crash

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
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'proxy_server.py')

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
    try:
        _root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        if os.path.isdir(os.path.join(_root, '.git')):
            r = subprocess.run(['git', 'pull', '--ff-only'], cwd=_root,
                capture_output=True, text=True, timeout=60)
            if r.returncode == 0:
                return True, f"git pull: {(r.stdout or '').strip()[:200]}"
            return False, f"git pull failed: {(r.stderr or r.stdout or '').strip()[:200]}"
    except Exception as e:
        return False, f"git pull error: {e}"
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

