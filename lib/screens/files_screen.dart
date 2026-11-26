import 'dart:async';
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

enum _FileViewMode { gallery, list }

enum _FileMenuAction { view, openExternal, share, select, info, delete }

class _SelectableIndexMeta {
  final int index;
  const _SelectableIndexMeta(this.index);
}

/// Dedicated "File" explorer tab:
/// Level 0: Platform folders (YouTube, TikTok, Instagram, Pixiv, Facebook, Douyin, X)
/// Level 1: Creator / Username folders inside the selected platform
/// Level 2: Downloaded files inside `<Platform>/<Username>/` with:
///   - Gallery Grid (3-column) & Row List toggle
///   - Long-press & continuous Drag-to-Select (with smooth edge auto-scroll!)
///   - Per-file 3-dot action menu (Lihat, Bagikan, Pilih, Buka App Lain, Detail, Hapus)
///   - Multi-Share (Android ACTION_SEND_MULTIPLE) & Multi-Delete batch bar
///   - In-app swipeable pinch-to-zoom Photo Viewer
class FilesScreen extends StatefulWidget {
  final DownloadManager manager;

  const FilesScreen({super.key, required this.manager});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();

  String? _selectedPlatformFolder;
  String? _selectedCreatorFolder;
  _FileViewMode _viewMode = _FileViewMode.gallery;

  // Multi-select & Drag-select state
  bool _isSelectionMode = false;
  final Set<String> _selectedKeys = <String>{};
  int? _dragStartIndex;
  int? _dragLastIndex;
  bool _dragSelectMode = true;
  Set<String> _preDragSelectedKeys = <String>{};
  Offset? _lastDragGlobalPos;
  Timer? _autoScrollTimer;
  List<ManagedFile> _activeFolderFiles = const [];

  @override
  void dispose() {
    _stopAutoScroll();
    _scrollController.dispose();
    super.dispose();
  }

  String _fileKey(ManagedFile file) =>
      file.contentUri.isNotEmpty ? file.contentUri : file.savedPath;

  void _exitSelectionMode() {
    _stopAutoScroll();
    setState(() {
      _isSelectionMode = false;
      _selectedKeys.clear();
      _dragStartIndex = null;
      _dragLastIndex = null;
    });
  }

  void _enterSelectionWith(ManagedFile file) {
    HapticFeedback.mediumImpact();
    setState(() {
      _isSelectionMode = true;
      _selectedKeys.add(_fileKey(file));
    });
  }

  void _toggleFileSelection(ManagedFile file) {
    final key = _fileKey(file);
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
    if (_isSelectionMode) {
      _exitSelectionMode();
      return;
    }
    setState(() {
      if (_selectedCreatorFolder != null) {
        _selectedCreatorFolder = null;
      } else if (_selectedPlatformFolder != null) {
        _selectedPlatformFolder = null;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Google Photos–style Long-Press + Drag-to-Select Hit Testing & Auto-Scroll
  // ---------------------------------------------------------------------------
  int? _hitTestFileIndex(Offset globalPosition) {
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
    if (_selectedCreatorFolder == null || _activeFolderFiles.isEmpty) return;
    final hitIdx = _hitTestFileIndex(details.globalPosition);
    if (hitIdx == null || hitIdx < 0 || hitIdx >= _activeFolderFiles.length) return;

    HapticFeedback.mediumImpact();
    final key = _fileKey(_activeFolderFiles[hitIdx]);
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
    if (_dragStartIndex == null || _activeFolderFiles.isEmpty) return;
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
    final hitIdx = _hitTestFileIndex(globalPos);
    if (hitIdx == null || hitIdx < 0 || hitIdx >= _activeFolderFiles.length) return;
    if (hitIdx == _dragLastIndex) return;

    _dragLastIndex = hitIdx;
    HapticFeedback.selectionClick();

    final lo = math.min(startIdx, hitIdx);
    final hi = math.max(startIdx, hitIdx);
    final updated = Set<String>.from(_preDragSelectedKeys);
    for (int i = lo; i <= hi; i++) {
      final k = _fileKey(_activeFolderFiles[i]);
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
      final factor = ((localPos.dy - (height - edgeZone)) / edgeZone).clamp(0.15, 1.0);
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
      final target = (pos.pixels + velocity).clamp(pos.minScrollExtent, pos.maxScrollExtent);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allFiles = widget.manager.managedFiles;

    // Group: platform -> creator -> files
    final byPlatform = <String, Map<String, List<ManagedFile>>>{};
    for (final file in allFiles) {
      final platMap = byPlatform.putIfAbsent(file.platformFolder, () => {});
      platMap.putIfAbsent(file.creatorFolder, () => []).add(file);
    }

    // Reset stale navigation if folder became empty/deleted
    if (_selectedPlatformFolder != null &&
        !byPlatform.containsKey(_selectedPlatformFolder)) {
      _selectedPlatformFolder = null;
      _selectedCreatorFolder = null;
      _isSelectionMode = false;
      _selectedKeys.clear();
    } else if (_selectedPlatformFolder != null &&
        _selectedCreatorFolder != null &&
        !(byPlatform[_selectedPlatformFolder]?.containsKey(_selectedCreatorFolder) ??
            false)) {
      _selectedCreatorFolder = null;
      _isSelectionMode = false;
      _selectedKeys.clear();
    }

    final inCreatorFolder =
        _selectedPlatformFolder != null && _selectedCreatorFolder != null;
    final folderFiles = inCreatorFolder
        ? (byPlatform[_selectedPlatformFolder!]?[_selectedCreatorFolder!] ??
            const <ManagedFile>[])
        : const <ManagedFile>[];
    _activeFolderFiles = folderFiles;

    // Prune any selected keys that no longer exist
    if (_selectedKeys.isNotEmpty && inCreatorFolder) {
      final validKeys = folderFiles.map(_fileKey).toSet();
      _selectedKeys.removeWhere((k) => !validKeys.contains(k));
      if (_selectedKeys.isEmpty && _isSelectionMode) {
        _isSelectionMode = false;
      }
    }

    final selectedFiles = _isSelectionMode
        ? folderFiles.where((f) => _selectedKeys.contains(_fileKey(f))).toList()
        : const <ManagedFile>[];
    final allSelectedInFolder = inCreatorFolder &&
        folderFiles.isNotEmpty &&
        selectedFiles.length == folderFiles.length;

    final canPopFolder =
        _isSelectionMode || _selectedPlatformFolder != null || _selectedCreatorFolder != null;

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
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  _buildAppBar(
                    context,
                    inCreatorFolder: inCreatorFolder,
                    canPopFolder: canPopFolder,
                    selectedCount: selectedFiles.length,
                    allSelected: allSelectedInFolder,
                    folderFiles: folderFiles,
                  ),

                  // Interactive Breadcrumb + View Mode Switcher Bar
                  if (!_isSelectionMode)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: [
                                        _BreadcrumbChip(
                                          label: 'File',
                                          active: _selectedPlatformFolder == null,
                                          onTap: () => setState(() {
                                            _selectedPlatformFolder = null;
                                            _selectedCreatorFolder = null;
                                            _isSelectionMode = false;
                                            _selectedKeys.clear();
                                          }),
                                        ),
                                        if (_selectedPlatformFolder != null) ...[
                                          const Icon(Icons.chevron_right_rounded, size: 18),
                                          _BreadcrumbChip(
                                            label: _selectedPlatformFolder!,
                                            active: _selectedCreatorFolder == null,
                                            onTap: () => setState(() {
                                              _selectedCreatorFolder = null;
                                              _isSelectionMode = false;
                                              _selectedKeys.clear();
                                            }),
                                          ),
                                        ],
                                        if (_selectedCreatorFolder != null) ...[
                                          const Icon(Icons.chevron_right_rounded, size: 18),
                                          _BreadcrumbChip(
                                            label: _selectedCreatorFolder!,
                                            active: true,
                                            onTap: () {},
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                if (inCreatorFolder && folderFiles.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  _ViewModeToggle(
                                    mode: _viewMode,
                                    onChanged: (m) => setState(() => _viewMode = m),
                                  ),
                                ],
                              ],
                            ),
                            if (inCreatorFolder && folderFiles.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                '${folderFiles.length} item • Tahan & geser jari untuk pilih banyak',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
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
                                Icons.folder_copy_outlined,
                                size: 56,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Belum ada folder file',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Media yang diunduh otomatis dipisahkan berdasarkan folder Aplikasi dan Username di dalam all_download.',
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
                  else if (_selectedCreatorFolder == null)
                    _buildCreatorFoldersSliver(
                      _selectedPlatformFolder!,
                      byPlatform[_selectedPlatformFolder!] ?? const {},
                    )
                  else if (_viewMode == _FileViewMode.gallery)
                    _buildFilesGallerySliver(folderFiles)
                  else
                    _buildFilesRowSliver(folderFiles),
                ],
              ),
            ),
          ),

          // Floating Multi-Select Batch Action Bar (Share + Delete)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: 16,
            right: 16,
            bottom: _isSelectionMode && selectedFiles.isNotEmpty ? 14 : -96,
            child: _SelectionBatchBar(
              selectedCount: selectedFiles.length,
              onShare: () => _shareSelectedFiles(selectedFiles),
              onDelete: () => _confirmDeleteMultiple(selectedFiles),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(
    BuildContext context, {
    required bool inCreatorFolder,
    required bool canPopFolder,
    required int selectedCount,
    required bool allSelected,
    required List<ManagedFile> folderFiles,
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
          '$selectedCount dipilih',
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
                    ..addAll(folderFiles.map(_fileKey));
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
        if (inCreatorFolder && folderFiles.isNotEmpty)
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
          childAspectRatio: 1.22,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final name = platformNames[index];
            final creators = byPlatform[name]!;
            final totalFiles = creators.values.fold<int>(
              0,
              (sum, list) => sum + list.length,
            );
            final platform = MediaPlatformMeta.fromKey(name);

            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => setState(() => _selectedPlatformFolder = name),
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
                        '${creators.length} akun • $totalFiles file',
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
  // LEVEL 1: Folders by Username / Creator inside Platform
  // ===========================================================================
  Widget _buildCreatorFoldersSliver(
    String platformFolder,
    Map<String, List<ManagedFile>> byCreator,
  ) {
    final creators = byCreator.keys.toList()
      ..sort((a, b) {
        final aLatest = byCreator[a]!.first.modifiedAt;
        final bLatest = byCreator[b]!.first.modifiedAt;
        return bLatest.compareTo(aLatest);
      });
    final platform = MediaPlatformMeta.fromKey(platformFolder);

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      sliver: SliverList.separated(
        itemCount: creators.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final creator = creators[index];
          final files = byCreator[creator]!;
          final totalSize = files.fold<int>(0, (s, f) => s + f.fileSize);
          final sampleImage = files
              .where((f) => f.mediaKind == MediaKind.image && f.savedPath.isNotEmpty)
              .firstOrNull;

          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 6,
              ),
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
              title: Text(
                creator,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${files.length} file • ${formatBytes(totalSize)}',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => setState(() => _selectedCreatorFolder = creator),
            ),
          );
        },
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
  // LEVEL 2A: GALLERY GRID VIEW (3 columns, drag-to-select, per-tile 3-dot menu)
  // ===========================================================================
  Widget _buildFilesGallerySliver(List<ManagedFile> files) {
    final bottomPad = _isSelectionMode ? 96.0 : 28.0;

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
            final isSelected = _selectedKeys.contains(_fileKey(file));
            return MetaData(
              metaData: _SelectableIndexMeta(index),
              behavior: HitTestBehavior.opaque,
              child: _GalleryFileTile(
                file: file,
                selectionMode: _isSelectionMode,
                selected: isSelected,
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleFileSelection(file);
                  } else {
                    _openPrimaryView(file, files);
                  }
                },
                onMenuAction: (action) => _handleFileMenuAction(action, file, files),
              ),
            );
          },
          childCount: files.length,
        ),
      ),
    );
  }

  // ===========================================================================
  // LEVEL 2B: ROW / LIST VIEW (Detailed info, drag-to-select, per-row 3-dot menu)
  // ===========================================================================
  Widget _buildFilesRowSliver(List<ManagedFile> files) {
    final bottomPad = _isSelectionMode ? 96.0 : 28.0;
    final theme = Theme.of(context);

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(14, 2, 14, bottomPad),
      sliver: SliverList.separated(
        itemCount: files.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final file = files[index];
          final isSelected = _selectedKeys.contains(_fileKey(file));

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
                    _toggleFileSelection(file);
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
                            Text(
                              '${file.extension} • ${formatBytes(file.fileSize)} • ${_fmtDate(file.modifiedAt)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!_isSelectionMode)
                        _FilePopupMenu(
                          isImage: file.mediaKind == MediaKind.image,
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
  Future<void> _openPrimaryView(ManagedFile file, List<ManagedFile> folderFiles) async {
    if (file.mediaKind == MediaKind.image && file.savedPath.isNotEmpty) {
      final folderImages = folderFiles
          .where((f) => f.mediaKind == MediaKind.image && f.savedPath.isNotEmpty)
          .toList(growable: false);
      final idx = folderImages.indexWhere((f) => _fileKey(f) == _fileKey(file));
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
      case _FileMenuAction.openExternal:
        await _openExternalFile(file);
        break;
      case _FileMenuAction.share:
        await widget.manager.shareManagedFile(file);
        break;
      case _FileMenuAction.select:
        _enterSelectionWith(file);
        break;
      case _FileMenuAction.info:
        _showFileInfoSheet(file);
        break;
      case _FileMenuAction.delete:
        await _confirmDeleteSingle(file);
        break;
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

  Future<void> _confirmDeleteSingle(ManagedFile file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus File?'),
        content: Text('Hapus permanen "${file.fileName}" dari perangkat?'),
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
    if (ok == true) {
      await widget.manager.deleteManagedFile(file);
    }
  }

  Future<void> _confirmDeleteMultiple(List<ManagedFile> selected) async {
    if (selected.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus ${selected.length} File?'),
        content: Text(
          'Hapus permanen ${selected.length} media terpilih dari perangkat? Tindakan ini tidak dapat dibatalkan.',
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
            child: const Text('Hapus Semua'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final deleted = await widget.manager.deleteMultipleManagedFiles(selected);
    if (!mounted) return;
    _exitSelectionMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$deleted file berhasil dihapus.')),
    );
  }

  void _showFileInfoSheet(ManagedFile file) {
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
              _InfoRow(label: 'Nama', value: file.fileName),
              _InfoRow(
                label: 'Folder',
                value: '${file.platformFolder} / ${file.creatorFolder}',
              ),
              _InfoRow(label: 'Ukuran', value: formatBytes(file.fileSize)),
              _InfoRow(label: 'Tipe', value: file.mimeType),
              _InfoRow(label: 'Tanggal', value: _fmtDate(file.modifiedAt)),
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

class _GalleryFileTile extends StatelessWidget {
  final ManagedFile file;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final void Function(_FileMenuAction action) onMenuAction;

  const _GalleryFileTile({
    required this.file,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onMenuAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isImage = file.mediaKind == MediaKind.image && file.savedPath.isNotEmpty;

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

              // Subtle dim when selected or in selection mode
              if (selected)
                Container(
                  color: theme.colorScheme.primary.withValues(alpha: 0.16),
                ),

              // Bottom label for videos / audios / extensions
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

              // Media type pill on top-left for videos/audio
              if (!selectionMode && file.mediaKind != MediaKind.image)
                Positioned(
                  top: 5,
                  left: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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

              // Top-right: either Selection Checkbox OR 3-dot Menu button
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
  final bool compactOverlay;
  final void Function(_FileMenuAction action) onSelected;

  const _FilePopupMenu({
    required this.isImage,
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
            tooltip: 'Mode Galeri',
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
  final int selectedCount;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  const _SelectionBatchBar({
    required this.selectedCount,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(18),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: onShare,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.share_rounded, size: 19),
                label: Text(
                  'Bagikan ($selectedCount)',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: onDelete,
                style: FilledButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  backgroundColor: theme.colorScheme.error.withValues(alpha: 0.14),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
                label: Text(
                  'Hapus ($selectedCount)',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
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
