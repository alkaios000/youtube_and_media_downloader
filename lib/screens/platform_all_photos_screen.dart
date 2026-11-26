import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../models/managed_file.dart';
import '../models/media_info.dart';
import '../models/media_platform.dart';
import '../services/download_manager.dart';
import '../widgets/file_gallery_viewer.dart';

/// Displays ALL photos across EVERY artist/creator in [platformFolder],
/// shuffled by default, with pull-to-refresh + instant reshuffle button and
/// full-screen snappy horizontal slide viewing.
class PlatformAllPhotosScreen extends StatefulWidget {
  final DownloadManager manager;
  final String platformFolder;

  const PlatformAllPhotosScreen({
    super.key,
    required this.manager,
    required this.platformFolder,
  });

  @override
  State<PlatformAllPhotosScreen> createState() =>
      _PlatformAllPhotosScreenState();
}

class _PlatformAllPhotosScreenState extends State<PlatformAllPhotosScreen> {
  final ScrollController _scrollController = ScrollController();

  bool _shuffleEnabled = true;
  int _shuffleSeed = DateTime.now().microsecondsSinceEpoch;

  // Memoized photo list so scrolling never reshuffles or re-scans
  List<ManagedFile>? _cachedSourceRef;
  bool? _cachedShuffleEnabled;
  int? _cachedSeed;
  List<ManagedFile> _cachedPhotos = const [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<ManagedFile> _resolvePhotos(List<ManagedFile> allFiles) {
    if (identical(_cachedSourceRef, allFiles) &&
        _cachedShuffleEnabled == _shuffleEnabled &&
        _cachedSeed == _shuffleSeed) {
      return _cachedPhotos;
    }
    final photos = <ManagedFile>[];
    for (final f in allFiles) {
      if (f.platformFolder == widget.platformFolder &&
          f.mediaKind == MediaKind.image &&
          f.savedPath.isNotEmpty) {
        photos.add(f);
      }
    }
    if (_shuffleEnabled && photos.length > 1) {
      photos.shuffle(math.Random(_shuffleSeed));
    }
    _cachedSourceRef = allFiles;
    _cachedShuffleEnabled = _shuffleEnabled;
    _cachedSeed = _shuffleSeed;
    _cachedPhotos = photos;
    return photos;
  }

  void _scrollToTop({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    if (_scrollController.offset <= 0) return;
    if (animate) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(0);
    }
  }

  void _reshuffleOnly() {
    HapticFeedback.selectionClick();
    setState(() {
      _shuffleEnabled = true;
      _shuffleSeed = DateTime.now().microsecondsSinceEpoch;
    });
    _scrollToTop(animate: true);
  }

  Future<void> _refreshAndReshuffle() async {
    HapticFeedback.selectionClick();
    await widget.manager.refreshManagedFiles();
    if (!mounted) return;
    setState(() {
      if (_shuffleEnabled) {
        _shuffleSeed = DateTime.now().microsecondsSinceEpoch;
      }
    });
    _scrollToTop(animate: true);
  }

  void _toggleShuffle() {
    HapticFeedback.selectionClick();
    setState(() {
      _shuffleEnabled = !_shuffleEnabled;
      if (_shuffleEnabled) {
        _shuffleSeed = DateTime.now().microsecondsSinceEpoch;
      }
    });
    _scrollToTop(animate: true);
  }

  void _openSlideViewer(List<ManagedFile> photos, int initialIndex) {
    if (photos.isEmpty) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FileGalleryViewer(
          manager: widget.manager,
          images: photos,
          initialIndex: initialIndex,
          enableShuffleRefresh: true,
          showCreatorInSubtitle: true,
          onShuffleRefresh: () {
            if (mounted) {
              setState(() {
                _shuffleEnabled = true;
                _shuffleSeed = DateTime.now().microsecondsSinceEpoch;
              });
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final platform = MediaPlatformMeta.fromKey(widget.platformFolder);

    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.manager,
          builder: (context, _) {
            final photos = _resolvePhotos(widget.manager.managedFiles);

            return RefreshIndicator(
              onRefresh: _refreshAndReshuffle,
              child: CustomScrollView(
                controller: _scrollController,
                scrollCacheExtent: const ScrollCacheExtent.pixels(360),
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverAppBar(
                    floating: true,
                    title: Text('Semua Foto • ${widget.platformFolder}'),
                    actions: [
                      if (photos.isNotEmpty)
                        IconButton(
                          onPressed: () => _openSlideViewer(photos, 0),
                          icon: const Icon(Icons.view_carousel_rounded),
                          tooltip: 'Mode Slide',
                        ),
                      IconButton(
                        onPressed: _refreshAndReshuffle,
                        icon: const Icon(Icons.refresh_rounded),
                        tooltip: 'Segarkan & acak ulang',
                      ),
                    ],
                  ),
                  if (photos.isNotEmpty)
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _StickyAllPhotosBarDelegate(
                        backgroundColor: theme.scaffoldBackgroundColor,
                        brandColor: platform.brandColor,
                        totalPhotos: photos.length,
                        shuffleEnabled: _shuffleEnabled,
                        onToggleShuffle: _toggleShuffle,
                        onReshuffle: _reshuffleOnly,
                        onStartSlide: () => _openSlideViewer(photos, 0),
                      ),
                    ),
                  if (photos.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.photo_library_outlined,
                                size: 54,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Belum ada foto di ${widget.platformFolder}',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 28),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                          childAspectRatio: 0.84,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final photo = photos[index];
                            return GestureDetector(
                              key: ValueKey<String>(photo.uniqueKey),
                              onTap: () => _openSlideViewer(photos, index),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.file(
                                      File(photo.savedPath),
                                      cacheWidth: 260,
                                      filterQuality: FilterQuality.low,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                        color: theme.colorScheme
                                            .surfaceContainerHighest,
                                        child: const Icon(
                                          Icons.broken_image_outlined,
                                          size: 26,
                                        ),
                                      ),
                                    ),
                                    if (photo.isPrivate)
                                      Positioned(
                                        top: 5,
                                        left: 5,
                                        child: Container(
                                          padding: const EdgeInsets.all(3.5),
                                          decoration: BoxDecoration(
                                            color: Colors.black
                                                .withValues(alpha: 0.58),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: const Icon(
                                            Icons.lock_rounded,
                                            size: 11,
                                            color: Color(0xFFFBBF24),
                                          ),
                                        ),
                                      ),
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        padding: const EdgeInsets.fromLTRB(
                                          6,
                                          14,
                                          6,
                                          4,
                                        ),
                                        decoration: const BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: [
                                              Color(0xC8000000),
                                              Colors.transparent,
                                            ],
                                          ),
                                        ),
                                        child: Text(
                                          photo.creatorFolder,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                          childCount: photos.length,
                          addAutomaticKeepAlives: false,
                          addRepaintBoundaries: true,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StickyAllPhotosBarDelegate extends SliverPersistentHeaderDelegate {
  final Color backgroundColor;
  final Color brandColor;
  final int totalPhotos;
  final bool shuffleEnabled;
  final VoidCallback onToggleShuffle;
  final VoidCallback onReshuffle;
  final VoidCallback onStartSlide;

  const _StickyAllPhotosBarDelegate({
    required this.backgroundColor,
    required this.brandColor,
    required this.totalPhotos,
    required this.shuffleEnabled,
    required this.onToggleShuffle,
    required this.onReshuffle,
    required this.onStartSlide,
  });

  @override
  double get minExtent => 52;

  @override
  double get maxExtent => 52;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    return Material(
      color: backgroundColor,
      elevation: overlapsContent ? 2 : 0,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        decoration: overlapsContent
            ? BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.35),
                  ),
                ),
              )
            : null,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilterChip(
                      avatar: Icon(
                        Icons.shuffle_rounded,
                        size: 16,
                        color: shuffleEnabled ? brandColor : null,
                      ),
                      label: Text(shuffleEnabled ? 'Acak Aktif' : 'Terbaru'),
                      selected: shuffleEnabled,
                      showCheckmark: false,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => onToggleShuffle(),
                    ),
                    const SizedBox(width: 8),
                    ActionChip(
                      avatar: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Acak Lagi'),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onPressed: onReshuffle,
                    ),
                    const SizedBox(width: 8),
                    ActionChip(
                      avatar: const Icon(Icons.view_carousel_rounded, size: 16),
                      label: const Text('Slide'),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onPressed: onStartSlide,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$totalPhotos foto',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickyAllPhotosBarDelegate oldDelegate) {
    return backgroundColor != oldDelegate.backgroundColor ||
        brandColor != oldDelegate.brandColor ||
        totalPhotos != oldDelegate.totalPhotos ||
        shuffleEnabled != oldDelegate.shuffleEnabled;
  }
}
