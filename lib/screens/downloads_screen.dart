import 'package:flutter/material.dart';

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

class _DownloadsScreenState extends State<DownloadsScreen> {
  final ScrollController _scrollController = ScrollController();
  _LibraryFilter _filter = _LibraryFilter.all;
  String _search = '';
  late int _sectionIndex;

  @override
  void initState() {
    super.initState();
    final hasLoading = widget.manager.items.any(isLoadingHistoryItem);
    _sectionIndex = widget.sectionNotifier?.value ?? (hasLoading ? 0 : 1);
    widget.sectionNotifier?.addListener(_onExternalSectionChanged);
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
    _scrollController.dispose();
    super.dispose();
  }

  void _onExternalSectionChanged() {
    final next = widget.sectionNotifier?.value;
    if (next != null && next != _sectionIndex && mounted) {
      setState(() => _sectionIndex = next);
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
    setState(() => _sectionIndex = next);
    if (widget.sectionNotifier != null && widget.sectionNotifier!.value != next) {
      widget.sectionNotifier!.value = next;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToTop(animate: false);
    });
  }

  bool _matchesFilterAndSearch(DownloadItem item) {
    final matchesFilter = switch (_filter) {
      _LibraryFilter.all => true,
      _LibraryFilter.video => item.mediaKind == MediaKind.video,
      _LibraryFilter.audio => item.mediaKind == MediaKind.audio,
      _LibraryFilter.image => item.mediaKind == MediaKind.image,
    };
    if (!matchesFilter) return false;
    if (_search.trim().isEmpty) return true;
    final q = _search.toLowerCase();
    return item.title.toLowerCase().contains(q) ||
        item.author.toLowerCase().contains(q) ||
        item.platform.label.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allItems = widget.manager.items;

    final allLoading = allItems.where(isLoadingHistoryItem).toList(growable: false);
    final allFinished =
        allItems.where((i) => !isLoadingHistoryItem(i)).toList(growable: false);

    final filteredLoading = sortLoadingDownloads(
      allLoading.where(_matchesFilterAndSearch).toList(growable: false),
    );
    final filteredFinished =
        allFinished.where(_matchesFilterAndSearch).toList(growable: false);

    final processingItems = filteredLoading
        .where((i) =>
            i.status == DownloadStatus.saving ||
            i.status == DownloadStatus.downloading)
        .toList(growable: false);
    final queuedItems = filteredLoading
        .where((i) => i.status == DownloadStatus.queued)
        .toList(growable: false);
    final pausedItems = filteredLoading
        .where((i) => i.status == DownloadStatus.paused)
        .toList(growable: false);
    final failedItems = filteredLoading
        .where((i) => i.status == DownloadStatus.failed)
        .toList(growable: false);

    final activeCount = widget.manager.activeDownloads.length;
    final pausedCount = widget.manager.pausedDownloads.length;
    final isLoadingTab = _sectionIndex == 0;
    final currentTotalCount = isLoadingTab ? allLoading.length : allFinished.length;
    final currentEmpty =
        isLoadingTab ? filteredLoading.isEmpty : filteredFinished.isEmpty;

    return Scrollbar(
      controller: _scrollController,
      interactive: true,
      thumbVisibility: true,
      thickness: 4.5,
      radius: const Radius.circular(8),
      child: CustomScrollView(
        controller: _scrollController,
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
            if (allFinished.isNotEmpty)
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
            loadingCount: allLoading.length,
            finishedCount: allFinished.length,
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
                  onChanged: (v) => setState(() => _search = v),
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
                        onTap: () => setState(() => _filter = _LibraryFilter.all),
                      ),
                      const SizedBox(width: 8),
                      _FilterPill(
                        label: 'Video',
                        selected: _filter == _LibraryFilter.video,
                        onTap: () => setState(() => _filter = _LibraryFilter.video),
                      ),
                      const SizedBox(width: 8),
                      _FilterPill(
                        label: 'Audio',
                        selected: _filter == _LibraryFilter.audio,
                        onTap: () => setState(() => _filter = _LibraryFilter.audio),
                      ),
                      const SizedBox(width: 8),
                      _FilterPill(
                        label: 'Foto',
                        selected: _filter == _LibraryFilter.image,
                        onTap: () => setState(() => _filter = _LibraryFilter.image),
                      ),
                    ],
                  ),
                ),
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
              queuedItems,
              bottomPad: (pausedItems.isEmpty && failedItems.isEmpty)
                  ? 28.0
                  : 12.0,
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
              pausedItems,
              bottomPad: failedItems.isEmpty ? 28.0 : 12.0,
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
            _buildItemsSliver(failedItems, bottomPad: 28.0),
          ],
        ] else
          _buildItemsSliver(filteredFinished, bottomPad: 28.0),
      ],
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
      sliver: SliverList.separated(
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = items[index];
          final markerKey = item.markerKey.isNotEmpty
              ? item.markerKey
              : canonicalMarkerKey(item.sourceUrl);
          return DownloadTile(
            item: item,
            isMarkedDownloaded: widget.manager.isMarkedDownloaded(markerKey),
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
          );
        },
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
