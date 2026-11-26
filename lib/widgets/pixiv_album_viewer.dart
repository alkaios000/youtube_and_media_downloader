import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../models/managed_file.dart';
import '../models/media_info.dart';
import '../services/download_manager.dart';
import 'file_gallery_viewer.dart';
import 'wallpaper_sheet.dart';

enum _AlbumReaderMode { pixivScroll, galleryGrid, rowList }

enum _PageMenuAction { view, setWallpaper, toggleLock, share, select, openExternal, info, delete }

class _PageHitMeta {
  final int index;
  const _PageHitMeta(this.index);
}

/// Effortless, buttery-smooth, critically-damped page physics (~120ms settle):
/// - Uses the exact drag-start pixel offset so touching mid-glide NEVER bounces
///   back accidentally.
/// - Requires only a tiny horizontal slide (~14% of screen width) or gentle flick
///   to switch to the adjacent album (instead of Flutter's default 50% drag).
/// - Critically-damped spring settles cleanly with zero sluggish tail so vertical
///   scrolling responds immediately after switching albums.
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
        mass: 0.50,
        stiffness: 680.0,
        ratio: 1.0,
      );

  @override
  Tolerance toleranceFor(ScrollMetrics metrics) {
    return const Tolerance(
      distance: 1.0,
      time: 0.01,
      velocity: 20.0,
    );
  }

  @override
  double get minFlingDistance => 4.0;

  @override
  double get minFlingVelocity => 45.0;

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

    // Super responsive: a gentle thumb flick (45 px/s) OR just ~8% drag (~30px)
    // immediately glides to the next/previous album!
    const double switchThreshold = 0.08;
    const double flickVelocity = 45.0;

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
  final int initialAlbumIndex;

  const PixivAlbumViewer({
    super.key,
    required this.manager,
    required this.platformFolder,
    required this.creatorFolder,
    required this.albumName,
    this.albumNames = const [],
    this.initialAlbumIndex = 0,
  });

  @override
  State<PixivAlbumViewer> createState() => _PixivAlbumViewerState();
}

class _PixivAlbumViewerState extends State<PixivAlbumViewer> {
  late final List<String> _albumOrder;
  late final PageController _pageController;
  late final ValueNotifier<int> _currentAlbumIndexNotifier;
  late int _currentAlbumIndex;
  double? _dragStartPixels;

  final Map<int, ScrollController> _scrollControllers = {};
  final Map<int, GlobalKey> _viewportKeys = {};

  // Memoized grouping cache so horizontal album slides do ZERO O(N) scan/sort!
  List<ManagedFile>? _cachedFilesRef;
  Map<String, List<ManagedFile>> _cachedAlbumsMap = const {};
  List<String> _cachedActiveAlbums = const [];

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

  @override
  void initState() {
    super.initState();
    _albumOrder = widget.albumNames.isNotEmpty
        ? List<String>.from(widget.albumNames)
        : <String>[widget.albumName];
    var idx = widget.initialAlbumIndex;
    if (idx < 0 || idx >= _albumOrder.length) {
      idx = _albumOrder.indexOf(widget.albumName);
      if (idx < 0) idx = 0;
    }
    _currentAlbumIndex = idx;
    _currentAlbumIndexNotifier = ValueNotifier<int>(idx);
    _pageController = PageController(initialPage: _currentAlbumIndex);
  }

  @override
  void dispose() {
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
    final allFiles = widget.manager.managedFiles;
    if (identical(_cachedFilesRef, allFiles)) {
      return _cachedAlbumsMap;
    }
    final grouped = <String, List<ManagedFile>>{};
    for (final f in allFiles) {
      if (f.platformFolder == widget.platformFolder &&
          f.creatorFolder == widget.creatorFolder) {
        grouped.putIfAbsent(f.effectiveAlbumName, () => []).add(f);
      }
    }
    for (final pages in grouped.values) {
      pages.sort((a, b) => naturalCompareFileNames(a.fileName, b.fileName));
    }
    _cachedFilesRef = allFiles;
    _cachedAlbumsMap = grouped;
    _cachedActiveAlbums = _albumOrder
        .where((name) => (grouped[name]?.isNotEmpty ?? false))
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

    return ListenableBuilder(
      listenable: widget.manager,
      builder: (context, _) {
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

        final currentAlbumName = activeAlbums.isNotEmpty
            ? activeAlbums[_currentAlbumIndex]
            : widget.albumName;
        final pages = activeAlbums.isNotEmpty
            ? (albumsMap[currentAlbumName] ?? const <ManagedFile>[])
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
                        final title = activeAlbums.isNotEmpty
                            ? activeAlbums[safeIdx]
                            : widget.albumName;
                        final albumPageCount = activeAlbums.isNotEmpty
                            ? (albumsMap[title]?.length ?? 0)
                            : 0;
                        final sub = hasMultipleAlbums
                            ? '${widget.creatorFolder} • ${safeIdx + 1}/${activeAlbums.length} • $albumPageCount hal'
                            : '${widget.creatorFolder} • $albumPageCount halaman';
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
                ? const Center(child: Text('Album kosong atau sudah dihapus.'))
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
                          // Respond from touchdown so quick thumb flicks have zero dead-zone lag!
                          dragStartBehavior: DragStartBehavior.down,
                          // Strictly do NOT pre-render offscreen neighbor albums so
                          // sliding stays buttery-smooth with minimal RAM & GPU load.
                          allowImplicitScrolling: false,
                          itemCount: activeAlbums.length,
                          physics: _isSelectionMode
                              ? const NeverScrollableScrollPhysics()
                              : _SnappyAlbumPagePhysics(
                                  dragStartPixelsProvider: () =>
                                      _dragStartPixels,
                                ),
                          onPageChanged: (newIndex) {
                            _stopAutoScroll();
                            _currentAlbumIndex = newIndex;
                            _dragStartIndex = null;
                            _dragLastIndex = null;
                            if (newIndex >= 0 && newIndex < activeAlbums.length) {
                              _currentPages =
                                  albumsMap[activeAlbums[newIndex]] ??
                                      const <ManagedFile>[];
                            }
                            // Update ONLY the AppBar title via ValueNotifier —
                            // ZERO setState rebuild of PageView mid-slide!
                            _currentAlbumIndexNotifier.value = newIndex;
                          },
                          itemBuilder: (context, albumIdx) {
                            final albumTitle = activeAlbums[albumIdx];
                            final albumPages =
                                albumsMap[albumTitle] ?? const <ManagedFile>[];
                            final privateCount =
                                albumPages.where((p) => p.isPrivate).length;
                            final publicCount =
                                albumPages.length - privateCount;

                            return RepaintBoundary(
                              key: ValueKey<String>(albumTitle),
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
                                  _buildPixivVerticalScrollSliver(albumPages)
                                else if (_mode == _AlbumReaderMode.galleryGrid)
                                  _buildGalleryGridSliver(albumPages)
                                else
                                  _buildRowListSliver(albumPages),
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
      },
    );
  }

  // ===========================================================================
  // VIEW 1: PIXIV VERTICAL SCROLL (Full-width page-by-page reading!)
  // ===========================================================================
  Widget _buildPixivVerticalScrollSliver(List<ManagedFile> pages) {
    final theme = Theme.of(context);
    final bottomPad = _isSelectionMode ? 104.0 : 32.0;
    final screenPxWidth =
        (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(540, 900);

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
                    } else if (page.mediaKind == MediaKind.video) {
                      widget.manager.openManagedFile(page);
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
                            ? Container(
                                height: 240,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      const Color(0xFF0096FA)
                                          .withValues(alpha: 0.35),
                                      const Color(0xFF0F172A),
                                    ],
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.play_circle_filled_rounded,
                                      size: 64,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(height: 10),
                                    const Text(
                                      'Animasi Ugoira (MP4)',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Ketuk untuk memutar • ${formatBytes(page.fileSize)}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : ConstrainedBox(
                                constraints:
                                    const BoxConstraints(minHeight: 180),
                                child: Image.file(
                                  File(page.savedPath),
                                  width: double.infinity,
                                  cacheWidth: screenPxWidth,
                                  filterQuality: FilterQuality.low,
                                  gaplessPlayback: true,
                                  fit: BoxFit.fitWidth,
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
  // VIEW 2: ALBUM GALLERY GRID (3 columns)
  // ===========================================================================
  Widget _buildGalleryGridSliver(List<ManagedFile> pages) {
    final theme = Theme.of(context);
    final bottomPad = _isSelectionMode ? 104.0 : 32.0;

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(10, 2, 10, bottomPad),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
          childAspectRatio: 0.88,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final page = pages[index];
            final isSelected = _selectedKeys.contains(page.uniqueKey);

            return MetaData(
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
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: EdgeInsets.all(isSelected ? 4 : 0),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    color: isSelected
                        ? theme.colorScheme.primary.withValues(alpha: 0.2)
                        : Colors.transparent,
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.35),
                      width: isSelected ? 2 : 0.8,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(isSelected ? 8 : 10),
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
                                cacheWidth: 320,
                                filterQuality: FilterQuality.low,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                  child: const Icon(Icons.image_outlined),
                                ),
                              ),
                        if (isSelected)
                          Container(
                            color:
                                theme.colorScheme.primary.withValues(alpha: 0.16),
                          ),
                        Positioned(
                          top: 4,
                          left: 4,
                          child: _PrivacyMiniBadge(
                            isPrivate: page.isPrivate,
                            iconOnly: true,
                          ),
                        ),
                        Positioned(
                          left: 4,
                          bottom: 4,
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
                        if (_isSelectionMode)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: _PageSelectCircle(selected: isSelected),
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
        ),
      ),
    );
  }

  // ===========================================================================
  // VIEW 3: ROW / LIST VIEW
  // ===========================================================================
  Widget _buildRowListSliver(List<ManagedFile> pages) {
    final theme = Theme.of(context);
    final bottomPad = _isSelectionMode ? 104.0 : 32.0;

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
    if (target != null && target.mediaKind == MediaKind.video) {
      await widget.manager.openManagedFile(target);
      return;
    }
    final imagesOnly = pages
        .where((p) => p.mediaKind == MediaKind.image)
        .toList(growable: false);
    if (imagesOnly.isEmpty) return;
    final imgIdx = target != null
        ? imagesOnly.indexWhere((p) => p.uniqueKey == target.uniqueKey)
        : 0;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileGalleryViewer(
          manager: widget.manager,
          images: imagesOnly,
          initialIndex: imgIdx >= 0 ? imgIdx : 0,
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          targets.length == 1 ? 'Hapus Foto?' : 'Hapus ${targets.length} Foto?',
        ),
        content: Text(
          targets.length == 1
              ? 'Hapus permanen "${targets.first.fileName}"?'
              : 'Hapus permanen ${targets.length} foto terpilih dari perangkat?',
        ),
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
    if (ok != true) return;
    final deleted = await widget.manager.deleteMultipleManagedFiles(targets);
    if (!mounted) return;
    if (_isSelectionMode) _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$deleted foto dihapus.')),
    );
  }

  void _showInfoSheet(ManagedFile f) {
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
              _DetailLine(label: 'Status', value: f.isPrivate ? 'Privat (Tersembunyi dari Galeri & WA)' : 'Terbuka (Muncul di Galeri & WA)'),
              _DetailLine(label: 'Album', value: f.effectiveAlbumName),
              _DetailLine(label: 'Nama', value: f.fileName),
              _DetailLine(label: 'Ukuran', value: formatBytes(f.fileSize)),
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
