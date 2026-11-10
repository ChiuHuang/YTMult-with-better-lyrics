# Ownership and debug policy

What is owner-only, what debug means, when debug is on, and what a STABLE
install sends or shows. Applies to the iOS tweak, the dashboard and the
browser extension/userscript.

## Channels are labels on the same binary

Every CI release is born BETA (`prerelease: true`). Promotion moves a build
to STABLE (dashboard card + `gh release edit build-N --prerelease=false
--latest`). THE SAME PACKED IPA serves both channels; nothing is stripped at
compile time. What makes "stable = no debug" true is runtime gating: every
debug path checks the paired-device state BEFORE doing any work, so an
install without the pairing does nothing, costs nothing and shows nothing.

## Debug is default OFF, and only on when ALL of these hold

1. The debug toggle inside the Debug settings page is ON (off on every fresh
   install). The page's row in the main settings list is hidden while the
   toggle is off; the owner door into the page is a long-press on the build
   footer of the main tweak settings page.
2. A pairing token exists (one-time OTP generated on the dashboard, typed on
   the device, exchanged for a token). No token = uploads refuse at both
   ends (`YTMUDebugDeviceEnabled() && YTMUDebugHasToken()`).
3. Every record upload is tagged `owner_debug: true`.

Debug surfaces (device): the census/probe hooks (class lists, scheme lists,
playback outcomes), the Debug settings page (stream status, log level,
upload switches, test log). Debug surfaces (dashboard): paired devices,
capture files (view + FULL download), recent records, OTP generation.

None of it runs on a stable install: the census gate sits before its
`dispatch_once`, the play-attempt bookkeeping builds nothing (nil-dict),
response probes and playback-event notes return at their first line.

## What leaves a STABLE install

- The lyrics fetches and update checks any build makes (same code path for
  everyone), plus one count ping (below).
- NOTHING else. No logs, no dumps, no bodies, no telemetry beyond the count.

## The count ping (device-count statistics)

- The device stores ONE random UUID it generated itself and sends it ONLY to
  `POST /api/app/ping` ({uid, channel}) — on a dedicated route, nothing
  else rides along.
- The server stores a SALTED HASH of the uid (the salt never leaves the
  server), the channel (`stable` / `debug`, from the debug toggle) and a
  lastSeen timestamp. Counts are stable-count and debug-count separately.
- The raw uid is not reconstructable from the hash without the server salt;
  the device could regenerate it at any time by clearing the pref.

## The privacy policy page

`GET /privacy` renders the public policy: what the server keeps (lyrics
cache contents for fetched songs, salted-hash device counts, crash logs,
debug captures from paired devices only), for how long, and how to vanish
(clear the pref on the device for a new identity; unpair/revoke on the
dashboard for capture removal).
