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
| `GET` | `/api/app/settings` | none | - | `{ok, settings}` |
| `GET` | `/api/admin/app/settings` | session | - | `{ok, settings}` |
| `POST` | `/api/admin/app/settings` | session | `{key, value}` | `{ok, settings}` |
| `DELETE` | `/api/admin/app/settings` | session | `{key}` | `{ok, removed, settings}` |
| `POST` | `/api/admin/app/settings/reset` | session | - | `{ok, settings}` |

Every admin response carries the **full merged map** after the change, so a
client can re-render from one round trip (the dashboard does exactly that).

### `GET /api/app/settings` (public)

```sh
curl -s https://ytmtranslate.chiuhuang.dev/api/app/settings
```

```json
{"ok": true, "settings": {"upload_logs": true}}
```

Open by design: the device has no credentials. **Never put a secret in here.**

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
**It refetches at most once an hour** (`YTMUAppSettingsFetchedAt`), so a
change you push from the dashboard is not visible on a device that was
already open. Backgrounding and relaunching the app does not force it either;
the hour is the only thing that does.

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

## Adding a key

1. Server: add it to `_DEFAULTS` in `server/app_settings.py` with a comment
   saying what it gates. Without a default it still works, but then a
   missing key is indistinguishable from a false one, so the device must
   pass its own fallback to `YTMUAppSettingBool`.
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
defaults*. The form parses the value field the way an operator expects:
`true`/`false` become booleans, anything numeric becomes a number, empty
stays the empty string, everything else is text. It is not a JSON editor, so
a value containing a leading/trailing space is trimmed by the form and
cannot be entered from the UI -- use the API for that.

## Traps

- `config/app_settings.json` is gitignored. Losing it loses every override,
  and `reset` is the fastest way to do that by accident.
- The real file is created on the first **write**; nothing copies
  `config/app_settings.example.json` at startup. That example file is a
  template to read, not a seed.
- Nothing validates that a key is a known one. A typo (`upload_log`) is
  accepted, stored, served publicly and ignored by the device.
- A `POST` with a missing `value` is a `400`, not a `null` -- there is no way
  to store a null.
- A key that only exists in the file (not in `_DEFAULTS`) is served fine, and
  the device gets the value with no default fallback behind it.
