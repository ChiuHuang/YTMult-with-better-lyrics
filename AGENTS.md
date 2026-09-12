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
- `proxy_server.py` (Flask, port 20016): LRCLIB / Unison / YouTube / Cubey(JWT)
  providers, Cohere + Google translate, file caches, admin dashboard
  (`templates/index.html`), `LogTee` -> `logs/server.log` + `crash.log`,
  `SERVER_INSTANCE_ID` (uuid4 per start), self-update endpoints
  (`/api/admin/self_update/*`, supports `app.py`/`main.py`/`bot.py` via
  `admin_config["main_file"]` or `MAIN_FILE` env), UI_DUMP analysis.
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
