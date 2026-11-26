import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../models/creator_profile.dart';
import '../models/managed_file.dart';
import '../models/media_info.dart';
import '../models/media_metadata.dart';
import '../models/media_platform.dart';
import '../services/download_manager.dart';
import '../widgets/file_gallery_viewer.dart';
import '../widgets/pixiv_album_viewer.dart';
import '../widgets/wallpaper_sheet.dart';
import 'platform_all_photos_screen.dart';

enum _FileViewMode { gallery, list }

enum _CreatorSortMode {
  newest,
  sizeDesc,
  sizeAsc,
  photosDesc,
  albumsDesc,
  nameAsc,
}

enum _FileMenuAction {
  view,
  setWallpaper,
  toggleLock,
  tagContent,
  openExternal,
  share,
  select,
  info,
  delete,
}

enum _AlbumMenuAction { open, info, unlock, lock, share, select, delete }

class _SelectableIndexMeta {
  final int index;
  const _SelectableIndexMeta(this.index);
}

class _PixivAlbumGroup {
  final String albumName;
  final List<ManagedFile> pages;

  const _PixivAlbumGroup({
    required this.albumName,
    required this.pages,
  });

  ManagedFile get cover => pages.first;
  int get totalBytes => pages.fold<int>(0, (s, f) => s + f.fileSize);
  int get privateCount => pages.where((f) => f.isPrivate).length;
  int get publicCount => pages.length - privateCount;
  bool get hasPrivate => privateCount > 0;
  bool get hasPublic => publicCount > 0;
  DateTime get latestModified => pages
      .map((e) => e.modifiedAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);
}

/// Dedicated "File" explorer tab:
/// Level 0: Platform folders (Pixiv, YouTube, TikTok, Instagram, Facebook, Douyin, X)
/// Level 1: Creator / Username folders inside the selected platform
/// Level 2:
///   - For **Pixiv**: Per-Album / Per-Halaman view (Album Grid / Row) with Private Vault
///     status (`Privat` default — hidden from Gallery & WA until Unlocked!), click any album
///     to open [PixivAlbumViewer] (Pixiv Vertical Scroll / Album Grid / Row), plus multi-select
///     drag on albums for batch Unlock, Lock, Share, & Delete!
///   - For **Other Platforms**: Gallery Grid (3-column) & Row List with Long-Press &
///     Drag-to-Select, per-file 3-dot menu, Multi-Share, Unlock/Lock, and Photo Viewer.
class FilesScreen extends StatefulWidget {
  final DownloadManager manager;
  final ValueChanged<String>? onOpenProfileUrl;

  const FilesScreen({
    super.key,
    required this.manager,
    this.onOpenProfileUrl,
  });

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final GlobalKey _viewportKey = GlobalKey();

  String? _selectedPlatformFolder;
  String? _selectedCreatorFolder;
  String _searchQuery = '';
  _FileViewMode _viewMode = _FileViewMode.gallery;
  _CreatorSortMode _creatorSortMode = _CreatorSortMode.newest;
  bool _pixivShowAllPhotos = false;
  bool _shuffleEnabled = false;
  int _shuffleSeed = 0;

  // Multi-select & Drag-select state (works for both Pixiv albums & loose files!)
  bool _isSelectionMode = false;
  bool _isBusy = false;
  final Set<String> _selectedKeys = <String>{};
  int? _dragStartIndex;
  int? _dragLastIndex;
  bool _dragSelectMode = true;
  Set<String> _preDragSelectedKeys = <String>{};
  Offset? _lastDragGlobalPos;
  Timer? _autoScrollTimer;
  List<String> _activeSelectableKeys = const [];

  @override
  void dispose() {
    _stopAutoScroll();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    _searchQuery = '';
  }

  bool get _isPixivPlatform =>
      MediaPlatformMeta.fromKey(_selectedPlatformFolder) == MediaPlatform.pixiv;

  void _exitSelectionMode() {
    _stopAutoScroll();
    setState(() {
      _isSelectionMode = false;
      _selectedKeys.clear();
      _dragStartIndex = null;
      _dragLastIndex = null;
    });
  }

  void _enterSelectionWithKey(String key) {
    HapticFeedback.mediumImpact();
    setState(() {
      _isSelectionMode = true;
      _selectedKeys.add(key);
    });
  }

  void _toggleSelectionKey(String key) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedKeys.contains(key)) {
        _selectedKeys.remove(key);
        if (_selectedKeys.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _isSelectionMode = true;
        _selectedKeys.add(key);
      }
    });
  }

  void _goBackOneLevel() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_isSelectionMode) {
      _exitSelectionMode();
      return;
    }
    setState(() {
      _clearSearch();
      _pixivShowAllPhotos = false;
      _shuffleEnabled = false;
      if (_selectedCreatorFolder != null) {
        _selectedCreatorFolder = null;
      } else if (_selectedPlatformFolder != null) {
        _selectedPlatformFolder = null;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Long-Press + Drag-to-Select Hit Testing & Auto-Scroll
  // ---------------------------------------------------------------------------
  int? _hitTestIndex(Offset globalPosition) {
    final renderObj = _viewportKey.currentContext?.findRenderObject();
    if (renderObj is! RenderBox) return null;
    final localPos = renderObj.globalToLocal(globalPosition);
    final result = BoxHitTestResult();
    renderObj.hitTest(result, position: localPos);

    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is _SelectableIndexMeta) {
        return (target.metaData as _SelectableIndexMeta).index;
      }
    }
    return null;
  }

  void _onDragSelectStart(LongPressStartDetails details) {
    if (_selectedCreatorFolder == null || _activeSelectableKeys.isEmpty) return;
    final hitIdx = _hitTestIndex(details.globalPosition);
    if (hitIdx == null || hitIdx < 0 || hitIdx >= _activeSelectableKeys.length) {
      return;
    }

    HapticFeedback.mediumImpact();
    final key = _activeSelectableKeys[hitIdx];
    final alreadySelected = _selectedKeys.contains(key);

    setState(() {
      _isSelectionMode = true;
      _dragStartIndex = hitIdx;
      _dragLastIndex = hitIdx;
      _dragSelectMode = !alreadySelected;
      _preDragSelectedKeys = Set<String>.from(_selectedKeys);
      if (_dragSelectMode) {
        _selectedKeys.add(key);
      } else {
        _selectedKeys.remove(key);
      }
    });
    _lastDragGlobalPos = details.globalPosition;
  }

  void _onDragSelectMove(LongPressMoveUpdateDetails details) {
    if (_dragStartIndex == null || _activeSelectableKeys.isEmpty) return;
    _lastDragGlobalPos = details.globalPosition;
    _applyDragAtGlobalPosition(details.globalPosition);
    _updateAutoScroll(details.globalPosition);
  }

  void _onDragSelectEnd(LongPressEndDetails details) {
    _stopAutoScroll();
    _dragStartIndex = null;
    _dragLastIndex = null;
    _lastDragGlobalPos = null;
    if (_selectedKeys.isEmpty && _isSelectionMode) {
      setState(() => _isSelectionMode = false);
    }
  }

  void _applyDragAtGlobalPosition(Offset globalPos) {
    final startIdx = _dragStartIndex;
    if (startIdx == null) return;
    final hitIdx = _hitTestIndex(globalPos);
    if (hitIdx == null || hitIdx < 0 || hitIdx >= _activeSelectableKeys.length) {
      return;
    }
    if (hitIdx == _dragLastIndex) return;

    _dragLastIndex = hitIdx;
    HapticFeedback.selectionClick();

    final lo = math.min(startIdx, hitIdx);
    final hi = math.max(startIdx, hitIdx);
    final updated = Set<String>.from(_preDragSelectedKeys);
    for (int i = lo; i <= hi; i++) {
      final k = _activeSelectableKeys[i];
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
    final renderObj = _viewportKey.currentContext?.findRenderObject();
    if (renderObj is! RenderBox || !_scrollController.hasClients) {
      _stopAutoScroll();
      return;
    }
    final localPos = renderObj.globalToLocal(globalPos);
    final height = renderObj.size.height;
    const edgeZone = 76.0;

    double velocity = 0;
    if (localPos.dy < edgeZone) {
      final factor = ((edgeZone - localPos.dy) / edgeZone).clamp(0.15, 1.0);
      velocity = -14.0 * factor;
    } else if (localPos.dy > height - edgeZone) {
      final factor =
          ((localPos.dy - (height - edgeZone)) / edgeZone).clamp(0.15, 1.0);
      velocity = 14.0 * factor;
    }

    if (velocity == 0) {
      _stopAutoScroll();
      return;
    }

    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_scrollController.hasClients || _dragStartIndex == null) {
        _stopAutoScroll();
        return;
      }
      final pos = _scrollController.position;
      final target =
          (pos.pixels + velocity).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if (target != pos.pixels) {
        _scrollController.jumpTo(target);
        if (_lastDragGlobalPos != null) {
          _applyDragAtGlobalPosition(_lastDragGlobalPos!);
        }
      }
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  // Memoized grouping caches so search/selection/scroll do zero redundant O(N log N) work
  List<ManagedFile>? _cachedFilesRef;
  Map<String, Map<String, List<ManagedFile>>> _cachedByPlatform = const {};
  List<ManagedFile>? _cachedAlbumsSourceRef;
  List<_PixivAlbumGroup> _cachedPixivAlbums = const [];

  Map<String, Map<String, List<ManagedFile>>> _getByPlatform(
    List<ManagedFile> allFiles,
  ) {
    if (identical(_cachedFilesRef, allFiles)) {
      return _cachedByPlatform;
    }
    final byPlatform = <String, Map<String, List<ManagedFile>>>{};
    for (final file in allFiles) {
      final platMap = byPlatform.putIfAbsent(file.platformFolder, () => {});
      platMap.putIfAbsent(file.creatorFolder, () => []).add(file);
    }
    _cachedFilesRef = allFiles;
    _cachedByPlatform = byPlatform;
    _cachedAlbumsSourceRef = null;
    return byPlatform;
  }

  List<_PixivAlbumGroup> _groupIntoPixivAlbums(List<ManagedFile> files) {
    if (identical(_cachedAlbumsSourceRef, files)) {
      return _cachedPixivAlbums;
    }
    final byAlbum = <String, List<ManagedFile>>{};
    for (final f in files) {
      byAlbum.putIfAbsent(f.effectiveAlbumName, () => []).add(f);
    }
    final groups = <_PixivAlbumGroup>[];
    byAlbum.forEach((albumName, pages) {
      pages.sort((a, b) => naturalCompareFileNames(a.fileName, b.fileName));
      groups.add(_PixivAlbumGroup(albumName: albumName, pages: pages));
    });
    groups.sort((a, b) => b.latestModified.compareTo(a.latestModified));
    _cachedAlbumsSourceRef = files;
    _cachedPixivAlbums = groups;
    return groups;
  }

  List<T> _applyShuffle<T>(List<T> input) {
    if (!_shuffleEnabled || input.length <= 1) return input;
    final copy = List<T>.from(input);
    copy.shuffle(math.Random(_shuffleSeed));
    return copy;
  }

  void _toggleShuffle() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_shuffleEnabled) {
        _shuffleEnabled = false;
      } else {
        _shuffleEnabled = true;
        _shuffleSeed = DateTime.now().microsecondsSinceEpoch;
      }
    });
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

  void _reshuffle() {
    HapticFeedback.selectionClick();
    setState(() {
      _shuffleEnabled = true;
      _shuffleSeed = DateTime.now().microsecondsSinceEpoch;
    });
    _scrollToTop(animate: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allFiles = widget.manager.visibleManagedFiles;
    final allHiddenByFilter =
        allFiles.isEmpty && widget.manager.managedFiles.isNotEmpty;

    // Group: platform -> creator -> files (memoized by reference!)
    final byPlatform = _getByPlatform(allFiles);

    // Reset stale navigation if folder became empty/deleted
    if (_selectedPlatformFolder != null &&
        !byPlatform.containsKey(_selectedPlatformFolder)) {
      _selectedPlatformFolder = null;
      _selectedCreatorFolder = null;
      _pixivShowAllPhotos = false;
      _shuffleEnabled = false;
      _isSelectionMode = false;
      _selectedKeys.clear();
    } else if (_selectedPlatformFolder != null &&
        _selectedCreatorFolder != null &&
        !(byPlatform[_selectedPlatformFolder]
                ?.containsKey(_selectedCreatorFolder) ??
            false)) {
      _selectedCreatorFolder = null;
      _pixivShowAllPhotos = false;
      _shuffleEnabled = false;
      _isSelectionMode = false;
      _selectedKeys.clear();
    }

    final inCreatorFolder =
        _selectedPlatformFolder != null && _selectedCreatorFolder != null;
    final folderFiles = inCreatorFolder
        ? (byPlatform[_selectedPlatformFolder!]?[_selectedCreatorFolder!] ??
            const <ManagedFile>[])
        : const <ManagedFile>[];

    final isPixivArtist = inCreatorFolder && _isPixivPlatform;
    final isPixivAlbumView = isPixivArtist && !_pixivShowAllPhotos;

    final allPixivAlbums = isPixivArtist
        ? _groupIntoPixivAlbums(folderFiles)
        : const <_PixivAlbumGroup>[];
    final pixivAlbums = isPixivAlbumView
        ? _applyShuffle(allPixivAlbums)
        : const <_PixivAlbumGroup>[];

    final visibleFolderFiles =
        !isPixivAlbumView ? _applyShuffle(folderFiles) : folderFiles;

    _activeSelectableKeys = isPixivAlbumView
        ? pixivAlbums.map((a) => a.albumName).toList(growable: false)
        : visibleFolderFiles.map((f) => f.uniqueKey).toList(growable: false);

    // Prune stale selected keys
    if (_selectedKeys.isNotEmpty && inCreatorFolder) {
      final validSet = _activeSelectableKeys.toSet();
      _selectedKeys.removeWhere((k) => !validSet.contains(k));
      if (_selectedKeys.isEmpty && _isSelectionMode) {
        _isSelectionMode = false;
      }
    }

    // Resolve actual ManagedFiles covered by current selection (for Share / Unlock / Lock / Delete)
    final selectedActualFiles = <ManagedFile>[];
    if (_isSelectionMode) {
      if (isPixivAlbumView) {
        for (final album in pixivAlbums) {
          if (_selectedKeys.contains(album.albumName)) {
            selectedActualFiles.addAll(album.pages);
          }
        }
      } else {
        for (final f in folderFiles) {
          if (_selectedKeys.contains(f.uniqueKey)) {
            selectedActualFiles.add(f);
          }
        }
      }
    }

    final selectedUnitCount = _selectedKeys.length;
    final allUnitsSelected = inCreatorFolder &&
        _activeSelectableKeys.isNotEmpty &&
        selectedUnitCount == _activeSelectableKeys.length;

    final canPopFolder = _isSelectionMode ||
        _selectedPlatformFolder != null ||
        _selectedCreatorFolder != null;

    return PopScope(
      canPop: !canPopFolder,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && canPopFolder) {
          _goBackOneLevel();
        }
      },
      child: Stack(
        children: [
          GestureDetector(
            key: _viewportKey,
            behavior: HitTestBehavior.translucent,
            onLongPressStart: inCreatorFolder ? _onDragSelectStart : null,
            onLongPressMoveUpdate: inCreatorFolder ? _onDragSelectMove : null,
            onLongPressEnd: inCreatorFolder ? _onDragSelectEnd : null,
            child: RefreshIndicator(
              onRefresh: widget.manager.refreshManagedFiles,
              child: CustomScrollView(
                controller: _scrollController,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  _buildAppBar(
                    context,
                    inCreatorFolder: inCreatorFolder,
                    isPixivAlbumView: isPixivAlbumView,
                    canPopFolder: canPopFolder,
                    selectedUnitCount: selectedUnitCount,
                    allSelected: allUnitsSelected,
                    hasItems: _activeSelectableKeys.isNotEmpty,
                  ),

                  // Interactive Breadcrumb + Artist-Only Search Bar
                  if (!_isSelectionMode)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          inCreatorFolder ? 4 : 10,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  _BreadcrumbChip(
                                    label: 'File',
                                    active: _selectedPlatformFolder == null,
                                    onTap: () {
                                      FocusManager.instance.primaryFocus
                                          ?.unfocus();
                                      setState(() {
                                        _selectedPlatformFolder = null;
                                        _selectedCreatorFolder = null;
                                        _pixivShowAllPhotos = false;
                                        _shuffleEnabled = false;
                                        _clearSearch();
                                        _isSelectionMode = false;
                                        _selectedKeys.clear();
                                      });
                                    },
                                  ),
                                  if (_selectedPlatformFolder != null) ...[
                                    const Icon(Icons.chevron_right_rounded,
                                        size: 18),
                                    _BreadcrumbChip(
                                      label: _selectedPlatformFolder!,
                                      active: _selectedCreatorFolder == null,
                                      onTap: () {
                                        FocusManager.instance.primaryFocus
                                            ?.unfocus();
                                        setState(() {
                                          _selectedCreatorFolder = null;
                                          _pixivShowAllPhotos = false;
                                          _shuffleEnabled = false;
                                          _clearSearch();
                                          _isSelectionMode = false;
                                          _selectedKeys.clear();
                                        });
                                      },
                                    ),
                                  ],
                                  if (_selectedCreatorFolder != null) ...[
                                    const Icon(Icons.chevron_right_rounded,
                                        size: 18),
                                    _BreadcrumbChip(
                                      label: _selectedCreatorFolder!,
                                      active: true,
                                      onTap: () {},
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (_selectedPlatformFolder != null &&
                                _selectedCreatorFolder == null) ...[
                              const SizedBox(height: 10),
                              TextField(
                                controller: _searchController,
                                onChanged: (v) =>
                                    setState(() => _searchQuery = v),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: _isPixivPlatform
                                      ? 'Cari artist Pixiv...'
                                      : 'Cari kreator $_selectedPlatformFolder...',
                                  prefixIcon:
                                      const Icon(Icons.search_rounded, size: 20),
                                  suffixIcon: _searchQuery.isNotEmpty
                                      ? IconButton(
                                          onPressed: () =>
                                              setState(_clearSearch),
                                          icon: const Icon(Icons.close_rounded,
                                              size: 18),
                                          tooltip: 'Hapus pencarian',
                                        )
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    _buildCreatorSortChip(
                                      mode: _CreatorSortMode.newest,
                                      icon: Icons.schedule_rounded,
                                      label: 'Terbaru',
                                    ),
                                    const SizedBox(width: 6),
                                    _buildCreatorSortChip(
                                      mode: _CreatorSortMode.sizeDesc,
                                      icon: Icons.arrow_downward_rounded,
                                      label: 'Terbesar',
                                    ),
                                    const SizedBox(width: 6),
                                    _buildCreatorSortChip(
                                      mode: _CreatorSortMode.sizeAsc,
                                      icon: Icons.arrow_upward_rounded,
                                      label: 'Terkecil',
                                    ),
                                    const SizedBox(width: 6),
                                    _buildCreatorSortChip(
                                      mode: _CreatorSortMode.photosDesc,
                                      icon: Icons.photo_library_outlined,
                                      label: _isPixivPlatform
                                          ? 'Foto Terbanyak'
                                          : 'File Terbanyak',
                                    ),
                                    if (_isPixivPlatform) ...[
                                      const SizedBox(width: 6),
                                      _buildCreatorSortChip(
                                        mode: _CreatorSortMode.albumsDesc,
                                        icon: Icons.collections_bookmark_outlined,
                                        label: 'Album Terbanyak',
                                      ),
                                    ],
                                    const SizedBox(width: 6),
                                    _buildCreatorSortChip(
                                      mode: _CreatorSortMode.nameAsc,
                                      icon: Icons.sort_by_alpha_rounded,
                                      label: 'A–Z',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                  // Sticky Album / Photo Toolbar (pinned at top while scrolling)
                  if (!_isSelectionMode &&
                      inCreatorFolder &&
                      folderFiles.isNotEmpty)
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _StickyAlbumToolbarDelegate(
                        backgroundColor: theme.scaffoldBackgroundColor,
                        isPixivArtist: isPixivArtist,
                        albumCount: allPixivAlbums.length,
                        photoCount: folderFiles.length,
                        showAllPhotos: _pixivShowAllPhotos,
                        shuffleEnabled: _shuffleEnabled,
                        viewMode: _viewMode,
                        onSelectAlbums: () {
                          if (!_pixivShowAllPhotos) {
                            _scrollToTop(animate: true);
                            return;
                          }
                          setState(() {
                            _pixivShowAllPhotos = false;
                            _isSelectionMode = false;
                            _selectedKeys.clear();
                          });
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _scrollToTop(animate: false);
                          });
                        },
                        onSelectAllPhotos: () {
                          if (_pixivShowAllPhotos) {
                            _scrollToTop(animate: true);
                            return;
                          }
                          setState(() {
                            _pixivShowAllPhotos = true;
                            _isSelectionMode = false;
                            _selectedKeys.clear();
                          });
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _scrollToTop(animate: false);
                          });
                        },
                        onToggleShuffle: _toggleShuffle,
                        onReshuffle: _reshuffle,
                        onViewModeChanged: (m) =>
                            setState(() => _viewMode = m),
                      ),
                    ),

                  if (widget.manager.isLoadingFiles && allFiles.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (allFiles.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                allHiddenByFilter
                                    ? Icons.visibility_off_outlined
                                    : Icons.folder_copy_outlined,
                                size: 56,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                allHiddenByFilter
                                    ? 'Semua file disembunyikan oleh filter'
                                    : 'Belum ada folder file',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                allHiddenByFilter
                                    ? 'Buka Pengaturan → Visibilitas Konten untuk mencentang kategori Biasa, Ecchi, atau NSFW yang ingin ditampilkan.'
                                    : 'Media yang diunduh otomatis dipisahkan berdasarkan Aplikasi & Username. Foto Pixiv disimpan secara Privat hingga Anda Unlock.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else if (_selectedPlatformFolder == null)
                    _buildPlatformFoldersSliver(byPlatform)
                  else if (_selectedCreatorFolder == null) ...[
                    _buildAllPlatformPhotosMenuSliver(
                      context,
                      _selectedPlatformFolder!,
                      byPlatform[_selectedPlatformFolder!] ?? const {},
                    ),
                    _buildCreatorFoldersSliver(
                      _selectedPlatformFolder!,
                      byPlatform[_selectedPlatformFolder!] ?? const {},
                    ),
                  ]
                  else if (isPixivAlbumView)
                    (pixivAlbums.isEmpty
                        ? _buildEmptySearchSliver(context, 'Album tidak ditemukan')
                        : (_viewMode == _FileViewMode.gallery
                            ? _buildPixivAlbumsGridSliver(pixivAlbums)
                            : _buildPixivAlbumsRowSliver(pixivAlbums)))
                  else if (visibleFolderFiles.isEmpty)
                    _buildEmptySearchSliver(context, 'File tidak ditemukan')
                  else if (_viewMode == _FileViewMode.gallery)
                    _buildFilesGallerySliver(visibleFolderFiles)
                  else
                    _buildFilesRowSliver(visibleFolderFiles),
                ],
              ),
            ),
          ),

          // Floating Multi-Select Batch Action Bar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: 12,
            right: 12,
            bottom: _isSelectionMode && selectedActualFiles.isNotEmpty
                ? 14
                : -110,
            child: _SelectionBatchBar(
              selectedUnitCount: selectedUnitCount,
              selectedFiles: selectedActualFiles,
              busy: _isBusy,
              onUnlock: () => _unlockFiles(
                selectedActualFiles.where((f) => f.isPrivate).toList(),
              ),
              onLock: () => _lockFiles(
                selectedActualFiles.where((f) => !f.isPrivate).toList(),
              ),
              onShare: () => _shareSelectedFiles(selectedActualFiles),
              onDelete: () => _confirmDeleteMultiple(
                selectedActualFiles,
                unitLabel: isPixivAlbumView
                    ? '$selectedUnitCount album (${selectedActualFiles.length} foto)'
                    : '${selectedActualFiles.length} file',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(
    BuildContext context, {
    required bool inCreatorFolder,
    required bool isPixivAlbumView,
    required bool canPopFolder,
    required int selectedUnitCount,
    required bool allSelected,
    required bool hasItems,
  }) {
    if (_isSelectionMode) {
      return SliverAppBar(
        pinned: true,
        leading: IconButton(
          onPressed: _exitSelectionMode,
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Batal pilih',
        ),
        title: Text(
          isPixivAlbumView
              ? '$selectedUnitCount album dipilih'
              : '$selectedUnitCount dipilih',
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
                    ..addAll(_activeSelectableKeys);
                }
              });
            },
            icon: Icon(
              allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
              size: 18,
            ),
            label: Text(allSelected ? 'Batal Semua' : 'Semua'),
          ),
          const SizedBox(width: 4),
        ],
      );
    }

    return SliverAppBar(
      floating: true,
      leading: canPopFolder
          ? IconButton(
              onPressed: _goBackOneLevel,
              icon: const Icon(Icons.arrow_back_rounded),
            )
          : null,
      title: Text(
        _selectedCreatorFolder ?? _selectedPlatformFolder ?? 'File Unduhan',
      ),
      actions: [
        if (inCreatorFolder && hasItems)
          IconButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              setState(() => _isSelectionMode = true);
            },
            icon: const Icon(Icons.checklist_rounded),
            tooltip: 'Pilih banyak',
          ),
        IconButton(
          onPressed: widget.manager.refreshManagedFiles,
          icon: const Icon(Icons.refresh_rounded),
          tooltip: 'Segarkan folder',
        ),
      ],
    );
  }

  // ===========================================================================
  // LEVEL 0: Folders by App / Platform
  // ===========================================================================
  Widget _buildPlatformFoldersSliver(
    Map<String, Map<String, List<ManagedFile>>> byPlatform,
  ) {
    final platformNames = byPlatform.keys.toList()..sort();

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.2,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final name = platformNames[index];
            final creators = byPlatform[name]!;
            final allPlatFiles = creators.values.expand((e) => e).toList();
            final privateCount = allPlatFiles.where((f) => f.isPrivate).length;
            final platform = MediaPlatformMeta.fromKey(name);

            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => setState(() {
                  _clearSearch();
                  _selectedPlatformFolder = name;
                }),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: platform.gradientColors,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              platform.icon,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                          const Spacer(),
                          if (privateCount > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF59E0B)
                                    .withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.lock_rounded,
                                    size: 12,
                                    color: Color(0xFFF59E0B),
                                  ),
                                  SizedBox(width: 3),
                                  Text(
                                    'Privat',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFFF59E0B),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            Icon(
                              Icons.folder_rounded,
                              color: platform.brandColor.withValues(alpha: 0.7),
                              size: 22,
                            ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${creators.length} akun • ${allPlatFiles.length} file',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
          childCount: platformNames.length,
        ),
      ),
    );
  }

  // ===========================================================================
  // LEVEL 1 TOP MENU: "Semua Foto" (All photos across all artists, shuffled & slideable!)
  // ===========================================================================
  Widget _buildAllPlatformPhotosMenuSliver(
    BuildContext context,
    String platformFolder,
    Map<String, List<ManagedFile>> byCreator,
  ) {
    final allPhotos = <ManagedFile>[];
    for (final list in byCreator.values) {
      for (final f in list) {
        if (f.mediaKind == MediaKind.image && f.savedPath.isNotEmpty) {
          allPhotos.add(f);
        }
      }
    }
    if (allPhotos.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final theme = Theme.of(context);
    final platform = MediaPlatformMeta.fromKey(platformFolder);
    final isPixiv = platform == MediaPlatform.pixiv;
    final sample = allPhotos.first;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Card(
          clipBehavior: Clip.antiAlias,
          color: platform.brandColor.withValues(alpha: 0.10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: platform.brandColor.withValues(alpha: 0.32),
            ),
          ),
          child: InkWell(
            onTap: () {
              FocusManager.instance.primaryFocus?.unfocus();
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => PlatformAllPhotosScreen(
                    manager: widget.manager,
                    platformFolder: platformFolder,
                  ),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(sample.savedPath),
                            cacheWidth: 160,
                            filterQuality: FilterQuality.low,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: platform.gradientColors,
                                ),
                              ),
                              child: const Icon(
                                Icons.photo_library_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                          Container(
                            color: Colors.black.withValues(alpha: 0.28),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.shuffle_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Semua Foto',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${allPhotos.length} foto • ${byCreator.length} ${isPixiv ? 'artist' : 'kreator'} • Acak & slide',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: platform.brandColor,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCreatorSortChip({
    required _CreatorSortMode mode,
    required IconData icon,
    required String label,
  }) {
    final selected = _creatorSortMode == mode;
    return ChoiceChip(
      avatar: Icon(icon, size: 15),
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      onSelected: (_) {
        if (_creatorSortMode == mode) return;
        HapticFeedback.selectionClick();
        setState(() => _creatorSortMode = mode);
      },
    );
  }

  // ===========================================================================
  // LEVEL 1: Folders by Username / Creator inside Platform
  // ===========================================================================
  Widget _buildCreatorFoldersSliver(
    String platformFolder,
    Map<String, List<ManagedFile>> byCreator,
  ) {
    final q = _searchQuery.trim().toLowerCase();
    final platform = MediaPlatformMeta.fromKey(platformFolder);
    final isPixiv = platform == MediaPlatform.pixiv;
    final effectiveSort = (!isPixiv && _creatorSortMode == _CreatorSortMode.albumsDesc)
        ? _CreatorSortMode.photosDesc
        : _creatorSortMode;

    final entries = <_CreatorEntry>[];
    for (final entry in byCreator.entries) {
      final creator = entry.key;
      if (q.isNotEmpty && !creator.toLowerCase().contains(q)) continue;
      final files = entry.value;
      var totalSize = 0;
      var photoCount = 0;
      var privateCount = 0;
      ManagedFile? sampleImage;
      DateTime latestMod = files.first.modifiedAt;
      final albumNames = isPixiv ? <String>{} : null;

      for (final f in files) {
        totalSize += f.fileSize;
        if (f.mediaKind == MediaKind.image) {
          photoCount++;
          if (sampleImage == null && f.savedPath.isNotEmpty) {
            sampleImage = f;
          }
        }
        if (f.isPrivate) privateCount++;
        if (f.modifiedAt.isAfter(latestMod)) latestMod = f.modifiedAt;
        albumNames?.add(f.effectiveAlbumName);
      }

      entries.add(
        _CreatorEntry(
          name: creator,
          files: files,
          totalSize: totalSize,
          photoCount: photoCount,
          privateCount: privateCount,
          albumCount: albumNames?.length ?? 0,
          latestModified: latestMod,
          sampleImage: sampleImage,
        ),
      );
    }

    entries.sort((a, b) {
      final primary = switch (effectiveSort) {
        _CreatorSortMode.newest => b.latestModified.compareTo(a.latestModified),
        _CreatorSortMode.sizeDesc => b.totalSize.compareTo(a.totalSize),
        _CreatorSortMode.sizeAsc => a.totalSize.compareTo(b.totalSize),
        _CreatorSortMode.photosDesc => isPixiv
            ? b.photoCount.compareTo(a.photoCount)
            : b.files.length.compareTo(a.files.length),
        _CreatorSortMode.albumsDesc => b.albumCount.compareTo(a.albumCount),
        _CreatorSortMode.nameAsc =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      if (primary != 0) return primary;
      final bySize = b.totalSize.compareTo(a.totalSize);
      if (bySize != 0) return bySize;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    if (entries.isEmpty) {
      return _buildEmptySearchSliver(
        context,
        isPixiv ? 'Artist Pixiv tidak ditemukan' : 'Kreator tidak ditemukan',
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      sliver: SliverList.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = entries[index];
          final creator = item.name;
          final files = item.files;
          final totalSize = item.totalSize;
          final privateCount = item.privateCount;
          final albumCount = item.albumCount;
          final sampleImage = item.sampleImage;

          final subLine = isPixiv
              ? '$albumCount album • ${files.length} foto • ${formatBytes(totalSize)}'
              : '${files.length} file • ${formatBytes(totalSize)}';
          final savedProfile =
              widget.manager.getCreatorProfile(platformFolder, creator);

          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: sampleImage != null
                      ? Image.file(
                          File(sampleImage.savedPath),
                          cacheWidth: 160,
                          filterQuality: FilterQuality.low,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _creatorIconBox(platform),
                        )
                      : _creatorIconBox(platform),
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      creator,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (privateCount > 0) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.lock_rounded,
                      size: 14,
                      color: Color(0xFFF59E0B),
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                savedProfile != null ? '$subLine • Link tersimpan' : subLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (savedProfile != null)
                    IconButton(
                      onPressed: () => widget.onOpenProfileUrl
                          ?.call(savedProfile.profileUrl),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.cloud_download_outlined,
                        size: 20,
                        color: platform.brandColor,
                      ),
                      tooltip: 'Lanjut Unduh karya baru',
                    ),
                  IconButton(
                    onPressed: () => _openEditCreatorLinkDialog(
                      platform,
                      creator,
                      savedProfile,
                    ),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      savedProfile != null
                          ? Icons.link_rounded
                          : Icons.add_link_rounded,
                      size: 19,
                      color: savedProfile != null
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    tooltip: savedProfile != null
                        ? 'Edit link profil'
                        : 'Simpan link profil',
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 20),
                ],
              ),
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() {
                  _clearSearch();
                  _pixivShowAllPhotos = false;
                  _shuffleEnabled = false;
                  _selectedCreatorFolder = creator;
                });
              },
              onLongPress: () {
                FocusManager.instance.primaryFocus?.unfocus();
                HapticFeedback.mediumImpact();
                _showCreatorInfoSheet(
                  platform: platform,
                  creatorName: creator,
                  files: files,
                  savedProfile: savedProfile,
                  sampleImage: sampleImage,
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// Read-only bottom sheet displaying detailed stats for an artist/creator
  /// (total size in MB/GB, photo/video/audio/album counts, privacy breakdown,
  /// last updated date, and saved profile link). Intentionally has NO delete action.
  void _showCreatorInfoSheet({
    required MediaPlatform platform,
    required String creatorName,
    required List<ManagedFile> files,
    required CreatorProfileRecord? savedProfile,
    required ManagedFile? sampleImage,
  }) {
    final isPixiv = platform == MediaPlatform.pixiv;
    final totalBytes = files.fold<int>(0, (s, f) => s + f.fileSize);
    final photoCount = files.where((f) => f.mediaKind == MediaKind.image).length;
    final videoCount = files.where((f) => f.mediaKind == MediaKind.video).length;
    final audioCount = files.where((f) => f.mediaKind == MediaKind.audio).length;
    final privateCount = files.where((f) => f.isPrivate).length;
    final publicCount = files.length - privateCount;
    final albumCount =
        isPixiv ? files.map((f) => f.effectiveAlbumName).toSet().length : 0;
    final latestMod = files.isNotEmpty
        ? files
            .map((e) => e.modifiedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b)
        : null;

    final sizeLabel = totalBytes > 0 ? formatBytes(totalBytes) : '0 B';
    final mediaBreakdown = <String>[
      if (photoCount > 0) '$photoCount foto',
      if (videoCount > 0)
        isPixiv ? '$videoCount video/Ugoira' : '$videoCount video',
      if (audioCount > 0) '$audioCount audio',
    ].join(' • ');

    String formatDateTime(DateTime dt) {
      final d = dt.day.toString().padLeft(2, '0');
      final m = dt.month.toString().padLeft(2, '0');
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$d/$m/${dt.year} $hh:$mm';
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: Avatar + Artist Name + Platform
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: sampleImage != null
                            ? Image.file(
                                File(sampleImage.savedPath),
                                cacheWidth: 160,
                                filterQuality: FilterQuality.low,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    _creatorIconBox(platform),
                              )
                            : _creatorIconBox(platform),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            creatorName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Informasi ${isPixiv ? 'Artist' : 'Kreator'} • ${platform.label}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: platform.brandColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Quick Stat Cards (Total Size, Photo/Media Count, Album/File Count)
                Row(
                  children: [
                    Expanded(
                      child: _CreatorStatCard(
                        icon: Icons.sd_storage_outlined,
                        color: platform.brandColor,
                        value: sizeLabel,
                        label: 'Total Ukuran',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _CreatorStatCard(
                        icon: Icons.photo_outlined,
                        color: const Color(0xFF38BDF8),
                        value: '$photoCount',
                        label: 'Foto',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _CreatorStatCard(
                        icon: isPixiv
                            ? Icons.collections_bookmark_outlined
                            : Icons.insert_drive_file_outlined,
                        color: const Color(0xFFA855F7),
                        value: isPixiv ? '$albumCount' : '${files.length}',
                        label: isPixiv ? 'Album' : 'Total File',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Detailed Read-Only Info Rows
                _InfoRow(label: 'Platform', value: platform.label),
                _InfoRow(label: 'Total File', value: '${files.length} file'),
                if (mediaBreakdown.isNotEmpty)
                  _InfoRow(label: 'Media', value: mediaBreakdown),
                if (isPixiv) _InfoRow(label: 'Album', value: '$albumCount album'),
                if (privateCount > 0 || isPixiv)
                  _InfoRow(
                    label: 'Privasi',
                    value: '$privateCount privat • $publicCount galeri',
                  ),
                if (latestMod != null)
                  _InfoRow(label: 'Terakhir', value: formatDateTime(latestMod)),
                if (savedProfile != null)
                  _InfoRow(label: 'Link', value: savedProfile.profileUrl),

                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (savedProfile != null) ...[
                      TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: savedProfile.profileUrl),
                          );
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Link profil disalin.'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 17),
                        label: const Text('Salin Link'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    FilledButton.tonal(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Tutup'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openEditCreatorLinkDialog(
    MediaPlatform platform,
    String creatorFolder,
    CreatorProfileRecord? existing,
  ) async {
    final controller = TextEditingController(text: existing?.profileUrl ?? '');
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Link Profil $creatorFolder'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Simpan tautan profil ${platform.label} agar Anda bisa 1-klik "Lanjut Unduh" untuk mengecek karya terbaru kapan saja.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: platform == MediaPlatform.pixiv
                    ? 'https://www.pixiv.net/users/... atau pixiv:nama'
                    : 'https://...',
                suffixIcon: IconButton(
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    final raw = data?.text?.trim() ?? '';
                    if (raw.isNotEmpty) {
                      controller.text = UrlParser.extractUrl(raw) ?? raw;
                    }
                  },
                  icon: const Icon(Icons.content_paste_rounded, size: 19),
                  tooltip: 'Tempel',
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              child: const Text('Hapus'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Simpan'),
          ),
          if (widget.onOpenProfileUrl != null)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save_and_open'),
              child: const Text('Lanjut Unduh'),
            ),
        ],
      ),
    );

    final rawText = controller.text.trim();
    controller.dispose();

    if (action == 'delete') {
      await widget.manager.removeCreatorProfile(
        platform.folderName,
        creatorFolder,
      );
      return;
    }

    if ((action == 'save' || action == 'save_and_open') && rawText.isNotEmpty) {
      final cleanUrl = UrlParser.extractUrl(rawText) ?? rawText;
      await widget.manager.saveCreatorProfile(
        platform: platform,
        creatorFolder: creatorFolder,
        profileUrl: cleanUrl,
        displayName: creatorFolder,
      );
      if (action == 'save_and_open') {
        widget.onOpenProfileUrl?.call(cleanUrl);
      }
    }
  }

  Widget _buildEmptySearchSliver(BuildContext context, String message) {
    final theme = Theme.of(context);
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off_rounded,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Coba kata kunci lain atau hapus pencarian.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _creatorIconBox(MediaPlatform platform) {
    return Container(
      decoration: BoxDecoration(
        color: platform.brandColor.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.folder_shared_rounded,
        color: platform.brandColor,
      ),
    );
  }

  // ===========================================================================
  // LEVEL 2 (PIXIV): PER-ALBUM / PER-HALAMAN GRID (2 Columns)
  // ===========================================================================
  Widget _buildPixivAlbumsGridSliver(List<_PixivAlbumGroup> albums) {
    final bottomPad = _isSelectionMode ? 104.0 : 28.0;
    final theme = Theme.of(context);

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(12, 2, 12, bottomPad),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.80,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final album = albums[index];
            final isSelected = _selectedKeys.contains(album.albumName);
            final albumTags = widget.manager.getAlbumTags(
              _selectedPlatformFolder!,
              _selectedCreatorFolder!,
              album.albumName,
            );

            return MetaData(
              metaData: _SelectableIndexMeta(index),
              behavior: HitTestBehavior.opaque,
              child: GestureDetector(
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleSelectionKey(album.albumName);
                  } else {
                    _openPixivAlbum(albums, index);
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 130),
                  decoration: BoxDecoration(
                    color: theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.4),
                      width: isSelected ? 2.2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            album.cover.mediaKind == MediaKind.video
                                ? Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          const Color(0xFF0096FA)
                                              .withValues(alpha: 0.35),
                                          const Color(0xFF1E293B),
                                        ],
                                      ),
                                    ),
                                    child: const Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.play_circle_filled_rounded,
                                          size: 46,
                                          color: Colors.white,
                                        ),
                                        SizedBox(height: 6),
                                        Text(
                                          'Ugoira MP4',
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : Image.file(
                                    File(album.cover.savedPath),
                                    cacheWidth: 380,
                                    filterQuality: FilterQuality.low,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                      color: theme
                                          .colorScheme.surfaceContainerHighest,
                                      child: const Icon(
                                          Icons.collections_outlined,
                                          size: 36),
                                    ),
                                  ),
                            if (isSelected)
                              Container(
                                color: theme.colorScheme.primary
                                    .withValues(alpha: 0.22),
                              ),
                            // Privacy status pill (top-left)
                            Positioned(
                              top: 6,
                              left: 6,
                              child: _AlbumStatusPill(album: album),
                            ),
                            // Page count pill (bottom-right, Pixiv-style!)
                            Positioned(
                              right: 6,
                              bottom: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.72),
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      album.cover.mediaKind == MediaKind.video
                                          ? Icons.movie_creation_rounded
                                          : Icons.collections_rounded,
                                      size: 11,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      album.cover.mediaKind == MediaKind.video &&
                                              album.pages.length == 1
                                          ? 'Ugoira'
                                          : '${album.pages.length} Hal',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Top-right: selection circle or 3-dot album menu
                            if (_isSelectionMode)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: _SelectionCircle(selected: isSelected),
                              )
                            else
                              Positioned(
                                top: 4,
                                right: 4,
                                child: _AlbumPopupMenu(
                                  album: album,
                                  overlay: true,
                                  onSelected: (act) =>
                                      _handleAlbumAction(act, albums, index),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              album.albumName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${album.pages.length} foto • ${formatBytes(album.totalBytes)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (albumTags.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                albumTags.take(3).map((t) => '#$t').join(' '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 10,
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.9),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
          childCount: albums.length,
        ),
      ),
    );
  }

  // ===========================================================================
  // LEVEL 2 (PIXIV): PER-ALBUM ROW LIST
  // ===========================================================================
  Widget _buildPixivAlbumsRowSliver(List<_PixivAlbumGroup> albums) {
    final bottomPad = _isSelectionMode ? 104.0 : 28.0;
    final theme = Theme.of(context);

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(14, 2, 14, bottomPad),
      sliver: SliverList.separated(
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final album = albums[index];
          final isSelected = _selectedKeys.contains(album.albumName);
          final albumTags = widget.manager.getAlbumTags(
            _selectedPlatformFolder!,
            _selectedCreatorFolder!,
            album.albumName,
          );

          return MetaData(
            metaData: _SelectableIndexMeta(index),
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
                    _toggleSelectionKey(album.albumName);
                  } else {
                    _openPixivAlbum(albums, index);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
                  child: Row(
                    children: [
                      if (_isSelectionMode) ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _SelectionCircle(selected: isSelected),
                        ),
                      ],
                      ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: SizedBox(
                          width: 60,
                          height: 60,
                          child: album.cover.mediaKind == MediaKind.video
                              ? Container(
                                  color: const Color(0xFF0096FA)
                                      .withValues(alpha: 0.2),
                                  child: const Icon(
                                    Icons.play_circle_filled_rounded,
                                    color: Color(0xFF0096FA),
                                    size: 30,
                                  ),
                                )
                              : Image.file(
                                  File(album.cover.savedPath),
                                  cacheWidth: 160,
                                  filterQuality: FilterQuality.low,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    color: theme
                                        .colorScheme.surfaceContainerHighest,
                                    child:
                                        const Icon(Icons.collections_outlined),
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
                                _AlbumStatusPill(album: album),
                                const SizedBox(width: 6),
                                Text(
                                  '${album.pages.length} Hal',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              album.albumName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${formatBytes(album.totalBytes)} • ${_fmtDate(album.latestModified)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (albumTags.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                albumTags.take(4).map((t) => '#$t').join(' '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.9),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (!_isSelectionMode)
                        _AlbumPopupMenu(
                          album: album,
                          onSelected: (act) =>
                              _handleAlbumAction(act, albums, index),
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
  // LEVEL 2 (NON-PIXIV): GALLERY GRID & ROW LIST
  // ===========================================================================
  Widget _buildFilesGallerySliver(List<ManagedFile> files) {
    final bottomPad = _isSelectionMode ? 104.0 : 28.0;

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(10, 2, 10, bottomPad),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
          childAspectRatio: 0.92,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final file = files[index];
            final isSelected = _selectedKeys.contains(file.uniqueKey);
            return MetaData(
              metaData: _SelectableIndexMeta(index),
              behavior: HitTestBehavior.opaque,
              child: _GalleryFileTile(
                file: file,
                rating: widget.manager.getPhotoRating(file),
                selectionMode: _isSelectionMode,
                selected: isSelected,
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleSelectionKey(file.uniqueKey);
                  } else {
                    _openPrimaryView(file, files);
                  }
                },
                onMenuAction: (action) =>
                    _handleFileMenuAction(action, file, files),
              ),
            );
          },
          childCount: files.length,
        ),
      ),
    );
  }

  Widget _buildFilesRowSliver(List<ManagedFile> files) {
    final bottomPad = _isSelectionMode ? 104.0 : 28.0;
    final theme = Theme.of(context);

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(14, 2, 14, bottomPad),
      sliver: SliverList.separated(
        itemCount: files.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final file = files[index];
          final isSelected = _selectedKeys.contains(file.uniqueKey);

          return MetaData(
            metaData: _SelectableIndexMeta(index),
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
                    _toggleSelectionKey(file.uniqueKey);
                  } else {
                    _openPrimaryView(file, files);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
                  child: Row(
                    children: [
                      if (_isSelectionMode) ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _SelectionCircle(selected: isSelected),
                        ),
                      ],
                      _FileThumb(file: file),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              file.fileName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                if (widget.manager.getPhotoRating(file) !=
                                    ContentRating.normal) ...[
                                  ContentRatingBadge(
                                    rating: widget.manager.getPhotoRating(file),
                                    compact: true,
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Expanded(
                                  child: Text(
                                    '${file.extension} • ${formatBytes(file.fileSize)} • ${_fmtDate(file.modifiedAt)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (!_isSelectionMode)
                        _FilePopupMenu(
                          isImage: file.mediaKind == MediaKind.image,
                          isPrivate: file.isPrivate,
                          onSelected: (action) =>
                              _handleFileMenuAction(action, file, files),
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
  Future<void> _openPixivAlbum(
    List<_PixivAlbumGroup> albums,
    int index,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (index < 0 || index >= albums.length) return;
    final albumNames = albums.map((a) => a.albumName).toList(growable: false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PixivAlbumViewer(
          manager: widget.manager,
          platformFolder: _selectedPlatformFolder!,
          creatorFolder: _selectedCreatorFolder!,
          albumName: albumNames[index],
          albumNames: albumNames,
          initialAlbumIndex: index,
        ),
      ),
    );
  }

  Future<void> _handleAlbumAction(
    _AlbumMenuAction action,
    List<_PixivAlbumGroup> albums,
    int index,
  ) async {
    final album = albums[index];
    switch (action) {
      case _AlbumMenuAction.open:
        await _openPixivAlbum(albums, index);
        break;
      case _AlbumMenuAction.info:
        _showAlbumInfoAndTagsSheet(album);
        break;
      case _AlbumMenuAction.unlock:
        await _unlockFiles(album.pages.where((p) => p.isPrivate).toList());
        break;
      case _AlbumMenuAction.lock:
        await _lockFiles(album.pages.where((p) => !p.isPrivate).toList());
        break;
      case _AlbumMenuAction.share:
        await _shareSelectedFiles(album.pages);
        break;
      case _AlbumMenuAction.select:
        _enterSelectionWithKey(album.albumName);
        break;
      case _AlbumMenuAction.delete:
        await _confirmDeleteMultiple(
          album.pages,
          unitLabel: 'album "${album.albumName}" (${album.pages.length} foto)',
        );
        break;
    }
  }

  Future<void> _openPrimaryView(
    ManagedFile file,
    List<ManagedFile> folderFiles,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (file.mediaKind == MediaKind.image && file.savedPath.isNotEmpty) {
      final folderImages = folderFiles
          .where((f) => f.mediaKind == MediaKind.image && f.savedPath.isNotEmpty)
          .toList(growable: false);
      final idx = folderImages.indexWhere((f) => f.uniqueKey == file.uniqueKey);
      if (idx != -1 && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FileGalleryViewer(
              manager: widget.manager,
              images: folderImages,
              initialIndex: idx,
            ),
          ),
        );
        return;
      }
    }
    await _openExternalFile(file);
  }

  Future<void> _handleFileMenuAction(
    _FileMenuAction action,
    ManagedFile file,
    List<ManagedFile> folderFiles,
  ) async {
    switch (action) {
      case _FileMenuAction.view:
        await _openPrimaryView(file, folderFiles);
        break;
      case _FileMenuAction.setWallpaper:
        await showSetWallpaperSheet(
          context,
          manager: widget.manager,
          file: file,
        );
        break;
      case _FileMenuAction.toggleLock:
        if (file.isPrivate) {
          await _unlockFiles([file]);
        } else {
          await _lockFiles([file]);
        }
        break;
      case _FileMenuAction.tagContent:
        await showPhotoContentRatingSheet(
          context,
          manager: widget.manager,
          file: file,
        );
        break;
      case _FileMenuAction.openExternal:
        await _openExternalFile(file);
        break;
      case _FileMenuAction.share:
        await widget.manager.shareManagedFile(file);
        break;
      case _FileMenuAction.select:
        _enterSelectionWithKey(file.uniqueKey);
        break;
      case _FileMenuAction.info:
        _showFileInfoSheet(file);
        break;
      case _FileMenuAction.delete:
        await _confirmDeleteMultiple([file], unitLabel: '"${file.fileName}"');
        break;
    }
  }

  Future<void> _unlockFiles(List<ManagedFile> targets) async {
    if (targets.isEmpty || _isBusy) return;
    setState(() => _isBusy = true);
    try {
      await widget.manager.unlockManagedFiles(targets);
      if (!mounted) return;
      if (_isSelectionMode) _exitSelectionMode();
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _lockFiles(List<ManagedFile> targets) async {
    if (targets.isEmpty || _isBusy) return;
    setState(() => _isBusy = true);
    try {
      await widget.manager.lockManagedFiles(targets);
      if (!mounted) return;
      if (_isSelectionMode) _exitSelectionMode();
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _openExternalFile(ManagedFile file) async {
    final ok = await widget.manager.openManagedFile(file);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Tidak ada aplikasi pemutar yang cocok atau file sudah dipindah.',
          ),
        ),
      );
    }
  }

  Future<void> _shareSelectedFiles(List<ManagedFile> selected) async {
    if (selected.isEmpty) return;
    final ok = await widget.manager.shareMultipleManagedFiles(selected);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Gagal membuka menu Bagikan untuk file terpilih.'),
        ),
      );
    }
  }

  Future<void> _confirmDeleteMultiple(
    List<ManagedFile> selected, {
    required String unitLabel,
  }) async {
    if (selected.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Permanen?'),
        content: Text(
          'Hapus $unitLabel dari perangkat? Tindakan ini tidak dapat dibatalkan.',
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

    final deleted = await widget.manager.deleteMultipleManagedFiles(selected);
    if (!mounted) return;
    if (_isSelectionMode) _exitSelectionMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$deleted file berhasil dihapus.')),
    );
  }

  void _showAlbumInfoAndTagsSheet(_PixivAlbumGroup album) {
    final platformFolder = _selectedPlatformFolder ?? album.cover.platformFolder;
    final creatorFolder = _selectedCreatorFolder ?? album.cover.creatorFolder;
    final tags = widget.manager.getAlbumTags(
      platformFolder,
      creatorFolder,
      album.albumName,
    );
    var normalCount = 0;
    var ecchiCount = 0;
    var nsfwCount = 0;
    for (final p in album.pages) {
      switch (widget.manager.getPhotoRating(p)) {
        case ContentRating.normal:
          normalCount++;
          break;
        case ContentRating.ecchi:
          ecchiCount++;
          break;
        case ContentRating.nsfw:
          nsfwCount++;
          break;
      }
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Info & Tag Album',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                _InfoRow(label: 'Album', value: album.albumName),
                _InfoRow(label: 'Artist', value: creatorFolder),
                _InfoRow(
                  label: 'Halaman',
                  value: '${album.pages.length} file • ${formatBytes(album.totalBytes)}',
                ),
                _InfoRow(
                  label: 'Privasi',
                  value: '${album.privateCount} privat • ${album.publicCount} galeri',
                ),
                _InfoRow(
                  label: 'Konten',
                  value: '$normalCount biasa • $ecchiCount ecchi • $nsfwCount NSFW',
                ),
                const SizedBox(height: 10),
                Text(
                  tags.isNotEmpty
                      ? 'Tag Album (${tags.length}) — ketuk untuk salin'
                      : 'Belum ada tag tersimpan untuk album ini',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final tag in tags)
                            ActionChip(
                              label: Text(
                                '#$tag',
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: tag));
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(
                                    SnackBar(
                                      duration: const Duration(seconds: 1),
                                      content: Text('Tag "#$tag" disalin.'),
                                    ),
                                  );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (tags.isNotEmpty) ...[
                      TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(
                              text: tags.map((t) => '#$t').join(' '),
                            ),
                          );
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Semua tag album disalin.'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 17),
                        label: const Text('Salin Tag'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    FilledButton.tonal(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Tutup'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFileInfoSheet(ManagedFile file) {
    final rating = widget.manager.getPhotoRating(file);
    final albumTags = widget.manager.getAlbumTags(
      file.platformFolder,
      file.creatorFolder,
      file.effectiveAlbumName,
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
                'Detail File',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 12),
              _InfoRow(
                label: 'Privasi',
                value: file.isPrivate
                    ? 'Privat (Tersembunyi dari Galeri & WA)'
                    : 'Publik (Muncul di Galeri & WA)',
              ),
              _InfoRow(label: 'Konten', value: rating.label),
              _InfoRow(label: 'Nama', value: file.fileName),
              _InfoRow(
                label: 'Folder',
                value: '${file.platformFolder} / ${file.creatorFolder}',
              ),
              _InfoRow(label: 'Ukuran', value: formatBytes(file.fileSize)),
              _InfoRow(label: 'Tipe', value: file.mimeType),
              _InfoRow(label: 'Tanggal', value: _fmtDate(file.modifiedAt)),
              if (albumTags.isNotEmpty)
                _InfoRow(
                  label: 'Tag',
                  value: albumTags.map((t) => '#$t').join(' '),
                ),
              _InfoRow(
                label: 'Lokasi',
                value: file.savedPath.isNotEmpty
                    ? file.savedPath
                    : file.relativePath,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(
                          text: file.savedPath.isNotEmpty
                              ? file.savedPath
                              : file.relativePath,
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
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      widget.manager.shareManagedFile(file);
                    },
                    icon: const Icon(Icons.share_rounded, size: 17),
                    label: const Text('Bagikan'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmtDate(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$d/$m $hh:$mm';
  }
}

// =============================================================================
// UI SUB-COMPONENTS
// =============================================================================

class _AlbumStatusPill extends StatelessWidget {
  final _PixivAlbumGroup album;

  const _AlbumStatusPill({required this.album});

  @override
  Widget build(BuildContext context) {
    final allPrivate = !album.hasPublic;
    final allPublic = !album.hasPrivate;
    final color = allPublic
        ? const Color(0xFF16A34A)
        : const Color(0xFFF59E0B);
    final label = allPrivate
        ? 'Privat'
        : (allPublic ? 'Galeri' : '${album.privateCount} Privat');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            allPublic ? Icons.lock_open_rounded : Icons.lock_rounded,
            size: 10.5,
            color: Colors.white,
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumPopupMenu extends StatelessWidget {
  final _PixivAlbumGroup album;
  final bool overlay;
  final ValueChanged<_AlbumMenuAction> onSelected;

  const _AlbumPopupMenu({
    required this.album,
    required this.onSelected,
    this.overlay = false,
  });

  @override
  Widget build(BuildContext context) {
    final err = Theme.of(context).colorScheme.error;
    return PopupMenuButton<_AlbumMenuAction>(
      onSelected: onSelected,
      padding: EdgeInsets.zero,
      tooltip: 'Opsi album',
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
          value: _AlbumMenuAction.open,
          child: Row(
            children: [
              Icon(Icons.menu_book_rounded, size: 19),
              SizedBox(width: 10),
              Text('Buka Halaman Album'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _AlbumMenuAction.info,
          child: Row(
            children: [
              Icon(Icons.tag_rounded, size: 19),
              SizedBox(width: 10),
              Text('Info & Tag Album'),
            ],
          ),
        ),
        if (album.hasPrivate)
          const PopupMenuItem(
            value: _AlbumMenuAction.unlock,
            child: Row(
              children: [
                Icon(Icons.lock_open_rounded,
                    size: 19, color: Color(0xFF16A34A)),
                SizedBox(width: 10),
                Text('Unlock ke Galeri & WA'),
              ],
            ),
          ),
        if (album.hasPublic)
          const PopupMenuItem(
            value: _AlbumMenuAction.lock,
            child: Row(
              children: [
                Icon(Icons.lock_outline_rounded,
                    size: 19, color: Color(0xFFF59E0B)),
                SizedBox(width: 10),
                Text('Kunci Kembali ke Privat'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: _AlbumMenuAction.share,
          child: Row(
            children: [
              Icon(Icons.share_rounded, size: 19),
              SizedBox(width: 10),
              Text('Bagikan Album'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _AlbumMenuAction.select,
          child: Row(
            children: [
              Icon(Icons.check_circle_outline_rounded, size: 19),
              SizedBox(width: 10),
              Text('Pilih Banyak'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _AlbumMenuAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 19, color: err),
              const SizedBox(width: 10),
              Text('Hapus Album', style: TextStyle(color: err)),
            ],
          ),
        ),
      ],
    );
  }
}

class _GalleryFileTile extends StatelessWidget {
  final ManagedFile file;
  final ContentRating rating;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final void Function(_FileMenuAction action) onMenuAction;

  const _GalleryFileTile({
    required this.file,
    required this.rating,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onMenuAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isImage =
        file.mediaKind == MediaKind.image && file.savedPath.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.all(selected ? 4 : 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.22)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
            width: selected ? 2 : 0.8,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(selected ? 8 : 11),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (isImage)
                Image.file(
                  File(file.savedPath),
                  cacheWidth: 320,
                  filterQuality: FilterQuality.low,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _mediaFallback(theme),
                )
              else
                _mediaFallback(theme),

              if (selected)
                Container(
                  color: theme.colorScheme.primary.withValues(alpha: 0.16),
                ),

              if (!isImage)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(6, 12, 6, 5),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.78),
                        ],
                      ),
                    ),
                    child: Text(
                      file.fileName,
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

              if (!selectionMode && file.isPrivate)
                Positioned(
                  top: 5,
                  left: 5,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.lock_rounded,
                      size: 11,
                      color: Colors.white,
                    ),
                  ),
                )
              else if (!selectionMode && file.mediaKind != MediaKind.image)
                Positioned(
                  top: 5,
                  left: 5,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      file.extension,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),

              if (!selectionMode && rating != ContentRating.normal)
                Positioned(
                  left: 5,
                  bottom: 5,
                  child: ContentRatingBadge(rating: rating, compact: true),
                ),

              if (selectionMode)
                Positioned(
                  top: 5,
                  right: 5,
                  child: _SelectionCircle(selected: selected),
                )
              else
                Positioned(
                  top: 3,
                  right: 3,
                  child: _FilePopupMenu(
                    isImage: file.mediaKind == MediaKind.image,
                    isPrivate: file.isPrivate,
                    compactOverlay: true,
                    onSelected: onMenuAction,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mediaFallback(ThemeData theme) {
    final icon = switch (file.mediaKind) {
      MediaKind.video => Icons.play_circle_filled_rounded,
      MediaKind.audio => Icons.music_note_rounded,
      MediaKind.image => Icons.image_rounded,
    };
    return Container(
      color: file.platform.brandColor.withValues(alpha: 0.16),
      child: Center(
        child: Icon(icon, color: file.platform.brandColor, size: 36),
      ),
    );
  }
}

class _FilePopupMenu extends StatelessWidget {
  final bool isImage;
  final bool isPrivate;
  final bool compactOverlay;
  final void Function(_FileMenuAction action) onSelected;

  const _FilePopupMenu({
    required this.isImage,
    required this.isPrivate,
    required this.onSelected,
    this.compactOverlay = false,
  });

  @override
  Widget build(BuildContext context) {
    final errColor = Theme.of(context).colorScheme.error;

    return PopupMenuButton<_FileMenuAction>(
      onSelected: onSelected,
      padding: EdgeInsets.zero,
      tooltip: 'Opsi file',
      child: compactOverlay
          ? Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.52),
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
        PopupMenuItem(
          value: _FileMenuAction.view,
          child: Row(
            children: [
              Icon(
                isImage ? Icons.visibility_rounded : Icons.play_arrow_rounded,
                size: 19,
              ),
              const SizedBox(width: 10),
              Text(isImage ? 'Lihat Foto' : 'Putar'),
            ],
          ),
        ),
        if (isImage)
          const PopupMenuItem(
            value: _FileMenuAction.setWallpaper,
            child: Row(
              children: [
                Icon(Icons.wallpaper_rounded, size: 19),
                SizedBox(width: 10),
                Text('Jadikan Wallpaper'),
              ],
            ),
          ),
        PopupMenuItem(
          value: _FileMenuAction.toggleLock,
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
            value: _FileMenuAction.tagContent,
            child: Row(
              children: [
                Icon(Icons.label_outline_rounded, size: 19),
                SizedBox(width: 10),
                Text('Tandai Konten (Biasa/Ecchi/NSFW)'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: _FileMenuAction.share,
          child: Row(
            children: [
              Icon(Icons.share_rounded, size: 19),
              SizedBox(width: 10),
              Text('Bagikan'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _FileMenuAction.select,
          child: Row(
            children: [
              Icon(Icons.check_circle_outline_rounded, size: 19),
              SizedBox(width: 10),
              Text('Pilih Banyak'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _FileMenuAction.openExternal,
          child: Row(
            children: [
              Icon(Icons.open_in_new_rounded, size: 19),
              SizedBox(width: 10),
              Text('Buka di App Lain'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _FileMenuAction.info,
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 19),
              SizedBox(width: 10),
              Text('Detail File'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _FileMenuAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 19, color: errColor),
              const SizedBox(width: 10),
              Text('Hapus', style: TextStyle(color: errColor)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ViewModeToggle extends StatelessWidget {
  final _FileViewMode mode;
  final ValueChanged<_FileViewMode> onChanged;

  const _ViewModeToggle({required this.mode, required this.onChanged});

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
          _ModeBtn(
            icon: Icons.grid_view_rounded,
            tooltip: 'Mode Album / Galeri',
            active: mode == _FileViewMode.gallery,
            onTap: () => onChanged(_FileViewMode.gallery),
          ),
          _ModeBtn(
            icon: Icons.view_agenda_rounded,
            tooltip: 'Mode Baris',
            active: mode == _FileViewMode.list,
            onTap: () => onChanged(_FileViewMode.list),
          ),
        ],
      ),
    );
  }
}

class _ModeBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _ModeBtn({
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
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
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

class _SelectionCircle extends StatelessWidget {
  final bool selected;

  const _SelectionCircle({required this.selected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 23,
      height: 23,
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

class _SelectionBatchBar extends StatelessWidget {
  final int selectedUnitCount;
  final List<ManagedFile> selectedFiles;
  final bool busy;
  final VoidCallback onUnlock;
  final VoidCallback onLock;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  const _SelectionBatchBar({
    required this.selectedUnitCount,
    required this.selectedFiles,
    required this.busy,
    required this.onUnlock,
    required this.onLock,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPrivate = selectedFiles.any((f) => f.isPrivate);
    final hasPublic = selectedFiles.any((f) => !f.isPrivate);

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(18),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            if (hasPrivate) ...[
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
                  label: const Text(
                    'Unlock',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (hasPublic && !hasPrivate) ...[
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
                  label: const Text(
                    'Kunci',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
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
                label: Text(
                  'Share ($selectedUnitCount)',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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

class _FileThumb extends StatelessWidget {
  final ManagedFile file;

  const _FileThumb({required this.file});

  @override
  Widget build(BuildContext context) {
    final isLocalImg =
        file.mediaKind == MediaKind.image && file.savedPath.isNotEmpty;

    final icon = switch (file.mediaKind) {
      MediaKind.video => Icons.play_circle_filled_rounded,
      MediaKind.audio => Icons.music_note_rounded,
      MediaKind.image => Icons.image_rounded,
    };

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 54,
        height: 54,
        child: isLocalImg
            ? Image.file(
                File(file.savedPath),
                cacheWidth: 160,
                filterQuality: FilterQuality.low,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _fallback(context, icon),
              )
            : _fallback(context, icon),
      ),
    );
  }

  Widget _fallback(BuildContext context, IconData icon) {
    return Container(
      color: file.platform.brandColor.withValues(alpha: 0.16),
      child: Icon(icon, color: file.platform.brandColor, size: 28),
    );
  }
}

class _BreadcrumbChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _BreadcrumbChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.16)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _StickyAlbumToolbarDelegate extends SliverPersistentHeaderDelegate {
  final Color backgroundColor;
  final bool isPixivArtist;
  final int albumCount;
  final int photoCount;
  final bool showAllPhotos;
  final bool shuffleEnabled;
  final _FileViewMode viewMode;
  final VoidCallback onSelectAlbums;
  final VoidCallback onSelectAllPhotos;
  final VoidCallback onToggleShuffle;
  final VoidCallback onReshuffle;
  final ValueChanged<_FileViewMode> onViewModeChanged;

  const _StickyAlbumToolbarDelegate({
    required this.backgroundColor,
    required this.isPixivArtist,
    required this.albumCount,
    required this.photoCount,
    required this.showAllPhotos,
    required this.shuffleEnabled,
    required this.viewMode,
    required this.onSelectAlbums,
    required this.onSelectAllPhotos,
    required this.onToggleShuffle,
    required this.onReshuffle,
    required this.onViewModeChanged,
  });

  @override
  double get minExtent => 54;

  @override
  double get maxExtent => 54;

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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
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
                    if (isPixivArtist) ...[
                      ChoiceChip(
                        avatar: const Icon(
                          Icons.collections_bookmark_outlined,
                          size: 16,
                        ),
                        label: Text('Album ($albumCount)'),
                        selected: !showAllPhotos,
                        showCheckmark: false,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => onSelectAlbums(),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        avatar: const Icon(
                          Icons.photo_library_outlined,
                          size: 16,
                        ),
                        label: Text('Semua Foto ($photoCount)'),
                        selected: showAllPhotos,
                        showCheckmark: false,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => onSelectAllPhotos(),
                      ),
                      const SizedBox(width: 8),
                    ],
                    FilterChip(
                      avatar: Icon(
                        Icons.shuffle_rounded,
                        size: 16,
                        color: shuffleEnabled
                            ? theme.colorScheme.primary
                            : null,
                      ),
                      label: Text(shuffleEnabled ? 'Acak Aktif' : 'Acak'),
                      selected: shuffleEnabled,
                      showCheckmark: false,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => onToggleShuffle(),
                    ),
                    if (shuffleEnabled) ...[
                      const SizedBox(width: 6),
                      ActionChip(
                        avatar: const Icon(
                          Icons.refresh_rounded,
                          size: 16,
                        ),
                        label: const Text('Acak Lagi'),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        onPressed: onReshuffle,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _ViewModeToggle(
              mode: viewMode,
              onChanged: onViewModeChanged,
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickyAlbumToolbarDelegate oldDelegate) {
    return backgroundColor != oldDelegate.backgroundColor ||
        isPixivArtist != oldDelegate.isPixivArtist ||
        albumCount != oldDelegate.albumCount ||
        photoCount != oldDelegate.photoCount ||
        showAllPhotos != oldDelegate.showAllPhotos ||
        shuffleEnabled != oldDelegate.shuffleEnabled ||
        viewMode != oldDelegate.viewMode;
  }
}

class _CreatorEntry {
  final String name;
  final List<ManagedFile> files;
  final int totalSize;
  final int photoCount;
  final int privateCount;
  final int albumCount;
  final DateTime latestModified;
  final ManagedFile? sampleImage;

  const _CreatorEntry({
    required this.name,
    required this.files,
    required this.totalSize,
    required this.photoCount,
    required this.privateCount,
    required this.albumCount,
    required this.latestModified,
    required this.sampleImage,
  });
}

class _CreatorStatCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  const _CreatorStatCard({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

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
