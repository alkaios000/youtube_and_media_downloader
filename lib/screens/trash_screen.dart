import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_info.dart';
import '../models/media_metadata.dart';
import '../services/download_manager.dart';
import '../widgets/app_feedback.dart';

/// Recycle Bin / Trash management screen displaying recently deleted files
/// stored safely in `Documents/.all_download_vault/.trash/` with 1-tap restore
/// back to their exact original Private Vault or Public Gallery location.
class TrashScreen extends StatefulWidget {
  final DownloadManager manager;

  const TrashScreen({super.key, required this.manager});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(widget.manager.refreshTrashItems());
  }

  void _toggleSelect(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectionMode = true;
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _restoreIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final restored = await widget.manager.restoreTrashItems(ids);
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    if (restored > 0) {
      showTopToast(
        context,
        '$restored item dipulihkan ke lokasi semula.',
        icon: Icons.restore_from_trash_rounded,
      );
    }
  }

  Future<void> _deletePermanently(List<String> ids) async {
    if (ids.isEmpty) return;
    final ok = await showBottomDeleteConfirm(
      context,
      title: ids.length == 1
          ? 'Hapus Permanen?'
          : 'Hapus Permanen ${ids.length} Item?',
      message:
          'File yang dihapus permanen dari Sampah tidak dapat dipulihkan lagi.',
      confirmLabel: 'Hapus Permanen',
    );
    if (!ok || !mounted) return;
    await widget.manager.deleteTrashItemsPermanently(ids);
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _confirmEmptyTrash(int count) async {
    if (count == 0) return;
    final ok = await showBottomDeleteConfirm(
      context,
      title: 'Kosongkan Sampah ($count item)?',
      message:
          'Semua file di Tempat Sampah akan dihapus permanen untuk membebaskan ruang penyimpanan.',
      confirmLabel: 'Kosongkan',
    );
    if (!ok || !mounted) return;
    await widget.manager.emptyTrash();
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    showTopToast(
      context,
      'Tempat Sampah berhasil dikosongkan.',
      icon: Icons.delete_sweep_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: widget.manager,
      builder: (context, _) {
        final items = widget.manager.trashItems;
        final retentionDays = widget.manager.settings.trashRetentionDays;
        final validIds = items.map((e) => e.id).toSet();
        _selectedIds.removeWhere((id) => !validIds.contains(id));
        if (_selectedIds.isEmpty && _selectionMode) {
          _selectionMode = false;
        }
        final allSelected =
            items.isNotEmpty && _selectedIds.length == items.length;
        final totalBytes = items.fold<int>(0, (acc, e) => acc + e.fileSize);

        return Scaffold(
          appBar: _selectionMode
              ? AppBar(
                  leading: IconButton(
                    onPressed: () => setState(() {
                      _selectionMode = false;
                      _selectedIds.clear();
                    }),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  title: Text(
                    '${_selectedIds.length} dipilih',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        setState(() {
                          if (allSelected) {
                            _selectedIds.clear();
                            _selectionMode = false;
                          } else {
                            _selectedIds
                              ..clear()
                              ..addAll(items.map((e) => e.id));
                          }
                        });
                      },
                      child: Text(allSelected ? 'Batal' : 'Semua'),
                    ),
                  ],
                )
              : AppBar(
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Tempat Sampah',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        items.isEmpty
                            ? 'Kosong'
                            : '${items.length} item • ${formatBytes(totalBytes)}'
                                '${retentionDays > 0 ? ' • Auto-hapus $retentionDays hari' : ''}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    if (items.isNotEmpty) ...[
                      IconButton(
                        onPressed: () => setState(() => _selectionMode = true),
                        icon: const Icon(Icons.checklist_rounded),
                        tooltip: 'Pilih banyak',
                      ),
                      IconButton(
                        onPressed: () => _confirmEmptyTrash(items.length),
                        icon: Icon(
                          Icons.delete_sweep_rounded,
                          color: theme.colorScheme.error,
                        ),
                        tooltip: 'Kosongkan Sampah',
                      ),
                    ],
                  ],
                ),
          body: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,
                          size: 48,
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Tempat Sampah Kosong',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.manager.settings.trashEnabled
                              ? 'Foto atau video yang Anda hapus (termasuk lewat Fast Delete) akan disimpan sementara di sini agar bisa dipulihkan kapan saja.'
                              : 'Fitur Tempat Sampah sedang nonaktif. Aktifkan di Pengaturan → Unduhan & Penyimpanan.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    GridView.builder(
                      padding: EdgeInsets.fromLTRB(
                        10,
                        10,
                        10,
                        _selectionMode ? 96 : 24,
                      ),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 0.72,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final selected = _selectedIds.contains(item.id);
                        final remDays = item.remainingDays(retentionDays);

                        return GestureDetector(
                          onLongPress: () => _toggleSelect(item.id),
                          onTap: () {
                            if (_selectionMode) {
                              _toggleSelect(item.id);
                            } else {
                              _showItemActions(item);
                            }
                          },
                          child: Card(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: selected
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outlineVariant
                                        .withValues(alpha: 0.35),
                                width: selected ? 2.2 : 0.8,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      item.isImage
                                          ? Image.file(
                                              File(item.trashPath),
                                              cacheWidth: 320,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  Container(
                                                color: theme.colorScheme
                                                    .surfaceContainerHighest,
                                                child: const Icon(
                                                  Icons.image_outlined,
                                                ),
                                              ),
                                            )
                                          : Container(
                                              color: const Color(0xFF0096FA)
                                                  .withValues(alpha: 0.22),
                                              child: const Icon(
                                                Icons.play_circle_filled_rounded,
                                                size: 34,
                                                color: Colors.white,
                                              ),
                                            ),
                                      if (selected)
                                        Container(
                                          color: theme.colorScheme.primary
                                              .withValues(alpha: 0.22),
                                        ),
                                      if (remDays >= 0)
                                        Positioned(
                                          left: 4,
                                          bottom: 4,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.black
                                                  .withValues(alpha: 0.7),
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                            ),
                                            child: Text(
                                              '${remDays}h',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                        ),
                                      if (_selectionMode)
                                        Positioned(
                                          top: 5,
                                          right: 5,
                                          child: Container(
                                            width: 22,
                                            height: 22,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: selected
                                                  ? theme.colorScheme.primary
                                                  : Colors.black
                                                      .withValues(alpha: 0.5),
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 1.6,
                                              ),
                                            ),
                                            child: selected
                                                ? const Icon(
                                                    Icons.check_rounded,
                                                    size: 14,
                                                    color: Colors.white,
                                                  )
                                                : null,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(6, 5, 6, 6),
                                  child: Text(
                                    item.fileName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 200),
                      left: 12,
                      right: 12,
                      bottom:
                          _selectionMode && _selectedIds.isNotEmpty ? 14 : -100,
                      child: Material(
                        elevation: 8,
                        borderRadius: BorderRadius.circular(16),
                        color: theme.colorScheme.surfaceContainerHigh,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () =>
                                      _restoreIds(_selectedIds.toList()),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF16A34A),
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size.fromHeight(44),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.restore_from_trash_rounded,
                                    size: 18,
                                  ),
                                  label: const Text(
                                    'Pulihkan',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () =>
                                      _deletePermanently(_selectedIds.toList()),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: theme.colorScheme.error,
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size.fromHeight(44),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.delete_forever_rounded,
                                    size: 18,
                                  ),
                                  label: const Text(
                                    'Hapus Permanen',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  void _showItemActions(TrashItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                item.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                '${item.platformFolder} / ${item.creatorFolder}'
                '${item.albumFolder.isNotEmpty ? ' / ${item.albumFolder}' : ''} • ${formatBytes(item.fileSize)}',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _restoreIds([item.id]);
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.restore_from_trash_rounded,
                          size: 18),
                      label: const Text('Pulihkan'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _deletePermanently([item.id]);
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(ctx).colorScheme.error,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.delete_forever_rounded, size: 18),
                      label: const Text('Hapus'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
