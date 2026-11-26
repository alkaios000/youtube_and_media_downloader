import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/managed_file.dart';
import '../models/media_info.dart';
import '../services/download_manager.dart';
import 'wallpaper_sheet.dart';

/// Full-screen, swipeable, unclipped pinch-to-zoom & double-tap-to-zoom gallery viewer
/// for downloaded images with Unlock/Lock, Share, Open Externally, Info, and Delete controls.
class FileGalleryViewer extends StatefulWidget {
  final DownloadManager manager;
  final List<ManagedFile> images;
  final int initialIndex;
  final bool enableShuffleRefresh;
  final bool showCreatorInSubtitle;
  final VoidCallback? onShuffleRefresh;

  const FileGalleryViewer({
    super.key,
    required this.manager,
    required this.images,
    required this.initialIndex,
    this.enableShuffleRefresh = false,
    this.showCreatorInSubtitle = false,
    this.onShuffleRefresh,
  });

  @override
  State<FileGalleryViewer> createState() => _FileGalleryViewerState();
}

class _FileGalleryViewerState extends State<FileGalleryViewer> {
  late final PageController _pageController;
  late List<ManagedFile> _images;
  late int _currentIndex;
  double? _dragStartPixels;
  bool _showChrome = true;
  bool _isZoomed = false;
  bool _togglingPrivacy = false;

  @override
  void initState() {
    super.initState();
    _images = List<ManagedFile>.from(widget.images);
    _currentIndex = widget.initialIndex.clamp(0, _images.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  ManagedFile get _current => _images[_currentIndex];

  void _shuffleInViewer() {
    if (_images.length <= 1) return;
    HapticFeedback.selectionClick();
    final shuffled = List<ManagedFile>.from(_images)
      ..shuffle(math.Random(DateTime.now().microsecondsSinceEpoch));
    setState(() {
      _images = shuffled;
      _currentIndex = 0;
      _isZoomed = false;
    });
    if (_pageController.hasClients) {
      _pageController.jumpToPage(0);
    }
    widget.onShuffleRefresh?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_images.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Full-viewport swipeable & unclipped zoomable pager
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.depth == 0) {
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  _dragStartPixels = notification.metrics.pixels;
                } else if (notification is ScrollEndNotification) {
                  _dragStartPixels = null;
                }
              }
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              // Do not eagerly decode offscreen neighbors so every swipe stays light & smooth
              allowImplicitScrolling: false,
              physics: _isZoomed
                  ? const NeverScrollableScrollPhysics()
                  : _SnappyPhotoPagePhysics(
                      dragStartPixelsProvider: () => _dragStartPixels,
                    ),
              itemCount: _images.length,
              onPageChanged: (idx) {
                setState(() {
                  _currentIndex = idx;
                  _isZoomed = false;
                });
              },
              itemBuilder: (context, index) {
                final img = _images[index];
                return RepaintBoundary(
                  key: ValueKey(img.uniqueKey),
                  child: _ZoomablePhotoPage(
                    filePath: img.savedPath,
                    onTap: () => setState(() => _showChrome = !_showChrome),
                    onZoomStateChanged: (zoomed) {
                      if (index == _currentIndex && zoomed != _isZoomed) {
                        setState(() => _isZoomed = zoomed);
                      }
                    },
                  ),
                );
              },
            ),
          ),

          // Top bar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            top: _showChrome ? 0 : -120,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.78),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _current.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              widget.showCreatorInSubtitle
                                  ? '${_currentIndex + 1} / ${_images.length} • ${_current.creatorFolder}'
                                  : '${_currentIndex + 1} / ${_images.length} • ${formatBytes(_current.fileSize)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.enableShuffleRefresh && _images.length > 1)
                        IconButton(
                          onPressed: _shuffleInViewer,
                          icon: const Icon(
                            Icons.shuffle_rounded,
                            color: Colors.white,
                          ),
                          tooltip: 'Acak ulang & segarkan',
                        ),
                      IconButton(
                        onPressed: () => widget.manager.openManagedFile(_current),
                        icon: const Icon(Icons.open_in_new_rounded, color: Colors.white),
                        tooltip: 'Buka di App Lain',
                      ),
                      IconButton(
                        onPressed: _showInfoSheet,
                        icon: const Icon(Icons.info_outline_rounded, color: Colors.white),
                        tooltip: 'Detail File',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Bottom action bar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            bottom: _showChrome ? 0 : -120,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.82),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ViewerActionBtn(
                        icon: _current.isPrivate
                            ? Icons.lock_rounded
                            : Icons.lock_open_rounded,
                        label: _current.isPrivate ? 'Privat' : 'Galeri',
                        color: _current.isPrivate
                            ? const Color(0xFFFBBF24)
                            : const Color(0xFF4ADE80),
                        activePill: true,
                        loading: _togglingPrivacy,
                        onTap: _togglingPrivacy ? () {} : _togglePrivacyCurrent,
                      ),
                      _ViewerActionBtn(
                        icon: Icons.wallpaper_rounded,
                        label: 'Wallpaper',
                        onTap: () => showSetWallpaperSheet(
                          context,
                          manager: widget.manager,
                          file: _current,
                        ),
                      ),
                      _ViewerActionBtn(
                        icon: Icons.share_rounded,
                        label: 'Bagikan',
                        onTap: () => widget.manager.shareManagedFile(_current),
                      ),
                      _ViewerActionBtn(
                        icon: Icons.delete_outline_rounded,
                        label: 'Hapus',
                        color: const Color(0xFFF87171),
                        onTap: _confirmDeleteCurrent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _togglePrivacyCurrent() async {
    if (_togglingPrivacy) return;
    setState(() => _togglingPrivacy = true);
    try {
      final target = _current;
      final wasPrivate = target.isPrivate;
      final count = wasPrivate
          ? await widget.manager.unlockManagedFiles([target])
          : await widget.manager.lockManagedFiles([target]);
      if (!mounted || count == 0) return;

      final updated = widget.manager.managedFiles
          .where((f) =>
              f.platformFolder == target.platformFolder &&
              f.creatorFolder == target.creatorFolder &&
              f.fileName == target.fileName)
          .firstOrNull;
      setState(() {
        if (updated != null) {
          _images[_currentIndex] = updated;
        }
      });
    } finally {
      if (mounted) setState(() => _togglingPrivacy = false);
    }
  }

  Future<void> _confirmDeleteCurrent() async {
    final target = _current;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Foto?'),
        content: Text('Hapus permanen "${target.fileName}" dari perangkat?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await widget.manager.deleteManagedFile(target);
    if (!mounted) return;
    setState(() {
      _images.removeAt(_currentIndex);
      if (_images.isEmpty) {
        Navigator.pop(context);
      } else if (_currentIndex >= _images.length) {
        _currentIndex = _images.length - 1;
      }
    });
  }

  void _showInfoSheet() {
    final f = _current;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Detail File',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 12),
              _DetailRow(
                label: 'Status',
                value: f.isPrivate
                    ? 'Privat (Tersembunyi dari Galeri & WA)'
                    : 'Terbuka (Muncul di Galeri & WA)',
              ),
              _DetailRow(label: 'Nama', value: f.fileName),
              _DetailRow(
                label: 'Folder',
                value: '${f.platformFolder} / ${f.creatorFolder}',
              ),
              _DetailRow(label: 'Ukuran', value: formatBytes(f.fileSize)),
              _DetailRow(label: 'Format', value: f.mimeType),
              _DetailRow(
                label: 'Lokasi',
                value: f.savedPath.isNotEmpty ? f.savedPath : f.relativePath,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(
                        text: f.savedPath.isNotEmpty
                            ? f.savedPath
                            : f.relativePath,
                      ),
                    );
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Lokasi file disalin.')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  label: const Text('Salin Lokasi'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-viewport zoomable image page:
/// - `InteractiveViewer` occupies the ENTIRE screen (`SizedBox.expand`), NOT just
///   the image's intrinsic aspect-ratio rectangle, so zooming landscape or portrait
///   images expands freely into the full screen with ZERO top/bottom/side clipping!
/// - Double-tap zooms cleanly to 2.6x at the tapped focal point (or resets to 1.0x).
/// - Panning only locks the parent PageView while zoomed (> 1.02x).
class _ZoomablePhotoPage extends StatefulWidget {
  final String filePath;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomStateChanged;

  const _ZoomablePhotoPage({
    required this.filePath,
    required this.onTap,
    required this.onZoomStateChanged,
  });

  @override
  State<_ZoomablePhotoPage> createState() => _ZoomablePhotoPageState();
}

class _ZoomablePhotoPageState extends State<_ZoomablePhotoPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _controller = TransformationController();
  late final AnimationController _animController;
  Animation<Matrix4>? _matrixAnimation;
  TapDownDetails? _doubleTapDetails;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() {
        if (_matrixAnimation != null) {
          _controller.value = _matrixAnimation!.value;
        }
      });
    _controller.addListener(_handleMatrixChange);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleMatrixChange);
    _animController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleMatrixChange() {
    final scale = _controller.value.getMaxScaleOnAxis();
    final nowZoomed = scale > 1.02;
    if (nowZoomed != _zoomed) {
      _zoomed = nowZoomed;
      widget.onZoomStateChanged(nowZoomed);
    }
  }

  void _handleDoubleTap() {
    final currentScale = _controller.value.getMaxScaleOnAxis();
    final Matrix4 target;
    if (currentScale > 1.05) {
      target = Matrix4.identity();
    } else {
      const zoomScale = 2.6;
      final tapPos = _doubleTapDetails?.localPosition ??
          Offset(
            MediaQuery.sizeOf(context).width / 2,
            MediaQuery.sizeOf(context).height / 2,
          );
      target = Matrix4.identity()
        ..translateByDouble(
          -tapPos.dx * (zoomScale - 1),
          -tapPos.dy * (zoomScale - 1),
          0,
          1,
        )
        ..scaleByDouble(zoomScale, zoomScale, 1, 1);
    }

    _matrixAnimation = Matrix4Tween(
      begin: _controller.value,
      end: target,
    ).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _doubleTapDetails = d,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1.0,
        maxScale: 5.0,
        clipBehavior: Clip.none,
        panEnabled: _zoomed,
        child: SizedBox.expand(
          child: Center(
            child: Image.file(
              File(widget.filePath),
              cacheWidth: 1280,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 56,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Gagal memuat gambar',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool activePill;
  final bool loading;
  final VoidCallback onTap;

  const _ViewerActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
    this.activePill = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: activePill
            ? BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color.withValues(alpha: 0.5)),
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              SizedBox(
                width: 24,
                height: 24,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                ),
              )
            else
              Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnappyPhotoPagePhysics extends PageScrollPhysics {
  final double? Function()? dragStartPixelsProvider;

  const _SnappyPhotoPagePhysics({
    this.dragStartPixelsProvider,
    super.parent,
  });

  @override
  _SnappyPhotoPagePhysics applyTo(ScrollPhysics? ancestor) {
    return _SnappyPhotoPagePhysics(
      dragStartPixelsProvider: dragStartPixelsProvider,
      parent: buildParent(ancestor),
    );
  }

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 0.72,
        stiffness: 440.0,
        ratio: 1.0,
      );

  @override
  Tolerance toleranceFor(ScrollMetrics metrics) {
    return const Tolerance(
      distance: 1.0,
      time: 0.01,
      velocity: 25.0,
    );
  }

  @override
  double get minFlingDistance => 10.0;

  @override
  double get minFlingVelocity => 140.0;

  double _resolveTargetPixels(ScrollMetrics position, double velocity) {
    final viewport = position.viewportDimension;
    if (viewport <= 0) return position.pixels;
    final page = position.pixels / viewport;
    final maxPage = (position.maxScrollExtent / viewport).roundToDouble();
    final startPx = dragStartPixelsProvider?.call();
    final basePage = startPx != null
        ? (startPx / viewport).roundToDouble()
        : page.roundToDouble();
    final dragDelta = startPx != null
        ? (position.pixels - startPx) / viewport
        : (page - basePage);

    const double switchThreshold = 0.25;
    const double flickVelocity = 200.0;

    double targetPage;
    if (dragDelta.abs() >= 0.85) {
      if (velocity > flickVelocity) {
        targetPage = page.ceilToDouble();
      } else if (velocity < -flickVelocity) {
        targetPage = page.floorToDouble();
      } else {
        targetPage = page.roundToDouble();
      }
    } else if (velocity > flickVelocity) {
      targetPage = (dragDelta < -0.04) ? basePage : (basePage + 1.0);
    } else if (velocity < -flickVelocity) {
      targetPage = (dragDelta > 0.04) ? basePage : (basePage - 1.0);
    } else if (dragDelta >= switchThreshold) {
      targetPage = basePage + 1.0;
    } else if (dragDelta <= -switchThreshold) {
      targetPage = basePage - 1.0;
    } else {
      targetPage = page.roundToDouble();
    }

    return targetPage.clamp(0.0, maxPage) * viewport;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final target = _resolveTargetPixels(position, velocity);
    if ((target - position.pixels).abs() < tolerance.distance) {
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
