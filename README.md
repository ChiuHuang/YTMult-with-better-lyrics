# YTMusicUltimate (with better lyrics)

[![Latest release](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=release)](https://github.com/ChiuHuang/ytmusicultimate/releases)
[![Lyrics API](assets/badges/server.svg)](https://ytmtranslate.chiuhuang.dev)

A YouTube Music tweak for iOS that plays lyrics properly: word-by-word
highlight that follows the music, translations, and an offline-friendly
downloader. Lyrics are fetched from a small lyrics server, which is included
here and can be self-hosted.

> [!NOTE]
> You need a **decrypted** YouTube Music IPA to build. It cannot be provided
> here.

## Features

- Lyrics highlight sweeps word by word, synced to the actual playback time
- Eight lyric providers raced at once; the best one wins and upgrades in place
- Translation shown under each line, streamed in as it is translated
- Provider switcher when you prefer a different source for a song
- Audio downloads that also play in the app's own player
- Liquid glass player, landscape lyrics, mini player
- Every feature is a switch in Settings, nothing is permanent

## Install

- **AltStore / SideStore / Feather:** add this source
  `https://ytmtranslate.chiuhuang.dev/api/app/altstore`
- **IPA:** download the latest `build-N` from
  [Releases](https://github.com/ChiuHuang/ytmusicultimate/releases). Every
  push to `main` builds one.
- **Jailbreak:** build the `.deb` yourself (below).

## Build your own IPA

1. Fork this repo and allow write access for Actions (Settings → Actions →
   General).
2. Run the **Build and Release YTMusicUltimate** workflow and paste the URL of
   your decrypted IPA.
3. The IPA shows up under your fork's Releases.

For a jailbreak package, install [Theos](https://theos.dev/docs/installation)
and run `make clean package` (add `ROOTLESS=1` for a rootless jailbreak, or
`SIDELOADING=1` to inject into an IPA).

## Lyrics server

The tweak asks a server for lyrics. The public one is
`https://ytmtranslate.chiuhuang.dev`; you can point the tweak at any other
endpoint in Settings → Lyrics.

The same server is in this repo:

```sh
python proxy_server.py        # listens on :20016
```

- Add your own translation keys in `config/ai_providers.json` (there is an
  `.example.json` to copy). Config files are created on first use and are
  never committed.
- The dashboard is password-gated and opens on first run so you can set one.
- Debug features stay off until you pair a device; a normal install only asks
  for lyrics and sends one anonymous count ping.

## Privacy

- Public instance: https://ytmtranslate.chiuhuang.dev/privacy
- In the app: Settings → Privacy policy opens `<your server>/privacy`, so it
  always describes the server this build actually talks to.
- Self-hosting: the page is a template (`templates/privacy.html`) and names
  whatever host serves it, so edit the body to match what your deployment
  keeps. The written version is
  [`docs/ownership-and-debug.md`](docs/ownership-and-debug.md).

## Credits

Fork of [YTMusicUltimate](https://github.com/ginsudev/YTMusicUltimate) by Ginsu
and Dayanch96. Lyrics system, server, and dashboard by ChiuHuang. Badge icons
are [Material Icons](https://fonts.google.com/icons) by Google (Apache-2.0).
