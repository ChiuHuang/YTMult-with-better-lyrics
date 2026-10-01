# Settings API (`/api/app/settings`)

Remote config for the tweak. The dashboard writes it, every device reads it
over plain HTTP with no auth, and it is deliberately flat: a string/number/
boolean map, no nesting, no secrets.

| | |
|---|---|
| Storage | `config/app_settings.json` (gitignored; created on first write) |
| Server code | `server/app_settings.py` (load/save/validate) |
| Routes | `server/routes_misc.py` (public read), `server/routes_admin.py` (CRUD) |
| Dashboard | App tab, `static/dash.js` (`renderApp`, `app-set`, `app-reset`) |
| Device read | `Source/LyricsCore.x` (`YTMUFetchAppSettings`, `YTMUAppSettingBool`) |
| Per-build kill switch | `server/kill_switch.py` — see *Targeted kill switch* |

Two levels, and the distinction is the whole point:

- **Flat keys** (`ui.liquid_glass`, `ui.lyricsV2Enabled`, ...) reach **every
  device on every build**. They are the right tool for an emergency.
- **Kill targets** reach **a chosen build**. They are the right tool for "this
  release is broken", which is the case that actually happens.

## Merge order

`get_all()` returns **defaults, overlaid by the file**:

```python
d = dict(_DEFAULTS)      # server/app_settings.py
d.update(_load_file())   # config/app_settings.json
```

So a key in the file always wins, and deleting a key restores the default
rather than removing it. A read never raises: a missing or corrupt file is
an empty override set, not an error.

## Rules

Key (`_check_key`, `_KEY_RE`):

- `^[A-Za-z0-9_.-]{1,64}$` -- letters, digits, `_`, `.`, `-`; max 64 chars.
- Anything else is a `400`.

Value (`_check_value`):

- `str`, `bool`, `int`, `float` only. `null`, lists and objects are a `400`.
- Strings are capped at 4000 chars.
- Stored verbatim: the server never coerces `"false"` into `False`. The device
  does that itself (see *Device side* below), so a string that *looks* like a
  bool is still a string here.

Writes are serialized by a module-level lock and go through a `.tmp` file plus
`os.replace`, so a reader never sees a half-written file.

## Endpoints

| Method | Path | Auth | Body | Returns |
|---|---|---|---|---|
| `GET` | `/api/app/settings` | none | `?sha=&v=&rev=` | `{ok, settings, rev, kill, sha}` |
| `GET` | `/api/admin/app/settings` | session | - | `{ok, settings}` |
| `POST` | `/api/admin/app/settings` | session | `{key, value}` | `{ok, settings}` |
| `DELETE` | `/api/admin/app/settings` | session | `{key}` | `{ok, removed, settings}` |
| `POST` | `/api/admin/app/settings/reset` | session | - | `{ok, settings}` |

Every admin response carries the **full merged map** after the change, so a
client can re-render from one round trip (the dashboard does exactly that).

### `GET /api/app/settings` (public)

```sh
curl -s https://ytmtranslate.chiuhuang.dev/api/app/settings
curl -s 'https://ytmtranslate.chiuhuang.dev/api/app/settings?sha=abc123def456&v=2.4.1'
```

```json
{"ok": true, "settings": {"upload_logs": true}, "rev": "6f1a...",
 "kill": [], "sha": "abc123def456"}
```

Open by design: the device has no credentials. **Never put a secret in here.**

| Param | Meaning |
|---|---|
| `sha` | The build the caller is running (`TWEAK_GIT_COMMIT`, 12 hex chars). Kill targets matching **this** build are folded into `settings`, and the build is recorded in the census. |
| `v` | Tweak version, stored next to the count for display only. |
| `rev` | The `rev` the caller already holds. If nothing that would change the answer has, the response is `{"ok":true,"unchanged":true,"rev":...}` with **no** `settings` key. |

All three are optional. Without `sha` the caller is unidentified and receives
only the flat map plus any selector-less (blanket) target — a build-scoped
target never applies to a caller that cannot say what it is running.

`settings` is resolved, not raw: `kill` lists the ids of the targets that fired,
so a client can log which ones hit it.

## Targeted kill switch

The flat keys are **every device, every build**. `ui.liquid_glass = false` turns
off every Liquid Glass surface on every phone, which is fine for an emergency
and useless for "build-42 renders the player wrong, take the glass away from
the people on build-42". The kill switch targets a **build** instead.

| | |
|---|---|
| Code | `server/kill_switch.py` |
| Storage | `config/kill_targets.json` (gitignored), census in `database/kill_census.json` |
| Admin API | `GET/POST/DELETE /api/admin/kill/targets`, `GET /api/admin/kill/preview?sha=` |
| Dashboard | App tab, *Targeted kill switch* |
| Device | nothing but `?sha=` — it never evaluates a selector |

### Selectors

Exactly one per target:

| Selector | Matches | Resolved by |
|---|---|---|
| `sha` | one build, by (possibly short) hex prefix | string prefix |
| `tag` | one release, by tag name | `git rev-list -n 1 <tag>` |
| `from_sha` + `to_sha` | a contiguous window of first-parent history | index arithmetic over `git log --first-parent` |
| *(none)* | every build — the legacy blanket | nothing needed |

Both range endpoints are optional: `from_sha` alone means "this build and
everything after it", `to_sha` alone means "everything up to it". Reversed
endpoints are the same window. "From A to B" is the usual case: a regression
lands, a few commits later somebody finds it, so the bad window is a range.

A device only ever learns its sha, never its tag, so the tag→sha and range
mappings have to live on a machine with the repository. That is why the whole
decision is server-side and the device reads a finished verdict.

### Actions

One action per target, and each maps to exactly one remote key:

| `scope` | Turns off | Effect |
|---|---|---|
| `lg` | `ui.liquid_glass` | every V2 surface (the old blanket switch) |
| `tweak` | `ui.tweak` | the glass stack master itself, both generations |
| `surface` + `key` | `ui.<key>` | one surface, named by its `device_key` |

Targets stack: several can apply to the same build, and every matched one turns
its key off.

`scope=surface` can only name a key that is genuinely reachable: the picker is fed
from the `_SCHEMA` `device_key` list, which is exactly the 18 keys that go through
`YTMULGFeatureEnabled`. The six extra keys in `YTMULGDefaultPreferences`
(`videoV2Enabled`, `landscapePlayerV2Enabled`, `lyricsEntryButtonEnabled`,
`lyricsProviderAllFetchEnabled`, `reduceTransparencyFallbackEnabled`,
`reduceGlassMotionEnabled`) are local-only prefs whose features never consult the
remote gate, so the server cannot reach them and they are not offered. That is
by design, not a gap in the picker.

### Census

`record_poll` runs on every settings read that carries a `sha`, so the device
count costs nothing extra. Keyed by sha, de-duplicated by client IP (the
`usage_stats` precedent — one phone must not read as two, and a phone behind
carrier NAT cannot be told apart from its neighbours anyway).

`devices` counts only IPs seen in the last 30 days; `devices_total` is
unpruned. Both are shown, because "0 live / 900 ever" is the shape of a build
everybody already left, and arming against it is a no-op.

### Validation

`POST` returns `400`, not a stored row that looks armed, when:

- `scope` is not one of the three, or `scope=surface` has no/unknown `key`
- `sha` is not 4-40 hex chars (or the literal `unknown`)
- more than one selector is given
- a range endpoint is not in the last 400 commits

### Traps

- A selector that **cannot** be resolved kills **nobody**, and never everybody.
  An unresolvable tag, an out-of-window range endpoint, or a device that sent
  no sha all fall on the "no match" side. A kill switch that guesses is worse
  than no kill switch.
- `unknown` is compared **exactly**, never as a prefix. `unknown` is a word the
  Makefile bakes when git was unavailable, not hex; prefix-matching it would
  let a target for the sha `unk` silently capture every such device.
- Git facts are cached for 5 minutes. A sha outside the 400-commit window
  resolves as "no match", not as "error" — the window exists so the range math
  stays index arithmetic over a bounded list. A **tag** outside the window still
  resolves (and still shows in the picker); only a *range* endpoint cannot,
  because the window is the range's coordinate system.
- The tag listing is parsed on a literal NUL (`%00`), not `%x1f`.
  `git for-each-ref` does not expand `%xNN` the way `git log --format` does — it
  emits the six characters verbatim, so a `%x1f` format parses as one field and
  the tag list comes back **empty with no error**. Same trap for `|`, which is a
  legal refname character.
- `rev` is a digest of the **resolved** map, so two builds with no target
  applied share one and nobody refetches for nothing. Arming or disarming a
  target moves it, which is what forces a device holding the old one to
  refetch.
- Folding only ever sets keys to `false`. It never re-enables one, so an
  explicit `ui.liquid_glass = false` in the file stays false on every build.

### `GET /api/admin/app/settings`

Same body as the public read. Useful only to tell "override" from "default",
which the merged map does not show.

### `POST /api/admin/app/settings`

```sh
curl -s -X POST https://host/api/admin/app/settings \
  -H 'Content-Type: application/json' \
  -b cookies.txt -c cookies.txt \
  -d '{"key":"upload_logs","value":false}'
```

```json
{"ok": true, "settings": {"upload_logs": false}}
```

Sets exactly one key, creating or overwriting it. Response `400`:

```json
{"ok": false, "error": "bad key (a-z 0-9 _ . - , max 64)"}
{"ok": false, "error": "value must be string/number/boolean"}
```

### `DELETE /api/admin/app/settings`

```sh
curl -s -X DELETE https://host/api/admin/app/settings \
  -H 'Content-Type: application/json' -b cookies.txt \
  -d '{"key":"upload_logs"}'
```

```json
{"ok": true, "removed": true, "settings": {"upload_logs": true}}
```

`removed` is `false` when the key had no override (the defaults still apply, so
deleting `upload_logs` when it was never set changes nothing visible). A
malformed key is a `400`, not a `500`.

### `POST /api/admin/app/settings/reset`

Drops **every** override: the file is rewritten as `{}` and the response is
the defaults-only map. There is no undo -- re-post the keys you want back.

## Auth

`login_required` (`server/app.py`) checks the Flask session flag
`admin_logged_in`. Consequences worth knowing before you script against it:

- An unauthenticated admin call returns **`302` to `/login`**, not `401`, and
  the body is an HTML page. `curl -f` will not flag it; check the status.
- If no password has been set yet, `/login` itself redirects to `/setup`.
- The session cookie is the only credential. Get one with
  `curl -c cookies.txt -d 'password=...' https://host/login` (that POST
  answers `302` to `/` on success).

## Errors

| Status | When |
|---|---|
| `200` | success (including a no-op DELETE) |
| `302` | admin route without a session -> `/login` |
| `400` | bad key, unsupported value type, string over 4000 chars |
| `500` | should not happen; anything here lands in `logs/crash.log` |

## Device side

`YTMUFetchAppSettings()` (`Source/LyricsCore.x`) fetches the public endpoint
on launch and caches the map in `NSUserDefaults` under `YTMUAppSettings`.
It is called on `WillEnterForeground` and `DidBecomeActive`, and refetches at
most once every **15 minutes** (`YTMUAppSettingsFetchedAt`). That interval used
to be 24 hours, which made every kill switch a next-day change; 15 minutes is
affordable because the call carries `?rev=`, so a poll where nothing changed
answers `{ok, unchanged, rev}` and the device skips the map write entirely.

The request also carries `?sha=<TWEAK_GIT_COMMIT>&v=<TWEAK_VERSION>`. The sha
is what makes the kill switch *targeted* (see *Targeted kill switch* above);
the device still only reads booleans and never evaluates a selector.

Read a key with:

```objc
BOOL YTMUAppSettingBool(NSString *key, BOOL dflt);
```

Its coercion, which is why the server stores strings verbatim:

| JSON value | Reads as |
|---|---|
| `true` / `false` | itself |
| `"true"` / `"1"` (any case) | `YES` |
| `"false"` / `"0"` (any case) | `NO` |
| number | `boolValue` of it |
| missing / anything else | the caller's default |

A gate is usually the AND of a device pref and a server key, so the server can
only ever turn a feature off. Example, `upload_logs`:

```objc
BOOL YTMUDebugUploadAllowed(NSString *level) {
    if (!YTMULyricsPreference(@"sendDebugLogsToServer", NO)) return NO;  // device master switch
    if (!YTMUAppSettingBool(@"upload_logs", YES)) return NO;              // server kill switch
    ...
}
```

The Debug settings page reads the same key, so the server-side switch is
visible on the device instead of looking like a dead upload.

## Known keys

| Key | Default | Effect |
|---|---|---|
| `upload_logs` | `true` | Master switch for every device->server debug upload (`POST /log`, `DEBUG_` pings, screenshot dumps). `false` silences them all. |
| `ui.remote_control` | unset (on) | The server's own master. Off means the server cannot disable anything. |
| `ui.liquid_glass` | unset (on) | Off disables every V2 Liquid Glass surface. |
| `ui.tweak` | unset (on) | Off turns off the material system itself — the remote twin of the tweak's own on/off row, both generations. |
| `ui.<feature>` | unset (on) | One surface. The 18 keys are generated from `_UI_FEATURES`; each has a `device_key` naming what the device reads. |

Every `ui.*` key is **unset by default rather than defaulted in `_DEFAULTS`**,
which is why it is absent from the public map until something writes it. That is
deliberate: "absent" means "the device's own fallback", which is on, so the map
stays small and a fold-in to `false` is the only way a key ever reads false.

## Adding a key

1. Server: add it to `_SCHEMA` in `server/app_settings.py` with a comment
   saying what it gates. Add it to `_DEFAULTS` only if it should have a
   fail-**closed** default; a `ui.*` switch wants the fail-open default of the
   device, which means no `_DEFAULTS` entry at all.
2. Device: read it with `YTMUAppSettingBool(@"your_key", <fallback>)` inside
   the decision it should gate, and declare nothing new -- the helper is
   already in `LyricsShared.h`.
3. If the device should show the current value (like the Debug page does for
   `upload_logs`), read it there too; otherwise a server-side change is
   invisible until something breaks.
4. No strings, no localization: the key is a wire name, not copy.
5. Test: `POST` the key, `GET /api/app/settings`, confirm it is public, then
   `DELETE` it and confirm the default comes back.

## Dashboard

App tab -> *App settings*. A row per key (`key = value` as JSON) with **Edit**
and **Reset** (per key, i.e. DELETE), plus a Key/Value form and *Reset
defaults*, and below them the *Targeted kill switch* panel (build picker, action
picker, preview, active targets, devices-per-build census). Both pickers are
options lists served by the server — the build list from git plus the census,
the surface list from the `_SCHEMA` device keys — so neither can name something
the device does not actually read.

The Key/Value form parses the value field the way an operator expects:
`true`/`false` become booleans, anything numeric becomes a number, empty
stays the empty string, everything else is text. It is not a JSON editor, so
a value containing a leading/trailing space is trimmed by the form and
cannot be entered from the UI -- use the API for that.

## Traps

- `config/app_settings.json` is gitignored. Losing it loses every override,
  and `reset` is the fastest way to do that by accident.
- `config/kill_targets.json` is gitignored for the same reason plus one more:
  committing an armed switch would ship it to every deploy.
- The real file is created on the first **write**; nothing copies
  `config/app_settings.example.json` at startup. That example file is a
  template to read, not a seed.
- Nothing validates that a key is a known one. A typo (`upload_log`) is
  accepted, stored, served publicly and ignored by the device.
- A `POST` with a missing `value` is a `400`, not a `null` -- there is no way
  to store a null.
- A key that only exists in the file (not in `_DEFAULTS`) is served fine, and
  the device gets the value with no default fallback behind it.
