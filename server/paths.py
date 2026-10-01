# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
#
# Every on-disk data path in one place.
#
# This directory used to be called `cache/`, which was a lie in both directions:
# most of it (lyrics, provider snapshots, translations, the Cubey token pool,
# manual renames) is durable state the server is the source of truth for, not
# something that can be thrown away and refetched. And the name was actively
# dangerous, because "cache" is exactly the word that makes you skip a version
# gate: a parser fix lands, every entry on disk still carries the old `v`, and
# `get_cached` keeps serving the pre-fix text forever. That is how the sub-word
# span bug (`19c5d2c`) kept rendering "Through the sha dow s of de s pair"
# long after the parser was fixed.
#
# So: one constant, referenced by name everywhere. The next rename is one edit
# here plus one migration, not fifteen greps. Import this module instead of
# writing a literal path -- a literal is how the last rename drifted.
import os

# Root of all persistent server state, relative to the working directory the
# server is started from (repo root / deploy dir).
DATA_DIR = 'database'

LYRICS_DIR = os.path.join(DATA_DIR, 'lyrics')
TRANSLATE_DIR = os.path.join(DATA_DIR, 'translate')
CANDIDATES_DIR = os.path.join(DATA_DIR, 'candidates')
JWT_FILE = os.path.join(DATA_DIR, 'jwt.json')
USAGE_STATS_FILE = os.path.join(DATA_DIR, 'usage_stats.json')
LATENCY_STATS_FILE = os.path.join(DATA_DIR, 'latency_stats.json')
BADGE_STATS_FILE = os.path.join(DATA_DIR, 'badge_stats.json')
RENAME_FILE = os.path.join(DATA_DIR, 'rename.json')
PROVIDER_FILE = os.path.join(DATA_DIR, 'provider.json')
UNLYRICED_FILE = os.path.join(DATA_DIR, 'library_unlyriced.jsonl')


def ensure_data_dir():
    """Create DATA_DIR. Idempotent, safe to call from any entry point."""
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
    except Exception:
        pass


# State files worth carrying across the rename. Deliberately NOT lyrics,
# candidates or translations: those hold the pre-fix parsed text, and moving
# them is exactly the bug this rename was asked to kill. jwt.json is the one
# that would actually hurt to lose -- without it every restart empties the
# Cubey pool and the provider goes dark until devices re-contribute.
_MIGRATE_FILES = (
    'jwt.json',
    'usage_stats.json',
    'badge_stats.json',
    'rename.json',
    'provider.json',
    'library_unlyriced.jsonl',
    # Latency percentiles. Purely derived history, so losing it is harmless --
    # it is listed for symmetry with usage_stats.json, not because the rings
    # cannot be rebuilt (they refill from the next fetch).
    'latency_stats.json',
)


def migrate_legacy_cache_dir():
    """One-shot: move the old cache/ state files into database/.

    Runs on every start and is a no-op once cache/ is gone or the destination
    file already exists, so it is safe to leave in place. Returns the list of
    files moved. Never raises -- a failed migration must not stop the server,
    it just means that file rebuilds itself empty.
    """
    legacy = 'cache'
    if not os.path.isdir(legacy):
        return []
    moved = []
    for name in _MIGRATE_FILES:
        src = os.path.join(legacy, name)
        dst = os.path.join(DATA_DIR, name)
        if not os.path.isfile(src) or os.path.exists(dst):
            continue
        try:
            ensure_data_dir()
            os.replace(src, dst)
            moved.append(name)
        except Exception:
            continue
    if moved:
        print(f"[PATHS] moved {len(moved)} state file(s) from {legacy}/ to {DATA_DIR}/: "
              f"{', '.join(moved)}")
        print(f"[PATHS] {legacy}/lyrics, {legacy}/candidates and {legacy}/translate were "
              f"left behind on purpose -- they hold pre-fix parsed text. Delete them "
              f"when you no longer need the old data.")
    return moved
