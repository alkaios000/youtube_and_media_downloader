import 'dart:io';

import 'package:flutter/material.dart';

import '../models/managed_file.dart';
import '../models/media_info.dart';
import '../models/media_platform.dart';
import '../services/download_manager.dart';

/// Dedicated "File" explorer tab:
/// Level 0: Platform folders (YouTube, TikTok, Instagram, Pixiv, Facebook, Douyin, X)
/// Level 1: Creator / Username folders inside the selected platform
/// Level 2: Downloaded files (video, photo, audio) inside the selected username folder
class FilesScreen extends StatefulWidget {
  final DownloadManager manager;

  const FilesScreen({super.key, required this.manager});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  String? _selectedPlatformFolder;
  String? _selectedCreatorFolder;

  void _goBackOneLevel() {
    setState(() {
      if (_selectedCreatorFolder != null) {
        _selectedCreatorFolder = null;
      } else if (_selectedPlatformFolder != null) {
        _selectedPlatformFolder = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allFiles = widget.manager.managedFiles;
    final canPopFolder =
        _selectedPlatformFolder != null || _selectedCreatorFolder != null;

    // Group: platform -> creator -> files
    final byPlatform = <String, Map<String, List<ManagedFile>>>{};
    for (final file in allFiles) {
      final platMap = byPlatform.putIfAbsent(file.platformFolder, () => {});
      platMap.putIfAbsent(file.creatorFolder, () => []).add(file);
    }

    // Reset stale navigation if folder was deleted
    if (_selectedPlatformFolder != null &&
        !byPlatform.containsKey(_selectedPlatformFolder)) {
      _selectedPlatformFolder = null;
      _selectedCreatorFolder = null;
    } else if (_selectedPlatformFolder != null &&
        _selectedCreatorFolder != null &&
        !(byPlatform[_selectedPlatformFolder]
                ?.containsKey(_selectedCreatorFolder) ??
            false)) {
      _selectedCreatorFolder = null;
    }

    return PopScope(
      canPop: !canPopFolder,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && canPopFolder) {
          _goBackOneLevel();
        }
      },
      child: RefreshIndicator(
        onRefresh: widget.manager.refreshManagedFiles,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              floating: true,
              leading: canPopFolder
                  ? IconButton(
                      onPressed: _goBackOneLevel,
                      icon: const Icon(Icons.arrow_back_rounded),
                    )
                  : null,
              title: Text(
                _selectedCreatorFolder ??
                    _selectedPlatformFolder ??
                    'File Unduhan',
              ),
              actions: [
                IconButton(
                  onPressed: widget.manager.refreshManagedFiles,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Segarkan folder',
                ),
              ],
            ),

            // Interactive Breadcrumb Bar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
                        }),
                      ),
                      if (_selectedPlatformFolder != null) ...[
                        const Icon(Icons.chevron_right_rounded, size: 18),
                        _BreadcrumbChip(
                          label: _selectedPlatformFolder!,
                          active: _selectedCreatorFolder == null,
                          onTap: () => setState(() {
                            _selectedCreatorFolder = null;
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
            else
              _buildFilesListSliver(
                byPlatform[_selectedPlatformFolder!]?[_selectedCreatorFolder!] ??
                    const [],
              ),
          ],
        ),
      ),
    );
  }

  // LEVEL 0: Folders by App / Platform
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

  // LEVEL 1: Folders by Username / Creator inside Platform
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
                  child: sampleImage != null && File(sampleImage.savedPath).existsSync()
                      ? Image.file(
                          File(sampleImage.savedPath),
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

  // LEVEL 2: Actual Files inside <Platform>/<Username>/
  Widget _buildFilesListSliver(List<ManagedFile> files) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      sliver: SliverList.separated(
        itemCount: files.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final file = files[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _openFile(file),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
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
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => widget.manager.shareManagedFile(file),
                      icon: const Icon(Icons.share_outlined, size: 20),
                      tooltip: 'Bagikan',
                    ),
                    IconButton(
                      onPressed: () => _confirmDelete(file),
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      tooltip: 'Hapus',
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openFile(ManagedFile file) async {
    final ok = await widget.manager.openManagedFile(file);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tidak ada aplikasi pemutar yang cocok atau file sudah dipindah.'),
        ),
      );
    }
  }

  Future<void> _confirmDelete(ManagedFile file) async {
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

  String _fmtDate(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$d/$m $hh:$mm';
  }
}

class _FileThumb extends StatelessWidget {
  final ManagedFile file;

  const _FileThumb({required this.file});

  @override
  Widget build(BuildContext context) {
    final isLocalImg = file.mediaKind == MediaKind.image &&
        file.savedPath.isNotEmpty &&
        File(file.savedPath).existsSync();

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
