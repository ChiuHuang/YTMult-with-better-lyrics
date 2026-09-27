#!/usr/bin/env python3
"""
YTMusicUltimate lyrics node.

This file is generated per-node -- the server bakes in a unique NODE_ID and
NODE_KEY when you download it from the admin panel's Nodes page, so you can
drop it onto any machine and run it with zero manual configuration:

    pip install websocket-client requests
    python3 node.py

It connects back to the main server over a WebSocket and does more than two
things:
  1. Answers "do you have this cached?" queries, so a cache hit doesn't
     repeat work someone else's node (or the server itself) already did.
  2. Relays outbound lyric-provider HTTP requests through this machine's IP
     when asked, for IP diversity against provider rate limits.
  3. Accepts the server's Cubey JWT pool ('jwt_sync' messages) and hands a
     token back when asked ('jwt_get'), so the server can borrow one when
     its own pool is empty.
  4. Self-updates: the server tells it the current node.template code_sha in
     the hello_ack and in periodic ping messages; when its own copy is stale
     it refetches the personalized script from the server and restarts.
  5. Contributes a Cubey JWT to the shared pool if YTMU_JWT is set.

This node never sees the server's Cohere/translation API keys -- those stay
on the main server. All this node does is fetch raw (untranslated) lyrics
data on request and serve its own local cache. It also has no built-in idea
of what "Cubey" or "Musixmatch" even are: it just performs whatever HTTP
request it's told to and hands back the status + body, so all the
provider-specific logic stays in one place (the main server) instead of
being duplicated -- and potentially drifting out of sync -- here.

If you ever lose this file, don't try to hand-edit a copy: revoke the node
from the admin panel and download a fresh one. The key below only exists in
this file and in a hash on the server; it cannot be recovered or reissued
for the same node_id.
"""

import hashlib
import json
import os
import random
import re
import sys
import time
import requests
import websocket  # pip install websocket-client
from urllib.parse import quote, urlsplit

SERVER_WS_URL = "__SERVER_WS_URL__"
NODE_ID = "__NODE_ID__"
NODE_KEY = "__NODE_KEY__"

CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "node_cache", "lyrics")
CACHE_TTL_SECONDS = 86400 * 3  # matches the main server's cache lifetime
JWT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "node_cache", "jwt.json")

os.makedirs(CACHE_DIR, exist_ok=True)

_SAFE_COMPONENT_RE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')


def _safe_cache_path(cache_key):
    # cache_key is always "<video_id>:<lang>" or "<video_id>:<lang>:fast",
    # already validated server-side before it's ever sent here -- but this
    # node is an independently-run process and should never trust that
    # blindly, so it re-validates every component before touching disk.
    parts = cache_key.split(':')
    if not (2 <= len(parts) <= 3):
        return None
    for p in parts:
        if not _SAFE_COMPONENT_RE.match(p):
            return None
    return os.path.join(CACHE_DIR, cache_key.replace(':', '__') + ".json")


def _load_local_cache(cache_key):
    path = _safe_cache_path(cache_key)
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path, 'r', encoding='utf-8') as f:
            entry = json.load(f)
        if time.time() - entry.get('ts', 0) > CACHE_TTL_SECONDS:
            return None
        return entry.get('data')
    except Exception:
        return None


def _save_local_cache(cache_key, data):
    path = _safe_cache_path(cache_key)
    if not path:
        return
    try:
        with open(path, 'w', encoding='utf-8') as f:
            json.dump({'data': data, 'ts': time.time()}, f, ensure_ascii=False)
    except Exception:
        pass


def _save_synced_jwts(tokens):
    """Replace this node's stored copy of the server's JWT pool wholesale, so a
    token the server dropped (twice dead, or evicted past the pool cap) also
    disappears here. Returns how many are held."""
    clean = [t for t in (tokens or []) if isinstance(t, str) and len(t) >= 20]
    if not clean:
        return 0
    try:
        os.makedirs(os.path.dirname(JWT_FILE), exist_ok=True)
        with open(JWT_FILE, 'w', encoding='utf-8') as f:
            json.dump({'tokens': clean, 'updated': time.time()}, f)
    except Exception as e:
        print(f"[node] jwt store failed: {e}")
        return 0
    return len(clean)


def _pick_synced_jwt():
    """The token to hand back on 'jwt_get': last one received, else whatever is
    still on disk. Purely local, no network."""
    tok = getattr(_pick_synced_jwt, '_last', None)
    if tok:
        return tok
    try:
        if not os.path.exists(JWT_FILE):
            return None
        with open(JWT_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
        toks = [t for t in (data.get('tokens') or []) if isinstance(t, str) and len(t) >= 20]
        return toks[-1] if toks else None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Self-update + JWT contribution
# ---------------------------------------------------------------------------
# SERVER_WS_URL / NODE_ID / NODE_KEY are personalized per node, so hashes of
# the raw file would differ even for identical code. Normalize those three
# lines to empty values -- the server hashes its node.py template the same
# way -- so the sha only changes when node code actually changes.
_NODE_VERSION_RE = re.compile(r'^(SERVER_WS_URL|NODE_ID|NODE_KEY)(\s*=\s*)["\'](.*)["\']$', re.M)


def _code_sha():
    try:
        with open(os.path.abspath(__file__), 'r', encoding='utf-8') as f:
            src = f.read()
        norm = _NODE_VERSION_RE.sub(lambda m: m.group(1) + m.group(2) + '""', src)
        return hashlib.sha256(norm.encode('utf-8')).hexdigest()
    except Exception:
        return None


def _http_base():
    # SERVER_WS_URL carries the ws endpoint path too (e.g. wss://host/ws/node);
    # self-update and any direct HTTP need the bare origin, not that path.
    parts = urlsplit(SERVER_WS_URL)
    if not parts.scheme or not parts.netloc:
        return None
    scheme = 'https' if parts.scheme == 'wss' else ('http' if parts.scheme == 'ws' else parts.scheme)
    return f"{scheme}://{parts.netloc}"


def _maybe_self_update(server_code_sha):
    """Refetch the personalized node script when the server's node-template
    code_sha differs from ours. Returns True only if it execv'd a fresh
    interpreter (never returns in that case), else False."""
    local = _code_sha()
    if not server_code_sha or not local or server_code_sha == local:
        return False
    print(f"[node] server code_sha {server_code_sha[:10]} != local {local[:10]}, refetching script")
    base = _http_base()
    if not base:
        return False
    url = f"{base}/api/admin/nodes/generate/{quote(NODE_ID)}?key={quote(NODE_KEY)}"
    try:
        resp = requests.get(url, timeout=20)
    except Exception as e:
        print(f"[node] self-update fetch failed: {e}")
        return False
    script = resp.text
    if resp.status_code != 200 or len(script) < 500:
        print(f"[node] self-update: bad response status={resp.status_code}")
        return False
    if NODE_ID not in script or NODE_KEY not in script:
        print("[node] self-update: server returned a different identity, ignoring")
        return False
    try:
        with open(os.path.abspath(__file__), 'w', encoding='utf-8', newline='\n') as f:
            f.write(script.replace('\r\n', '\n'))
    except Exception as e:
        print(f"[node] self-update: write failed: {e}")
        return False
    print("[node] self-update: downloaded new script, restarting")
    os.execv(sys.executable, [sys.executable] + sys.argv)
    return True


_jwt_env = os.environ.get('YTMU_JWT') or ''


def _maybe_contribute_jwt(ws):
    if not _jwt_env:
        return
    try:
        ws.send(json.dumps({'type': 'jwt_contribute', 'token': _jwt_env}))
    except Exception:
        pass


def handle_task(msg):
    """Perform a relayed task on this node's own IP and return the result.
    Currently only 'http_fetch' exists: run the exact HTTP request the
    server asks for and hand back the raw status + body."""
    if msg.get('task') != 'http_fetch':
        return {'error': f"unknown task {msg.get('task')}"}
    print(f"[node] executing http task from server: {msg.get('method', 'GET')} {msg.get('url')}")
    try:
        resp = requests.request(
            msg.get('method', 'GET'),
            msg['url'],
            data=msg.get('data'),
            headers=msg.get('headers') or {},
            timeout=20,
        )
        raw = resp.content
        # Force UTF-8: lyrics SSE/JSON APIs serve UTF-8 bytes but usually omit
        # the charset, and resp.text would then guess ISO-8859-1 (mojibake).
        try:
            text = raw.decode('utf-8')
        except UnicodeDecodeError:
            text = resp.text
        return {'status': resp.status_code, 'text': text}
    except Exception as e:
        return {'error': str(e)}


def on_open(ws):
    print(f"[node] socket open, authenticating as {NODE_ID}")
    ws.send(json.dumps({'type': 'hello', 'node_id': NODE_ID, 'key': NODE_KEY, 'code_sha': _code_sha()}))


def on_message(ws, raw):
    try:
        msg = json.loads(raw)
    except Exception:
        return
    mtype = msg.get('type')
    request_id = msg.get('request_id')

    if mtype == 'hello_ack':
        if msg.get('ok'):
            # The server accepted this node: the reconnect loop resets its
            # backoff on this, so a socket that lived for hours does not
            # hand the next outage a 10s wait.
            _SESSION['authed_at'] = time.time()
            print(f"[node] connected and authenticated as {NODE_ID}")
            if not _maybe_self_update(msg.get('code_sha')):
                _maybe_contribute_jwt(ws)
        else:
            print(f"[node] server rejected connection: {msg.get('error')}")
            ws.close()
        return

    if mtype == 'ping':
        # server broadcast -- self-update when the template sha moved on
        _maybe_self_update(msg.get('code_sha'))
        return

    if mtype == 'jwt_sync':
        n = _save_synced_jwts(msg.get('tokens'))
        if n:
            # Remember the freshest one in memory: 'jwt_get' can then answer
            # even before the file write is visible, and the newest token is
            # the one the server wants back.
            _pick_synced_jwt._last = msg['tokens'][-1]
        print(f"[node] jwt pool synced: {n} token(s) held")
        return

    if mtype == 'jwt_get':
        token = _pick_synced_jwt()
        ws.send(json.dumps({'type': 'jwt_data', 'request_id': request_id, 'token': token}))
        return

    if mtype == 'cache_check':
        found = _load_local_cache(msg.get('cache_key', '')) is not None
        ws.send(json.dumps({'type': 'cache_check_result', 'request_id': request_id, 'found': found}))
        return

    if mtype == 'cache_fetch':
        data = _load_local_cache(msg.get('cache_key', ''))
        ws.send(json.dumps({'type': 'cache_data', 'request_id': request_id, 'data': data}))
        return

    if mtype == 'task':
        result = handle_task(msg)
        result['type'] = 'task_result'
        result['request_id'] = request_id
        ws.send(json.dumps(result))
        return


def on_close(ws, code, reason):
    print(f"[node] disconnected (code={code} reason={reason})")


def _to_wss(url):
    # Reverse proxies often 301 ws:// -> wss:// ; websocket-client treats a
    # scheme change as an invalid redirect, so we upgrade the URL ourselves.
    if url.startswith('ws://'):
        return 'wss://' + url[5:]
    if url.startswith('http://'):
        return 'https://' + url[7:]
    return url


# ------------------------------------------------------------------
# Reconnect pacing + liveness
# ------------------------------------------------------------------
# A node is a background helper, not a user-facing client: it only ever
# has to be back online within a few seconds of the server, so the floor
# is 1s and the cap only 10s. The old 2s-doubling-to-60s curve meant a
# server restart (or a 3am wifi blip after a long healthy session) left
# the node dark for up to a minute, and nothing ever reset the curve -- one
# bad afternoon cost the whole day.
_RECONNECT_MIN = 1.0
_RECONNECT_MAX = 10.0
_RECONNECT_GROWTH = 1.5
# Jitter so a fleet of nodes that all dropped at the same moment (a
# deploy) does not come back in lockstep. It only ever LENGTHENS the wait,
# and the result is clamped back to _RECONNECT_MAX, so both ends of the
# band stay exactly 1s and 10s.
_RECONNECT_JITTER = 0.15
# Liveness: ping every 30s, but wait 120s for the pong. The pong is
# recorded by the READER thread, which is the same thread on_message runs
# on, so a relayed http task (20s timeout, and they can queue) blocks it.
# With ping_timeout=10 a single slow fetch was enough for the client to
# call a healthy socket dead and tear it down.
_PING_INTERVAL = 30
_PING_TIMEOUT = 120

# Written by on_message, cleared before every dial: the loop uses this to
# tell "a working session ended" (reset the curve) from "the dial never got
# anywhere" / "the server rejected us" (keep growing, so neither a revoked
# key nor a proxy that kills every socket can spin at 1s forever).
_SESSION = {'authed_at': 0.0}
# ...but a session must have lived at least this long to earn the reset: a
# socket that dies a second after auth is a fault to back off from, not an
# outage to retry quickly.
_SESSION_RESET_MIN = 15.0


def run_forever_with_backoff():
    backoff = _RECONNECT_MIN
    url = SERVER_WS_URL
    state = {'upgrade': False}
    while True:
        _SESSION['authed_at'] = 0.0

        def _on_error(ws, error):
            msg = str(error)
            if ('Invalid redirect target' in msg and 'scheme' in msg
                    and url.startswith(('ws://', 'http://'))):
                state['upgrade'] = True
            print(f"[node] error: {msg}")

        try:
            ws = websocket.WebSocketApp(
                url,
                on_open=on_open,
                on_message=on_message,
                on_error=_on_error,
                on_close=on_close,
            )
            ws.run_forever(ping_interval=_PING_INTERVAL, ping_timeout=_PING_TIMEOUT)
        except Exception as e:
            print(f"[node] connection loop error: {e}")
        authed_at = _SESSION['authed_at']
        if authed_at:
            held = time.time() - authed_at
            if held >= _SESSION_RESET_MIN:
                backoff = _RECONNECT_MIN
                print(f"[node] session lasted {held:.0f}s")
            else:
                print(f"[node] session lasted only {held:.0f}s, keeping backoff")
        if state['upgrade']:
            url = _to_wss(url)
            state['upgrade'] = False
            backoff = _RECONNECT_MIN
            print(f"[node] server requires HTTPS websocket, upgraded to {url}")
        wait = min(backoff * (1.0 + _RECONNECT_JITTER * random.random()),
                   _RECONNECT_MAX)
        print(f"[node] reconnecting in {wait:.1f}s…")
        time.sleep(wait)
        backoff = min(backoff * _RECONNECT_GROWTH, _RECONNECT_MAX)


if __name__ == "__main__":
    if SERVER_WS_URL.startswith("__") or NODE_KEY.startswith("__"):
        print("This node.py hasn't been personalized. Download it from the "
              "admin panel's Nodes page instead of running this template file directly.")
        sys.exit(1)
    print(f"[node] starting, connecting to {SERVER_WS_URL} as {NODE_ID}")
    run_forever_with_backoff()
