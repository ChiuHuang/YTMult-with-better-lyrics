# Egress proxy: route provider requests through proxy.chiuhuang.dev.
#
# MEASURED, not assumed (the three questions this file used to say were open):
#   1. Protocol: `{BASE}/{full-url}`. Confirmed by the repo's own use of it to
#      mirror the IPA.
#   2. Auth: none. A bare proxied GET/POST works.
#   3. It forwards what a provider actually needs: a POST form body arrives
#      intact at the target (checked with httpbin) and custom headers are
#      passed through. That matters -- Cubey is a POST with a form body and an
#      SSE response, and a proxy that dropped either would break it.
#   Measured on 2026-10-01: 12/12 requests to Cubey through the proxy with a
#   real token answered HTTP 200 with the SSE stream intact, and 120 samples
#   through it produced 41 distinct IPv4 egress addresses spread over 10 /16s.
#
# Why: a single small origin IP that every request leaves from is one address to
# block. An anycast edge pool spreads the same traffic over an enormous set, and
# a provider cannot blanket-block a range that carries a large share of the
# internet -- it would take its own customers down with it.
#
# SCOPE IS DELIBERATE. Only Cubey goes through this by default, because Cubey is
# the only provider that refuses us (LRCLib, Unison, boidu and AMLL answer
# normally from the origin, and putting a hop in front of a working provider
# buys nothing and risks a new failure mode). `egress.scope = all` widens it.
#
# The NODE path is deliberately NOT wrapped: a node relay already egresses from
# that node's own address, which is the whole point of having nodes. Wrapping it
# would replace a diverse IP with the proxy's, which is the opposite of what this
# file is for.
import os

# Kept as a module constant so the default lives in one place and a settings
# read that fails still has something to fall back to.
DEFAULT_PROXY_URL = 'https://proxy.chiuhuang.dev'


def _setting(key, dflt=''):
    """One setting, read live so a dashboard change takes effect without a
    restart. Never raises -- a proxy setting must not break a fetch."""
    try:
        from .app_settings import get_all
        v = get_all().get(key, dflt)
        return v if isinstance(v, str) else dflt
    except Exception:
        return dflt


def _flag(key, dflt):
    try:
        from .app_settings import flag
        return flag(key, dflt)
    except Exception:
        return dflt


def proxy_url():
    """The configured proxy base, or '' for none. Falls back to the
    YTMU_EGRESS_PROXY env var so a deployment can set it without touching
    config/app_settings.json."""
    base = _setting('egress.proxy_url', DEFAULT_PROXY_URL).strip()
    if not base or base.lower() == 'off':
        return ''
    env = (os.environ.get('YTMU_EGRESS_PROXY') or '').strip()
    if env:
        base = env
    return base.rstrip('/')


def scope():
    """'cubey' (default) or 'all'. Anything else reads as the safe default."""
    s = _setting('egress.scope', 'cubey').strip().lower()
    return s if s in ('cubey', 'all') else 'cubey'


def egress_enabled():
    return bool(proxy_url()) and _flag('egress.enabled', True)


def in_scope(host):
    """Is this provider routed through the proxy?"""
    if not egress_enabled():
        return False
    s = scope()
    if s == 'all':
        return True
    return 'dacubeking' in (host or '').lower()


def egress_url(url):
    """Return the URL a provider should request.

    Passthrough when the proxy is off or this provider is out of scope. Only
    http(s) is wrapped, and an already-proxied URL is returned untouched -- a
    double wrap would produce `base/https://base/https://...` and fail in a way
    that reads like the provider is down.
    """
    try:
        if not url or not url.startswith(('http://', 'https://')):
            return url
        base = proxy_url()
        if not base:
            return url
        if url.startswith(base + '/'):
            return url
        host = url.split('://', 1)[1].split('/', 1)[0]
        if not in_scope(host):
            return url
        return f'{base}/{url}'
    except Exception as e:
        print(f"  [EGRESS] [WARN] passthrough: {e}")
        return url


def describe():
    """What the dashboard shows on the Settings page."""
    return {
        'enabled': _flag('egress.enabled', True),
        'proxy_url': proxy_url(),
        'scope': scope(),
        'applies_to': 'Cubey only' if scope() == 'cubey' else 'every provider',
        'note': ('Node relays are NOT proxied -- a node already egresses from its '
                 'own address, which is the point of having nodes.'),
    }