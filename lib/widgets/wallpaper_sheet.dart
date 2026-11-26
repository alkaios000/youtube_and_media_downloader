import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/managed_file.dart';
import '../services/download_manager.dart';

/// Presents a fast native-backed bottom sheet letting the user set any image
/// (public or Private Vault) as Android Home Screen, Lock Screen, Both, or via
/// our in-app interactive Crop & Preview Wallpaper editor (100% Xiaomi MIUI &
/// Android 7–16 compatible, zero broken OEM intents and zero Private Vault leaks).
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
            subtitle: Text('Pilih layar tujuan atau atur posisi & zoom gambar'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.crop_rounded),
            title: const Text('Atur & Potong (Preview)'),
            subtitle: const Text('Geser & zoom gambar persis sesuai layar HP Anda'),
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

  if (target == 'crop') {
    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => WallpaperCropPreviewScreen(
          manager: manager,
          file: file,
        ),
      ),
    );
    if (applied == true && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Wallpaper berhasil dipasang!')),
        );
    }
    return;
  }

  await _applyWallpaperDirect(
    context,
    manager: manager,
    file: file,
    target: target,
  );
}

Future<bool> _applyWallpaperDirect(
  BuildContext context, {
  required DownloadManager manager,
  required ManagedFile file,
  required String target,
  Rect? cropRect,
}) async {
  try {
    final ok = await manager.setManagedFileAsWallpaper(
      file,
      target: target,
      cropRect: cropRect,
    );
    if (!context.mounted) return ok;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'Wallpaper berhasil dipasang!' : 'Gagal memasang wallpaper.',
          ),
        ),
      );
    return ok;
  } on MissingPluginException {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Modul native belum terpasang. Stop lalu Run ulang aplikasi (atau pasang APK terbaru) agar fitur Wallpaper aktif.',
          ),
        ),
      );
    return false;
  } on PlatformException catch (e) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            e.message?.isNotEmpty == true
                ? e.message!
                : 'Gagal memasang wallpaper.',
          ),
        ),
      );
    return false;
  } catch (e) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Gagal memasang wallpaper: ${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    return false;
  }
}

/// Full-screen interactive Wallpaper Crop & Preview editor.
/// Works on all Android OEMs (including Xiaomi MIUI/HyperOS) and Private Vault
/// images without touching public MediaStore or broken OEM intents.
class WallpaperCropPreviewScreen extends StatefulWidget {
  final DownloadManager manager;
  final ManagedFile file;

  const WallpaperCropPreviewScreen({
    super.key,
    required this.manager,
    required this.file,
  });

  @override
  State<WallpaperCropPreviewScreen> createState() =>
      _WallpaperCropPreviewScreenState();
}

class _WallpaperCropPreviewScreenState
    extends State<WallpaperCropPreviewScreen> {
  final TransformationController _transformController =
      TransformationController();
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  Size? _naturalImageSize;
  Size? _lastViewportSize;
  bool _hasCentered = false;
  bool _showClockOverlay = true;
  bool _applying = false;
  String _selectedTarget = 'both';
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _resolveNaturalImageSize();
  }

  void _resolveNaturalImageSize() {
    final path = widget.file.savedPath;
    if (path.isEmpty) {
      _loadError = 'Lokasi file gambar tidak tersedia.';
      return;
    }
    final provider = FileImage(File(path));
    final stream = provider.resolve(const ImageConfiguration());
    _imageStream = stream;
    _imageListener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!mounted) return;
        setState(() {
          _naturalImageSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
          _loadError = null;
        });
      },
      onError: (Object err, StackTrace? _) {
        if (!mounted) return;
        setState(() {
          _loadError = 'Gambar tidak dapat dimuat dari penyimpanan.';
        });
      },
    );
    stream.addListener(_imageListener!);
  }

  @override
  void dispose() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _transformController.dispose();
    super.dispose();
  }

  Size _computeCoverDisplaySize(Size viewport, Size natural) {
    final scaleCover = math.max(
      viewport.width / natural.width,
      viewport.height / natural.height,
    );
    return Size(natural.width * scaleCover, natural.height * scaleCover);
  }

  void _centerInitialMatrix(Size viewport, Size displaySize) {
    final dx = (viewport.width - displaySize.width) / 2.0;
    final dy = (viewport.height - displaySize.height) / 2.0;
    _transformController.value = Matrix4.identity()
      ..setTranslationRaw(dx, dy, 0.0);
    _hasCentered = true;
    _lastViewportSize = viewport;
  }

  Rect? _computeNormalizedCropRect(Size viewport, Size displaySize) {
    final m = _transformController.value;
    final scale = m.getMaxScaleOnAxis();
    if (scale <= 0 || displaySize.width <= 0 || displaySize.height <= 0) {
      return null;
    }
    final tx = m.storage[12];
    final ty = m.storage[13];

    final visLeft = -tx / scale;
    final visTop = -ty / scale;
    final visWidth = viewport.width / scale;
    final visHeight = viewport.height / scale;

    final left = (visLeft / displaySize.width).clamp(0.0, 0.99);
    final top = (visTop / displaySize.height).clamp(0.0, 0.99);
    final width = (visWidth / displaySize.width).clamp(0.01, 1.0 - left);
    final height = (visHeight / displaySize.height).clamp(0.01, 1.0 - top);
    return Rect.fromLTWH(left, top, width, height);
  }

  Future<void> _applyCroppedWallpaper(Size viewport, Size displaySize) async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      final cropRect = _computeNormalizedCropRect(viewport, displaySize);
      final ok = await widget.manager.setManagedFileAsWallpaper(
        widget.file,
        target: _selectedTarget,
        cropRect: cropRect,
      );
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
      } else {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Gagal memasang wallpaper.')),
          );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              e.message?.isNotEmpty == true
                  ? e.message!
                  : 'Gagal memasang wallpaper.',
            ),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Gagal memasang wallpaper: ${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          final natural = _naturalImageSize;
          Size? displaySize;
          if (natural != null && natural.width > 0 && natural.height > 0) {
            displaySize = _computeCoverDisplaySize(viewport, natural);
            if (!_hasCentered || _lastViewportSize != viewport) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && displaySize != null) {
                  _centerInitialMatrix(viewport, displaySize);
                }
              });
              // Apply synchronously for frame 1 so there is zero jump
              _centerInitialMatrix(viewport, displaySize);
            }
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              if (_loadError != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _loadError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                )
              else if (displaySize == null)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                )
              else
                InteractiveViewer(
                  transformationController: _transformController,
                  constrained: false,
                  minScale: 1.0,
                  maxScale: 4.0,
                  boundaryMargin: EdgeInsets.zero,
                  child: SizedBox(
                    width: displaySize.width,
                    height: displaySize.height,
                    child: Image.file(
                      File(widget.file.savedPath),
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),

              // Optional Lockscreen Clock Preview Overlay (non-interactive!)
              if (_showClockOverlay && displaySize != null)
                IgnorePointer(
                  child: SafeArea(
                    child: Align(
                      alignment: const Alignment(0, -0.62),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            timeStr,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 64,
                              fontWeight: FontWeight.w300,
                              letterSpacing: -1.5,
                              shadows: [
                                Shadow(
                                  color: Color(0x88000000),
                                  blurRadius: 18,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                          const Text(
                            'Geser & cubit untuk atur posisi wallpaper',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(
                                  color: Color(0xAA000000),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Top Action Bar
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xBB000000), Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: _applying
                                ? null
                                : () => Navigator.of(context).pop(false),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white,
                            ),
                          ),
                          const Expanded(
                            child: Text(
                              'Atur Wallpaper',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => setState(
                              () => _showClockOverlay = !_showClockOverlay,
                            ),
                            icon: Icon(
                              _showClockOverlay
                                  ? Icons.access_time_filled_rounded
                                  : Icons.access_time_rounded,
                              color: _showClockOverlay
                                  ? Colors.white
                                  : Colors.white54,
                            ),
                            tooltip: 'Preview Jam',
                          ),
                          if (displaySize != null)
                            IconButton(
                              onPressed: () => setState(() {
                                _centerInitialMatrix(viewport, displaySize!);
                              }),
                              icon: const Icon(
                                Icons.center_focus_strong_rounded,
                                color: Colors.white,
                              ),
                              tooltip: 'Reset Posisi',
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Bottom Target Picker & Apply Bar
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Color(0xE6000000),
                        Color(0x99000000),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _TargetPill(
                                  label: 'Utama',
                                  icon: Icons.home_outlined,
                                  selected: _selectedTarget == 'home',
                                  onTap: () =>
                                      setState(() => _selectedTarget = 'home'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _TargetPill(
                                  label: 'Kunci',
                                  icon: Icons.lock_outline_rounded,
                                  selected: _selectedTarget == 'lock',
                                  onTap: () =>
                                      setState(() => _selectedTarget = 'lock'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _TargetPill(
                                  label: 'Keduanya',
                                  icon: Icons.smartphone_rounded,
                                  selected: _selectedTarget == 'both',
                                  onTap: () =>
                                      setState(() => _selectedTarget = 'both'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: FilledButton.icon(
                              onPressed: (_applying || displaySize == null)
                                  ? null
                                  : () => _applyCroppedWallpaper(
                                        viewport,
                                        displaySize!,
                                      ),
                              icon: _applying
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.check_rounded),
                              label: Text(
                                _applying
                                    ? 'Memasang Wallpaper...'
                                    : 'Pasang Wallpaper',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TargetPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _TargetPill({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Material(
      color: selected ? primary : Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
