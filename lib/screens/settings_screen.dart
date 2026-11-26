import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';
import '../models/media_info.dart';
import '../models/media_metadata.dart';
import '../services/download_manager.dart';
import '../services/storage_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/security_lock_screen.dart';
import 'trash_screen.dart';

/// Main Settings hub organized into clean categories that navigate to focused
/// submenu pages so every option is quick to find and uncluttered.
class SettingsScreen extends StatelessWidget {
  final DownloadManager manager;

  const SettingsScreen({super.key, required this.manager});

  int get _activeSessionCount {
    var count = 0;
    if (manager.instagramLoggedIn) count++;
    if (manager.tiktokLoggedIn) count++;
    if (manager.douyinLoggedIn) count++;
    if (manager.facebookLoggedIn) count++;
    if (manager.pixivLoggedIn) count++;
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final settings = manager.settings;
    final engine = manager.engineStatus;
    final sessions = _activeSessionCount;

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
              // Group 1: Core Download & App Experience
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _SettingsMenuTile(
                      icon: Icons.speed_rounded,
                      iconColor: const Color(0xFF38BDF8),
                      title: 'Unduhan & Rate Limiting',
                      subtitle:
                          'Maks ${settings.maxConcurrentAlbums} album bersamaan • ${settings.rateLimitLabel}',
                      onTap: () => _openSubmenu(
                        context,
                        _DownloadRateLimitSubmenu(manager: manager),
                      ),
                    ),
                    const Divider(height: 1, indent: 68),
                    _SettingsMenuTile(
                      icon: Icons.public_rounded,
                      iconColor: const Color(0xFFA855F7),
                      title: 'Akun & Login Platform',
                      subtitle: sessions > 0
                          ? '$sessions/5 login browser aktif${settings.hasCookies ? ' • Cookies manual' : ''}'
                          : (settings.hasCookies
                              ? 'Cookies manual aktif'
                              : 'Login IG, TikTok, Douyin, FB, Pixiv & Cookies'),
                      onTap: () {
                        manager.refreshBrowserSessions();
                        _openSubmenu(
                          context,
                          _AccountsLoginSubmenu(manager: manager),
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 68),
                    _SettingsMenuTile(
                      icon: Icons.palette_outlined,
                      iconColor: const Color(0xFFF59E0B),
                      title: 'Tampilan & Umum',
                      subtitle:
                          '${_themeLabel(settings.themeMode)} • Clipboard ${settings.clipboardAutoDetect ? 'aktif' : 'nonaktif'}',
                      onTap: () => _openSubmenu(
                        context,
                        _AppearanceGeneralSubmenu(manager: manager),
                      ),
                    ),
                    const Divider(height: 1, indent: 68),
                    _SettingsMenuTile(
                      icon: Icons.visibility_outlined,
                      iconColor: const Color(0xFFEC4899),
                      title: 'Visibilitas Konten',
                      badgeLabel: 'BARU',
                      subtitle: settings.contentVisibilitySummary,
                      onTap: () async {
                        if (settings.isSecurityLockActive) {
                          final ok = await verifySecurityGate(
                            context,
                            manager,
                            title: 'Verifikasi Visibilitas Konten',
                            subtitle:
                                'Masukkan PIN atau sidik jari untuk mengubah filter konten',
                          );
                          if (!ok || !context.mounted) return;
                        }
                        _openSubmenu(
                          context,
                          _ContentVisibilitySubmenu(manager: manager),
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 68),
                    _SettingsMenuTile(
                      icon: Icons.security_rounded,
                      iconColor: settings.isSecurityLockActive ||
                              settings.secureScreenEnabled
                          ? const Color(0xFF22C55E)
                          : const Color(0xFF6366F1),
                      title: 'Keamanan & Privasi',
                      badgeLabel: 'BARU',
                      subtitle: settings.isSecurityLockActive
                          ? 'Kunci aktif (${settings.appLockScope == 'vault' ? 'Brankas File' : 'Seluruh App'})${settings.secureScreenEnabled ? ' • Anti-Preview' : ''}'
                          : (settings.secureScreenEnabled
                              ? 'Anti-Preview Recent Apps aktif'
                              : 'PIN, Sidik Jari, Anti-Preview Recent Apps & Mode Aman'),
                      onTap: () => _openSubmenu(
                        context,
                        _SecurityPrivacySubmenu(manager: manager),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Group 2: Data, Backup & System Engine
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _SettingsMenuTile(
                      icon: Icons.import_export_rounded,
                      iconColor: const Color(0xFF14B8A6),
                      title: 'Backup, Migrasi & Data',
                      subtitle:
                          '${manager.downloadedMarkers.length} penanda • ${manager.creatorProfiles.length} artis • Cache ${manager.cacheBytes > 0 ? formatBytes(manager.cacheBytes) : 'bersih'}',
                      onTap: () {
                        manager.refreshStorageInfo();
                        _openSubmenu(
                          context,
                          _BackupDataSubmenu(manager: manager),
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 68),
                    _SettingsMenuTile(
                      icon: Icons.memory_rounded,
                      iconColor: (manager.permissionStatus.granted &&
                              manager.permissionStatus.allFilesGranted)
                          ? const Color(0xFF22C55E)
                          : const Color(0xFFF59E0B),
                      title: 'Mesin & Izin Sistem',
                      subtitle:
                          'yt-dlp ${engine.version} • Anti-Hilang ${manager.permissionStatus.allFilesGranted ? 'aktif' : 'belum aktif'}',
                      onTap: () {
                        manager.ensureEngineInitialized();
                        manager.refreshPermissions();
                        manager.refreshStorageInfo();
                        _openSubmenu(
                          context,
                          _EngineSystemSubmenu(manager: manager),
                        );
                      },
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

  void _openSubmenu(BuildContext context, Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }
}

class _SettingsMenuTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String? badgeLabel;
  final VoidCallback onTap;

  const _SettingsMenuTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badgeLabel,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (badgeLabel != null && badgeLabel!.isNotEmpty) ...[
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: iconColor.withValues(alpha: 0.45)),
              ),
              child: Text(
                badgeLabel!,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  color: iconColor,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

// =============================================================================
// SUBMENU 1: Unduhan & Rate Limiting
// =============================================================================
class _DownloadRateLimitSubmenu extends StatelessWidget {
  final DownloadManager manager;

  const _DownloadRateLimitSubmenu({required this.manager});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unduhan & Rate Limiting')),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final theme = Theme.of(context);
          final settings = manager.settings;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              // Concurrent Albums Rate Limiter Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.layers_rounded,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Maksimal Album Bersamaan',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${settings.maxConcurrentAlbums} album',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Atur berapa banyak album/tugas yang boleh diunduh bersamaan. Nilai lebih kecil lebih hemat RAM & aman dari batas server; berlaku langsung bahkan saat unduhan aktif.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      Slider(
                        value: settings.maxConcurrentAlbums.toDouble(),
                        min: AppSettings.minConcurrentAlbums.toDouble(),
                        max: AppSettings.maxConcurrentAlbumsLimit.toDouble(),
                        divisions: AppSettings.maxConcurrentAlbumsLimit -
                            AppSettings.minConcurrentAlbums,
                        label: '${settings.maxConcurrentAlbums} album',
                        onChanged: (v) => manager.updateSettings(
                          settings.copyWith(maxConcurrentAlbums: v.round()),
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (int n = AppSettings.minConcurrentAlbums;
                              n <= AppSettings.maxConcurrentAlbumsLimit;
                              n++)
                            ChoiceChip(
                              label: Text('$n'),
                              selected: settings.maxConcurrentAlbums == n,
                              showCheckmark: false,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) => manager.updateSettings(
                                settings.copyWith(maxConcurrentAlbums: n),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Rate Limit Cooldown Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.timer_outlined,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Jeda Rate Limit Antar Album',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Tambahkan jeda singkat setelah setiap album selesai agar server (Pixiv, TikTok, Instagram) tidak memblokir sementara (HTTP 429) saat unduh massal.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final ms in AppSettings.rateLimitPresetsMs)
                            ChoiceChip(
                              label: Text(_formatDelayPreset(ms)),
                              selected: settings.downloadRateLimitMs == ms,
                              showCheckmark: false,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) => manager.updateSettings(
                                settings.copyWith(downloadRateLimitMs: ms),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Quality & Aria2c Card
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.high_quality_rounded),
                      title: const Text('Kualitas Default (Unduh Cepat)'),
                      subtitle: Text(settings.defaultQuality.label),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pickDefaultQuality(context, manager),
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

              const SizedBox(height: 14),

              // Recycle Bin / Trash Card (protects Fast Delete!)
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.delete_outline_rounded),
                      title: const Text('Tempat Sampah (Trash) & Undo'),
                      subtitle: const Text(
                        'Foto/video yang dihapus (termasuk Fast Delete) dipindah sementara ke Sampah agar bisa di-Urungkan',
                      ),
                      value: settings.trashEnabled,
                      onChanged: (v) => manager.updateSettings(
                        settings.copyWith(trashEnabled: v),
                      ),
                    ),
                    if (settings.trashEnabled) ...[
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Auto-Hapus Sampah: ${settings.trashRetentionLabel}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                for (final days in const [7, 14, 30, 0])
                                  ChoiceChip(
                                    label: Text(
                                      days == 0 ? 'Manual' : '$days hari',
                                    ),
                                    selected:
                                        settings.trashRetentionDays == days,
                                    showCheckmark: false,
                                    visualDensity: VisualDensity.compact,
                                    onSelected: (_) => manager.updateSettings(
                                      settings.copyWith(
                                        trashRetentionDays: days,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.restore_from_trash_rounded),
                        title: const Text('Buka Tempat Sampah'),
                        subtitle: Text(
                          manager.trashCount > 0
                              ? '${manager.trashCount} item menunggu di Sampah'
                              : 'Tempat Sampah kosong',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TrashScreen(manager: manager),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatDelayPreset(int ms) {
    if (ms <= 0) return 'Tanpa jeda';
    if (ms >= 1000) return '${ms ~/ 1000} detik';
    return '$ms ms';
  }
}

// =============================================================================
// SUBMENU 2: Akun & Login Platform
// =============================================================================
class _AccountsLoginSubmenu extends StatelessWidget {
  final DownloadManager manager;

  const _AccountsLoginSubmenu({required this.manager});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Akun & Login Platform')),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final settings = manager.settings;
          final anyLoggedIn = manager.instagramLoggedIn ||
              manager.tiktokLoggedIn ||
              manager.douyinLoggedIn ||
              manager.facebookLoggedIn ||
              manager.pixivLoggedIn;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    const ListTile(
                      leading: Icon(Icons.public_rounded),
                      title: Text('Login Browser 1-Tap'),
                      subtitle: Text(
                        'Login sekali di aplikasi agar profil, Reel, karya R-18 & Ugoira terbuka penuh',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
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
                                    manager,
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
                                    manager,
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
                                    manager,
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
                                    manager,
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
                                manager,
                                'pixiv',
                                'Pixiv',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (anyLoggedIn) ...[
                      const Divider(height: 1),
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.logout_rounded, size: 20),
                        title: const Text('Hapus Semua Sesi Browser'),
                        onTap: () async {
                          await manager.clearBrowserSessions();
                          if (!context.mounted) return;
                          showTopToast(
                            context,
                            'Semua sesi login browser dihapus.',
                            icon: Icons.logout_rounded,
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 14),

              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: const Icon(Icons.cookie_outlined),
                  title: const Text('Cookies Browser Manual (Opsional)'),
                  subtitle: Text(
                    settings.hasCookies
                        ? 'Cookies aktif — digunakan untuk konten login/privat'
                        : 'Format Netscape cookies.txt untuk konten privat/terbatas usia',
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => _openCookiesDialog(context, manager),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// SUBMENU 3: Backup, Migrasi & Data
// =============================================================================
class _BackupDataSubmenu extends StatelessWidget {
  final DownloadManager manager;

  const _BackupDataSubmenu({required this.manager});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup, Migrasi & Data')),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        Icons.import_export_rounded,
                        color: theme.colorScheme.primary,
                      ),
                      title: const Text('Ekspor & Impor Pengaturan'),
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
                                  onPressed: () =>
                                      _exportBackupFile(context, manager),
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
                                  onPressed: () =>
                                      _importBackupFile(context, manager),
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
                                  onPressed: () =>
                                      _copyBackupJson(context, manager),
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
                                  onPressed: () =>
                                      _openPasteBackupDialog(context, manager),
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
                        'Langkah pindah pengaturan, file publik & Brankas Privat Pixiv',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _showMigrationGuideSheet(context),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
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
                            : () => _confirmResetMarkers(context, manager),
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
                        onPressed: () => _clearCache(context, manager),
                        child: const Text('Bersihkan'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// SUBMENU 4: Tampilan & Umum
// =============================================================================
class _AppearanceGeneralSubmenu extends StatelessWidget {
  final DownloadManager manager;

  const _AppearanceGeneralSubmenu({required this.manager});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tampilan & Umum')),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final settings = manager.settings;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('Tema Aplikasi'),
                      subtitle: Text(_themeLabel(settings.themeMode)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pickThemeMode(context, manager),
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
                    ListTile(
                      leading: const Icon(
                        Icons.visibility_outlined,
                        color: Color(0xFFEC4899),
                      ),
                      title: const Text('Visibilitas Konten'),
                      subtitle: Text(settings.contentVisibilitySummary),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              _ContentVisibilitySubmenu(manager: manager),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// SUBMENU 4B: Visibilitas Konten (Checklist Biasa / Ecchi / NSFW)
// =============================================================================
class _ContentVisibilitySubmenu extends StatelessWidget {
  final DownloadManager manager;

  const _ContentVisibilitySubmenu({required this.manager});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Visibilitas Konten')),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final theme = Theme.of(context);
          final settings = manager.settings;
          final counts = manager.countPhotosByRating();

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  'Centang kategori konten foto yang ingin ditampilkan di tab File, Album, dan Semua Foto. Semua foto secara default bertanda Biasa dan dapat diganti langsung dari tombol Tandai saat melihat foto.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    CheckboxListTile(
                      secondary: _ratingIconBox(ContentRating.normal),
                      title: Row(
                        children: [
                          Text(
                            ContentRating.normal.label,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 8),
                          _ratingCountChip(
                            context,
                            counts[ContentRating.normal] ?? 0,
                            ContentRating.normal.color,
                          ),
                        ],
                      ),
                      subtitle: Text(ContentRating.normal.description),
                      value: settings.showNormalContent,
                      onChanged: (v) => manager.updateSettings(
                        settings.copyWith(showNormalContent: v ?? true),
                      ),
                    ),
                    const Divider(height: 1, indent: 68),
                    CheckboxListTile(
                      secondary: _ratingIconBox(ContentRating.ecchi),
                      title: Row(
                        children: [
                          Text(
                            ContentRating.ecchi.label,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 8),
                          _ratingCountChip(
                            context,
                            counts[ContentRating.ecchi] ?? 0,
                            ContentRating.ecchi.color,
                          ),
                        ],
                      ),
                      subtitle: Text(ContentRating.ecchi.description),
                      value: settings.showEcchiContent,
                      onChanged: (v) => manager.updateSettings(
                        settings.copyWith(showEcchiContent: v ?? true),
                      ),
                    ),
                    const Divider(height: 1, indent: 68),
                    CheckboxListTile(
                      secondary: _ratingIconBox(ContentRating.nsfw),
                      title: Row(
                        children: [
                          Text(
                            ContentRating.nsfw.label,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 8),
                          _ratingCountChip(
                            context,
                            counts[ContentRating.nsfw] ?? 0,
                            ContentRating.nsfw.color,
                          ),
                        ],
                      ),
                      subtitle: Text(ContentRating.nsfw.description),
                      value: settings.showNsfwContent,
                      onChanged: (v) => manager.updateSettings(
                        settings.copyWith(showNsfwContent: v ?? true),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: settings.showsAllContentRatings
                          ? null
                          : () => manager.updateSettings(
                                settings.copyWith(
                                  showNormalContent: true,
                                  showEcchiContent: true,
                                  showNsfwContent: true,
                                ),
                              ),
                      icon: const Icon(Icons.done_all_rounded, size: 18),
                      label: const Text('Tampilkan Semua'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (settings.showNormalContent &&
                              !settings.showEcchiContent &&
                              !settings.showNsfwContent)
                          ? null
                          : () => manager.updateSettings(
                                settings.copyWith(
                                  showNormalContent: true,
                                  showEcchiContent: false,
                                  showNsfwContent: false,
                                ),
                              ),
                      icon: const Icon(Icons.shield_outlined, size: 18),
                      label: const Text('Biasa Saja'),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _ratingIconBox(ContentRating rating) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: rating.color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(rating.icon, color: rating.color, size: 20),
    );
  }

  Widget _ratingCountChip(BuildContext context, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count foto',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// =============================================================================
// SUBMENU 5: Mesin & Izin Sistem
// =============================================================================
class _EngineSystemSubmenu extends StatelessWidget {
  final DownloadManager manager;

  const _EngineSystemSubmenu({required this.manager});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mesin & Izin Sistem')),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final theme = Theme.of(context);
          final settings = manager.settings;
          final engine = manager.engineStatus;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
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
                        label: 'FFmpeg (Merge HD, MP3 & Ugoira)',
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
                              : () => _updateEngine(context, manager),
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

              const SizedBox(height: 14),

              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
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
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(
                        manager.permissionStatus.allFilesGranted
                            ? Icons.lock_person_rounded
                            : Icons.admin_panel_settings_outlined,
                        color: manager.permissionStatus.allFilesGranted
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFF59E0B),
                      ),
                      title: const Text('Penyimpanan Anti-Hilang (Akses Semua File)'),
                      subtitle: Text(
                        manager.permissionStatus.allFilesGranted
                            ? 'Aktif — Brankas Privat Pixiv & seluruh pengaturan tersimpan di Documents/.all_download_vault (tahan uninstall & flutter run)'
                            : 'Belum aktif — aktifkan agar foto Privat Pixiv, penanda, tag album, rating & pengaturan otomatis bertahan saat uninstall / install ulang',
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: () async {
                          await manager.requestAllFilesAccess();
                        },
                        child: Text(
                          manager.permissionStatus.allFilesGranted
                              ? 'Aktif'
                              : 'Aktifkan',
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: Icon(
                        Icons.notifications_active_outlined,
                        color: (settings.notificationsEnabled &&
                                manager.permissionStatus.notificationGranted)
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFF59E0B),
                      ),
                      title: const Text('Notifikasi & Layanan Latar Belakang'),
                      subtitle: Text(
                        !manager.permissionStatus.notificationGranted
                            ? 'Izin notifikasi belum aktif — nyalakan agar progres unduhan & Foreground Service tetap berjalan saat layar mati'
                            : (settings.notificationsEnabled
                                ? 'Aktif — tampilkan progres unduhan, tombol Jeda Semua, dan notifikasi saat selesai'
                                : 'Nonaktif — progres unduhan tidak ditampilkan di bar notifikasi'),
                      ),
                      value: settings.notificationsEnabled &&
                          manager.permissionStatus.notificationGranted,
                      onChanged: (v) async {
                        if (v && !manager.permissionStatus.notificationGranted) {
                          final ok =
                              await manager.requestNotificationPermission();
                          if (!ok && context.mounted) {
                            showTopToast(
                              context,
                              'Izinkan Notifikasi di pengaturan sistem agar layanan anti-kill aktif.',
                              isError: true,
                            );
                            return;
                          }
                        }
                        await manager.updateSettings(
                          settings.copyWith(notificationsEnabled: v),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(
                        manager.permissionStatus.batteryOptimizationIgnored
                            ? Icons.battery_charging_full_rounded
                            : Icons.battery_alert_rounded,
                        color: manager.permissionStatus.batteryOptimizationIgnored
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFF59E0B),
                      ),
                      title: const Text('Anti-Kill Baterai (MIUI / HyperOS)'),
                      subtitle: Text(
                        manager.permissionStatus.batteryOptimizationIgnored
                            ? 'Aktif — aplikasi dikecualikan dari penghemat baterai agar unduhan massal ratusan album tidak terputus di latar belakang'
                            : 'Disarankan aktifkan di HP Xiaomi/MIUI agar sistem tidak mematikan proses unduhan saat layar terkunci',
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: () async {
                          await manager.requestIgnoreBatteryOptimizations();
                        },
                        child: Text(
                          manager.permissionStatus.batteryOptimizationIgnored
                              ? 'Aktif'
                              : 'Bebaskan',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// SUBMENU: Keamanan & Privasi (PIN, Biometrik, FLAG_SECURE, Stealth)
// =============================================================================
class _SecurityPrivacySubmenu extends StatelessWidget {
  final DownloadManager manager;

  const _SecurityPrivacySubmenu({required this.manager});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Keamanan & Privasi')),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final settings = manager.settings;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: Icon(
                        settings.isSecurityLockActive
                            ? Icons.lock_rounded
                            : Icons.lock_open_rounded,
                        color: settings.isSecurityLockActive
                            ? const Color(0xFF22C55E)
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: const Text('Kunci Keamanan Aplikasi / Brankas'),
                      subtitle: Text(
                        settings.isSecurityLockActive
                            ? 'Aktif — melindungi koleksi & pengaturan dengan ${settings.hasPinConfigured ? 'PIN' : ''}${settings.hasPinConfigured && settings.appLockUseBiometric ? ' + ' : ''}${settings.appLockUseBiometric ? 'Sidik Jari / Kunci HP' : ''}'
                            : 'Aktifkan PIN dan/atau Sidik Jari agar koleksi tetap aman',
                      ),
                      value: settings.appLockEnabled,
                      onChanged: (enable) async {
                        if (enable) {
                          var nextPinHash = settings.appLockPinHash;
                          final canBio =
                              await manager.canAuthenticateBiometric();
                          if (!context.mounted) return;
                          if (nextPinHash.isEmpty && !canBio) {
                            final pinHash = await showPinSetupSheet(context);
                            if (pinHash == null || !context.mounted) return;
                            nextPinHash = pinHash;
                          } else if (nextPinHash.isEmpty) {
                            final pinHash = await showPinSetupSheet(context);
                            if (pinHash != null) nextPinHash = pinHash;
                          }
                          await manager.updateSettings(
                            settings.copyWith(
                              appLockEnabled: true,
                              appLockPinHash: nextPinHash,
                              appLockUseBiometric: canBio,
                            ),
                          );
                          if (context.mounted) {
                            showTopToast(
                              context,
                              'Kunci keamanan aktif!',
                              icon: Icons.lock_rounded,
                            );
                          }
                        } else {
                          final ok = await verifySecurityGate(
                            context,
                            manager,
                            title: 'Nonaktifkan Kunci',
                            subtitle:
                                'Verifikasi terlebih dahulu untuk mematikan kunci',
                          );
                          if (!ok || !context.mounted) return;
                          await manager.updateSettings(
                            settings.copyWith(appLockEnabled: false),
                          );
                          if (context.mounted) {
                            showTopToast(
                              context,
                              'Kunci keamanan dinonaktifkan.',
                              icon: Icons.lock_open_rounded,
                            );
                          }
                        }
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.pin_outlined),
                      title: Text(
                        settings.hasPinConfigured
                            ? 'Ubah PIN Keamanan'
                            : 'Atur PIN (4–6 Digit)',
                      ),
                      subtitle: Text(
                        settings.hasPinConfigured
                            ? 'PIN sudah terpasang (tersimpan aman di backup anti-hilang)'
                            : 'Buat PIN cadangan jika sidik jari tidak tersedia',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        if (settings.hasPinConfigured &&
                            settings.isSecurityLockActive) {
                          final ok = await verifySecurityGate(
                            context,
                            manager,
                            title: 'Verifikasi PIN Lama',
                            subtitle: 'Masukkan PIN lama sebelum mengganti PIN',
                          );
                          if (!ok || !context.mounted) return;
                        }
                        final pinHash = await showPinSetupSheet(
                          context,
                          isChange: settings.hasPinConfigured,
                        );
                        if (pinHash == null || !context.mounted) return;
                        await manager.updateSettings(
                          settings.copyWith(
                            appLockPinHash: pinHash,
                            appLockEnabled: true,
                          ),
                        );
                        if (context.mounted) {
                          showTopToast(
                            context,
                            'PIN keamanan berhasil disimpan.',
                            icon: Icons.verified_user_rounded,
                          );
                        }
                      },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.fingerprint_rounded),
                      title: const Text('Gunakan Sidik Jari / Kunci Layar HP'),
                      subtitle: const Text(
                        'Buka kunci cepat menggunakan sensor sidik jari atau pola/PIN perangkat',
                      ),
                      value: settings.appLockUseBiometric,
                      onChanged: (v) async {
                        if (v) {
                          final canBio =
                              await manager.canAuthenticateBiometric();
                          if (!canBio && context.mounted) {
                            showTopToast(
                              context,
                              'Perangkat belum mengaktifkan sidik jari / kunci layar sistem.',
                              isError: true,
                            );
                            return;
                          }
                        }
                        await manager.updateSettings(
                          settings.copyWith(appLockUseBiometric: v),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Cakupan Kunci',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              ChoiceChip(
                                label: const Text('Seluruh Aplikasi'),
                                selected: settings.appLockScope == 'app',
                                onSelected: (_) => manager.updateSettings(
                                  settings.copyWith(appLockScope: 'app'),
                                ),
                              ),
                              ChoiceChip(
                                label: const Text('Tab File & Visibilitas Saja'),
                                selected: settings.appLockScope == 'vault',
                                onSelected: (_) => manager.updateSettings(
                                  settings.copyWith(appLockScope: 'vault'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.phonelink_lock_rounded),
                      title: const Text('Sembunyikan Preview Recent Apps'),
                      subtitle: const Text(
                        'Aktifkan FLAG_SECURE Android agar layar aplikasi tampil kosong di Recent Apps dan mencegah tangkapan layar tidak sengaja',
                      ),
                      value: settings.secureScreenEnabled,
                      onChanged: (v) => manager.updateSettings(
                        settings.copyWith(secureScreenEnabled: v),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.visibility_off_outlined),
                      title: const Text('Tips Mode Aman Cepat (Stealth)'),
                      subtitle: const Text(
                        'Tekan tahan ikon tab "File" di navigasi bawah kapan saja untuk langsung menyembunyikan seluruh konten Ecchi & NSFW seketika.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// SHARED ACTIONS & DIALOGS
// =============================================================================
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

Future<void> _exportBackupFile(
  BuildContext context,
  DownloadManager manager,
) async {
  try {
    final saved = await manager.exportBackupToFile();
    if (!context.mounted) return;
    if (saved) {
      showTopToast(
        context,
        'Backup pengaturan & data berhasil diekspor (.json).',
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    showTopToast(
      context,
      'Gagal mengekspor backup: $e',
      isError: true,
    );
  }
}

Future<void> _copyBackupJson(
  BuildContext context,
  DownloadManager manager,
) async {
  final json = manager.buildBackupJson();
  await Clipboard.setData(ClipboardData(text: json));
  if (!context.mounted) return;
  showTopToast(
    context,
    'Data backup JSON disalin ke clipboard.',
    icon: Icons.copy_rounded,
  );
}

Future<void> _importBackupFile(
  BuildContext context,
  DownloadManager manager,
) async {
  try {
    final bundle = await manager.pickAndParseBackupFile();
    if (bundle == null || !context.mounted) return;
    await _confirmAndApplyBackup(context, manager, bundle);
  } catch (e) {
    if (!context.mounted) return;
    showTopToast(
      context,
      'Gagal membaca file backup: ${e.toString().replaceFirst('FormatException: ', '')}',
      isError: true,
    );
  }
}

Future<void> _openPasteBackupDialog(
  BuildContext context,
  DownloadManager manager,
) async {
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
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
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
    await _confirmAndApplyBackup(context, manager, bundle);
  } catch (e) {
    if (!context.mounted) return;
    showTopToast(
      context,
      'Format JSON tidak valid: ${e.toString().replaceFirst('FormatException: ', '')}',
      isError: true,
    );
  }
}

Future<void> _confirmAndApplyBackup(
  BuildContext context,
  DownloadManager manager,
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
          if (bundle.albumMetadata.isNotEmpty)
            Text('• Tag album tersimpan: ${bundle.albumMetadata.length}'),
          if (bundle.photoRatings.isNotEmpty)
            Text('• Foto bertanda Ecchi/NSFW: ${bundle.photoRatings.length}'),
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
  showTopToast(
    context,
    mode == 'merge'
        ? 'Backup berhasil digabungkan!'
        : 'Backup berhasil diterapkan!',
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
                'Di HP lama, buka Pengaturan → Backup, Migrasi & Data → ketuk "Ekspor (.json)" (atau "Salin JSON"). File backup ini menyimpan pengaturan kualitas/tema/rate limit, seluruh penanda "Sudah Diunduh", daftar link profil artis ("Lanjut Unduh"), serta riwayat & antrean terjeda.',
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
                'Foto Pixiv yang berstatus Privat tersembunyi dari Galeri & WA:\n• Jika Penyimpanan Anti-Hilang (Akses Semua File) aktif, seluruh foto Privat & pengaturan tersimpan otomatis di folder Documents/.all_download_vault/ (tahan uninstall/install ulang di HP yang sama; cukup salin folder ini jika pindah HP).\n• Cara Tanpa PC: Buka tab File → Pixiv → tahan & pilih semua album → ketuk Unlock (pindah ke Pictures/all_download/Pixiv), lalu Kunci kembali di HP baru.',
          ),
          const SizedBox(height: 10),
          const _MigrationStepCard(
            step: '4',
            title: 'Impor Backup di HP Baru',
            body:
                'Pasang aplikasi all_download di HP baru → izinkan akses penyimpanan → buka Pengaturan → Backup, Migrasi & Data → ketuk "Impor (.json)" lalu pilih file backup tadi (pilih Gabung atau Timpa Semua).\n\nCatatan keamanan: Sesi login browser (IG/TikTok/Pixiv) sengaja tidak ikut diekspor demi keamanan akun — cukup login ulang 1 kali di Pengaturan HP baru.',
          ),
        ],
      ),
    ),
  );
}

Future<void> _doBrowserLogin(
  BuildContext context,
  DownloadManager manager,
  String key,
  String label,
) async {
  final ok = await manager.openBrowserLogin(key);
  if (!context.mounted) return;
  showTopToast(
    context,
    ok ? 'Sesi $label tersimpan!' : 'Sesi $label ditutup.',
    icon: ok ? Icons.verified_user_rounded : Icons.info_outline_rounded,
  );
}

Future<void> _updateEngine(
  BuildContext context,
  DownloadManager manager,
) async {
  try {
    final result = await manager.updateYtDlpEngine();
    if (!context.mounted) return;
    final msg = result.updated
        ? 'Berhasil diperbarui ke yt-dlp ${result.version}'
        : 'yt-dlp sudah versi terbaru (${result.version})';
    showTopToast(context, msg, icon: Icons.system_update_rounded);
  } catch (e) {
    if (!context.mounted) return;
    showTopToast(
      context,
      'Gagal memperbarui yt-dlp: $e',
      isError: true,
    );
  }
}

Future<void> _clearCache(
  BuildContext context,
  DownloadManager manager,
) async {
  final freed = await manager.clearCache();
  if (!context.mounted) return;
  final msg = freed > 0
      ? 'Berhasil membersihkan ${formatBytes(freed)} cache sementara.'
      : 'Tidak ada cache sementara untuk dibersihkan.';
  showTopToast(context, msg, icon: Icons.cleaning_services_rounded);
}

Future<void> _confirmResetMarkers(
  BuildContext context,
  DownloadManager manager,
) async {
  final count = manager.downloadedMarkers.length;
  final ok = await showBottomDeleteConfirm(
    context,
    title: 'Reset Semua Penandaan?',
    message:
        'Hapus semua $count tanda "Sudah diunduh"? File yang tersimpan di penyimpanan perangkat tetap aman.',
    confirmLabel: 'Reset Semua',
  );
  if (ok) {
    await manager.clearAllDownloadedMarkers();
    if (!context.mounted) return;
    showTopToast(
      context,
      'Semua penandaan "Sudah diunduh" telah dihapus.',
    );
  }
}

Future<void> _pickDefaultQuality(
  BuildContext context,
  DownloadManager manager,
) async {
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

Future<void> _pickThemeMode(
  BuildContext context,
  DownloadManager manager,
) async {
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

Future<void> _openCookiesDialog(
  BuildContext context,
  DownloadManager manager,
) async {
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
      showTopToast(
        context,
        saved.isEmpty
            ? 'Cookies dihapus.'
            : 'Cookies berhasil disimpan.',
        icon: Icons.cookie_outlined,
      );
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
