import 'package:flutter/material.dart';

import '../models/download_item.dart';
import '../models/media_info.dart';
import '../models/media_platform.dart';
import '../services/download_manager.dart';
import '../widgets/download_tile.dart';

enum _LibraryFilter { all, video, audio, image }

class DownloadsScreen extends StatefulWidget {
  final DownloadManager manager;

  const DownloadsScreen({super.key, required this.manager});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  _LibraryFilter _filter = _LibraryFilter.all;
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allItems = widget.manager.items;

    final filtered = allItems.where((item) {
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
    }).toList();

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          title: const Text('Riwayat Unduhan'),
          actions: [
            if (widget.manager.historyItems.isNotEmpty)
              IconButton(
                onPressed: _confirmClearHistory,
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: 'Bersihkan riwayat',
              ),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  onChanged: (v) => setState(() => _search = v),
                  decoration: const InputDecoration(
                    hintText: 'Cari judul, kreator, atau platform...',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterPill(
                        label: 'Semua (${allItems.length})',
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
              ],
            ),
          ),
        ),
        if (filtered.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_open_rounded,
                      size: 58,
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      allItems.isEmpty
                          ? 'Belum ada media diunduh'
                          : 'Tidak ada hasil yang cocok',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      allItems.isEmpty
                          ? 'Tempel tautan di tab Unduh untuk mulai menyimpan video, audio, atau foto ke folder DCIM/all_download (Galeri).'
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
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            sliver: SliverList.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final item = filtered[index];
                return DownloadTile(
                  item: item,
                  onCancel: item.isActive
                      ? () => widget.manager.cancelDownload(item.id)
                      : null,
                  onOpen: () => _openFile(item),
                  onShare: () => widget.manager.shareDownloadedItem(item),
                  onDelete: () => _confirmDeleteItem(item),
                );
              },
            ),
          ),
      ],
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
          'Daftar riwayat akan dikosongkan. File yang sudah tersimpan di folder DCIM/all_download (Galeri) tetap aman.',
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
