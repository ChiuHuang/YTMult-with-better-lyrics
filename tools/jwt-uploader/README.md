# YTMU JWT Uploader

Two ways in, same destination:

- **`ytmu-jwt-push.user.js`** — a userscript. Silent: no popup, no badge, no
  notification, nothing added to the page. Solve the challenge once and the
  token is in the pool. This is the one to use if you do not want to notice it.
- **the extension** (`manifest.json` + `background.js` + `challenge.js` +
  `popup.*`) — the same flow with a popup: a live pool count, a probe button, a
  timer, `alt+shift+j`, and a paste-a-token box.

Server side, both post to `/api/jwt/push` with the push key (userscript) or to
`/api/admin/jwt/contribute` with the dashboard session (extension).

## The silent one: `ytmu-jwt-push.user.js`

1. dashboard -> **JWT Pool** -> **Copy push key**
2. paste it into `CONFIG.key` (and your server into `CONFIG.server`) at the top
   of the file, or set it at runtime without editing:
   `GM_setValue('cfg', {server:'http://192.168.1.5:20016', key:'<push key>'})`
3. save the file; Tampermonkey/Violentmonkey installs it
4. open `https://lyrics.api.dacubeking.com/challenge` once

That is the whole setup. The script takes the Turnstile response, exchanges it
at `/verify-turnstile`, and `POST`s the JWT to `/api/jwt/push` with
`X-YTMU-Key`. No UI, no DOM changes, no console output unless something fails
(and then exactly one warning line, ever).

`CONFIG.auto = true` plus an uncommented `@match *://*/*` makes it fully
automatic: it drops a 2x2px iframe of the challenge page into pages you
already visit, at most once every `CONFIG.autoEveryMin` minutes. Cloudflare may
not solve the widget in a frame that is effectively invisible, so treat that as
best-effort; the manual page always works.

## Extension install

1. `chrome://extensions` -> Developer mode on -> **Load unpacked**
2. pick this folder (`tools/jwt-uploader`)
3. pin it (the puzzle-piece menu -> the extension)

## One-time setup

Log into the dashboard once in a normal tab (`http://<host>:20016/`). That
session cookie is what authorises the admin endpoints; the extension reuses it.

Nothing else is configured. The server url defaults to
`http://localhost:20016`; set it in the popup (a bare `192.168.1.5:20016` works,
`http://` is assumed) and press **save**.

## Use

| Action | How |
| --- | --- |
| Upload now | popup -> **Get JWT + upload**, or `alt+shift+j` from any page |
| Upload a token you already have | paste it in the popup -> **send** |
| Upload without clicking anything | open `https://lyrics.api.dacubeking.com/challenge`, solve it, and the token is uploaded on the spot |
| Keep the pool warm | popup -> `auto` -> every 15 min / 30 min / hour / 3 h |
| See the pool | the `pool N` chip, refreshed whenever the popup opens |
| Re-probe + evict dead tokens | popup -> **probe** (`POST /api/admin/jwt/check`) |
| Stop a run | the main button turns into **cancel** while it runs |

The toolbar badge shows the last outcome: `..` running, `OK` uploaded, `X`
failed, and a notification fires when a run finishes from the keyboard shortcut
or the timer (i.e. with the popup closed).

## How a run works

1. a hidden tab opens `https://lyrics.api.dacubeking.com/challenge`
2. `challenge.js` picks up the Turnstile response two ways: the page's own
   `window.parent.postMessage({type:'turnstile-token'})` (the top window is its
   own parent when the page is a tab), and a poll of the widget's hidden
   `input[name=cf-turnstile-response]`. Whichever lands first wins.
3. the worker POSTs that token to `/verify-turnstile` and gets `{jwt}`
4. the JWT is POSTed to the server pool
5. the tab this extension opened is closed again. A tab you opened yourself is
   left alone, and a challenge that is still waiting for a click is left open
   on purpose -- solve it and step 2 continues without another click.

## How it authenticates (and why there are two paths)

The admin endpoints only answer an authenticated session cookie
(`login_required` in `server/routes_admin.py`). Flask's session cookie carries
no `SameSite` attribute, so browsers treat it as `Lax` and will not attach it
to a cross-site POST from the extension.

So every call is tried twice:

1. **from the extension** -- `host_permissions` bypass CORS, and if Chrome
   decides to send the cookie anyway, this is the fast path;
2. **inside a tab on the server** -- if step 1 came back as the login page, the
   same request is re-run by `chrome.scripting.executeScript` in a tab that is
   already on the server origin. It is an ordinary same-origin request, so the
   cookie is sent the way any page request sends it. That path works as long as
   step one of the setup above is done.

`read via extension` / `read via tab` in the pool tooltip and the `via` field in
the log tell you which one ran.

## Notes

- The JWT is never written to `chrome.storage`. Only its length, the first 8
  characters and its `exp` claim are kept for the log line.
- `node_id` is sent as `chrome-ext`, so the dashboard's JWT table shows where a
  token came from.
- Host permissions are `http://*/*` and `https://*/*` because the server's
  address (LAN ip, port, tunnel) changes; narrow them in `manifest.json` if you
  always use one host.
- Nothing in the repo depends on this extension. It is only a faster way to
  feed the pool that the device, the nodes and `dash.js` feed on their own.

## Troubleshooting

| Message | Cause |
| --- | --- |
| `not logged in: open ... in a tab and log in once` | no dashboard session in this browser profile |
| `server unreachable: Failed to fetch` | wrong host/port, or the server is down |
| `could not run the request in tab N` | a tab on that origin is stuck loading; close it, or hit the dashboard button to open a fresh one |
| `timed out waiting for the Turnstile token` | Cloudflare wanted a click; the tab was left open, solve it there |
| `verify-turnstile did not return a JWT` | the challenge was rejected upstream; retry |
| pool chip says `no session` / `offline` | same as the first two rows, the chip tooltip has the detail |

## Files

- `manifest.json` -- MV3, permissions, content script, `alt+shift+j`
- `background.js` -- the whole run: challenge tab, verify, upload, pool reads,
  alarm, hotkey, storage-backed job state (so a run survives the worker being
  idled or the popup being closed)
- `challenge.js` -- content script on the challenge page, token relay only
- `popup.html` / `popup.css` / `popup.js` -- the view; all work is in the worker
- `ytmu-jwt-push.user.js` -- the silent userscript (no extension needed)
