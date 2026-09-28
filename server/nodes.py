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
from flask import request
from .app import sock

# ============================================================
# Node mesh (WebSocket worker nodes)
#
# Lets you run node.py on other machines/IPs. They connect back here over a
# persistent, authenticated WebSocket. Used for three things:
#   1. Cache sharing, PULL ONLY: before doing a fresh fetch, every connected
#      node gets asked "do you already have this cached?" so work a node
#      already did doesn't get redone. The server deliberately does NOT push
#      its own cache/lyrics down to the nodes anymore -- a node only holds
#      what it fetched itself (or got with a JWT-scoped relay), and the pull
#      is a best-effort bonus on top of that, never a dependency.
#   2. JWT sync (server -> node): the live Cubey token pool is pushed to
#      nodes so one that is holding a token can hand it back when this
#      server's pool is dry. A node already sees raw tokens today through
#      relay_http_request (a probe posts the token in the body), so this is
#      the same exposure, not a new one. Per-node opt-out: "jwt_sync": false
#      in config/nodes.json.
#   3. IP diversity: the Cubey/Musixmatch lookup (the one most exposed to
#      per-IP rate limits) can be relayed through a connected node's
#      outbound IP instead of always going out from this server.
# Node availability is purely additive: with no nodes connected, or if a
# node call fails or times out, everything falls back to exactly the same
# local behavior as without this feature at all. Keeping this fast is a
# nice-to-have, not a requirement -- every node call has a short timeout and
# a local fallback, so a slow or dead node degrades gracefully instead of
# blocking a real request.
# ============================================================

NODES_FILE = os.path.join('config', 'nodes.json')


def _load_nodes():
    if os.path.exists(NODES_FILE):
        try:
            with open(NODES_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def _save_nodes(nodes):
    os.makedirs('config', exist_ok=True)
    with open(NODES_FILE, 'w', encoding='utf-8') as f:
        json.dump(nodes, f, indent=2)


def _hash_node_key(key):
    return hashlib.sha256(key.encode()).hexdigest()


def client_real_ip():
    """Real client IP, honoring Cloudflare's proxy headers. Works in both
    regular Flask routes and flask-sock websocket handlers (the WS upgrade
    is just an HTTP request with the same headers)."""
    xff = (request.headers.get('X-Forwarded-For') or '').split(',')[0].strip()
    return (request.headers.get('CF-Connecting-IP') or xff or request.remote_addr) or ''


connected_nodes = {}          # node_id -> {'ws':..., 'connected_ts':..., 'label':...}
_connected_nodes_lock = threading.Lock()

_pending_node_requests = {}   # request_id -> {'event': threading.Event(), 'result': dict|None}
_pending_lock = threading.Lock()

_node_rr_counter = 0
_node_rr_lock = threading.Lock()


def pick_node():
    """Round-robin pick of a connected node's id, or None if none are
    online. Deliberately simple -- load/latency-aware routing isn't worth
    the complexity here."""
    global _node_rr_counter
    with _connected_nodes_lock:
        ids = list(connected_nodes.keys())
    if not ids:
        return None
    with _node_rr_lock:
        idx = _node_rr_counter % len(ids)
        _node_rr_counter += 1
    return ids[idx]


def send_to_node(node_id, message, wait_reply=True, timeout=5.0):
    """Send a JSON message to a connected node, optionally blocking for a
    reply carrying the same request_id. Returns the reply dict, or None on
    timeout / disconnection / no-reply-requested -- callers must treat None
    as "unavailable, fall back", never as an error worth surfacing."""
    with _connected_nodes_lock:
        entry = connected_nodes.get(node_id)
    if not entry:
        return None
    request_id = message.get('request_id')
    ev = None
    if wait_reply and request_id:
        ev = threading.Event()
        with _pending_lock:
            _pending_node_requests[request_id] = {'event': ev, 'result': None}
    try:
        entry['ws'].send(json.dumps(message))
    except Exception as e:
        print(f"  [NODE] send to {node_id} failed: {e}")
        if ev:
            with _pending_lock:
                _pending_node_requests.pop(request_id, None)
        return None
    if not wait_reply or not request_id:
        return None
    got = ev.wait(timeout=timeout)
    with _pending_lock:
        pending = _pending_node_requests.pop(request_id, None)
    if not got or not pending:
        print(f"  [NODE] {node_id} timed out after {timeout}s")
        return None
    return pending['result']


def ask_nodes_for_cache(cache_key, timeout=2.0):
    """Ask every connected node whether it already has this exact cache_key
    cached, and if so, pull the data. Returns the data dict, or None.
    Sequential with a short per-node timeout -- fine since this only runs
    on a cache miss, and finding already-done work matters more than
    shaving milliseconds off this path."""
    with _connected_nodes_lock:
        ids = list(connected_nodes.keys())
    for node_id in ids:
        reply = send_to_node(node_id, {
            'type': 'cache_check', 'request_id': _secrets.token_hex(8), 'cache_key': cache_key,
        }, timeout=timeout)
        if reply and reply.get('found'):
            data_reply = send_to_node(node_id, {
                'type': 'cache_fetch', 'request_id': _secrets.token_hex(8), 'cache_key': cache_key,
            }, timeout=timeout * 2)
            if data_reply and data_reply.get('data'):
                print(f"  [NODE] cache hit on {node_id} for {cache_key}")
                return data_reply['data']
    return None


def relay_http_request(node_id, method, url, data=None, headers=None, timeout=15):
    """Ask a node to perform an HTTP request using its own outbound IP and
    hand back the raw response. Returns (status_code, text) or None on
    failure/timeout -- callers must fall back to a direct local request
    when this returns None, never treat a node as a hard dependency."""
    reply = send_to_node(node_id, {
        'type': 'task', 'task': 'http_fetch', 'request_id': _secrets.token_hex(8),
        'method': method, 'url': url, 'data': data, 'headers': headers or {},
    }, timeout=timeout + 3)
    if not reply or 'status' not in reply:
        return None
    print(f"  [NODE] {node_label(node_id)} handled {method} {url} (HTTP {reply['status']})")
    return reply['status'], reply.get('text', '')


def node_label(node_id):
    """Human-readable label for a node: its configured label when known,
    otherwise just the id."""
    with _connected_nodes_lock:
        entry = connected_nodes.get(node_id)
    if entry and entry.get('label'):
        return f"{entry['label']} ({node_id})"
    return node_id


# ============================================================
# Node script versioning + JWT sync + pings
# ============================================================
_NODE_TEMPLATE_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'node.py')
# These three lines are personalized per node, so comparing raw hashes would
# always report a bogus mismatch. Normalize their values to empty on BOTH the
# server template and the node's own copy (the node mirrors this regex), so
# the hashes only change when the actual node code changes.
_NODE_VERSION_RE = re.compile(r'^(SERVER_WS_URL|NODE_ID|NODE_KEY)(\s*=\s*)["\'](.*)["\']$', re.M)


def _normalize_node_source(src):
    return _NODE_VERSION_RE.sub(lambda m: f'{m.group(1)}{m.group(2)}""', src)


def _node_template_sha():
    try:
        with open(_NODE_TEMPLATE_PATH, 'r', encoding='utf-8') as f:
            return hashlib.sha256(_normalize_node_source(f.read()).encode('utf-8')).hexdigest()
    except Exception as e:
        print(f"  [NODE] template sha error: {e}")
        return None


def _current_server_sha():
    try:
        from .self_update import _get_local_sha
        return _get_local_sha()
    except Exception:
        return None


def _broadcast_pings():
    """Keep every node honest: periodically tell it the server's node-template
    code_sha (plus the server's own repo sha). A node whose own script version
    differs refetches its personalized script and restarts itself."""
    while True:
        time_module.sleep(30)
        try:
            code_sha = _node_template_sha()
        except Exception:
            code_sha = None
        server_sha = _current_server_sha()
        msg = json.dumps({'type': 'ping', 'server_sha': server_sha, 'code_sha': code_sha, 'ts': time_module.time()})
        with _connected_nodes_lock:
            ws_list = [e['ws'] for e in connected_nodes.values()]
        for entry_ws in ws_list:
            try:
                entry_ws.send(msg)
            except Exception:
                pass


def _jwt_sync_allowed(node_id):
    """Per-node opt-out for the JWT push: "jwt_sync": false in
    config/nodes.json. Read from the live record cached at connect time, with
    the on-disk record as the fallback for a node that predates that field."""
    with _connected_nodes_lock:
        entry = connected_nodes.get(node_id)
    if entry is not None and 'jwt_sync' in entry:
        return bool(entry['jwt_sync'])
    try:
        rec = _load_nodes().get(node_id) or {}
    except Exception:
        return True
    return rec.get('jwt_sync', True) is not False


def _live_jwt_tokens():
    """Raw live tokens from the server's Cubey pool, newest-use first. Imports
    lazily: jwt_pool imports us at module level."""
    try:
        from .jwt_pool import live_jwt_tokens
        return live_jwt_tokens()
    except Exception as e:
        print(f"  [NODE] jwt pool read failed: {e}")
        return []


def _push_jwt_sync(node_id, tokens):
    """Send the pool to one node as a single 'jwt_sync' message. The node
    replaces its stored copy wholesale, so a token this server dropped (twice
    dead, or past POOL_MAX) disappears from the node too. Returns True when the
    push went out."""
    if not tokens or not _jwt_sync_allowed(node_id):
        return False
    with _connected_nodes_lock:
        entry = connected_nodes.get(node_id)
        entry_ws = entry['ws'] if entry else None
    if entry_ws is None:
        return False
    try:
        entry_ws.send(json.dumps({'type': 'jwt_sync', 'tokens': tokens}))
    except Exception as e:
        print(f"  [NODE] jwt sync to {node_id} failed: {e}")
        return False
    print(f"  [NODE] jwt sync to {node_id}: {len(tokens)} token(s)")
    return True


def _jwt_sync_for(node_id):
    """Connect-time push, so a node that just came online can answer 'jwt_get'
    immediately instead of staying empty until the next tick."""
    try:
        _push_jwt_sync(node_id, _live_jwt_tokens())
    except Exception as e:
        print(f"  [NODE] jwt sync thread error: {e}")


def ask_nodes_for_jwt(timeout=2.0):
    """Ask each connected node for a Cubey token it is holding. Returns
    (node_id, token) or (None, None). Callers treat a miss as 'pool is dry',
    never as an error -- this is a background top-up, not a request path."""
    with _connected_nodes_lock:
        ids = list(connected_nodes.keys())
    for node_id in ids:
        reply = send_to_node(node_id, {
            'type': 'jwt_get', 'request_id': _secrets.token_hex(8),
        }, timeout=timeout)
        if reply and reply.get('token'):
            return node_id, reply['token']
    return None, None


def _jwt_sync_loop():
    """Keep every node's copy of the pool current. Only re-pushes when the
    token set actually changed (cheap signature over the ids), so a steady
    pool costs one hash per minute."""
    last_sig = None
    while True:
        time_module.sleep(60)
        try:
            tokens = _live_jwt_tokens()
            sig = hashlib.sha256('|'.join(tokens).encode('utf-8')).hexdigest()
            # A node that connects while the pool is already this exact shape
            # still gets its own push from _jwt_sync_for at connect time, so
            # here a changed signature is the only thing worth re-sending.
            if sig != last_sig:
                with _connected_nodes_lock:
                    ids = list(connected_nodes.keys())
                for nid in ids:
                    _push_jwt_sync(nid, tokens)
                last_sig = sig
        except Exception as e:
            print(f"  [NODE] jwt sync loop error: {e}")


_started_threads = False
_thread_start_lock = threading.Lock()


def _ensure_node_workers():
    global _started_threads
    with _thread_start_lock:
        if _started_threads:
            return
        _started_threads = True
    threading.Thread(target=_broadcast_pings, daemon=True).start()
    threading.Thread(target=_jwt_sync_loop, daemon=True).start()


@sock.route('/ws/node')
def ws_node(ws):
    node_id = None
    try:
        raw = ws.receive(timeout=10)
        if not raw:
            return
        hello = json.loads(raw)
        if hello.get('type') != 'hello':
            ws.send(json.dumps({'type': 'hello_ack', 'ok': False, 'error': 'expected hello'}))
            return

        candidate_id = hello.get('node_id')
        key = hello.get('key')
        nodes = _load_nodes()
        record = nodes.get(candidate_id)
        if not record or not key or record.get('key_hash') != _hash_node_key(key):
            ws.send(json.dumps({'type': 'hello_ack', 'ok': False, 'error': 'invalid node_id or key'}))
            print(f"  [NODE] rejected connection for node_id={candidate_id} (bad key)")
            return

        node_id = candidate_id
        real_ip = client_real_ip()
        record['last_seen'] = datetime.now().isoformat()
        if real_ip:
            record['last_ip'] = real_ip
        # Default-on JWT push, per-node opt-out via "jwt_sync": false.
        if 'jwt_sync' not in record:
            record['jwt_sync'] = True
        nodes[node_id] = record
        _save_nodes(nodes)

        with _connected_nodes_lock:
            connected_nodes[node_id] = {'ws': ws, 'connected_ts': time_module.time(), 'label': record.get('label', node_id), 'ip': real_ip, 'jwt_sync': bool(record.get('jwt_sync', True))}
        print(f"  [NODE] {node_id} ({record.get('label', '')}) connected")
        try:
            from .app import _sse_broadcast
            _sse_broadcast('node', {'node_id': node_id, 'label': record.get('label', ''), 'online': True, 'ip': real_ip})
        except Exception:
            pass
        ws.send(json.dumps({'type': 'hello_ack', 'ok': True,
                            'code_sha': _node_template_sha(),
                            'server_sha': _current_server_sha()}))
        threading.Thread(target=_jwt_sync_for, args=(node_id,), daemon=True).start()

        while True:
            raw = ws.receive(timeout=90)  # generous: the node's WebSocketApp pings every 30s
            if raw is None:
                break
            try:
                msg = json.loads(raw)
            except Exception:
                continue
            mtype = msg.get('type')
            request_id = msg.get('request_id')
            if mtype in ('cache_check_result', 'cache_data', 'task_result', 'jwt_data') and request_id:
                with _pending_lock:
                    pending = _pending_node_requests.get(request_id)
                if pending:
                    pending['result'] = msg
                    pending['event'].set()
            elif mtype == 'jwt_contribute':
                # A node boots with a Cubey JWT available (env YTMU_JWT) and
                # hands it over here so the server can fall back to it when a
                # request arrives without one.
                from .jwt_pool import contribute_jwt
                res = contribute_jwt(msg.get('token'), node_id=node_id)
                if request_id:
                    ack = dict(res)
                    ack['type'] = 'jwt_contribute_ack'
                    ack['request_id'] = request_id
                    try:
                        ws.send(json.dumps(ack))
                    except Exception:
                        pass
            # any other message type (e.g. a bare ping) needs no action --
            # receive() just needs to return periodically to keep the loop alive
    except Exception as e:
        print(f"  [NODE] connection error: {e}")
    finally:
        if node_id:
            with _connected_nodes_lock:
                connected_nodes.pop(node_id, None)
            print(f"  [NODE] {node_id} disconnected")
            try:
                from .app import _sse_broadcast
                _sse_broadcast('node', {'node_id': node_id, 'online': False})
            except Exception:
                pass


_ensure_node_workers()

