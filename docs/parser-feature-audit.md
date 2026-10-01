# Parser feature audit — what AMLL and braccato do that we do not

## Status

**Landed in `server/parsers_ttml.py`** (verified by `tmp/tv.py`, 42 checks, and
`tmp/test_ttml_xbg.py` against the user's own snippet):

| Row | Now |
|-----|-----|
| 1.1 | `x-bg` -> `entry['bg']`, its own text/parts/window, parens stripped, never a vocal word |
| 1.2 | `x-translation` -> seeds `translated` |
| 1.3 | `x-roman` -> `entry['romanization']` |
| 1.4 | `tts:ruby` -> `part['ruby']` = timed readings on the base syllable |
| 1.5 | `amll:obscene` -> `part['obscene']` |
| 1.6 | `amll:empty-beat` -> `part['emptyBeat']` |
| 1.7 | `<transliterations>` sidecar -> `romanization`, parsed so it can carry its own timings |
| 1.8 | `<translations>` sidecar -> `translated`, **gated on `xml:lang`** (see §8.1 — this was a live bug) |
| 1.9 | `<ttm:agent><ttm:name>` -> `entry['singerName']`; the old docstring denying it can exist is gone |
| 1.12 | `<tt xml:lang>` read; not stored per line (see §8.4) |
| 1.14 | `itunes:song-part` (kebab) read alongside `itunes:songPart` |
| 1.15 | a `<p>` with no `begin`/`end` gets its window from its children instead of being dropped |
| 1.18 | inter-word spacing read from the real whitespace text nodes; the `has_gap`/`is_cjk`/`glued` guess is gone |
| 1.19 | text containing `\n` is not treated as a word |
| 1.21 | all whitespace runs collapsed (`\s+`), not just literal spaces |
| 1.22 | background cue unwrapped from `(`/`（` … `)`/`）` |
| 1.A | undeclared namespace prefixes get a synthetic `xmlns:` — **a `tts:`/`itunes:` file used to return None and lose every line** |
| — | `_PARSER_EPOCH` 1 -> 2, because none of the above is replayable offline |

**Deliberately not adopted:** 1.16 (`applyFallbackWord`) — our own
`cache.sanitize_lyrics_parts` drops any line with <=1 part, so it would be
stripped again before anything could use it. The bg/romanization sub-lines are
where it mattered and they keep their window.

**Still open:** everything in §2 (LRC), §3 (QRC), §4 (SRT), §5 (credits), plus
TTML rows 1.10, 1.11, 1.13, 1.16, 1.23, 1.24, 1.25, and §7 (the whole device
half). See §8.

Sources read in full at these pins, and re-read before changing anything:

- AMLL: `packages/ttml/src/parser.ts` + `constants.ts`
  @ `86200dead453bb067e554e989110cbadca8d4756` (amll-dev/applemusic-like-lyrics)
- braccato: `packages/parsers/src/{ttml,ttmlTypes,lrc,qrc,srt,plain,credits,instrumentalBreaks,stringSimilarity,detect,format,formatPredicates,types}.ts`
  @ `master` (better-lyrics/braccato)

Our side: `server/parsers_lrc.py`, `server/parsers_qrc.py`,
`server/parsers_ttml.py`, `server/cache.py::_insert_instrumental_gaps`.

Every row below is verified against our source, not inferred. "Worse for us"
means we do the thing but a different way that loses information or is a guess.

---

## 1. TTML — `ttm:role` (the one the user hit)

Our parser has **no notion of `ttm:role` at all**. `p.iter('span')` is
*recursive*, so a wrapper `<span ttm:role="x-bg">` **and** its inner cue both
land in `parts`. Verified with `tmp/test_ttml_xbg.py` against the user's own
snippet: the cue `(ちーん)` becomes karaoke word #9 of line L24, so the wipe
lights it up and the translation swallows it — plus one **empty** part from the
wrapper span, which has its text in the child.

| # | Feature | AMLL | braccato | Us |
|---|---------|------|----------|-----|
| 1.1 | `ttm:role="x-bg"` background vocal, own text + own words | `backgroundVocal` | per-part `isBackground`, traverses one level in | **absent** |
| 1.2 | `ttm:role="x-translation"` inline translation | `translations[]` | falls into `parseLyricPart` | **absent** |
| 1.3 | `ttm:role="x-roman"` inline romanization | `romanizations[]` | falls into `parseLyricPart` | **absent** |
| 1.4 | `tts:ruby` container/base/textContainer/text → per-syllable furigana with its own begin/end | `Syllable.ruby` | not read | **absent** (ruby text becomes extra *words*, so a kana line renders doubled) |
| 1.5 | `amll:obscene="true"` per syllable | `Syllable.obscene` | `@_obscene` / `@_explicit` | **absent** |
| 1.6 | `amll:empty-beat="N"` per syllable | `Syllable.emptyBeat` | not read | **absent** |
| 1.7 | `<transliterations>` sidecar → `romanization` + **timed** romanization | yes | yes | **absent** |
| 1.8 | `<translations>` sidecar as a *separate* per-line translation, keyed `for`, tagged `xml:lang`, two dialects | yes | yes | **conflated** — we read `<text for>` into `line_texts` and use it as the line's own `text` |
| 1.9 | `<ttm:name>` inside `<ttm:agent>` → the singer's NAME | yes (`Agent.name`) | no | **absent, and our docstring denies it can exist** |
| 1.10 | `<songwriters>` list / Composer `<meta key="songwriter">` | yes | yes | **absent** |
| 1.11 | `amll:meta` key/value: musicName, artists, album, isrc, ncm/qq/spotify/apple ids | yes | no | **absent** (we extract no song metadata from lyrics at all) |
| 1.12 | `<tt xml:lang>` / `<body xml:lang>` → song language | yes | yes | **absent** |
| 1.13 | `itunes:timing="Word"\|"Line"` — authoritative timing mode | yes | no | **absent** — we infer it from part counts |
| 1.14 | `itunes:song-part` (KEBAB) alongside `itunes:songPart` | yes (`SongPartKebab` first) | no | **only `songPart`** — the kebab form loses its section |
| 1.15 | Line `begin`/`end` **derived from the children** when `<p>` has none | `calculateTimeRange` | no (skips the line) | **we drop the whole line** (`if not begin: continue`) |
| 1.16 | Whole-line fallback word when there is text but no timed span | `applyFallbackWord` | no | **absent** — no parts at all |
| 1.17 | Drop a lone word whose start *and* end are 0 (a placeholder) | `isZeroFallback` | no | **kept** as a 0/0 part |
| 1.18 | Inter-word spacing read from the **actual whitespace text nodes** | yes (`endsWithSpace`) | indirect | **a guess** — `has_gap` + `is_cjk` + `glued`, the source of "foll ow" |
| 1.19 | Text containing `\n` is formatting, not a word | `isFormatting` | no | **absent** |
| 1.20 | `finalizeWords`: trim first word's leading space, last word's trailing, force last `endsWithSpace=false` | yes | yes | ad hoc, inside the join |
| 1.21 | `normalizeText`: collapse **all** whitespace runs | yes (`/\s+/g`) | yes | **only literal spaces** (`re.sub(r' +', ' ')`) — a tab or newline survives into the line |
| 1.22 | Strip the wrapping `(`/`（` … `)`/`）` off a background cue | yes | no | **absent** — braccato renders `ちーん`, we would render `(ちーん)` |
| 1.23 | An inline translation/romanization may never contribute words | `ignoreWords=true` | no | n/a until 1.2/1.3 exist |
| 1.24 | `blockIndex` per div/p | yes | no | **absent** (we rely on document order) |
| 1.25 | A repeated `itunes:key` (a chorus) keeps one entry per occurrence | suffixes ids, fans translations out | same | `line_texts.setdefault` — one shared text, which is actually fine for our shape |

### 1.A The availability bug in 1.4's neighbourhood

`parse_ttml_basic` regex-strips `amll:` and the default `xmlns` and nothing
else. braccato has `declareMissingNamespaces`, which injects a synthetic
`xmlns:` for **every undeclared prefix** before parsing. ElementTree *raises*
on an undeclared prefix, our `except` returns `None`, and **the entire file is
lost**. A file using `tts:` or `itunes:` without declaring them — which is
exactly what AMLL's own exporter does — currently produces nothing at all.

---

## 2. LRC — `server/parsers_lrc.py`

| # | Feature | braccato | Us |
|---|---------|----------|-----|
| 2.1 | **`[bg:...]` LySy enhanced-LRC background group** → parts flagged background | yes | **absent** — a second voice in an LRC file is glued into the line |
| 2.2 | ID tags `ti ar al au lr length by offset re tool ve #` | yes, into a map | **only `offset`** |
| 2.3 | `au` (author) and `lr` (lyricist) are songwriters | yes | **discarded** |
| 2.4 | `lrcFixers` pass 1 — a Musixmatch `" "` gap part within 15ms of, or under 100ms vs, its predecessor donates its duration to the real word | yes | **absent** |
| 2.5 | `lrcFixers` pass 2 — when >50% of real words are ≤100ms, stretch each to the next part | yes | **absent** |
| 2.6 | Musixmatch style detection (whitespace-only gap fragments between `<ts>` pairs) | yes | **absent** |
| 2.7 | Credit-line drop (`作词：周杰伦`) using the 1.9 rules | yes | **absent** — a credit line becomes a sung line |
| 2.8 | `[offset:]` applied to line **and** part starts | yes | **already have it** |
| 2.9 | Line span = min..max across *all* time tags on the line | yes | need to confirm `parse_lrc` |

---

## 3. QRC — `server/parsers_qrc.py`

| # | Feature | braccato | Us |
|---|---------|----------|-----|
| 3.1 | **Singer from a `"Name:"` line prefix**, both the whole-line tag and the mid-syllable colon, with `currentSinger` carried onto following lines | yes | **absent** — a QQ duet has no voice attribution at all, so our duet feature has nothing to align |
| 3.2 | `合` / `ALL` / `合唱` → the group agent (both voices) | yes | **absent** |
| 3.3 | CJK credit-role drop (`作词`, `编曲`, `和声`, …) with the length-4 role-noun rule | yes | **one English regex**, `_QRC_CREDIT_RE` |
| 3.4 | `<QrcInfos LyricContent="...">` envelope + `&quot;`/`&amp;` unescape | yes | we peel Cubey's JSON and a bare `{...}`, **not** `LyricContent=` |
| 3.5 | Drop opening lines that echo the title/artist, via `stringSimilarity > 0.5` | yes | only a line containing the `ti:` text |
| 3.6 | Uniform-syllable-duration heuristic to drop machine-generated openers | yes | **absent** |
| 3.7 | Real per-word + per-line durations | yes | **already have it, and better** (we clamp to the line end rather than the next line's start) |
| 3.8 | CJK-aware joining | yes | **already have it** |

---

## 4. SRT — a format we do not have at all

`isSrt` predicate, cue number + `HH:MM:SS,mmm --> HH:MM:SS,mmm` blocks,
`<tag>` stripping, multi-line cue text joined with `\n`. No provider of ours
returns SRT today, so this is a free win for anything that does (a node's mesh
payload, a manual paste).

---

## 5. Credits — `credits.ts` is a whole module we do not have

`isCreditRole`, `isSongwriterRole`, `isCreditLine`, `songwritersInCreditLine`,
`splitCreditNames`, `uniqueNames`, plus the CJK role vocabulary
(`词 曲 编曲 和声 混音 吉他 制作人 演唱 原唱 翻唱 后期 和音 录音 策划 伴奏 美工 海报 旁白`)
and the rule that an unlisted CJK role still counts when it is ≤4 chars and ends
in a role noun — without that, `我听见你的声音` reads as a credit. We have one
English regex and no name list at all.

---

## 6. Things we already have, or do differently on purpose

Do not "sync" these backwards.

- **We have instrumental breaks.** `cache.py::_insert_instrumental_gaps`, same
  5000 ms threshold. They emit `words: ""` + `isInstrumental`; we emit
  `text: '[instrumental]'` + a synthetic one-part `parts`, because our client
  keys off the text. Ours takes the outro gap from the caller's duration, they
  take it from `<body dur>`.
- **`ttm:agent` nearest-wins scope** down `<p>` → `<div>` → `<body>` (and
  `itunes:songPart` the same way). Neither reference has this; it is what makes
  Die With A Smile attribute 50 lines correctly. Keep it.
- **`ttm:agent type="group"` → `duet`.** Ours alone. Keep it.
- **`<text for>` as the authoritative line text.** Deliberate (it fixed 24 of 53
  lines on an lrc.red/BiniLyrics file where the spans are the *romanised* source
  and joining them mangles it). Both references treat it as a translation
  instead. This is a real semantic disagreement, not an oversight — see §8.
- **QRC duration clamping** is stricter than braccato's. Keep it.

---

## 7. The client half

Everything in §1–§5 is server-side. To be *visible* it also needs the device,
and the device half is **unbuilt** (no toolchain on this host — see the standing
REBUILD blocker in AGENTS.md). What the client would need per feature:

- **1.1 / 2.1 background vocal** → its own row under the lyric, dimmed, no wipe,
  no translation. Better Lyrics renders it exactly that way.
- **1.3 / 1.7 romanization** → its own row; this is what the user's very first
  screenshot showed (romaji in the same row) and we currently have no way to
  carry it at all.
- **1.4 ruby** → small text over the syllable, sharing the syllable's window.
- **1.5 obscene** → replaced or blurred.
- **1.9 singer names** → replaces the bare `singer` index in the duet label.

---

## 8. Open questions (do not guess these)

1. **`<text for>`: line text or translation? — RESOLVED, and it was a live
   bug.** Both references say translation; our commit `c729dbb` made it line
   text, because for lrc.red/BiniLyrics the spans are a romanised source and
   joining them mangles it. Treating *every* `<text for>` as the line text means
   an Apple file carrying an English `<translations>` block has its original
   lyrics **replaced by the translation**. The separator is `xml:lang`, and both
   references already require one before accepting the block as a translation:
   - `xml:lang` in scope on the `<text for>` -> translation / romanization
   - no `xml:lang` anywhere -> the line text (lrc.red, BiniLyrics)
   Both paths are now covered by `tmp/tv.py` cases 9 and 9b. Still worth one
   real lrc.red file to confirm the langless shape is really langless.
2. **Does a background cue get translated?** Better Lyrics leaves it alone, and
   the Chinese row in the user's screenshot (`它腐爛並死在地板上（chush）`) is the
   translation of the *vocal* line — `（chush）` is part of that translation, not
   of the cue. So: no, and that is what we do. `translate_result_in_place` only
   ever sees `line['text']`.
3. **Do we want songwriters at all?** Nothing consumes them today. §5 is a whole
   module in braccato; porting it buys a credit-line filter (which we want, §2.7
   and §3.3) far more than it buys a credits display.
4. **Where does `xml:lang` live?** It is read but not stored per line — our line
   dict has no field for it and `_canonical_lyrics_bytes` packs only
   start/dur/text/translated/wordSynced/parts, so adding one would need a
   deliberate decision about the hash. It matters for choosing a translation
   target and for the romanization label.
