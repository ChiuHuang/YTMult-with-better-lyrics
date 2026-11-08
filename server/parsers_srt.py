# Split-out module: SRT (SubRip) subtitle text as a lyrics source.
# No provider of ours documents SRT today, but external Cubey inner payloads
# and pasted blobs reached parse_lrc, where the [mm:ss.xx] tag set matches
# nothing, so a whole SRT file came back empty and the candidate was dropped.
# Output is the same entry shape parse_lrc yields. SRT carries no word
# timing, and none may be fabricated (generate_interpolated_parts is a
# deliberate no-op for the same reason): every cue is line-synced only,
# wordSynced=False. Credit lines (performers, songwriters) are dropped by the
# shared rule.
import re

from .parsers_credits import is_credit_line

# braccato's isSrt predicate: the cue number runs to line start and is
# anchored at the beginning of its digit run, so a long run of digits stays
# linear rather than quadratic.
_SRT_DETECT_RE = re.compile(
    r'(?<!\d)\d+\r?\n\d{2}:\d{2}:\d{2}[,.]\d+ --> \d{2}:\d{2}:\d{2}[,.]\d+')

# One cue's timing line. Accepts the SubRip comma and the WebVTT dot as the
# millisecond separator, exactly like the reference parser does.
_CUE_TIME_RE = re.compile(
    r'^\s*(\d+):(\d{1,2}):(\d{1,2})[,.](\d+)\s*-->\s*'
    r'(\d+):(\d{1,2}):(\d{1,2})[,.](\d+)\s*$')

# HTML-ish tags inside cue text (<i>, <v Speaker>, <c.class>) are markup.
_SRT_TAG_RE = re.compile(r'<[^>]+>')


def is_srt(text):
    return bool(text) and bool(_SRT_DETECT_RE.search(text))


def _parse_time(h, m, s, ms_token):
    ms = int(str(ms_token).ljust(3, '0')[:3])
    return (int(h) * 3600000 + int(m) * 60000 + int(s) * 1000) + ms


def parse_srt(srt_text, duration_sec=0):
    """Parse SubRip subtitle blocks into the shared lyrics entry shape.

    Blocks are separated by blank lines, and the file is newline-normalised
    before the split -- a CRLF file has \r between the two \n of its block
    separator, and splitting for \n\n before normalising found no boundary at
    all and read the whole file as ONE block. See tmp/test_srt.py.
    Inside a block, any line containing the cue arrow is the timing line and
    everything AFTER it is the cue text (multi-line cues join with a newline,
    as the reference parser does); everything before it -- the cue index,
    WEBVTT headers, NOTE blocks -- is dropped by construction. A cue with no
    text inside, or text that is a credit line (performer/songwriter), is
    skipped entirely.
    """
    text = srt_text.strip().replace('\r\n', '\n').replace('\r', '\n')
    blocks = text.split('\n\n')
    result = []
    for block in blocks:
        lines = block.split('\n')
        arrow = None
        for idx, line in enumerate(lines):
            if '-->' in line:
                arrow = _CUE_TIME_RE.match(line)
                if arrow and idx > 0:
                    break
                arrow = None
        if not arrow:
            continue
        start_ms = _parse_time(*arrow.group(1, 2, 3, 4))
        end_ms = _parse_time(*arrow.group(5, 6, 7, 8))

        arrow_idx = next(i for i, line in enumerate(lines) if '-->' in line)
        text = _SRT_TAG_RE.sub('', '\n'.join(lines[arrow_idx + 1:])).strip()
        if not text or is_credit_line(text):
            continue

        duration_ms = max(end_ms - start_ms, 0)
        result.append({
            'time': round(start_ms / 1000.0, 3),
            'startTimeMs': start_ms,
            'text': text,
            'durationMs': duration_ms,
            'duration': round(duration_ms / 1000.0, 3),
            'wordSynced': False,
        })

    # The cue index is not order in every hand-made file.
    result.sort(key=lambda x: x['startTimeMs'])
    return result


def parse_synced_text(text, duration_sec=0):
    """The ONE dispatcher for an unlabelled 'synced' lyric blob.

    Providers hand external text here with no format declared, and callers
    kept assuming LRC -- which silently loses a whole SRT file (parse_lrc
    returns [] because its [mm:ss.xx] tags never match). New formats join
    the chain here rather than every caller growing its own guess.
    """
    if is_srt(text):
        return parse_srt(text, duration_sec)
    from .parsers_lrc import parse_lrc
    return parse_lrc(text, duration_sec)
