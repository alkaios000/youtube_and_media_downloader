import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_info.dart';
import '../models/media_metadata.dart';
import '../services/download_manager.dart';
import 'app_feedback.dart';
import 'pixiv_album_viewer.dart';

/// Displays all visible albums across all artists/platforms that share [tag].
/// Tapping any album opens [PixivAlbumViewer] preloaded with all matching albums
/// so the user can even swipe horizontally across every album carrying this tag.
class TagAlbumsScreen extends StatelessWidget {
  final DownloadManager manager;
  final String tag;

  const TagAlbumsScreen({
    super.key,
    required this.manager,
    required this.tag,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isR18 = tag.toLowerCase().contains('r-18');
    final accent = isR18 ? const Color(0xFFEF4444) : theme.colorScheme.primary;

    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final matches = manager.findAlbumsByTag(tag);
        final uniqueArtists =
            matches.map((m) => m.creatorFolder.toLowerCase()).toSet().length;
        final targets = matches.map((m) => m.toTarget()).toList(growable: false);

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tag_rounded, size: 17, color: accent),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        tag,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  matches.isEmpty
                      ? 'Tidak ada album yang cocok'
                      : '${matches.length} album • $uniqueArtists artist',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: tag));
                  showTopToast(
                    context,
                    'Tag "#$tag" disalin.',
                    icon: Icons.copy_rounded,
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 20),
                tooltip: 'Salin tag',
              ),
            ],
          ),
          body: matches.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.collections_bookmark_outlined,
                          size: 46,
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.55),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Belum ada album dengan tag "#$tag".',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Album mungkin sudah dihapus atau disembunyikan oleh filter Visibilitas Konten.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final album = matches[index];
                    return _TaggedAlbumCard(
                      album: album,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => PixivAlbumViewer(
                              manager: manager,
                              platformFolder: album.platformFolder,
                              creatorFolder: album.creatorFolder,
                              albumName: album.albumName,
                              albumTargets: targets,
                              initialAlbumIndex: index,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
        );
      },
    );
  }
}

class _TaggedAlbumCard extends StatelessWidget {
  final TaggedAlbumMatch album;
  final VoidCallback onTap;

  const _TaggedAlbumCard({
    required this.album,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = album.cover;
    final allPublic = album.privateCount == 0;
    final lockColor =
        allPublic ? const Color(0xFF16A34A) : const Color(0xFFF59E0B);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  cover.mediaKind == MediaKind.video
                      ? Container(
                          color:
                              const Color(0xFF0096FA).withValues(alpha: 0.22),
                          child: const Icon(
                            Icons.play_circle_filled_rounded,
                            size: 42,
                            color: Colors.white,
                          ),
                        )
                      : Image.file(
                          File(cover.savedPath),
                          cacheWidth: 420,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, _, _) => Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            alignment: Alignment.center,
                            child: const Icon(Icons.image_outlined, size: 32),
                          ),
                        ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: lockColor.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        allPublic
                            ? Icons.lock_open_rounded
                            : Icons.lock_rounded,
                        size: 11,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.68),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${album.pages.length} hal',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.albumName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${album.creatorFolder} • ${formatBytes(album.totalBytes)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
