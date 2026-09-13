# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
"""Thin shim -- the server now lives in server/. Kept so existing
`python proxy_server.py`, imports, and self-update checks keep working."""
from server import app, sock  # noqa: F401
from server import nodes, logging_util, self_update  # noqa: F401
from server import parsers_lrc, parsers_qrc, parsers_ttml  # noqa: F401
from server import providers_lrclib, providers_yt, providers_cubey, providers_unison  # noqa: F401
from server import translate, metadata, cache, pipeline, race  # noqa: F401
from server import routes_lyrics, playlist, routes_stream, routes_admin, routes_misc  # noqa: F401
from server.app import SERVER_INSTANCE_ID, SERVER_START_TS, SERVER_LOG_FILE, CRASH_LOG_FILE  # noqa: F401
from server.cache import clear_not_found_caches, get_cached, set_cached  # noqa: F401
from server.pipeline import fetch_all_lyrics, fetch_fast_lyrics  # noqa: F401
from server.logging_util import _log_crash  # noqa: F401

if __name__ == '__main__':
    print("=" * 60)
    print("[MUSIC] YTMusic Ultimate - Lyrics API Server")
    print(f"Instance: {SERVER_INSTANCE_ID} started {SERVER_START_TS}")
    print("=" * 60)
    print("Providers (priority order):")
    print("  0. Cubey API  (Musixmatch/QQ/KuGou/NetEase, requires JWT)")
    print("  1. LRCLIB     (synced + plain, free)")
    print("  2. Unison     (community, free)")
    print("  3. YT Music   (plain, via ytmusicapi)")
    print("Translation: Cohere Command A Translate")
    print("Auth: Cloudflare Turnstile via in-app WKWebView")
    print("=" * 60)
    print("Server: http://0.0.0.0:20016")
    print(f"Logs: {SERVER_LOG_FILE} | Crash: {CRASH_LOG_FILE}")
    print("=" * 60)
    # Log startup to files
    try:
        with open(SERVER_LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(f"\n{'='*60}\n[{SERVER_START_TS}] START instance {SERVER_INSTANCE_ID}\n{'='*60}\n")
    except: pass

    clear_not_found_caches()
    try:
        app.run(host='0.0.0.0', port=20016, debug=False, use_reloader=False, threaded=True)
    except Exception as e:
        _log_crash(type(e), e, e.__traceback__)
        raise

