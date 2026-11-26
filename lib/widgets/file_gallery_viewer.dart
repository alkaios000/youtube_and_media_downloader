import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/managed_file.dart';
import '../models/media_info.dart';
import '../services/download_manager.dart';

/// Full-screen, swipeable, pinch-to-zoom gallery viewer for downloaded images
/// with direct Share, Open Externally, Info, and Delete controls.
class FileGalleryViewer extends StatefulWidget {
  final DownloadManager manager;
  final List<ManagedFile> images;
  final int initialIndex;

  const FileGalleryViewer({
    super.key,
    required this.manager,
    required this.images,
    required this.initialIndex,
  });

  @override
  State<FileGalleryViewer> createState() => _FileGalleryViewerState();
}

class _FileGalleryViewerState extends State<FileGalleryViewer> {
  late final PageController _pageController;
  late List<ManagedFile> _images;
  late int _currentIndex;
  bool _showChrome = true;

  @override
  void initState() {
    super.initState();
    _images = List<ManagedFile>.from(widget.images);
    _currentIndex = widget.initialIndex.clamp(0, _images.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  ManagedFile get _current => _images[_currentIndex];

  @override
  Widget build(BuildContext context) {
    if (_images.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Swipeable & zoomable image pager
          GestureDetector(
            onTap: () => setState(() => _showChrome = !_showChrome),
            child: PageView.builder(
              controller: _pageController,
              itemCount: _images.length,
              onPageChanged: (idx) => setState(() => _currentIndex = idx),
              itemBuilder: (context, index) {
                final img = _images[index];
                return Center(
                  child: InteractiveViewer(
                    minScale: 1.0,
                    maxScale: 4.0,
                    child: Image.file(
                      File(img.savedPath),
                      cacheWidth: 1600,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white54,
                            size: 56,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Gagal memuat gambar',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // Top bar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            top: _showChrome ? 0 : -110,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.78),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _current.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              '${_currentIndex + 1} / ${_images.length} • ${formatBytes(_current.fileSize)}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _showInfoSheet,
                        icon: const Icon(Icons.info_outline_rounded, color: Colors.white),
                        tooltip: 'Detail File',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Bottom action bar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            bottom: _showChrome ? 0 : -110,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.82),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ViewerActionBtn(
                        icon: Icons.share_rounded,
                        label: 'Bagikan',
                        onTap: () => widget.manager.shareManagedFile(_current),
                      ),
                      _ViewerActionBtn(
                        icon: Icons.open_in_new_rounded,
                        label: 'Buka App',
                        onTap: () => widget.manager.openManagedFile(_current),
                      ),
                      _ViewerActionBtn(
                        icon: Icons.delete_outline_rounded,
                        label: 'Hapus',
                        color: const Color(0xFFF87171),
                        onTap: _confirmDeleteCurrent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteCurrent() async {
    final target = _current;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Foto?'),
        content: Text('Hapus permanen "${target.fileName}" dari perangkat?'),
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
    if (ok != true || !mounted) return;

    await widget.manager.deleteManagedFile(target);
    if (!mounted) return;
    setState(() {
      _images.removeAt(_currentIndex);
      if (_images.isEmpty) {
        Navigator.pop(context);
      } else if (_currentIndex >= _images.length) {
        _currentIndex = _images.length - 1;
      }
    });
  }

  void _showInfoSheet() {
    final f = _current;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Detail File',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 12),
              _DetailRow(label: 'Nama', value: f.fileName),
              _DetailRow(label: 'Folder', value: '${f.platformFolder} / ${f.creatorFolder}'),
              _DetailRow(label: 'Ukuran', value: formatBytes(f.fileSize)),
              _DetailRow(label: 'Format', value: f.mimeType),
              _DetailRow(label: 'Lokasi', value: f.savedPath.isNotEmpty ? f.savedPath : f.relativePath),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(
                        text: f.savedPath.isNotEmpty ? f.savedPath : f.relativePath,
                      ),
                    );
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Lokasi file disalin.')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  label: const Text('Salin Lokasi'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewerActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ViewerActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
