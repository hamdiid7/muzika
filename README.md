<div align="center">

# Muzika

**Free music for Ethiopia: Ethiopian and world music, stories, lyrics and offline listening in one app.**

[Website](https://muzika.pages.dev) · [Download](https://muzika.pages.dev) · [License: GPL-3.0](LICENSE)

</div>

---

## What it does

- **Stories** at the top of Home: new music videos and releases from the artists you play and artists like them, Instagram-style.
- **Made for you**: Daily Mixes, "New releases for you", "Or listen again" and "For you", built from what you actually listen to.
- **Search that knows your library**: your own songs first, then artists and songs from the catalog as you type, even with Amharic names spelt different ways.
- **Lyrics**: synced lyrics that follow the song, plain lyrics when that's all there is, and a ✏️ to time them yourself. What you time is shared on [LRCLIB](https://lrclib.net) for everyone.
- **Canvas and Clips**: looping music-video clips behind the player and a full-screen Clips feed.
- **Artist and album pages** with "Fans also like", "More by" and "You might also like"; one page per artist even when catalogs spell the name two ways ("Efrem" / "Ephrem").
- **Offline**: download songs and playlists, and keep the songs you played lately.
- **Made for slow connections**: a data saver that switches on by itself when the line is slow, smaller covers and quick song starts.
- **Bring your music**: import Spotify playlists from a link or a CSV file.
- **Undo instead of "are you sure?"**: clearing or deleting happens at once, with Undo for five seconds.

Muzika runs on **Android** and **Windows**.

## Download

Get the latest APK from **[muzika.pages.dev](https://muzika.pages.dev)**.

## Build it yourself

You need [Flutter](https://flutter.dev) (stable channel).

```bash
flutter pub get
flutter run -d windows
```

Android release build (64-bit phones):

```bash
flutter build apk --release --split-per-abi --target-platform android-arm64
```

Optional: anonymous usage stats use [PostHog](https://posthog.com). Put your own key in a `posthog.json` file (not part of this repository) and build with `--dart-define-from-file=posthog.json`:

```json
{ "POSTHOG_KEY": "phc_...", "POSTHOG_HOST": "https://us.i.posthog.com" }
```

Without it, the app sends nothing.

## Credits and license

Muzika is free software under the [GNU General Public License v3.0](LICENSE).

It includes code by **Valeri Gokadze**, released under the same licence; his copyright notices are kept in the files he wrote.

Song information comes from Deezer and Apple's public catalogs, lyrics from LRCLIB and NetEase. Muzika is not affiliated with any of them.
