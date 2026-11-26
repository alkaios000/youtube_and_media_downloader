import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/download_item.dart';
import '../models/media_info.dart';
import '../models/media_platform.dart';
import '../services/download_manager.dart';
import '../widgets/download_detail_sheet.dart';
import '../widgets/download_tile.dart';

enum _LibraryFilter { all, video, audio, image }

/// Whether [item] belongs to the "Berjalan / Loading" section of Riwayat.
/// Failed downloads stay at the very bottom of Loading (never inside Selesai).
bool isLoadingHistoryItem(DownloadItem item) =>
    item.isActive || item.isPaused || item.status == DownloadStatus.failed;

int _loadingPriority(DownloadStatus status) {
  switch (status) {
    case DownloadStatus.saving:
      return 0;
    case DownloadStatus.downloading:
      return 1;
    case DownloadStatus.queued:
      return 2;
    case DownloadStatus.paused:
      return 3;
    case DownloadStatus.failed:
      return 4;
    case DownloadStatus.completed:
    case DownloadStatus.cancelled:
      return 5;
  }
}

/// Orders loading items so actively processing downloads (`saving` / `downloading`)
/// ALWAYS stay at the very top, followed by `queued` and `paused`, while preserving
/// stable relative order within each group.
List<DownloadItem> sortLoadingDownloads(List<DownloadItem> items) {
  final indexed = items.asMap().entries.toList(growable: false);
  indexed.sort((a, b) {
    final pa = _loadingPriority(a.value.status);
    final pb = _loadingPriority(b.value.status);
    if (pa != pb) return pa.compareTo(pb);
    return a.key.compareTo(b.key);
  });
  return indexed.map((e) => e.value).toList(growable: false);
}

class DownloadsScreen extends StatefulWidget {
  final DownloadManager manager;

  /// Optional controller: `0` = Berjalan (loading), `1` = Selesai.
  final ValueNotifier<int>? sectionNotifier;

  const DownloadsScreen({
    super.key,
    required this.manager,
    this.sectionNotifier,
  });

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _HistoryBucketSnapshot {
  final int totalLoadingCount;
  final int totalFinishedCount;
  final List<DownloadItem> processing;
  final List<DownloadItem> queued;
  final List<DownloadItem> paused;
  final List<DownloadItem> failed;
  final List<DownloadItem> finished;

  const _HistoryBucketSnapshot({
    required this.totalLoadingCount,
    required this.totalFinishedCount,
    required this.processing,
    required this.queued,
    required this.paused,
    required this.failed,
    required this.finished,
  });

  int get filteredLoadingCount =>
      processing.length + queued.length + paused.length + failed.length;
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  static const int _initialGroupWindow = 40;
  static const int _initialFinishedWindow = 60;
  static const int _batchExpandStep = 60;
  static const int _loadBalancerThreshold = 80;

  final ScrollController _scrollController = ScrollController();
  _LibraryFilter _filter = _LibraryFilter.all;
  String _search = '';
  late int _sectionIndex;

  // Windowed batch render limits so even 5,000+ queued/completed items stay silky & crash-free
  int _queuedLimit = _initialGroupWindow;
  int _pausedLimit = _initialGroupWindow;
  int _failedLimit = _initialGroupWindow;
  int _finishedLimit = _initialFinishedWindow;
  DateTime _lastAutoExpandAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Memoized single-pass bucket cache keyed by revision + filter + search
  int _cachedRevision = -1;
  int _cachedItemsLength = -1;
  _LibraryFilter? _cachedFilter;
  String? _cachedSearch;
  _HistoryBucketSnapshot? _cachedSnapshot;

  @override
  void initState() {
    super.initState();
    final hasLoading = widget.manager.items.any(isLoadingHistoryItem);
    _sectionIndex = widget.sectionNotifier?.value ?? (hasLoading ? 0 : 1);
    widget.sectionNotifier?.addListener(_onExternalSectionChanged);
    _scrollController.addListener(_onScrollAutoLoad);
  }

  @override
  void didUpdateWidget(covariant DownloadsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sectionNotifier != widget.sectionNotifier) {
      oldWidget.sectionNotifier?.removeListener(_onExternalSectionChanged);
      widget.sectionNotifier?.addListener(_onExternalSectionChanged);
      if (widget.sectionNotifier != null) {
        _sectionIndex = widget.sectionNotifier!.value;
      }
    }
  }

  @override
  void dispose() {
    widget.sectionNotifier?.removeListener(_onExternalSectionChanged);
    _scrollController.removeListener(_onScrollAutoLoad);
    _scrollController.dispose();
    super.dispose();
  }

  void _resetRenderWindows() {
    _queuedLimit = _initialGroupWindow;
    _pausedLimit = _initialGroupWindow;
    _failedLimit = _initialGroupWindow;
    _finishedLimit = _initialFinishedWindow;
  }

  void _onScrollAutoLoad() {
    if (!mounted || _sectionIndex != 1 || !_scrollController.hasClients) return;
    final snap = _cachedSnapshot;
    if (snap == null || _finishedLimit >= snap.finished.length) return;
    final pos = _scrollController.position;
    if (!pos.hasPixels || !pos.hasContentDimensions) return;
    if (pos.maxScrollExtent - pos.pixels > 520) return;
    final now = DateTime.now();
    if (now.difference(_lastAutoExpandAt) < const Duration(milliseconds: 220)) {
      return;
    }
    _lastAutoExpandAt = now;
    setState(() {
      _finishedLimit = (_finishedLimit + _batchExpandStep)
          .clamp(_initialFinishedWindow, snap.finished.length);
    });
  }

  void _onExternalSectionChanged() {
    final next = widget.sectionNotifier?.value;
    if (next != null && next != _sectionIndex && mounted) {
      setState(() {
        _sectionIndex = next;
        _resetRenderWindows();
      });
    }
  }

  void _scrollToTop({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    if (_scrollController.offset <= 0) return;
    if (animate) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(0);
    }
  }

  void _selectSection(int next) {
    if (_sectionIndex == next) {
      _scrollToTop(animate: true);
      return;
    }
    setState(() {
      _sectionIndex = next;
      _resetRenderWindows();
    });
    if (widget.sectionNotifier != null && widget.sectionNotifier!.value != next) {
      widget.sectionNotifier!.value = next;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToTop(animate: false);
    });
  }

  bool _matchesFilterAndSearch(DownloadItem item, String normalizedQuery) {
    final matchesFilter = switch (_filter) {
      _LibraryFilter.all => true,
      _LibraryFilter.video => item.mediaKind == MediaKind.video,
      _LibraryFilter.audio => item.mediaKind == MediaKind.audio,
      _LibraryFilter.image => item.mediaKind == MediaKind.image,
    };
    if (!matchesFilter) return false;
    if (normalizedQuery.isEmpty) return true;
    return item.title.toLowerCase().contains(normalizedQuery) ||
        item.author.toLowerCase().contains(normalizedQuery) ||
        item.platform.label.toLowerCase().contains(normalizedQuery);
  }

  /// Single-pass O(N) bucketing cached by (revision, length, filter, search)
  /// so scrolling or batch expansion does zero redundant work even at 5,000+ items.
  _HistoryBucketSnapshot _resolveSnapshot() {
    final rev = widget.manager.itemsRevision;
    final allItems = widget.manager.items;
    if (_cachedSnapshot != null &&
        _cachedRevision == rev &&
        _cachedItemsLength == allItems.length &&
        _cachedFilter == _filter &&
        _cachedSearch == _search) {
      return _cachedSnapshot!;
    }

    final normalizedQuery = _search.trim().toLowerCase();
    var totalLoading = 0;
    var totalFinished = 0;
    final saving = <DownloadItem>[];
    final downloading = <DownloadItem>[];
    final queued = <DownloadItem>[];
    final paused = <DownloadItem>[];
    final failed = <DownloadItem>[];
    final finished = <DownloadItem>[];

    for (final item in allItems) {
      final isLoading = isLoadingHistoryItem(item);
      if (isLoading) {
        totalLoading++;
      } else {
        totalFinished++;
      }
      if (!_matchesFilterAndSearch(item, normalizedQuery)) continue;

      if (isLoading) {
        switch (item.status) {
          case DownloadStatus.saving:
            saving.add(item);
            break;
          case DownloadStatus.downloading:
            downloading.add(item);
            break;
          case DownloadStatus.queued:
            queued.add(item);
            break;
          case DownloadStatus.paused:
            paused.add(item);
            break;
          case DownloadStatus.failed:
            failed.add(item);
            break;
          case DownloadStatus.completed:
          case DownloadStatus.cancelled:
            break;
        }
      } else {
        finished.add(item);
      }
    }

    final processing = saving.isEmpty
        ? downloading
        : (downloading.isEmpty ? saving : [...saving, ...downloading]);

    final snap = _HistoryBucketSnapshot(
      totalLoadingCount: totalLoading,
      totalFinishedCount: totalFinished,
      processing: processing,
      queued: queued,
      paused: paused,
      failed: failed,
      finished: finished,
    );
    _cachedRevision = rev;
    _cachedItemsLength = allItems.length;
    _cachedFilter = _filter;
    _cachedSearch = _search;
    _cachedSnapshot = snap;
    return snap;
  }

  List<DownloadItem> _sliceWindow(List<DownloadItem> source, int limit) {
    if (source.length <= limit) return source;
    return source.sublist(0, limit);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snap = _resolveSnapshot();

    final processingItems = snap.processing;
    final queuedItems = snap.queued;
    final pausedItems = snap.paused;
    final failedItems = snap.failed;
    final filteredFinished = snap.finished;

    final visibleQueued = _sliceWindow(queuedItems, _queuedLimit);
    final visiblePaused = _sliceWindow(pausedItems, _pausedLimit);
    final visibleFailed = _sliceWindow(failedItems, _failedLimit);
    final visibleFinished = _sliceWindow(filteredFinished, _finishedLimit);

    final activeCount = widget.manager.activeDownloadCount;
    final pausedCount = widget.manager.pausedDownloadCount;
    final isLoadingTab = _sectionIndex == 0;
    final currentTotalCount =
        isLoadingTab ? snap.totalLoadingCount : snap.totalFinishedCount;
    final currentFilteredCount =
        isLoadingTab ? snap.filteredLoadingCount : filteredFinished.length;
    final currentVisibleCount = isLoadingTab
        ? processingItems.length +
            visibleQueued.length +
            visiblePaused.length +
            visibleFailed.length
        : visibleFinished.length;
    final currentEmpty = currentFilteredCount == 0;
    final isLoadBalancerActive = currentFilteredCount >= _loadBalancerThreshold;
    final canCompactWindow = isLoadingTab
        ? (_queuedLimit > _initialGroupWindow ||
            _pausedLimit > _initialGroupWindow ||
            _failedLimit > _initialGroupWindow)
        : (_finishedLimit > _initialFinishedWindow);

    return Scrollbar(
      controller: _scrollController,
      interactive: true,
      thumbVisibility: true,
      thickness: 4.5,
      radius: const Radius.circular(8),
      child: CustomScrollView(
        controller: _scrollController,
        scrollCacheExtent: const ScrollCacheExtent.pixels(360),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
        SliverAppBar(
          floating: true,
          title: const Text('Riwayat Unduhan'),
          actions: [
            if (activeCount > 0)
              IconButton(
                onPressed: widget.manager.pauseAllDownloads,
                icon: const Icon(Icons.pause_circle_outline_rounded),
                tooltip: 'Jeda Semua ($activeCount)',
              ),
            if (pausedCount > 0)
              IconButton(
                onPressed: widget.manager.resumeAllPaused,
                icon: const Icon(
                  Icons.play_circle_outline_rounded,
                  color: Color(0xFFF59E0B),
                ),
                tooltip: 'Lanjut Semua ($pausedCount)',
              ),
            if (snap.totalFinishedCount > 0)
              IconButton(
                onPressed: _confirmClearHistory,
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: 'Bersihkan riwayat selesai',
              ),
          ],
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickyHistoryTabsDelegate(
            backgroundColor: theme.scaffoldBackgroundColor,
            loadingCount: snap.totalLoadingCount,
            finishedCount: snap.totalFinishedCount,
            selectedIndex: _sectionIndex,
            onTapSection: _selectSection,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  onChanged: (v) => setState(() {
                    _search = v;
                    _resetRenderWindows();
                  }),
                  decoration: const InputDecoration(
                    hintText: 'Cari judul, kreator, atau platform...',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterPill(
                        label: 'Semua ($currentTotalCount)',
                        selected: _filter == _LibraryFilter.all,
                        onTap: () => setState(() {
                          _filter = _LibraryFilter.all;
                          _resetRenderWindows();
                        }),
                      ),
                      const SizedBox(width: 8),
                      _FilterPill(
                        label: 'Video',
                        selected: _filter == _LibraryFilter.video,
                        onTap: () => setState(() {
                          _filter = _LibraryFilter.video;
                          _resetRenderWindows();
                        }),
                      ),
                      const SizedBox(width: 8),
                      _FilterPill(
                        label: 'Audio',
                        selected: _filter == _LibraryFilter.audio,
                        onTap: () => setState(() {
                          _filter = _LibraryFilter.audio;
                          _resetRenderWindows();
                        }),
                      ),
                      const SizedBox(width: 8),
                      _FilterPill(
                        label: 'Foto',
                        selected: _filter == _LibraryFilter.image,
                        onTap: () => setState(() {
                          _filter = _LibraryFilter.image;
                          _resetRenderWindows();
                        }),
                      ),
                    ],
                  ),
                ),
                if (isLoadBalancerActive) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.memory_rounded,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            'Load Balancer Aktif • menampilkan $currentVisibleCount dari $currentFilteredCount item',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (canCompactWindow)
                          TextButton(
                            onPressed: () {
                              setState(_resetRenderWindows);
                              _scrollToTop(animate: true);
                            },
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              'Ringkas',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (isLoadingTab && pausedCount > 0) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.pause_circle_filled_rounded,
                          size: 18,
                          color: Color(0xFFF59E0B),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$pausedCount unduhan terjeda siap dilanjutkan',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFFF59E0B),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: widget.manager.resumeAllPaused,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 17),
                          label: const Text('Lanjut Semua'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (currentEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isLoadingTab
                          ? Icons.downloading_rounded
                          : Icons.folder_open_rounded,
                      size: 56,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      currentTotalCount == 0
                          ? (isLoadingTab
                              ? 'Tidak ada unduhan yang sedang berjalan'
                              : 'Belum ada unduhan yang selesai')
                          : 'Tidak ada hasil yang cocok',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      currentTotalCount == 0
                          ? (isLoadingTab
                              ? 'Semua unduhan aktif, antrean, dan yang dijeda akan muncul di sini dengan proses aktif di urutan teratas.'
                              : 'Media yang selesai diunduh akan tersimpan rapi di sini.')
                          : 'Coba ubah kata kunci pencarian atau filter kategori.',
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
        else if (isLoadingTab) ...[
          if (processingItems.isNotEmpty) ...[
            _buildSectionHeaderSliver(
              context,
              title: 'Sedang Diproses (${processingItems.length})',
              color: const Color(0xFF38BDF8),
              icon: Icons.bolt_rounded,
            ),
            _buildItemsSliver(
              processingItems,
              bottomPad: (queuedItems.isEmpty &&
                      pausedItems.isEmpty &&
                      failedItems.isEmpty)
                  ? 28.0
                  : 12.0,
            ),
          ],
          if (queuedItems.isNotEmpty) ...[
            _buildSectionHeaderSliver(
              context,
              title: 'Antrean (${queuedItems.length})',
              color: theme.colorScheme.onSurfaceVariant,
              icon: Icons.schedule_rounded,
            ),
            _buildItemsSliver(
              visibleQueued,
              bottomPad: (visibleQueued.length < queuedItems.length)
                  ? 6.0
                  : ((pausedItems.isEmpty && failedItems.isEmpty) ? 28.0 : 12.0),
            ),
            if (visibleQueued.length < queuedItems.length ||
                _queuedLimit > _initialGroupWindow)
              _buildBatchWindowFooterSliver(
                context,
                shown: visibleQueued.length,
                total: queuedItems.length,
                label: 'antrean',
                canCollapse: _queuedLimit > _initialGroupWindow,
                bottomPad:
                    (pausedItems.isEmpty && failedItems.isEmpty) ? 28.0 : 12.0,
                onLoadMore: () => setState(() {
                  _queuedLimit = (_queuedLimit + _batchExpandStep)
                      .clamp(_initialGroupWindow, queuedItems.length);
                }),
                onCollapse: () => setState(() {
                  _queuedLimit = _initialGroupWindow;
                }),
              ),
          ],
          if (pausedItems.isNotEmpty) ...[
            _buildSectionHeaderSliver(
              context,
              title: 'Dijeda (${pausedItems.length})',
              color: const Color(0xFFF59E0B),
              icon: Icons.pause_circle_outline_rounded,
            ),
            _buildItemsSliver(
              visiblePaused,
              bottomPad: (visiblePaused.length < pausedItems.length)
                  ? 6.0
                  : (failedItems.isEmpty ? 28.0 : 12.0),
            ),
            if (visiblePaused.length < pausedItems.length ||
                _pausedLimit > _initialGroupWindow)
              _buildBatchWindowFooterSliver(
                context,
                shown: visiblePaused.length,
                total: pausedItems.length,
                label: 'terjeda',
                canCollapse: _pausedLimit > _initialGroupWindow,
                bottomPad: failedItems.isEmpty ? 28.0 : 12.0,
                onLoadMore: () => setState(() {
                  _pausedLimit = (_pausedLimit + _batchExpandStep)
                      .clamp(_initialGroupWindow, pausedItems.length);
                }),
                onCollapse: () => setState(() {
                  _pausedLimit = _initialGroupWindow;
                }),
              ),
          ],
          if (failedItems.isNotEmpty) ...[
            _buildSectionHeaderSliver(
              context,
              title: 'Gagal (${failedItems.length})',
              color: theme.colorScheme.error,
              icon: Icons.error_outline_rounded,
              trailingAction: TextButton.icon(
                onPressed: widget.manager.retryAllFailed,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('Coba Semua'),
              ),
            ),
            _buildItemsSliver(
              visibleFailed,
              bottomPad: (visibleFailed.length < failedItems.length ||
                      _failedLimit > _initialGroupWindow)
                  ? 6.0
                  : 28.0,
            ),
            if (visibleFailed.length < failedItems.length ||
                _failedLimit > _initialGroupWindow)
              _buildBatchWindowFooterSliver(
                context,
                shown: visibleFailed.length,
                total: failedItems.length,
                label: 'gagal',
                canCollapse: _failedLimit > _initialGroupWindow,
                bottomPad: 28.0,
                onLoadMore: () => setState(() {
                  _failedLimit = (_failedLimit + _batchExpandStep)
                      .clamp(_initialGroupWindow, failedItems.length);
                }),
                onCollapse: () => setState(() {
                  _failedLimit = _initialGroupWindow;
                }),
              ),
          ],
        ] else ...[
          _buildItemsSliver(
            visibleFinished,
            bottomPad: visibleFinished.length < filteredFinished.length
                ? 8.0
                : 28.0,
          ),
          if (visibleFinished.length < filteredFinished.length)
            _buildBatchWindowFooterSliver(
              context,
              shown: visibleFinished.length,
              total: filteredFinished.length,
              label: 'selesai',
              canCollapse: _finishedLimit > _initialFinishedWindow,
              bottomPad: 28.0,
              onLoadMore: () => setState(() {
                _finishedLimit = (_finishedLimit + _batchExpandStep)
                    .clamp(_initialFinishedWindow, filteredFinished.length);
              }),
              onCollapse: () {
                setState(() => _finishedLimit = _initialFinishedWindow);
                _scrollToTop(animate: true);
              },
            ),
        ],
      ],
      ),
    );
  }

  Widget _buildBatchWindowFooterSliver(
    BuildContext context, {
    required int shown,
    required int total,
    required String label,
    required bool canCollapse,
    required double bottomPad,
    required VoidCallback onLoadMore,
    required VoidCallback onCollapse,
  }) {
    final theme = Theme.of(context);
    final remaining = total - shown;
    final nextStep =
        remaining > _batchExpandStep ? _batchExpandStep : remaining;

    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, bottomPad),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  remaining > 0
                      ? 'Menampilkan $shown dari $total $label ($remaining tersisa)'
                      : 'Menampilkan semua $total $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (canCollapse) ...[
                const SizedBox(width: 6),
                TextButton(
                  onPressed: onCollapse,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('Ringkas'),
                ),
              ],
              if (remaining > 0) ...[
                const SizedBox(width: 6),
                FilledButton.tonal(
                  onPressed: onLoadMore,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                  ),
                  child: Text('Muat +$nextStep'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeaderSliver(
    BuildContext context, {
    required String title,
    required Color color,
    required IconData icon,
    Widget? trailingAction,
  }) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 14, 6),
        child: Row(
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
              ),
            ),
            ?trailingAction,
          ],
        ),
      ),
    );
  }

  Widget _buildItemsSliver(
    List<DownloadItem> items, {
    required double bottomPad,
  }) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, 2, 16, bottomPad),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = items[index];
            final markerKey = item.markerKey.isNotEmpty
                ? item.markerKey
                : canonicalMarkerKey(item.sourceUrl);
            return Padding(
              padding: EdgeInsets.only(
                bottom: index == items.length - 1 ? 0 : 10,
              ),
              child: DownloadTile(
                key: ValueKey<String>(item.id),
                item: item,
                isMarkedDownloaded:
                    widget.manager.isMarkedDownloaded(markerKey),
                onTapDetail: () => showDownloadDetailSheet(
                  context,
                  manager: widget.manager,
                  itemId: item.id,
                ),
                onPause: item.isActive
                    ? () => widget.manager.pauseDownload(item.id)
                    : null,
                onResume: item.canResume
                    ? () => widget.manager.resumeDownload(item.id)
                    : null,
                onCancel: (item.isActive || item.isPaused)
                    ? () => widget.manager.cancelDownload(item.id)
                    : null,
                onOpen: () => _openFile(item),
                onShare: () => widget.manager.shareDownloadedItem(item),
                onDelete: () => _confirmDeleteItem(item),
              ),
            );
          },
          childCount: items.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
        ),
      ),
    );
  }

  Future<void> _openFile(DownloadItem item) async {
    final ok = await widget.manager.openDownloadedItem(item);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File tidak ditemukan atau tidak ada aplikasi pemutar yang cocok.'),
        ),
      );
    }
  }

  Future<void> _confirmDeleteItem(DownloadItem item) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Item'),
        content: Text(
          'Hapus "${item.title}" dari daftar riwayat saja, atau hapus juga file dari penyimpanan perangkat?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'history'),
            child: const Text('Riwayat Saja'),
          ),
          if (item.status == DownloadStatus.completed)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'device'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              child: const Text('Hapus File'),
            ),
        ],
      ),
    );

    if (action == 'history') {
      await widget.manager.removeHistoryItem(item, deleteFromDevice: false);
    } else if (action == 'device') {
      await widget.manager.removeHistoryItem(item, deleteFromDevice: true);
    }
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bersihkan Riwayat?'),
        content: const Text(
          'Daftar riwayat akan dikosongkan. File yang sudah tersimpan di folder Pictures/all_download (Album all_download) tetap aman.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Bersihkan'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.manager.clearAllHistory();
    }
  }
}

class _StickyHistoryTabsDelegate extends SliverPersistentHeaderDelegate {
  final Color backgroundColor;
  final int loadingCount;
  final int finishedCount;
  final int selectedIndex;
  final ValueChanged<int> onTapSection;

  const _StickyHistoryTabsDelegate({
    required this.backgroundColor,
    required this.loadingCount,
    required this.finishedCount,
    required this.selectedIndex,
    required this.onTapSection,
  });

  @override
  double get minExtent => 56;

  @override
  double get maxExtent => 56;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Material(
      color: backgroundColor,
      elevation: overlapsContent ? 2 : 0,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF172033)
                : theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: _StickyTabButton(
                  icon: Icons.downloading_rounded,
                  label: 'Berjalan ($loadingCount)',
                  selected: selectedIndex == 0,
                  onTap: () => onTapSection(0),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _StickyTabButton(
                  icon: Icons.check_circle_outline_rounded,
                  label: 'Selesai ($finishedCount)',
                  selected: selectedIndex == 1,
                  onTap: () => onTapSection(1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickyHistoryTabsDelegate oldDelegate) {
    return backgroundColor != oldDelegate.backgroundColor ||
        loadingCount != oldDelegate.loadingCount ||
        finishedCount != oldDelegate.finishedCount ||
        selectedIndex != oldDelegate.selectedIndex;
  }
}

class _StickyTabButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _StickyTabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected ? theme.colorScheme.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected
                    ? Colors.white
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected
                        ? Colors.white
                        : theme.colorScheme.onSurfaceVariant,
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

class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
    );
  }
}
