# Saran Pengembangan Lanjutan — `all_download` (Pasca v2.3.0)

Dokumen ini merangkum ide pengembangan lanjutan yang disusun berdasarkan arsitektur dan alur penggunaan `all_download` saat ini (unduh multi-platform, koleksi Pixiv berskala besar, brankas privat anti-hilang, manajemen tag & rating konten, serta kurasi foto cepat).

---

## Ringkasan Pondasi Saat Ini (`v2.3.0`)
- **Multi-platform downloader**: YouTube, TikTok, Douyin, Instagram, X, Facebook, dan Pixiv (single, multi-halaman, Ugoira, serta unduh massal profil dengan auto-skip penanda).
- **Brankas Privat Anti-Hilang**: `Documents/.all_download_vault/` (`.nomedia`) + dual-write state mirroring & auto-restore saat install ulang + `versionCode` seragam anti-downgrade.
- **Gallery & Kurasi Cepat**: `SharpOriginalImage` resolusi asli hingga zoom 8×, Masonry Grid rasio asli tanpa potong, *slide* antar album mulus 1/4 layar, **Fast Delete** instan (0ms UI + IO asinkron), konfirmasi hapus di bawah (jangkauan jempol), notifikasi toast di atas, rating foto (`Biasa` / `Ecchi` / `NSFW`), serta tag di bawah album yang bisa diketuk untuk melihat semua album bertag sama.

---

## 1. Prioritas Tinggi (Dampak Paling Terasa Sehari-hari)

### 1.1 Tempat Sampah Sementara (Trash / Undo 1-Ketuk untuk Fast Delete)
- **Masalah**: Dengan **Fast Delete** instan 0ms, salah ketuk 1 kali langsung menghapus permanen tanpa bisa dibatalkan.
- **Solusi**:
  - Tambahkan opsi **"Pindah ke Sampah (Trash)"** (aktif/nonaktif di Pengaturan) yang memindahkan file ke `Documents/.all_download_vault/.trash/` alih-alih langsung `unlink`.
  - Munculkan tombol **`Urungkan` (Undo)** kecil di toast atas selama 3 detik setelah hapus.
  - Sediakan menu **Sampah** di tab File dengan *auto-purge* otomatis setelah 7/14/30 hari serta tombol *Kosongkan Sampah*.

### 1.2 Penjelajah Tag Global, Filter Multi-Tag & Edit Tag Manual
- **Pengembangan dari fitur tag saat ini (`TagAlbumsScreen`)**:
  - **Halaman Semua Tag**: Akses langsung dari tab File untuk melihat semua tag yang dimiliki koleksi, diurutkan berdasarkan jumlah album terbanyak + kolom pencarian tag.
  - **Filter Kombinasi Multi-Tag**: Bisa memilih lebih dari 1 tag sekaligus (misalnya `#Original` **DAN** `#Fantasy`, atau kecualikan tag tertentu seperti `-#Sketch`).
  - **Auto-Rating dari Tag R-18 (Opsional)**: Toggle di Pengaturan agar album Pixiv yang memiliki tag `#R-18` otomatis ditandai rating `NSFW` saat selesai diunduh (tetap bisa diubah manual per foto).
  - **Tambah / Edit Tag Kustom**: Kemampuan menambah tag buatan sendiri pada album/foto (termasuk untuk album lama yang diunduh sebelum fitur tag ada, atau media non-Pixiv).

### 1.3 Favorit (Bintang/Hati) & Koleksi Kustom Tanpa Duplikasi File
- Tambahkan tombol **Favorit (♥)** 1-ketuk di detail foto (`FileGalleryViewer`) dan di album.
- Tambahkan **Koleksi / Playlist Foto Kustom** (mis. *"Wallpaper Terbaik"*, *"Referensi Karakter"*, *"Terbaik 2026"*) yang hanya menyimpan referensi `ratingKey` di `Documents/.all_download_vault/state/` sehingga **tidak menggandakan ukuran file di penyimpanan**.
- Integrasikan filter *"Hanya Favorit"* di menu **Semua Foto (Acak & Slide)**.

### 1.4 "Cek Karya Baru Semua Artis" (Batch Profile Sync)
- Saat ini setiap artis sudah menyimpan link profil (`CreatorProfileRecord`) dan riwayat penanda (`downloadedMarkers`).
- **Pengembangan**: Tambahkan tombol **Cek Update Semua Artis** di daftar artis Pixiv/TikTok yang memeriksa profil tersimpan secara bertahap (menghormati *rate limit* agar akun aman), lalu menampilkan badge **`+N karya baru`** pada kartu artis yang punya unggahan baru — tinggal 1 ketuk untuk langsung memilih & mengunduh karya terbarunya saja.

### 1.5 Kunci Privasi (Sidik Jari / PIN) & Tombol Stealth Cepat
- Proteksi biometrik (`local_auth` / Android `BiometricPrompt`) atau PIN opsional saat:
  - Membuka brankas/tab File, **atau**
  - Mengaktifkan kembali centang `Ecchi` / `NSFW` di **Visibilitas Konten**.
- **Quick Hide / Mode Aman**: Tekan lama tab *File* atau aktifkan *shake-to-hide* untuk langsung mematikan tampilan `Ecchi` & `NSFW` secara instan saat HP dipinjam orang lain.
- **Amankan Preview Recent Apps**: Opsi `FLAG_SECURE` di Android agar isi brankas tidak ikut terekam di *thumbnail* Recent Apps / *app switcher*.

---

## 2. Prioritas Menengah (Pengalaman Viewer, Video & Otomatisasi)

### 2.1 Pemutar Video & Ugoira In-App (Langsung di Dalam Viewer)
- Saat ini video MP4 dan animasi **Pixiv Ugoira** masih dibuka lewat aplikasi eksternal.
- **Solusi**: Integrasikan pemutar video ringan in-app di `FileGalleryViewer` & `PixivAlbumViewer` sehingga:
  - Ugoira langsung berputar otomatis (*auto-loop*, tanpa suara) persis seperti di aplikasi Pixiv resmi.
  - Video TikTok/IG/YouTube/X bisa di-swipe menyatu dengan foto tanpa keluar-masuk aplikasi, lengkap dengan *seek bar* jempol, kecepatan 0.5×–2×, dan tombol *mute/unmute*.

### 2.2 Pre-Warm Foto Berikutnya Saat Mode Fast Delete Aktif
- Saat pengguna menyalakan **Fast Delete**, pre-decode **1 foto berikutnya** di background dengan resolusi layar (`ResizeImage` ~1080px, bukan full 20MP) agar saat menekan **Hapus** bertubi-tubi (mis. 3–5× per detik), foto berikutnya tampil benar-benar tanpa kedipan frame kosong.

### 2.3 Terima Share Langsung dari Aplikasi Lain (`ACTION_SEND`)
- Daftarkan `intent-filter` `text/plain` di `AndroidManifest.xml` agar pengguna cukup menekan tombol **Bagikan → all_download** langsung dari YouTube, TikTok, Instagram, X, atau Pixiv.
- Tambahkan opsi **Mode Unduh Cepat dari Share**: untuk tautan tunggal, bisa langsung masuk antrean unduh di latar belakang tanpa membuka UI penuh (*floating toast* konfirmasi singkat saja).

### 2.4 Foreground Service & Notifikasi Progres Android (Anti-Kill MIUI/HyperOS)
- Pada Android (terutama Xiaomi MIUI/HyperOS), unduhan massal ratusan album bisa dihentikan paksa oleh sistem saat layar mati atau aplikasi di-minimize terlalu lama.
- **Solusi**: Tambahkan Android `ForegroundService` (`dataSync`) yang aktif otomatis hanya saat ada unduhan berjalan, menampilkan notifikasi progres (`12/80 album • 4.2 MB/s`) beserta tombol cepat **Jeda / Lanjut / Batalkan**.

### 2.5 Detektor Duplikat & Analitik Penyimpanan
- **Deteksi Foto Duplikat / Mirip**: Pemindaian *perceptual hash* (dHash) di background untuk mendeteksi gambar identik atau re-upload lintas artis/album dengan perbandingan berdampingan (*side-by-side* resolusi & ukuran file) agar mudah memilih versi paling tajam dan menghapus sisanya.
- **Dashboard Storage**: Grafik penggunaan memori per platform & top 10 artis terbesar, plus tombol sekali klik untuk membersihkan folder kosong, file `.tmp` sisa unduhan gagal, dan cache thumbnail.

### 2.6 Ekspor & Impor Sesi / Pengaturan Lebih Pintar + Auto-Backup Terjadwal
- Menjadwalkan *auto-snapshot* `state/` berkala (misalnya simpan 3 versi backup rolling terakhir) agar jika file JSON pernah korup akibat HP mati mendadak, aplikasi otomatis *fallback* ke snapshot sehat sebelumnya.
- Opsi **Ekspor Album ke ZIP / CBZ** (kompatibel pembaca komik seperti Tachiyomi/Mihon) untuk membagikan atau mengarsipkan 1 album multi-halaman secara rapi.

---

## 3. Prioritas Jangka Panjang (Skalabilitas & Arsitektur)

### 3.1 Migrasi Penyimpanan Metadata & Indeks File ke SQLite (Drift / sqflite)
- Saat koleksi berkembang hingga **20.000–100.000+ file**, pemindaian direktori penuh + JSON datar mulai terasa saat cold start atau pencarian.
- **Solusi**: Simpan indeks file, tag album, rating foto, favorit, dan penanda unduhan di SQLite lokal (yang file `.db`-nya juga ikut dicerminkan ke `Documents/.all_download_vault/state/`).
- Manfaat:
  - Cold start instan (<150ms) karena langsung membaca dari indeks lokal lalu menyinkronkan perubahan folder secara inkremental di background.
  - Pencarian judul/artis/multi-tag menjadi instan dalam hitungan milidetik dengan indeks FTS5.

### 3.2 Dukungan Fitur Pixiv & Situs Ilustrasi Lanjutan
- **Unduh Bookmark Pixiv Pribadi**: Mendukung URL `pixiv.net/users/{id}/bookmarks/artworks` (publik & privat) serta daftar *Following*.
- **Dukungan Seri / Manga Pixiv**: Mengelompokkan chapter seri secara berurutan.
- **Backfill Tag Otomatis untuk Album Lama**: Tombol di Pengaturan untuk mengambil ulang tag dari Pixiv API bagi album lama yang sudah terunduh sebelum v2.2.6 (cukup berdasarkan ID illust atau judul).
- **Ekstensi Platform Opsional**: Dukungan ekstraktor langsung untuk situs ilustrasi populer lain (mis. Danbooru / Gelbooru / Kemono / Reddit gallery) dengan struktur folder & tag yang sama.

### 3.3 Transfer & Manajemen Koleksi via Wi-Fi LAN (PC Companion)
- Jalankan server HTTP lokal ringan sementara di HP (dengan PIN acak & QR code) saat berada di Wi-Fi yang sama dengan laptop/PC:
  - Bisa melihat galeri di layar besar browser PC, menandai/menghapus foto, atau **mengunduh/backup seluruh folder `Documents/.all_download_vault/` & `Pictures/all_download/`** ke PC tanpa kabel USB dan tanpa MTP Android yang lambat.

### 3.4 Refactor Modularitas Kode & CI/CD Otomatis
- **Modularisasi**: File inti seperti `download_manager.dart` (~3.300 baris), `files_screen.dart` (~3.700 baris), dan `MediaEngineBridge.kt` (~2.400 baris) sebaiknya dipecah berdasarkan domain (`VaultRepository`, `PixivSyncService`, `DownloadQueueController`, `MediaStoreService`) agar lebih mudah dirawat dan diuji.
- **GitHub Actions CI**: Workflow otomatis setiap *push* / *tag* untuk menjalankan `flutter analyze`, `flutter test`, dan mem-build APK `--split-per-abi` otomatis ke GitHub Releases.

---

## 4. Rekomendasi Urutan Pengerjaan

| Fase | Fitur Utama | Estimasi Effort | Dampak Pengguna |
| :--- | :--- | :---: | :---: |
| **Fase 1 (Quick Wins)** | Undo / Trash untuk Fast Delete, Kunci Sidik Jari/PIN + `FLAG_SECURE`, Auto-Rating `#R-18`, Pre-warm 1 foto saat Fast Delete | Kecil–Sedang | Sangat Tinggi |
| **Fase 2 (Power User)** | Penjelajah Tag Global + Filter Multi-Tag, Favorit & Koleksi Kustom, Share Intent `ACTION_SEND`, Foreground Service anti-kill MIUI | Sedang | Sangat Tinggi |
| **Fase 3 (Next Level)** | Pemutar Video/Ugoira In-App, Batch Sync Semua Artis (`+N baru`), Detektor Duplikat, Backfill Tag Album Lama | Sedang–Besar | Tinggi |
| **Fase 4 (Skala Besar)** | Indeks SQLite/FTS5 (50k+ file), Wi-Fi LAN Backup ke PC, Modularisasi kode & GitHub Actions CI | Besar | Jangka Panjang |
