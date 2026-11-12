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
- `[DONE] ses_privlink_20261110 | Settings links this fork and the SERVER's own
  privacy page, and the policy page now names the host that serves it | files:
  Source/Prefs/YTMUltimateSettingsController.m, layout/.../*.lproj/Localizable.strings,
  templates/privacy.html, README.md | next: device check -- Settings row 6 of the
  links section ("Privacy policy") must open `<lyrics endpoint>/privacy`, and
  `Source code` must open ChiuHuang/ytmusicultimate | does: the row is built from
  YTMUApiBase(), never a hardcoded host, so a build pointed at a self-hosted
  endpoint opens THAT server's policy (and a server without /privacy 404s -- the
  row assumes the template exists). TRAPS: the links section is index 3 with
  `Check for updates` pinned at row 4 and privacy appended at 5, so any new link
  row must go AFTER 5 or the update check breaks; rows >= 4 use SF Symbols while
  rows 0-3 load PNGs from the bundle's icons dir.`
- `[DONE] ses_censbtn_20261110 | census2 is runnable by hand from the Debug
  page (its dispatch_once was per PROCESS, so a device paired after its first
  play could never send one) and the offline fullscreen header names the song
  from its own download | files: Source/Downloading.x,
  Source/{LyricsSheet.x,LyricsShared.h},
  Source/Prefs/DebugSettingsController.m, layout/.../*.lproj/Localizable.strings
  | next: device check -- Debug > Actions > "Run player census" must post a
  player-census2 record (Probe chip) on the current song; offline, the
  landscape title/artist must read the download's "<author> - <title>" instead
  of a placeholder | does: the census body became YTMUPlayerCensus2Now and the
  dispatch_once wrapper stayed for the automatic path; YTMULocalMediaNameForVideoID
  returns the stored media name whether or not the file still exists, and the
  header splits it at the LAST " - " (a bare video id is rejected). TRAPS:
  YTMUDebugHasToken is file-local in DebugDeviceMode.x -- callers outside use
  YTMUDebugDeviceToken().length; the English "Now Playing" placeholder is gone
  on purpose (an unknown title now renders empty); and the 2-X landscape
  report is still UNVERIFIED -- the header close is hidden by tag 8889 in
  landscape, so the second X must be identified from a UI dump before any fix.`
- `[DONE] ses_logcap_20261110 | the app's own log now uploads (NSLog full text +
  os_log format string) through the paired buffer, the Debug page's capture
  feed got the colouring + a kind-aware filter (Live logs was the wrong
  place), and the server stopped dropping request bodies | files:
  Source/DebugLogCapture.x (new), Source/{DebugDeviceMode.x,LyricsShared.h},
  server/routes_debug.py, static/dash.js, templates/index.html | next: device
  check -- Debug page must show LOG lines with kind=log once paired, dashboard
  live feed renders them colorized, `/api/admin/logs` filter chips actually
  hide rows, and a captured POST shows its body | does: DebugLogCapture.x is
  the FIRST `%hookf` in this tweak: it hooks NSLog and the private
  `_os_log_impl` and feeds YTMUDebugDeviceNoteLog, where consent + budget live
  (120 lines per 15s window, checked BEFORE any pref read; `[YTMU` own lines
  skipped; 700-char cap; owner_debug on every record). `_clean_record` kept
  only ts/m/host/path/vid/u, so the body capture shipped earlier had never
  reached a file -- body and owner_debug persist now, and kind=log carries the
  text in `log`. TRAPS: Logos' `%hookf` gives you `%orig` that cannot forward
  `...`, so the NSLog hook formats the line itself and re-emits via NSLogv
  (a thread-local flag stops that forwarded copy being recorded a second time
  by the os_log hook); an os_log record holds the FORMAT STRING, not values;
  and the log-filter predicate + chips shipped with NO listeners for a whole
  session -- existing UI is not running UI. Build 383 is the first beta with
  all of it (382 was 73537b7). The dashboard filter then MOVED to the Debug
  page's capture feed (18db24d, Build 385): that feed mixes three record
  shapes, so its chips select kind (Log/Net/Probe/Err) and the text box ANDs
  on top -- and both the new dash.js and the server's kind=log persistence
  only exist where the DEPLOYED instance has pulled this repo, so a phone can
  upload LOG records into an old server that silently drops them.`
- `[DONE] ses_lyrchip_20261108 | chip marker no longer lands on the action-row
  bar (the dim reaches the chip), a chip YT disables by HIDING an ASDK cell is
  rescued on the spot, mini cover base walk fixed, retitle gated to decorated
  titles only | files: Source/{LyricsEngagement,LyricsNowPlaying}.x,
  Source/LyricsShared.h, Source/MiniPlayerLiquidGlassV3.xm, server/library.py |
  next: device check -- drag a popup sheet off and watch the action row dim WITH
  the chip; a song whose chip is missing/greyed must show it and open our panel;
  the mini cover must be ONE rounded rect; a title with 【...】 must come back
  without the brackets | does: (1) `YTMUMarkLyricsPath` stops at a CHIP SIZE
  (parent >240pt wide or >120pt tall) instead of 250pt / 90%-of-window, so the
  marker never sits on chrome. (2) 9.35 chips are ASDK `_ASDisplayView`s -- no
  UILabel and no UIControl -- so the text walk never marked them and the disable
  (which is `cell.hidden = YES`, NOT `enabled = NO`) went through;
  `YTMURescueLyricsChip` probes accessibilityElements on hide/dim for CHIP-SIZED
  views, `_actionButtonsFromRenderers` pairs renderer to button, and the ELM tap
  marks whatever view carried the lyrics command. (3) mini: the base walk
  stopped at "width > 72pt", so a 76pt mount kept its fill = a circle riding a
  square; the stop is SHAPE now (near-square, <=200pt) and the base takes a flat
  7pt (7/scale was 11.2pt and disagreed with the art's visible radius). (4)
  retitle: `title_has_decoration` gates the LLM (a clean title costs nothing)
  and `retitle_text_matches` only lets it DELETE -- substring of the input, not
  longer than it, at least 60% of what our own cleaner leaves. TRAPS: ANY marker
  above the chip refuses YT's popup-drag dim (that is the "chip escapes out of
  the popup first" symptom); the size gate is also what keeps YT's 412pt
  "沒有歌詞" snackbar a toast; and 【...】 is a decoration class stripped whole at
  both ends.
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
- `[ACTIVE] ses_bgspc_20261109 | OFFLINE REPLAY (census half done: focused census2 = 84c1e16; INJECTION half lost to a Stopped session -- YTMUCachedResponseForVideoID still unused, REWRITE from scratch) + CHANNELS (9af061d, 28c082f, Build 365 first beta) + OWNER/DEBUG POLICY (9e7135f, 320e27d, 4613675, ae6ee64) + count ping /privacy (3d8cf34) + body capture (d987ddb) + docs (1f72c53) + icon raw fallback (d776108) + README rewrite (403fa92: what+install only) + settings repo/privacy links (6d6ed6c, 83cd5b3) + privacy names host (2cf0263) + LOG CAPTURE (ses_logcap: DebugLogCapture.x NSLog+os_log, Build 383/385) + landing page (40361ef: / renders templates/landing.html when signed out, signed-in still hits dashboard; url_for('dashboard') preserved) | files: Source/Downloading.x, Source/{LyricsCore,DebugDeviceMode,DebugLogCapture}.x, Source/{Prefs/YTMUltimateSettingsController.m,LyricsShared.h}, server/{instances,paths,release_info,routes_misc,routes_admin,routes_debug}.py, templates/, static/, .github/workflows/main.yml, README.md | next: USER resprings and plays ONE song on 383+ so the per-PROCESS dispatch_once census2 actually fires (their 12:02 capture was a process started before 381 -- no census2 in it, and a reinstall alone does not resend) and pastes the player-census2 probe -> write the INJECTION half (parseFromData the .pb at the fetch point); user: deployed server self-updates for landing/privacy/LOG records, promote once, device-verify batch | TRAPS: (1) iOS libobjc does NOT export protocol_copyMethodList/protocol_copyOptionalMethodList - neither declared in the 16.5 SDK nor linked (extern-declaring breaks the LINK, not just -Werror); the exported API is protocol_copyMethodDescriptionList(proto, isRequired, isInstance, &count) with objc_method_description.name = the SEL (Downloading.x census2); (2) SDK nullability annotations are -Werror errors the synall stubs never see - nil into a nonnull completionHandler needs an explicit block cast + objc/message.h import (LyricsCore.x ping); (3) census2 dispatch_once per process - a respring does NOT resend, only a fresh process; (4) the valueWithPointer Protocol needs __bridge both directions under ARC; (5) promote's GitHub flip is manual (gh release edit build-N --prerelease=false --latest); (6) pairing UI lives INSIDE the Debug page so never hide the row without the footer door; (7) YTMUDebugDeviceNoteRequest signature has the 3rd NSData* arg`
- `[DONE] ses_bgspc_20261109 | Build 355 (6b21643) SHIPPED: (1) downloads play in the APP's own player (de03e15): YTMUPlayVideoID tries the bundle's OWN URL scheme then shared-instance player services, YTMUVideoIDForMediaName inverts the vid->mediaName map that YTMURememberDownload writes at the ffmpeg move (FFMpegDownloader.m:46) - the missing half that made an earlier draft inert; AVPlayer stays fallback for unnamed files; attempts go out on the play-api probe. (2) bg-cue spaces (6b21643): `space` is THREE-STATE now (True=source printed a gap, honored verbatim even CJK-CJK; False=glued; absent=unknown, CJK heuristic) in parsers_ttml._finish_parts, the device join wbwDisplayTextForLyric (LyricsSheet.x:~5799) AND cache._bake_part_separators; _PARSER_EPOCH 5->6 = one refetch per entry. (3) chip rescue link fix (b37d952): [YTIButtonRenderer class] hard-imports _OBJC_CLASS_$_YTIButtonRenderer and the target resolves no binary class symbols -> %c(). Earlier in the run: chip marker scope (c3f4aaa), rescue+mini cover base walk (ea2e4fb), retitle gate (0e215b9), translate English rows (c6af85e). TRAPS: PS 5.1 eats quotes in git commit -m (use -F file); a cancelled CI run still consumes the run number (352-354 were cancels, 6b21643 shipped as 355); the extension concatenates parts verbatim, so the bake - not the device join - is what it sees.`
- `[DONE] ses_dlcap_20261103 | M6 mini-cover platter fixed as Build 349 (728b0f4): YTMUMiniTree kills ALL art-layer animations per pass (YT 9.35 rotates its own mini art - nothing of ours rotates) + near-square black containers under the art (<=72pt) take the 7pt radius and drop their fill = ONE rounded rect ("same rect with rounded"); tile range 38-56 -> 30-64; two device-only unknowns: rotation may live above the art layer, a >72pt black base escapes the break; prior: seek-bar decolor Build 347 (4bf156c, frames-only + neutral knob, docs F1 recorded 345 observation: accent bar != warm block -> our paint off F1 suspects) | files: Source/MiniPlayerLiquidGlassV3.xm, Source/FullPlayerLiquidGlassV2.xm, docs/ux-audit-fullplayer-and-lyrics.md | next: device verify 347+349 (bar stock color + smooth + knob, mini cover one rounded rect no rotation); [investigate] batch still wants a dump: F1 warm scrim block, F2 real inset frames, M1 empty panel, L9 scroll 37% measurement, L10 dark shadow on current line, L14 half-glyph wipe |`
- `[DONE] ses_now | EIGHT batches: ... (1) sweep+ladder, (2) translate off-by-one + spacer, (3) player chrome follows song (1a68cb5), (4) provider cache + delay marks + transport ink + base radius (Build 310), (5) carousel current-page gate + chips song glass + landscape crop (Build 312), (6) search red ring -> glass border + video overlay cover-card crop (Build 313), (7) mini player song glass per-pass re-tint (Build 314), (8) version display = app-version.build ("9.26.2.<run_number>" via TWEAK_BUILD in Makefile+CI footer/Debug/dump) + search RESULT LIST hooked (YTLightweightCollectionViewController chain, force-dark trait) (95dbdeb = Build 315 released), (9) search white ROUND THREE: 316 dumps (deployed-server, user-provided) proved BrowseBackground hidden but rows still white = ASDK nodes rasterize their own bg -> YTMUStyleSearchPageDepth reads _ASDisplayView's node via NSSelectorFromString and flattens white system colors to clear through ASDK (3befbbe = Build 317 released), (10) search white ROUND FOUR: YOUR debug proved the white is OURS (searchV2 toggle) -- Screen transparentised + walk killed only 2 exact pointer fills + YTMUStyleSearchText painted all labels white on the never-darkened bg; fix = OWN the base (YTMULGOlive() ink on the search controller view, no more guessing the app's fill) + resolved-lightness kill (neutral spread<=.06 & max>=.72 & a>=.5 -> clear) at view AND ASDK node level (3befbbe was 317, round-4 e8e3839 = Build 318 released), (11) L10N batch: strings fixes (蟾幕->螢幕, duet garbage, 標穤->標籤, pinyin zh, script-normalize sentence dropped from all 14 lproj) (d45339e) + lyrics settings page fully LOC()-ed (~40 literals -> 92 keys en/zh-Hant/zh-Hans, other langs fall back to en) + translate target = action-sheet from fixed list (native names, "auto" follows device via YTMUTargetLang BCP-47 resolve, no more typed codes/zh-TW seed) (77d707a) + lyrics entry button force-visibility unconditional (lyricsEntryButtonEnabled pref + LG row + g_ytmuOwnLyricsButton + keys removed) (8b64394); open: blur-by-distance, lock-screen, estimated sweep, meanings, credit label | files: Source/{LyricsSheet,LyricsCore,DynamicArtworkThemeV2,FullPlayerLiquidGlassV2,MiniPlayerLiquidGlassV3,VideoOverlayCompatibilityV2,BrowseEntityDownloadsV2}.x(m), Source/{Prefs/*,YTMUVisualStyle,YTMULiquidGlassPreferences,LyricsShared}.h+.m, Makefile, .github/workflows/main.yml, server/* | next: device verify 312-315 (theme, chips, +Xs, providers instant, landscape crop, search no red/white, video card no bands, mini song glass, footer 9.26.2.315), webhook key answers: HOOK_SECRET GitHub secret (release-hook) vs Copy push key on dashboard JWT Pool page (jwt_push_key in config/admin_config.json), tmp/synobjcxx.sh is the ObjC++ single-file harness for .xm with extern-C`
- `[DONE] ses_now | search crash + wipe mismatch + size/spacing + per-word slide + parity doc | files: Source/Headers/YTMUBulkHook.h, Source/BrowseEntityDownloadsV2.xm, Source/YTMUVisualStyle.h, Source/LyricsSheet.x, docs/lyrics-parity.md | next: none this turn | does: THE CRASH — YTMUBulkHook saved the same (inherited) Method twice when two listed classes share one unoverridden selector (YTMSearchBarViewV2 next to YTMSearchBoxView from 53889f9), so the second class's orig WAS the replacement and its first layout pass recursed to death; fixed with an already-is-replacement skip plus class_addMethod copy for non-owner classes, ownership by pointer compare (method_getClass undeclared in this SDK). The WIPE MISMATCH was the reveal label carrying NSKern 0.08 the base copy lacked (different wrapping) AND alignment missing from the measuring layout manager (right-aligned duet rows lit their mirror) — both copies now build from ONE attribute set. "ONLY THE LAST WORD LIT" was YTMUAppendRevealedWords trimming the first rect of a wrapped line against the previous line's edge (TextKit restarts x per row) — ladder restarts per visual line now. Jumping was shouldRasterize on a mask that changes per frame (mask swaps do not dirty the raster cache). 464c942 + b4db7a2 + 43d4709. TRAPS: a locations/frame write outside a disabled CATransaction takes a 0.25s implicit animation and the feather trails the song; reading .text.length on an attributed label silently blanks the fade-out path.`
- `[DONE] ses_f033796faffeC32ISpNDwW0STV | fitted lyric size + wipe word-level reveal + white ink landed | files: Source/LyricsSheet.x, Source/LyricsShared.h, Source/YTMUVisualStyle.h | next: device check | does: the fitted-size work (TextKit YTMUVisualLineCount, floor 18pt, rotation re-fit) rode into commit a6f350c TOGETHER with the wipe changes (they were one uncommitted tree), so it is NOT a separate commit as originally intended; the follow-up wipe/mismatch/size work is 464c942. TRAPS: see 464c942 message for the three wipe bugs (kern mismatch, wrapped-line ladder trim, rasterized mask staleness).`
- `[ACTIVE] ses_eff28f66affdILC3ZVe9BGTjCE | extension ported to upstream 3.0.0.4 on branch ytmU-3.0 (+ manual push button); needs a real browser, then a PR | files: better-lyrics src/modules/lyrics/providers/{ytmu,ytmuUpgrade}.ts, src/options/{background,options}.ts, manifest.json; server/routes_admin.py | next: build the extension from ytmU-3.0 and confirm (a) the Sources page shows the key field + toggle + Send current lyrics, (b) a cold song no longer sits on "still searching" for 46s — the provider now resolves empty at 2.5s and the server finishes in the background, (c) a song the server lacks gets pushed back. TRAPS: a provider timeout must record tier -1, not nothing — "never asked" and "the server has nothing" are different states and only the second is fillable; the 2.4.0 ordering put ytmu-PLAIN at priority 2 where it beat every richsynced provider, so the three keys sit inside their own tier now; and 2 of the 54 upstream self-checks (bundle-sizes, ui-guards) fail on a CLEAN 3.0.0.4 tree here, so they are baseline`
- `[DONE] ses_eff28f66affdILC3ZVe9BGTjCE | the extension is a two-way street now: same endpoint as the iOS app, its race upgrades OUR cache, our [instrumental] flag renders | files: server/library.py, server/routes_admin.py, server/routes_library.py, C:/Users/chiuhuang/better-lyrics/src/modules/lyrics/providers/{ytmu,ytmuUpgrade}.ts | next: none — open items: the extension half is committed on better-lyrics `master` (f7229df, still ahead of myfork/master by 2), untested in a real browser; the server half is 5496bc5, also unpushed | does: `fast=1` was the whole complaint — it is LRCLib+YouTube+fast Google, no JWT, writes the :fast key while the phone reads the full one, so the browser could be served line/plain for a song we had wbw for. library.apply_lyrics_payload is now the ONE write path for both the dashboard apply and POST /api/lyrics/contribute (key auth, same key as the JWT push, no CORS). require_better=True + tier read AFTER sanitize is the whole safety argument; :fast sibling upgraded too or the phone shows pre-upgrade lyrics for the first seconds. TRAPS: an ABSENT tier record is not -1 (never asked != had nothing, and reading it as empty makes every provider an upgrade); a 401 clears the pushed mark but a refusal does not; and `npm run lint` here reformats 15 unrelated files, so stage only what you touched`
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
  real fatal error (that was `6a7fd48`).

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
  **UI DUMPS land on the DEPLOYED server, not this dev machine** — the local
  `logs/UI_DUMP_*.txt` are relics and must not be used to diagnose the
  current device state. Ask the user to pull the fresh dump from the
  deployed dashboard, then reason from THAT file (once it is attached, treat
  it as the only viewpoint; old dumps still describe stable YT class
  hierarchies but never the current fix state).
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
- `716b99d` + `5e9b141` — the wipe is ONE continuous sweep (knots {ms,x,slope} per
  VISUAL row, fixed-width feather strip, Fritsch-Carlson) and the distance ladder
  keeps its anchor through inter-line gaps; server: opencc self-heals at import +
  pip re-runs only when requirements.txt's sha256 changed, and ja kanji rows are
  repaired out of the poisoned cache on serve ([StaleHan]). TRAPS: knot x values
  are per VISUAL row because TextKit restarts x at each wrap (whole-line knots
  run backwards); the translate cache key MUST carry song_lang or the SKIPPING
  pass's entries keep hitting forever no matter how the skip logic is fixed; and
  `YTMUBuildRowKnots` needs the GLOBAL part indices — starts/ends are
  part-indexed, a row is only a subset.
- `2a24e48` + `8cde2d7` — the shared visual header now imports the C-linkage
  artwork API declarations; the build completes when the 110 MB IPA passes
  compile/injection, and a Cloudflare 413 from the optional Asia mirror no
  longer blocks the GitHub CDN release (Build 291). Trap: dynamic mirror URLs
  must use the step output in release expressions, not `env` written later.
- `53889f9` — the search field now uses the YTM red-accented glass capsule;
  observed search/response controllers get dark text, transparent surfaces,
  rounded image content, and restrained table separators. Trap: the search
  dump shows suggestions but not submitted results, so collection-cell
  separators/cards are intentionally omitted until that hierarchy is logged.
- `d34698f` — the AltStore source lists the build TWICE (Asia file CDN first,
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
- `5496bc5` + better-lyrics `f7229df` — the extension stopped asking for the
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
- `a649070` — the JWT pool counts the requests a token really served (the old
  `successes` moved only for probes) and keeps a ledger of retired tokens with
  the reason, so "requests before death" is a fact. Charts on the JWT Pool page.
  Trap: two bookkeeping entry points per HTTP site is how a strike goes missing
  silently, and `el()` used to coerce only string children — a numeric tile value
  was a TypeError that took the page render with it.
- `3426ea9` — a Settings page for THIS server, split out of the App page: the
  wbw second Cubey pass is a server-only key that was being rendered inside the
  page promising every switch reaches every device. The schema now carries
  `GROUPS_REMOTE`/`GROUPS_SERVER` and one renderer draws both. New keys:
  `fetch.wbw_retry_delay_s` (float — an int-typed 0.8s default rounds to 1s and
  nobody would notice) and `bulk.*` defaults for a new job.
## Open / pending
- **The parser audit: TTML + LRC + QRC + credits + SRT are DONE
  (`fa55839`, `b46006c`; SRT = `server/parsers_srt.py` dispatched through
  `parse_synced_text` into every Cubey/bLyrics raw-text path); the device's
  ruby/obscene rendering and TTML rows 1.10/1.11/1.13/1.23-1.25 are open.**
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
