import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/media_info.dart';
import '../services/download_manager.dart';

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

              // Browser Session Login Card (1-Tap for Instagram & Douyin)
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.public_rounded),
                      title: const Text('Login Browser (Instagram & Douyin)'),
                      subtitle: const Text(
                        'Opsional: login sekali langsung di aplikasi agar Reels/Post Instagram & video Douyin yang dibatasi terbuka penuh',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () async {
                                final ok = await manager.openBrowserLogin('instagram');
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok
                                          ? 'Sesi Instagram tersimpan!'
                                          : 'Sesi Instagram ditutup.',
                                    ),
                                  ),
                                );
                              },
                              icon: Icon(
                                manager.instagramLoggedIn
                                    ? Icons.check_circle_rounded
                                    : Icons.login_rounded,
                                size: 18,
                              ),
                              label: Text(
                                manager.instagramLoggedIn
                                    ? 'IG Aktif'
                                    : 'Login IG',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () async {
                                final ok = await manager.openBrowserLogin('douyin');
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok
                                          ? 'Sesi Douyin tersimpan!'
                                          : 'Sesi Douyin ditutup.',
                                    ),
                                  ),
                                );
                              },
                              icon: Icon(
                                manager.douyinLoggedIn
                                    ? Icons.check_circle_rounded
                                    : Icons.login_rounded,
                                size: 18,
                              ),
                              label: Text(
                                manager.douyinLoggedIn
                                    ? 'Douyin Aktif'
                                    : 'Login Douyin',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (manager.instagramLoggedIn || manager.douyinLoggedIn) ...[
                      const Divider(height: 1),
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.logout_rounded, size: 20),
                        title: const Text('Hapus Sesi Browser'),
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
