# LinkDrop — All-in-One Android Media Downloader (Flutter)

Aplikasi Android berbasis **Flutter + Native Kotlin (`youtubedl-android` / yt-dlp + FFmpeg + Aria2c)** untuk mengunduh video, audio (MP3/M4A), dan foto cukup dengan menempelkan tautan (atau langsung *Share* dari aplikasi media sosial).

## Platform yang Didukung
- **YouTube** (Video HD/Full HD/4K, Shorts, Audio MP3/M4A via `yt-dlp` + `FFmpeg` native)
- **TikTok** (Tanpa watermark, video HD/SD, audio, & slideshow foto via `yt-dlp` + fallback cepat)
- **Douyin (抖音)** (Pembersihan teks share bahasa Mandarin otomatis, video tanpa watermark, foto & audio via extractor langsung `_ROUTER_DATA` + fallback `yt-dlp`)
- **Instagram** (Reels, Post, Video via `yt-dlp`, mendukung *cookies* opsional untuk konten login/privat)
- **X (Twitter)** (Video, GIF, dan foto via `yt-dlp` + fallback `vxtwitter`/`fxtwitter`)

## Fitur Utama
- **Hanya dari Link**: Cukup tempel link (termasuk teks share acak dari Douyin/TikTok) atau kirim lewat menu **Bagikan / Share** Android langsung ke **LinkDrop**.
- **Deteksi Otomatis Clipboard**: Banner 1-klik saat membuka aplikasi dengan tautan media di clipboard.
- **Pilih Kualitas atau Unduh Cepat**: Pilih resolusi spesifik (4K / 1080p / 720p / 480p / MP3 / M4A) atau tekan **Unduh Cepat** dengan kualitas default.
- **Langsung Masuk Galeri & File Manager**: Tersimpan otomatis di `Download/LinkDrop` menggunakan Android `MediaStore` (tanpa perlu izin penyimpanan rumit di Android 10+).
- **Update Engine yt-dlp di Dalam Aplikasi**: Perbarui binary `yt-dlp` (Stable / Nightly) langsung dari tab **Pengaturan** tanpa harus install ulang APK.

## Cara Menjalankan di Android Studio / CLI
1. Buka folder proyek ini di **Android Studio** atau terminal.
2. Pastikan emulator Android atau HP Android (USB Debugging aktif) terhubung:
   ```bash
   flutter devices
   ```
3. Jalankan aplikasi:
   ```bash
   flutter run
   ```
4. Build file APK siap install (split per ABI agar ukuran APK lebih ringkas):
   ```bash
   flutter build apk --release --split-per-abi
   ```
   APK hasil build berada di `build/app/outputs/flutter-apk/`.
