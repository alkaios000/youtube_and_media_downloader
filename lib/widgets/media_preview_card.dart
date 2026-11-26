import 'package:flutter/material.dart';

import '../models/media_info.dart';
import '../models/media_platform.dart';
import 'platform_badge.dart';

bool _neverDownloaded(String _) => false;

class MediaPreviewCard extends StatefulWidget {
  final MediaInfo info;
  final MediaFormatOption? initialOption;
  final void Function(MediaFormatOption selected) onDownloadOption;
  final void Function(List<SelectableMediaItem> selected) onDownloadSelectedPhotos;
  final void Function(List<SelectableMediaItem> selected, bool audioOnly)
      onDownloadBulkProfile;
  final VoidCallback onDismiss;
  final bool Function(String markerKey) isDownloaded;
  final Future<void> Function(String markerKey)? onUnmarkKey;
  final Future<void> Function(Iterable<String> markerKeys)? onUnmarkKeys;
  final Future<void> Function(Iterable<String> markerKeys)? onMarkKeys;

  const MediaPreviewCard({
    super.key,
    required this.info,
    required this.initialOption,
    required this.onDownloadOption,
    required this.onDownloadSelectedPhotos,
    required this.onDownloadBulkProfile,
    required this.onDismiss,
    this.isDownloaded = _neverDownloaded,
    this.onUnmarkKey,
    this.onUnmarkKeys,
    this.onMarkKeys,
  });

  @override
  State<MediaPreviewCard> createState() => _MediaPreviewCardState();
}

class _MediaPreviewCardState extends State<MediaPreviewCard> {
  MediaFormatOption? _selectedOption;
  final Set<String> _selectedIds = {};
  final Set<String> _unmarkSelectedIds = {};
  final TextEditingController _profileSearchController = TextEditingController();
  String _profileSearch = '';
  bool _bulkAudioOnly = false;
  bool _isUnmarkMode = false;

  @override
  void dispose() {
    _profileSearchController.dispose();
    super.dispose();
  }

  /// Strictly lock already-downloaded items across ALL platforms until unmarked.
  bool get _strictLockMarked => true;

  bool _isItemMarked(SelectableMediaItem item) {
    if (widget.info.isBulkProfile) {
      return widget.isDownloaded(item.markerKey);
    }
    return widget.isDownloaded(item.markerKey) ||
        widget.isDownloaded(widget.info.markerKey);
  }

  bool _isItemLocked(SelectableMediaItem item) {
    return _strictLockMarked && _isItemMarked(item);
  }

  @override
  void initState() {
    super.initState();
    _resetSelection();
  }

  @override
  void didUpdateWidget(covariant MediaPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.info.originalUrl != widget.info.originalUrl) {
      _resetSelection();
    } else {
      _pruneSelections();
    }
  }

  void _resetSelection() {
    _selectedOption = widget.initialOption ??
        (widget.info.options.isNotEmpty ? widget.info.options.first : null);
    _selectedIds.clear();
    _unmarkSelectedIds.clear();
    _profileSearchController.clear();
    _profileSearch = '';
    _isUnmarkMode = false;
    _bulkAudioOnly = false;

    final items = widget.info.selectableItems;
    if (widget.info.isBulkProfile || _strictLockMarked) {
      // Never pre-select already downloaded items (and on Pixiv, marked items are strictly locked!)
      for (final item in items) {
        if (!_isItemMarked(item)) {
          _selectedIds.add(item.id);
        }
      }
    } else {
      final undownloaded = items.where((e) => !_isItemMarked(e)).toList();
      if (undownloaded.isNotEmpty && undownloaded.length < items.length) {
        _selectedIds.addAll(undownloaded.map((e) => e.id));
      } else {
        _selectedIds.addAll(items.map((e) => e.id));
      }
    }
  }

  void _pruneSelections() {
    final items = widget.info.selectableItems;
    if (_strictLockMarked) {
      for (final item in items) {
        if (_isItemLocked(item)) {
          _selectedIds.remove(item.id);
        }
      }
    }
    final markedIds = items.where(_isItemMarked).map((e) => e.id).toSet();
    _unmarkSelectedIds.removeWhere((id) => !markedIds.contains(id));
    if (markedIds.isEmpty && _isUnmarkMode) {
      _isUnmarkMode = false;
    }
  }

  Future<bool> _confirmUnmarkDialog(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Hapus Tanda',
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
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
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _unmarkSingleItem(
    BuildContext context,
    SelectableMediaItem item,
  ) async {
    final confirmed = await _confirmUnmarkDialog(
      context,
      title: 'Hapus Penandaan?',
      message:
          'Hapus tanda "Sudah diunduh" untuk "${item.title}" agar bisa diunduh ulang? File yang sudah tersimpan di HP tidak ikut terhapus.',
    );
    if (!confirmed) return;

    if (widget.info.isBulkProfile) {
      await widget.onUnmarkKey?.call(item.markerKey);
      return;
    }

    // For multi-photo post: if the whole album key was marked, split it into
    // remaining pages so ONLY this specific photo becomes unlocked!
    if (widget.isDownloaded(widget.info.markerKey)) {
      final remainingKeys = widget.info.selectableItems
          .where((e) => e.id != item.id && e.markerKey.isNotEmpty)
          .map((e) => e.markerKey)
          .toList();
      await widget.onUnmarkKeys?.call([widget.info.markerKey, item.markerKey]);
      if (remainingKeys.isNotEmpty) {
        await widget.onMarkKeys?.call(remainingKeys);
      }
    } else {
      await widget.onUnmarkKey?.call(item.markerKey);
    }
  }

  Future<void> _confirmUnmarkSingleCard(
    BuildContext context,
    MediaInfo info,
  ) async {
    final confirmed = await _confirmUnmarkDialog(
      context,
      title: 'Hapus Penandaan?',
      message:
          'Hapus tanda "Sudah diunduh" untuk "${info.title}" agar bisa diunduh ulang? File yang sudah tersimpan di HP tidak ikut terhapus.',
    );
    if (!confirmed) return;
    await widget.onUnmarkKey?.call(info.markerKey);
  }

  Future<void> _executeBulkUnmarkSelected(
    BuildContext context,
    List<SelectableMediaItem> items,
  ) async {
    if (_unmarkSelectedIds.isEmpty) return;
    final chosenItems =
        items.where((e) => _unmarkSelectedIds.contains(e.id)).toList();
    if (chosenItems.isEmpty) return;

    final confirmed = await _confirmUnmarkDialog(
      context,
      title: 'Hapus Penandaan?',
      message:
          'Hapus tanda "Sudah diunduh" dari ${chosenItems.length} media terpilih? File yang sudah tersimpan di HP tidak ikut terhapus.',
    );
    if (!confirmed) return;

    if (widget.info.isBulkProfile) {
      final keys = chosenItems.map((e) => e.markerKey).toList();
      await widget.onUnmarkKeys?.call(keys);
    } else {
      final chosenIds = chosenItems.map((e) => e.id).toSet();
      final keysToRemove = <String>[
        ...chosenItems.map((e) => e.markerKey),
        if (widget.isDownloaded(widget.info.markerKey)) widget.info.markerKey,
      ];
      final remainingMarkedKeys = items
          .where((e) => !chosenIds.contains(e.id) && _isItemMarked(e))
          .map((e) => e.markerKey)
          .toList();
      await widget.onUnmarkKeys?.call(keysToRemove);
      if (widget.isDownloaded(widget.info.markerKey) &&
          remainingMarkedKeys.isNotEmpty) {
        await widget.onMarkKeys?.call(remainingMarkedKeys);
      }
    }

    if (!mounted) return;
    setState(() {
      _unmarkSelectedIds.clear();
      _isUnmarkMode = false;
    });
  }

  Future<void> _confirmUnmarkAll(
    BuildContext context,
    List<SelectableMediaItem> items,
    int downloadedCount,
  ) async {
    final keysToRemove = <String>[
      if (!widget.info.isBulkProfile && widget.info.markerKey.isNotEmpty)
        widget.info.markerKey,
      ...items.where(_isItemMarked).map((e) => e.markerKey),
    ];
    if (keysToRemove.isEmpty) return;

    final confirmed = await _confirmUnmarkDialog(
      context,
      title: downloadedCount == 1
          ? 'Hapus Penandaan?'
          : 'Hapus Semua Penandaan?',
      message: downloadedCount == 1
          ? 'Hapus tanda "Sudah diunduh" dari media ini? File yang sudah tersimpan di HP tidak ikut terhapus.'
          : 'Hapus tanda "Sudah diunduh" dari semua $downloadedCount media di daftar ini? File yang sudah tersimpan di HP tidak ikut terhapus.',
      confirmLabel:
          downloadedCount == 1 ? 'Hapus Tanda' : 'Hapus Semua Tanda',
    );
    if (confirmed) {
      await widget.onUnmarkKeys?.call(keysToRemove);
      if (mounted) {
        setState(() {
          _unmarkSelectedIds.clear();
          _isUnmarkMode = false;
        });
      }
    }
  }

  void _showLockedHint(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 2),
          content: Text(
            'Sudah tertandai terunduh — tidak bisa dicentang. Hapus tanda dulu (ketuk badge hijau atau Hapus Tanda Massal).',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    _pruneSelections();
    if (widget.info.isBulkProfile) {
      return _buildBulkProfileCard(context);
    }
    if (widget.info.selectableItems.length > 1) {
      return _buildMultiPhotoPickerCard(context);
    }
    return _buildStandardSingleCard(context);
  }

  // =========================================================================
  // MODE 1: PROFILE / PLAYLIST BULK DOWNLOADER
  // =========================================================================
  Widget _buildBulkProfileCard(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.info;
    final allItems = info.selectableItems;
    final query = _profileSearch.trim().toLowerCase();
    final items = query.isEmpty
        ? allItems
        : allItems
            .where((e) =>
                e.title.toLowerCase().contains(query) ||
                e.badgeLabel.toLowerCase().contains(query) ||
                (e.pixivIllustId?.contains(query) ?? false) ||
                e.tags.any((t) => t.toLowerCase().contains(query)))
            .toList(growable: false);
    final hasVideoItems = allItems.any((i) => i.kind == MediaKind.video);
    final isPixivBulk =
        info.platform == MediaPlatform.pixiv && info.isBulkProfile;

    final downloadedItems = allItems.where(_isItemMarked).toList();
    final downloadedCount = downloadedItems.length;
    final allEligibleItems = allItems.where((e) => !_isItemLocked(e)).toList();
    final eligibleItems = items.where((e) => !_isItemLocked(e)).toList();
    final undownloadedItems = items.where((e) => !_isItemMarked(e)).toList();
    final chosenEligibleCount =
        allEligibleItems.where((e) => _selectedIds.contains(e.id)).length;
    final uncheckedEligibleCount =
        isPixivBulk ? (allEligibleItems.length - chosenEligibleCount) : 0;

    final allEligibleSelected = eligibleItems.isNotEmpty &&
        eligibleItems.every((e) => _selectedIds.contains(e.id));
    final allMarkedSelectedForUnmark = downloadedItems.isNotEmpty &&
        downloadedItems.every((e) => _unmarkSelectedIds.contains(e.id));

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                PlatformBadge(platform: info.platform),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    info.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: widget.onDismiss,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              info.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),

            if (downloadedCount > 0) ...[
              const SizedBox(height: 10),
              if (_isUnmarkMode)
                _UnmarkModeBanner(
                  selectedCount: _unmarkSelectedIds.length,
                  totalMarked: downloadedCount,
                  allMarkedSelected: allMarkedSelectedForUnmark,
                  onToggleSelectAllMarked: () {
                    setState(() {
                      if (allMarkedSelectedForUnmark) {
                        _unmarkSelectedIds.clear();
                      } else {
                        _unmarkSelectedIds
                          ..clear()
                          ..addAll(downloadedItems.map((e) => e.id));
                      }
                    });
                  },
                  onDone: () => setState(() {
                    _isUnmarkMode = false;
                    _unmarkSelectedIds.clear();
                  }),
                )
              else
                _DownloadedNoticeStrip(
                  message: _strictLockMarked
                      ? '$downloadedCount/${allItems.length} sudah diunduh (terkunci dari unduh ulang)'
                      : '$downloadedCount dari ${allItems.length} media sudah pernah diunduh',
                  showBulkPickBtn: downloadedCount > 1 && widget.onUnmarkKeys != null,
                  onPickBulkUnmark: () {
                    setState(() {
                      _isUnmarkMode = true;
                      _unmarkSelectedIds.clear();
                    });
                  },
                  onClearAll: widget.onUnmarkKeys != null
                      ? () => _confirmUnmarkAll(context, allItems, downloadedCount)
                      : null,
                ),
            ],

            if (!_isUnmarkMode) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: eligibleItems.isEmpty
                        ? null
                        : () {
                            setState(() {
                              if (allEligibleSelected) {
                                _selectedIds.clear();
                              } else {
                                _selectedIds
                                  ..clear()
                                  ..addAll(eligibleItems.map((e) => e.id));
                              }
                            });
                          },
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: Icon(
                      allEligibleSelected
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                      size: 17,
                    ),
                    label: Text(
                      allEligibleSelected
                          ? 'Batal Semua'
                          : (_strictLockMarked && downloadedCount > 0
                              ? 'Pilih Belum (${eligibleItems.length})'
                              : 'Pilih Semua'),
                    ),
                  ),
                  if (!_strictLockMarked &&
                      downloadedCount > 0 &&
                      undownloadedItems.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _selectedIds
                            ..clear()
                            ..addAll(undownloadedItems.map((e) => e.id));
                        });
                      },
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.fiber_new_rounded, size: 17),
                      label: Text('Belum (${undownloadedItems.length})'),
                    ),
                  Text(
                    '${_selectedIds.length} / ${eligibleItems.length} dipilih',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (isPixivBulk && uncheckedEligibleCount > 0) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.fast_forward_rounded,
                        size: 16,
                        color: Color(0xFFF59E0B),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '$uncheckedEligibleCount album tidak dicentang → tidak diunduh, tapi tetap ditandai selesai (ter-skip ke depannya).',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: const Color(0xFFF59E0B),
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              if (hasVideoItems && info.platform != MediaPlatform.pixiv) ...[
                const SizedBox(height: 10),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.videocam_rounded, size: 17),
                      label: Text('Video MP4'),
                    ),
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.audiotrack_rounded, size: 17),
                      label: Text('Audio MP3'),
                    ),
                  ],
                  selected: {_bulkAudioOnly},
                  onSelectionChanged: (s) =>
                      setState(() => _bulkAudioOnly = s.first),
                ),
              ],
            ],

            if (allItems.length > 6) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _profileSearchController,
                onChanged: (v) => setState(() => _profileSearch = v),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Cari judul atau ID karya ${info.author}...',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _profileSearch.isNotEmpty
                      ? IconButton(
                          onPressed: () => setState(() {
                            _profileSearchController.clear();
                            _profileSearch = '';
                          }),
                          icon: const Icon(Icons.close_rounded, size: 18),
                        )
                      : null,
                ),
              ),
            ],

            const SizedBox(height: 12),

            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Tidak ada karya yang cocok dengan "$_profileSearch".',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              _buildAdaptiveSelectableGrid(
                context,
                items: items,
                aspectRatio: 0.82,
              ),

            const SizedBox(height: 14),
            if (_isUnmarkMode)
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: _unmarkSelectedIds.isEmpty
                            ? null
                            : () => _executeBulkUnmarkSelected(context, allItems),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.bookmark_remove_rounded),
                        label: Text(
                          'Hapus ${_unmarkSelectedIds.length} Penanda',
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      onPressed: () =>
                          _confirmUnmarkAll(context, allItems, downloadedCount),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        side: BorderSide(color: theme.colorScheme.error),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text('Semua'),
                    ),
                  ),
                ],
              )
            else
              SizedBox(
                height: 50,
                child: FilledButton.icon(
                  onPressed: (_selectedIds.isEmpty && uncheckedEligibleCount == 0)
                      ? null
                      : () {
                          final chosen = allItems
                              .where((e) =>
                                  _selectedIds.contains(e.id) &&
                                  !_isItemLocked(e))
                              .toList();
                          if (chosen.isEmpty && uncheckedEligibleCount == 0) {
                            _showLockedHint(context);
                            return;
                          }
                          widget.onDownloadBulkProfile(chosen, _bulkAudioOnly);
                        },
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: Icon(
                    chosenEligibleCount == 0 && uncheckedEligibleCount > 0
                        ? Icons.fast_forward_rounded
                        : Icons.download_for_offline_rounded,
                  ),
                  label: Text(
                    allEligibleItems.isEmpty && _strictLockMarked
                        ? 'Semua Sudah Diunduh (Hapus Tanda Dulu)'
                        : (chosenEligibleCount == 0 &&
                                uncheckedEligibleCount > 0
                            ? 'Tandai Dilewati ($uncheckedEligibleCount Album)'
                            : (uncheckedEligibleCount > 0
                                ? 'Unduh $chosenEligibleCount • Skip $uncheckedEligibleCount'
                                : 'Unduh Massal (${_selectedIds.length} Media)')),
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // MODE 2: MULTI-PHOTO PICKER (Pixiv multi-page, X photos, IG carousel, TikTok/Douyin)
  // =========================================================================
  Widget _buildMultiPhotoPickerCard(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.info;
    final items = info.selectableItems;
    final extraOptions = info.options.where((o) => !o.isImage).toList();

    final downloadedItems = items.where(_isItemMarked).toList();
    final downloadedCount = downloadedItems.length;
    final eligibleItems = items.where((e) => !_isItemLocked(e)).toList();

    final allEligibleSelected = eligibleItems.isNotEmpty &&
        eligibleItems.every((e) => _selectedIds.contains(e.id));
    final allMarkedSelectedForUnmark = downloadedItems.isNotEmpty &&
        downloadedItems.every((e) => _unmarkSelectedIds.contains(e.id));

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                PlatformBadge(platform: info.platform),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    info.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: widget.onDismiss,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              info.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),

            if (downloadedCount > 0) ...[
              const SizedBox(height: 10),
              if (_isUnmarkMode)
                _UnmarkModeBanner(
                  selectedCount: _unmarkSelectedIds.length,
                  totalMarked: downloadedCount,
                  allMarkedSelected: allMarkedSelectedForUnmark,
                  onToggleSelectAllMarked: () {
                    setState(() {
                      if (allMarkedSelectedForUnmark) {
                        _unmarkSelectedIds.clear();
                      } else {
                        _unmarkSelectedIds
                          ..clear()
                          ..addAll(downloadedItems.map((e) => e.id));
                      }
                    });
                  },
                  onDone: () => setState(() {
                    _isUnmarkMode = false;
                    _unmarkSelectedIds.clear();
                  }),
                )
              else
                _DownloadedNoticeStrip(
                  message: downloadedCount == items.length
                      ? (_strictLockMarked
                          ? 'Album ini sudah diunduh (terkunci)'
                          : 'Album ini sudah pernah diunduh')
                      : '$downloadedCount/${items.length} foto sudah diunduh',
                  showBulkPickBtn: downloadedCount > 1 && widget.onUnmarkKeys != null,
                  onPickBulkUnmark: () {
                    setState(() {
                      _isUnmarkMode = true;
                      _unmarkSelectedIds.clear();
                    });
                  },
                  onClearAll: widget.onUnmarkKeys != null
                      ? () => _confirmUnmarkAll(context, items, downloadedCount)
                      : null,
                ),
            ],

            if (!_isUnmarkMode) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'Pilih Foto (${_selectedIds.length}/${eligibleItems.length})',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: eligibleItems.isEmpty
                        ? null
                        : () {
                            setState(() {
                              if (allEligibleSelected) {
                                _selectedIds.clear();
                              } else {
                                _selectedIds
                                  ..clear()
                                  ..addAll(eligibleItems.map((e) => e.id));
                              }
                            });
                          },
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: Icon(
                      allEligibleSelected
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                      size: 17,
                    ),
                    label: Text(allEligibleSelected ? 'Reset' : 'Pilih Semua'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),

            _buildAdaptiveSelectableGrid(
              context,
              items: items,
              aspectRatio: 0.9,
            ),

            const SizedBox(height: 14),
            if (_isUnmarkMode)
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: _unmarkSelectedIds.isEmpty
                            ? null
                            : () => _executeBulkUnmarkSelected(context, items),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.bookmark_remove_rounded),
                        label: Text(
                          'Hapus ${_unmarkSelectedIds.length} Penanda',
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      onPressed: () =>
                          _confirmUnmarkAll(context, items, downloadedCount),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        side: BorderSide(color: theme.colorScheme.error),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text('Semua'),
                    ),
                  ),
                ],
              )
            else
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () {
                          final chosen = items
                              .where((e) =>
                                  _selectedIds.contains(e.id) &&
                                  !_isItemLocked(e))
                              .toList();
                          if (chosen.isEmpty) {
                            _showLockedHint(context);
                            return;
                          }
                          widget.onDownloadSelectedPhotos(chosen);
                        },
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    eligibleItems.isEmpty && _strictLockMarked
                        ? 'Semua Foto Sudah Diunduh'
                        : 'Unduh ${_selectedIds.length} Foto Terpilih',
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),

            if (extraOptions.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: extraOptions.map((opt) {
                  return OutlinedButton.icon(
                    onPressed: () => widget.onDownloadOption(opt),
                    icon: Icon(_iconForKind(opt.kind), size: 17),
                    label: Text(opt.label),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // MODE 3: SINGLE VIDEO / AUDIO / SINGLE PHOTO
  // =========================================================================
  Widget _buildStandardSingleCard(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final info = widget.info;
    final selected = _selectedOption ??
        (info.options.isNotEmpty ? info.options.first : null);
    final alreadyDownloaded = widget.isDownloaded(info.markerKey);
    final lockedForRedownload = _strictLockMarked && alreadyDownloaded;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: info.thumbnailUrl != null && info.thumbnailUrl!.isNotEmpty
                    ? Image.network(
                        info.thumbnailUrl!,
                        headers: info.thumbnailHeaders.isEmpty
                            ? null
                            : info.thumbnailHeaders,
                        cacheWidth: 720,
                        filterQuality: FilterQuality.low,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _ThumbnailFallback(
                          platformColor: theme.colorScheme.primary,
                        ),
                      )
                    : _ThumbnailFallback(
                        platformColor: theme.colorScheme.primary,
                      ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.35),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.72),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: PlatformBadge(platform: info.platform),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton.filledTonal(
                  onPressed: widget.onDismiss,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.55),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: 'Tutup',
                ),
              ),
              if (info.formattedDuration.isNotEmpty)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      info.formattedDuration,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (alreadyDownloaded) ...[
                  _DownloadedNoticeStrip(
                    message: lockedForRedownload
                        ? 'Karya ini sudah diunduh (hapus tanda untuk unduh ulang)'
                        : 'Media ini sudah pernah diunduh',
                    showBulkPickBtn: false,
                    onClearAll: widget.onUnmarkKey != null
                        ? () => _confirmUnmarkSingleCard(context, info)
                        : null,
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  info.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.person_outline_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        info.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ...info.options.map((opt) {
                  final isSel = selected?.id == opt.id;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () => setState(() => _selectedOption = opt),
                      borderRadius: BorderRadius.circular(14),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: isSel
                              ? theme.colorScheme.primary.withValues(
                                  alpha: isDark ? 0.16 : 0.10,
                                )
                              : (isDark
                                  ? const Color(0xFF172033)
                                  : const Color(0xFFF3F6FB)),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSel
                                ? theme.colorScheme.primary
                                : (isDark
                                    ? const Color(0xFF26324A)
                                    : const Color(0xFFDCE5F2)),
                            width: isSel ? 1.5 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: isSel
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                _iconForKind(opt.kind),
                                size: 18,
                                color: isSel
                                    ? Colors.white
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    opt.label,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    opt.subtitle,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              isSel
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              size: 20,
                              color: isSel
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
                if (selected != null) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: lockedForRedownload
                          ? null
                          : () => widget.onDownloadOption(selected),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: Icon(
                        lockedForRedownload
                            ? Icons.lock_rounded
                            : Icons.download_rounded,
                      ),
                      label: Text(
                        lockedForRedownload
                            ? 'Sudah Diunduh (Hapus Tanda Dulu)'
                            : 'Unduh ${selected.extension.toUpperCase()}',
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdaptiveSelectableGrid(
    BuildContext context, {
    required List<SelectableMediaItem> items,
    required double aspectRatio,
  }) {
    final isLarge = items.length > 12;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.52;

    final grid = GridView.builder(
      shrinkWrap: !isLarge,
      physics: isLarge
          ? const AlwaysScrollableScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: aspectRatio,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final isDone = _isItemMarked(item);
        final isLocked = _isItemLocked(item);
        final isSelected = _selectedIds.contains(item.id) && !isLocked;
        final isPickedForUnmark = _unmarkSelectedIds.contains(item.id);

        return _SelectableGridTile(
          item: item,
          selected: isSelected,
          downloaded: isDone,
          locked: isLocked,
          unmarkMode: _isUnmarkMode,
          pickedForUnmark: isPickedForUnmark,
          onUnmark: !_isUnmarkMode && isDone && widget.onUnmarkKey != null
              ? () => _unmarkSingleItem(context, item)
              : null,
          onTap: () {
            if (_isUnmarkMode) {
              if (!isDone) return;
              setState(() {
                if (isPickedForUnmark) {
                  _unmarkSelectedIds.remove(item.id);
                } else {
                  _unmarkSelectedIds.add(item.id);
                }
              });
              return;
            }

            if (isLocked) {
              _showLockedHint(context);
              return;
            }

            setState(() {
              if (isSelected) {
                _selectedIds.remove(item.id);
              } else {
                _selectedIds.add(item.id);
              }
            });
          },
        );
      },
    );

    if (!isLarge) return grid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: maxHeight.clamp(280.0, 460.0),
          child: Scrollbar(
            thumbVisibility: true,
            child: grid,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _isUnmarkMode
              ? 'Ketuk item bertanda hijau untuk dipilih hapus penandaannya'
              : 'Geser kotak di atas untuk melihat seluruh ${items.length} media • Ketuk badge hijau untuk hapus tanda',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  IconData _iconForKind(MediaKind kind) {
    switch (kind) {
      case MediaKind.video:
        return Icons.videocam_rounded;
      case MediaKind.audio:
        return Icons.audiotrack_rounded;
      case MediaKind.image:
        return Icons.photo_library_rounded;
    }
  }
}

class _DownloadedNoticeStrip extends StatelessWidget {
  final String message;
  final bool showBulkPickBtn;
  final VoidCallback? onPickBulkUnmark;
  final VoidCallback? onClearAll;

  const _DownloadedNoticeStrip({
    required this.message,
    required this.showBulkPickBtn,
    this.onPickBulkUnmark,
    this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    const emerald = Color(0xFF22C55E);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: emerald.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: emerald.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: emerald, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: emerald,
                      ),
                ),
              ),
            ],
          ),
          if (showBulkPickBtn || onClearAll != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (showBulkPickBtn && onPickBulkUnmark != null)
                  OutlinedButton.icon(
                    onPressed: onPickBulkUnmark,
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      side: BorderSide(color: emerald.withValues(alpha: 0.6)),
                      foregroundColor: emerald,
                    ),
                    icon: const Icon(Icons.checklist_rtl_rounded, size: 15),
                    label: const Text(
                      'Hapus Tanda Massal',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                if (onClearAll != null)
                  TextButton.icon(
                    onPressed: onClearAll,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                    label: Text(
                      showBulkPickBtn ? 'Hapus Semua Tanda' : 'Hapus Tanda',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _UnmarkModeBanner extends StatelessWidget {
  final int selectedCount;
  final int totalMarked;
  final bool allMarkedSelected;
  final VoidCallback onToggleSelectAllMarked;
  final VoidCallback onDone;

  const _UnmarkModeBanner({
    required this.selectedCount,
    required this.totalMarked,
    required this.allMarkedSelected,
    required this.onToggleSelectAllMarked,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final err = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: err.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: err.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bookmark_remove_rounded, color: err, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Mode Hapus Penanda ($selectedCount / $totalMarked dipilih)',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: err,
                      ),
                ),
              ),
              TextButton(
                onPressed: onDone,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Batal'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: onToggleSelectAllMarked,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: Icon(
                  allMarkedSelected
                      ? Icons.deselect_rounded
                      : Icons.select_all_rounded,
                  size: 16,
                ),
                label: Text(
                  allMarkedSelected
                      ? 'Batal Pilih Tanda'
                      : 'Pilih Semua Tanda ($totalMarked)',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SelectableGridTile extends StatelessWidget {
  final SelectableMediaItem item;
  final bool selected;
  final bool downloaded;
  final bool locked;
  final bool unmarkMode;
  final bool pickedForUnmark;
  final VoidCallback? onUnmark;
  final VoidCallback onTap;

  const _SelectableGridTile({
    required this.item,
    required this.selected,
    required this.downloaded,
    required this.locked,
    required this.unmarkMode,
    required this.pickedForUnmark,
    this.onUnmark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errColor = theme.colorScheme.error;

    Color borderColor;
    double borderWidth;
    if (unmarkMode) {
      borderColor = pickedForUnmark
          ? errColor
          : (downloaded
              ? const Color(0xFF22C55E).withValues(alpha: 0.75)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.4));
      borderWidth = pickedForUnmark ? 2.4 : 1.2;
    } else if (selected) {
      borderColor = theme.colorScheme.primary;
      borderWidth = 2.2;
    } else if (downloaded) {
      borderColor = const Color(0xFF22C55E).withValues(alpha: 0.75);
      borderWidth = 1.5;
    } else {
      borderColor = theme.colorScheme.outlineVariant;
      borderWidth = 1;
    }

    final shouldDim = unmarkMode
        ? (!downloaded || !pickedForUnmark)
        : (!selected);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.thumbnailUrl != null && item.thumbnailUrl!.isNotEmpty)
              Image.network(
                item.thumbnailUrl!,
                headers: item.headers.isEmpty ? null : item.headers,
                cacheWidth: 260,
                filterQuality: FilterQuality.low,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _gridPlaceholder(theme),
              )
            else
              _gridPlaceholder(theme),

            if (shouldDim)
              Container(
                color: Colors.black.withValues(
                  alpha: unmarkMode && !downloaded ? 0.62 : (locked ? 0.48 : 0.32),
                ),
              ),

            if (unmarkMode && pickedForUnmark)
              Container(color: errColor.withValues(alpha: 0.22)),

            // Bottom gradient + badge/title
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(6, 14, 6, 5),
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
                  item.badgeLabel.isNotEmpty ? item.badgeLabel : item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            // "✓ Sudah" downloaded marker badge on top-left
            if (downloaded)
              Positioned(
                top: 5,
                left: 5,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onUnmark,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF16A34A).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.check_rounded,
                          size: 11,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 2),
                        const Text(
                          'Sudah',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (onUnmark != null) ...[
                          const SizedBox(width: 2),
                          const Icon(
                            Icons.close_rounded,
                            size: 11,
                            color: Colors.white70,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

            // Top-right indicator:
            // - Unmark mode: red checkbox on marked items only
            // - Locked Pixiv item: clean lock badge (cannot be checked!)
            // - Normal item: primary checkmark / plus circle
            if (unmarkMode && downloaded)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  width: 23,
                  height: 23,
                  decoration: BoxDecoration(
                    color: pickedForUnmark
                        ? errColor
                        : Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.6),
                  ),
                  child: Icon(
                    pickedForUnmark
                        ? Icons.delete_outline_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              )
            else if (!unmarkMode && locked)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  width: 23,
                  height: 23,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF22C55E),
                      width: 1.5,
                    ),
                  ),
                  child: const Icon(
                    Icons.lock_rounded,
                    size: 13,
                    color: Color(0xFF22C55E),
                  ),
                ),
              )
            else if (!unmarkMode)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  width: 23,
                  height: 23,
                  decoration: BoxDecoration(
                    color: selected
                        ? theme.colorScheme.primary
                        : Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Icon(
                    selected ? Icons.check_rounded : Icons.add_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _gridPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        item.kind == MediaKind.image
            ? Icons.image_outlined
            : Icons.videocam_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _ThumbnailFallback extends StatelessWidget {
  final Color platformColor;

  const _ThumbnailFallback({required this.platformColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            platformColor.withValues(alpha: 0.35),
            platformColor.withValues(alpha: 0.1),
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.movie_filter_rounded, size: 48, color: Colors.white70),
      ),
    );
  }
}
