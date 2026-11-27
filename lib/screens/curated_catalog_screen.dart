import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_metadata.dart';
import '../models/media_platform.dart';
import '../services/download_manager.dart';
import '../widgets/app_feedback.dart';
import '../widgets/route_aware_listener.dart';

/// Curated Keep-Only Catalog ("Katalog Kurasi"):
/// - Records ONLY the photos/pages the user actually kept (never deleted or
///   skipped items).
/// - Deleted & excluded works stay marked as finished in `downloadedMarkers`
///   so they are NEVER re-downloaded.
/// - After accidental wipe or switching phones, 1 tap selectively re-downloads
///   ONLY the missing kept photos/pages with exact original filenames (so
///   manual Ecchi/NSFW ratings & album tags re-attach automatically!).
class CuratedCatalogScreen extends StatefulWidget {
  final DownloadManager manager;

  const CuratedCatalogScreen({
    super.key,
    required this.manager,
  });

  @override
  State<CuratedCatalogScreen> createState() => _CuratedCatalogScreenState();
}

class _CuratedCatalogScreenState extends State<CuratedCatalogScreen> {
  static const int _windowStep = 100;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  String _searchQuery = '';
  bool _onlyMissing = false;
  bool _isSyncing = false;
  bool _isRestoring = false;
  int _visibleLimit = _windowStep;
  int _totalFilteredCount = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_visibleLimit >= _totalFilteredCount) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 700) {
      setState(() {
        _visibleLimit =
            math.min(_totalFilteredCount, _visibleLimit + _windowStep);
      });
    }
  }

  Future<void> _syncWithDevice() async {
    if (_isSyncing) return;
    HapticFeedback.selectionClick();
    setState(() => _isSyncing = true);
    try {
      final res = await widget.manager.syncCuratedCatalogWithDeviceFiles(
        refreshFirst: true,
      );
      if (!mounted) return;
      if (res.skippedPruneBecauseDeviceEmpty) {
        showTopToast(
          context,
          'File di perangkat masih kosong — Katalog (${res.totalKeptFiles} foto) tetap aman untuk dipulihkan.',
          icon: Icons.shield_outlined,
        );
      } else {
        showTopToast(
          context,
          'Sinkron selesai: +${res.addedFiles} dicatat, -${res.prunedFiles} dihapus • Total ${res.totalKeptFiles} foto (${res.totalKeptWorks} album).',
          icon: Icons.sync_rounded,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showTopToast(
        context,
        'Gagal sinkronisasi katalog: $e',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _confirmAndRestore({
    required int missingFilesCount,
    required int missingWorksCount,
    required int excludedCount,
    String? creatorFolder,
    String? singleMarkerKey,
    String? label,
  }) async {
    if (_isRestoring || missingFilesCount <= 0) return;
    final scopeTitle = label ??
        (creatorFolder != null
            ? 'Pulihkan koleksi $creatorFolder?'
            : 'Pulihkan Foto Katalog Kurasi?');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(scopeTitle),
        content: Text(
          'Hanya $missingFilesCount foto pilihan dari $missingWorksCount album yang tercatat di Katalog Kurasi yang akan diunduh ulang.\n\n'
          '$excludedCount album/item yang pernah Anda hapus atau lewati TIDAK akan diunduh dan tetap dianggap selesai.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.cloud_download_rounded, size: 18),
            label: Text('Unduh $missingFilesCount Foto'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    HapticFeedback.mediumImpact();
    setState(() => _isRestoring = true);
    try {
      final queued = await widget.manager.restoreMissingCuratedWorks(
        creatorFolder: creatorFolder,
        singleMarkerKey: singleMarkerKey,
      );
      if (!mounted) return;
      if (queued > 0) {
        showTopToast(
          context,
          'Memulihkan $queued foto terpilih — pantau progres di tab Riwayat.',
          icon: Icons.cloud_download_rounded,
        );
      } else {
        showTopToast(
          context,
          'Semua foto pilihan sudah lengkap di perangkat.',
          icon: Icons.check_circle_outline_rounded,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showTopToast(
        context,
        'Gagal memulai pemulihan: $e',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isRestoring = false);
    }
  }

  Future<void> _exportBackup() async {
    try {
      final ok = await widget.manager.exportBackupToFile();
      if (!mounted) return;
      if (ok) {
        showTopToast(
          context,
          'Backup JSON (termasuk Katalog Kurasi) berhasil diekspor.',
          icon: Icons.file_upload_outlined,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showTopToast(
        context,
        'Gagal mengekspor backup: $e',
        isError: true,
      );
    }
  }

  void _showWorkDetailsSheet(CuratedWorkRecord work, int missingCount) {
    final missingNames = widget.manager
        .getMissingFilesForCuratedWork(work)
        .map((e) => e.normalizedFileName)
        .toSet();
    final platform = MediaPlatformMeta.fromKey(work.platformFolder);

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.72,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: platform.brandColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          platform.icon,
                          color: platform.brandColor,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              work.albumFolder.isNotEmpty
                                  ? work.albumFolder
                                  : work.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              '${work.platformFolder} • ${work.creatorFolder} • ${work.keptFiles.length}/${work.totalPages} hal tersimpan',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Daftar File Terpilih yang Tercatat',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: work.keptFiles.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, idx) {
                        final f = work.keptFiles[idx];
                        final isMissing =
                            missingNames.contains(f.normalizedFileName);
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: isMissing
                                ? const Color(0xFFF59E0B)
                                    .withValues(alpha: 0.16)
                                : const Color(0xFF22C55E)
                                    .withValues(alpha: 0.16),
                            child: Text(
                              '${f.pageIndex + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: isMissing
                                    ? const Color(0xFFF59E0B)
                                    : const Color(0xFF22C55E),
                              ),
                            ),
                          ),
                          title: Text(
                            f.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          trailing: Text(
                            isMissing ? 'Hilang' : 'Ada di HP',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isMissing
                                  ? const Color(0xFFF59E0B)
                                  : const Color(0xFF22C55E),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            final ok = await showBottomDeleteConfirm(
                              context,
                              title: 'Kecualikan dari Katalog?',
                              message:
                                  'Hapus "${work.albumFolder.isNotEmpty ? work.albumFolder : work.title}" dari daftar simpan Katalog Kurasi? Item ini akan tetap dianggap selesai dan tidak akan diunduh ulang.',
                              confirmLabel: 'Kecualikan',
                            );
                            if (!ok || !mounted) return;
                            await widget.manager
                                .removeCuratedWork(work.markerKey);
                            if (mounted) {
                              showTopToast(
                                context,
                                'Dikecualikan dari Katalog Kurasi (tetap dianggap selesai).',
                                icon: Icons.block_rounded,
                              );
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                          ),
                          icon: const Icon(Icons.block_rounded, size: 17),
                          label: const Text('Kecualikan'),
                        ),
                      ),
                      if (missingCount > 0) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () {
                              Navigator.pop(ctx);
                              _confirmAndRestore(
                                missingFilesCount: missingCount,
                                missingWorksCount: 1,
                                excludedCount: widget.manager
                                    .computeCuratedCatalogStatus()
                                    .excludedMarkersCount,
                                singleMarkerKey: work.markerKey,
                                label:
                                    'Pulihkan "${work.albumFolder.isNotEmpty ? work.albumFolder : work.title}"?',
                              );
                            },
                            icon: const Icon(
                              Icons.cloud_download_rounded,
                              size: 17,
                            ),
                            label: Text('Pulihkan ($missingCount)'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Katalog Kurasi'),
        actions: [
          IconButton(
            onPressed: _isSyncing ? null : _syncWithDevice,
            icon: _isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
            tooltip: 'Sinkronkan dengan file di HP',
          ),
          IconButton(
            onPressed: _exportBackup,
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Ekspor Backup (.json)',
          ),
        ],
      ),
      body: RouteAwareListenableBuilder(
        listenable: widget.manager,
        builder: (context) {
          final status = widget.manager.computeCuratedCatalogStatus();
          final allEntries = widget.manager.getCuratedWorksWithMissingCounts(
            onlyMissing: _onlyMissing,
          );
          final q = _searchQuery.trim().toLowerCase();
          final filtered = q.isEmpty
              ? allEntries
              : allEntries.where((e) {
                  final w = e.$1;
                  return w.creatorFolder.toLowerCase().contains(q) ||
                      w.albumFolder.toLowerCase().contains(q) ||
                      w.title.toLowerCase().contains(q) ||
                      w.platformFolder.toLowerCase().contains(q);
                }).toList(growable: false);

          _totalFilteredCount = filtered.length;
          final renderedCount = math.min(filtered.length, _visibleLimit);

          return CustomScrollView(
            controller: _scrollController,
            slivers: [
              // Summary + Actions Card
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.bookmarks_rounded,
                                    color: theme.colorScheme.primary,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Catatan Foto Pilihan (Anti-Pilah Ulang)',
                                      style:
                                          theme.textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Hanya foto yang Anda simpan yang tercatat. Foto yang dihapus atau dilewati otomatis tidak terekam dan tetap dianggap selesai — saat pindah HP atau data hilang, cukup unduh ulang yang pilihan saja.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  height: 1.38,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: _CatalogStatTile(
                                      value: '${status.keptFilesCount}',
                                      label:
                                          'Tersimpan (${status.keptWorksCount} alb)',
                                      color: const Color(0xFF22C55E),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _CatalogStatTile(
                                      value: '${status.missingOnDeviceCount}',
                                      label: 'Hilang di HP',
                                      color: status.missingOnDeviceCount > 0
                                          ? const Color(0xFFF59E0B)
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _CatalogStatTile(
                                      value: '${status.excludedMarkersCount}',
                                      label: 'Dikecualikan',
                                      color: const Color(0xFF64748B),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (status.missingOnDeviceCount > 0) ...[
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: _isRestoring
                                        ? null
                                        : () => _confirmAndRestore(
                                              missingFilesCount:
                                                  status.missingOnDeviceCount,
                                              missingWorksCount:
                                                  status.missingWorksCount,
                                              excludedCount:
                                                  status.excludedMarkersCount,
                                            ),
                                    icon: _isRestoring
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.cloud_download_rounded,
                                            size: 19,
                                          ),
                                    label: Text(
                                      'Pulihkan ${status.missingOnDeviceCount} Foto Pilihan Yang Hilang',
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed:
                                          _isSyncing ? null : _syncWithDevice,
                                      icon: const Icon(
                                        Icons.sync_rounded,
                                        size: 17,
                                      ),
                                      label: const Text('Sinkron File HP'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _exportBackup,
                                      icon: const Icon(
                                        Icons.file_upload_outlined,
                                        size: 17,
                                      ),
                                      label: const Text('Backup JSON'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _searchController,
                        onChanged: (v) => setState(() {
                          _searchQuery = v;
                          _visibleLimit = _windowStep;
                        }),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Cari artist, album, atau platform...',
                          prefixIcon: const Icon(Icons.search_rounded, size: 20),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  onPressed: () => setState(() {
                                    _searchController.clear();
                                    _searchQuery = '';
                                    _visibleLimit = _windowStep;
                                  }),
                                  icon:
                                      const Icon(Icons.close_rounded, size: 18),
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          ChoiceChip(
                            label: Text('Semua (${status.keptWorksCount})'),
                            selected: !_onlyMissing,
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => setState(() {
                              _onlyMissing = false;
                              _visibleLimit = _windowStep;
                            }),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label:
                                Text('Hilang di HP (${status.missingWorksCount})'),
                            selected: _onlyMissing,
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => setState(() {
                              _onlyMissing = true;
                              _visibleLimit = _windowStep;
                            }),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              if (filtered.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _onlyMissing
                                ? Icons.verified_rounded
                                : Icons.bookmarks_outlined,
                            size: 48,
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.55),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _onlyMissing
                                ? 'Semua foto kurasi sudah ada di HP!'
                                : 'Belum ada catatan di Katalog Kurasi',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _onlyMissing
                                ? 'Tidak ada foto pilihan yang hilang.'
                                : 'Ketuk "Sinkron File HP" untuk langsung mencatat koleksi foto yang sudah tersimpan di HP Anda saat ini.',
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
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                  sliver: SliverList.separated(
                    itemCount: renderedCount,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final (work, missingCount) = filtered[index];
                      final platform =
                          MediaPlatformMeta.fromKey(work.platformFolder);
                      final displayTitle = work.albumFolder.isNotEmpty
                          ? work.albumFolder
                          : work.title;
                      final pageBadge = work.totalPages > work.keptFiles.length
                          ? '${work.keptFiles.length}/${work.totalPages} hal pilihan'
                          : '${work.keptFiles.length} file';

                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          contentPadding:
                              const EdgeInsets.fromLTRB(12, 4, 8, 4),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color:
                                  platform.brandColor.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Icon(
                              platform.icon,
                              color: platform.brandColor,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                          subtitle: Text(
                            '${work.creatorFolder} • $pageBadge',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: (missingCount > 0
                                          ? const Color(0xFFF59E0B)
                                          : const Color(0xFF22C55E))
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  missingCount > 0
                                      ? '$missingCount hilang'
                                      : 'Lengkap',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: missingCount > 0
                                        ? const Color(0xFFF59E0B)
                                        : const Color(0xFF22C55E),
                                  ),
                                ),
                              ),
                              if (missingCount > 0)
                                IconButton(
                                  onPressed: _isRestoring
                                      ? null
                                      : () => _confirmAndRestore(
                                            missingFilesCount: missingCount,
                                            missingWorksCount: 1,
                                            excludedCount:
                                                status.excludedMarkersCount,
                                            singleMarkerKey: work.markerKey,
                                            label:
                                                'Pulihkan "$displayTitle"?',
                                          ),
                                  icon: const Icon(
                                    Icons.cloud_download_outlined,
                                    size: 20,
                                  ),
                                  tooltip: 'Unduh ulang yang hilang',
                                ),
                            ],
                          ),
                          onTap: () =>
                              _showWorkDetailsSheet(work, missingCount),
                        ),
                      );
                    },
                  ),
                ),

              if (renderedCount < filtered.length)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _visibleLimit = math.min(
                            filtered.length,
                            _visibleLimit + _windowStep,
                          );
                        }),
                        icon: const Icon(Icons.expand_more_rounded, size: 18),
                        label: Text(
                          'Muat lagi ($renderedCount / ${filtered.length} album)',
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

class _CatalogStatTile extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _CatalogStatTile({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
