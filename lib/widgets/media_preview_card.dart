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
  });

  @override
  State<MediaPreviewCard> createState() => _MediaPreviewCardState();
}

class _MediaPreviewCardState extends State<MediaPreviewCard> {
  MediaFormatOption? _selectedOption;
  final Set<String> _selectedIds = {};
  bool _bulkAudioOnly = false;

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
    }
  }

  void _resetSelection() {
    _selectedOption = widget.initialOption ??
        (widget.info.options.isNotEmpty ? widget.info.options.first : null);
    _selectedIds.clear();
    final items = widget.info.selectableItems;
    if (widget.info.isBulkProfile) {
      // Pre-select only NOT-yet-downloaded albums/media so revisiting a profile
      // makes grabbing new releases 1-tap without re-downloading old albums!
      for (final item in items) {
        if (!widget.isDownloaded(item.markerKey)) {
          _selectedIds.add(item.id);
        }
      }
    } else {
      final undownloaded =
          items.where((e) => !widget.isDownloaded(e.markerKey)).toList();
      if (undownloaded.isNotEmpty && undownloaded.length < items.length) {
        _selectedIds.addAll(undownloaded.map((e) => e.id));
      } else {
        _selectedIds.addAll(items.map((e) => e.id));
      }
    }
    _bulkAudioOnly = false;
  }

  @override
  Widget build(BuildContext context) {
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
    final items = info.selectableItems;
    final allSelected = _selectedIds.length == items.length && items.isNotEmpty;
    final hasVideoItems = items.any((i) => i.kind == MediaKind.video);

    final downloadedItems =
        items.where((e) => widget.isDownloaded(e.markerKey)).toList();
    final downloadedCount = downloadedItems.length;
    final undownloadedCount = items.length - downloadedCount;

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
              _DownloadedNoticeStrip(
                message: '$downloadedCount dari ${items.length} media sudah pernah diunduh',
                actionLabel: 'Hapus Tanda',
                onClear: widget.onUnmarkKeys != null
                    ? () => _confirmUnmarkBulk(
                          context,
                          downloadedItems.map((e) => e.markerKey).toList(),
                          downloadedCount,
                        )
                    : null,
              ),
            ],

            const SizedBox(height: 12),

            // Select All / Select Only New / Count
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () {
                    setState(() {
                      if (allSelected) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds.addAll(items.map((e) => e.id));
                      }
                    });
                  },
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: Icon(
                    allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
                    size: 17,
                  ),
                  label: Text(allSelected ? 'Batal Semua' : 'Pilih Semua'),
                ),
                if (downloadedCount > 0 && undownloadedCount > 0)
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _selectedIds
                          ..clear()
                          ..addAll(
                            items
                                .where((e) => !widget.isDownloaded(e.markerKey))
                                .map((e) => e.id),
                          );
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.fiber_new_rounded, size: 17),
                    label: Text('Belum ($undownloadedCount)'),
                  ),
                Text(
                  '${_selectedIds.length} / ${items.length} dipilih',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),

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
                onSelectionChanged: (s) => setState(() => _bulkAudioOnly = s.first),
              ),
            ],

            const SizedBox(height: 12),

            _buildAdaptiveSelectableGrid(
              context,
              items: items,
              aspectRatio: 0.82,
            ),

            const SizedBox(height: 14),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: _selectedIds.isEmpty
                    ? null
                    : () {
                        final chosen = items
                            .where((e) => _selectedIds.contains(e.id))
                            .toList();
                        widget.onDownloadBulkProfile(chosen, _bulkAudioOnly);
                      },
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.download_for_offline_rounded),
                label: Text(
                  'Unduh Massal (${_selectedIds.length} Media)',
                  style: const TextStyle(
                    fontSize: 15,
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

  Future<void> _confirmUnmarkBulk(
    BuildContext context,
    List<String> keys,
    int count,
  ) async {
    if (count == 1) {
      await widget.onUnmarkKeys?.call(keys);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Penandaan?'),
        content: Text(
          'Hapus tanda "Sudah diunduh" dari $count media pada daftar ini? File yang sudah tersimpan di perangkat tidak ikut terhapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus Tanda'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.onUnmarkKeys?.call(keys);
    }
  }

  // =========================================================================
  // MODE 2: MULTI-PHOTO PICKER (Pixiv multi-page, X photos, IG carousel, TikTok/Douyin)
  // =========================================================================
  Widget _buildMultiPhotoPickerCard(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.info;
    final items = info.selectableItems;
    final allSelected = _selectedIds.length == items.length && items.isNotEmpty;
    final extraOptions = info.options.where((o) => !o.isImage).toList();
    final albumAlreadyDownloaded = widget.isDownloaded(info.markerKey);

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

            if (albumAlreadyDownloaded) ...[
              const SizedBox(height: 10),
              _DownloadedNoticeStrip(
                message: 'Album ini sudah pernah diunduh',
                actionLabel: 'Hapus Tanda',
                onClear: widget.onUnmarkKeys != null
                    ? () => widget.onUnmarkKeys!([
                          info.markerKey,
                          ...items.map((e) => e.markerKey),
                        ])
                    : (widget.onUnmarkKey != null
                        ? () => widget.onUnmarkKey!(info.markerKey)
                        : null),
              ),
            ],

            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  'Pilih Foto (${_selectedIds.length}/${items.length})',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      if (allSelected) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds.addAll(items.map((e) => e.id));
                      }
                    });
                  },
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: Icon(
                    allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
                    size: 17,
                  ),
                  label: Text(allSelected ? 'Reset' : 'Pilih Semua'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            _buildAdaptiveSelectableGrid(
              context,
              items: items,
              aspectRatio: 0.9,
            ),

            const SizedBox(height: 14),
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _selectedIds.isEmpty
                    ? null
                    : () {
                        final chosen = items
                            .where((e) => _selectedIds.contains(e.id))
                            .toList();
                        widget.onDownloadSelectedPhotos(chosen);
                      },
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.download_rounded),
                label: Text(
                  'Unduh ${_selectedIds.length} Foto Terpilih',
                  style: const TextStyle(
                    fontSize: 15,
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
                    message: 'Media ini sudah pernah diunduh',
                    actionLabel: 'Hapus Tanda',
                    onClear: widget.onUnmarkKey != null
                        ? () => widget.onUnmarkKey!(info.markerKey)
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
                      onPressed: () => widget.onDownloadOption(selected),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.download_rounded),
                      label: Text(
                        'Unduh ${selected.extension.toUpperCase()}',
                        style: const TextStyle(
                          fontSize: 15,
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
        final isSelected = _selectedIds.contains(item.id);
        final isDone = widget.isDownloaded(item.markerKey);
        return _SelectableGridTile(
          item: item,
          selected: isSelected,
          downloaded: isDone,
          onUnmark: isDone && widget.onUnmarkKey != null
              ? () => widget.onUnmarkKey!(item.markerKey)
              : null,
          onTap: () {
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
          'Geser kotak di atas untuk melihat seluruh ${items.length} media • Ketuk badge hijau untuk hapus tanda',
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
  final String actionLabel;
  final VoidCallback? onClear;

  const _DownloadedNoticeStrip({
    required this.message,
    required this.actionLabel,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    const emerald = Color(0xFF22C55E);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: emerald.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: emerald.withValues(alpha: 0.4)),
      ),
      child: Row(
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
          if (onClear != null)
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
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
  final VoidCallback? onUnmark;
  final VoidCallback onTap;

  const _SelectableGridTile({
    required this.item,
    required this.selected,
    required this.downloaded,
    this.onUnmark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : (downloaded
                    ? const Color(0xFF22C55E).withValues(alpha: 0.75)
                    : theme.colorScheme.outlineVariant),
            width: selected ? 2.2 : (downloaded ? 1.5 : 1),
          ),
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

            // Dim overlay when unselected so selection pops immediately
            if (!selected)
              Container(color: Colors.black.withValues(alpha: 0.35)),

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

            // "✓ Sudah" downloaded marker badge on top-left (tap directly to remove marker!)
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

            // Checkmark selection indicator on top-right
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
