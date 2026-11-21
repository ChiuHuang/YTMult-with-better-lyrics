"""Rebuild parsed lyrics from archived raw sources.

Usage (from the repo root):

    .venv\\Scripts\\python -m server.rebuild_raw            # every archived song
    .venv\\Scripts\\python -m server.rebuild_raw <video_id>  # one song
    .venv\\Scripts\\python -m server.rebuild_raw <video_id> zh-Hans

Nothing here talks to a provider: it re-parses the LZMA text with the
parsers in THIS build and writes the best result to the lyrics cache. Run it
after a parser fix instead of waiting for every song to be re-fetched.
"""
import os
import sys

from .paths import RAW_DIR, ensure_data_dir
from . import raw_archive


def main(argv=None):
    argv = list(argv if argv is not None else sys.argv[1:])
    lang = argv[1] if len(argv) > 1 else 'zh-TW'
    ensure_data_dir()
    if argv:
        vids = [argv[0]]
    else:
        vids = [name[:-5] for name in sorted(os.listdir(RAW_DIR))
                if name.endswith('.lzma')] if os.path.isdir(RAW_DIR) else []
    done = 0
    for vid in vids:
        payload = raw_archive.rebuild_cache(vid, lang)
        if payload:
            done += 1
    print(f"[RAW] rebuilt {done}/{len(vids)} song(s) into lang={lang}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
