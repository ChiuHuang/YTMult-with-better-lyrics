# Split from parsers_lrc.py / parsers_qrc.py -- edit HERE.
#
# Credits recognition, ported from better-lyrics/braccato
# `packages/parsers/src/credits.ts`, because BOTH of our LRC and QRC paths need
# it and each had grown its own private approximation:
#
#   parsers_qrc._QRC_CREDIT_RE  one English regex: `\b(lyrics|composed|
#       arranged|produced|written|vocals?|chorus|mixed|mastered)\s*by\b`
#   parsers_lrc                  nothing at all
#
# One English regex is not enough for the sources we actually fetch. QQ Music
# writes `作词：周杰伦`, and that line used to sail straight through into the
# lyrics as a sung line. The vocabulary has to be CJK, and it has to be
# careful: `编曲` ends in `曲` and is NOT a songwriter, while `词曲` is.
#
# Why the length rule exists. An unlisted CJK role still counts when it is at
# most ROLE_NOUN_MAX_LENGTH chars and ends in a role noun. Without the length
# bound, a real sung clause like `我听见你的声音` ("I hear your voice") ends in
# `音` and reads as a credit, so the line gets dropped and the song loses it.
# That is the whole reason this is not a plain suffix check.
import re

# The roles that name a writer of the words or the music.
_SONGWRITER_ROLES = frozenset((
    '词', '詞', '作词', '作詞', '曲', '作曲', '词曲', '詞曲',
    '作词作曲', '作詞作曲',
    'writtenby', 'lyricsby', 'composedby', 'lyricist', 'composer',
))

# Every credit role, so a line crediting only the arranger can still be dropped.
_CREDIT_ROLES = _SONGWRITER_ROLES | frozenset((
    '编曲', '編曲', '和声', '和聲', '混音', '吉他', '制作人', '製作人',
    '演唱', '原唱', '翻唱', '后期', '後期', '和音', '录音', '錄音',
    '策划', '策劃', '伴奏', '美工', '海报', '海報', '旁白',
    'producedby', 'arrangedby', 'mixing', 'mastering', 'vocal', 'vocals',
    'guitar', 'bass', 'drums', 'producer', 'arranger',
))

_ROLE_NOUN_SUFFIXES = ('词', '詞', '曲', '声', '聲', '音')
_ROLE_NOUN_MAX_LENGTH = 4
_ROLE_SEPARATORS = re.compile(r'[/&、,，・·]')
_CREDIT_LINE_RE = re.compile(r'^([^:：]+)[:：]\s*(.+)$')
_FREE_TEXT_SEPARATORS = re.compile(r'[/、，,]')
_WS_RE = re.compile(r'\s+')


def _normalize_role(role):
    return _WS_RE.sub('', (role or '').lower())


def _is_role_noun(part):
    if part in _CREDIT_ROLES:
        return True
    return (len(part) <= _ROLE_NOUN_MAX_LENGTH
            and any(part.endswith(noun) for noun in _ROLE_NOUN_SUFFIXES))


def _role_parts(normalized):
    """QQ Music joins roles (`作曲/编曲`) and tags them in Latin (`Rap作词`), so a
    CJK role is read part by part rather than as one string.

    re.split, not str.split: the separator set is a compiled pattern, and
    str.split raises TypeError on one -- which took out every role that was not
    an exact member of a vocabulary set, i.e. precisely the joined and
    Latin-tagged ones this function exists for."""
    stripped = re.sub(r'[a-z]+', '', normalized)
    return [p for p in re.split(_ROLE_SEPARATORS, stripped) if p]


def is_credit_role(role):
    """Whether the text before a colon names a credit role, not a singer."""
    n = _normalize_role(role)
    if n in _CREDIT_ROLES:
        return True
    parts = _role_parts(n)
    return bool(parts) and all(_is_role_noun(p) for p in parts)


def is_songwriter_role(role):
    n = _normalize_role(role)
    if n in _SONGWRITER_ROLES:
        return True
    if not is_credit_role(role):
        return False
    return any(p in _SONGWRITER_ROLES for p in _role_parts(n))


def is_credit_line(text):
    """Whether a lyric line's text is a credit (`作词：周杰伦`) rather than a
    sung line. This is the function the parsers call; the rest is here so the
    names can be harvested too."""
    if not text:
        return False
    m = _CREDIT_LINE_RE.match(text.strip())
    return bool(m) and is_credit_role(m.group(1))


def songwriters_in_credit_line(text):
    """The names a songwriting credit line lists, or [] when it credits
    anything else. `编曲：某人` is a credit worth dropping but names no writer."""
    if not text:
        return []
    m = _CREDIT_LINE_RE.match(text.strip())
    if not m or not is_songwriter_role(m.group(1)):
        return []
    return split_credit_names(m.group(2))


def split_credit_names(value):
    return [n.strip() for n in _FREE_TEXT_SEPARATORS.split(value or '') if n.strip()]


def unique_names(names):
    """Trim, drop empties, keep the first of each exact duplicate, in order."""
    seen = set()
    out = []
    for name in names or ():
        trimmed = (name or '').strip()
        if trimmed and trimmed not in seen:
            seen.add(trimmed)
            out.append(trimmed)
    return out


def string_similarity(a, b, substring_length=2):
    """Dice coefficient over 2-grams, 0..1.

    Ported from braccato's stringSimilarity.ts (MIT, Stephen Brown). Used to
    drop a QRC opening line that just echoes the song title -- a containment
    test is not enough, because the echo is usually the title plus a word or
    two of lyric."""
    a = (a or '').lower()
    b = (b or '').lower()
    if len(a) < substring_length or len(b) < substring_length:
        return 0.0
    grams = {}
    for i in range(len(a) - (substring_length - 1)):
        g = a[i:i + substring_length]
        grams[g] = grams.get(g, 0) + 1
    match = 0
    for j in range(len(b) - (substring_length - 1)):
        g = b[j:j + substring_length]
        if grams.get(g, 0) > 0:
            grams[g] -= 1
            match += 1
    return (match * 2) / (len(a) + len(b) - (substring_length - 1) * 2)
