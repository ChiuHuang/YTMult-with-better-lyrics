# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
# See AGENTS.md architecture section.
import functools
import json
import os
import re
import sys
import requests
import hashlib
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
from flask import Flask, request, jsonify, render_template, session, redirect, url_for, Response, stream_with_context
from .app import app, SERVER_INSTANCE_ID, CRASH_LOG_FILE, _crash_logs, LOG_DIR
from .logging_util import _log_crash
from .self_update import _get_local_sha

@app.route('/deploy.sh')
def serve_deploy_sh():
    deploy_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'deploy.sh')
    try:
        with open(deploy_path, 'r', encoding='utf-8') as f:
            script = f.read()
        return Response(script, mimetype='text/x-shellscript', headers={
            'Content-Disposition': 'inline; filename="deploy.sh"',
            'Cache-Control': 'no-cache',
        })
    except FileNotFoundError:
        return jsonify({'error': 'deploy.sh not found on server'}), 404


@app.errorhandler(404)
def handle_404(e):
    # log but not crash
    print(f"[WARN] 404 {request.path} from {request.remote_addr}")
    return jsonify({'error': 'Not found'}), 404

@app.errorhandler(500)
def handle_500(e):
    _log_crash(type(e), e, getattr(e, '__traceback__', None))
    return jsonify({'error': 'Internal error', 'instance': SERVER_INSTANCE_ID}), 500


@app.route('/api/app/settings', methods=['GET'])
def api_app_settings():
    """Public remote config for the tweak. Open by design (values are
    non-secret); managed from the dashboard App tab."""
    from .app_settings import get_all
    return jsonify({'ok': True, 'settings': get_all()})


@app.route('/api/app/stats', methods=['GET'])
def api_app_stats():
    """Public usage counter: lyrics served, devices, last song + status.
    Actions embeds it into release notes."""
    from .usage_stats import snapshot
    return jsonify({'ok': True, **snapshot()})


# ------------------------------------------------------------
# MD3 badge renderer (same look as assets/badges/*.svg)
# ------------------------------------------------------------
# One glyph per type, so the row does not read as five download buttons.
# Official Google Material Icons (Apache-2.0), 24x24 paths pasted verbatim and
# drawn at scale(0.5) -> 12x12 inside the 24px chip. Same set as
# assets/badges/*.svg, so dynamic and static badges look identical.
_BADGE_GLYPHS = {
    'release': 'M5,20h14v-2H5V20z M19,9h-4V3H9v6H5l7,7L19,9z',
    # 'subtitles', not Material's 'lyrics': that one is a chat bubble with a
    # note in it, and the previous entry was the plain 'chat' bubble, so a
    # lyrics counter read as a message counter. The caption box is what a lyric
    # line actually looks like on screen.
    'lyrics': 'M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zM4 12h4v2H4v-2zm10 6H4v-2h10v2zm6 0h-4v-2h4v2zm0-4H10v-2h10v2z',
    'devices': 'M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99zM17 19H7V5h10v14z',
    'tracks': 'M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 14.5c-2.49 0-4.5-2.01-4.5-4.5S9.51 7.5 12 7.5s4.5 2.01 4.5 4.5-2.01 4.5-4.5 4.5zm0-5.5c-.55 0-1 .45-1 1s.45 1 1 1 1-.45 1-1-.45-1-1-1z',
    'nodes': 'M2 20h20v-4H2v4zm2-3h2v2H4v-2zM2 4v4h20V4H2zm4 3H4V5h2v2zm-4 7h20v-4H2v4zm2-3h2v2H4v-2z',
}
_BADGE_TEXT_X = 33    # label start: chip (28) + 5px gap
_BADGE_PAD_R = 10     # room after the label, so a wider fallback font still fits
_BADGE_MIN_W = 88
# Advance widths (px) of Roboto Medium at 13px for ASCII 0x20..0x7E, straight
# out of the font's hmtx (unitsPerEm 2048); font-weight:500 picks Medium when
# Roboto is installed. A flat 7.4px/char average over-stretched short labels
# (up to 23%), and textLength then squashed the glyphs to fit -- that is what
# made the digits on "Lyrics 397" look fat. Measure per character instead.
_BADGE_ASCII_W = (
    '3.237 3.485 4.215 7.935 7.389 9.547 8.309 2.196 4.532 4.583 5.745 '
    '7.243 2.856 4.266 3.631 5.142 7.389 7.389 7.389 7.389 7.389 7.389 '
    '7.389 7.389 7.389 7.389 3.447 3.091 6.608 7.274 6.767 6.322 '
    '11.629 8.652 8.201 8.487 8.493 7.351 7.141 8.849 9.236 3.669 '
    '7.217 8.195 7.033 11.381 9.229 8.976 8.309 8.976 8.112 7.846 '
    '7.890 8.474 8.411 11.438 8.227 7.922 7.827 3.561 5.434 3.561 '
    '5.554 5.865 4.189 7.033 7.319 6.805 7.338 6.976 4.608 7.370 7.217 '
    '3.320 3.256 6.786 3.320 11.312 7.230 7.401 7.319 7.382 4.570 '
    '6.709 4.323 7.224 6.430 9.661 6.538 6.329 6.538 4.361 3.263 4.361 '
    '8.639 '
)
_BADGE_W = [float(v) for v in _BADGE_ASCII_W.split()]


def _badge_text_width(text):
    """Advance width of `text` at 13px/500 Roboto. Unknown codepoints get a
    rough latin/CJK width so a stray character cannot break the pill."""
    total = 0.0
    for ch in text:
        cp = ord(ch)
        if 32 <= cp <= 126:
            total += _BADGE_W[cp - 32]
        elif cp > 0x2E80:                 # CJK and friends: full width
            total += 13.0
        else:
            total += 7.0
    return total


def _xml_esc(s):
    return (s or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def _badge_svg(text, aria=None, glyph='release'):
    """Server-rendered MD3 pill. Plain %s substitution: str.format would
    choke on the CSS braces. textLength forces an exact fit, so measure the
    WHOLE string (prefix + value) -- measuring the value alone squeezed a
    long prefix down to ~2px per char. It is set to the string's REAL width,
    so the glyphs are never distorted; only a font whose metrics differ from
    Roboto (Segoe UI ~3%, Calibri ~13%) gets rescaled, and a wider one still
    cannot spill out of the pill."""
    text = (text or '')[:44]
    tw = round(_badge_text_width(text), 2)
    w = max(_BADGE_MIN_W, int(round(_BADGE_TEXT_X + tw + _BADGE_PAD_R)))
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="32" '
        'viewBox="0 0 %d 32" role="img" aria-label="%s">'
        '<style>.bg{fill:#D3E3FD}.fg{fill:#041E49;'
        "font-family:Roboto,-apple-system,'Segoe UI',sans-serif;"
        'font-size:13px;font-weight:500}.chip{fill:#041E49}'
        '.glyph{fill:#D3E3FD}'
        '@media (prefers-color-scheme: dark){.bg{fill:#004A77}'
        '.fg{fill:#D3E3FD}.chip{fill:#D3E3FD}.glyph{fill:#004A77}}'
        '</style>'
        '<rect class="bg" width="%d" height="32" rx="16"/>'
        '<circle class="chip" cx="16" cy="16" r="12"/>'
        '<g transform="translate(10,10) scale(0.5)">'
        '<path class="glyph" d="%s"/>'
        '</g>'
        '<text class="fg" x="%d" y="20.5" textLength="%s" '
        'lengthAdjust="spacingAndGlyphs">%s</text></svg>'
    ) % (w, w, _xml_esc(aria or text), w,
         _BADGE_GLYPHS.get(glyph, _BADGE_GLYPHS['release']),
         _BADGE_TEXT_X, ('%.2f' % tw), _xml_esc(text))


def _badge_tracks_cached():
    """Distinct cached (video_id, lang) pairs. Filenames only -- scan_cache()
    would open every JSON file, far too slow for a badge."""
    from .app import _ROOT
    from .cache import _cache_key_from_filename
    try:
        names = os.listdir(os.path.join(_ROOT, 'cache', 'lyrics'))
    except OSError:
        return 0
    keys = set()
    for fname in names:
        key = _cache_key_from_filename(fname)
        if not key:
            continue
        parts = key.split(':')
        if parts and parts[-1] == 'fast':
            parts.pop()
        if len(parts) >= 2:
            keys.add(':'.join(parts))
    return len(keys)


# Serving counters live in cache/usage_stats.json, which only counts what this
# process instance served since it started -- it reads low after a restart or
# a redeploy. The log file has every serve the box ever did (plus one rotated
# generation), so count from that instead. badge_stats owns the counting: it
# reads the log ONCE, remembers the byte offset, and afterwards reads only
# what was appended. This used to re-read the whole ~6MB log every 30s.
def _served_from_logs():
    from .badge_stats import served_count
    return served_count()


def _badge_nodes_online():
    from .nodes import connected_nodes, _connected_nodes_lock
    with _connected_nodes_lock:
        return len(connected_nodes)


def _badge_text(btype):
    """'<label> <value>' for a badge type, or None when unknown."""
    if btype == 'release':
        from .release_info import latest_release
        try:
            tag = (latest_release() or {}).get('tag') or 'none yet'
        except Exception:
            tag = 'unknown'
        return f'Download Last Build: {tag[:24]}'
    if btype == 'lyrics':
        served = _served_from_logs()
        if served <= 0:                      # no log yet -> usage counter
            from .usage_stats import snapshot
            served = int(snapshot().get('served', 0))
        return f'Lyrics served {served:,}'
    if btype == 'devices':
        from .usage_stats import snapshot
        return f"Devices {int(snapshot().get('users', 0)):,}"
    if btype == 'tracks':
        return f"Tracks {_badge_tracks_cached():,}"
    if btype == 'nodes':
        return f'Nodes {_badge_nodes_online()}'
    return None


@app.route('/api/app/badge', methods=['GET'])
def api_app_badge():
    """Server-rendered MD3 badge (same theme as assets/badges/), used in the
    README. ?type=release|lyrics|devices|tracks|nodes. SVG, no-store.
    Any failure degrades to an 'unknown' pill, never a broken image."""
    btype = (request.args.get('type') or 'release').strip()
    try:
        text = _badge_text(btype)
    except Exception as e:
        print(f"[BADGE] [WARN] type={btype} failed: {e}")
        text = None
    if text is None:
        text = f'{(btype or "badge")[:20]}: unknown'
    return Response(_badge_svg(text, glyph=btype), mimetype='image/svg+xml',
                    headers={'Cache-Control': 'no-store'})


@app.route('/api/app/release-hook', methods=['POST'])
def api_app_release_hook():
    """Actions webhook: instant release info (incl. Asia mirror URL) without
    waiting for GitHub API polling. Secret-gated via X-YTMU-Hook header
    (YTMU_HOOK_SECRET env or admin_config hook_secret). Body: {tag,
    download_url, asia_url?, published_at?, size?, icon_url?, notes?}."""
    import secrets as _secrets_mod
    from .release_info import hook_secret, update_cache
    secret = hook_secret()
    if not secret:
        return jsonify({'ok': False, 'error': 'hook not configured'}), 403
    provided = (request.headers.get('X-YTMU-Hook') or '').strip()
    if not provided or not _secrets_mod.compare_digest(provided, secret):
        return jsonify({'ok': False, 'error': 'bad hook secret'}), 403
    body = request.get_json(silent=True) or {}
    if update_cache(body):
        print(f"[Release] [OK] webhook push tag={body.get('tag')} "
              f"asia={'yes' if body.get('asia_url') else 'no'}")
        return jsonify({'ok': True, 'tag': body.get('tag')})
    return jsonify({'ok': False, 'error': 'need tag + download_url'}), 400


@app.route('/api/app/altstore', methods=['GET'])
def api_app_altstore():
    """AltStore source JSON, always pointing at the newest build-N release
    (download via the worker proxy for Asia). Submit this URL on
    altdirect.app to get direct-install links."""
    from .release_info import ALTSTORE_ICON, latest_release, worker_url
    rel = latest_release()
    if not rel or not rel.get('download_url'):
        return jsonify({'error': 'No release with an IPA asset found'}), 503
    tag = rel.get('tag') or 'build-?'
    version = tag[6:] if tag.startswith('build-') else tag
    icon_url = (rel.get('icon_url') or ALTSTORE_ICON or
                'https://raw.githubusercontent.com/ChiuHuang/YTMult-with-better-lyrics/main/Resources/icon.png')
    # Asia file CDN is the fastest direct link; worker-proxied GitHub second.
    dl = rel.get('asia_url') or worker_url(rel['download_url'])
    return jsonify({
        'name': 'YTMusicUltimate',
        'identifier': 'dev.chiuhuang.ytmult',
        'apps': [{
            'name': 'YouTube Music',
            'bundleIdentifier': 'com.google.ios.youtubemusic',
            'developerName': 'ChiuHuang',
            'version': version,
            'versionDate': rel.get('published_at') or '',
            'versionDescription': f'YTMusicUltimate ({tag})',
            'downloadURL': dl,
            'localizedDescription': 'YouTube Music with Ultimate tweak + synced lyrics.',
            'iconURL': icon_url,
            'size': rel.get('size') or 0,
        }],
    })

def _dump_screen_name(dump_content):
    """Topmost screen from the VC hierarchy section (presented wins, else deepest child)."""
    try:
        start = dump_content.index('--- VIEW CONTROLLER HIERARCHY ---')
    except ValueError:
        start = 0
    try:
        end = dump_content.index('--- WINDOWS & VIEW HIERARCHY ---', start)
    except ValueError:
        end = len(dump_content)
    section = dump_content[start:end]
    vc_pat = re.compile(r'<([A-Za-z0-9_]+(?:ViewController|SheetController|DialogViewController))\b')
    if '[Presented]' in section:
        tail = section.rsplit('[Presented]', 1)[1]
        m = vc_pat.findall(tail)
        if m:
            return m[-1]
    m = vc_pat.findall(section)
    if m:
        return m[-1]
    return 'UnknownScreen'


def _safe_dump_component(s, default='novideo'):
    s = re.sub(r'[^A-Za-z0-9_-]+', '_', (s or '').strip()).strip('_')
    return s or default


@app.route('/log', methods=['POST'])
def proxy_log():
    try:
        data = request.get_json(force=True)
        req_type = data.get('type', '')

        if req_type == "APP_LOG":
            event = data.get('event', 'unknown')
            level = data.get('level', 'info')
            message = data.get('message', '')
            payload = data.get('payload', {})
            timestamp = data.get('timestamp') or datetime.now().isoformat(timespec='milliseconds')
            vid = payload.get('videoId') or payload.get('videoID') or ''
            client_ip = request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-For') or request.remote_addr
            if vid:
                print(f"[iOS] [iOS Tweak] [{timestamp}] [{level.upper()}] {event}: {message} | payload={payload} ip={client_ip}")
            else:
                print(f"[iOS] [iOS Tweak] [{timestamp}] [{level.upper()}] {event}: {message}")
                if payload:
                    print(f"  [iOS] payload={payload} ip={client_ip}")
            return jsonify({"status": "ok"})

        if req_type == "UI_DUMP":
            os.makedirs(LOG_DIR, exist_ok=True)
            timestamp = datetime.now().strftime("%H-%M-%S")
            dump_content = data.get('request_body', '')
            vc_count = dump_content.count('ViewController')
            win_count = dump_content.count('[WINDOW:')
            has_9999 = 'tag = 9999' in dump_content
            has_engagement = 'Engagement' in dump_content
            has_lyrics_chip = 'No lyrics found' in dump_content or 'lyric' in dump_content.lower()
            hidden_yes = dump_content.count('hidden = YES')
            hidden_no = dump_content.count('hidden = NO')
            video_id_match = re.search(r'Current VideoID:\s*(\S+)', dump_content)
            playback_match = re.search(r'Playback Time:\s*([\d\.]+)', dump_content)
            tweak_match = re.search(r'Tweak Build:\s*(\S+)', dump_content)
            vid = video_id_match.group(1) if video_id_match else '?'
            ptime = playback_match.group(1) if playback_match else '?'
            tweak_sha = tweak_match.group(1) if tweak_match else '?'
            try:
                srv_sha = (_get_local_sha() or '?')[:7]
            except Exception:
                srv_sha = '?'
            print(f"\n[ALERT] [UI_DUMP {timestamp}] [DUMP] UI Dump received! video={vid} t={ptime}s tweak={tweak_sha} srv={srv_sha} vc={vc_count} win={win_count} has9999={has_9999} hasEngagement={has_engagement} hasLyricsChip={has_lyrics_chip} hiddenYES={hidden_yes} hiddenNO={hidden_no}")
            if not has_9999:
                print(f"  [WARN] [UI_DUMP] Modded lyrics view tag 9999 NOT found - panel will show official!")
            if not has_engagement:
                print(f"  [WARN] [UI_DUMP] No Engagement panel detected - user may not have opened lyrics panel")
            if not has_lyrics_chip:
                print(f"  [WARN] [UI_DUMP] No lyrics chip text detected - button may be hidden/locked or ASDisplayView (unlock failed)")

            filepath = os.path.join(LOG_DIR, f"UI_DUMP_{timestamp}_{_safe_dump_component(_dump_screen_name(dump_content), 'UnknownScreen')}_{_safe_dump_component(vid if vid != '?' else '', 'novideo')}.txt")
            _dup = 1
            _base, _ext = os.path.splitext(filepath)
            while os.path.exists(filepath):
                _dup += 1
                filepath = f"{_base}_{_dup}{_ext}"
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(dump_content)
            print(f"[OK] [UI_DUMP] Saved to {filepath} ({len(dump_content)} bytes)")
            return jsonify({"status": "ok"})

        if req_type == "CRASH":
            # iOS tweak crash report
            payload = data.get('payload', {})
            msg = data.get('message', 'iOS crash')
            print(f"[CRASH] [iOS] {msg} payload={payload}")
            _crash_logs.append({'ts': datetime.now().isoformat(), 'type': 'iOS_Crash', 'msg': msg, 'trace': str(payload)[:3000], 'instance': SERVER_INSTANCE_ID})
            try:
                with open(CRASH_LOG_FILE, 'a', encoding='utf-8') as f:
                    f.write(f"\n[{datetime.now().isoformat()}] [CRASH] iOS: {msg} {payload}\n")
            except: pass
            return jsonify({"status": "ok"})

        print(f"[WARN] Unknown log type: {req_type} payload={data}")
        return jsonify({"status": "ok"})

    except Exception as e:
        print(f"[FAIL] [LOG] error: {e}")
        import traceback as _tb; _tb.print_exc()
        _log_crash(type(e), e, e.__traceback__)
        return jsonify({"status": "error", "message": str(e)}), 500

