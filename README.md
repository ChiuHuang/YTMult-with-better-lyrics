# YTMusicUltimate (with better lyrics)

YouTube Music iOS tweak + a self-hosted lyrics server: synced and
word-synced lyrics, multi-provider race, translation, and an admin dashboard.
Open source — forks and pull requests welcome.

## Download


- **Releases (IPA):** https://github.com/ChiuHuang/YTMult-with-better-lyrics/releases
  Every push to `main` builds `YTMusicUltimate.ipa` as `build-N`.
<a href="https://stikstore.app/altdirect/?url=https://ytmtranslate.chiuhuang.dev/api/app/altstore" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200"/>
</a>
- **AltStore:** add this source URL (or paste it on altdirect.app):
  `https://ytmtranslate.chiuhuang.dev/api/app/altstore`
- **Jailbreak (.deb):** build locally with Theos (below).

You need a **decrypted** YouTube Music IPA as the base (cannot be provided
here for legal reasons). Upload it somewhere with a direct link
(filebin.net, Dropbox, or your own file host).

## Build your own IPA with GitHub Actions

1. Fork this repo.
2. Fork settings → Actions → enable Read and Write permissions.
3. Actions tab → "Build and Release YTMusicUltimate" → Run workflow,
   paste your decrypted IPA URL (plus optional app name / bundle ID).
4. The IPA appears under your fork's Releases. Optional repo secrets for
   the Asia mirror step: `FILE_UPLOAD_URL`, `FILE_UPLOAD_TOKEN`,
   `FILE_UPLOAD_FIELD` (multipart field name, default `file`).

Build troubleshooting: 99% of failures are the base IPA (must be decrypted
`.ipa`, direct link). If the run is green but you can't find output, append
`/releases` to your fork URL.

## Build the .deb locally

1. Install [Theos](https://theos.dev/docs/installation).
2. Clone this repo, then:
   - `make clean package` — rootful jailbreak
   - `make clean package ROOTLESS=1` — rootless jailbreak
   - `make clean package SIDELOADING=1` — for IPA injection
     (see [Azule](https://github.com/Al4ise/Azule) for injection)

## Lyrics server

The tweak fetches lyrics from the included Python server (default
`https://ytmtranslate.chiuhuang.dev`, changeable in tweak settings).

```sh
python proxy_server.py        # listens on :20016
```

- First run copies: `config/ai_providers.example.json` →
  `config/ai_providers.json` (translation/retitle keys, gitignored),
  `config/app_settings.example.json` → `config/app_settings.json`
  (tweak remote config). Never commit the real files.
- Extra keys via env: `YTMU_COHERE_KEYS`, `ORCAROUTER_API_KEY`
  (`YTMU_ORCA_BASE`, `YTMU_ORCA_MODEL`).
- Dashboard (password-gated): live logs, library manager (rebase, bulk
  refetch, retitle, translate queue), JWT pool, nodes, self-update, crash
  logs, and the **App** tab (tweak remote config served at
  `/api/app/settings`).
- Device debug uploads land in `logs/`; on-device lyrics cache is never
  poisoned by not-found results.

## Tweak features (highlights)

- Apple-Music-style sliding word highlight, 120fps link, extrapolated clock
- Provider race (Cubey/QQ/KuGou/BiniLyrics/LRCLib/Unison/AMLL/YouTube),
  per-video provider switcher, probe-and-pick from dashboard
- Background auto-sync of server translations into the on-device cache
  (every 6h, toggle in Lyrics settings)
- Liquid Glass mini-player surface, landscape lyrics, FPS meter
- In-app update check (Settings → Check for updates) with proxied download

## Repo layout

- `Source/` — the tweak (Theos/Logos)
- `server/` — lyrics server (`proxy_server.py` is a thin shim)
- `static/dash.js`, `templates/index.html` — admin dashboard
- `.github/workflows/main.yml` — build + release + mirror

Fork of [YTMusicUltimate](https://github.com/ginsudev/YTMusicUltimate)
by Ginsu and Dayanch96. Lyrics system, server, and dashboard by ChiuHuang.
