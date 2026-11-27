import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../models/managed_file.dart';
import '../models/media_info.dart';
import '../models/media_metadata.dart';
import '../services/download_manager.dart';
import 'app_feedback.dart';
import 'file_gallery_viewer.dart';
import 'in_app_video_player.dart';
import 'sharp_original_image.dart';
import 'tag_albums_screen.dart';
import 'wallpaper_sheet.dart';

enum _AlbumReaderMode { pixivScroll, galleryGrid, rowList }

enum _PageMenuAction {
  view,
  setWallpaper,
  toggleLock,
  tagContent,
  share,
  select,
  openExternal,
  info,
  delete,
}

class _PageHitMeta {
  final int index;
  const _PageHitMeta(this.index);
}

/// Silky-smooth, critically-damped page physics matching [FileGalleryViewer]:
/// - Deliberate ~25% (1/4 screen) horizontal slide OR a gentle thumb flick
///   glides smoothly to the adjacent album.
/// - Cleanly settles without sluggish tail so vertical scrolling responds right away.
class _SnappyAlbumPagePhysics extends PageScrollPhysics {
  final double? Function()? dragStartPixelsProvider;

  const _SnappyAlbumPagePhysics({
    this.dragStartPixelsProvider,
    super.parent,
  });

  @override
  _SnappyAlbumPagePhysics applyTo(ScrollPhysics? ancestor) {
    return _SnappyAlbumPagePhysics(
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

    // 1/4 screen (25%) deliberate slide OR gentle flick (200 px/s) switches cleanly!
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

/// Dedicated Pixiv Album Reader opened when clicking a Pixiv artwork/album in File tab.
/// Supports horizontal sliding between adjacent albums of the same artist (Pixiv-like UX)
/// plus 3 vertical viewing modes inside each album:
/// 1) Pixiv Vertical Scroll (default — seamless full-width reading like Pixiv app)
/// 2) Album Grid (3-column gallery)
/// 3) Row List (detailed list)
/// Plus Private Vault Unlock (show in Gallery & WA) / Lock (hide back to Private),
/// Long-press & Drag-to-Select, per-photo 3-dot menu, Multi-Share, and Zoom Lightbox.
class PixivAlbumViewer extends StatefulWidget {
  final DownloadManager manager;
  final String platformFolder;
  final String creatorFolder;
  final String albumName;
  final List<String> albumNames;
  final List<AlbumTarget>? albumTargets;
  final int initialAlbumIndex;

  const PixivAlbumViewer({
    super.key,
    required this.manager,
    required this.platformFolder,
    required this.creatorFolder,
    required this.albumName,
    this.albumNames = const [],
    this.albumTargets,
    this.initialAlbumIndex = 0,
  });

  @override
  State<PixivAlbumViewer> createState() => _PixivAlbumViewerState();
}

class _PixivAlbumViewerState extends State<PixivAlbumViewer> {
  late final List<AlbumTarget> _albumOrder;
  late final Set<String> _allowedAlbumKeys;
  late final PageController _pageController;
  late final ValueNotifier<int> _currentAlbumIndexNotifier;
  late int _currentAlbumIndex;
  double? _dragStartPixels;

  final Map<int, ScrollController> _scrollControllers = {};
  final Map<int, GlobalKey> _viewportKeys = {};

  // Route-aware rebuild gating: 0% CPU while covered by FileGalleryViewer!
  bool _isRouteCurrent = true;
  bool _dirtyWhileHidden = false;

  // Memoized grouping cache so horizontal album slides do ZERO O(N) scan/sort!
  List<ManagedFile>? _cachedFilesRef;
  int _cachedRatingsRev = -1;
  int _cachedAlbumMetaRev = -1;
  Map<String, List<ManagedFile>> _cachedAlbumsMap = const {};
  List<AlbumTarget> _cachedActiveAlbums = const [];

  _AlbumReaderMode _mode = _AlbumReaderMode.pixivScroll;
  bool _isSelectionMode = false;
  bool _isBusy = false;
  final Set<String> _selectedKeys = <String>{};

  // Drag-select state
  int? _dragStartIndex;
  int? _dragLastIndex;
  bool _dragSelectMode = true;
  Set<String> _preDragKeys = <String>{};
  Offset? _lastDragGlobalPos;
  Timer? _autoScrollTimer;
  List<ManagedFile> _currentPages = const [];
  final Set<String> _probedDimensionPaths = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.albumTargets != null && widget.albumTargets!.isNotEmpty) {
      _albumOrder = List<AlbumTarget>.from(widget.albumTargets!);
    } else if (widget.albumNames.isNotEmpty) {
      _albumOrder = widget.albumNames
          .map(
            (name) => AlbumTarget(
              platformFolder: widget.platformFolder,
              creatorFolder: widget.creatorFolder,
              albumName: name,
            ),
          )
          .toList(growable: false);
    } else {
      _albumOrder = [
        AlbumTarget(
          platformFolder: widget.platformFolder,
          creatorFolder: widget.creatorFolder,
          albumName: widget.albumName,
        ),
      ];
    }
    _allowedAlbumKeys = _albumOrder.map((t) => t.lookupKey).toSet();

    var idx = widget.initialAlbumIndex;
    if (idx < 0 || idx >= _albumOrder.length) {
      final initialKey = AlbumMetadata.buildLookupKey(
        widget.platformFolder,
        widget.creatorFolder,
        widget.albumName,
      );
      idx = _albumOrder.indexWhere((t) => t.lookupKey == initialKey);
      if (idx < 0) idx = 0;
    }
    _currentAlbumIndex = idx;
    _currentAlbumIndexNotifier = ValueNotifier<int>(idx);
    _pageController = PageController(initialPage: _currentAlbumIndex);
    widget.manager.addListener(_onManagerUpdated);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    _isRouteCurrent = current;
    if (current && _dirtyWhileHidden) {
      _dirtyWhileHidden = false;
    }
  }

  /// Only rebuilds when visible files, photo ratings, or album tags change AND
  /// this viewer is the active route (skipping hidden rebuilds when covered by
  /// [FileGalleryViewer] during rapid Fast Delete or rating edits!).
  void _onManagerUpdated() {
    if (!mounted) return;
    final needsRebuild =
        !identical(_cachedFilesRef, widget.manager.visibleManagedFiles) ||
            _cachedRatingsRev != widget.manager.photoRatingsRevision ||
            _cachedAlbumMetaRev != widget.manager.albumMetadataRevision;
    if (!needsRebuild) return;
    if (!_isRouteCurrent) {
      _dirtyWhileHidden = true;
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerUpdated);
    _stopAutoScroll();
    _currentAlbumIndexNotifier.dispose();
    _pageController.dispose();
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    _scrollControllers.clear();
    super.dispose();
  }

  ScrollController _controllerFor(int albumIdx) =>
      _scrollControllers.putIfAbsent(albumIdx, ScrollController.new);

  GlobalKey _viewportKeyFor(int albumIdx) =>
      _viewportKeys.putIfAbsent(albumIdx, GlobalKey.new);

  Map<String, List<ManagedFile>> _resolveAllAlbumsMap() {
    final allFiles = widget.manager.visibleManagedFiles;
    _cachedRatingsRev = widget.manager.photoRatingsRevision;
    _cachedAlbumMetaRev = widget.manager.albumMetadataRevision;
    if (identical(_cachedFilesRef, allFiles)) {
      return _cachedAlbumsMap;
    }
    final grouped = <String, List<ManagedFile>>{};
    for (final f in allFiles) {
      final key = f.albumLookupKey;
      if (_allowedAlbumKeys.contains(key)) {
        grouped.putIfAbsent(key, () => []).add(f);
      }
    }
    for (final pages in grouped.values) {
      pages.sort((a, b) => naturalCompareFileNames(a.fileName, b.fileName));
    }
    _cachedFilesRef = allFiles;
    _cachedAlbumsMap = grouped;
    _cachedActiveAlbums = _albumOrder
        .where((target) => (grouped[target.lookupKey]?.isNotEmpty ?? false))
        .toList(growable: false);
    return grouped;
  }

  void _exitSelection() {
    _stopAutoScroll();
    setState(() {
      _isSelectionMode = false;
      _selectedKeys.clear();
      _dragStartIndex = null;
      _dragLastIndex = null;
    });
  }

  void _togglePage(ManagedFile page) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedKeys.contains(page.uniqueKey)) {
        _selectedKeys.remove(page.uniqueKey);
        if (_selectedKeys.isEmpty) _isSelectionMode = false;
      } else {
        _isSelectionMode = true;
        _selectedKeys.add(page.uniqueKey);
      }
    });
  }

  int? _hitTestIndex(Offset globalPos) {
    final key = _viewportKeys[_currentAlbumIndex];
    final obj = key?.currentContext?.findRenderObject();
    if (obj is! RenderBox) return null;
    final local = obj.globalToLocal(globalPos);
    final result = BoxHitTestResult();
    obj.hitTest(result, position: local);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is _PageHitMeta) {
        return (target.metaData as _PageHitMeta).index;
      }
    }
    return null;
  }

  void _onDragStart(LongPressStartDetails details) {
    if (_currentPages.isEmpty) return;
    final idx = _hitTestIndex(details.globalPosition);
    if (idx == null || idx < 0 || idx >= _currentPages.length) return;
    HapticFeedback.mediumImpact();
    final key = _currentPages[idx].uniqueKey;
    final already = _selectedKeys.contains(key);
    setState(() {
      _isSelectionMode = true;
      _dragStartIndex = idx;
      _dragLastIndex = idx;
      _dragSelectMode = !already;
      _preDragKeys = Set<String>.from(_selectedKeys);
      if (_dragSelectMode) {
        _selectedKeys.add(key);
      } else {
        _selectedKeys.remove(key);
      }
    });
    _lastDragGlobalPos = details.globalPosition;
  }

  void _onDragMove(LongPressMoveUpdateDetails details) {
    if (_dragStartIndex == null || _currentPages.isEmpty) return;
    _lastDragGlobalPos = details.globalPosition;
    _applyDrag(details.globalPosition);
    _updateAutoScroll(details.globalPosition);
  }

  void _onDragEnd(LongPressEndDetails details) {
    _stopAutoScroll();
    _dragStartIndex = null;
    _dragLastIndex = null;
    _lastDragGlobalPos = null;
    if (_selectedKeys.isEmpty && _isSelectionMode) {
      setState(() => _isSelectionMode = false);
    }
  }

  void _applyDrag(Offset globalPos) {
    final start = _dragStartIndex;
    if (start == null) return;
    final idx = _hitTestIndex(globalPos);
    if (idx == null || idx < 0 || idx >= _currentPages.length) return;
    if (idx == _dragLastIndex) return;

    _dragLastIndex = idx;
    HapticFeedback.selectionClick();

    final lo = math.min(start, idx);
    final hi = math.max(start, idx);
    final updated = Set<String>.from(_preDragKeys);
    for (int i = lo; i <= hi; i++) {
      final k = _currentPages[i].uniqueKey;
      if (_dragSelectMode) {
        updated.add(k);
      } else {
        updated.remove(k);
      }
    }
    setState(() {
      _selectedKeys
        ..clear()
        ..addAll(updated);
    });
  }

  void _updateAutoScroll(Offset globalPos) {
    final key = _viewportKeys[_currentAlbumIndex];
    final controller = _scrollControllers[_currentAlbumIndex];
    final obj = key?.currentContext?.findRenderObject();
    if (obj is! RenderBox || controller == null || !controller.hasClients) {
      _stopAutoScroll();
      return;
    }
    final local = obj.globalToLocal(globalPos);
    final height = obj.size.height;
    const edge = 76.0;
    double vel = 0;
    if (local.dy < edge) {
      vel = -15.0 * ((edge - local.dy) / edge).clamp(0.15, 1.0);
    } else if (local.dy > height - edge) {
      vel = 15.0 * ((local.dy - (height - edge)) / edge).clamp(0.15, 1.0);
    }
    if (vel == 0) {
      _stopAutoScroll();
      return;
    }
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final activeCtrl = _scrollControllers[_currentAlbumIndex];
      if (activeCtrl == null || !activeCtrl.hasClients || _dragStartIndex == null) {
        _stopAutoScroll();
        return;
      }
      final pos = activeCtrl.position;
      final next = (pos.pixels + vel).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if (next != pos.pixels) {
        activeCtrl.jumpTo(next);
        if (_lastDragGlobalPos != null) _applyDrag(_lastDragGlobalPos!);
      }
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final albumsMap = _resolveAllAlbumsMap();
    final activeAlbums = _cachedActiveAlbums;

    if (activeAlbums.isNotEmpty &&
        _currentAlbumIndex >= activeAlbums.length) {
      _currentAlbumIndex = activeAlbums.length - 1;
      _currentAlbumIndexNotifier.value = _currentAlbumIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(_currentAlbumIndex);
        }
      });
    }

    final currentTarget = activeAlbums.isNotEmpty
        ? activeAlbums[_currentAlbumIndex]
        : AlbumTarget(
            platformFolder: widget.platformFolder,
            creatorFolder: widget.creatorFolder,
            albumName: widget.albumName,
          );
    final pages = activeAlbums.isNotEmpty
        ? (albumsMap[currentTarget.lookupKey] ?? const <ManagedFile>[])
        : const <ManagedFile>[];
    _currentPages = pages;

    if (_selectedKeys.isNotEmpty) {
      final valid = pages.map((e) => e.uniqueKey).toSet();
      _selectedKeys.removeWhere((k) => !valid.contains(k));
      if (_selectedKeys.isEmpty && _isSelectionMode) {
        _isSelectionMode = false;
      }
    }

    final selectedPages = _isSelectionMode
        ? pages.where((p) => _selectedKeys.contains(p.uniqueKey)).toList()
        : const <ManagedFile>[];
    final allSelected =
        pages.isNotEmpty && selectedPages.length == pages.length;

    final hasMultipleAlbums = activeAlbums.length > 1;

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelectionMode) {
          _exitSelection();
        }
      },
      child: Scaffold(
        appBar: _isSelectionMode
            ? AppBar(
                leading: IconButton(
                  onPressed: _exitSelection,
                  icon: const Icon(Icons.close_rounded),
                ),
                title: Text(
                  '${selectedPages.length} dipilih',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                actions: [
                  TextButton.icon(
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        if (allSelected) {
                          _selectedKeys.clear();
                          _isSelectionMode = false;
                        } else {
                          _selectedKeys
                            ..clear()
                            ..addAll(pages.map((e) => e.uniqueKey));
                        }
                      });
                    },
                    icon: Icon(
                      allSelected
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                      size: 18,
                    ),
                    label: Text(allSelected ? 'Batal' : 'Semua'),
                  ),
                ],
              )
            : AppBar(
                title: ValueListenableBuilder<int>(
                  valueListenable: _currentAlbumIndexNotifier,
                  builder: (context, idx, _) {
                    final safeIdx = activeAlbums.isEmpty
                        ? 0
                        : idx.clamp(0, activeAlbums.length - 1);
                    final target = activeAlbums.isNotEmpty
                        ? activeAlbums[safeIdx]
                        : AlbumTarget(
                            platformFolder: widget.platformFolder,
                            creatorFolder: widget.creatorFolder,
                            albumName: widget.albumName,
                          );
                    final title = target.albumName;
                    final albumPageCount = activeAlbums.isNotEmpty
                        ? (albumsMap[target.lookupKey]?.length ?? 0)
                        : 0;
                    final sub = hasMultipleAlbums
                        ? '${target.creatorFolder} • ${safeIdx + 1}/${activeAlbums.length} • $albumPageCount hal'
                        : '${target.creatorFolder} • $albumPageCount halaman';
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                actions: [
                  if (activeAlbums.isNotEmpty)
                    IconButton(
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        setState(() => _isSelectionMode = true);
                      },
                      icon: const Icon(Icons.checklist_rounded),
                      tooltip: 'Pilih banyak',
                    ),
                ],
              ),
        body: activeAlbums.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    widget.manager.managedFiles.any((f) =>
                            f.platformFolder == widget.platformFolder &&
                            f.creatorFolder == widget.creatorFolder)
                        ? 'Foto disembunyikan oleh filter Visibilitas Konten.\nUbah di Pengaturan → Visibilitas Konten.'
                        : 'Album kosong atau sudah dihapus.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : Stack(
                children: [
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
                      // Strictly do NOT pre-render offscreen neighbor albums so
                      // sliding stays buttery-smooth with minimal RAM & GPU load.
                      allowImplicitScrolling: false,
                      itemCount: activeAlbums.length,
                      physics: _isSelectionMode
                          ? const NeverScrollableScrollPhysics()
                          : _SnappyAlbumPagePhysics(
                              dragStartPixelsProvider: () => _dragStartPixels,
                            ),
                      onPageChanged: (newIndex) {
                        _stopAutoScroll();
                        _currentAlbumIndex = newIndex;
                        _dragStartIndex = null;
                        _dragLastIndex = null;
                        if (newIndex >= 0 && newIndex < activeAlbums.length) {
                          _currentPages =
                              albumsMap[activeAlbums[newIndex].lookupKey] ??
                                  const <ManagedFile>[];
                        }
                        // Update ONLY the AppBar title via ValueNotifier —
                        // ZERO setState rebuild of PageView mid-slide!
                        _currentAlbumIndexNotifier.value = newIndex;
                      },
                      itemBuilder: (context, albumIdx) {
                        final target = activeAlbums[albumIdx];
                        final albumTitle = target.albumName;
                        final albumPages =
                            albumsMap[target.lookupKey] ?? const <ManagedFile>[];
                        final albumTags = widget.manager.getAlbumTags(
                          target.platformFolder,
                          target.creatorFolder,
                          albumTitle,
                        );
                        final privateCount =
                            albumPages.where((p) => p.isPrivate).length;
                        final publicCount = albumPages.length - privateCount;
                        final hasTagsFooter = albumTags.isNotEmpty;

                        return RepaintBoundary(
                          key: ValueKey<String>(target.lookupKey),
                          child: GestureDetector(
                            key: _viewportKeyFor(albumIdx),
                            behavior: HitTestBehavior.translucent,
                            onLongPressStart: _onDragStart,
                            onLongPressMoveUpdate: _onDragMove,
                            onLongPressEnd: _onDragEnd,
                            child: CustomScrollView(
                              controller: _controllerFor(albumIdx),
                              // Strict zero off-screen pre-render: photos not yet
                              // visible on screen are NOT rendered or decoded!
                              scrollCacheExtent:
                                  const ScrollCacheExtent.pixels(0),
                              slivers: [
                                // Privacy Status + 3-Mode Reader Switcher Banner
                                if (!_isSelectionMode)
                                  SliverToBoxAdapter(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        14,
                                        8,
                                        14,
                                        10,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          _AlbumPrivacyBanner(
                                            privateCount: privateCount,
                                            publicCount: publicCount,
                                            busy: _isBusy,
                                            onUnlockAll: privateCount > 0
                                                ? () => _unlockPages(
                                                      albumPages
                                                          .where((p) =>
                                                              p.isPrivate)
                                                          .toList(),
                                                    )
                                                : null,
                                            onLockAll: publicCount > 0
                                                ? () => _lockPages(
                                                      albumPages
                                                          .where((p) =>
                                                              !p.isPrivate)
                                                          .toList(),
                                                    )
                                                : null,
                                          ),
                                          const SizedBox(height: 10),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  hasMultipleAlbums
                                                      ? 'Geser kiri/kanan pindah album • Tahan pilih banyak'
                                                      : 'Tahan & geser untuk pilih banyak',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: theme
                                                      .textTheme.labelSmall
                                                      ?.copyWith(
                                                    color: theme.colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              _ReaderModeToggle(
                                                mode: _mode,
                                                onChanged: (m) =>
                                                    setState(() => _mode = m),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                if (_mode == _AlbumReaderMode.pixivScroll)
                                  _buildPixivVerticalScrollSliver(
                                    albumPages,
                                    hasFooterBelow: hasTagsFooter,
                                  )
                                else if (_mode == _AlbumReaderMode.galleryGrid)
                                  _buildGalleryGridSliver(
                                    albumPages,
                                    hasFooterBelow: hasTagsFooter,
                                  )
                                else
                                  _buildRowListSliver(
                                    albumPages,
                                    hasFooterBelow: hasTagsFooter,
                                  ),

                                // Per-album tags positioned BELOW the album when scrolled
                                if (hasTagsFooter)
                                  SliverToBoxAdapter(
                                    child: Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        12,
                                        14,
                                        12,
                                        _isSelectionMode ? 104 : 36,
                                      ),
                                      child: _AlbumTagsFooterSection(
                                        albumTitle: albumTitle,
                                        tags: albumTags,
                                        onTapTag: _openAlbumsWithTag,
                                        onLongPressTag: (tag) {
                                          Clipboard.setData(
                                            ClipboardData(text: tag),
                                          );
                                          showTopToast(
                                            context,
                                            'Tag "#$tag" disalin.',
                                            icon: Icons.copy_rounded,
                                          );
                                        },
                                        onCopyAllTags: () {
                                          Clipboard.setData(
                                            ClipboardData(
                                              text: albumTags
                                                  .map((t) => '#$t')
                                                  .join(' '),
                                            ),
                                          );
                                          showTopToast(
                                            context,
                                            'Semua tag album disalin.',
                                            icon: Icons.copy_rounded,
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  // Floating Multi-Select Batch Bar (Unlock, Lock, Share, Delete)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    left: 12,
                    right: 12,
                    bottom:
                        _isSelectionMode && selectedPages.isNotEmpty ? 14 : -110,
                    child: _AlbumBatchActionBar(
                      selectedPages: selectedPages,
                      busy: _isBusy,
                      onUnlock: () => _unlockPages(
                        selectedPages.where((p) => p.isPrivate).toList(),
                      ),
                      onLock: () => _lockPages(
                        selectedPages.where((p) => !p.isPrivate).toList(),
                      ),
                      onShare: () =>
                          widget.manager.shareMultipleManagedFiles(selectedPages),
                      onDelete: () => _confirmDeleteMany(selectedPages),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // ===========================================================================
  // VIEW 1: PIXIV VERTICAL SCROLL (Full-width page-by-page reading!)
  // ===========================================================================
  Widget _buildPixivVerticalScrollSliver(
    List<ManagedFile> pages, {
    bool hasFooterBelow = false,
  }) {
    final theme = Theme.of(context);
    final bottomPad = hasFooterBelow ? 8.0 : (_isSelectionMode ? 104.0 : 32.0);
    final mediaSize = MediaQuery.sizeOf(context);
    // Reserve ~65% of screen height before Photo #1 finishes decoding so
    // Flutter mounts STRICTLY 1 photo (not 4-5 undecoded 180px stubs!) on slide!
    final loadingPlaceholderHeight = (mediaSize.height * 0.65).clamp(380.0, 580.0);

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(0, 2, 0, bottomPad),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final page = pages[index];
            final isSelected = _selectedKeys.contains(page.uniqueKey);

            return Padding(
              padding: EdgeInsets.only(bottom: index == pages.length - 1 ? 0 : 8),
              child: MetaData(
                metaData: _PageHitMeta(index),
                behavior: HitTestBehavior.opaque,
                child: GestureDetector(
                  onTap: () {
                    if (_isSelectionMode) {
                      _togglePage(page);
                    } else {
                      _openFullscreenLightbox(pages, index);
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant
                                .withValues(alpha: 0.25),
                        width: isSelected ? 2.4 : 0.8,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        page.mediaKind == MediaKind.video
                            ? InAppVideoPlayer(
                                filePath: page.savedPath,
                                inlineLoop: true,
                                autoLoop: true,
                                onOpenExternal: () =>
                                    widget.manager.openManagedFile(page),
                              )
                            : SharpOriginalImage(
                                filePath: page.savedPath,
                                width: double.infinity,
                                fit: BoxFit.fitWidth,
                                originalUpgradeDelay:
                                    const Duration(milliseconds: 140),
                                maxOriginalDimension: 4096,
                                maxOriginalPixels: 18 * 1000 * 1000,
                                frameBuilder: (context, child, frame, wasSync) {
                                  if (wasSync || frame != null) {
                                    return child;
                                  }
                                  return Container(
                                    height: loadingPlaceholderHeight,
                                    width: double.infinity,
                                    color: theme
                                        .colorScheme.surfaceContainerHighest
                                        .withValues(alpha: 0.35),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Icons.image_outlined,
                                      size: 32,
                                      color: theme
                                          .colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.35),
                                    ),
                                  );
                                },
                                errorBuilder: (_, _, _) => Container(
                                  height: 220,
                                  color: theme
                                      .colorScheme.surfaceContainerHighest,
                                  alignment: Alignment.center,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                    size: 42,
                                  ),
                                ),
                              ),

                        if (isSelected)
                          Positioned.fill(
                            child: Container(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.18),
                            ),
                          ),

                        // Page Number + Privacy pill on top-left
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.68),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${index + 1} / ${pages.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _PrivacyMiniBadge(isPrivate: page.isPrivate),
                              if (widget.manager.getPhotoRating(page) !=
                                  ContentRating.normal) ...[
                                const SizedBox(width: 6),
                                ContentRatingBadge(
                                  rating: widget.manager.getPhotoRating(page),
                                ),
                              ],
                            ],
                          ),
                        ),

                        // Top-right: selection circle or 3-dot menu
                        if (_isSelectionMode)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _PageSelectCircle(selected: isSelected),
                          )
                        else
                          Positioned(
                            top: 6,
                            right: 6,
                            child: _PagePopupMenu(
                              isPrivate: page.isPrivate,
                              isImage: page.mediaKind == MediaKind.image,
                              overlay: true,
                              onSelected: (act) =>
                                  _handlePageAction(act, page, pages, index),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
          childCount: pages.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
        ),
      ),
    );
  }

  // ===========================================================================
  // VIEW 2: ALBUM MASONRY GRID (3 columns, original aspect ratio — ZERO crop!)
  // ===========================================================================
  void _ensureGridDimensionsResolved(List<ManagedFile> pages) {
    final pendingPaths = <String>[];
    for (final p in pages) {
      if (p.mediaKind != MediaKind.image || p.savedPath.isEmpty) continue;
      if (ImageDimensionCache.peekAspectRatio(p.savedPath) != null) continue;
      if (_probedDimensionPaths.add(p.savedPath)) {
        pendingPaths.add(p.savedPath);
      }
    }
    if (pendingPaths.isEmpty) return;

    Future<void>(() async {
      bool anyResolved = false;
      const batchSize = 8;
      for (int i = 0; i < pendingPaths.length; i += batchSize) {
        if (!mounted) return;
        final end = math.min(i + batchSize, pendingPaths.length);
        final chunk = pendingPaths.sublist(i, end);
        final results = await Future.wait(
          chunk.map(ImageDimensionCache.resolve),
        );
        if (results.any((r) => r != null)) {
          anyResolved = true;
        }
      }
      if (anyResolved && mounted) {
        setState(() {});
      }
    });
  }

  Widget _buildGalleryGridSliver(
    List<ManagedFile> pages, {
    bool hasFooterBelow = false,
  }) {
    final theme = Theme.of(context);
    final bottomPad = hasFooterBelow ? 8.0 : (_isSelectionMode ? 104.0 : 32.0);

    _ensureGridDimensionsResolved(pages);

    final aspectRatios = List<double>.generate(pages.length, (i) {
      final page = pages[i];
      if (page.mediaKind != MediaKind.image) return 0.85;
      return ImageDimensionCache.peekAspectRatio(page.savedPath) ?? 0.88;
    }, growable: false);

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(8, 2, 8, bottomPad),
      sliver: SliverGrid(
        gridDelegate: MasonrySliverGridDelegate(
          crossAxisCount: 3,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
          aspectRatios: aspectRatios,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final page = pages[index];
            final isSelected = _selectedKeys.contains(page.uniqueKey);

            return MetaData(
              metaData: _PageHitMeta(index),
              behavior: HitTestBehavior.opaque,
              child: GestureDetector(
                // Always open enlarged full-resolution preview on photo tap!
                // In selection mode, unchecking/checking is done strictly via the checklist circle.
                onTap: () => _openFullscreenLightbox(pages, index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.22),
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.35),
                      width: isSelected ? 2.2 : 0.8,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        page.mediaKind == MediaKind.video
                            ? Container(
                                color: const Color(0xFF0096FA)
                                    .withValues(alpha: 0.22),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.play_circle_filled_rounded,
                                      size: 34,
                                      color: Colors.white,
                                    ),
                                    SizedBox(height: 3),
                                    Text(
                                      'Ugoira',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Image.file(
                                File(page.savedPath),
                                cacheWidth: 420,
                                filterQuality: FilterQuality.medium,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) => Container(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                  child: const Icon(Icons.image_outlined),
                                ),
                              ),
                        if (isSelected)
                          IgnorePointer(
                            child: Container(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.16),
                            ),
                          ),
                        Positioned(
                          top: 4,
                          left: 4,
                          child: IgnorePointer(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _PrivacyMiniBadge(
                                  isPrivate: page.isPrivate,
                                  iconOnly: true,
                                ),
                                if (widget.manager.getPhotoRating(page) !=
                                    ContentRating.normal) ...[
                                  const SizedBox(width: 3),
                                  ContentRatingBadge(
                                    rating: widget.manager.getPhotoRating(page),
                                    compact: true,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 4,
                          bottom: 4,
                          child: IgnorePointer(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_isSelectionMode)
                          Positioned(
                            top: 0,
                            right: 0,
                            child: GestureDetector(
                              key: ValueKey<String>('grid_select_circle_$index'),
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _togglePage(page),
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(10, 4, 4, 10),
                                child: _PageSelectCircle(selected: isSelected),
                              ),
                            ),
                          )
                        else
                          Positioned(
                            top: 2,
                            right: 2,
                            child: _PagePopupMenu(
                              isPrivate: page.isPrivate,
                              isImage: page.mediaKind == MediaKind.image,
                              overlay: true,
                              onSelected: (act) =>
                                  _handlePageAction(act, page, pages, index),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
          childCount: pages.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
        ),
      ),
    );
  }

  // ===========================================================================
  // VIEW 3: ROW / LIST VIEW
  // ===========================================================================
  Widget _buildRowListSliver(
    List<ManagedFile> pages, {
    bool hasFooterBelow = false,
  }) {
    final theme = Theme.of(context);
    final bottomPad = hasFooterBelow ? 8.0 : (_isSelectionMode ? 104.0 : 32.0);

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(12, 2, 12, bottomPad),
      sliver: SliverList.separated(
        itemCount: pages.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final page = pages[index];
          final isSelected = _selectedKeys.contains(page.uniqueKey);

          return MetaData(
            metaData: _PageHitMeta(index),
            behavior: HitTestBehavior.opaque,
            child: Card(
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: isSelected ? 1.8 : 0,
                ),
              ),
              color: isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.1)
                  : null,
              child: InkWell(
                onTap: () {
                  if (_isSelectionMode) {
                    _togglePage(page);
                  } else {
                    _openFullscreenLightbox(pages, index);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                  child: Row(
                    children: [
                      if (_isSelectionMode) ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _PageSelectCircle(selected: isSelected),
                        ),
                      ],
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 56,
                          height: 56,
                          child: page.mediaKind == MediaKind.video
                              ? Container(
                                  color: const Color(0xFF0096FA)
                                      .withValues(alpha: 0.2),
                                  child: const Icon(
                                    Icons.play_circle_filled_rounded,
                                    color: Color(0xFF0096FA),
                                    size: 28,
                                  ),
                                )
                              : Image.file(
                                  File(page.savedPath),
                                  cacheWidth: 160,
                                  filterQuality: FilterQuality.low,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    color: theme
                                        .colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.image_outlined),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Hal ${index + 1}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _PrivacyMiniBadge(isPrivate: page.isPrivate),
                                if (widget.manager.getPhotoRating(page) !=
                                    ContentRating.normal) ...[
                                  const SizedBox(width: 6),
                                  ContentRatingBadge(
                                    rating: widget.manager.getPhotoRating(page),
                                    compact: true,
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              page.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${page.extension} • ${formatBytes(page.fileSize)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!_isSelectionMode)
                        _PagePopupMenu(
                          isPrivate: page.isPrivate,
                          isImage: page.mediaKind == MediaKind.image,
                          onSelected: (act) =>
                              _handlePageAction(act, page, pages, index),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // ACTIONS
  // ===========================================================================
  Future<void> _openFullscreenLightbox(List<ManagedFile> pages, int index) async {
    final target = (index >= 0 && index < pages.length) ? pages[index] : null;
    final viewable = pages
        .where((p) =>
            p.mediaKind == MediaKind.image || p.mediaKind == MediaKind.video)
        .toList(growable: false);
    if (viewable.isEmpty) {
      if (target != null) await widget.manager.openManagedFile(target);
      return;
    }
    final viewIdx = target != null
        ? viewable.indexWhere((p) => p.uniqueKey == target.uniqueKey)
        : 0;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileGalleryViewer(
          manager: widget.manager,
          images: viewable,
          initialIndex: viewIdx >= 0 ? viewIdx : 0,
        ),
      ),
    );
  }

  Future<void> _handlePageAction(
    _PageMenuAction action,
    ManagedFile page,
    List<ManagedFile> pages,
    int index,
  ) async {
    switch (action) {
      case _PageMenuAction.view:
        await _openFullscreenLightbox(pages, index);
        break;
      case _PageMenuAction.setWallpaper:
        await showSetWallpaperSheet(
          context,
          manager: widget.manager,
          file: page,
        );
        break;
      case _PageMenuAction.toggleLock:
        if (page.isPrivate) {
          await _unlockPages([page]);
        } else {
          await _lockPages([page]);
        }
        break;
      case _PageMenuAction.tagContent:
        await showPhotoContentRatingSheet(
          context,
          manager: widget.manager,
          file: page,
        );
        break;
      case _PageMenuAction.share:
        await widget.manager.shareManagedFile(page);
        break;
      case _PageMenuAction.select:
        HapticFeedback.mediumImpact();
        setState(() {
          _isSelectionMode = true;
          _selectedKeys.add(page.uniqueKey);
        });
        break;
      case _PageMenuAction.openExternal:
        await widget.manager.openManagedFile(page);
        break;
      case _PageMenuAction.info:
        _showInfoSheet(page);
        break;
      case _PageMenuAction.delete:
        await _confirmDeleteMany([page]);
        break;
    }
  }

  Future<void> _unlockPages(List<ManagedFile> targets) async {
    if (targets.isEmpty || _isBusy) return;
    setState(() => _isBusy = true);
    try {
      await widget.manager.unlockManagedFiles(targets);
      if (!mounted) return;
      if (_isSelectionMode) _exitSelection();
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _lockPages(List<ManagedFile> targets) async {
    if (targets.isEmpty || _isBusy) return;
    setState(() => _isBusy = true);
    try {
      await widget.manager.lockManagedFiles(targets);
      if (!mounted) return;
      if (_isSelectionMode) _exitSelection();
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _confirmDeleteMany(List<ManagedFile> targets) async {
    if (targets.isEmpty) return;
    final useTrash = widget.manager.settings.trashEnabled;
    final ok = await showBottomDeleteConfirm(
      context,
      title: useTrash
          ? (targets.length == 1
              ? 'Pindahkan ke Sampah?'
              : 'Pindahkan ${targets.length} Item ke Sampah?')
          : (targets.length == 1
              ? 'Hapus Foto?'
              : 'Hapus ${targets.length} Foto?'),
      message: useTrash
          ? (targets.length == 1
              ? 'Pindahkan "${targets.first.fileName}" ke Tempat Sampah?'
              : 'Pindahkan ${targets.length} item terpilih ke Tempat Sampah?')
          : (targets.length == 1
              ? 'Hapus permanen "${targets.first.fileName}"?'
              : 'Hapus permanen ${targets.length} foto terpilih dari perangkat?'),
      confirmLabel: useTrash ? 'Ke Sampah' : 'Hapus',
    );
    if (!ok) return;
    if (useTrash) {
      unawaited(_trashBatchWithUndo(targets));
    } else {
      unawaited(widget.manager.deleteMultipleManagedFiles(targets, permanent: true));
    }
    if (!mounted) return;
    if (_isSelectionMode) _exitSelection();
  }

  Future<void> _trashBatchWithUndo(List<ManagedFile> targets) async {
    final trashed = await widget.manager.moveManagedFilesToTrash(targets);
    if (trashed.isEmpty || !mounted) return;
    final ids = trashed.map((e) => e.id).toList(growable: false);
    showTopToast(
      context,
      ids.length == 1
          ? 'Dipindah ke Sampah'
          : '${ids.length} item dipindah ke Sampah',
      duration: const Duration(seconds: 3),
      icon: Icons.delete_outline_rounded,
      actionLabel: 'Urungkan',
      onAction: () => unawaited(widget.manager.restoreTrashItems(ids)),
    );
  }

  void _openAlbumsWithTag(String tag) {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TagAlbumsScreen(
          manager: widget.manager,
          tag: tag,
        ),
      ),
    );
  }

  void _showInfoSheet(ManagedFile f) {
    final rating = widget.manager.getPhotoRating(f);
    final albumTags = widget.manager.getAlbumTags(
      f.platformFolder,
      f.creatorFolder,
      f.effectiveAlbumName,
    );
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
                'Detail Foto',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 12),
              _DetailLine(
                label: 'Status',
                value: f.isPrivate
                    ? 'Privat (Tersembunyi dari Galeri & WA)'
                    : 'Terbuka (Muncul di Galeri & WA)',
              ),
              _DetailLine(label: 'Konten', value: rating.label),
              _DetailLine(label: 'Album', value: f.effectiveAlbumName),
              _DetailLine(label: 'Nama', value: f.fileName),
              _DetailLine(label: 'Ukuran', value: formatBytes(f.fileSize)),
              if (albumTags.isNotEmpty)
                _DetailLine(
                  label: 'Tag',
                  value: albumTags.map((t) => '#$t').join(' '),
                ),
              _DetailLine(label: 'Lokasi', value: f.savedPath),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SUB-WIDGETS
// =============================================================================

class _AlbumPrivacyBanner extends StatelessWidget {
  final int privateCount;
  final int publicCount;
  final bool busy;
  final VoidCallback? onUnlockAll;
  final VoidCallback? onLockAll;

  const _AlbumPrivacyBanner({
    required this.privateCount,
    required this.publicCount,
    required this.busy,
    this.onUnlockAll,
    this.onLockAll,
  });

  @override
  Widget build(BuildContext context) {
    final allPrivate = publicCount == 0;
    final allPublic = privateCount == 0;
    final accent = allPublic
        ? const Color(0xFF22C55E)
        : const Color(0xFFF59E0B);

    final statusMsg = allPrivate
        ? 'Mode Privat ($privateCount foto tersembunyi dari Galeri & WA)'
        : (allPublic
            ? 'Terbuka di Galeri & WA ($publicCount foto)'
            : '$privateCount Privat • $publicCount Terbuka di Galeri');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: accent.withValues(alpha: 0.42)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                allPublic ? Icons.lock_open_rounded : Icons.lock_rounded,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  statusMsg,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (onUnlockAll != null)
                FilledButton.icon(
                  onPressed: busy ? null : onUnlockAll,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.lock_open_rounded, size: 16),
                  label: Text(
                    allPrivate
                        ? 'Unlock ke Galeri & WA'
                        : 'Unlock Sisa ($privateCount)',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
              if (onLockAll != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : onLockAll,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.lock_outline_rounded, size: 16),
                  label: Text(
                    allPublic
                        ? 'Kunci Kembali ke Privat'
                        : 'Kunci ($publicCount)',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReaderModeToggle extends StatelessWidget {
  final _AlbumReaderMode mode;
  final ValueChanged<_AlbumReaderMode> onChanged;

  const _ReaderModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SegIconBtn(
            icon: Icons.view_day_rounded,
            tooltip: 'Scroll ala Pixiv',
            active: mode == _AlbumReaderMode.pixivScroll,
            onTap: () => onChanged(_AlbumReaderMode.pixivScroll),
          ),
          _SegIconBtn(
            icon: Icons.grid_view_rounded,
            tooltip: 'Mode Album / Galeri',
            active: mode == _AlbumReaderMode.galleryGrid,
            onTap: () => onChanged(_AlbumReaderMode.galleryGrid),
          ),
          _SegIconBtn(
            icon: Icons.view_agenda_rounded,
            tooltip: 'Mode Baris',
            active: mode == _AlbumReaderMode.rowList,
            onTap: () => onChanged(_AlbumReaderMode.rowList),
          ),
        ],
      ),
    );
  }
}

class _SegIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _SegIconBtn({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: active ? theme.colorScheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 17,
            color: active ? Colors.white : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _PrivacyMiniBadge extends StatelessWidget {
  final bool isPrivate;
  final bool iconOnly;

  const _PrivacyMiniBadge({required this.isPrivate, this.iconOnly = false});

  @override
  Widget build(BuildContext context) {
    final color = isPrivate ? const Color(0xFFF59E0B) : const Color(0xFF16A34A);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: iconOnly ? 4.5 : 6,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPrivate ? Icons.lock_rounded : Icons.lock_open_rounded,
            size: 11,
            color: Colors.white,
          ),
          if (!iconOnly) ...[
            const SizedBox(width: 3),
            Text(
              isPrivate ? 'Privat' : 'Galeri',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PageSelectCircle extends StatelessWidget {
  final bool selected;

  const _PageSelectCircle({required this.selected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.primary
            : Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.8),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
          : null,
    );
  }
}

class _PagePopupMenu extends StatelessWidget {
  final bool isPrivate;
  final bool isImage;
  final bool overlay;
  final ValueChanged<_PageMenuAction> onSelected;

  const _PagePopupMenu({
    required this.isPrivate,
    required this.onSelected,
    this.isImage = true,
    this.overlay = false,
  });

  @override
  Widget build(BuildContext context) {
    final err = Theme.of(context).colorScheme.error;
    return PopupMenuButton<_PageMenuAction>(
      onSelected: onSelected,
      padding: EdgeInsets.zero,
      tooltip: 'Opsi foto',
      child: overlay
          ? Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.56),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.more_vert_rounded,
                size: 16,
                color: Colors.white,
              ),
            )
          : const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.more_vert_rounded, size: 21),
            ),
      itemBuilder: (ctx) => [
        const PopupMenuItem(
          value: _PageMenuAction.view,
          child: Row(
            children: [
              Icon(Icons.zoom_in_rounded, size: 19),
              SizedBox(width: 10),
              Text('Lihat Penuh'),
            ],
          ),
        ),
        if (isImage)
          const PopupMenuItem(
            value: _PageMenuAction.setWallpaper,
            child: Row(
              children: [
                Icon(Icons.wallpaper_rounded, size: 19),
                SizedBox(width: 10),
                Text('Jadikan Wallpaper'),
              ],
            ),
          ),
        PopupMenuItem(
          value: _PageMenuAction.toggleLock,
          child: Row(
            children: [
              Icon(
                isPrivate ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                size: 19,
                color: isPrivate
                    ? const Color(0xFF16A34A)
                    : const Color(0xFFF59E0B),
              ),
              const SizedBox(width: 10),
              Text(isPrivate ? 'Unlock ke Galeri & WA' : 'Kunci ke Privat'),
            ],
          ),
        ),
        if (isImage)
          const PopupMenuItem(
            value: _PageMenuAction.tagContent,
            child: Row(
              children: [
                Icon(Icons.label_outline_rounded, size: 19),
                SizedBox(width: 10),
                Text('Tandai Konten (Biasa/Ecchi/NSFW)'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: _PageMenuAction.share,
          child: Row(
            children: [
              Icon(Icons.share_rounded, size: 19),
              SizedBox(width: 10),
              Text('Bagikan'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _PageMenuAction.select,
          child: Row(
            children: [
              Icon(Icons.check_circle_outline_rounded, size: 19),
              SizedBox(width: 10),
              Text('Pilih Banyak'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _PageMenuAction.openExternal,
          child: Row(
            children: [
              Icon(Icons.open_in_new_rounded, size: 19),
              SizedBox(width: 10),
              Text('Buka di App Lain'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _PageMenuAction.info,
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 19),
              SizedBox(width: 10),
              Text('Detail'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _PageMenuAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 19, color: err),
              const SizedBox(width: 10),
              Text('Hapus', style: TextStyle(color: err)),
            ],
          ),
        ),
      ],
    );
  }
}

class _AlbumBatchActionBar extends StatelessWidget {
  final List<ManagedFile> selectedPages;
  final bool busy;
  final VoidCallback onUnlock;
  final VoidCallback onLock;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  const _AlbumBatchActionBar({
    required this.selectedPages,
    required this.busy,
    required this.onUnlock,
    required this.onLock,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPrivate = selectedPages.any((p) => p.isPrivate);
    final hasPublic = selectedPages.any((p) => !p.isPrivate);

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(18),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            if (hasPrivate)
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : onUnlock,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.lock_open_rounded, size: 17),
                  label: const Text('Unlock', style: TextStyle(fontSize: 12.5)),
                ),
              ),
            if (hasPrivate && hasPublic) const SizedBox(width: 6),
            if (hasPublic)
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: busy ? null : onLock,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.lock_outline_rounded, size: 17),
                  label: const Text('Kunci', style: TextStyle(fontSize: 12.5)),
                ),
              ),
            const SizedBox(width: 6),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : onShare,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.share_rounded, size: 17),
                label: const Text('Share', style: TextStyle(fontSize: 12.5)),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filledTonal(
              onPressed: busy ? null : onDelete,
              style: IconButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                backgroundColor:
                    theme.colorScheme.error.withValues(alpha: 0.14),
              ),
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              tooltip: 'Hapus',
            ),
          ],
        ),
      ),
    );
  }
}

class _AlbumTagsFooterSection extends StatelessWidget {
  final String albumTitle;
  final List<String> tags;
  final ValueChanged<String> onTapTag;
  final ValueChanged<String> onLongPressTag;
  final VoidCallback onCopyAllTags;

  const _AlbumTagsFooterSection({
    required this.albumTitle,
    required this.tags,
    required this.onTapTag,
    required this.onLongPressTag,
    required this.onCopyAllTags,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Container(
      key: const ValueKey<String>('album_tags_footer'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tag_rounded, size: 17, color: accent),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tag Album (${tags.length})',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Ketuk tag untuk melihat semua album bertag sama',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onCopyAllTags,
                icon: const Icon(Icons.copy_rounded, size: 18),
                tooltip: 'Salin semua tag',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final tag in tags) _buildTagChip(context, tag),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTagChip(BuildContext context, String tag) {
    final theme = Theme.of(context);
    final isR18 = tag.toLowerCase().contains('r-18');
    final chipColor =
        isR18 ? const Color(0xFFEF4444) : theme.colorScheme.onSurface;
    return Material(
      color: isR18
          ? const Color(0xFFEF4444).withValues(alpha: 0.14)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () => onTapTag(tag),
        onLongPress: () => onLongPressTag(tag),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isR18
                  ? const Color(0xFFEF4444).withValues(alpha: 0.45)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Text(
            '#$tag',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: chipColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Pure-Flutter virtualized Masonry / Waterfall [SliverGridDelegate] that preserves
/// each photo's exact original aspect ratio (`width / height`, zero cropping!) while
/// packing every item into the shortest column so columns interlock tightly and fit.
class MasonrySliverGridDelegate extends SliverGridDelegate {
  final int crossAxisCount;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final List<double> aspectRatios;

  const MasonrySliverGridDelegate({
    required this.crossAxisCount,
    required this.aspectRatios,
    this.mainAxisSpacing = 6.0,
    this.crossAxisSpacing = 6.0,
  }) : assert(crossAxisCount > 0);

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final usableCrossAxis = math.max(
      0.0,
      constraints.crossAxisExtent - crossAxisSpacing * (crossAxisCount - 1),
    );
    final columnWidth = usableCrossAxis / crossAxisCount;
    return _MasonrySliverGridLayout(
      crossAxisCount: crossAxisCount,
      columnWidth: columnWidth,
      mainAxisSpacing: mainAxisSpacing,
      crossAxisSpacing: crossAxisSpacing,
      aspectRatios: aspectRatios,
    );
  }

  @override
  bool shouldRelayout(covariant MasonrySliverGridDelegate oldDelegate) {
    if (oldDelegate.crossAxisCount != crossAxisCount ||
        oldDelegate.mainAxisSpacing != mainAxisSpacing ||
        oldDelegate.crossAxisSpacing != crossAxisSpacing ||
        oldDelegate.aspectRatios.length != aspectRatios.length) {
      return true;
    }
    for (int i = 0; i < aspectRatios.length; i++) {
      if ((oldDelegate.aspectRatios[i] - aspectRatios[i]).abs() > 0.001) {
        return true;
      }
    }
    return false;
  }
}

class _MasonrySliverGridLayout extends SliverGridLayout {
  final int crossAxisCount;
  final double columnWidth;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final List<double> _tops;
  final List<double> _bottoms;
  final List<double> _extents;
  final List<double> _crossOffsets;
  final double _maxExtent;

  _MasonrySliverGridLayout({
    required this.crossAxisCount,
    required this.columnWidth,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
    required List<double> aspectRatios,
  })  : _tops = List<double>.filled(aspectRatios.length, 0.0),
        _bottoms = List<double>.filled(aspectRatios.length, 0.0),
        _extents = List<double>.filled(aspectRatios.length, 0.0),
        _crossOffsets = List<double>.filled(aspectRatios.length, 0.0),
        _maxExtent = _computePlacement(
          crossAxisCount: crossAxisCount,
          columnWidth: columnWidth,
          mainAxisSpacing: mainAxisSpacing,
          crossAxisSpacing: crossAxisSpacing,
          aspectRatios: aspectRatios,
        ) {
    final colHeights = List<double>.filled(crossAxisCount, 0.0);
    for (int i = 0; i < aspectRatios.length; i++) {
      int bestCol = 0;
      double minH = colHeights[0];
      for (int c = 1; c < crossAxisCount; c++) {
        if (colHeights[c] < minH - 0.5) {
          minH = colHeights[c];
          bestCol = c;
        }
      }
      final ratio = aspectRatios[i].clamp(0.22, 3.5);
      final itemHeight = columnWidth <= 0
          ? 0.0
          : (columnWidth / ratio).clamp(42.0, columnWidth * 4.5);
      final top = colHeights[bestCol];
      final bottom = top + itemHeight;
      _tops[i] = top;
      _bottoms[i] = bottom;
      _extents[i] = itemHeight;
      _crossOffsets[i] = bestCol * (columnWidth + crossAxisSpacing);
      colHeights[bestCol] = bottom + mainAxisSpacing;
    }
  }

  static double _computePlacement({
    required int crossAxisCount,
    required double columnWidth,
    required double mainAxisSpacing,
    required double crossAxisSpacing,
    required List<double> aspectRatios,
  }) {
    if (aspectRatios.isEmpty || columnWidth <= 0) return 0.0;
    final colHeights = List<double>.filled(crossAxisCount, 0.0);
    for (int i = 0; i < aspectRatios.length; i++) {
      int bestCol = 0;
      double minH = colHeights[0];
      for (int c = 1; c < crossAxisCount; c++) {
        if (colHeights[c] < minH - 0.5) {
          minH = colHeights[c];
          bestCol = c;
        }
      }
      final ratio = aspectRatios[i].clamp(0.22, 3.5);
      final itemHeight = (columnWidth / ratio).clamp(42.0, columnWidth * 4.5);
      colHeights[bestCol] = colHeights[bestCol] + itemHeight + mainAxisSpacing;
    }
    double maxH = 0.0;
    for (final h in colHeights) {
      final net = h > 0 ? (h - mainAxisSpacing) : 0.0;
      if (net > maxH) maxH = net;
    }
    return maxH;
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    if (_tops.isEmpty || scrollOffset <= 0) return 0;
    for (int i = 0; i < _bottoms.length; i++) {
      if (_bottoms[i] >= scrollOffset) return i;
    }
    return _tops.length;
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (_tops.isEmpty) return 0;
    int maxIdx = 0;
    for (int i = 0; i < _tops.length; i++) {
      if (_tops[i] <= scrollOffset) {
        maxIdx = i;
      }
    }
    return maxIdx;
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    if (index >= 0 && index < _tops.length) {
      return SliverGridGeometry(
        scrollOffset: _tops[index],
        crossAxisOffset: _crossOffsets[index],
        mainAxisExtent: _extents[index],
        crossAxisExtent: columnWidth,
      );
    }
    final col = index % crossAxisCount;
    final row = index ~/ crossAxisCount;
    final fallbackExtent = columnWidth > 0 ? columnWidth : 100.0;
    return SliverGridGeometry(
      scrollOffset: row * (fallbackExtent + mainAxisSpacing),
      crossAxisOffset: col * (columnWidth + crossAxisSpacing),
      mainAxisExtent: fallbackExtent,
      crossAxisExtent: columnWidth,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) {
    if (childCount <= 0 || _tops.isEmpty) return 0.0;
    if (childCount == _tops.length) return _maxExtent;
    final limit = math.min(childCount, _bottoms.length);
    double maxH = 0.0;
    for (int i = 0; i < limit; i++) {
      if (_bottoms[i] > maxH) maxH = _bottoms[i];
    }
    return maxH;
  }
}

class _DetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _DetailLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
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
