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
- `[DONE] ses_ci_fix_20261010 | fixed the shared artwork declaration compile error and made mirror-host rejection non-fatal; Build 291 released successfully | files: Source/YTMUVisualStyle.h, .github/workflows/main.yml | Asia mirror unavailable on 413; GitHub CDN release is live`
- `[DONE] ses_6a1f0c2bd41YQq7XhR3mNzK | FIVE device reads are ONE endpoint, and
  the race route turned out never to save a provider snapshot AT ALL | files:
  server/{routes_stream,routes_lyrics,candidates,pipeline}.py,
  Source/{LyricsSheet,LyricsStream,LyricsCore}.x, Source/LyricsShared.h | next:
  rebuild and look at the provider switcher FIRST — it has been silently empty
  on this route since it existed | does: `/lyrics/song` was redundant because
  `meta` was emitted AFTER the song lookup, so a cache hit came back with no
  title at all (it now goes BEFORE the cache gate, art URLs being a free string
  build); `/providers/candidates` was redundant because the payload lacked
  provider meta; `/check` and `/providers/data` are now `probe=1` and `pdata=1`,
  both cache-only with NO provider traffic, sharing `build_check_payload` /
  `build_provider_data` with the legacy JSON routes. THE BUG: `save_candidates`
  was reachable only from `fetch_all_lyrics` and `_snapshot_provider` was a
  CLOSURE inside it, so the race saved nothing — switcher empty, /providers/data
  found=0, re-race had no known misses; invisible until the phone left the
  blocking route, and my previous commit's "provider meta fixed" claim was
  attaching an empty one. TRAPS: Logos shares no classes across TUs, so the
  probe had to move to LyricsStream.x (where YTMULyricsSSEClient lives) and
  `ytmu_startFullFetchForVideoID:force:from:` had to be declared in
  LyricsShared.h next to the VC methods LyricsStream.x already calls; and a
  block-local `self` from `weakSelf` trips -Wshadow under -Werror (name it `vc`).`
- `[DONE] ses_6a1f0c2bd41YQq7XhR3mNzK | ONE SSE endpoint carries the whole
  song; the device stopped sending \`?fast=1\` and stopped using \`/tstream\` |
  files: server/routes_stream.py, Source/LyricsSheet.x, Source/LyricsStream.x |
  next: rebuild on a device and watch a cold song — plain/line must paint first
  (Unison usually lands ~150ms), then upgrade to wbw in place, then translations
  stream in | does: there were THREE ways to get lyrics and the phone used all
  three. \`?fast=1\` was a deliberately reduced pipeline writing the \`:fast\` key
  nothing else reads, sent FIRST on every song — on a song it missed, pure added
  latency. \`/tstream\` is SSE but runs the pipeline to completion and pushes
  \`lyrics\` ONCE afterwards: it streamed the translation with nothing to stream
  FROM. \`/api/lyrics/stream\` already raced the providers concurrently and
  pushed every improvement as it landed — measured raw/Unison 55 lines 0 wbw →
  raw/AMLL 58 lines 58 wbw → final — and only the BROWSER used it. TRAPS: the
  switch was not a URL change, the race was missing five things tstream had
  (Cubey skipped outright with no \`jwt\` and no pool fallback, \`song_lang\`
  never passed to the translator, no missing-line repair so \`final\` could be
  cached half-translated, \`_record_serve\`+provider meta never attached so usage
  counts and the switcher were empty, no node-cache lookup); and \`tstream=0\`
  pushes \`machine\` then re-pushes the same rows as \`final\`, so the reveal
  and the DISK cache write must both be gated on a stage that will not be
  replaced. tstream kept, marked DEPRECATED, for pre-switch builds only.`
- `[ACTIVE] ses_f033796faffeC32ISpNDwW0STV | UNCOMMITTED work in the tree (Source/LyricsSheet.x, Source/LyricsShared.h): the per-song lyric type size is now FITTED with real TextKit (YTMUVisualLineCount) instead of a character count, the floor dropped 24->18pt, 2 lines max per row, and a rotation re-fits (fittedRowWidth) | files: Source/LyricsSheet.x, Source/LyricsShared.h | next: re-verify that diff, then commit it as its own commit — it is NOT in 9a3d724. TRAPS: only the LONGEST-LAID-OUT line may be fitted (a 40-char Latin line and a 16-char CJK line measure alike, so fitting by string length shrinks a whole song for nothing), wrapping is not linear in the size so the candidate set must be carried down (a line that wrapped at 24pt can stop at 23.5 and then a DIFFERENT line is the worst case), and round() not ceil() on the measured height because TextKit's line-fragment rect carries rounding and a one-line string measures 1.02 lines`
- `[ACTIVE] ses_eff28f66affdILC3ZVe9BGTjCE | extension ported to upstream 3.0.0.4 on branch ytmU-3.0 (+ manual push button); needs a real browser, then a PR | files: better-lyrics src/modules/lyrics/providers/{ytmu,ytmuUpgrade}.ts, src/options/{background,options}.ts, manifest.json; server/routes_admin.py | next: build the extension from ytmU-3.0 and confirm (a) the Sources page shows the key field + toggle + Send current lyrics, (b) a cold song no longer sits on "still searching" for 46s — the provider now resolves empty at 2.5s and the server finishes in the background, (c) a song the server lacks gets pushed back. TRAPS: a provider timeout must record tier -1, not nothing — "never asked" and "the server has nothing" are different states and only the second is fillable; the 2.4.0 ordering put ytmu-PLAIN at priority 2 where it beat every richsynced provider, so the three keys sit inside their own tier now; and 2 of the 54 upstream self-checks (bundle-sizes, ui-guards) fail on a CLEAN 3.0.0.4 tree here, so they are baseline`
- `[DONE] ses_eff28f66affdILC3ZVe9BGTjCE | the extension is a two-way street now: same endpoint as the iOS app, its race upgrades OUR cache, our [instrumental] flag renders | files: server/library.py, server/routes_admin.py, server/routes_library.py, C:/Users/chiuhuang/better-lyrics/src/modules/lyrics/providers/{ytmu,ytmuUpgrade}.ts | next: none — open items: the extension half is committed on better-lyrics `master` (f7229df, still ahead of myfork/master by 2), untested in a real browser; the server half is 5c28795, also unpushed | does: `fast=1` was the whole complaint — it is LRCLib+YouTube+fast Google, no JWT, writes the :fast key while the phone reads the full one, so the browser could be served line/plain for a song we had wbw for. library.apply_lyrics_payload is now the ONE write path for both the dashboard apply and POST /api/lyrics/contribute (key auth, same key as the JWT push, no CORS). require_better=True + tier read AFTER sanitize is the whole safety argument; :fast sibling upgraded too or the phone shows pre-upgrade lyrics for the first seconds. TRAPS: an ABSENT tier record is not -1 (never asked != had nothing, and reading it as empty makes every provider an upgrade); a 401 clears the pushed mark but a refusal does not; and `npm run lint` here reformats 15 unrelated files, so stage only what you touched`
- `[DONE] ses_f033796faffeC32ISpNDwW0STV | karaoke wipe + the cue's own timeline + pinyin behind a switch + the wobble DELETED | files: Source/LyricsSheet.x, Source/LyricsShared.h, Source/LyricsCore.x, Source/Prefs/LyricsSettingsController.m, layout/**/Localizable.strings, server/cache.py, server/candidates.py, server/translate.py | next: rebuild on a device and read the [FPS] log line (it now prints the tick cost: tick=X ms peak=Y ms) | does: the "highlight box" is the wipe label's own DARK layer shadow, clipped by the mask the code deliberately widens by the glow radius — a glow cannot be dark and unclipped at once, so it is the bright ink now (YTMULyricGlow). The fade-out left the mask + radius alive for its 0.5s, which is what the finished line was wearing. The reveal is now a PREFIX by construction: one range per PART (a textless part used to shift every later rect by one), holes filled, boxes trimmed to the previous word. The x-bg cue has its OWN label pair, mask, rect cache and cursor (YTMUWordCursor, shared with the lead so there is one definition of "where are we"), because the payload always carried the cue's parts and the device printed them as static text — and an LRC [bg:] cue has parts on a LINE-synced row, which never reaches the lead's tick at all. Pinyin is behind `lyricsShowRomanization`, default OFF. server/cache.py takes a trailing base（reading） out of the line and out of every part, _PARSER_EPOCH is 4, and the DEVICE cache finally has the matching gate (LyricsCore YTMULyricsCacheParserEpoch) — a parser fix used to be invisible on the phone forever, because its own file was still readable. TRAPS: a mask CLIPS the shadow under it, so a glow drawn under a widened mask MUST be the text's own colour or it is a rectangle; a reveal label must never be `hidden` (layout skips it, bounds stay zero, rects unmeasurable); and THE WOBBLE IS GONE ON PURPOSE — braccato's translateX(0.05em) with its scaleX half already dropped, and a transform makes a layer give up its raster cache, so it re-rendered two full-width CJK labels every frame of every word. Do not port a motion just because the reference engine has it: on CSS it is free on the compositor, here it is the most expensive thing in the tick.`

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
  Streaming translation: ONE SSE route carries the whole song.
  `/api/lyrics/stream` (`routes_stream.api_lyrics_stream`) is the only lyrics
  route the device uses: it races every provider concurrently and pushes
  `lyrics` **every time one beats the current best score**, so
  line-synced -> word-synced -> `final` is one request, not a ladder of calls.
  Measured on `Lixpftlm0Eo`: raw/Unison 55 lines 0 wbw -> raw/AMLL 58 lines
  58 wbw -> final. `tstream=1|0` is the streamed-translation SETTING expressed
  as a query param (Cohere token stream vs Google interim + blocking pass), not
  a second endpoint. `/api/lyrics/tstream` is DEPRECATED and kept only for
  builds predating the switch; it pushed `lyrics` ONCE after the pipeline
  finished, so it streamed the translation with nothing to stream from.
  `?fast=1` on `/api/lyrics` is no longer sent by the device (it is a reduced
  pipeline writing the `:fast` key nothing else reads); the blocking route
  survives only as the stream-died fallback. **FIVE device reads are now ONE
  endpoint**: `/lyrics/song` was redundant because `meta` went out AFTER the
  song lookup (so a cache hit carried no title — it now goes BEFORE the cache
  gate), `/providers/candidates` because the payload lacked provider meta, and
  `/check` + `/providers/data` are modes (`probe=1`, `pdata=1`, both cache-only
  with no provider traffic) whose bodies are `routes_lyrics.build_check_payload`
  and `build_provider_data` — the legacy JSON routes call the same helpers, so
  the tier vocabulary and the provider caps have one definition. TRAPS: the race
  route saved NO provider snapshot at all (`save_candidates` was reachable only
  from `fetch_all_lyrics`, and `_snapshot_provider` was a closure inside it), so
  the switcher, `/providers/data` and the re-race known-misses were all silently
  dead on it — invisible until the phone moved off the blocking route; and
  `client_ver < FORMAT_VERSION` must stay `<`, not `!=`, or a client NEWER than
  the server refetches forever with no way to converge.
  Moving the phone onto the race route was also not a URL change — the race was
  missing five things tstream
  had, each a live defect (Cubey skipped with no `jwt` and no pool fallback,
  `song_lang` never passed to the translator, no missing-line repair so
  `final` could be written to disk half-translated, `_record_serve` and
  provider meta never attached so usage counts and the provider switcher were
  empty, no node-cache lookup); and with `tstream=0` the server pushes
  `machine` then re-pushes the same rows as `final`, so the device gates
  `typewriterLive` AND the on-disk cache write on a stage that will not be
  replaced. SSE bodies without a
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
- `Source/LyricsStream.x`: SSE client for `GET /api/lyrics/stream` (the ONE
  route; `YTMULyricsSSEClient`), the typewriter reveal (per-row state in
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
- **`logs/server.log` is the LOCAL instance only, and it is NOT synced with the
  deployed server.** The better-lyrics extension points at
  `https://ytmtranslate.chiuhuang.dev` (its own host permission + CSP
  `connect-src`), so nothing the browser does shows up in this file — this file
  has the phone, the nodes and the local device traffic only. To read what the
  extension actually asked for, open the DEPLOYED dashboard's log view (that
  host's own `/api/admin/logs`), not this repo. Two `server.log`s, two
  `database/lyrics/` stores, two caches: a fix measured here is not evidence
  about what the browser is served.
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
- `acb9d8a` + `8e1a6eb` — the shared visual header now imports the C-linkage
  artwork API declarations; the build completes when the 110 MB IPA passes
  compile/injection, and a Cloudflare 413 from the optional Asia mirror no
  longer blocks the GitHub CDN release (Build 291). Trap: dynamic mirror URLs
  must use the step output in release expressions, not `env` written later.
- `8e263d8` — the search field now uses the YTM red-accented glass capsule;
  observed search/response controllers get dark text, transparent surfaces,
  rounded image content, and restrained table separators. Trap: the search
  dump shows suggestions but not submitted results, so collection-cell
  separators/cards are intentionally omitted until that hierarchy is logged.
- `9a3d724` — the AltStore source lists the build TWICE (Asia file CDN first,
  Cloudflare-proxied GitHub second; same bundle ID + version, so the second is
  a fallback, not a second app), and the mirror URL survives a restart: the
  webhook writes `database/release_mirror.json` and the GitHub-poll path reads
  it back, with the release body's `- **Asia Mirror** (...)` line as the
  first source. TRAPS: the Asia URL is not derivable (opaque
  `/dl/pub/<uuid>/<hash>`), it lived ONLY in the webhook payload, and the poll
  path hardcoded `asia_url: None` — so every restart silently downgraded
  /api/update and the source to the Cloudflare link; a stored mirror must be
  honoured only for the tag it was stored with (yesterday's URL is a 404), and
  list one host once when both resolve to the same URL.
- `5c28795` + better-lyrics `f7229df` — the extension stopped asking for the
  fast path (no JWT, writes the key the phone never reads) and gained the other
  direction: a win on a strictly better tier is POSTed to `/api/lyrics/contribute`
  with the push key. `[instrumental]` renders as a note because the flag was
  being dropped field-by-field. Traps: an absent tier record is not -1, a 401
  clears the pushed mark but a refusal does not, and `npm run lint` in
  better-lyrics reformats 15 files you did not touch.
- `this session` — the karaoke wipe stopped drawing a black box and stopped
  running backwards, and the phone's own lyrics cache finally respects a parser
  bump. Traps: a mask CLIPS the shadow under it, so widening a mask to let a glow
  escape also widens what that shadow may paint — a dark glow under a mask is a
  hard-edged rectangle, and it has to be the text's own colour; `ranges` is
  indexed by part but was built by skipping textless parts, which shifted every
  rect after one; and a parser fix was invisible on the device forever because
  `cv` (the payload's SHAPE) was the only gate the device had.
- `0ed2a6a` — the JWT pool counts the requests a token really served (the old
  `successes` moved only for probes) and keeps a ledger of retired tokens with
  the reason, so "requests before death" is a fact. Charts on the JWT Pool page.
  Trap: two bookkeeping entry points per HTTP site is how a strike goes missing
  silently, and `el()` used to coerce only string children — a numeric tile value
  was a TypeError that took the page render with it.
- `ba1b0e2` — a Settings page for THIS server, split out of the App page: the
  wbw second Cubey pass is a server-only key that was being rendered inside the
  page promising every switch reaches every device. The schema now carries
  `GROUPS_REMOTE`/`GROUPS_SERVER` and one renderer draws both. New keys:
  `fetch.wbw_retry_delay_s` (float — an int-typed 0.8s default rounds to 1s and
  nobody would notice) and `bulk.*` defaults for a new job.
- `802614b` — the bulk refetch panel stopped answering only "a bulk refetch is
  already running": it now adopts whatever job holds the slot (even one started
  in another tab), shows its progress, and offers Take over. Work runs in
  batches and fetch threads / CPU workers / translate workers / batch size /
  the translate switch are all editable WHILE it runs; the job waits for the
  translate queue to drain before it calls itself done. Traps: the heartbeat
  only fired when a song finished (a stuck job looked dead for 10 minutes), and
  the translate queue's blocking `get()` meant a lowered worker count only took
  effect after the next song.
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
- **The wipe, on a device, with the `[FPS]` line in the log.** The panel has an
  fps counter (`updatePlaybackTime`, Debug page) that logs
  `[FPS] lyric render rate N/M fps` every second — that number is the only honest
  way to judge the frame-rate complaint, and it is per-panel not per-app. On a
  wbw line, in one pass: NO dark rectangle around the sung word or around the
  word that just finished (the glow is now the bright ink); the reveal never
  goes white -> grey -> white; the highlight edge is smooth rather than stepping
  in 24 jumps; and the fps holds. Everything else in this commit is a one-shot
  observable: the provider switcher must not offer the same provider twice (the
  switcher is built straight from the candidates snapshot, and one song offered
  `Unison 1/10 .. 4/10`), the x-bg cue must sit clearly under its line as a small
  dim annotation instead of a third lyric row, and every device cache entry is
  dropped once by the new parser-epoch gate (so the first play of a song refetches
  — that is the fix for a line still printing `ぎゅって抱いた空（ぎゅたて抱いた空）`,
  which was a STALE payload, not a live parse: the current Unison TTML for Cubism
  has no parentheses at all).
- **The landscape active line looks pinned to the top of the column with a dead
  band above it, in every landscape screenshot.** NOT reproduced from the code:
  `ytmu_scrollToRow` targets 37% of the visible height and clamps against
  `adjustedContentInset`, and the dead band above is not the distance ladder
  (rows 1-3 out are 0.88/0.72/0.52 alpha, plainly visible in portrait). Do not
  "fix" it by changing the ratio without a measurement — get the real
  `contentOffset`, `contentSize` and `bounds.height` from a debug line first.
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
