# AGENTS.md — session handoff for YTMusicUltimate (lyrics system)

> "btw we met 49% context window you can write a agent.md or a prompt for new session
> like how we talk or utf8 encoding error what we've do including this line"
> — user request that created this file. New session: read this first.

## How we talk (user expectations — keep these)
- Short, concise, facts-first. No superlatives, no praise, no emotional validation.
- No emojis anywhere: not in code, logs, UI strings, or filenames. Plain tags instead
  (`[OK]`, `[FAIL]`, `[WARN]`, `[REQ]`, `[MUSIC]`, ...).
- Reference code as `file_path:line_number`.
- User corrections persist across turns until explicitly lifted. Never regress a
  fixed constraint (e.g. re-introducing emojis).
- Verify through execution when possible (`py_compile`, import test, device logs).
- Commit + push when a fix/feature is done (CI builds the tweak).

## Environment traps (Windows host, PowerShell 5.1)
- GitHub work: use `gh` CLI (authenticated as ChiuHuang) — prefer
  `gh api repos/OWNER/REPO/commits/SHA` for commits/compare info. Avoid bare
  `github.com/.../compare/...` webfetches, and NEVER render them with the
  WebFetch tool. PowerShell gotchas: redirecting `gh` output with `>` writes
  UTF-16 (read it back with Python `encoding='utf-8-sig'`), and quoting a long
  `--jq` inline in PS 5.1 breaks — write the jq to a file or parse the JSON
  with `.venv\Scripts\python` instead.
- PowerShell 5.1: NO `&&` chaining, NO `head`/`grep`/`cat`. Use `;`, `Select-String`,
  `Get-Content`. `default.bash` runs PowerShell, not bash.
- Python: `.venv\Scripts\python` (has deps) or `py -3`. `flask` is only in `.venv`.
- The console is cp950: printing CJK/emoji through it throws
  `UnicodeEncodeError` and corrupts what you see. NEVER trust console-rendered
  CJK — verify with `repr(bytes)` / hexdump to a file, then `Get-Content
  -Encoding utf8`. `�` in tool output is usually the console, not the data.
- All edited files: UTF-8 without BOM, LF only. Normalize after edits
  (strip BOM, `\r\n` -> `\n`). The `bom-fmt-guard` skill applies to Rust/Cargo
  files only — still keep LF/no-BOM everywhere.
- Bulk emoji replacement once corrupted every `?` ternary and `&` URL into
  `[WAIT]` and broke the iOS build. After any bulk replace: re-check `?`, `&`,
  run `py_compile`, and diff.

## iOS/Logos specifics
- Theos build uses `-Werror`: unused `static` C functions fail the build — mark
  helpers `__attribute__((unused))`. ObjC methods are exempt.
- `return %orig;` is valid in void hooks (see Downloading.x pattern).
- `git push` prints "repository moved" redirect notice — harmless, push succeeds.

## Architecture (what lives where)
- `server/` package (Flask, port 20016; `proxy_server.py` is now a thin shim
  that re-exports it, so `python proxy_server.py` still works). Modules:
  `app` (app/sock/shared state), `nodes` (ws mesh), `logging_util`
  (`LogTee` -> `logs/server.log` + `crash.log`, `SERVER_INSTANCE_ID`),
  `self_update` (prefers `git pull`, falls back to single-file fetch),
  `parsers_lrc`/`parsers_qrc`/`parsers_ttml`, `providers_lrclib`/
  `providers_yt`/`providers_cubey`/`providers_unison`/`providers_braccato`
  (boidu + binimum direct, no JWT)/`providers_amll` (amlldb word-TTML,
  no key), `translate`
  (Cohere + Google), `metadata`, `cache`, `pipeline` (fast/full fetch),
  `race` (parallel race + SSE helpers), `playlist` (sync job via
  `routes_library` too), `routes_lyrics`,
  `routes_stream`, `routes_admin`, `routes_misc`, `utils`
  (`_safe_cache_component`). Run: `python proxy_server.py` or
  `.venv\Scripts\python -c "from server import main; main()"`.
  DAG: `app`<-everything; providers->parsers/nodes; pipeline/race->
  providers/translate/cache; routes->all, nothing imports routes.
  Dashboard refetch-from-URL feature: `pipeline.probe_providers()` fetches
  EVERY provider independently (Cubey split into inner `Cubey/Musixmatch`,
  `Cubey/QQ`, `Cubey/bLyrics`, `Cubey/BiniLyrics`, `Cubey/NetEase`,
  `Cubey/KuGou` via `fetch_cubey_all`, bLyrics/ttml, QQ, KuGou,
  BiniLyrics/binimum, AMLL (amlldb word-TTML, no key), LRCLib, Unison,
  YouTube) -> candidates best-first,
  nothing excluded; manual rename store in `library.py` (`cache/rename.json`,
  `get_rename`/`save_rename`, custom > saved > fetched); endpoints
  `POST /api/admin/library/probe` {url|video_id, lang, title?, artist?,
  source?} and `/probe/apply` {video_id, lang, source, data, title?, artist?}
  (translate + cache + drop from unlyriced + SSE `rebase`). UI: Library page
  "Refetch from URL" + "Playlist refetch" panels in `templates/index.html`,
  `static/dash.js` (`probeRefetch`, `renderProbeCandidates`,
  `startPlaylistSyncWeb` -> polls `/api/playlist/sync/status/<job_id>`);
  `openPreview(videoId, lang, inlineData)` renders uncached candidates.
- `Source/TranslateLyrics.x`: player hooks, `YTMULyricsViewController`
  (fallback sheet + engagement-panel embed tag 9999), sliding wipe highlight,
  client file cache (`YTMU_LyricsCache`, count+size limits), ELM tap hijack,
  `YTIButtonRenderer` unlock, JWT pre-warm hooks.
- `Source/Prefs/LyricsSettingsController.{h,m}`: own Lyrics System settings
  page (display, cache limits, preview, actions). Integrated as 6th row in
  `YTMUltimateSettingsController` section 1.
- `Source/YTMUTurnstileManager.h`: Turnstile WKWebView -> JWT. Lesson: commit
  `480ec09` replaced the real `/challenge` iframe HTML with a placeholder and
  silently killed all JWT fetching; restored in `dee2c0a`. Never stub this.

## Debugging workflow that works here
- Device: screenshot triggers UI dump POST to `/log`; server saves
  `logs/UI_DUMP_*.txt` + prints analysis (video, `has9999`, `hasEngagement`).
- Dashboard (password-gated): live logs, crash logs, file download, server
  instance chip, self-update card with SHA + parent SHA.
- Video-ID chain: `g_currentVideoID` -> `YTMUResolveCurrentVideoID()` (player
  `currentVideoID`/`contentVideoID`) -> `ActivePlayer:` dump line. If sheet is
  empty, check dump header first.
- Known dump artifacts (NOT bugs): `[Presented] -> YTMULyricsViewController`
  repeated under every VC (container forwards `presentedViewController`);
  `'9999'` substring matches addresses like `0x139999200` — server checks
  `'tag = 9999'`.
- Server log tags per request: `[REQ <id>]`, `[Cache]`, `[Provider]`, `[In-Flight]`.

## Done recently (HEAD -> back)
- parallel probes + outcome tags + prune: `probe_providers` runs all 8
  groups concurrently (Cubey, bLyrics/QQ/KuGou/BiniLyrics, LRCLib, Unison,
  AMLL, YouTube) with live started/found/missed/error/skipped SSE per
  provider; every run records per-provider outcomes (found tier / missed /
  error / skipped) into the candidate snapshot; snapshots prune plain iff
  line/wbw exists (line never pruned by wbw); rerace skips known-miss
  providers with zero network calls. Verified: stubbed parallel run
  (outcomes + save + prune), all-miss snapshot persists, skip leg makes no
  network calls, rerace upgrade still works.
- JWT pool durability: raw tokens persist to cache/jwt.json (survive
  restart/update; hashes only on display); twice-rule eviction (two
  consecutive 401/403s, unknowns never count, probation tokens still serve
  last); richer metadata (successes/fails/last_ok/verdict/last_used) shown
  in the pool table. Verified: persist+reload roundtrip, fail-twice evict,
  ok metadata.
- keep-remix queries: `clean_title_keep_remix` adds a strip-everything-
  except-remix variant (+ raw/raw combo) so remix entries match every probe.
- no-poll dashboard: probe/bulk/playlist/rebase/retitle/page polls all
  replaced by SSE (`bulk_progress` start/row/stage/done added;
  `playlist_sync_progress` + `probe_progress` already existed); heartbeat
  `?interval=` drives server-pushed page refresh; hash-routed tabs
  (#/logs...) with nav hrefs for middle-click; sessionStorage rejoins live
  jobs after reload; bulk has heartbeat + stale-takeover (no more
  perpetual 409); fetch_all gained an on_stage hook so bulk shows
  song + trying-which-provider live; fast `pro` now also covers fast-key
  wbw hits. Verified: node --check, SSE interval endpoint, py_compile.
- provider switcher anytime + no probing popup + server saves all providers:
  iOS header/landscape toolbar now has [<] [list] [name i/n] [>] (steppers
  apply instantly, menu rows show index + current mark, per-video candidate
  cache opens the menu with zero re-probe); probing shows no popup (buttons
  dim while running, menu opens on completion, errors only log). Server
  `candidates.py` persists every full probe snapshot (latest wins,
  translations stripped) from `probe_providers`; rerace upgrades from saved
  snapshots before hitting network; device select serves saved providers
  instantly (translate-to-lang on demand). `fetch_all_lyrics` stages are
  isolated (one provider throw no longer aborts the rest) + same-line wbw
  graft onto a non-wbw winner. Verified: graft y/n cases, save/load
  roundtrip, rerace-from-saved tier upgrade, select-from-saved with
  translation, py_compile + import.
- title/artist reliability: stale landscape title/artist reset on song
  change (old values stuck forever because the refill guard only ran when
  empty); server song/artist captured from every fetch payload as fallback
  between live player data and scraped now-playing labels.
- bg-keyed chrome: all buttons/pills/transport/progress/status/fps colors
  follow blurred-artwork luminance via `YTMULyricFill` + `ytmu_refreshChromeInk`
  (play circle keeps contrasting glyph); lyric cells nudged right (leading
  20->28). TODO(theme) markers filed for the remaining OS-theme followers
  (blur style, modal close button, trait re-theme).
- embed z-order self-heal (`ytmu_assertOnTop`): YT reorders/unhides
  engagement-panel siblings at any time, burying the tag-9999 lyrics view
  after `updateLyrics` put it on top. Helper re-asserts front + hides
  siblings (only while our view is visible, never blanking the panel);
  called throttled ~1/sec from `updatePlaybackTime`, from `viewWillAppear`,
  and from `updateLyrics` (replacing the inline block). Modal sheets are
  UIKit-presented above YT, no-op there.
- instrumental icon rows on iOS + fast-as-final (`pro`) flag: `configureCell`
  renders `isInstrumental`/`[instrumental]`/`[MUSIC] Instrumental` lines as a
  centered note glyph (28pt, active=full ink / idle=dim, no wipe/trans row;
  font+alignment reset in the text branch for reused cells); tap-to-seek and
  the active-line scan fall back to `startTimeMs` (gap rows carry no `time`
  key, previously tap sought to 0). Server tags fast requests served from the
  full cache (or node cache) with transport-only `pro:true` (never persisted;
  fast-only hits untagged so the upgrade fetch still runs); the client caches
  `pro` payloads and skips the redundant full fetch + JWT wait. Verified via
  Flask test client: fast-on-full pro=True, full req untagged,
  fast-on-fast untagged, nothing written to disk.
- album-filter retry in `providers_braccato.py`: boidu treats `al` as a hard
  filter and `get_song_info` album is often wrong (held the artist name for
  Suki/yuri) -> every boidu fetch blanked even on perfect song/artist
  matches. Root-caused live: ttml+album=yuri=None, ttml w/o album=43 wbw
  lines. Now query with album, retry without (`_boidu_query` for
  ttml/qq/kugou, same loop in `fetch_binimum`). Fixes probe AND race/rebase/
  bulk/client paths at once (all funnel through these fetchers). Verified
  live: probe for mIpfco-kC-w now leads bLyrics wbw 2042.53.
- live probe race log: `probe_providers(..., run_id=...)` broadcasts
  `probe_progress` SSE per provider group (started/found/missed/error/
  skipped, fixed shape so future providers just call `report()`); endpoint
  accepts/echoes `run_id`; dashboard `#refetch-live` box streams
  `[OK]/[--]/[FAIL]/[SKIP]/...` lines filtered by run_id. Verified full
  8-group event sequence via captured `_sse_broadcast` (note: `server.app`
  package attr is the Flask object -- patch `sys.modules['server.app']`).
- node relay UTF-8 fix (`node.py handle_task`): `resp.text` guesses
  ISO-8859-1 when lyrics SSE omits charset -> Japanese came back mojibake
  through Cubey-via-node (same bug class as the braccato forced-UTF-8
  comment). Now `content.decode('utf-8')` first, `resp.text` fallback.
  Nodes self-update from the server template, so connected nodes pick it
  up automatically. Probe now returns `notes` (e.g. `Cubey skipped (no JWT
  in pool)`) shown in the refetch meta line, so a missing wbw candidate is
  explained instead of silent.
- bulk refetch-all: `server/bulk_refetch.py` job (admin options scope
  all|non-wbw|unlyriced, mode fresh|rerace, lang, fetch threads, cpu workers,
  translate toggle; never downgrades cache, removes unlyriced on upgrade);
  threads fetch, `server/parse_pool.py` ProcessPool normalizes+scores
  (stdlib-only, spawn-safe; mirrors of cache/race/parsers fns, cross-checked
  by test), `translate.translate_queue_enqueue` silent background queue
  (2 daemon workers, same index-aligned mapping via
  `translate_result_in_place`, also used by `fetch_all_lyrics` now);
  endpoints `POST /api/admin/library/refetch/start` (409 busy),
  `GET .../refetch/status/<job_id>`, `POST .../refetch/stop`; Library page
  "Refetch all (bulk)" panel (segmented scope/mode, workers, translate
  switch, progress + up/kept/failed/tr counters). Verified: mirror==
  canonical, real pool tiers, queue drain + cache rewrite, full job
  (upgrade + no-downgrade-overwrite + 409) via Flask test client.
- `4f2726d` probe isolation: every provider group in `probe_providers`
  catches its own exceptions (was: one Cubey/LRCLib/Unison throw 500d the
  whole refetch-probe click).
- `66b8405` dashboard refetch-from-URL: `pipeline.probe_providers()` (all 8
  providers, best-first, nothing excluded), manual rename store in
  `library.py` (`cache/rename.json`), `POST /api/admin/library/probe` +
  `/probe/apply`, Library page "Refetch from URL" (custom title/artist,
  per-provider Preview/Save) + "Playlist refetch" panels. Verified via Flask
  test client with module-level provider mocks
  (`providers_braccato._DIRECT_FETCHERS[k]`, `providers_lrclib.fetch_lrclib`,
  `providers_unison.fetch_unison`, `providers_yt.fetch_yt_lyrics`,
  `pipeline.fetch_yt_lyrics` + `routes_library.*` fns); copied to
  `tmp/` and deleted after. Lesson: `_extract_video_id` regex is exactly
  11 chars — a 12-char test ID silently got a prefix captured; test with a
  real 11-char ID.
- `2f1be3f` server half of playlist sync (`server/playlist.py`): the iOS
  feature landed in `9ce33ad`; contract `playlist_id`/`lang`/`auto_zh`,
  returns `job_id` + `status_url`, status has `state`/`done`/`total`/
  `found`/`unlyriced`/`error_count`/`current`/`tracks[]` (tag found/
  unlyriced/error/invalid_id), `POST /api/playlist/sync/stop/<job_id>`.
- `5ddef6c` wbw-first rank parity with braccato: Cubey events golyrics
  (bLyrics TTML) + binimum (syllable TTML); new `providers_braccato.py`
  direct boidu (TTML/QRC/LRC) + binimum hunt, raced as its own jobs (pool
  -> 8); `_lyrics_score` applied uniformly in pipeline (plain never beats
  synced, wbw beats all); self-update shim sanity (Flask-free 2KB) fix +
  `_log_crash` import; iOS exact per-word window `[start,start+dur]` floor
  120ms (was 0.1x/1.6x stretch = the lag/jump), cell ptr into
  lastColorKey.
- `25f61d4` mask reveal: CAShapeLayer union of TextKit word rects (real
  per-word timing, wrapped lines OK), normalized spacing via forward-search
  alignment (fixes 5-space karaoke padding), baked text shadow on bright
  overlay, 60-120 frame-rate range, fps/max readout, artwork safety net in
  updateLyrics (broadcast path never loaded bg).
- `5469a4d` FPS probe (volume-down toggles `N fps` readout + `/log` lines,
  `lyricsFpsMeter` setting default ON).
- `3e8fe9b` stuck-empty-sheet fix: fetch watchdog (45s reclaim), status before
  guards (Loading/Waiting), full fetch extracted to helper with 10s JWT
  fallback (nil JWT -> server skips Cubey), no clobber of fast lyrics on full
  failure. Root cause of 11:42 empty sheet: lost JWT callback wedged
  g_globalLoadingInFlight/isLoading, re-taps bailed silently.
- `abd2abd` link fix: `%c(YTMNowPlayingViewController)` runtime lookup
  (a8138d3 used `[.. class]` -> undefined `_OBJC_CLASS_$_` at link).
- `6466e66` AM theme pass: inactive white 0.2, dim translations, 1.04->1
  activation pop at 120fps display link.
- `fc57242` word-run coloring from real per-word timestamps (no geometric
  wipe), fonts 22/15, bg fix on cache hits.
- `3d91ee8` SSE `/api/lyrics/stream`: parallel provider race, raw->machine->
  final stages. Server ranking now wbw-sync (2000+) > line-sync > provider.
- `2af5e15` Apple Music sliding wipe (mask overlay), smaller fonts (20/14),
  header-width fix (was `Relo...eload`), persistent artwork background.
- `eaa04c3` lazy video-ID resolution, empty-sheet guard, `tag = 9999` fix.
- `dee2c0a` Turnstile HTML restore + JWT pre-warm on launch/foreground.
- `058bba0`/`6fbc5c0` client cache + Lyrics System page + warning fixes.

## Open / pending
- Exact ELM lyrics node key: watch server logs for `Lyrics ELM tap key=...`,
  then pin it like `music_download_badge_1`.
- Device was a build behind on wipe overlay — retest on latest build.
- "Translated words on Check for updates" claim: section 4 code is untouched
  since `120e8c1` (verified via diff) — needs a screenshot of that exact row.
- Cell-reuse reset in LyricsSettingsController (icons/colors/fonts leaked
  into lyric rows) + `viewWillAppear` refetch: committed, untested on device.
- Re-tap refresh of already-presented sheet: committed, untested on device.
