# server/ — endpoint auth map

Flask app, port 20016 (`python proxy_server.py` or `.venv\Scripts\python -c
"from server import main; main()"`). This file is the one-glance answer to
"who can call what". Nothing here overrides the code; when they disagree,
the code wins and this file gets fixed.

## PUBLIC — no auth (the tweak's world)

| Endpoint | Notes |
|---|---|
| `GET /api/lyrics/...` | lyrics fetch/serve, `probe=1` / `pdata=1` modes |
| `GET /api/lyrics/stream` | THE lyrics SSE route the device uses |
| `GET /api/update` | update check; `?channel=beta` opt-in |
| `GET /api/app/altstore` | AltStore source, STABLE channel |
| `GET /api/app/altstore-beta` | AltStore source, BETA channel (`?channel=beta` equivalent) |
| `GET /api/app/settings` | tweak remote config (public half of app_settings) |
| `GET /privacy` | the privacy policy page |

## OWNER-KEY — a shared secret, not a session

| Endpoint | Secret | Who holds it |
|---|---|---|
| `POST /api/app/release-hook` | `X-YTMU-Hook` header = GitHub secret `HOOK_SECRET` | CI workflow only (value also lives in the server env `YTMU_HOOK_SECRET` or admin_config `hook_secret`) |
| `POST /api/jwt/push` | push key in the body/header | the browser userscript / extension (key from the dashboard JWT Pool page "Copy push key"; `jwt_push_key` in admin_config) |
| `POST /api/lyrics/contribute` | same push key | the browser extension (two-way: its wins upgrade our cache) |

The userscript/extension is OWNER-ONLY tooling: the push key is the owner's.
It is not distributed; a third party holding it could write lyrics into the
cache (tier-checked, never worse than what we serve) and burn JWT pool
requests. Do not publish it anywhere.

## OWNER-DEBUG — paired device token, default OFF

| Endpoint | Gate |
|---|---|
| `POST /api/debug/enroll` | one-time OTP the operator generates on the dashboard |
| `POST /api/debug/upload` | `X-YTMU-Debug-Token` = the token enroll handed out |
| `GET /api/debug/fetch` | same token (device reads back logs/crashes) |

Debug is OFF on every install until the owner flips the debug toggle inside
the Debug settings page (hidden entry: long-press the build footer on the
main tweak settings page). Records uploaded this way are tagged
`owner_debug: true` and may carry request bodies (capped) that no other
path ever sends.

## OWNER SESSION — dashboard

`/` and everything under `/api/admin/*` (password session). Includes
release channels (`/api/admin/channels` + `promote`), instances
(`/api/admin/instances`), debug pairing OTP, logs, caches, library.

## NODES — mesh identity

Nodes authenticate with `node_id` + `node_key` (created on the dashboard
Nodes page). Pull-only for lyrics cache; JWT pool sync is push and can be
disabled per node with `"jwt_sync": false`.
