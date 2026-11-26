import 'package:flutter/material.dart';

import '../models/download_item.dart';
import '../models/media_info.dart';
import '../services/download_manager.dart';
import 'platform_badge.dart';

/// Opens a live-updating bottom sheet displaying per-file download progress,
/// speeds, saved status, individual Open/Share actions, and album marker control.
Future<void> showDownloadDetailSheet(
  BuildContext context, {
  required DownloadManager manager,
  required String itemId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => _DownloadDetailSheet(
      manager: manager,
      itemId: itemId,
    ),
  );
}

class _DownloadDetailSheet extends StatelessWidget {
  final DownloadManager manager;
  final String itemId;

  const _DownloadDetailSheet({
    required this.manager,
    required this.itemId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.42,
      maxChildSize: 0.94,
      builder: (context, scrollController) {
        return ListenableBuilder(
          listenable: manager,
          builder: (context, _) {
            final item = manager.findItemById(itemId);
            if (item == null) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Item riwayat sudah dihapus.'),
                ),
              );
            }

            final files = _effectiveSubFiles(item);
            final completedCount =
                files.where((f) => f.status == DownloadStatus.completed).length;
            final markerKey = item.markerKey.isNotEmpty
                ? item.markerKey
                : canonicalMarkerKey(item.sourceUrl);
            final isMarked = manager.isMarkedDownloaded(markerKey);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header Summary
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          PlatformBadge(platform: item.platform, compact: true),
                          const SizedBox(width: 8),
                          Text(
                            '$completedCount / ${files.length} file',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          if (item.fileSize != null && item.fileSize! > 0) ...[
                            const SizedBox(width: 8),
                            Text(
                              '• ${formatBytes(item.fileSize)}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (item.isActive) ...[
                            FilledButton.tonalIcon(
                              onPressed: () => manager.pauseDownload(item.id),
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                              ),
                              icon: const Icon(
                                Icons.pause_circle_outline_rounded,
                                size: 16,
                              ),
                              label: const Text('Jeda'),
                            ),
                            const SizedBox(width: 4),
                            TextButton.icon(
                              onPressed: () => manager.cancelDownload(item.id),
                              style: TextButton.styleFrom(
                                foregroundColor: theme.colorScheme.error,
                                visualDensity: VisualDensity.compact,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                              ),
                              icon: const Icon(
                                Icons.stop_circle_outlined,
                                size: 17,
                              ),
                              label: const Text('Batal'),
                            ),
                          ] else if (item.canResume) ...[
                            FilledButton.icon(
                              onPressed: () => manager.resumeDownload(item.id),
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                              ),
                              icon: Icon(
                                item.isPaused
                                    ? Icons.play_arrow_rounded
                                    : Icons.refresh_rounded,
                                size: 17,
                              ),
                              label: Text(
                                item.isPaused ? 'Lanjut' : 'Coba Lagi',
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                        ),
                      ),
                      if (item.author.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          item.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (item.isActive || item.isPaused) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            minHeight: 7,
                            color: item.isPaused ? const Color(0xFFF59E0B) : null,
                            backgroundColor: item.isPaused
                                ? const Color(0xFFF59E0B).withValues(alpha: 0.18)
                                : null,
                            value: item.progress >= 0
                                ? (item.progress / 100.0).clamp(0.0, 1.0)
                                : (item.isPaused ? 0.0 : null),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          item.statusText,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: item.isPaused
                                ? const Color(0xFFF59E0B)
                                : theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],

                      // Downloaded Marker Control Strip
                      if (markerKey.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isMarked
                                ? const Color(0xFF22C55E).withValues(alpha: 0.12)
                                : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isMarked
                                  ? const Color(0xFF22C55E).withValues(alpha: 0.4)
                                  : theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isMarked
                                    ? Icons.check_circle_rounded
                                    : Icons.bookmark_border_rounded,
                                size: 18,
                                color: isMarked
                                    ? const Color(0xFF22C55E)
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  isMarked
                                      ? 'Ditandai sudah diunduh'
                                      : 'Belum ditandai sebagai sudah diunduh',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () async {
                                  if (isMarked) {
                                    await manager.unmarkDownloaded(markerKey);
                                  } else {
                                    await manager.markDownloaded(markerKey);
                                  }
                                },
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: isMarked
                                      ? theme.colorScheme.error
                                      : theme.colorScheme.primary,
                                ),
                                child: Text(
                                  isMarked ? 'Hapus Tanda' : 'Tandai',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const Divider(height: 1),

                // Per-file Live Progress List
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                    itemCount: files.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final sub = files[index];
                      return _SubFileRow(
                        index: index + 1,
                        file: sub,
                        onOpen: sub.status == DownloadStatus.completed &&
                                ((sub.savedPath != null && sub.savedPath!.isNotEmpty) ||
                                    (sub.contentUri != null && sub.contentUri!.isNotEmpty))
                            ? () async {
                                final ok = await manager.openSubFile(sub);
                                if (!ok && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'File tidak ditemukan atau belum ada pemutar yang cocok.',
                                      ),
                                    ),
                                  );
                                }
                              }
                            : null,
                        onShare: sub.status == DownloadStatus.completed &&
                                ((sub.savedPath != null && sub.savedPath!.isNotEmpty) ||
                                    (sub.contentUri != null && sub.contentUri!.isNotEmpty))
                            ? () => manager.shareSubFile(sub, title: sub.fileName)
                            : null,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<SubFileTask> _effectiveSubFiles(DownloadItem item) {
    if (item.subFiles.isNotEmpty) return item.subFiles;
    return [
      SubFileTask(
        id: '${item.id}_legacy',
        fileName: item.fileName ?? '${item.title}.${item.extension}',
        status: item.status,
        progress: item.progress,
        downloadedBytes: item.fileSize ?? 0,
        totalBytes: item.fileSize ?? 0,
        savedPath: item.savedPath,
        contentUri: item.contentUri,
        mimeType: item.mimeType,
        errorMessage: item.errorMessage,
      ),
    ];
  }
}

class _SubFileRow extends StatelessWidget {
  final int index;
  final SubFileTask file;
  final VoidCallback? onOpen;
  final VoidCallback? onShare;

  const _SubFileRow({
    required this.index,
    required this.file,
    this.onOpen,
    this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final statusColor = _colorFor(file.status);

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF172033) : const Color(0xFFF4F7FC),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: file.status == DownloadStatus.downloading
              ? theme.colorScheme.primary.withValues(alpha: 0.45)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: file.status == DownloadStatus.completed
                    ? Icon(Icons.check_rounded, size: 16, color: statusColor)
                    : Text(
                        '$index',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: statusColor,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitleText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: file.status == DownloadStatus.failed
                            ? theme.colorScheme.error
                            : (file.isActive
                                ? statusColor
                                : theme.colorScheme.onSurfaceVariant),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (onOpen != null)
                IconButton(
                  onPressed: onOpen,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.open_in_new_rounded, size: 19),
                  tooltip: 'Buka file',
                ),
              if (onShare != null)
                IconButton(
                  onPressed: onShare,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.share_outlined, size: 18),
                  tooltip: 'Bagikan',
                ),
            ],
          ),
          if (file.status == DownloadStatus.downloading ||
              file.status == DownloadStatus.saving ||
              (file.status == DownloadStatus.paused && file.progress > 0)) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 5,
                color: file.status == DownloadStatus.paused
                    ? const Color(0xFFF59E0B)
                    : null,
                value: file.progress >= 0
                    ? (file.progress / 100.0).clamp(0.0, 1.0)
                    : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _subtitleText() {
    switch (file.status) {
      case DownloadStatus.queued:
        return 'Menunggu slot unduhan...';
      case DownloadStatus.downloading:
        final parts = <String>[];
        if (file.progress >= 0) {
          parts.add('${file.progress.toStringAsFixed(0)}%');
        }
        if (file.totalBytes > 0) {
          parts.add(
            '${formatBytes(file.downloadedBytes)} / ${formatBytes(file.totalBytes)}',
          );
        } else if (file.downloadedBytes > 0) {
          parts.add(formatBytes(file.downloadedBytes));
        }
        if (file.speedText.isNotEmpty) {
          parts.add(file.speedText);
        }
        return parts.isEmpty ? 'Mengunduh...' : parts.join(' • ');
      case DownloadStatus.saving:
        return 'Menyimpan ke galeri...';
      case DownloadStatus.paused:
        return file.progress > 0
            ? 'Dijeda • ${file.progress.toStringAsFixed(0)}%'
            : 'Dijeda';
      case DownloadStatus.completed:
        if (file.speedText.isNotEmpty) {
          return file.downloadedBytes > 0
              ? '${file.speedText} • ${formatBytes(file.downloadedBytes)}'
              : file.speedText;
        }
        return file.downloadedBytes > 0
            ? 'Selesai • ${formatBytes(file.downloadedBytes)}'
            : 'Selesai';
      case DownloadStatus.failed:
        return file.errorMessage?.isNotEmpty == true
            ? 'Gagal: ${file.errorMessage}'
            : 'Gagal mengunduh';
      case DownloadStatus.cancelled:
        return 'Dibatalkan';
    }
  }

  Color _colorFor(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.queued:
        return const Color(0xFF94A3B8);
      case DownloadStatus.downloading:
        return const Color(0xFF38BDF8);
      case DownloadStatus.saving:
        return const Color(0xFF818CF8);
      case DownloadStatus.paused:
        return const Color(0xFFF59E0B);
      case DownloadStatus.completed:
        return const Color(0xFF22C55E);
      case DownloadStatus.failed:
        return const Color(0xFFEF4444);
      case DownloadStatus.cancelled:
        return const Color(0xFF94A3B8);
    }
  }
}
