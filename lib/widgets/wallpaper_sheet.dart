import 'package:flutter/material.dart';

import '../models/managed_file.dart';
import '../services/download_manager.dart';

/// Presents a fast native-backed bottom sheet letting the user set any image
/// (public or Private Vault) as Android Home Screen, Lock Screen, Both, or via
/// Android's built-in Crop & Preview wallpaper chooser.
Future<void> showSetWallpaperSheet(
  BuildContext context, {
  required DownloadManager manager,
  required ManagedFile file,
}) async {
  final target = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            leading: Icon(Icons.wallpaper_rounded),
            title: Text(
              'Jadikan Wallpaper',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text('Pilih layar tujuan atau atur posisi gambar'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.crop_rounded),
            title: const Text('Atur & Potong (Preview Sistem)'),
            subtitle: const Text('Sesuaikan posisi & zoom sebelum dipasang'),
            onTap: () => Navigator.pop(ctx, 'crop'),
          ),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Layar Utama (Home Screen)'),
            onTap: () => Navigator.pop(ctx, 'home'),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline_rounded),
            title: const Text('Layar Kunci (Lock Screen)'),
            onTap: () => Navigator.pop(ctx, 'lock'),
          ),
          ListTile(
            leading: const Icon(Icons.smartphone_rounded),
            title: const Text('Layar Utama & Layar Kunci'),
            onTap: () => Navigator.pop(ctx, 'both'),
          ),
          const SizedBox(height: 10),
        ],
      ),
    ),
  );

  if (target == null || !context.mounted) return;

  try {
    final ok = await manager.setManagedFileAsWallpaper(file, target: target);
    if (!context.mounted) return;
    if (target != 'crop') {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Wallpaper berhasil dipasang!'
                  : 'Gagal memasang wallpaper.',
            ),
          ),
        );
    } else if (!ok) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Tidak dapat membuka pemilih wallpaper sistem.'),
          ),
        );
    }
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Gagal memasang wallpaper: ${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
  }
}
