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
  (`_safe_cache_component`), `jwt_push` (key-authed `POST /api/jwt/push` for
  the browser userscript). Run: `python proxy_server.py` or
  `.venv\Scripts\python -c "from server import main; main()"`.
  DAG: `app`<-everything; providers->parsers/nodes; pipeline/race->
  providers/translate/cache; routes->all, nothing imports routes. Node mesh
  (`nodes.py`) is PULL-ONLY for lyrics cache (`ask_nodes_for_cache` on a disk
  miss: routes_lyrics 316/731, routes_stream 231, playlist 85) -- the server
  does NOT push `cache/lyrics` down anymore, so a node only holds what it
  fetched itself. The one push that remains is the Cubey JWT pool:
  `_push_jwt_sync` (`jwt_sync` message) on connect + a 60s tick that re-pushes
  only when the token-set signature changes, per-node opt-out via
  `"jwt_sync": false` in `config/nodes.json` (shown as a clickable `jwt on/off`
  pill in the dashboard node row, `POST /api/admin/nodes/<id>/jwt_sync`).
  Node side stores it in `node_cache/jwt.json` and answers `jwt_get`;
  `jwt_pool._top_up_from_nodes` pulls one in from `_check_loop` when the pool
  has no live token, so a node holding a token can rescue an empty pool. A
  node already saw raw tokens via `relay_http_request` (the Cubey probe posts
  the token in the body), so this is the same exposure, not a new one.
  Streaming translation: `translate.translate_stream` is the generator,
  `routes_stream._stream_translate` runs it on a worker thread and drains it
  into SSE, and the device reads `GET /api/lyrics/tstream` (its full-fetch
  path). `/api/lyrics/stream` is the older provider-race endpoint and shares
  the same helper. `routes_stream` imports `fetch_all_lyrics`,
  `ask_nodes_for_cache`, `is_not_found_result` and `_log_crash` at module
  level, and `_provider_meta` lazily from `routes_lyrics` (routes_lyrics is
  imported first in `server/__init__.py`, so that direction is safe).
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
- `Source/LyricsStream.x`: SSE client for `GET /api/lyrics/tstream`
  (`YTMULyricsSSEClient`), the typewriter reveal (per-row state in
  `typeState`/`typeRows`, gradient mask on `transLabel`, driven from
  `updatePlaybackTime`), the stream event handlers and
  `YTMUDebugStreamStatus()`. The VC's stream/type methods are declared in
  `LyricsShared.h` (Logos does not see `%new`/category helpers from another
  .x, and a category cannot synthesize the property ivars it needs -- the lazy
  `ytmu_typeStates` / `ytmu_typeRowSet` accessors exist for that reason).
- `Source/Prefs/LyricsSettingsController.{h,m}`: own Lyrics System settings
  page (display, cache limits, preview, actions). Integrated as 6th row in
  `YTMUltimateSettingsController` section 1.
- `Source/Prefs/DebugSettingsController.{h,m}`: Debug page (7th row of
  `YTMUltimateSettingsController` section 1) holding everything about
  diagnostics: live streaming-translation status read from
  `YTMUDebugStreamStatus()` on a 1s timer, the log level segment and the
  debug-upload switches (moved out of the lyrics page), copy-diagnostics and
  send-test-log actions. New settings strings live in all 14
  `layout/Library/Application Support/YTMusicUltimate.bundle/*.lproj/Localizable.strings`
  (the .strings files are UTF-8 no-BOM **CRLF**, unlike the rest of the
  repo -- match the file you are editing; untranslated languages get the
  English source string as a placeholder, that is the project convention).
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
- **the retitle job: one LLM call per SONG, and a provider race even when
  the retitle changed nothing** (user pasted 101/205 rows of the Retitling
  dialog and asked "is this retitle ragebait? and we can put many songs in
  one call not one song one call". It was). Read the log, it is a page of
  `old == new` + red `retitled_no_lyrics`: `routes_library._run_retitle`
  had no no-op guard, so a clean title still cost a Cohere call AND a full
  8-provider race, then reported the miss as "retitled" -- while
  `library._try_llm_retitle_fetch` 200 lines away HAS the guard
  (`if new_song == song and new_artist == artist: return None`). dash.js
  paints `retitled_no_lyrics` red (`rb-failed`), so ~95 unavoidable
  misses read as ~95 failures. Batching: `library.retitle_batch(pairs)`
  sends 20 pairs per call (`YTMU_RETITLE_BATCH`, 2 chunks in flight) and
  writes into the same `_retitled_cache` that `retitle_song` reads, so the
  worker pool's per-row call becomes a dict hit -- 205 songs, 11 calls.
  A job clears that cache first (`retitle_cache_clear`) or a re-run after a
  prompt change replays process-lifetime wording. An unusable chunk falls
  back to REGEX ONLY: the per-song retry turned one API outage into 205
  more failing calls and a wall of log lines. Also in the job: a no-op
  returns `retitled_noop` without touching the pipeline; an existing cache
  entry is only overwritten when `_tier(result) > _tier(old)` (the rebase
  rule -- `fetch_all_lyrics` stamps the retitled pair onto the result at
  `pipeline.py:411`, so the old code both renamed AND downgraded); and
  `get_rename`/`save_rename` are honored, so a manual rename wins and the
  LLM's answer is what later reads see. `retitle_reject_reason()` rejects
  what actually reached the cache -- channel handle as the title with the
  real artist as the handle (`EmoCosine - EmoCosine`, `Chenomio -
  Chenomio`, `Camellia - Camellia`), swapped fields, implausible growth. It
  deliberately does NOT reject a short title: `喵~ - Sān-Z & HOYO-MiX` ->
  `喵~` is CORRECT, so a length heuristic there loses more than it saves
  (I wrote one, it rejected the fake test data, I deleted it -- `照` from
  `《絕區零》照EP｜Tiny Giant` stays unfixed and is 1 row in 101). Two
  regex bugs the log exposed: the noise patterns substituted `''` while
  consuming the closing bracket, so `TIME(Cover)Kobo` -> `TIMEKobo`; and
  the `-`/`/` split took `parts[0]` unconditionally, deleting the subtitle
  whenever an artist was already present (`PHD / 重音テトSV` -> `PHD`).
  Now a space is substituted, empty bracket pairs are dropped, and the
  tail is only taken when the artist is actually adopted. Verified with
  `tmp/test_retitle_batch.py` (42) + `tmp/test_retitle_job.py` (17), both
  driving the real functions against a fake Cohere/pipeline. TRAP worth
  keeping: `_run_retitle` does `from .cache import set_cached` INSIDE the
  function, so patching `routes_library.set_cached` is not enough -- the
  test writes to `cache/lyrics` until you patch `server.cache` too. Both
  tests also had wrong EXPECTATIONS before they had bugs: two of the log's
  "garbage" rows (`OMG (Bossa Remix) - NewJeans`, `Starlight - Zenless
  Zone Zero`) are the correct answer, and a manual rename that differs
  from the stored title is a real retitle, not a no-op.
- **a browser JWT uploader, because "get a JWT into the pool" was a dashboard
  prompt and a device-only flow** (user: "write me a chrome extention or user
  script to upload jwt anytime", then "can you just inject in site? or
  userscript? dont make it user noticeable"). `tools/jwt-uploader/`, TWO
  front ends and ONE new server route. The extension drives the endpoint that
  already existed (`routes_admin.py:420`, `node_id: chrome-ext` so the
  dashboard shows where a token came from); the userscript cannot, see below.
  Extension flow: a background tab on
  `lyrics.api.dacubeking.com/challenge` -> `challenge.js` catches the
  Turnstile response TWO ways (the page's own
  `postMessage({type:'turnstile-token'})`, which works at top level because
  `window.parent === window`, and a poll of the hidden
  `input[name=cf-turnstile-response]`, which covers a message that fires before
  the content script is injected) -> the worker POSTs `/verify-turnstile`, takes
  `jwt` or `jwtToken` -> `POST /api/admin/jwt/contribute`. Triggers: the popup
  button, `alt+shift+j` from any page, an optional `chrome.alarms` timer (off by
  default), and the "anytime" one -- a challenge the user solved in their OWN
  tab uploads with no click at all (`onTurnstileToken` starts a run when no job
  is pending). Two structural traps: run state lives in
  `chrome.storage.local` and not in a promise, because an MV3 worker is killed
  while a challenge sits open and the token message can arrive long after the
  popup closed; and the timeout is an alarm that re-arms for the remainder,
  because Chrome may fire an alarm earlier than asked. The auth trap is the
  reason there are two request paths at all: the admin endpoints need a Flask
  session cookie, that cookie is written with no `SameSite` so browsers treat
  it as `Lax`, and a cross-site POST from the extension arrives WITHOUT it.
  So every call goes out from the worker first (host_permissions bypass CORS)
  and, if the answer is the login page, is re-run by
  `chrome.scripting.executeScript` inside a tab already on the server origin --
  an ordinary same-origin request, cookie included. That tab path is why one
  manual dashboard login is the entire setup, and `via extension` / `via tab` in
  the log says which one ran. An injected `func` is serialized into the page,
  so `inPageCall` MUST be self-contained: it began by calling this file's
  `pathOf`/`isHtml` and would have died on a ReferenceError, caught by its own
  try/catch and reported as "could not run the request in tab N". The JWT is
  never written to storage (only `len`, the first 8 chars and `exp`).
  The SILENT half is `ytmu-jwt-push.user.js` in the same folder, which is what
  the user actually asked for: no popup, no badge, no notification, no DOM
  change, no console output (one `console.warn`, ever, and only on a real
  failure). Same two token paths, but there the hidden-input poll is the
  load-bearing one, because a FRAMED challenge page posts to its PARENT and
  the message never arrives inside the frame -- which is also what lets
  `CONFIG.auto`'s hidden 2x2px iframe work with no visible tab at all
  (best effort: Cloudflare may refuse a frame that is effectively invisible).
  A userscript cannot use the admin endpoint at all, so `server/jwt_push.py`
  adds `POST /api/jwt/push`: 32 bytes of hex in `config/admin_config.json`
  (`jwt_push_key`, created on the first `GET /api/admin/jwt/push_key`, which is
  what the dashboard's new "Copy push key" button calls), compared with
  `hmac.compare_digest`, and deliberately NO CORS headers and no preflight
  answer -- requiring the `X-YTMU-Key` header is precisely what stops a random
  web page from making a browser send it, because such a request needs a
  preflight this server never answers. Trust level equals a node key's (a node
  already contributes tokens over the websocket), and the key is deliberately
  NOT in `app_settings.json`, whose read endpoint is public.
  Verified, and the checks are worth copying: `compileall` over `server/`,
  `node --check` on all four JS files, and 24 Flask-test-client checks on
  `/api/jwt/push` (401 for no/wrong/empty/non-ASCII key, 302 to /login on
  `/api/admin/jwt/push_key` with no session, 400 under 20 chars, 200 at exactly
  20, `Cache-Control: no-store`, no `Access-Control-Allow-Origin`, key also
  accepted in the body, `node_id` = the source sent, a repeat returning the same
  id without growing the pool) with every entry it created removed again, so
  the pool ended byte-identical. The test lives at `tmp/test_jwt_push.py`
  (gitignored, self-cleaning, unique token per run) and it CAUGHT two bugs in
  itself before it caught anything real: a 21-char "short" token that the
  `< 20` rule correctly accepted, and an entry that leaked into the pool. The
  one real bug it could not have found was in the userscript, and `node --check`
  found it immediately: the setup prose was a `/* ... */` block that CONTAINED
  the string `@match *://*/*`, so the `*/` in that glob terminated the comment
  early and the rest of the prose was parsed as JavaScript. The userscript would
  not have run at all. Watch for a glob inside a block comment in any script
  with a metadata block. Also worth knowing: the `shell` tool is NOT listed in
  the agent's tool inventory but exists and works -- `search()` inside
  `execute` cannot see it, and the Code Mode runtime is not Node (`process`,
  `require`, `globalThis` and `import()` are all absent), so "I have no shell"
  is a wrong conclusion twice over.
  Still unverified: nothing has run in a real browser. The Turnstile half (both
  token paths, and whether Cloudflare solves the widget in the `CONFIG.auto`
  2x2px frame) needs the userscript installed and
  `https://lyrics.api.dacubeking.com/challenge` opened once, with `DEBUG` on
  for the console trace.
- **the node deletes itself** (user pasted 20+ `[NODE] rejected connection for
  node_id=... (bad key)` lines and asked "why node delete itself?"). Nothing
  deletes a node: the server has no record for that `node_id`, because every
  writer of `config/nodes.json` did load -> edit -> save with NO lock and NO
  re-read, so the last writer won on stale data. The offender that made it
  permanent is the `pong` branch of `ws_node` (`server/nodes.py`): it kept the
  dict it loaded once at connect time and rewrote the WHOLE file from it every
  30s, forever. Consequences, both reproduced: a node generated in the
  dashboard was erased from disk within 30s and stayed erased (so the node.py
  just handed out got `(bad key)` on every reconnect -- exactly the pasted
  log, and the "it deleted itself" feeling, since the row vanishes from the
  Nodes page a minute after generating it), and `revoke` deleted a record only
  for the next pong to write it back. Compounding it, `_save_nodes` truncated
  before writing, so a reader could parse a half-written file, get `{}` from
  `_load_nodes`, and persist an empty registry. Fix: one `_nodes_file_lock`
  around the whole read-modify-write plus a fresh read on every write
  (`_mutate_nodes(mutator)`, mutator returns False to abort without writing),
  an atomic `tmp` + `os.replace` save, and the pong now stamps only its own
  record instead of the connect-time snapshot. Every call site converted
  (`ws_node` connect + pong, `admin_nodes_generate`, `admin_nodes_regenerate`,
  `admin_nodes_jwt_sync`, `admin_nodes_revoke`). Note the two halves are both
  needed: the lock alone still lets a stale in-hand dict clobber the file, and
  atomicity alone still loses the update. Recovery is NOT possible server-side
  -- only a `key_hash` is stored, never the key -- so any node.py that is
  already being rejected has to be re-generated and re-deployed. Verified: a
  repro of the old behaviour, then 7 checks against the fix (5 threads
  hammering the registry, revoke surviving 50 pongs, jwt_sync toggle
  surviving, abort-on-False writing nothing, an unknown id never being
  resurrected, 600 interleaved reads with zero truncated parses and no stray
  `.tmp`, a fresh node's key still validating after 60 pongs) and the Flask
  test client end to end (3 generates with 20 pongs between each: all three
  records present with a matching hash, and the keyed self-update fetch
  returning 200).

- **the translated-lyrics echo bug** (user: "allow to fix broken
  translate(lyrics)", with a rendered row reading "Every single morning
  ((Huh) （哈）每一個清晨"). NOT a display bug: the panel is two labels in one
  cell and nothing joins them, so the STRING was wrong. The guard in
  `server/translate.py` was `orig in trans` -- whole-line containment. It
  caught the full echo, retried once, then took the retry ON FAITH with no
  second check, so an echo survived into `cache/translate/` permanently; and
  it MISSED the more common PARTIAL echo (clause kept, trailing vocal cue
  dropped), which a whole-line test cannot see. Fixed at four points, each
  because the other alone leaks: `_echoes_original` compares leading words
  (`_leading_echo_fraction`, bar 0.75 so a kept proper noun like "BITE!" is
  spared) with `_strip_echo_prefix` to salvage the tail; the retry is
  re-checked in BOTH the blocking and stream paths; the stream path repairs
  BEFORE yielding the delta (the client paints each delta as it arrives, so a
  post-hoc fix is already on screen -- that is literally how the user watched
  the original repeat); and the cache-read sanitiser now runs on the Cohere
  AND Google paths with `apply_display_transforms` as the last-chance repair
  (covers entries persisted before the fix). The blocking path also stopped
  caching a run that translated nothing. Device: row gap 6 -> 10pt (at 0.68x
  the two labels read as one string) and the auto font shrink now measures the
  translation on the scale it is drawn at. TRAPS: `_WORD_SPLIT` must NOT
  include the parens -- splitting them made "((Huh)" three empty fragments,
  reached the cue-only branch never, and shifted every index; and a
  cue-only original must keep containment while a ONE-WORD original must not,
  which is the only thing separating a vocal cue from a kept proper noun.
  Verified by driving the real `cohere_translate` / `translate_stream` with a
  fake API: the echo survives end to end before the fix, never reaches the
  wire after it. No romaji / orig+romaji+translate display feature exists on
  the device -- if that is wanted it has to be built, and the parsers
  currently DISCARD the `tlyric` / `<translation>` data that would feed it.
- **settings: schema UI, a real off switch, full l10n** (user: "what eats
  server settings now? make a ui for it not raw string and allow turning it
  off dont impact users too much"). The App tab was a free-form key/value
  bag, so the ~20 keys the device actually reads were undiscoverable: only
  `upload_logs` had a server default and every `ui.*` switch existed solely in
  the tweak. `server/app_settings.py` now owns `_SCHEMA` (key, type, default,
  group, label, desc) and the dashboard renders typed switches from it, with
  an override/default pill the flat map could never express; the raw form
  survives under a collapsed Advanced heading. Remote control is bounded from
  BOTH ends: server master `ui.remote_control`, and `allowServerFeatureControl`
  as a LOCAL pref (a user who wants the server out of their UI must not need
  the server's permission) shown as a row in the Liquid Glass settings page.
  `YTMULGServerAllows` moved out of the header into `LyricsCore.x` because it
  runs on every layout pass of ~40 hooked classes and was doing two
  NSUserDefaults deserializations plus an allocation per call; it is now
  memoized and invalidated on fetch / on the switch flipping. All four guards
  fail open. Also: a non-string key was a 500 through the crash handler not a
  400; schema keys are type-checked; bulk set is all-or-nothing; reset now
  confirms; and `YTMULiquidGlassPreferences.h` redeclared
  `YTMUAppSettingBool` with NO extern C guard while `LyricsShared.h` declares
  it WITH one, and `LiquidGlass.xm` imports both -- a link break waiting to
  happen. l10n: 185 strings were sitting in English inside the non-English
  .strings files (ja 61, ar 22, ...) and the zip's 8 new rows were hardcoded
  English literals; all 14 files are complete, with the remaining identical
  values being words that are genuinely the same word there (SponsorBlock,
  Audio, Player) and declared as such.
- **node self-update could not fix the one class of bug it exists for**
  (user: "bruh why didnt node self update"). `_maybe_self_update` needs the
  server's `code_sha`, and that only ever arrives inside `hello_ack` or a
  `ping` message -- BOTH require a working socket. So a node whose
  `run_forever()` raises before the handshake (exactly what the illegal
  ping pair did) can never discover it is outdated: it retries forever,
  hears nothing, and every node stays broken until a human edits the file.
  The recovery mechanism was structurally blind to startup failures, and I
  shipped that blind spot into the very commit that needed it. Fix:
  `_http_self_update()` + `_HTTP_SELF_UPDATE_AFTER = 3`, called from
  `run_forever_with_backoff`'s new `else:` branch (no authenticated
  session) once three consecutive dials have failed. The `generate` endpoint
  is keyed by node key, not a session, so it works with no socket at all --
  that is the property the whole fix rests on. Guards carried over: identity
  must be echoed back, 200 + >=500 bytes, and the sha comparison normalizes
  the three identity lines exactly like the server does, otherwise a
  personalized node always looks stale to itself. Throttled on purpose: only
  while already broken, so a healthy node never pays for it, and a 403/500
  can never turn into a restart loop. Verified end to end: a staged node
  with `_PING_TIMEOUT = 120` and a live server repaired its own file to 25
  and execv'd; the repaired copy kept its own identity and carried the pong
  fix; a node with no local sha restarts zero times over 6 dials; the
  threshold really is throttled (3 dials, 0 checks before the cut).
- **the node disconnect bug was on the SERVER, and my first fix made it
  worse** (user reported `connection loop error: Ensure ping_interval >
  ping_timeout` in a loop, after "make backoff lower or dont make it
  disconnect"). Three things here, read in order:
  1. `ping_timeout 10 -> 120` was WRONG and shipped broken.
     websocket-client validates the pair in `run_forever` and raises
     `Ensure ping_interval > ping_timeout` BEFORE opening a socket, so every
     node crash-looped and never authenticated. And it could not self-update
     out of it (self-update needs `hello_ack`). A node in that state needs a
     MANUAL restart after the fix -- the template sha bump is not enough.
     Now `_PING_INTERVAL 30` / `_PING_TIMEOUT 25`: still more headroom than
     the old 10s (the reader thread that records the pong is the same one
     `on_message` runs on, so a relayed `http_fetch` with its 20s timeout
     blocks it), but legal. The two are coupled -- never tune one alone.
  2. THE REAL DISCONNECT, pre-existing since the mesh landed: the server's
     `ws.receive(timeout=90)` in `ws_node` is reset ONLY by an APPLICATION
     message. `simple_websocket`'s `_handle_events` answers a protocol Ping
     with a Pong internally and never touches `input_buffer` or the event,
     so a protocol ping is invisible to `receive()`. The comment at
     `server/nodes.py:397` ("the node's WebSocketApp pings every 30s") was
     therefore wrong: a healthy, IDLE node was being reaped every 90s, and
     `on_message` answered the server's own `ping` with silence. Fix: the
     node now replies `{"type":"pong","ts":...}` to that 30s `ping`
     (`node.py` `on_message`, cadence `_SERVER_PING_ANSWER_EVERY`, module
     counter `_pong_count` -- it needs a `global`, so it lives next to its
     policy constant, not as a local), and the server handles `pong` by
     stamping `last_seen` (`server/nodes.py`). The 90s reaper is UNCHANGED
     and still drops a truly dead node -- that detection is wanted.
     Verified both directions on a real socket against a real
     `werkzeug.serving` app: a node that answers survives 100s with 200
     pings and keeps advancing `last_seen`; a node that ignores them is
     dropped at 90s. Plus a wire-level proof against the installed ws.py
     that a Ping is invisible to `receive()` while an app message is not
     (drive wsproto directly -- a socketpair harness deadlocks in the
     library's non-daemon reader thread, and a WSConnection that never
     handshakes silently discards data frames, which makes the control case
     lie).
  3. `config/nodes.json` is now gitignored: it holds `key_hash` for every
     node, which is credential material, and it was the one runtime config
     file missing from `.gitignore`.
  The reconnect pacing from the previous entry is unchanged and still
  stands: `_RECONNECT_MIN 1.0` / `_RECONNECT_MAX 10.0` / `_RECONNECT_GROWTH
  1.5`, jitter lengthened then clamped to keep 1s and 10s exact, reset only
  on a session that authenticated and lived >= 15s (`_SESSION['authed_at']`).
- **node reconnect: fast floor, bounded ceiling** (user: "make backoff lower
  or dont make it disconnect"). `node.py` was the only backoff in the repo:
  2s doubling to a 60s cap, and NOTHING ever reset it, so a server restart
  or a wifi blip could leave a node dark for a minute and one bad afternoon
  set the pace for the whole day. Verified with a stubbed-`websocket` harness
  over the real `run_forever_with_backoff`: never-connects walks 1.1 -> 8.1
  -> 10.0 and stays there (6 dials/min worst case), a long session drops the
  next wait back to ~1.0, a rejected key and an immediately-dropped session
  both still climb to the cap. (The liveness half of this entry was wrong and
  is corrected above.)
- **settings API documented** (`docs/settings-api.md`, linked from the
  README's public-endpoints list). Full reference: merge order (defaults
  overlaid by the file, a read never raises), the key regex and the
  value-type rules, all five endpoints with request/response bodies and curl,
  the auth trap (an unauthenticated admin call is a `302` to `/login`, not a
  `401`, so `curl -f` does not catch it), the device side (1h fetch cache in
  `YTMUFetchAppSettings`, so a dashboard change is not instant; the
  `YTMUAppSettingBool` string coercion table; the `upload_logs` gate as the
  worked example), a checklist for adding a key, the dashboard's value-field
  parsing, and the traps (gitignored file, no seed copy of the
  `.example.json`, no unknown-key validation, no null values). Fixed one
  inconsistency the doc would otherwise have had to lie about: DELETE with a
  malformed key was a 500 through the crash handler while POST returned
  `400` -- now `400` too (`server/routes_admin.py:141`). Also corrected the
  README's "first run copies config/*.example.json" claim: no code does
  that, the real files are created on first write. Verified with the Flask
  test client against 22 checks (public read open, admin gated, 400s for a
  bad key / list / >4000-char string / missing value, DELETE 400, defaults
  surviving a delete, reset emptying the file to `{}`).
- **node cache push removed, JWT push added** (user: "stop syncing caches and
  also sync jwt"). Gone: `_cache_entries_for_sync` / `_push_cache_sync` /
  `_full_sync_for` / `_cache_sync_loop` and the `'sync'`/`'sync_end'` receivers
  in `node.py`, plus the orphaned `_cache_key_from_filename` import. The
  60s-tick, 300-entry-per-push, 120s-cutoff lyric push had almost no value
  anyway -- it was already capped at ~300 songs and never backfilled, and the
  nodes it fed are the ones being asked in `ask_nodes_for_cache`. The PULL
  stays (that is the read path that actually saves work) but a node now only
  has what it fetched itself, so expect `[Node cache] hit` to get much rarer.
  New: the server pushes its live Cubey pool (`live_jwt_tokens`, best-first by
  the same key as `pick_jwt`) to every node as one `jwt_sync` message, on
  connect and on a 60s tick gated by a sha256 over the token set so a steady
  pool costs one hash a minute. The node replaces its copy wholesale (so a
  twice-dead token really disappears) and hands one back on `jwt_get`;
  `jwt_pool._top_up_from_nodes()` runs at the top of `_check_loop` and, only
  when `pick_jwt()` would be None, pulls one in from a node and contributes it
  -- background only, never on a request path. Gate: `"jwt_sync": false` per
  node in `config/nodes.json`, defaulted in at connect, toggled from the
  dashboard node row. Accepted trade: a token pulled back from a node gets a
  fresh `fails: 0` from `contribute_jwt` and is re-probed within 300s, so a
  node holding a long-dead token can re-seed the pool once per cycle until the
  probe kills it again (bounded, self-correcting). Nodes pick this up on their
  own: the template sha moved, so the next 30s ping makes every node refetch
  node.py. Verified: py_compile x4, `node --check`, dash.js syntax, and a
  loopback test (fake ws -> real `node.py` handlers) covering push, store,
  pull, top-up-into-an-emptied-pool, the opt-out refusing the push, no-nodes
  being a silent False, and `cache_check` still working.
- **precache actually works now** (it had never run): the only caller of
  `YTMULyricsPrecacheQueue` was a Logos hook on `YTMQueueConfigImpl
  -setQueueModel:`, a setter nothing calls - every other hook on that class in
  this tweak is a getter, and the queue actually lives in
  `YTMQueueCollectionViewController` / `YTMWatchNextResponseViewController`.
  A declared-but-guessed selector is how it got in, so the replacement probes
  a candidate list behind `respondsToSelector` + `@try` at depth 3 from the
  player / now-playing VC / key window / root VC, capped at 5, dropping the
  current track via `YTMUResolveCurrentVideoID` (not the lazy global). Two
  reliable triggers instead of one dead hook: a main-queue `YTMUSongDidChange`
  observer (the same notification the whole lyrics system runs on, so the
  up-next tracks are covered minutes before they play) and a 20s snapshot
  timer parked in a file-scope static (a `dispatch_source_t` in a local would
  be released on return, and a resumed source is cancelled on release).
  Requests only go out when the id list actually changes, 15s floor. Server
  side had a second bug: `_run_precache_job` wrote EVERY result to the full
  key `<vid>:<lang>`, so a fast precache shadowed the real wbw full fetch
  forever (fast results now go to `<vid>:<lang>:fast`, and a fast job is
  satisfied by a full entry but not the reverse). Added per-video
  `[PRECACHE]` log lines - the job previously logged only on exceptions, so
  "it silently did nothing" had no trace in the dashboard either. Verified
  with the Flask test client and the exact device body: 2 jobs, 5 cache
  files, no `translated` leak, and the fast entry no longer shadowing the full
  pipeline call.
- **streamed translate + typewriter reveal** (the "translate as a stream" ask):
  translation is no longer awaited. `server/translate.py` grew
  `translate_stream(texts, target_lang, song_lang)`, a generator yielding
  `{'i', 'text', 'done'}` per line, on top of `_NumberedStreamParser` (splits
  the numbered `[n] text` format across token deltas, emits a completed line
  on the newline and a throttled ~45ms partial while the line is still being
  written), `_cohere_translate_stream` (Cohere v2 `/v2/chat` with
  `stream:true`, key rotation on 429) and `_chat_stream_deltas` (the
  OpenAI-compatible provider). Contract matches `cohere_translate` exactly:
  same cache key, same "Han-script lines for a zh target never hit the API"
  bucketing, same echo-original retry, never negative-caches a failure, and
  always terminates with every line (falls back to the blocking call).
  **Encoding trap, same class as node.py:** Cohere and the chat providers
  answer `text/event-stream` with NO charset, so requests defaults to
  ISO-8859-1 and every CJK delta is mojibake. `_sse_data_lines` sets
  `resp.encoding = 'utf-8'` first. Both also send a `data: [DONE]` sentinel
  on `message-end` -- it is not valid JSON, so parse defensively. Cohere emits
  one token per `content-delta`; a model may also append a bonus `[n+1]` line,
  so out-of-range line numbers are dropped in `translate_stream`.
  `server/routes_stream.py` added `GET /api/lyrics/tstream`: the SAME work as
  `/api/lyrics` (full-cache gate, node cache, `fetch_all_lyrics` run
  UNTRANSLATED, disk cache, unlyriced, provider meta, usage stats) but pushes
  `lyrics` stage=raw the moment the winner is ranked, one `tline`
  `{i,row,text,done}` per translated line while the model writes, then
  `lyrics` stage=final + `done`. It is deliberately NOT in the in-flight
  gate: the device's fast request shares that gate, so waiting would stall the
  stream behind a fast-grade result. `_stream_translate()` runs the
  translate on a worker thread and drains a bounded queue with 1.5s SSE
  keepalives; `stop` is set in the generator's `finally`, so a disconnect
  never leaks a worker (verified: thread gone within 3s of `gen.close()`).
  The pre-existing `/api/lyrics/stream` now uses the same helper; the Google
  interim only runs with `tstream=0` (two overlapping fills of one row read
  as a flicker). Client: new `Source/LyricsStream.x` -- `YTMULyricsSSEClient`
  (byte-level SSE parser, chunks are never UTF-8 decoded before the frame
  delimiter is found or a CJK char gets cut at a chunk boundary; serial
  delegate queue; `onError` only when nothing was delivered),
  `fetchFullLyricsForVideo:jwt:force:` routes to the stream when
  `lyricsStreamTranslate` is on and falls back to the blocking JSON fetch if
  the stream dies before any lyrics, and `YTMUDebugStreamStatus()` for the
  Debug page. The typewriter reveal paints the translated row (the line under
  the lyric) letter by letter at `lyricsTypewriterCPS` chars/sec (default 30,
  cached in `YTMUTypewriterCPS()` because the tick reads it every frame).
  It is a `CAGradientLayer` mask on `transLabel`, NOT a text swap: the label
  keeps the full string so row heights never change mid-reveal, and the edge
  maps through the laid-out TEXT width (`sizeThatFits:`) because the label is
  stretched by its constraints. Only ACTIVE rows type (synced lyrics); a row
  that leaves the active set snaps to full, and streamed growth continues an
  in-flight reveal while a rewritten line (echo retry, OpenCC) keeps the common
  prefix via `YTMUCommonCharacterCount`. `updateLyrics:` only resets the
  per-row state on a song change or a row-count change, so `raw` -> `final`
  does not restart typing. The tick wiring is three lines in
  `updatePlaybackTime` and is easy to lose: `ytmu_typeRow:activate:NO` on every
  deactivated row, `ytmu_typeRow:activate:YES` on every activated row, and
  `ytmu_typeStep` as the LAST statement of the method -- so a line that became
  current in this tick starts moving in the same frame (`configureCell` runs
  `clearWipe`, which now also calls `ytmu_clearType`, so a reconfigure always
  drops a stale mask; `ytmu_typeRow:activate:` alone would freeze the row at
  fraction 0 forever). `tstreamFallbackUsed` latches the blocking retry:
  without it `fetchFullLyricsForVideo:` routes that retry straight back into
  the stream and a deterministic failure (400 from a bad lang, a dead
  endpoint) reconnects forever. The SSE client must deliver exactly ONE
  terminal callback (onError XOR onClose), or the retry it just started gets
  cancelled and reopened. Settings: the lyrics page grew a Stream
  translation switch and a Typewriter speed slider, its "Translation" section
  is now "Lyrics Engine", and the three debug rows moved to a new Debug page
  (`Prefs/DebugSettingsController.m`, 7th row of the main settings).
  Verified: py_compile, live Cohere stream (correct UTF-8, 3 lines, partials
  then done), full SSE order `meta,status,lyrics(raw),tline*,lyrics(final),done`
  with gap-row mapping, cache hit, `tstream=0`, 400s, no-key and non-SSE-body
  fallbacks, no thread leak on disconnect, cache-key parity with the blocking
  path. Untested on device: needs a rebuild.
- README/dashboard usage badges: `/api/app/badge?type=` now covers
  `release|lyrics|devices|tracks|nodes` (one glyph per type, short
  `<label> <value>` text, no link in the README). The MD3 pill renderer lives
  in `routes_misc.py` and measures the WHOLE string -- `textLength` forces an
  exact fit, so measuring only the value squeezed a long prefix to ~2px/char
  (the `Download Last Build: ` prefix the user added). `lyrics` is estimated
  from `logs/server.log` + `.1` (one `Returning` line per response, one
  `[Stream] push FINAL` per stream, 30s TTL cache), NOT from
  `usage_stats.served` -- that counter only counts since the process started,
  so it reads low after a redeploy; `devices` still comes from usage_stats.
  Count lines, never distinct `req_id`s: `req_id` is `token_hex(3)` and
  repeats. `tracks` counts distinct `(video_id, lang)` from cache filenames
  only (`:fast` siblings deduped) -- `scan_cache()` opens every JSON file.
  Gotcha for the dashboard: `mdui-dialog`'s shadow `.body` is
  `overflow:auto`, so an overfull dialog shows a scroll bar; hide it with
  `::part(body)` (mdui shadow roots are open). Release body now uses the
  official altdirect image embed instead of a fenced raw source URL.
  Badge icons are official Google Material Icons (Apache-2.0, credited in the
  README): 24x24 filled paths drawn at `translate(10,10) scale(0.5)` (12x12
  inside the 24px chip) with `.glyph{fill:...}`, not the old 14x14 hand-drawn
  strokes. `_BADGE_GLYPHS` stores BARE `d` data, so the template has to wrap
  it (`<path class="glyph" d="%s"/>`) -- pasting markup into the table renders
  nothing. Repo layout gotcha: the icons are NOT under `src/<category>/<name>`,
  they are `src/<category>/<name>/materialicons/24px.svg` (and `download` is in
  `file/`, `smartphone` in `hardware/`, `lyrics`/`album` in `av/`, `dns` in
  `action/`).
- intro skip becomes the song offset: a `music_offtopic` segment at the head
  of a video delays the song, so the lyric timeline (which starts at line 1)
  ran late by exactly the segment length. `Source/SponsorBlock.x` now stores
  `-(segment end)` per video and the loop adds it (lookup = playback +
  offset, so song time 0 lands where the seek landed; tap-to-seek already
  compensates the same way). `LyricsCore.x` keeps it under its own
  `lyricsSponsorOffset_<vid>` key next to the manual `lyricsTimingOffset_`
  one and `YTMULyricsOffsetForVideoID` returns the sum (both setters drop
  the per-video cache). Applied as soon as the segment list lands, reset to
  0 when the list has no head segment (stale shifts cannot survive), again
  on skip, cleared on unskip. Only head segments qualify (start <= 5s:
  `YTMU_INTRO_SEGMENT_MAX_START`) -- a mid-song segment needs a piecewise
  timeline, not one constant. New switch in Player settings next to
  SponsorBlock ("Shift lyrics for skipped intro", `lyricsSponsorOffset`,
  default on; turning it off drops the live shift). Lyrics settings section
  "Timing Offset" shows the manual number in the field and the auto one in
  the subtitle. Gotchas hit while landing it: Logos `%new` helpers are not
  visible to the type checker at earlier call sites -- declare them
  (`Headers/YTPlayerViewController.h` + `LyricsShared.h`); the skipSegments
  response is a list, so the local typed `NSDictionary *` breaks the call
  under `-Werror`; and a `.xm` caller of these C functions needs the
  `extern "C"` guard in `LyricsShared.h` or the link fails with
  `declaration possibly missing 'extern "C"'`. Untested on device: needs a
  video whose intro is a `music_offtopic` segment.
- every provider in **iPhone RAM** (not the server) + switcher press feedback
  + fullscreen title fix. Read the user literally: "provider in ram only no
  cache only cache the one" means the DEVICE holds all providers in memory and
  only the selected provider is ever cached -- `server/candidates.py` is back to
  its original disk snapshots (an earlier attempt moved them to server RAM;
  reverted, do not redo it). The RAM lives in `LyricsCore.x`:
  `g_providerLyricsRAM` (vid -> {provider: raw lyrics}) behind
  `YTMUProviderLyricsStore` / `YTMUProviderLyricsForProvider` /
  `YTMUProviderLyricsCount` / `YTMUProviderLyricsDrop`, an 8-video LRU
  (`g_providerRAMOrder`), memory only, never `YTMULyricsCacheSave`. Filled by
  `GET /api/lyrics/providers/data?v=&lang=` (`routes_lyrics`, up to 8
  providers / 200KB, raw pre-translation lyrics straight from the stored
  snapshot) via `ytmu_loadProviderLyricsForVideo:`, called on song change, on
  every `fetchLyricsForVideo:`, and when the provider menu opens. Switching
  paints from RAM first (`ytmu_applyProviderAtIndex:`, deliberately NOT into
  `g_lyricsCache`), then `/providers/select` returns the translation and caches
  that one provider. `YTMUPrefetchProviderLyrics` (called from
  `YTMULyricsPrecacheQueue`, 12s delay so the full race has landed) warms the
  next 2 queue tracks; `ytmu_precachePost` runs the FULL pipeline for the
  immediate next track (all providers raced, winner cached) and fast for the
  rest. Menu arming: `_provider_meta()` (slim rows) rides along on every
  `/api/lyrics` payload and `/api/lyrics/check`; `GET
  /api/lyrics/providers/candidates?v=` is the standalone read. Fullscreen
  title/artist: `GET /api/lyrics/song?v=` (cached entry, else
  `providers_yt.get_song_info_cached`, 30min TTL/LRU) via
  `ytmu_requestSongMetaForVideo:` (guarded by `songMetaVideoID`) -- the fix for
  "stuck on Now Playing", which happened whenever the lyrics came from the
  device cache and no payload carried metadata. Server track name outranks
  `playerResponse` (a video title -- `ytmu_cleanVideoTitle` strips
  `(Official Video)`/`- Topic`/`【MV】`/`| 4K`), the label scrape ranks by font
  size and skips hidden/zero-size plus audio-quality rows, and only fills gaps.
  [<] [>] steppers grow into a filled pill while held
  (`ytmu_wireStepperPress:` -> `ytmu_stepperPressIn:`/`Out:`, transform-based so
  layout passes cannot cut the spring). Verified: py_compile all server files,
  imports, node --check, stubbed endpoint runs (all providers shipped raw with
  timing, no translation leak, byte budget caps a fat snapshot, 400 on a bad
  id) and a stubbed fetch (winner-only disk cache, select served without
  network). Build traps fixed on the way (see the intro-skip entry):
  `UIControlEventTouchDown` (there is no `TouchDownInside`), the `extern "C"`
  guard for `.xm` callers, and declaring `%new` helpers.
- compact provider menu (better-lyrics dock style): collapsed trigger shows
  the current tier icon (wbw blue / line mint / plain dim, redrawn bars, no
  upstream SVG copied), tap expands a native anchored UIMenu (iOS 14+) with
  provider name + tier icon rows, `i/n · tier · lines` subtitles (15+),
  current checkmark, Best-available(auto) row; [<][>] steppers kept;
  probe completion arms the menu (no programmatic UIMenu open) instead of
  the fullscreen sheet; iOS 13 keeps the sheet fallback.
- 10-way audit cleanup: fixed outcome-tier clobber, on_candidate deadlock,
  Cubey/AMLL per-query guards, Unison considered-every-query (dup fix kept),
  JWT load crash on nulls + TTL prune + probation label, candidates
  outcomes-only saves + gap parity + ts tolerance, rerace translate
  alignment + (vid,lang) cooldown, library multi-lang dedupe, probe
  locks/prune, SSE NaN guard + dumps guard, sync JWT leak + auto_zh hash
  mismatch + max_items guard + probe error broadcast + partial-translate +
  aligned select translations, cohere/google negative-cache guards,
  playlist stop + rich track events, bulk cancel rows + tq counters.
  iOS: fetch slot release, clock/song/provider resets, pro metadata,
  probe-vid pinning, reload/select-failure index handling, upgrade + seek
  guards, lyrics-gated assertOnTop, startTimeMs synced, FE0F strip, stepper
  lockout, category dedupes. Dashboard: row-map eviction, idle-run guard,
  retry context, ticker cleanup, stop-state reset, tq + tag counts.
  Verified: py_compile x13, node --check, JWT/translate/snapshot tests.
- saved-all + 120fps split + extrapolated clock: `fetch_all_lyrics` now
  persists every tried provider as a snapshot (pre-translation, provider
  keys in switcher vocabulary) -- verified QQ/LRCLib saved, no
  translated leak; normal full fetches leave switch/rerace reuse like
  probes do. iOS keeps the 120fps link for smooth animations while state
  work stays cheap (offset lookup cached per video instead of NSUserDefaults
  twice per tick; extrapolated media clock ported from braccato tickView:
  rebase on sample + local extrapolation, freeze after 0.5s stall, seeks
  rebase). STAY (XfEMj-z3TtA) checked live: bLyrics wbw 41 lines, max 12
  parts/line -- parsing is clean, judder was the discrete clock + tick cost.
- scan 44-bug + iOS judder fixes: `scan_cache` preferred `:fast` over full
  (inverted condition) so stale fast siblings shadowed bulk upgrades --
  full now always wins (verified wbw with stale fast present); bulk mirrors
  upgrades onto an existing fast sibling. iOS tick slimmed per braccato's
  model (cheap ticks, zero mid-tick measurement): display link 120->30fps,
  incremental active-line scan (resume at currentIndex-2, full rescan after
  backward seeks), label rasterization (shadow baked once, mask animates on
  the cached bitmap), far jumps scroll instantly instead of stacking
  animated scrolls, z-order/metadata retry counters re-based on 30fps.
  Needs device rebuild to confirm smoothness on XfEMj-z3TtA.
- everything-parallel + live animated rows: `fetch_all_lyrics` stages and
  `_rerace_video` legs now run concurrently (wall = slowest, verified
  0.6s vs 1.6s serial with winner still correct); stream race already was.
  Fixed a pre-existing Unison bug (stray `continue` meant only the last
  query's result was ever considered). Dashboard probe log is now animated
  web rows (spinner + 250ms elapsed ticker, determinate pill + per-row
  re-probe via only_source on land); update dialog shows elapsed + tries.
  TODO(web-anim)/TODO(app-anim) filed; `server/egress.py` stubbed with the
  proxy-protocol questions for proxy.chiuhuang.dev. NOTE: sequential
  `[..]/[--]` logs mean a stale pre-parallel build is still running --
  self-update + restart to pick this up (probe prints `[probe] <vid>
  probing (parallel groups)` on the new build).
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
- **REQUEST LIST (user's words, 2026-09-27, do not lose this again).** Work
  these in this order; tick each line off here as it lands. Anything unclear
  gets a one-line note under the item instead of a silent guess. Status:
  everything below is CODE-DONE but NOT device-verified (no rebuild yet).
  1. `[done]` more left/right space on lyric rows, portrait AND fullscreen:
      gutters 48/-28 -> 64/-40 from `YTMULyricGutterLeading/Trailing()`,
      landscape gap 12 -> 24 on BOTH sides.
  2. `[done]` typewriter reveals up to 2 lines at once: `ytmu_revealCandidateRows`
      = every active row + the next typable row, capped by
      `YTMU_TYPEWRITER_MAX_CONCURRENT 2`, each at the full cps. Finished rows
      keep their state with a `done` flag (deleting it made "finished"
      indistinguishable from "never started" and the lookahead restarted the
      line from zero).
  3. `[done]` scroll + highlight share one `YTMUTransitionDuration` (0.28s);
      `ytmu_scrollToRow:instant:` animates only when no animated scroll is in
      flight (`s_scrollInFlightRow`), otherwise it jumps - no stacked scrolls.
  4. `[done]` fullscreen retranslate button (toolbar tag 7105, `globe`/`T`):
      keeps the caches, dims via `ytmu_setProbing:YES`, 10s JWT fallback then
      `fetchFullLyricsForVideo:jwt:force:YES`, 45s watchdog, no re-entry, and
      the provider switcher stays compact (`[<] [list] [>] [name i/n] [R] [T]`).
  5. `[done]` next song in fullscreen paints immediately: `handleSongChange:`
      requests the cover and fills the title/artist labels BEFORE the
      metadata / provider / JWT / lyrics work, so nothing waits on the server.
      The device builds the same `i.ytimg.com` URL the new endpoint returns (no
      invented notification in `LyricsStream.x`; `meta=1` is the slow uncached
      variant while `/api/lyrics/song` is the cached one), and
      `ytmu_requestArtworkOnce:` keeps it to exactly one request per song.
  6. `[done]` activation pop 1.04/alpha 0.3/0.5s -> 1.018/0.6/0.28s; word-synced
      rows animate only the wipe label, so the pop cannot fight the word mask.
  7. `[done]` dark overlay 0.30 -> 0.22 (light) / 0.48 -> 0.40 (dark), one
      helper for both copies. Blur styles untouched.
  8. `[done]` `YTMULyricInk` blends 14% toward the artwork mean colour (dark
      branch) and uses an artwork-hued dark ink for the light branch
      (`k = 0.18 + 0.27*luma`), falling back to the old ink when
      `|luma(ink) - luma(backdrop)| < 0.18`; with no cover sampled it returns
      the previous colour exactly. The mean is sampled once per song in
      `ytmu_probeArtworkBrightness:` and cleared on a song change.
  9. `[done - root cause]` precache never fired: its only caller was a Logos
      hook on `YTMQueueConfigImpl -setQueueModel:`, a setter nothing calls
      (the queue lives in the VCs), so the feature made zero requests ever.
      Replaced with two reliable triggers (a `YTMUSongDidChange` observer and
      a 20s snapshot timer in `%ctor`) + a guarded, depth-3 selector walk
      (every hop behind `respondsToSelector` + `@try`, no `performSelector:`
      which would trip `-Warc-performSelector-leaks`). Server: a fast result
      was being written to the FULL cache key, shadowing the real wbw fetch -
      now `full ? "<vid>:<lang>" : "<vid>:<lang>:fast"`, plus per-video
      `[PRECACHE]` log lines so a future failure is visible.
  10. `[done]` `GET /api/lyrics/image?v=&q=&meta=1` (instant, zero network
      without `meta=1`; `yt_cover_url()` in `providers_yt.py`) and the stream
      `meta` event now carries `art` + `art_maxres`.
  11. `[done]` the instrumental note (U+266A) shows only while it is that row's
      turn, on the LEFT (`NSTextAlignmentNatural`, the 64pt lyric gutter)
      instead of centred, and the row COLLAPSES when it is not its turn:
      `YTMURowPadTop/Gap/Bottom` are now named constraints plus a
      `transLabel.heightAnchor == 0` constraint (`flat`, inactive at init), and
      `ytmu_setRowCollapsed:` flips them - a hidden label still sizes itself
      through its constraints, so the collapse needed an explicit mechanism.
      The text branch and `prepareForReuse` always re-expand, so a recycled
      collapsed cell can never show a lyric at zero height. Judgement call: an
      UNTIMED payload (`!isSynced`) keeps the note up for the whole song, since
      there is no window to judge "its turn" by and the row would otherwise
      read as an empty gap.
  12. `[done]` one X per configuration: the header `closeBtn` + `menuBtn` are
      hidden for the whole landscape branch (`ytmu_applyHeaderButtonsForLandscape:`,
      reached from `viewDidLayoutSubviews`), which also removes the
      menu/exit-button overlap. `ytmu_assertOnTop` now also hides YT's own
      `YTEngagementPanelHeaderView` (found one level above our container by
      `YTMUPanelHeaderSibling()`) and the landscape layout calls it too, so a
      rotation cannot let it reappear. Leaving the embedded panel:
      `dismissModal` -> `ytmu_restoreHostingPanelChrome` (un-hides every
      sibling it hid + the panel header, re-orders) -> hide -> collapse via
      `ytmu_collapseHostingPanel` (5 guarded selector names, each behind
      `respondsToSelector` + `@try`), so nobody is trapped in landscape.
  13. `[done]` `artworkVideoID` is now the display INTENT (written on song
      change, in `fetchLyricsForVideo:` before every branch, in `forceReloadLyrics`)
      and `ytmu_applyArtworkImage:forVideoID:` validates against it +
      `YTMUResolveCurrentVideoID()` - a stale response is dropped with a log
      line, the current song's is adopted. No art guard reads `loadingVideoID`
      any more (which is what `ytmu_selectProvider` used to roll back to the
      previous video after a skip). The song-change reset of both images +
      `g_ytmu_bgLight` + `s_ytmuArtworkMean` is unconditional, the landscape
      card is painted FIRST (so it never waits on the background image), and
      `ytmu_applyLandscapeTheme`'s process-wide `static s_lastStyle` became
      per-instance associated state (the second live VC used to inherit the
      first one's decision). `ytmu_requestArtworkOnce:` + `s_ytmuArtRequestKey`
      keep it to one request per song.
  14. `[done]` rotate from fullscreen back to portrait CLOSES the fullscreen
      lyrics (no half-landscape panel, no re-present). `viewWillTransition
      ToSize:withTransitionCoordinator:` in `Source/LyricsSheet.x:2798` gates on
      the TRANSITION's target size (a fire-time interface check aborts every
      real rotation - the interface has not turned yet), then closes from the
      coordinator's completion block. The race with the auto-open chain is gone
      because both chains now carry an orientation generation
      (`s_ytmuOrientationGeneration`): `YTMUAttemptLandscapeOpenChain(int,
      NSUInteger)` and `YTMUAttemptFallbackPresent(NSString *, int, NSUInteger)`
      abort on any newer orientation decision, and `YTMUBumpOrientation
      Generation()` runs at close time. `isLyricsViewVisibleOnScreen`'s
      portrait-bounds comparison can no longer be fooled, because a closed
      instance stays closed: `YTMUSetClosedByRotation(self, YES)` latches, and
      `updateLyrics:` / `handleLyricsDidLoad:` both return early on it. The
      latch clears only in `viewWillAppear:` / `fetchLyricsForVideo:` (opens).
  15. `[done]` closing OURS no longer leaves the native panel up:
      `dismissModal` schedules `ytmu_collapseRevealedNativeLyrics` at +0.30 s
      (the modal has finished dismissing by then). Proof of "something is still
      up" = `YTMULyricsTaggedViewOnScreen()` or
      `isLyricsEngagementPanel(topMostViewController())`; the target is the
      controller that owns the tag-9999 view, `g_activeEngagementPanelContainer`
      or the top VC. Both `ytmu_restoreHostingPanelChrome` and
      `ytmu_collapseHostingPanel` are now behind `if (self.view.superview)` -
      the restore used to run with no container. Host resolution changed from
      `_viewControllerForAncestor` (which returns the NEAREST ancestor, i.e.
      usually `self`) to `ytmu_resolveHostingPanel`, a responder walk that skips
      `self` and sibling `YTMULyricsViewController`s and demands
      `YTMUViewIsInsideView(self.view, host.view)`. Both last-resort
      `dismissViewControllerAnimated:` calls require that ownership proof plus
      `dismissible != self` and `!isBeingDismissed`, so an unrelated VC can
      never be the fallback victim. The guarded selector list is now
      `ytmu_tryCollapseTarget:` (`respondsToSelector` + `@try` + the existing
      `-Warc-performSelector-leaks` pragma), shared by both collapse paths.
  16. `[done]` the landscape fullscreen is a FEATURE, default ON: pref
      `lyricsFullscreenAutoOpen` (missing key = ON) read at 4 sites -
      `ytmu_enforceFullscreenAutoOpen` (per-instance, `NSUserDefaultsDid
      ChangeNotification` + a throttled tick backstop, landscape-only so the
      portrait page sheet survives), `openLyricsFullscreenForLandscape`, each
      `YTMUAttemptLandscapeOpenChain` step, and `YTMULandscapeArm`. Toggling it
      off while the panel is up closes it through the same
      `ytmu_closeFullscreenWithReason:`. The close also releases what used to
      wedge the NEXT open: provider poll, probing dim, the retranslate latch,
      `ytmu_cancelTranslateStream` (before the dismissal), `isLoading` and both
      fetch slots. Face-up jitter in landscape no longer re-arms the chain: the
      arm defers 0.4 s in BOTH branches (the other one used 0 s). Settings row
      is in `Prefs/LyricsSettingsController.m` section 0 (`LYRICS_FULLSCREEN` /
      `LYRICS_FULLSCREEN_DESC`). Two judgement calls to keep in mind: the
      portrait tap-opened page sheet shares `dismissModal`, so it also collapses
      a revealed native panel; and the exit button still does NOT cancel the
      stream (only rotation and pref-off do) to avoid changing the retranslate
      path.
  17. `[done - small]` two real character bugs in the catalog, found by the
      strings pass and fixed in `d2bab38`: zh-Hant
      `LYRICS_FULLSCREEN{,_DESC}` had U+87FA (snail) where U+87FE (firefly/
      glow) was meant, and vi `LYRICS_FULLSCREEN_DESC` had a decomposed
      `m<combining acute>o` instead of precomposed U+1EDF. Sweep now finds no
      U+87FA and no combining marks in any of the 14 files. Still pre-existing
      and untouched: ar/ja/ru/th/vi `SB_LYRICS_OFFSET{,_DESC}` fully English,
      ja 4 untranslated tab-bar keys.
  18. `[done - small]` the `lyrics` badge glyph was the first path of Material's
      `chat` icon (bubble + tail = "a message icon with a dot"). Now
      `subtitles` (the caption box) - Material's own `lyrics` icon is a rounded
      bubble WITH a note in it, so it reads the same way. Commit `337c7d5`.
  - New request (2026-09-27, three screenshots), commit `6ffc5a6` -> `b4dac11`.
    All CODE-DONE, NOT device-verified. Read the two open points at the end of
    this block before rebuilding.
  19. `[done]` no glass elements in the lyrics. The user's words: "why tf one
      line have its own bow its ugly as fuck" (box). `LyricsLiquidGlassV2.xm`
      drew a rounded `UIVisualEffectView` behind EVERY row
      (`YTMULyricCard` + the `%hook YTMULyricsCell layoutSubviews`), so a full
      page of lyrics read as a stack of notification cards. Card, associated
      object and cell hook deleted; the `YTMULyricsCell` @interface in that
      file went with them. `lyricsV2Enabled` is NOT dead - it still owns
      `blurView.alpha = .82` and the table chrome, and the file now says that
      in a comment so nobody re-adds the cards.
  20. `[done]` "only show translate animation if it hasnt cached". New
      `typewriterLive` BOOL (`LyricsShared.h:150`), NO by default, so every
      cache path paints whole. Armed by the stream on `lyrics stage=raw` and on
      any `tline`; armed by a blocking response the server tagged `cached:0`.
      Gated in BOTH `ytmu_typeStep` AND `ytmu_typeRow:activate:` - the second
      one is the trap: it calls `ytmu_advanceRow:` with `dt=0`, so ungated it
      leaves `shown` at 0 and installs a mask that BLANKS the whole
      translation of a cache hit. Disarmed on song change, on both
      `fetchLyricsForVideo:` cache branches (RAM + on-disk), and on the
      provider switch + `/providers/select` paths, which always return a
      finished payload (otherwise a live fetch earlier in the song would carry
      the animation into a provider the user switched to).
      Server side: `routes_lyrics.serve(data, cached)` tags every response -
      True on the disk, in-flight-dedup and node hits, False on the two paths
      that just ran a pipeline. Transport-only, like `pro`: tagged after
      `set_cached`, never on disk (verified). `routes_stream` sends the same
      flag on its `raw` / `final` / `cached` events. Older servers omit it and
      the client falls back to `stage != 'cached'`, which is exact anyway.
  21. `[done]` mini player has no background, and the song colour now reaches
      the whole app.
      - Deleted the mini player's frosted card (`kMiniBlur`) and its
        white-to-black `YTMUMiniSongTheme` gradient. The artwork rounding and
        the drop shadow stay; the shadow follows the subviews' own alpha, so it
        still renders with a clear `backgroundColor`. V1 `LiquidGlass.xm` hooks
        the same class and would put a card back, but its
        `YTMULGV1Allowed(@"liquidGlassV2Enabled")` gate stands it down.
      - ROOT CAUSE of "the whole app is never tinted", found by reading the
        publish path instead of guessing at opaque views:
        `YTMUPublishTheme` rejected any image under 80pt, and the mini
        player's thumbnail is a 40pt `UIImage` (YT loads it at screen scale, so
        `.size` is 40 points, not 120). On the home tab that is the only
        artwork on screen, so `YTMUPrimaryColor` stayed nil and the app fell
        back to a near-black placeholder. Floor is 24pt now; the
        `YTMUArtworkAncestor` check, not the size, is what keeps this to real
        cover art. Symptom to remember: tinted full player, black everywhere
        else.
      - Full player ("great colors tho", just the geometry was wrong): the
        tint moved from `YTMNowPlayingView` (title/artist/chips strip only,
        hence the hard-edged purple rectangle) to
        `YTMNowPlayingViewController.view`, so the SAME three stops now run
        from behind the album art down past the transport row.
        `YTMNowPlayingView` must never become a theme host again: its opaque
        `backgroundColor` would cover the controller's gradient and restore
        the rectangle. `YTMUStyleLyricsEntries` deliberately STAYED on the old
        host - `ytmuPlaceLyricsBesideThreeDot` sets that chip's
        `cornerRadius` to a full pill on every pass, so moving the styler to
        the controller would start the two fighting over views that used to be
        out of each other's reach.
      - `LG_LYRICS_V2_DESC` and `LG_SONG_THEME_PLAYER_DESC` rewritten in all
        14 languages (they promised "lyric cards" and "V1 mini-player").
  - OPEN, needs a device check on the next build: (a) does the home tab now
    actually tint? `wholeAppSongThemeEnabled` must be ON and the mini player
    must be the thing that published the colour - if the home screen is still
    black with a tint on the full player, the 24pt floor did not fix it and
    the next suspect is an opaque sibling covering
    `YTMContentViewController.view` (the tab bar and the mini-player container
    are the likely ones; `HomeLiquidGlassV2.xm` already clears
    `YTMBrowseContainerView` + its scroll views and the shelf cells).
    (b) open a song the server already has, confirm the translation appears
    whole with no letter-by-letter reveal, then a song it does NOT have and
    confirm the reveal still runs.
  - Residual risk worth knowing: the queue walk probes YT selectors by name;
    if a YT update renames all of them the feature degrades to a no-op again.
    The one-shot `[PRECACHE] queue walk found no up-next list` line in the
    device log is the signal to add a selector. Also, a probed accessor that
    returned a SCALAR would hand back a bogus pointer; the return value is
    `isKindOfClass:`-checked but a scalar return would crash before that.
  - After all of it: rebuild `client_edits_pack.py` (the 7z/LZMA python pack)
    and commit + push. Everything above is CODE-DONE and NOT device-verified -
    after a rebuild, check: the single X in all four panel configurations, the
    `♪` appearing/collapsing, the art+title switching on the next song, the
    retranslate button, the typewriter on two lines, the new ink tint, the
    wider gutters, and the `[PRECACHE]` lines in the dashboard log (item 9 is
    code-done but has never actually fired on a device).
  - Fullscreen items 14/15/16 on device: (a) rotate landscape->portrait with
    the panel up - it must close, not linger half-landscape, and it must not
    pop back 1s later; (b) close with the X in landscape - NOTHING
    lyrics-shaped may stay on screen afterwards (that is item 15, the one that
    was visibly broken); (c) rotate back to landscape inside a second and it
    re-opens on its own (auto-open is ON by default); (d) turn
    `lyricsFullscreenAutoOpen` off in settings while the panel is up - it
    closes, and the next landscape rotation does NOT re-open it; (e) lay the
    phone face-up in landscape for a few seconds - the panel must not
    flap open/closed (the 0.4s arm deferral).
  - RESOLVED, no action left: `session-ses_f5af.md` / `BRACCATO_COMPARISON.md`
    are gone from disk and were never tracked (nothing to restore), and
    `pack.json` + `client_edits_pack.py` are now gitignored
    (`.gitignore:12-13`, "Local AI context packs: generated, never pushed") so
    they stopped showing as deletions. `client_edits_pack.py` is therefore
    untracked by design -- a rebuild does NOT need a commit.
- Streamed translate + typewriter reveal: needs a device rebuild. Check, in
  this order: (1) a song with no server cache -- the lyric lines appear
  untranslated first and each translation types in; (2) the Debug page shows
  state `opening` -> `done` with a non-zero `Events / lines`; (3) the
  typewriter speed slider changes the rate without a respring; (4) turning
  `Stream translation` off restores the old blocking fetch (status line
  "Loading..." then everything at once); (5) a song change mid-translation
  leaves no half-typed row and no lingering request.
- Exact ELM lyrics node key: watch server logs for `Lyrics ELM tap key=...`,
  then pin it like `music_download_badge_1`.
- Device was a build behind on wipe overlay — retest on latest build.
- "Translated words on Check for updates" claim: section 4 code is untouched
  since `120e8c1` (verified via diff) — needs a screenshot of that exact row.
- Cell-reuse reset in LyricsSettingsController (icons/colors/fonts leaked
  into lyric rows) + `viewWillAppear` refetch: committed, untested on device.
- Re-tap refresh of already-presented sheet: committed, untested on device.
