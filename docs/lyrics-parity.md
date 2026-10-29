# Lyrics parity: spoti.pw vs YTMU

Reference: `C:\Users\chiuhuang\Documents\Codex\2026-10-10\https-github-com-skopevoj-spoti-pw\work\spoti.pw\tweak\Sources`
(the owner paywalled/deleted the account; this clone is the source of truth).
YTMU side lives in `Source/LyricsSheet.x`, `Source/LyricsStream.x`, `Source/LyricsCore.x`,
`Source/LyricsShared.h`, `Source/Prefs/LyricsSettingsController.m`, and the `server/` package.

Status vocabulary: **DONE** (same behavior exists), **PARTIAL** (exists, differs), **MISSING**,
**DELIBERATE** (we do it differently on purpose — do not "fix" without a reason).

---

## 0. Architecture in one table

| Concern | spoti.pw | YTMU |
|---|---|---|
| Fetch | On-device providers, sequential walk, best-timing merge | Server-side parallel race (`server/race.py`, `pipeline.py`), best score wins, device reads ONE SSE route (`/api/lyrics/stream`) |
| Model | `SGKaraokeWord`/`SGKaraokeLine` objects, ms ints | `NSDictionary` rows: `text, time, startTimeMs, durationMs, wordSynced, parts[], bg{}, romanization, singer, duet, translated, isInstrumental, source, cached` |
| Render | One `SGRKaraokeView` (UIScrollView, per-line views, per-word label pairs) | `UITableView` sheet, per-row cell, dim `lyricLabel` + masked bright `wipeLabel` |
| Clock | Predicted + eased (`kClockPull=0.08`, snap 250ms) | Extrapolated media clock (rebase on sample, 0.2s freeze) |
| Cache | 3 in-memory LRU-ish maps (40/40/40), nothing on disk | Server disk cache (`database/lyrics`, parser epoch) + device client cache (`YTMU_LyricsCache`, parser-epoch gate) |
| Surfaces | Fullscreen page, redesigned player, lock screen, Live Activity | Panel/sheet + fullscreen landscape; no lock screen / Live Activity |

---

## 1. Timing model

| # | Feature | spoti.pw | YTMU status |
|---|---|---|---|
| 1.1 | Timing enum Words/Line/None, finest-first | `SGKaraokeTiming` (Lyrics.h:28-32), `SGKaraokeLinesTiming` = MIN over lines | PARTIAL — payload has `wordSynced` bool only; no Line/None vocabulary on the wire. Server `tier` int is the equivalent gate |
| 1.2 | Word: text/start/end ms, `joined` (CJK flush) | Lyrics.h:42-48; `piecesOf` per-composed-char split of unspaced scripts (KaraokeTiming.m:106-133) | DONE — `parts[].space:false` == `joined`; `wbwDisplayTextForLyric` rebuilds display from parts with CJK join |
| 1.3 | Line: words, start/end, voice, align, timing, backing, pronunciation, translation | Lyrics.h:50-68 | DONE/PARTIAL — `parts`, `bg` (backing, own cue timeline), `romanization`, `singer`, `duet` exist; `align` is derived per-row (`YTMUVoiceAlignment`), not a stored enum; pronunciation only as a whole-line string, not word-timed |
| 1.4 | `SGKaraokeSungEnd` = max(line, backing.end) | KaraokeTiming.m:32-34 | PARTIAL — active windows come from the timing table (`ytmu_rebuildTimingTable`); backing end does NOT extend the row's window (a line whose cue runs long deactivates early) |
| 1.5 | `SGKaraokeLeadLine` — earliest still-sung line, else last begun | KaraokeTiming.m:36-43 (used by lock screen / Live Activity) | MISSING (no single-line surfaces). The sheet's active-set (`ytmu_activeIndexesAtMs`) already keeps overlaps lit, cap none |
| 1.6 | Word estimation for line-timed lyrics: `sung = clamp(MAX(0.6*gap, 350+letters*75), ≤1.8*estimate, ≤gap)`, distribute by `(letters+2)/weight`, unspaced char = 3 letters | KaraokeTiming.m:13-19, 141-169 | MISSING — YTMU lights line-timed rows whole; there is no estimate and no sweep. See 3.9 (simulate setting) |
| 1.7 | Break detection: `♪`/blank lines dropped from estimation | KaraokeTiming.m:135-138 | DONE — instrumental rows handled by `ytmuIsInstrumentalLyric` + `[instrumental]` payload flag |
| 1.8 | Voice→align: voice heard first leads, second trails, later voices lead again | `SGKaraokeAlignVoices` (KaraokeTiming.m:68-80) | PARTIAL — YTMU: `singer >= 1` rows go right, `duet` rows centre (`YTMUVoiceAlignment`); no "later voices lead again" rule |
| 1.9 | Spotify color-lyrics body parse (JSON + protobuf) | KaraokeTiming.m:202-248 | DELIBERATE — YTMU's `providers_yt` fetches YouTube Music lyrics instead; no Spotify capture (wrong host app) |

---

## 2. Render engine

| # | Feature | spoti.pw | YTMU status |
|---|---|---|---|
| 2.1 | Word highlight = two stacked labels + gradient mask feather (22pt) | `SGRKaraokeWordView` fillTo, kFillEdge=22 (SGRKaraokeView.m:116-196) | DONE — `lyricLabel`(dim) + `wipeLabel`(bright) + `CAShapeLayer` mask + per-word `CAGradientLayer` feather (b752d44). YTMU's feather rides ONE word; spoti.pw's runs continuously across the line (cursor in line-units). Same look at word granularity |
| 2.2 | Sweep curve: monotone cubic (Fritsch–Carlson) through word knots, never backwards | SGRKaraokeSweep (:509-604) | PARTIAL — YTMU interpolates linearly inside the current word (`YTMUWordCursor`), with last-word clamp; no cross-word easing. Visual difference is small because YTMU's feather is per-word |
| 2.3 | Per-word float/rise: critically damped spring, lift 2.5pt, lead 80ms, min 700ms | floatAt (:183-189), kFloatMinMs/kFloatLeadMs | MISSING — YTMU has no word motion (the wobble was removed deliberately for raster cost; a 2.5pt Y-translate on a rasterized label is cheaper than the old skew but still re-renders). Port is possible per-row on the ACTIVE line only |
| 2.4 | Whole-line mode: line-timed lights whole, 0.35s white fade + 0.9s rise | kWholeFade/kWholeRiseMs (:530-544, 752-757) | DONE (fade) — YTMU line-synced arrival = crossfade 0.33s (`YTMUHighlightFadeInDuration`); no rise |
| 2.5 | `SGKeyLyricsSimulateWords` — sweep estimated words on Line-timed | Lyrics.h:23 | MISSING (depends on 1.6) |
| 2.6 | Duet: overlapping lines lit together, cap 6; anchorPoint at alignment edge; dim-scale toward own text | kMostSung=6, anchorPoint (:706, 1712-1729) | PARTIAL — YTMU multi-line active set lights overlaps (no cap); no dim-scale on distance, only alpha |
| 2.7 | Distance dimming: alpha 0.3 + per-line blur `1.4/line` up to 6, blur eased 0.6s from presentation value; scale 0.97 | placeLine (:1541-1563), setBlur (:717-730) | PARTIAL — YTMU `YTMUDistanceLadder` = {1.0, 0.88, 0.72, 0.52, 0.28, 0} alpha steps, no blur, no scale. CAFilter gaussianBlur is private API; on YTM (host app different) risk/benefit unclear — needs a device A/B before porting |
| 2.8 | Backing vocal: own nested line, 0.62x size, 0.8 alpha, own word timings, parent's align | (:696-700, 779-781) | DONE — `bgLabel`/`bgWipeLabel` pair with own cue cursor + rect cache (`ytmu_applyCueWipeToCell`), hard edge instead of feather (deliberate: second moving edge competes) |
| 2.9 | Pronunciation under words, syllable-matched | layPair (:360-433) | MISSING — YTMU `romanLabel` is one string under the line (no per-syllable matching, no word timing) |
| 2.10 | Text-size ORDER: first shown text = full size, others 0.67/0.54 by PLACE not identity | SGRKaraokeStyle (:216-236) | PARTIAL — YTMU sizes are fixed ratios of the fitted size: main 1.0, trans 19/28, cue/roman 13/28; no user-orderable sizes |
| 2.11 | Font 30pt, margin 24, lineGap 24, rowTighten 2; pitch = ceil(lineHeight)−2 | (:19-20, 334-355) | DONE — YTMU fitted per-song size (max 34, floor 20, 2 lines/row, b752d44), row padding 9/7/9, lineHeightMultiple 0.95 |
| 2.12 | Instrumental break: >=7s gap becomes three breathing dots; fill order follows the next line's reading direction; Reduce-Motion variant | SGRKaraokeBreakView, kBreakMinMs=7000 | DONE - gaps >=7s render the reference dots (080d2b7); the timeline is evaluated procedurally from the media clock instead of CAKeyframes on a layer clock, so pause holds and seek re-lands for free, and Reduce Motion keeps fades+fill only. The wave ribbon stays for 5-7s gaps (DELIBERATE: a bar rest reads as a wave, a break reads as dots) |
| 2.13 | Edge fade: 10% gradient mask top+bottom of the scroll view, re-aligned to presentation bounds | kEdgeFade (:1094-1097) | PARTIAL — YTMU sheet has no top/bottom fade; rows just scroll under the header |
| 2.14 | Anchor 28% of height; lines below focus follow a beat later (delay min(0.3, n*0.04)) | kAnchor (:1448-1455) | PARTIAL — YTMU anchor 37% (`YTMUScrollTargetRatio`), single animated scroll, no per-line stagger |
| 2.15 | View culling ±0.5 screens, ≤4 new views/frame; lit labels hidden when unsung | (:1494-1537, :149-151) | N/A — YTMU is a UITableView; UIKit owns recycling. Label count per row is fixed |
| 2.16 | Plain text mode: everything lit, no clock, no seek, scroll does not spring back | showPlain (:783-791) | DONE — `isSynced=NO` → full ink, no wipe |
| 2.17 | Clock: predicted, ease toward sample (pull 0.08), snap >250ms | clockMs (:1630-1643) | DONE — YTMU extrapolated clock, 0.2s freeze on stall |
| 2.18 | Display link frame range (80,120,120), torn down off-window/background | (:1225-1252) | PARTIAL — YTMU tick exists with `[FPS]` meter; frame-rate range not set |
| 2.19 | Sibling dimming while showing (syncSiblings) | (:1611-1625) | DELIBERATE — YTMU panel is an overlay/embed, not over a native lyrics view |

---

## 3. Scroll & interaction

| # | Feature | spoti.pw | YTMU status |
|---|---|---|---|
| 3.1 | Tap-to-seek on a line (hit area inflated) + haptic | tapped (:1132-1149) | DONE — row tap seeks, word tap seeks the word (`ytmu_handleWordTap`) |
| 3.2 | Manual scroll hold 3s, then spring back 0.7s (plain: never) | kBrowseHold (:1187-1214) | DONE — `userScrolledLyrics` lock until next tap; no timed auto-resume (differs: YTMU waits for a tap, spoti.pw times out). Candidate parity change: 3s auto-resume |
| 3.3 | Browsing zeroes blur | (:1187-1191) | N/A (no blur yet) |
| 3.4 | Seek = instant re-place when focus jumps >2 | (:1693-1700) | DONE — far jump rule (`labs(new-old) > 3` → instant) |
| 3.5 | Long-press line → meanings sheet | (:1151-1159) | MISSING (needs §7) |

---

## 4. Sources

| # | Feature | spoti.pw | YTMU status |
|---|---|---|---|
| 4.1 | Provider set | BiniLyrics, Musixmatch(richsync), Unison, NetEase(yrc), LRCLIB | DONE+ — YTMU server has all of these plus AMLL, QQ/KuGou (Cubey), braccato-direct, YouTube |
| 4.2 | ORDER = user setting, sequential walk, stop at first fully-timed answer; merge keeps best timing read off the lines | LyricsSources.m:255-358 | PARTIAL — YTMU races ALL providers in parallel and scores; order is server-side priority, not user-orderable. The device's provider switcher can pin a provider per song but there is no global order page |
| 4.3 | Failures never cached as negatives; unnamed sources passed over, asked once name arrives | finish (:303-328) | PARTIAL — server tier bookkeeping records per-provider outcomes; re-race known-misses exist; no "wait 1.5s for a name then retry skipped providers" stage (YouTube gives a name immediately, so low value) |
| 4.4 | Musixmatch: anonymous token, 600s cooldown on refusal, 401→drop+retry once | Musixmatch.m:82-104, 274-279 | DONE — server JWT pool (`jwt_pool`), node-mesh sync, retired-token ledger |
| 4.5 | NetEase yrc word timing, no page text | NetEase.m:34-115 | DONE — `providers_cubey` Cubey/NetEase |
| 4.6 | TTML dialect: ttm:agent voice, x-bg backing, translations/transliterations by xml:lang, itunes:key matching, pronunciation -Latn preference, bareText dedup | SGTTML.m | DONE — `server/parsers_ttml.py` ports the same dialect (parser audit: x-translation/x-roman/tts:ruby/amll:obscene still open — see `docs/parser-feature-audit.md`) |
| 4.7 | LRC parser: only opening stamps, fraction scaling, empty rows are breaks | LrcLib.m:24-65 | DONE — `server/parsers_lrc.py` (LySy [bg:] group learned) |
| 4.8 | Translation language choice: 31 tags, "Any" = first carried | LyricsSources.m:483-502 | DONE — device `lyricsTargetLang` (`YTMUTargetLang`) + server `song_lang` detection; "Any" semantics differ (YTMU always translates to target) |
| 4.9 | "Lyrics from <source>" credit line, 12pt @0.4, gated by a pref | creditTo (:1603-1609) | PARTIAL — provider name lives in the switcher + payload meta; no persistent credit label on the sheet |
| 4.10 | Donor-track redirect so Spotify serves lyrics for tracks it says have none | LyricsHook.x:95-113 | DELIBERATE — wrong host app; YTMU's equivalent is `lyricsAllTracks`-style offering via its own panel |
| 4.11 | Instrumental short-circuit | (:361-366) | DONE — `[instrumental]` payload flag renders as the note/wave |

---

## 5. Settings / UX surface

| # | Row | spoti.pw key | YTMU status |
|---|---|---|---|
| 5.1 | Sources order page | `lyricsProviders` | MISSING (device-side). Server-side priority + per-song switcher exists |
| 5.2 | Lyrics for every track | `lyricsAllTracks` | DELIBERATE — YTM panel always offers lyrics |
| 5.3 | Show source | `lyricsCredit` | PARTIAL (see 4.9) |
| 5.4 | Simulate word timing | `lyricsSimulateWords` | MISSING (see 2.5) |
| 5.5 | Text sizes order (drag list) | `redesign.lyricsTextOrder` | MISSING (see 2.10) |
| 5.6 | Pronunciation / Translation toggles + corner button menu | `redesign.lyricsPronunciation/.lyricsTranslation` | PARTIAL — YTMU: romanization switch in settings; translation always-on when payload has it; no in-lyrics menu button |
| 5.7 | Translation language (31 tags) | `lyricsTranslationLanguage` | DONE (see 4.8) |
| 5.8 | Line meanings level | `lyricsMeanings` | MISSING (needs §7) |
| 5.9 | Lock screen lyrics | `lockScreenLyrics` | MISSING — artist field swapped for the current line via `MPNowPlayingInfoCenter`, 0.25s tick, ≤30-char pieces, artist returns after 4s gap |
| 5.10 | Live Activity lyrics | `liveActivity(.view)` | MISSING — line + next line into the Activity, 0.25s tick |
| 5.11 | Duet display (align/label) | (only align) | DONE+ — YTMU has BOTH align and a singer-change marker |
| 5.12 | Pinyin/romanization toggle | (pronunciation toggle) | DONE — `lyricsShowRomanization` default OFF |
| 5.13 | FPS meter | (none) | DONE+ — YTMU-only, `[FPS]` log line |

---

## 6. Clock / perf parity notes worth porting regardless of features

1. **Feather locations write inside a disabled CATransaction** — done in b752d44; outside one, `locations` takes a 0.25s implicit animation and the ramp trails the word.
2. **Masks under `shouldRasterize`** — spoti.pw hides unsung lit labels instead of rasterizing; YTMU stopped rasterizing the wipe labels (b752d44) for the same reason: a mask swap does not reliably dirty a raster cache.
3. **Presentation-layer reads before animating** — spoti.pw eases blur from `presentationLayer`. YTMU's `ytmu_fadeHighlightTo:` already does this for opacity.
4. **Off-main layout measurement** (`QOS_CLASS_USER_INTERACTIVE`, generation counter to drop late results) — YTMU's per-song font fit runs on main inside `updateLyrics:`; a long song measures every line once per payload. Acceptable, but a rotation re-fit (`ytmu_refitFontSizeForCurrentWidth`) can stutter on 600-line songs. Port the off-thread pattern if it ever shows in `[FPS]`.

---

## 7. Genius meanings — the largest MISSING subsystem

spoti.pw: search `genius.com/api/search/song` → `api/referents` (5 pages × 50), author levels
(verified/accepted/community), fold + match lines (exact, or containment ≥10 chars, or ≥4 words
shared-ratio ≥0.75), attach a meaning to EVERY matching line (chorus explained at each occurrence),
marker = white bubble after the last word (artist) or dotted underline (others), sheet with detents,
"Next" cycling, "View on Genius".

Port plan (server-side fits YTMU better than device-side):
1. `server/providers_genius.py`: search + referents + fold/match (port `Meanings.m` matching as-is),
   cache per videoID in `database/meanings/`.
2. Payload: add `meanings: [{lines: [i, ...], body, author: "artist|editors|community", url}]` to the
   song payload (or a second endpoint fetched lazily — recommended: meanings are per-song heavy and
   most songs have none).
3. Device: `ytmu_meaningsForRow` index; bubble/underline marker on the row (bubble = 22pt circle with
   `quote.opening` after the last word; else CAShapeLayer dashed underline per wrapped row); tap →
   sheet (`YTMUMeaningSheetController`, medium+large detents).
4. Setting: `lyricsMeaningsLevel` 0-3 in Lyrics settings.

## 8. Ordered implementation plan (value per effort)

1. **Search crash fix** (blocking the app) — see the crash report in `tmp/search-crash-report.md`.
2. **2.12 break dots** - LANDED in 080d2b7 (dots on >=7s gaps, procedural clock; wave keeps 5-7s).
3. **2.7 blur by distance** — CAFilter gaussianBlur + 0.6s ease from presentation value; device A/B with `[FPS]` first.
4. **5.9 lock-screen lyrics** — `MPNowPlayingInfoCenter` hook + `YTMULeadLine()` helper (port 1.5's overlap rule onto the timing table). Biggest new surface per line of code.
5. **1.6 + 2.5 estimated word sweep** — port `timedLine` to the device (it needs only line starts + text), behind a settings switch; benefits every LRCLib-only song.
6. **4.9 + 5.6 credit label + in-lyrics menu** — provider credit line and pronunciation/translation toggles from a corner button.
7. **2.9 syllable-matched pronunciation** — needs word-timed romanization from the server (TTML transliterations already carry it; the parser audit's remaining items).
8. **7 meanings** — largest; server provider + payload + sheet UI.
9. **5.5 text-size ordering** — settings page drag list + per-row style application.
10. **5.1 device provider-order page** — only if the server priority is not enough; the switcher already covers per-song choice.

DELIBERATE differences to keep: wave ribbon over dots for short gaps, hard cue edge (no second
feather), no wobble/word-transform, UITableView recycling over manual culling, server race over
sequential walk, no Spotify capture/donor logic (wrong host app).
