# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
"""YTMusicUltimate lyrics server package (split from proxy_server.py)."""
from .app import app, sock  # noqa: F401
from . import nodes  # noqa: F401  (registers /ws/node)
from . import logging_util  # noqa: F401
from . import self_update  # noqa: F401
from . import parsers_lrc  # noqa: F401
from . import parsers_qrc  # noqa: F401
from . import parsers_ttml  # noqa: F401
from . import providers_lrclib  # noqa: F401
from . import providers_yt  # noqa: F401
from . import providers_cubey  # noqa: F401
from . import providers_unison  # noqa: F401
from . import translate  # noqa: F401
from . import metadata  # noqa: F401
from . import cache  # noqa: F401
from . import jwt_pool  # noqa: F401  (subscribes the cubey token pool)
jwt_pool.start_jwt_pool()
from . import pipeline  # noqa: F401
from . import race  # noqa: F401
from . import routes_lyrics  # noqa: F401
from . import playlist  # noqa: F401
from . import routes_stream  # noqa: F401
from . import routes_admin  # noqa: F401
from . import routes_misc  # noqa: F401

def main():
    from .app import SERVER_INSTANCE_ID, SERVER_START_TS, SERVER_LOG_FILE, CRASH_LOG_FILE
    from .cache import clear_not_found_caches
    from .logging_util import _log_crash
    print('=' * 60)
    print('[MUSIC] YTMusic Ultimate - Lyrics API Server')
    print(f'Instance: {SERVER_INSTANCE_ID} started {SERVER_START_TS}')
    print('Server: http://0.0.0.0:20016')
    print(f'Logs: {SERVER_LOG_FILE} | Crash: {CRASH_LOG_FILE}')
    print('=' * 60)
    clear_not_found_caches()
    try:
        app.run(host='0.0.0.0', port=20016, debug=False, use_reloader=False, threaded=True)
    except Exception as e:
        _log_crash(type(e), e, e.__traceback__)
        raise
