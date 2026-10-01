# Cubey reachability sweep: which egress can actually talk to Cubey?
#
# Run this ON THE SERVER HOST:
#     python tools/cubey_probe.py --token '<jwt>'
#     python tools/cubey_probe.py            # no token: shows the bare-403 shape
#
# Why it exists: on 2026-10-01 the pool was retiring JWTs after 1-3 requests and
# the operator asked whether the provider had started rejecting us. The log said
# no direct request had ever 401/403'd, every strike came from the background
# probe, and the same POST answered 403 through one node and 200 through
# another. So the question is not "is the token alive" but "WHICH EGRESS can
# reach Cubey" -- and that cannot be answered from the server's own IP, which is
# why this walks the paths in the order that matters: direct, then every
# connected node, then the CF proxy.
#
# For each path it prints the exit IP and then the real Cubey POST, with the
# response body. The body is the whole point: a bare 403 with an empty body is
# exactly what an UNAUTHENTICATED request gets, so "403" on its own never means
# "this token is dead".
#
# It imports server.nodes for the live node list, which imports server.app --
# that creates the Flask app object and installs the LogTee, so this appends to
# logs/server.log. It does NOT start the web server, the JWT checker, the
# re-race loop or any provider work.
#
# Never prints a token. Only its sha256 prefix, which is how the pool identifies
# it anyway.
import argparse
import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

CUBEY_URL = 'https://lyrics.api.dacubeking.com/v2/lyrics'
IP_ECHO = 'https://api.ipify.org'
CF_PROXY = os.environ.get('YTMU_EGRESS_PROXY', 'https://proxy.chiuhuang.dev').rstrip('/')
BODY_CHARS = 300


def form(token):
    return {'videoId': 'dQw4w9WgXcQ',
            'song': 'Never Gonna Give You Up',
            'artist': 'Rick Astley',
            'duration': '212',
            'alwaysFetchMetadata': 'false',
            **({'token': token} if token else {})}


def token_label(token):
    if not token:
        return 'no token (expect a bare 403 -- that is the baseline, not a failure)'
    return 'token sha256:' + hashlib.sha256(token.encode()).hexdigest()[:12]


def _clip(text):
    text = (text or '').replace('\r', '')
    flat = ' '.join(text.split())
    if len(flat) > BODY_CHARS:
        flat = flat[:BODY_CHARS] + '...'
    return flat or '<empty body>'


def _status_line(prefix, status, text):
    body = _clip(text)
    # The body is what tells 403-with-no-reason from 403-with-a-reason, so it is
    # always printed, never summarised away.
    print(f'   {prefix} HTTP {status}')
    print(f'   {prefix} body: {body}')


def probe_direct(token):
    import requests
    print('\n== 1. server (this host, direct) ==')
    try:
        r = requests.get(IP_ECHO, timeout=15)
        print(f'   exit IP: {r.text.strip()}')
    except Exception as e:
        print(f'   exit IP: <failed: {e}>')
    try:
        r = requests.post(CUBEY_URL, data=form(token), timeout=25)
        _status_line('cubey', r.status_code, r.text)
    except Exception as e:
        print(f'   cubey: <failed: {e}>')


def probe_node(node_id, label, token):
    """Through one node, using the SAME relay the providers use. The exit IP is
    fetched first: the node's address is the variable under test."""
    from server.nodes import relay_http_request
    print(f'\n== node {label} ({node_id}) ==')
    relay_ip = relay_http_request(node_id, 'GET', IP_ECHO, timeout=15)
    if relay_ip is None:
        print('   exit IP: <relay failed -- the node could not be asked>')
    else:
        status, text = relay_ip
        print(f'   exit IP: {text.strip() if status == 200 else f"<HTTP {status}>"}')
    rel = relay_http_request(node_id, 'POST', CUBEY_URL, data=form(token), timeout=25)
    if rel is None:
        print('   cubey: <relay failed>')
        return
    status, text = rel
    _status_line('cubey', status, text)


def probe_cf_proxy(token):
    import requests
    print(f'\n== last. CF proxy ({CF_PROXY}) ==')
    target = f'{CF_PROXY}/{IP_ECHO}'
    try:
        r = requests.get(target, timeout=25)
        print(f'   exit IP: {r.text.strip() if r.status_code == 200 else f"<HTTP {r.status_code}>"}')
    except Exception as e:
        print(f'   exit IP: <failed: {e}>')
    try:
        r = requests.post(f'{CF_PROXY}/{CUBEY_URL}', data=form(token), timeout=30)
        _status_line('cubey', r.status_code, r.text)
    except Exception as e:
        print(f'   cubey: <failed: {e}>')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--token', default='', help='a JWT to test with (omit for the bare-403 baseline)')
    ap.add_argument('--skip-nodes', action='store_true')
    ap.add_argument('--skip-proxy', action='store_true')
    args = ap.parse_args()

    print(f'Cubey reachability sweep  {time.strftime("%Y-%m-%d %H:%M:%S")}')
    print(f'probe: {token_label(args.token)}')

    probe_direct(args.token)

    if not args.skip_nodes:
        from server.nodes import connected_nodes, _connected_nodes_lock
        with _connected_nodes_lock:
            nodes = list(connected_nodes.items())
        print(f'\n== connected nodes: {len(nodes)} ==')
        if not nodes:
            print('   (none -- connect the nodes first, this half of the sweep is the point)')
        for node_id, entry in nodes:
            label = (entry or {}).get('label') or 'unlabelled'
            probe_node(node_id, label, args.token)

    if not args.skip_proxy:
        probe_cf_proxy(args.token)

    print('\n--- how to read this ---')
    print('  403 + EMPTY body  == what an unauthenticated request gets. On a path')
    print('                      that 200s for someone else, that is the PATH being')
    print('                      refused, not the token. Never retire a token on it.')
    print('  403 + a message    == read the message before deciding anything.')
    print('  200                == this path can reach Cubey with this token.')


if __name__ == '__main__':
    main()