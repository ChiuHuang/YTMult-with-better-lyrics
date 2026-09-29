# Key-authenticated JWT push -- the browser path.
#
# Why this exists: the admin JWT endpoints need the dashboard session cookie,
# and a page on another origin cannot present one. Flask writes that cookie
# with no SameSite attribute, so browsers treat it as Lax and a cross-site POST
# (a userscript, a fetch from the challenge page) arrives without it. This
# module is the alternative: a caller holding the push key adds a token with one
# POST and no session at all.
#
# The key is 32 random bytes of hex, created on first use and kept in
# config/admin_config.json -- the same gitignored file as the password hash.
# The trust level is identical to a node key: a node can already contribute
# tokens over the websocket (nodes.py ws jwt), so this grants nothing new to a
# caller that has one. It is deliberately NOT in app_settings.json, whose read
# endpoint is public.
#
# The HTTP side is in routes_admin.py (`/api/jwt/push`). It sends no CORS
# headers and answers no preflight, so a random web page cannot make a browser
# send the key; only a userscript manager's privileged request can.
import hmac
import secrets

from .app import _admin_cfg, _save_admin_config
from .jwt_pool import contribute_jwt

KEY_FIELD = 'jwt_push_key'
KEY_BYTES = 32


def ensure_key():
    """The push key, generated and persisted on first call."""
    key = _admin_cfg.get(KEY_FIELD)
    if not isinstance(key, str) or len(key) < 32:
        key = secrets.token_hex(KEY_BYTES)
        _admin_cfg[KEY_FIELD] = key
        try:
            _save_admin_config(_admin_cfg)
        except Exception as e:
            print(f'  [PUSH] could not persist the push key: {e}')
    return key


def key_ok(candidate):
    """Constant-time compare. A missing or short candidate still goes through
    compare_digest so a wrong key costs the same as an absent one. Bytes, not
    str: compare_digest raises TypeError on non-ASCII str, and a header can
    carry anything."""
    if not isinstance(candidate, str) or not candidate.strip():
        return False
    candidate = candidate.strip()
    try:
        expected = str(ensure_key())
    except Exception:
        return False
    try:
        return hmac.compare_digest(candidate.encode('utf-8'), expected.encode('utf-8'))
    except Exception:
        return False


def push(key, token, source='push'):
    """Verify the key, then contribute the token. Returns contribute_jwt's
    shape, with 'auth': False when the key was wrong."""
    if not key_ok(key):
        return {'ok': False, 'auth': False, 'error': 'bad key'}
    if not isinstance(token, str) or len(token.strip()) < 20:
        return {'ok': False, 'error': 'missing or malformed token'}
    source = (str(source).strip() or 'push')[:32]
    res = contribute_jwt(token.strip(), node_id=source)
    if res.get('ok'):
        print(f"  [PUSH] accepted {res.get('id')} source={source} pool={res.get('num_pool')}")
    return res
