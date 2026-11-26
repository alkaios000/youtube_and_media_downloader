# all_download — All-in-One Android Media Downloader (Flutter)

Aplikasi Android berbasis **Flutter + Native Kotlin (`youtubedl-android` / yt-dlp + FFmpeg + Chromium WebView Sniffer)** untuk mengunduh video, audio (MP3/M4A), dan foto (termasuk pilih foto tertentu & unduh massal profil) hanya dari tautan.

## Platform yang Didukung
- **YouTube**: Video H.264 ramah WhatsApp (hingga 4K/1080p/720p), Shorts, Audio MP3/M4A, serta unduh massal Channel/Playlist.
- **TikTok**: Video tanpa watermark, slideshow foto (bisa pilih foto tertentu), audio MP3, serta unduh massal profil `@username`.
- **Douyin (抖音)**: Pembersihan otomatis teks share Mandarin (`v.douyin.com`), video tanpa watermark, foto & profil.
- **Instagram**: Reels (video HD MP4), Post, Carousel foto (bisa pilih foto), serta unduh massal profil.
- **X (Twitter)**: Video, GIF, multi-foto (bisa pilih foto), serta unduh massal profil.
- **Pixiv**: Karya tunggal/multi-halaman resolusi original (bisa pilih halaman tertentu) serta unduh massal dari URL profil (`pixiv.net/users/...`) atau shortcut `pixiv:username`.
- **Facebook**: Reels, Watch, Video, Share link, dan Halaman/Profil.

## Fitur Utama
- **Antarmuka Minimalis & Ramah Jempol**: Input tautan di tengah layar dengan tombol Tempel di dalam kolom input dan deteksi platform otomatis saat menempel tautan.
- **4 Menu Navigasi**: **Unduh**, **File** (penjelajah folder otomatis per *Nama Aplikasi → Username*), **Riwayat**, dan **Pengaturan**.
- **Folder Terpisah & Waktu Terbaru di Galeri/WA**: Semua video & foto disimpan ke `Pictures/all_download/<Aplikasi>/<Username>/` (audio di `Music/all_download/<Aplikasi>/<Username>/`), dengan metadata `creation_time` & atom MP4 (`mvhd`/`tkhd`/`mdhd`) diperbarui ke waktu saat ini agar selalu tampil paling atas di WhatsApp dan Galeri.

## Build APK
```bash
flutter build apk --release --split-per-abi
```
APK hasil build berada di `build/app/outputs/flutter-apk/`.
