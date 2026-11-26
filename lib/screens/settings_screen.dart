import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';
import '../models/media_info.dart';
import '../services/download_manager.dart';
import '../services/storage_service.dart';

class SettingsScreen extends StatelessWidget {
  final DownloadManager manager;

  const SettingsScreen({super.key, required this.manager});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = manager.settings;
    final engine = manager.engineStatus;

    return CustomScrollView(
      slivers: [
        const SliverAppBar(
          floating: true,
          title: Text('Pengaturan'),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // Engine Status & Updater Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.memory_rounded,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Engine Unduhan (yt-dlp + FFmpeg)',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _InfoLine(label: 'Versi yt-dlp', value: engine.version),
                      _InfoLine(
                        label: 'FFmpeg (Merge HD & MP3)',
                        value: engine.ffmpegReady ? 'Aktif' : 'Belum siap',
                      ),
                      _InfoLine(
                        label: 'Folder Simpan',
                        value: engine.downloadFolder,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(
                            'Channel Update:',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 10),
                          ChoiceChip(
                            label: const Text('Stable'),
                            selected: settings.updateChannel == 'stable',
                            onSelected: (_) => manager.updateSettings(
                              settings.copyWith(updateChannel: 'stable'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Nightly'),
                            selected: settings.updateChannel == 'nightly',
                            onSelected: (_) => manager.updateSettings(
                              settings.copyWith(updateChannel: 'nightly'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: manager.isUpdatingEngine
                              ? null
                              : () => _updateEngine(context),
                          icon: manager.isUpdatingEngine
                              ? const SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.system_update_alt_rounded),
                          label: Text(
                            manager.isUpdatingEngine
                                ? 'Memperbarui yt-dlp...'
                                : 'Perbarui Engine yt-dlp',
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Tips: Jika YouTube, TikTok, atau Instagram tiba-tiba gagal mengunduh, perbarui yt-dlp (pilih Nightly untuk perbaikan tercepat).',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Permissions Card
              Card(
                child: ListTile(
                  leading: Icon(
                    manager.permissionStatus.granted
                        ? Icons.verified_user_outlined
                        : Icons.shield_outlined,
                    color: manager.permissionStatus.granted
                        ? const Color(0xFF22C55E)
                        : const Color(0xFFF59E0B),
                  ),
                  title: const Text('Izin Penyimpanan & Media'),
                  subtitle: Text(
                    manager.permissionStatus.granted
                        ? 'Diizinkan — siap menyimpan & membuka hasil unduhan'
                        : 'Belum diizinkan — ketuk untuk meminta izin sistem',
                  ),
                  trailing: FilledButton.tonal(
                    onPressed: () async {
                      if (manager.permissionStatus.granted ||
                          manager.permissionStatus.permanentlyDenied) {
                        await manager.openAppSettings();
                      } else {
                        await manager.requestStoragePermissions();
                      }
                    },
                    child: Text(
                      manager.permissionStatus.granted
                          ? 'Atur'
                          : (manager.permissionStatus.permanentlyDenied
                              ? 'Pengaturan'
                              : 'Izinkan'),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Preferences Card
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.high_quality_rounded),
                      title: const Text('Kualitas Default (Unduh Cepat)'),
                      subtitle: Text(settings.defaultQuality.label),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pickDefaultQuality(context),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.content_paste_search_rounded),
                      title: const Text('Deteksi Otomatis Clipboard'),
                      subtitle: const Text(
                        'Tampilkan banner cepat saat ada link media tersalin',
                      ),
                      value: settings.clipboardAutoDetect,
                      onChanged: (v) => manager.updateSettings(
                        settings.copyWith(clipboardAutoDetect: v),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.speed_rounded),
                      title: const Text('Akselerasi Multi-Koneksi (Aria2c)'),
                      subtitle: const Text(
                        'Aktifkan untuk video besar (matikan jika ada error segmen)',
                      ),
                      value: settings.useAria2c,
                      onChanged: (v) => manager.updateSettings(
                        settings.copyWith(useAria2c: v),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Browser Session Login Card (1-Tap for Instagram, TikTok, Douyin, Facebook & Pixiv)
              Card(
                child: Column(
                  children: [
                    const ListTile(
                      leading: Icon(Icons.public_rounded),
                      title: Text('Login Browser (IG, TikTok, Douyin, FB, Pixiv)'),
                      subtitle: Text(
                        'Opsional: login sekali di aplikasi agar profil, Reel & karya terbatas terbuka penuh',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _LoginChipBtn(
                                  label: manager.instagramLoggedIn
                                      ? 'IG Aktif'
                                      : 'Login IG',
                                  active: manager.instagramLoggedIn,
                                  onTap: () => _doBrowserLogin(
                                    context,
                                    'instagram',
                                    'Instagram',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _LoginChipBtn(
                                  label: manager.tiktokLoggedIn
                                      ? 'TikTok Aktif'
                                      : 'Login TikTok',
                                  active: manager.tiktokLoggedIn,
                                  onTap: () => _doBrowserLogin(
                                    context,
                                    'tiktok',
                                    'TikTok',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _LoginChipBtn(
                                  label: manager.douyinLoggedIn
                                      ? 'Douyin Aktif'
                                      : 'Login Douyin',
                                  active: manager.douyinLoggedIn,
                                  onTap: () => _doBrowserLogin(
                                    context,
                                    'douyin',
                                    'Douyin',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _LoginChipBtn(
                                  label: manager.facebookLoggedIn
                                      ? 'FB Aktif'
                                      : 'Login FB',
                                  active: manager.facebookLoggedIn,
                                  onTap: () => _doBrowserLogin(
                                    context,
                                    'facebook',
                                    'Facebook',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: _LoginChipBtn(
                              label: manager.pixivLoggedIn
                                  ? 'Pixiv Aktif'
                                  : 'Login Pixiv',
                              active: manager.pixivLoggedIn,
                              onTap: () => _doBrowserLogin(
                                context,
                                'pixiv',
                                'Pixiv',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (manager.instagramLoggedIn ||
                        manager.tiktokLoggedIn ||
                        manager.douyinLoggedIn ||
                        manager.facebookLoggedIn ||
                        manager.pixivLoggedIn) ...[
                      const Divider(height: 1),
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.logout_rounded, size: 20),
                        title: const Text('Hapus Semua Sesi Browser'),
                        onTap: () async {
                          await manager.clearBrowserSessions();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Semua sesi login browser dihapus.'),
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Export / Import Backup & Data Migration Guide Card
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        Icons.import_export_rounded,
                        color: theme.colorScheme.primary,
                      ),
                      title: const Text('Backup, Impor & Migrasi Data'),
                      subtitle: Text(
                        '${manager.downloadedMarkers.length} penanda • ${manager.creatorProfiles.length} link artis • ${manager.items.length} riwayat',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  onPressed: () => _exportBackupFile(context),
                                  icon: const Icon(
                                    Icons.file_upload_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('Ekspor (.json)'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  onPressed: () => _importBackupFile(context),
                                  icon: const Icon(
                                    Icons.file_download_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('Impor (.json)'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _copyBackupJson(context),
                                  icon: const Icon(
                                    Icons.content_copy_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Salin JSON'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _openPasteBackupDialog(context),
                                  icon: const Icon(
                                    Icons.content_paste_go_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Tempel JSON'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: const Text('Panduan Migrasi Data ke HP Baru'),
                      subtitle: const Text(
                        'Langkah lengkap pindah pengaturan, file publik & Brankas Privat Pixiv',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _showMigrationGuideSheet(context),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Cookies (Optional) Card
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cookie_outlined),
                  title: const Text('Cookies Browser (Opsional)'),
                  subtitle: Text(
                    settings.hasCookies
                        ? 'Cookies aktif — digunakan untuk konten login/privat'
                        : 'Opsional: berguna untuk Instagram privat, Douyin, atau video terbatas usia',
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => _openCookiesDialog(context),
                ),
              ),

              const SizedBox(height: 16),

              // Appearance & Storage Card
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('Tema Aplikasi'),
                      subtitle: Text(_themeLabel(settings.themeMode)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pickThemeMode(context),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.bookmark_added_outlined),
                      title: const Text('Penandaan Sudah Diunduh'),
                      subtitle: Text(
                        manager.downloadedMarkers.isNotEmpty
                            ? '${manager.downloadedMarkers.length} album/media ditandai sudah diunduh'
                            : 'Belum ada penandaan tersimpan',
                      ),
                      trailing: TextButton(
                        onPressed: manager.downloadedMarkers.isEmpty
                            ? null
                            : () => _confirmResetMarkers(context),
                        child: const Text('Reset Semua'),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.cleaning_services_outlined),
                      title: const Text('Bersihkan Cache Sementara'),
                      subtitle: Text(
                        manager.cacheBytes > 0
                            ? 'Ukuran cache saat ini: ${formatBytes(manager.cacheBytes)}'
                            : 'Cache bersih',
                      ),
                      trailing: TextButton(
                        onPressed: () => _clearCache(context),
                        child: const Text('Bersihkan'),
                      ),
                    ),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Future<void> _exportBackupFile(BuildContext context) async {
    try {
      final saved = await manager.exportBackupToFile();
      if (!context.mounted) return;
      if (saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Backup pengaturan & data berhasil diekspor (.json).'),
          ),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal mengekspor backup: $e')),
      );
    }
  }

  Future<void> _copyBackupJson(BuildContext context) async {
    final json = manager.buildBackupJson();
    await Clipboard.setData(ClipboardData(text: json));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Data backup JSON disalin ke clipboard.'),
      ),
    );
  }

  Future<void> _importBackupFile(BuildContext context) async {
    try {
      final bundle = await manager.pickAndParseBackupFile();
      if (bundle == null || !context.mounted) return;
      await _confirmAndApplyBackup(context, bundle);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Gagal membaca file backup: ${e.toString().replaceFirst('FormatException: ', '')}',
          ),
        ),
      );
    }
  }

  Future<void> _openPasteBackupDialog(BuildContext context) async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tempel Backup JSON'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tempel isi teks JSON dari hasil "Salin JSON" atau file backup all_download.',
                style: TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                maxLines: 6,
                style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  hintText: '{"app": "all_download", ...}',
                  suffixIcon: IconButton(
                    onPressed: () async {
                      final data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) {
                        controller.text = data!.text!;
                      }
                    },
                    icon: const Icon(Icons.content_paste_rounded, size: 19),
                    tooltip: 'Tempel',
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Lanjut'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || raw.trim().isEmpty || !context.mounted) return;

    try {
      final bundle = manager.parseBackupText(raw);
      await _confirmAndApplyBackup(context, bundle);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Format JSON tidak valid: ${e.toString().replaceFirst('FormatException: ', '')}',
          ),
        ),
      );
    }
  }

  Future<void> _confirmAndApplyBackup(
    BuildContext context,
    BackupDataBundle bundle,
  ) async {
    final dateText = bundle.exportedAt != null
        ? '${bundle.exportedAt!.day.toString().padLeft(2, '0')}/${bundle.exportedAt!.month.toString().padLeft(2, '0')}/${bundle.exportedAt!.year}'
        : '-';
    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Konfirmasi Impor Backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tanggal backup: $dateText'),
            const SizedBox(height: 8),
            Text('• Penanda sudah diunduh: ${bundle.downloadedMarkers.length}'),
            Text('• Link profil artis: ${bundle.creatorProfiles.length}'),
            Text('• Riwayat & antrean terjeda: ${bundle.history.length}'),
            const SizedBox(height: 12),
            Text(
              'Pilih "Gabung" untuk menambah data baru tanpa menghapus data saat ini, atau "Timpa Semua" untuk mengganti seluruh data.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, 'merge'),
            child: const Text('Gabung (Merge)'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'replace'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Timpa Semua'),
          ),
        ],
      ),
    );
    if (mode == null || !context.mounted) return;

    await manager.applyBackup(bundle, merge: mode == 'merge');
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          mode == 'merge'
              ? 'Backup berhasil digabungkan!'
              : 'Backup berhasil diterapkan!',
        ),
      ),
    );
  }

  Future<void> _showMigrationGuideSheet(BuildContext context) {
    final theme = Theme.of(context);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        minChildSize: 0.45,
        maxChildSize: 0.94,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          children: [
            Text(
              'Panduan Migrasi Data ke HP Baru',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Ikuti 4 langkah singkat berikut agar seluruh pengaturan, penanda "Sudah Diunduh", link profil artis, dan koleksi media Anda berpindah utuh tanpa duplikat.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            const _MigrationStepCard(
              step: '1',
              title: 'Ekspor Pengaturan & Penanda (.json)',
              body:
                  'Di HP lama, buka Pengaturan → ketuk "Ekspor (.json)" (atau "Salin JSON"). File backup ini menyimpan: pengaturan kualitas/tema, seluruh penanda "Sudah Diunduh" dari semua medsos, daftar link profil per artis ("Lanjut Unduh"), serta riwayat & antrean terjeda.',
            ),
            const SizedBox(height: 10),
            const _MigrationStepCard(
              step: '2',
              title: 'Salin Folder Media Publik',
              body:
                  'Sambungkan HP lama ke PC/laptop atau gunakan Quick Share / File Manager, lalu salin dua folder ini ke lokasi yang sama persis di HP baru:\n• Pictures/all_download/ (semua foto & video per platform/artis)\n• Music/all_download/ (semua audio MP3)',
            ),
            const SizedBox(height: 10),
            const _MigrationStepCard(
              step: '3',
              title: 'Pindahkan Brankas Privat Pixiv',
              body:
                  'Foto Pixiv yang berstatus Privat tersembunyi dari Galeri & WA. Ada 2 cara memindahkannya:\n• Cara Mudah (Tanpa PC): Buka tab File → Pixiv → tahan & pilih semua album → ketuk Unlock (foto pindah ke Pictures/all_download/Pixiv). Setelah disalin ke HP baru, pilih lalu Kunci lagi.\n• Cara Langsung (PC/USB): Salin folder Android/data/com.linkdrop.linkdrop_downloader/files/private_vault/ ke folder yang sama di HP baru.',
            ),
            const SizedBox(height: 10),
            const _MigrationStepCard(
              step: '4',
              title: 'Impor Backup di HP Baru',
              body:
                  'Pasang aplikasi all_download di HP baru → izinkan akses penyimpanan → buka Pengaturan → ketuk "Impor (.json)" lalu pilih file backup tadi (pilih Gabung atau Timpa Semua).\n\nCatatan keamanan: Sesi login browser (IG/TikTok/Pixiv) sengaja tidak ikut diekspor demi keamanan akun — cukup login ulang 1 kali di Pengaturan HP baru.',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _doBrowserLogin(
    BuildContext context,
    String key,
    String label,
  ) async {
    final ok = await manager.openBrowserLogin(key);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Sesi $label tersimpan!' : 'Sesi $label ditutup.',
        ),
      ),
    );
  }

  Future<void> _updateEngine(BuildContext context) async {
    try {
      final result = await manager.updateYtDlpEngine();
      if (!context.mounted) return;
      final msg = result.updated
          ? 'Berhasil diperbarui ke yt-dlp ${result.version}'
          : 'yt-dlp sudah versi terbaru (${result.version})';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal memperbarui yt-dlp: $e')),
      );
    }
  }

  Future<void> _clearCache(BuildContext context) async {
    final freed = await manager.clearCache();
    if (!context.mounted) return;
    final msg = freed > 0
        ? 'Berhasil membersihkan ${formatBytes(freed)} cache sementara.'
        : 'Tidak ada cache sementara untuk dibersihkan.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _confirmResetMarkers(BuildContext context) async {
    final count = manager.downloadedMarkers.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Semua Penandaan?'),
        content: Text(
          'Hapus semua $count tanda "Sudah diunduh"? File yang tersimpan di penyimpanan perangkat tetap aman.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset Semua'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await manager.clearAllDownloadedMarkers();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Semua penandaan "Sudah diunduh" telah dihapus.'),
        ),
      );
    }
  }

  Future<void> _pickDefaultQuality(BuildContext context) async {
    final chosen = await showModalBottomSheet<DefaultQualityPreset>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Pilih Kualitas Default',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ...DefaultQualityPreset.values.map(
              (preset) => ListTile(
                title: Text(preset.label),
                trailing: manager.settings.defaultQuality == preset
                    ? Icon(
                        Icons.check_rounded,
                        color: Theme.of(ctx).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(ctx, preset),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (chosen != null) {
      await manager.updateSettings(
        manager.settings.copyWith(defaultQuality: chosen),
      );
    }
  }

  Future<void> _pickThemeMode(BuildContext context) async {
    final chosen = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Pilih Tema',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final mode in [ThemeMode.dark, ThemeMode.light, ThemeMode.system])
              ListTile(
                title: Text(_themeLabel(mode)),
                trailing: manager.settings.themeMode == mode
                    ? Icon(
                        Icons.check_rounded,
                        color: Theme.of(ctx).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(ctx, mode),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (chosen != null) {
      await manager.updateSettings(manager.settings.copyWith(themeMode: chosen));
    }
  }

  Future<void> _openCookiesDialog(BuildContext context) async {
    final controller = TextEditingController(text: manager.settings.customCookies);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cookies (Netscape cookies.txt)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tempel isi file cookies.txt (format Netscape) jika Anda ingin mengunduh konten Instagram/Douyin/YouTube yang memerlukan login. Biarkan kosong untuk penggunaan normal.',
                style: TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 6,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: '# Netscape HTTP Cookie File\n.instagram.com\tTRUE\t/...',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('Hapus Cookies'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (saved != null) {
      await manager.updateSettings(
        manager.settings.copyWith(customCookies: saved),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saved.isEmpty
                  ? 'Cookies dihapus.'
                  : 'Cookies berhasil disimpan.',
            ),
          ),
        );
      }
    }
  }

  String _themeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.dark:
        return 'Mode Gelap';
      case ThemeMode.light:
        return 'Mode Terang';
      case ThemeMode.system:
        return 'Ikuti Sistem';
    }
  }
}

class _LoginChipBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _LoginChipBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(
        active ? Icons.check_circle_rounded : Icons.login_rounded,
        size: 18,
      ),
      label: Text(label),
    );
  }
}

class _MigrationStepCard extends StatelessWidget {
  final String step;
  final String title;
  final String body;

  const _MigrationStepCard({
    required this.step,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              step,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.4,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;

  const _InfoLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
