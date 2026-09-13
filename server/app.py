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
from flask_sock import Sock
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

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
app = Flask(__name__, template_folder=os.path.join(_ROOT, 'templates'))

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

sock = Sock(app)
