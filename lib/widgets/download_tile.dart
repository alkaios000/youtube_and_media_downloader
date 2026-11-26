import 'package:flutter/material.dart';

import '../models/download_item.dart';
import '../models/media_info.dart';
import '../models/media_platform.dart';
import 'platform_badge.dart';

class DownloadTile extends StatelessWidget {
  final DownloadItem item;
  final bool isMarkedDownloaded;
  final VoidCallback? onTapDetail;
  final VoidCallback? onCancel;
  final VoidCallback? onOpen;
  final VoidCallback? onShare;
  final VoidCallback? onDelete;

  const DownloadTile({
    super.key,
    required this.item,
    this.isMarkedDownloaded = false,
    this.onTapDetail,
    this.onCancel,
    this.onOpen,
    this.onShare,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final canOpen = item.status == DownloadStatus.completed;
    final fileCount = item.subFiles.length;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTapDetail ?? (canOpen ? onOpen : null),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _MiniThumb(item: item),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            PlatformBadge(
                              platform: item.platform,
                              compact: true,
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.black.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                item.extension.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (isMarkedDownloaded) ...[
                              const SizedBox(width: 5),
                              const Icon(
                                Icons.bookmark_added_rounded,
                                size: 15,
                                color: Color(0xFF22C55E),
                              ),
                            ],
                            const Spacer(),
                            _StatusChip(status: item.status),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _metaLine(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (canOpen && item.statusText.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(
                                Icons.folder_outlined,
                                size: 13,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  item.statusText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),

              if (item.isActive) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 7,
                    value: item.progress >= 0
                        ? (item.progress / 100.0).clamp(0.0, 1.0)
                        : null,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.statusText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onTapDetail != null)
                      TextButton.icon(
                        onPressed: onTapDetail,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        icon: const Icon(Icons.list_alt_rounded, size: 16),
                        label: Text(
                          fileCount > 1
                              ? '${item.completedSubFilesCount}/$fileCount'
                              : 'Detail',
                        ),
                      ),
                    TextButton.icon(
                      onPressed: onCancel,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.stop_circle_outlined, size: 17),
                      label: const Text('Batal'),
                    ),
                  ],
                ),
              ],

              if (item.status == DownloadStatus.failed &&
                  item.errorMessage != null &&
                  item.errorMessage!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    item.errorMessage!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],

              if (!item.isActive) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (canOpen) ...[
                      FilledButton.tonalIcon(
                        onPressed: onOpen,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: const Text('Buka'),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton.icon(
                        onPressed: onShare,
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        icon: const Icon(Icons.share_rounded, size: 15),
                        label: const Text('Bagikan'),
                      ),
                    ],
                    const Spacer(),
                    if (onTapDetail != null)
                      TextButton.icon(
                        onPressed: onTapDetail,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        icon: const Icon(Icons.list_alt_rounded, size: 16),
                        label: Text(
                          fileCount > 1 ? '$fileCount file' : 'Detail',
                        ),
                      ),
                    IconButton(
                      onPressed: onDelete,
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      tooltip: 'Hapus',
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _metaLine() {
    final parts = <String>[
      if (item.fileSize != null && item.fileSize! > 0)
        formatBytes(item.fileSize),
      if (item.subFiles.length > 1)
        '${item.completedSubFilesCount}/${item.subFiles.length} file'
      else
        item.formatLabel,
      _formatDate(item.createdAt),
    ];
    return parts.join(' • ');
  }

  String _formatDate(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$d/$m $hh:$mm';
  }
}

class _MiniThumb extends StatelessWidget {
  final DownloadItem item;

  const _MiniThumb({required this.item});

  @override
  Widget build(BuildContext context) {
    final fallbackIcon = item.mediaKind == MediaKind.audio
        ? Icons.music_note_rounded
        : (item.mediaKind == MediaKind.image
            ? Icons.image_rounded
            : Icons.videocam_rounded);

    final headers = item.platform == MediaPlatform.pixiv
        ? const {'Referer': 'https://www.pixiv.net/'}
        : null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 76,
        height: 76,
        child: item.thumbnailUrl != null && item.thumbnailUrl!.isNotEmpty
            ? Image.network(
                item.thumbnailUrl!,
                headers: headers,
                cacheWidth: 160,
                filterQuality: FilterQuality.low,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _ThumbPlaceholder(icon: fallbackIcon),
              )
            : _ThumbPlaceholder(icon: fallbackIcon),
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  final IconData icon;

  const _ThumbPlaceholder({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        icon,
        size: 30,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final DownloadStatus status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late final String text;
    switch (status) {
      case DownloadStatus.queued:
        color = const Color(0xFF94A3B8);
        text = 'Antrean';
        break;
      case DownloadStatus.downloading:
        color = const Color(0xFF38BDF8);
        text = 'Mengunduh';
        break;
      case DownloadStatus.saving:
        color = const Color(0xFF818CF8);
        text = 'Menyimpan';
        break;
      case DownloadStatus.completed:
        color = const Color(0xFF22C55E);
        text = 'Selesai';
        break;
      case DownloadStatus.failed:
        color = const Color(0xFFEF4444);
        text = 'Gagal';
        break;
      case DownloadStatus.cancelled:
        color = const Color(0xFF94A3B8);
        text = 'Batal';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
