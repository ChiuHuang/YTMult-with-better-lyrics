# Braccato vs YTMusicUltimate Lyrics System Comparison

## Braccato Packages (better-lyrics/braccato)

| Package | Description | We Have Equivalent? |
|---------|-------------|---------------------|
| `@braccato/core` | `<braccato-lyrics>` web component (Lit), renders LBL/WBW/syllable | No - we use native iOS renderer |
| `@braccato/parsers` | TTML, LRC, SRT, QRC, Plain parsers + auto-detect | Partial - missing SRT parser |
| `@braccato/provider-blyrics` | Provider chain with priority + validation | Partial - we have pipeline/race but no validation |
| `@braccato/rics` | RICS CSS preprocessor for theming | No - native iOS styling |
| `@braccato/types` | Shared Lyric/LyricPart interfaces | Similar shapes in our pipeline |

## Parser Coverage

| Format | Braccato | YTMusicUltimate |
|--------|----------|-----------------|
| TTML | Yes | Yes (`parsers_ttml.py`) |
| LRC | Yes | Yes (`parsers_lrc.py`) |
| QRC | Yes | Yes (`parsers_qrc.py`) |
| SRT | Yes | **Missing** |
| Plain | Yes | Partial (fallback in LRC parser) |

## Provider Coverage

### Braccato Built-in Providers
- `createBLyricsProvider` - bLyrics (TTML, often word-synced)
- `createLRCLibSyncedProvider` - LRCLIB synced
- `createLRCLibPlainProvider` - LRCLIB plain
- `createLegatoProvider` - Legato (LRC from kugou)

### Our Providers
| Provider | Source | Sync Type |
|----------|--------|-----------|
| Boidu TTML | lyrics-api.boidu.dev/getLyrics | Word (bLyrics) |
| Boidu QQ | lyrics-api.boidu.dev/qq/getLyrics | Word (QRC) |
| Boidu Kugou | lyrics-api.boidu.dev/kugou/getLyrics | Line (LRC) |
| Binimum | lyrics-api.binimum.org | Syllable (TTML) |
| Cubey | Cubey API | Word (bLyrics TTML) + Syllable (binimum) |
| Unison | unison.boidu.dev | Various |
| LRCLIB | lrclib.net | Line/Word |
| YouTube | ytmusic API | Line |

## Features We Have That Braccato Doesn't (Server-Side)

1. **Translation Pipeline** - Cohere + Google translation for Chinese scripts
2. **JWT Management** - Turnstile challenge -> JWT for Cubey access
3. **Parallel Provider Race** - SSE streaming with raw->machine->final stages
4. **Scoring/Ranking** - `_lyrics_score` prefers WBW > line-sync > plain
5. **Client File Cache** - `YTMU_LyricsCache` with count + size limits
6. **Background Re-race** - Periodic re-fetch for better lyrics (`rerace.py`)
7. **Native iOS Integration** - ELM tap hijack, engagement panel embed

## Features Braccato Has That We Don't

1. **SRT Parser** - SubRip format support
2. **Provider Validation** - `createSimilarityValidator` prevents wrong matches
3. **RICS Theming** - CSS preprocessor for consistent styling
4. **Web Component** - Framework-agnostic `<braccato-lyrics>` element
5. **Background Vocals** - `x-bg` TTML role support
6. **Linked Groups** - Repeating sections (choruses) linked in source
7. **Composer Editor** - Tap-to-sync, timeline editor, syllable splitting
8. **Syllable as First-Class** - Native syllable timing (we get it from binimum only)

## Client-Side Rendering Comparison

| Feature | Braccato (Web) | YTMusicUltimate (iOS) |
|---------|----------------|----------------------|
| Word-by-word highlight | Yes (CSS mask) | Yes (CAShapeLayer union of TextKit rects) |
| Syllable highlight | Yes | Yes (from binimum TTML) |
| Line-sync fallback | Yes | Yes |
| Scroll modes | Internal/External | Native table view |
| Theming | CSS variables + RICS | Native UIColor dynamic provider |
| Long word glow | `longWordThreshold` | Not implemented |
| Line-synced delay | `lineSyncedDelay` (50ms) | Hardcoded behavior |

## Gaps To Consider

### High Priority
- [ ] Add SRT parser (`parsers_srt.py`) for completeness
- [ ] Add provider validation (similarity check) to pipeline
- [ ] Consider long-word glow for karaoke UX

### Medium Priority
- [ ] Background vocals (`x-bg` role) rendering distinction
- [ ] Linked groups support for repeating sections
- [ ] RICS-like theming system for easier customization

### Low Priority
- [ ] Web component port (not needed for iOS-only tweak)
- [ ] Composer-style editor (out of scope)
- [ ] Tap-to-sync (out of scope)

## Notes

- Our iOS renderer uses real per-word timestamps from providers (bLyrics TTML, Portato QRC, Binimum syllable TTML)
- The mask reveal (CAShapeLayer union of TextKit rects) is functionally equivalent to braccato's CSS mask approach
- Server-side provider race with scoring ensures best sync type wins (WBW > syllable > line)
- Translation pipeline is unique to our system (server-side, not client-side)