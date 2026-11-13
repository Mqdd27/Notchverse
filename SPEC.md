# SPEC: Notchverse

> Status: draft v0.1. Nama masih placeholder, ganti kalau sudah final.
> Tanda **[VERIFY]** = belum diverifikasi, cek dulu di Mac sebelum dijadikan keputusan.

## 1. Ringkasan

App macOS ala notch / Dynamic Island yang menampilkan **lyrics sinkron** dari lagu yang sedang diputar.
Bekerja untuk **player apa pun** (Apple Music, Spotify, browser, VLC, dll.), bukan hanya satu.

- Open source, lisensi **MIT**.
- Target dev: MacBook Air M1, macOS 27. M1 Air **tanpa notch**, jadi UI tampil sebagai pill floating di tengah atas layar.
- Distribusi: DMG di GitHub Releases. Tanpa Apple Developer ID (ad-hoc signed), user menjalankan `xattr -dr com.apple.quarantine`.

## 2. Tujuan dan non-tujuan

**Tujuan**
1. Menampilkan baris lyrics aktif secara sinkron dengan posisi lagu.
2. Mendeteksi lagu dari player apa pun lewat sumber Now Playing sistem.
3. Kontrol dasar: play/pause, next, previous.
4. Ringan: CPU idle mendekati 0 saat tidak ada musik.

**Non-tujuan (v0.x)**
- Bukan music player dan tidak memutar audio sendiri.
- Tidak menyimpan atau mendistribusikan database lyrics.
- Tidak ke App Store.
- Tidak ada akun, login, atau telemetry.
- Tidak ada fitur kalender, file shelf, atau HUD replacement (itu wilayah boring.notch).

## 3. Referensi dan lisensi

| Project | Lisensi | Cara pakai |
|---|---|---|
| DynamicNotchKit (MrKai77) | MIT | Dependency (SPM): window notch/floating |
| mediaremote-adapter (ungive) | BSD-3-Clause | Di-bundle: script perl + framework, pin ke satu commit/tag |
| LRCLIB | API publik | Sumber lyrics utama, via HTTP |
| boring.notch | **GPL-3.0** | **Hanya inspirasi konsep. Jangan salin kode.** |
| LyricsKit / LyricsX | MPL 2.0 | Referensi format LRC. Salin kode hanya kalau siap menaati MPL |

## 4. Persyaratan fungsional

### FR-1 Now Playing
- Menerima: judul, artis, album, durasi, elapsedTime, timestamp, playbackRate, playing, bundleIdentifier, artwork.
- Sumber utama: mediaremote-adapter (`stream`). Fallback: AppleScript untuk Music dan Spotify.
- Saat startup, jalankan `test` dari adapter. Kalau gagal, otomatis pakai fallback dan tampilkan peringatan di Settings.
- Jika proses adapter mati, restart dengan backoff (1s, 2s, 4s, maks 30s).
- `stream` mengirim `diff`. State harus di-merge, bukan diganti total.

### FR-2 Lyrics
- Urutan provider: **Cache → LRCLIB `/api/get` → LRCLIB `/api/search` → (provider plugin lain)**.
- Untuk `/api/get` kirim `track_name`, `artist_name`, `album_name`, `duration` (detik, 1–3600).
- Jika `get` 404: `search` lalu pilih hasil dengan selisih duration terkecil (toleransi awal ±2 dtk, bisa diatur). Prioritaskan hasil dengan `syncedLyrics`.
- Normalisasi judul/artis (urutan: query asli dulu, baru versi normalisasi):
  - buang `(feat. ...)`, `[feat. ...]`, `- Remastered YYYY`, `- Single`, `- Live`, `(Deluxe ...)` pada nama album;
  - artis: ambil artis pertama sebagai fallback.
- Jika hanya ada plain lyrics: tampilkan statis tanpa sinkronisasi (ditandai jelas).
- Jika instrumental atau tidak ada: tampilkan kontrol musik saja, tanpa error.
- Cache: file di `~/Library/Application Support/<App>/cache/`. Kunci: hash dari (artis, judul, album, durasi dibulatkan). Cache negatif dengan TTL 7 hari.

### FR-3 Parser LRC
- Mendukung `[mm:ss.xx]`, `[mm:ss.xxx]`, `[mm:ss]`.
- Beberapa timestamp dalam satu baris: `[00:10.00][00:50.00]teks`.
- Tag meta: `[ti:]`, `[ar:]`, `[al:]`, `[length:]`, `[offset:]` (ms, bisa negatif).
- Baris kosong dengan timestamp = jeda instrumental (ditampilkan sebagai kosong atau "♪").
- Abaikan baris rusak tanpa crash. Hasil diurutkan berdasarkan waktu.
- Enhanced LRC (word-by-word `<mm:ss.xx>`) **di luar v0.1**, tapi parser tidak boleh crash jika menemuinya (tag dibuang).

### FR-4 Sinkronisasi (LyricsClock)
- Posisi sekarang = `elapsedAtTimestamp + (now − timestamp) × playbackRate + userOffset + lrcOffset`.
- Saat `playing == false`, posisi dibekukan.
- Mencari baris aktif dengan binary search. Update ~30 Hz hanya saat playing **dan** UI terlihat.
- Reaksi terhadap seek: baris aktif dihitung ulang dari posisi baru tanpa animasi berlebihan.
- Offset manual per lagu (langkah ±0.5 dtk), disimpan per kunci lagu.

### FR-5 UI
- **Compact**: artwork kecil + satu baris lyrics aktif + indikator playing.
- **Expanded** (hover atau klik): artwork, judul/artis, progress bar, kontrol, 3–5 baris lyrics dengan highlight baris aktif.
- Transisi antar baris: crossfade atau slide halus (hormati Reduce Motion).
- Mode: `.notch` (kalau layar punya notch) dan `.floating` (default di Mac tanpa notch). Pilih otomatis.
- Sembunyi otomatis jika tidak ada lagu. Opsi: sembunyi saat app fullscreen.
- Multi-display: tampil di display utama (opsi: display dengan kursor).

### FR-6 Settings dan menu bar
- Menu bar item: tampil/sembunyi, Settings, Quit.
- Settings: launch at login (`SMAppService`), blacklist player (bundle ID), toleransi durasi, mode tampilan, hapus cache.
- Pilih lyrics manual: tampilkan hasil `search` lain dan simpan pilihan user.

## 5. Persyaratan non-fungsional

- **Privasi**: satu-satunya request jaringan adalah ke `lrclib.net` (title, artist, album, duration). Dokumentasikan di README. Tidak ada analytics.
- **Etika API**: header `User-Agent: <App>/<versi> (<url repo>)`. Request sekuensial. Hormati `429` + `Retry-After` dengan jitter. Pertimbangkan daftar app ID di lrclib.net/developers.
- **Performa**: idle CPU < 1% saat tidak ada musik. Saat playing dengan UI compact, targetnya < 5% (di M1) **[VERIFY]**.
- **Ketahanan**: tidak ada crash saat metadata null, durasi 0, atau lagu berganti cepat. Request lyrics yang usang harus dibatalkan saat lagu berubah.
- **Aksesibilitas**: label VoiceOver untuk kontrol, dan hormati Reduce Motion.

## 6. Arsitektur

```
NowPlayingService (protocol)
 ├─ MediaRemoteAdapterSource   (utama: proses perl, stream JSON)
 └─ AppleScriptSource          (fallback: Music, Spotify)
        ▼
NowPlayingState { track, bundleId, isPlaying, elapsedAtTimestamp, timestamp, rate }
        ▼
LyricsCoordinator
 ├─ TitleNormalizer
 ├─ LyricsProvider (protocol): CacheProvider → LRCLIBProvider → ...
 └─ LRCParser → [LyricLine(time, text)]
        ▼
LyricsClock (30 Hz saat aktif)
        ▼
NotchViewModel (@Observable) → SwiftUI: Compact / Expanded
```

Struktur repo (Swift Package + app target):

```
/
├─ Package.swift              # modul inti: LyricsCore (tanpa dependensi UI/macOS khusus → bisa di-test di Linux)
├─ Sources/LyricsCore/        # LRCParser, LRCLIBClient, TitleNormalizer, LyricsClock, models
├─ Tests/LyricsCoreTests/
├─ App/                       # target macOS: NowPlaying, UI, Settings
├─ Vendor/mediaremote-adapter # pinned
├─ .github/workflows/         # CI build + test, release DMG
├─ SPEC.md  README.md  LICENSE  CONTRIBUTING.md  CHANGELOG.md
```

Prinsip: logika murni (parser, klien LRCLIB, normalizer, clock) ditaruh di `LyricsCore` supaya bisa diuji tanpa Mac fisik dan tanpa UI.

## 7. Model data (draft)

```swift
struct Track: Hashable { title, artist, album: String?; duration: TimeInterval }
struct NowPlayingState { track: Track?; bundleID: String?; isPlaying: Bool
                         elapsedAtTimestamp: TimeInterval; timestamp: Date; rate: Double }
struct LyricLine { time: TimeInterval; text: String }
enum Lyrics { case synced([LyricLine]); case plain(String); case instrumental; case none }
```

## 8. Edge case yang harus ditangani

| Kasus | Perilaku |
|---|---|
| Lagu ganti saat request berjalan | Batalkan request lama |
| Durasi 0 atau null (live stream, radio) | Lewati LRCLIB `get`, coba `search` tanpa filter durasi atau tampilkan tanpa lyrics |
| Metadata browser berantakan (judul YouTube) | Normalizer, lalu koreksi manual |
| Seek / scrub | Hitung ulang dari posisi baru |
| Pause lama lalu resume | Posisi dibekukan saat paused, lanjut dari elapsed |
| Dua player aktif | Ikuti yang dilaporkan sistem sebagai "now playing" |
| Offline / LRCLIB down | Tampilkan tanpa lyrics, coba lagi saat lagu berikutnya |
| Adapter rusak setelah update macOS | Fallback AppleScript + peringatan |
| Lyrics salah match | Tombol "bukan lyrics ini" / pilih manual |

## 9. Rencana pengujian

- **Unit (LyricsCore, jalan di CI Linux/macOS)**: parser LRC (banyak kasus tepi), normalizer, pemilihan hasil search, clock (seek, pause, rate, offset), cache TTL.
- **Klien LRCLIB**: pakai stub HTTP. Satu tes live opsional yang ditandai terpisah.
- **Manual di Mac** (checklist per rilis): Apple Music, Spotify, YouTube Music di Safari/Chrome, VLC, IINA, Podcasts; seek, pause, ganti lagu cepat, sleep/wake, fullscreen, multi-display.

## 10. Milestone dan kriteria selesai

| M | Isi | Selesai jika |
|---|---|---|
| M0 | Setup repo, CI, prototipe `stream` adapter | JSON now playing terlihat di terminal saat Apple Music memutar |
| M1 | LyricsCore: parser, LRCLIB client, cache, normalizer, clock | Semua unit test hijau, lyrics lagu contoh berhasil diambil |
| M2 | NowPlaying: adapter + fallback + kontrol | State benar untuk Music dan Spotify, kontrol berfungsi **[VERIFY: perintah kontrol adapter]** |
| M3 | UI MVP: floating pill, compact + expanded | Lyrics tampil sinkron (selisih < 300 ms secara visual) di Apple Music |
| M4 | Multi-player, offset, pilih manual, settings, launch at login | Checklist manual lolos untuk player yang disebutkan |
| M5 | Rilis v0.1: README + GIF, DMG, Homebrew tap | Install dari cask berjalan di Mac bersih |

## 11. Risiko dan pertanyaan terbuka

1. **Adapter bergantung pada celah sistem** (`/usr/bin/perl` entitlement). Apple bisa menutupnya. Mitigasi: fallback, pin versi, tes saat startup.
2. **DynamicNotchKit di macOS 27** belum dites. Kalau tidak build, patch atau fork kecil. **[VERIFY]**
3. **Notch asli** tidak bisa dites di M1 Air. Cari tester MacBook ber-notch.
4. **Hak cipta lyrics**: ambil runtime dari LRCLIB, jangan bundle atau commit data lyrics. Tulis disclaimer di README.
5. **Nama final** belum dipilih. Cek ketersediaan di GitHub, brew, dan domain.
6. Apakah perintah kontrol (play/pause/next) di adapter tersedia dan stabil? **[VERIFY]** baca README penuh.
7. Apakah Apple Music mengirim durasi dan elapsedTime yang akurat untuk lagu streaming? **[VERIFY]** lewat prototipe M0.

## 12. Backlog (setelah v0.1)

Terjemahan/romanization (tag `tr` di LRC), word-by-word lyrics, tema, file `.lrc` lokal dan tag embedded, dukungan notch asli, lokalisasi, pilihan provider tambahan.
