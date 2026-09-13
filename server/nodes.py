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
from .app import sock

# ============================================================
# Node mesh (WebSocket worker nodes)
#
# Lets you run node.py on other machines/IPs. They connect back here over a
# persistent, authenticated WebSocket. Used for two things:
#   1. Cache sharing: before doing a fresh fetch, every connected node gets
#      asked "do you already have this cached?" so work already done
#      elsewhere doesn't get redone.
#   2. IP diversity: the Cubey/Musixmatch lookup (the one most exposed to
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
    return reply['status'], reply.get('text', '')


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
        record['last_seen'] = datetime.now().isoformat()
        nodes[node_id] = record
        _save_nodes(nodes)

        with _connected_nodes_lock:
            connected_nodes[node_id] = {'ws': ws, 'connected_ts': time_module.time(), 'label': record.get('label', node_id)}
        print(f"  [NODE] {node_id} ({record.get('label', '')}) connected")
        ws.send(json.dumps({'type': 'hello_ack', 'ok': True}))

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
            if mtype in ('cache_check_result', 'cache_data', 'task_result') and request_id:
                with _pending_lock:
                    pending = _pending_node_requests.get(request_id)
                if pending:
                    pending['result'] = msg
                    pending['event'].set()
            # any other message type (e.g. a bare ping) needs no action --
            # receive() just needs to return periodically to keep the loop alive
    except Exception as e:
        print(f"  [NODE] connection error: {e}")
    finally:
        if node_id:
            with _connected_nodes_lock:
                connected_nodes.pop(node_id, None)
            print(f"  [NODE] {node_id} disconnected")

