# YTMusicUltimate (with better lyrics)

[![Latest release](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=release)](https://github.com/ChiuHuang/ytmusicultimate/releases)
[![Lyrics API](assets/badges/server.svg)](https://ytmtranslate.chiuhuang.dev)
![Lyrics served](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=lyrics)
![Devices](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=devices)
![Tracks cached](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=tracks)
![Nodes online](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=nodes)

A YouTube Music tweak for iOS that plays lyrics properly: word-by-word
highlight that follows the music, translations, and an offline-friendly
downloader. Lyrics are fetched from a small lyrics server, which is included
here and can be self-hosted.



<a href="https://altdirect.app/?url=https://ytmtranslate.chiuhuang.dev/api/app/altstore"><img src="https://altdirect.app/assets/png/AltSource_Blue.png" width="200" alt="Add to AltStore"></a>

### Stats
<div align="center">

| Lyrics served | Tracks cached | Devices | Last song |
|---|---|---|---|
| ![Live lyrics served](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=lyrics) | ![Tracks cached](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=tracks) | ![Live devices](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=devices) | ![Last song served](https://ytmtranslate.chiuhuang.dev/api/app/badge?type=now) |

</div>

## Screenshots & demo

Add screenshots or short screen recordings under `docs/media/`, then replace
the placeholders below. GIFs work well for lyric timing and player controls.

<div align="center">
<table>
<tr>
<td align="center"><strong>Synced lyrics</strong><br><em>Screenshot / GIF coming soon</em></td>
<td align="center"><strong>Player & downloads</strong><br><em>Screenshot / GIF coming soon</em></td>
<td align="center"><strong>Liquid Glass</strong><br><em>Screenshot / GIF coming soon</em></td>
</tr>
</table>
</div>

<!-- Example showcase asset: <img src="docs/media/lyrics-sync.gif" width="320" alt="Word-by-word synced lyrics"> -->

> [!NOTE]
> You need a **decrypted** YouTube Music IPA to build. It cannot be provided
> here.

## Features

### Lyrics

- Word-by-word highlighting follows the current playback position.
- Translations stream in beneath the lyrics; choose a target language or use
  automatic language selection.
- Eight lyric providers race in parallel. The best result is served first and
  can upgrade the cache when a better synced version arrives.
- Switch lyric provider for a track, adjust its timing, and choose how duet
  lines, romanization, and typewriter reveal are displayed.
- Keep lyrics available with the on-device cache, queue prefetch, playlist
  sync, and optional automatic updates.
- Selectable lyric text, landscape lyrics, and automatic full-screen lyrics
  are available as settings.

### Player & downloads

- Download audio and cover art; downloaded audio can play in YouTube Music's
  own player.
- Add playback-rate and seek controls, a volume bar, and audio/video playback
  mode selection.
- Skip non-music sections with SponsorBlock, with configurable skip or prompt
  behavior.
- Optional background playback, ad hiding, and playback warning controls.

### Appearance & navigation

- Liquid Glass styling for the player, lyrics, queue, home, search, library,
  downloads, and other supported screens.
- Song artwork can theme the player or the wider app; OLED and low-contrast
  display options are available.
- Customize startup tab, tab labels, visible tabs, and navigation buttons.
- Mini-player and landscape layouts adapt lyrics and controls to the screen.

### Haptics & Sing

- Core Haptics can follow live player audio, with lyric-timed cues as a
  fallback; ISRC lookup can enable native Music Haptics when a matching track
  is available.
- **Sing is in progress:** download and load the MDX23C model and choose
  vocals-only, original mix, or background-only. Separated audio is not yet
  routed into playback.

### Server & dashboard

- The included self-hostable lyrics server races providers, caches results,
  and serves lyrics to the tweak.
- The web dashboard manages providers, cached tracks, library data, and
  connected nodes, and includes live logs, optional device diagnostics, and
  ISRC lookup status.
- Point the tweak at a different lyrics server from Settings → Lyrics.

Most features can be enabled or adjusted in Settings.

## Install

- **AltStore / SideStore / Feather:**
  paste the URL:
  - Stable (promoted builds): `https://ytmtranslate.chiuhuang.dev/api/app/altstore`
  - Beta (every push, newest build first): `https://ytmtranslate.chiuhuang.dev/api/app/altstore-beta`
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
