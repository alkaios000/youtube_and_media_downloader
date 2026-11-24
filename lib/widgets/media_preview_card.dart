import 'package:flutter/material.dart';

import '../models/media_info.dart';
import 'platform_badge.dart';

class MediaPreviewCard extends StatefulWidget {
  final MediaInfo info;
  final MediaFormatOption initialOption;
  final void Function(MediaFormatOption selected) onDownload;
  final VoidCallback onDismiss;

  const MediaPreviewCard({
    super.key,
    required this.info,
    required this.initialOption,
    required this.onDownload,
    required this.onDismiss,
  });

  @override
  State<MediaPreviewCard> createState() => _MediaPreviewCardState();
}

class _MediaPreviewCardState extends State<MediaPreviewCard> {
  late MediaFormatOption _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialOption;
  }

  @override
  void didUpdateWidget(covariant MediaPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.info.originalUrl != widget.info.originalUrl) {
      _selected = widget.initialOption;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final info = widget.info;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Thumbnail Header
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
                  tooltip: 'Tutup pratinjau',
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
              Positioned(
                left: 12,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    info.extractorLabel,
                    style: const TextStyle(
                      color: Color(0xFFE2E8F0),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
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
                const SizedBox(height: 16),
                Text(
                  'Pilih Kualitas / Format',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                ...info.options.map((opt) {
                  final selected = opt.id == _selected.id;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () => setState(() => _selected = opt),
                      borderRadius: BorderRadius.circular(14),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? theme.colorScheme.primary.withValues(
                                  alpha: isDark ? 0.16 : 0.10,
                                )
                              : (isDark
                                  ? const Color(0xFF172033)
                                  : const Color(0xFFF3F6FB)),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: selected
                                ? theme.colorScheme.primary
                                : (isDark
                                    ? const Color(0xFF26324A)
                                    : const Color(0xFFDCE5F2)),
                            width: selected ? 1.5 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: selected
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                _iconForKind(opt.kind),
                                size: 19,
                                color: selected
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
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.black.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                opt.extension.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              selected
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              size: 20,
                              color: selected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: () => widget.onDownload(_selected),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.download_rounded),
                    label: Text(
                      'Unduh ${_selected.extension.toUpperCase()} Sekarang',
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
        ],
      ),
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
            const Color(0xFF0F172A),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.movie_creation_outlined,
          size: 48,
          color: Colors.white54,
        ),
      ),
    );
  }
}
