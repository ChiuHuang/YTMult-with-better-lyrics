# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Optional egress proxy (e.g. a Cloudflare Worker) for providers that
# rate-limit the server's own IP.
#
# TODO(egress): wire up proxy.chiuhuang.dev -- open questions before this
#   does anything:
#   1. Protocol: does the worker expect `{BASE}/{full-url}`, `?url=`, or a
#      real HTTP forward-proxy (CONNECT)? One wrong guess breaks every
#      provider, so nothing routes through it until confirmed.
#   2. Auth: header/query token? Which one?
#   3. Scope: all providers or only the rate-limited ones (Cubey? LRCLib?)?
# Set YTMU_EGRESS_PROXY to enable once 1-3 are answered; until then
# egress_url() is a documented passthrough.
import os

EGRESS_PROXY = os.environ.get('YTMU_EGRESS_PROXY', '').rstrip('/')


def egress_url(url):
    """Return the URL providers should request. Passthrough until the
    TODO(egress) above is resolved and YTMU_EGRESS_PROXY is set."""
    # TODO(egress): implement the confirmed worker pattern here, e.g.
    #   return f"{EGRESS_PROXY}/{url}"  (ONLY if that is the real pattern)
    return url


def egress_enabled():
    return bool(EGRESS_PROXY)
