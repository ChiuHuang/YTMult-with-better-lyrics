# AGENTS.md — session handoff for YTMusicUltimate (lyrics system)

> "btw we met 49% context window you can write a agent.md or a prompt for new session
> like how we talk or utf8 encoding error what we've do including this line"
> — user request that created this file. New session: read this first.

## LIVE MISSION (every agent keeps this current — this is live state, not history)
- First action of a session, before any other work: write your own `[ACTIVE]`
  line below. A session that leaves this stale is worse than one that never
  wrote it.
- Update the line the moment the mission changes, not at the end.
- On finishing: flip to `[DONE]` + one outcome line, then move the detail into
  `Done recently`.
- Uncommitted work in the tree means the previous mission was cut off. Treat
  the diff as the mission, re-verify it, and write that down.
- Sanity check before trusting a line: the named files must still carry the
  change (`git diff`, or the symbol must exist). If not, the mission is dead —
  clear it instead of building on it.
- No `[ACTIVE]` mission of your own and nothing in the tree? Ask. Do not
  invent one.
- Format: `[ACTIVE] <session-id> | <one-line mission> | files: <paths> | next: <single action>`
  Keep the whole block under 5 lines. Detail belongs in the sections below.
- **This file stays small.** `Done recently` is a digest of at most ~8
  one-line entries (newest first, commit sha + what + the one trap). Anything
  longer belongs in the commit message, which is already permanent. When you
  add an entry, delete the oldest ones past the cap. Same rule for
  `Open / pending`: only what is genuinely not done.

Current:
- `[DONE] ses_f08ea153affdqh6N7c3mREfQEC | per-build targeted kill switch shipped in 5ecf199 (selector sha/tag/from..to, action lg/tweak/surface, server-side resolution + device census) | files: server/kill_switch.py (new), app_settings.py, routes_misc.py, routes_admin.py, static/dash.js, templates/index.html, Source/LyricsCore.x, Source/YTMULiquidGlassPreferences.h, docs/settings-api.md, .gitignore | next: none — open items: never exercised on a device (the sha it reports is TWEAK_GIT_COMMIT, which only a real install has), and the dashboard panel has no browser screenshot | does: 4 python suites green (unit / Flask test-client / real-repo git timing / live server over a socket), 39/39 + 18/18 logos+clang syntax, node --check`

## How we talk (user expectations — keep these)
- Reply in Traditional Chinese, Taiwan usage (繁體中文／台灣用語). The user reads
  and writes English casually but asked for zh-TW replies; this is a standing
  preference, not a one-turn thing, and the user has said to keep it here after
  one edit to this file dropped it. Code, identifiers, commit messages, log
  lines and AGENTS.md itself stay English — only the conversation is zh-TW.
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
  files only — still keep LF/no-BOM everywhere. Exception: the 14
  `*.lproj/Localizable.strings` files are UTF-8 no-BOM **CRLF** — match the
  file you are editing.
- Bulk emoji replacement once corrupted every `?` ternary and `&` URL into
  `[WAIT]` and broke the iOS build. After any bulk replace: re-check `?`, `&`,
  run `py_compile`, and diff.
- THEOS/CLANG LIVE IN WSL, not on Windows: `/home/chiuhuang/theos` with
  `sdks/iPhoneOS16.5.sdk` and `bin/logos.pl`. `Makefile` on the Windows side is
  never used locally; CI builds the tweak. A local syntax-only pass over all 39
  `.x/.xm` is the cheapest way to catch what CI will only report one file at a
  time — see `tmp/synall4.sh` (harness lives in
  `%LOCALAPPDATA%\Temp\opencode\synall4.sh`, stubs in `...\opencode\stub\`).
  Trap baked into it: theos gives each TU its OWN file's directory plus
  `Source/`, never `Source/Headers` as a bare `-I`, so a header inside it must
  be reached as `"Headers/Foo.h"` — adding `-ISource/Headers` silently hides a
  real fatal error (that was `fba8e3e`).

## iOS/Logos specifics
- Theos build uses `-Werror`: unused `static` C functions fail the build — mark
  helpers `__attribute__((unused))`. ObjC methods are exempt.
- `return %orig;` is valid in void hooks (see Downloading.x pattern).
- `git push` prints "repository moved" redirect notice — harmless, push succeeds.
- Logos/C classes that have actually shipped broken and are now fixed — the
  pattern is the same every time, so check the shape before writing more:
  a `static BOOL x = f();` file-scope initializer is not a constant expression
  and cannot initialize static storage (make it a function, which also reads
  the pref live); `static const void *k = &k` seeds an associated-object key
  from its own address, so back the key with a `static char` and take *its*
  address; `(__bridge void*)someCGImage` is wrong because a `CGImageRef` is not
  an Objective-C object; `[x = foo()]` is not a message send; `CGRect` has no
  `.minX`/`.maxY` members in C (use `CGRectGetMinX`); `self.opaque` on a
  `UIViewController` hook does not compile; `%hook` inside a macro cannot work,
  hook the class list at runtime; cast `IMP` to `const void *` when boxing an
  original.

## Architecture (what lives where)
- `server/` package (Flask, port 20016; `proxy_server.py` is a thin shim that
  re-exports it, so `python proxy_server.py` still works). Modules: `app`
  (app/sock/shared state), `nodes` (ws mesh), `logging_util` (`LogTee` ->
  `logs/server.log` + `crash.log`, `SERVER_INSTANCE_ID`, `_classify_log` —
  new tags must be registered BEFORE the `'[REQ'` test), `self_update`
  (prefers `git pull`, falls back to single-file fetch),
  `parsers_lrc`/`parsers_qrc`/`parsers_ttml`, `providers_lrclib`/
  `providers_yt`/`providers_cubey`/`providers_unison`/`providers_braccato`
  (boidu + binimum direct, no JWT)/`providers_amll` (amlldb word-TTML, no key),
  `translate` (Cohere + Google, `translate_stream`), `metadata`, `cache`
  (keys `"vid:lang"` / `"vid:lang:fast"`), `paths`, `pipeline` (fast/full
  fetch, `probe_providers`), `race` (parallel race + `_maybe_cubey_second_pass`),
  `rerace`, `bulk_refetch`, `parse_pool`, `playlist`, `library`,
  `routes_lyrics`, `routes_stream`, `routes_admin`, `routes_library`,
  `routes_misc`, `utils`, `jwt_push` (key-authed `POST /api/jwt/push` for the
  browser userscript). Run: `python proxy_server.py` or
  `.venv\Scripts\python -c "from server import main; main()"`.
  DAG: `app`<-everything; providers->parsers/nodes; pipeline/race->
  providers/translate/cache; routes->all, nothing imports routes.
  Persistent state is `database/` (renamed from `cache/`, gitignored; only the
  parser epoch + format version in `paths.py` decide the sweep, they are
  separate numbers on purpose).
  Node mesh (`nodes.py`) is PULL-ONLY for lyrics cache
  (`ask_nodes_for_cache` on a disk miss) — the server does NOT push
  `cache/lyrics` down, so a node only holds what it fetched itself. The one
  push that remains is the Cubey JWT pool: `_push_jwt_sync` on connect + a 60s
  tick gated by a sha256 over the token set, per-node opt-out via
  `"jwt_sync": false` in `config/nodes.json` (a clickable `jwt on/off` pill,
  `POST /api/admin/nodes/<id>/jwt_sync`). A node stores it in
  `node_cache/jwt.json`, answers `jwt_get`, and `jwt_pool._top_up_from_nodes`
  pulls one back only when `pick_jwt()` would be None. `config/nodes.json` is
  gitignored (it holds every node's `key_hash`) and every writer goes through
  `_mutate_nodes(mutator)` — one lock, a fresh read, atomic `tmp`+`os.replace`;
  never load-edit-save by hand.
  Streaming translation: `translate.translate_stream` is the generator,
  `routes_stream._stream_translate` runs it on a worker thread and drains it
  into SSE, the device reads `GET /api/lyrics/tstream`. `/api/lyrics/stream` is
  the older provider-race endpoint and shares the helper. SSE bodies without a
  charset decode as ISO-8859-1 — force `resp.encoding = 'utf-8'` before
  parsing, and treat `data: [DONE]` as non-JSON.
  Dashboard refetch-from-URL: `pipeline.probe_providers()` fetches EVERY
  provider independently (Cubey split into `Cubey/Musixmatch`, `Cubey/QQ`,
  `Cubey/bLyrics`, `Cubey/BiniLyrics`, `Cubey/NetEase`, `Cubey/KuGou` via
  `fetch_cubey_all`, bLyrics/ttml, QQ, KuGou, BiniLyrics/binimum, AMLL, LRCLib,
  Unison, YouTube) -> candidates best-first, nothing excluded, each group
  catching its own exceptions; manual rename store in `library.py`
  (`database/rename.json`, `get_rename`/`save_rename`, custom > saved > fetched);
  endpoints `POST /api/admin/library/probe` {url|video_id, lang, title?, artist?,
  source?} and `/probe/apply` {video_id, lang, source, data, title?, artist?}.
  UI: Library page "Refetch from URL" + "Playlist refetch" panels in
  `templates/index.html`, `static/dash.js` (`probeRefetch`,
  `renderProbeCandidates`, `startPlaylistSyncWeb`). All dashboard progress is
  SSE, never polling (`probe_progress`, `bulk_progress`,
  `playlist_sync_progress`, heartbeat `?interval=`).
- `Source/TranslateLyrics.x`: player hooks, `YTMULyricsViewController`
  (fallback sheet + engagement-panel embed tag 9999), sliding wipe highlight,
  client file cache (`YTMU_LyricsCache`), ELM tap hijack, `YTIButtonRenderer`
  unlock, JWT pre-warm hooks.
- `Source/LyricsStream.x`: SSE client for `GET /api/lyrics/tstream`
  (`YTMULyricsSSEClient`), the typewriter reveal (per-row state in
  `typeState`/`typeRows`, `CAGradientLayer` mask on `transLabel`, driven from
  `updatePlaybackTime`), the stream event handlers and `YTMUDebugStreamStatus()`.
  The VC's stream/type methods are declared in `LyricsShared.h` (Logos does not
  see `%new`/category helpers from another .x, and a category cannot synthesize
  the property ivars it needs — the lazy `ytmu_typeStates` / `ytmu_typeRowSet`
  accessors exist for that reason). The tick wiring is three lines and is easy
  to lose: `ytmu_typeRow:activate:NO` per deactivated row, `:YES` per activated
  row, and `ytmu_typeStep` as the LAST statement of `updatePlaybackTime`.
  `typewriterLive` (default NO) gates the reveal so a cache hit always paints
  whole; server tags every response `cached:true|false` for exactly this.
- `Source/Prefs/LyricsSettingsController.{h,m}`: Lyrics System settings page
  (display, cache limits, preview, actions), 6th row of
  `YTMUltimateSettingsController` section 1.
- `Source/Prefs/DebugSettingsController.{h,m}`: Debug page (7th row) — live
  streaming-translation status from `YTMUDebugStreamStatus()` on a 1s timer,
  log level, debug-upload switches, copy-diagnostics, send-test-log.
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
- Server log tags per request: `[REQ <id>]`, `[Cache]`, `[Provider]`,
  `[In-Flight]`, `[PRECACHE]`, `[wbw-retry]`.
- Test scripts live in `tmp/` (gitignored). Drive the REAL function with
  providers stubbed rather than a reimplementation. Two traps that cost hours:
  a function that imports its dependency INSIDE its body (`set_cached`,
  `pick_jwt`) ignores a patch on the caller module — patch the defining module
  too, or the test writes to the real `database/`; and a test that asserts on
  real data needs real fixtures (`_extract_video_id` is exactly 11 chars).

## Done recently (digest — details are in the commit messages, `git show <sha>`)
- `5ecf199` — the kill switch targets a build, not every device: selector
  `sha | tag | from_sha..to_sha | blanket`, action `lg | tweak | surface`,
  resolved server-side from the `?sha=` the device already sends, plus a census
  of devices per build taken from that same poll. New remote key `ui.tweak`.
  Trap: `git for-each-ref` does NOT expand `%x1f` (it emits the six characters
  verbatim, so the tag list parsed as one field and 184 tags became 0 with no
  error) — use `%00`. Second trap: the `unknown` sha sentinel is a word, so
  prefix-matching let a target for the sha `unk` capture every such device.
- `c19d3bd`/`216b512` — the lyrics parsers learn what the format actually
  defines: TTML `ttm:role` (`x-bg` becomes its own row instead of a karaoke
  word of the vocal line), `x-roman`, `tts:ruby`, `amll:obscene`/`empty-beat`,
  both sidecar dialects, agent NAMES, a `<p>` with no `begin`, and spacing read
  from the real text nodes; LRC `[bg:]`; QRC `Name:` singer prefixes (the duet
  feature had zero data), the `LyricContent=` envelope and the title-echo drop;
  `server/parsers_credits.py` (CJK credit roles, shared). Epoch 1 -> 3. Trap: the
  device rebuilds the display string from `parts`, so unwrapping only the
  parser's `text` leaves the source's brackets on screen.
- `7dac3ed` — latency percentiles (`server/latency_stats.py`): p50/p95/p99 for
  time per song, time to line-sync and time to wbw, as three cards on the
  Overview page. Samples are recorded in `fetch_all_lyrics` (so every caller
  counts, not just one route), nearest-rank (never interpolated), misses are
  their own population and stay OUT of `song`, and a wbw hit never stamps
  `ttf_line` — otherwise the line-sync number inherits the slow path. Trap the
  widget test caught: the server sends a metric with no samples as `null` and the
  table read `m.n` straight off it.
- `fba8e3e`/`b4a9238`/`b3158d8` — five source files had NEVER compiled (CI
  reports only the first fatal error, so each fix revealed the next). The WSL
  logos.pl + `clang -fsyntax-only` pass finds them all at once: 39/39 clean.
- `443843d` — a song with no word-by-word lyrics now gets a real second Cubey
  pass on EVERY Cubey caller (`_maybe_cubey_second_pass`), 0.8s apart and with a
  rotated token. A repeat of the same JWT in the same millisecond is not a retry.
- `f4d758c` — the auto-sync push had not compiled since `9ce4a26`.
- `11bb42e`/`9ce4a26` — parser epoch split from format version, and the node
  mesh no longer defeats the version gate.
- `ac9ca4e` — duet lines get a setting (align / label / off).
- `c729dbb`/`5f2e396`/`19c5d2c` — ttml: `ttm:agent` singer + section kept, no
  invented spaces, `<text for>` is the line text.
- `6df5a58` — retitle batches 20 songs per LLM call, no-ops skip the pipeline.
- `ef25ad8`/`a31e8c8` — `tools/jwt-uploader/`: Chrome extension + silent
  userscript + key-authed `POST /api/jwt/push` (no CORS headers on purpose, so
  a random page cannot make a browser send it).

## Open / pending
- **The parser audit: TTML + LRC + QRC + credits are DONE (`216b512`,
  `c19d3bd`); SRT and the device's ruby/obscene are open.**
  `docs/parser-feature-audit.md` is tracked and carries a Status table.
  `parse_ttml_basic` dispatches on `ttm:role` instead of `p.iter('span')`, so
  `x-bg` becomes `entry['bg']` instead of a karaoke word of the vocal line; also
  `x-translation`, `x-roman`, `tts:ruby`, `amll:obscene`, `amll:empty-beat`,
  both sidecar dialects, `ttm:agent` NAMES, `itunes:song-part` (kebab), a `<p>`
  with no `begin`, and inter-word spacing read from the real text nodes instead
  of the `has_gap`/`is_cjk` guess. LRC learned the LySy `[bg:]` group and drops
  CJK credit lines. QRC learned the `Name:` singer prefix (the duet feature had
  ZERO data for it), the `<QrcInfos LyricContent=...>` envelope and the title-echo
  drop. `server/parsers_credits.py` is a port of braccato's `credits.ts`, shared
  by both. `_PARSER_EPOCH` is 3, so every TTML/LRC/QRC entry is parser-stale and
  wants a refetch. Bugs found and fixed along the way, not feature gaps: an
  undeclared `tts:`/`itunes:` prefix made ElementTree raise and the `except`
  returned None, losing the WHOLE file; every `<text for>` was treated as the
  line text, so an Apple file with an English `<translations>` block had its
  lyrics REPLACED BY THE TRANSLATION (`xml:lang` is the separator, §8.1); and
  x-bg unwrapped only the cue's text, not its PARTS, while the device rebuilds
  the display string from parts. Still open: SRT (a format we do not have),
  `amll:meta` song metadata, songwriters, and the device's ruby-over-the-syllable
  + obscure handling. §6 lists what we do differently on purpose.
- **Device rebuild outstanding** (all CODE-DONE, never run on a device):
  rebuild `client_edits_pack.py` and check, in one pass: the single X in all
  four panel configurations; landscape->portrait CLOSES the fullscreen lyrics
  and does not pop back a second later; closing in landscape leaves NOTHING
  lyrics-shaped on screen; rotating back to landscape re-opens it on its own;
  turning `lyricsFullscreenAutoOpen` off while it is up closes it and stops the
  next rotation; face-up in landscape must not flap open/closed; the `♪`
  appearing and collapsing; art + title switching on the next song; the
  retranslate button; the typewriter on two lines; the wider gutters; the new
  ink tint; `[PRECACHE]` lines in the dashboard log (precache has still never
  fired on a device); and the stream path — a song with no server cache types
  its translations in, the Debug page goes `opening` -> `done`, the cps slider
  moves the rate without a respring, and a song change mid-translation leaves
  no half-typed row.
- **Whole-app tint**: if the home tab is still black with a tinted full player,
  the 24pt floor in `YTMUPublishTheme` did not fix it — the next suspect is an
  opaque sibling over `YTMContentViewController.view` (tab bar, mini-player
  container; `HomeLiquidGlassV2.xm` already clears `YTMBrowseContainerView` and
  its scroll views and shelf cells).
- **Queue walk fragility**: it probes YT selectors by name. If a YT update
  renames them all, precache degrades to a no-op again; the one-shot
  `[PRECACHE] queue walk found no up-next list` line is the signal to add one. A
  probed accessor returning a SCALAR would crash before the `isKindOfClass:`
  check can reject it.
- Exact ELM lyrics node key: watch server logs for `Lyrics ELM tap key=...`,
  then pin it like `music_download_badge_1`.
- "Translated words on Check for updates" claim: section 4 code is untouched
  since `120e8c1` (verified via diff) — needs a screenshot of that exact row.
- Cell-reuse reset in LyricsSettingsController (icons/colors/fonts leaked into
  lyric rows) + `viewWillAppear` refetch: committed, untested on device.
- Re-tap refresh of an already-presented sheet: committed, untested on device.
- Pre-existing, untouched: ar/ja/ru/th/vi `SB_LYRICS_OFFSET{,_DESC}` are still
  fully English, ja has 4 untranslated tab-bar keys, and
  `server/egress.py` is still a stub.
