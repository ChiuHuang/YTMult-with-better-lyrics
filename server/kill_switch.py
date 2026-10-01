# Targeted kill switch: turn a feature off for a RANGE OF BUILDS instead of
# on every device at once.
#
# Why this exists: `ui.liquid_glass` (server/app_settings.py) is one flat bool
# in the public remote-config map, so flipping it off disables every Liquid
# Glass surface on EVERY device. There is no way to say "build-42 renders the
# player wrong -- take the glass away from the people on build-42 and leave
# everyone else alone", which is the only shape a kill switch is actually useful
# in once there are more than one build in the wild. This module is the missing
# half: a list of TARGETS, each a build selector plus an action, folded into
# the flat map at serve time.
#
# The decision is server-side on purpose. The device sends the sha it was
# compiled with (TWEAK_GIT_COMMIT, baked by the Makefile) as a query parameter
# and reads a finished map back; it never evaluates a selector. That matters
# because the interesting selectors need the repository -- a `build-41` tag, or
# "everything between A and B" -- and the device has no clone of it. One
# implementation, in one place, that can also answer "how many devices are even
# on build-41", which is the question you have to answer before pressing the
# button.
#
# Selector shapes, and why there are three:
#   sha              one build, by (possibly short) commit prefix
#   tag              one release, by tag name -- resolved through git, because
#                    the device only ever learns its sha, never its build-N tag
#   from_sha/to_sha  a contiguous window of first-parent history, i.e. "every
#                    build from A to B". The usual case: a regression lands, a
#                    few commits later somebody finds it, so the bad window is
#                    a range and not a single sha.
# No selector at all is the legacy blanket and stays supported: it is the one
# shape that needs no repository, and the one an operator reaches for when the
# damage is not build-specific.
#
# Storage: config/kill_targets.json (gitignored, like every other operator
# file). The census lives in database/kill_census.json because it is derived
# state that refills itself on the next poll.
#
# Nothing in here raises. It runs on the public settings endpoint, and a metrics
# or history failure must degrade to "no targets matched", never to a 500 on
# every device's config fetch.
import hashlib
import json
import os
import re
import subprocess
import threading
import time as time_module

from .paths import DATA_DIR, ensure_data_dir

_TARGETS_PATH = os.path.join('config', 'kill_targets.json')
_CENSUS_PATH = os.path.join(DATA_DIR, 'kill_census.json')

_LOCK = threading.Lock()

# A device's TWEAK_GIT_COMMIT is `git rev-parse --short=12` (Makefile), so 12
# hex chars is the full width we ever see. Accepting 4..40 lets an operator
# paste a short prefix off a terminal.
_SHA_RE = re.compile(r'^[0-9a-f]{4,40}$')
_TAG_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
# The sentinel the Makefile bakes when git was unavailable. A real install
# never reports it, so it is its own target shape rather than a sha.
UNKNOWN_SHA = 'unknown'

# How many first-parent commits back the "from A to B" range is evaluated
# against. A regression window is days, not weeks, so 400 is generous; the cap
# is here because the whole history is parsed into RAM on a timer.
_HISTORY_N = 400
# git is only asked once per this many seconds. Every device hits this module on
# its config poll, and a subprocess per request is not an option.
_GIT_TTL_S = 300
# How long a build counts as "a device is on it". A device that stopped
# reporting must stop inflating the number you are about to act on.
_CENSUS_ACTIVE_S = 30 * 24 * 3600
_MAX_SHAS = 200
_MAX_IPS_PER_SHA = 400

# Actions. Each one resolves to exactly ONE remote key, so what a target does
# is answerable by reading a single boolean, and the dashboard can print the
# exact key list for a preview instead of describing it in prose.
SCOPES = ('lg', 'tweak', 'surface')

# Scope -> the remote key it turns off. `lg` is the existing blanket key;
# `tweak` is the glass stack's own master (see YTMULGTweakEnabled); `surface`
# is resolved from the target's `key` against the schema's device keys.
SCOPE_KEYS = {
    'lg': 'ui.liquid_glass',
    'tweak': 'ui.tweak',
}


def _blank():
    return {'shas': {}}


def _load_targets():
    try:
        with open(_TARGETS_PATH, 'r', encoding='utf-8') as f:
            d = json.load(f)
        items = d.get('targets') if isinstance(d, dict) else None
        return [t for t in items if isinstance(t, dict)] if isinstance(items, list) else []
    except Exception:
        return []


def _save_targets(targets):
    ensure_data_dir()
    os.makedirs(os.path.dirname(_TARGETS_PATH) or '.', exist_ok=True)
    tmp = _TARGETS_PATH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump({'targets': targets}, f, ensure_ascii=False, indent=2)
    os.replace(tmp, _TARGETS_PATH)


def _mutate_targets(mutator):
    """One lock, a fresh read, an atomic write. Never hand-edit the file: every
    writer goes through here or two requests interleave and lose a target."""
    with _LOCK:
        targets = _load_targets()
        result = mutator(targets)
        _save_targets(targets)
        return result


# --------------------------------------------------------------------------
# Repository facts (tags, history, ordering). Cached, and every failure is an
# empty answer rather than an exception -- a deploy with no .git next to it must
# still serve a kill target by raw sha.
# --------------------------------------------------------------------------
_GIT_CACHE = {'at': 0.0, 'history': None, 'tags': None}


def _git(*args):
    from .self_update import _git_root
    root = _git_root()
    if not root:
        return None
    try:
        r = subprocess.run(['git'] + list(args), cwd=root, capture_output=True,
                           text=True, timeout=15)
        if r.returncode != 0:
            return None
        # NOT .strip(): the tag listing is parsed on a literal NUL separator, and
        # a stripped leading byte is a row that silently loses a field.
        return r.stdout or ''
    except Exception:
        return None


def _load_git_facts():
    """{history: [{sha, ts, subject}], tags: [{tag, sha}]}. Oldest-first for
    the history: the range math is index arithmetic and "index" only means
    something against one direction."""
    now = time_module.time()
    if _GIT_CACHE['history'] is not None and now - _GIT_CACHE['at'] < _GIT_TTL_S:
        return _GIT_CACHE
    history = []
    raw = _git('log', '--first-parent', '-n', str(_HISTORY_N),
               '--format=%H%x1f%ct%x1f%s')
    if raw:
        for line in reversed(raw.split('\n')):
            parts = line.split('\x1f')
            if len(parts) < 3 or not parts[0]:
                continue
            history.append({'sha': parts[0].lower(),
                            'short': parts[0].lower()[:12],
                            'ts': _int(parts[1]),
                            'subject': parts[2][:140]})
    tags = []
    # Two things are load-bearing here and both were found by running against
    # the real repo, not by reading the code:
    #
    # 1. The separator is a literal NUL byte, NOT %x1f. `git for-each-ref`
    #    does not expand %xNN the way `git log --format` does -- it emits the
    #    six characters verbatim, so a %x1f format parses as one field and the
    #    whole tag list silently came back empty. `%00` IS expanded here (and is
    #    the one byte that cannot occur in a refname).
    # 2. objecttype comes along for the ride because peeling has to be
    #    CONDITIONAL. A build-* tag is lightweight (it points straight at a
    #    commit) and `git rev-list -n 1 <tag>` agrees, but a repo with ~190 tags
    #    means ~190 subprocesses on the first call after the TTL, inside an
    #    admin request. `%(objectname)` already IS the commit for a lightweight
    #    tag, so only an annotated `tag` object needs the extra call.
    raw = _git('for-each-ref', '--sort=-creatordate',
               '--format=%(refname:short)%00%(objecttype)%00%(objectname)', 'refs/tags')
    if raw:
        for line in raw.split('\n'):
            parts = line.split('\x00')
            if len(parts) != 3 or not parts[0]:
                continue
            name = parts[0].strip()
            sha = parts[2].strip().lower()
            if parts[1] == 'tag':
                peeled = _git('rev-list', '-n', '1', name)
                if peeled:
                    sha = peeled.lower()
            if re.match(r'^[0-9a-f]{40}$', sha):
                tags.append({'tag': name, 'sha': sha, 'short': sha[:12]})
    _GIT_CACHE.update({'at': now, 'history': history, 'tags': tags})
    return _GIT_CACHE


def _int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _norm_sha(s):
    s = (s or '').strip().lower()
    return s if _SHA_RE.match(s) else ''


def _history_index(sha):
    """Position of `sha` in the oldest-first first-parent history, or None.

    Prefix match on purpose: the device only ever reports 12 chars, and an
    operator pastes whatever the terminal gave them."""
    if not sha:
        return None
    for i, h in enumerate(_load_git_facts()['history']):
        if h['sha'].startswith(sha) or sha.startswith(h['short']):
            return i
    return None


def _tag_sha(tag):
    for t in _load_git_facts()['tags']:
        if t['tag'].lower() == (tag or '').lower():
            return t['sha']
    # A tag the cached listing does not have (force-moved, or created since the
    # last refresh) still resolves, it just costs a subprocess.
    out = _git('rev-list', '-n', '1', tag)
    return out.lower() if out and re.match(r'^[0-9a-f]{40}$', out.strip().lower()) else None


def resolve_ref(ref):
    """Full sha for a tag name or a commit prefix, or None."""
    ref = (ref or '').strip()
    if not ref:
        return None
    sha = _norm_sha(ref)
    if sha:
        for h in _load_git_facts()['history']:
            if h['sha'].startswith(sha):
                return h['sha']
        out = _git('rev-parse', '--verify', '--quiet', sha + '^{commit}')
        return out.lower() if out else None
    return _tag_sha(ref)


# --------------------------------------------------------------------------
# Matching
# --------------------------------------------------------------------------
def _matches(target, sha=''):
    """True when `target`'s selector covers the build `sha`.

    `sha` is the device's own TWEAK_GIT_COMMIT (lowercased) or None. None means
    "this device did not tell us", which only a blanket target is allowed to
    match -- see resolve()."""
    if not sha:
        # The selector-less blanket is the only shape with a defined answer for
        # a client that cannot be identified. A build-scoped target does NOT
        # match here: guessing would either kill everyone or no one.
        return not (target.get('sha') or target.get('tag')
                    or target.get('from_sha') or target.get('to_sha'))
    t_sha = target.get('sha') or ''
    # The sentinel is a WORD, not a hex prefix, so it must be compared exactly.
    # Prefix-matching it would let a target for the sha "unk" (or any other
    # stray prefix) silently capture every device whose build git could not
    # resolve -- i.e. the one population a targeted kill must never guess at.
    if sha == UNKNOWN_SHA:
        return t_sha == UNKNOWN_SHA
    if t_sha:
        return bool(t_sha) and sha.startswith(t_sha)
    t_tag = target.get('tag') or ''
    if t_tag:
        full = _tag_sha(t_tag)
        if not full:
            return False           # unresolved tag kills nobody; the UI says so
        return full.startswith(sha) or sha.startswith(full[:len(sha)])
    frm = target.get('from_sha') or ''
    to = target.get('to_sha') or ''
    if frm or to:
        history = _load_git_facts()['history']
        i_me = _history_index(sha)
        if i_me is None:
            return False           # not in the window this range is read from
        # Both endpoints are optional and open-ended on purpose: "from A" means
        # A and everything after it ("it broke somewhere after here"), "to B"
        # means everything up to B. Only the endpoints that WERE given have to
        # resolve, and one that does not kills nobody rather than everything.
        if frm:
            i_frm = _history_index(frm)
            if i_frm is None:
                return False
        else:
            i_frm = 0
        if to:
            i_to = _history_index(to)
            if i_to is None:
                return False
        else:
            i_to = len(history) - 1
        if i_frm > i_to:
            i_frm, i_to = i_to, i_frm   # A..B or B..A, both mean "between"
        return i_frm <= i_me <= i_to
    return True                    # blanket


def keys_for_target(target):
    """The exact remote keys this target turns off, as a list."""
    scope = target.get('scope') or 'lg'
    if scope == 'tweak':
        return [SCOPE_KEYS['tweak']]
    if scope == 'surface':
        key = target.get('key') or ''
        return ['ui.' + key] if key else []
    return [SCOPE_KEYS['lg']]


def resolve(settings, sha, version=None):
    """Fold every matching target into a COPY of the flat settings map.

    Returns (settings, hits) where hits is the list of matched target ids, so
    the endpoint can echo back which targets fired for a device and the device
    can log it. `sha` is the raw query value; a value that is not a plausible
    sha is treated as "did not tell us" rather than trusted."""
    base = dict(settings or {})
    dev = (sha or '').strip().lower()
    if dev != UNKNOWN_SHA:
        dev = dev if _norm_sha(dev) else ''
    hits = []
    for t in _load_targets():
        try:
            if not _matches(t, dev):
                continue
            for k in keys_for_target(t):
                base[k] = False
            hits.append(t.get('id') or '')
        except Exception as e:
            print(f"[KILL] [WARN] target {t.get('id')} failed: {e}")
    return base, hits


def revision(settings):
    """Short digest of an effective map, so a device can poll with `?rev=` and
    get a no-op answer instead of a resend plus an NSUserDefaults write."""
    try:
        canon = json.dumps(settings, sort_keys=True, separators=(',', ':'))
        return hashlib.sha256(canon.encode('utf-8')).hexdigest()[:12]
    except Exception:
        return ''


# --------------------------------------------------------------------------
# Census: which builds devices are actually on.
#
# Recorded from the settings poll the device already makes, so it costs the
# device nothing extra. Keyed by the sha the device reported and de-duplicated
# by client ip, the same way usage_stats counts distinct users -- two requests
# from one phone must read as one device, and one phone behind carrier NAT
# cannot be told apart from its neighbours anyway.
# --------------------------------------------------------------------------
def _load_census():
    try:
        with open(_CENSUS_PATH, 'r', encoding='utf-8') as f:
            d = json.load(f)
        if not isinstance(d, dict) or not isinstance(d.get('shas'), dict):
            return _blank()
        return d
    except Exception:
        return _blank()


def _save_census(d):
    ensure_data_dir()
    tmp = _CENSUS_PATH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, _CENSUS_PATH)


def record_poll(sha, version, client_ip):
    """One device reporting which build it is. Never raises."""
    sha = (sha or '').strip().lower()
    if not sha:
        return
    # The device sends exactly 12 (Makefile --short=12). Truncate anything
    # longer rather than reject it: this file is derived state and a longer
    # prefix from a test client must not be able to grow it unbounded.
    sha = sha[:12]
    now = time_module.time()
    try:
        with _LOCK:
            d = _load_census()
            shas = d['shas']
            row = shas.get(sha)
            if not isinstance(row, dict):
                row = {'ips': {}, 'first': now}
                shas[sha] = row
            row['last'] = now
            if version:
                row['v'] = str(version)[:24]
            ips = row.setdefault('ips', {})
            if client_ip:
                ips[client_ip] = now
            if len(ips) > _MAX_IPS_PER_SHA:
                for k in sorted(ips, key=ips.get)[:len(ips) - _MAX_IPS_PER_SHA]:
                    del ips[k]
            if len(shas) > _MAX_SHAS:
                for k in sorted(shas, key=lambda x: shas[x].get('last', 0))[
                        :len(shas) - _MAX_SHAS]:
                    del shas[k]
            _save_census(d)
    except Exception as e:
        print(f"[KILL] [WARN] census record failed: {e}")


def census(active_within_s=_CENSUS_ACTIVE_S):
    """Per-build device counts, newest first.

    `devices` counts only ips seen inside the window; `devices_total` is the
    unpruned history. Both are reported because "0 active, 900 ever" is the
    shape of a build everybody already left, and killing it is a no-op."""
    now = time_module.time()
    out = []
    try:
        with _LOCK:
            d = _load_census()
        for sha, row in (d.get('shas') or {}).items():
            if not isinstance(row, dict):
                continue
            ips = row.get('ips') if isinstance(row.get('ips'), dict) else {}
            live = sum(1 for t in ips.values() if now - _float(t) <= active_within_s)
            out.append({
                'sha': sha,
                'version': row.get('v') or '',
                'devices': live,
                'devices_total': len(ips),
                'first_seen': _float(row.get('first')),
                'last_seen': _float(row.get('last')),
            })
    except Exception:
        return []
    out.sort(key=lambda r: r['last_seen'], reverse=True)
    return out


def _float(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


# --------------------------------------------------------------------------
# Admin surface
# --------------------------------------------------------------------------
def _surface_keys():
    """The device-facing per-surface keys, taken from the schema so this can
    never drift from what the device actually reads."""
    from .app_settings import _SCHEMA
    return [(e.get('device_key'), e.get('label')) for e in _SCHEMA if e.get('device_key')]


def options():
    """Everything the dashboard needs to render a target picker: the builds the
    server knows about, with device counts attached.

    The build list is bounded (the last _HISTORY_N commits) and the tag list is
    not, so they are separate arrays and a tag can be `known: false` -- its
    commit fell out of the window. Such a tag is still offered, because an
    operator hunting an old release needs it and it resolves through git, but it
    can never be a RANGE endpoint (the window is the range's coordinates).
    """
    facts = _load_git_facts()
    counts = {r['sha'][:12]: r for r in census()}
    tag_by_sha = {}
    for t in facts['tags']:
        tag_by_sha.setdefault(t['short'], []).append(t['tag'])
    builds = []
    for i, h in enumerate(facts['history']):
        row = counts.get(h['short'])
        builds.append({
            'sha': h['short'],
            'ts': h['ts'],
            'subject': h['subject'],
            'index': i,
            'tags': tag_by_sha.get(h['short'], []),
            'devices': row['devices'] if row else 0,
            'devices_total': row['devices_total'] if row else 0,
            'last_seen': row['last_seen'] if row else 0,
        })
    listed = {b['sha'] for b in builds}
    tags = [{'tag': t['tag'], 'sha': t['short'],
             'known': t['short'] in listed,
             'devices': (counts.get(t['short']) or {}).get('devices', 0),
             'devices_total': (counts.get(t['short']) or {}).get('devices_total', 0)}
            for t in facts['tags']]
    return {'builds': builds, 'tags': tags, 'census': census(),
            'scopes': list(SCOPES), 'surfaces': _surface_keys(),
            'unknown_sha': UNKNOWN_SHA, 'history_n': _HISTORY_N}


def describe_targets():
    """Active targets with their resolved state, so the dashboard can grey out
    a selector that cannot match anything instead of storing it silently."""
    counts = {r['sha'][:12]: r for r in census()}
    out = []
    for t in _load_targets():
        row = dict(t)
        row['keys'] = keys_for_target(t)
        row['status'] = _status(t)
        # The device count is the whole point of the row: "this kills 3 people"
        # before you press it. For a range, sum the window -- the counts of the
        # endpoints alone would understate it, which is the direction that
        # matters.
        row['devices'] = _covered_devices(t, counts)
        out.append(row)
    return out


def _covered_devices(t, counts):
    def n(sha):
        return (counts.get((sha or '')[:12]) or {}).get('devices', 0)
    if t.get('sha'):
        return n(t['sha'])
    if t.get('tag'):
        full = _tag_sha(t['tag'])
        return n(full) if full else 0
    frm, to = t.get('from_sha'), t.get('to_sha')
    if frm or to:
        history = _load_git_facts()['history']
        i_frm = _history_index(frm) if frm else 0
        i_to = _history_index(to) if to else len(history) - 1
        if i_frm is None or i_to is None:
            return 0
        if i_frm > i_to:
            i_frm, i_to = i_to, i_frm
        return sum(n(h['short']) for h in history[i_frm:i_to + 1])
    # A blanket target is the sum of everything currently reporting, minus the
    # devices that a build-scoped target already accounts for is NOT worth
    # computing: every device is in the blast radius, so report the total.
    return sum(c.get('devices', 0) for c in counts.values())


def _status(t):
    if not (t.get('sha') or t.get('tag') or t.get('from_sha') or t.get('to_sha')):
        return 'blanket'
    if t.get('tag') and not _tag_sha(t['tag']):
        return 'unresolved-tag'
    if (t.get('from_sha') or t.get('to_sha')):
        if t.get('from_sha') and _history_index(t['from_sha']) is None:
            return 'unresolved-endpoint'
        if t.get('to_sha') and _history_index(t['to_sha']) is None:
            return 'unresolved-endpoint'
        return 'range'
    return 'sha'


def _new_id():
    return 'k' + hashlib.sha1(
        (str(time_module.time()) + os.urandom(8).hex()).encode('utf-8')
    ).hexdigest()[:10]


def add_target(body):
    """Create one target. Raises ValueError with an operator-readable message;
    every message names the field that was wrong, because this is driven by a
    form and not by code."""
    if not isinstance(body, dict):
        raise ValueError('body must be an object')
    scope = (body.get('scope') or 'lg').strip()
    if scope not in SCOPES:
        raise ValueError(f"scope must be one of {', '.join(SCOPES)}")
    out = {'id': _new_id(), 'scope': scope, 'ts': time_module.time()}
    key = (body.get('key') or '').strip()
    if scope == 'surface':
        known = {k for k, _ in _surface_keys()}
        if not key:
            raise ValueError('scope=surface needs a surface key')
        if key not in known:
            raise ValueError(f'unknown surface key {key!r}')
        out['key'] = key
    elif key:
        raise ValueError(f'key is only used by scope=surface, not scope={scope}')

    sha = (body.get('sha') or '').strip().lower()
    tag = (body.get('tag') or '').strip()
    frm = (body.get('from_sha') or '').strip().lower()
    to = (body.get('to_sha') or '').strip().lower()
    selectors = [bool(sha), bool(tag), bool(frm or to)]
    if sum(1 for s in selectors if s) > 1:
        raise ValueError('pick one of sha, tag, or a from/to range')
    if sha:
        if sha != UNKNOWN_SHA and not _norm_sha(sha):
            raise ValueError('sha must be 4-40 hex characters')
        out['sha'] = sha
    if tag:
        if not _TAG_RE.match(tag):
            raise ValueError('tag must be letters, digits, dot, dash or underscore')
        out['tag'] = tag
    if frm or to:
        # An endpoint that resolves to nothing kills nobody, so refuse it here
        # rather than storing a row that will sit in the UI looking armed.
        for name, val in (('from_sha', frm), ('to_sha', to)):
            if val and _history_index(val) is None:
                raise ValueError(f'{name} {val!r} is not in the last '
                                 f'{_HISTORY_N} commits')
        if frm:
            out['from_sha'] = frm
        if to:
            out['to_sha'] = to
    note = (body.get('note') or '').strip()
    if note:
        out['note'] = note[:200]
    _mutate_targets(lambda ts: ts.append(out))
    return out


def remove_target(target_id):
    target_id = (target_id or '').strip()
    if not target_id:
        raise ValueError('id required')

    def mutator(ts):
        for i, t in enumerate(ts):
            if t.get('id') == target_id:
                del ts[i]
                return True
        return False
    return _mutate_targets(mutator)


def preview(sha):
    """Dry run: what would `sha` receive, and which targets fired. The dashboard
    shows this before it stores anything, because the whole cost of a bad
    target is discovered by users rather than by you."""
    from .app_settings import get_all
    base = get_all()
    resolved, hits = resolve(base, sha)
    changed = sorted(k for k in resolved if resolved[k] is False and base.get(k) is not False)
    return {'sha': (sha or '').lower(), 'hits': hits, 'keys_off': changed,
            'effective': {k: resolved[k] for k in changed}}