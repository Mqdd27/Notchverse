# Notchverse

Synced lyrics in a Dynamic Island–style pill at the top of your Mac screen, for **any** player
(Apple Music, Spotify, browsers, VLC, IINA…). Sits in the notch on MacBooks that have one,
floats as a pill on those that don't.

- Hover or click the pill: artwork, controls, progress, 5 lines of lyrics.
- Per-song offset (±0.5 s), "Wrong lyrics?" picker, settings in the menu bar icon.

## Install

Download the DMG from Releases, drag Notchverse to Applications, then (the app is ad-hoc signed, no Developer ID):

```sh
xattr -dr com.apple.quarantine /Applications/Notchverse.app
```

## Build

Requires macOS 14+, Swift 6, CMake.

```sh
scripts/build-app.sh          # .build/Notchverse.app
scripts/build-app.sh --dmg    # + .build/Notchverse-0.1.0.dmg
swift test                    # LyricsCore unit tests (also run on Linux)
LRCLIB_LIVE=1 swift test --filter live   # one optional live request to lrclib.net
```

Command Line Tools only (no Xcode)? Add
`-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` to `swift test`.

## How it works

- **Now Playing**: [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause, pinned in `Vendor/`)
  streams system Now Playing info via `/usr/bin/perl`. If its self-test fails, Notchverse falls back to AppleScript
  (Music and Spotify only) and says so in Settings.
- **Lyrics**: [LRCLIB](https://lrclib.net). Cached in `~/Library/Application Support/Notchverse/cache/`.

## Privacy

The only network requests go to `lrclib.net` and contain the track title, artist, album and duration.
No accounts, no analytics, no telemetry.

## Lyrics copyright

Notchverse does not ship or store a lyrics database. Lyrics are fetched at runtime from LRCLIB and belong to their
respective rights holders.

## License

MIT. See [LICENSE](LICENSE). Vendored mediaremote-adapter keeps its own BSD-3-Clause license.
