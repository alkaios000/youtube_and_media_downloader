import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_info.dart';
import '../models/media_metadata.dart';
import '../services/download_manager.dart';
import 'app_feedback.dart';
import 'pixiv_album_viewer.dart';
import 'route_aware_listener.dart';

/// Displays all visible albums across all artists/platforms that share [tag],
/// with live **Multi-Tag Refinement** (`+ #Tag` AND filter, `- #Tag` exclude)
/// and direct entry into the global [TagExplorerScreen].
class TagAlbumsScreen extends StatefulWidget {
  final DownloadManager manager;
  final String tag;

  const TagAlbumsScreen({
    super.key,
    required this.manager,
    required this.tag,
  });

  @override
  State<TagAlbumsScreen> createState() => _TagAlbumsScreenState();
}

class _TagAlbumsScreenState extends State<TagAlbumsScreen> {
  late final Set<String> _includeTags;
  final Set<String> _excludeTags = <String>{};

  @override
  void initState() {
    super.initState();
    _includeTags = <String>{widget.tag.trim()};
  }

  void _toggleInclude(String tag) {
    final lower = tag.trim().toLowerCase();
    HapticFeedback.selectionClick();
    setState(() {
      _excludeTags.removeWhere((t) => t.toLowerCase() == lower);
      final existing = _includeTags
          .where((t) => t.toLowerCase() == lower)
          .firstOrNull;
      if (existing != null) {
        if (_includeTags.length > 1) {
          _includeTags.remove(existing);
        }
      } else {
        _includeTags.add(tag.trim());
      }
    });
  }

  void _toggleExclude(String tag) {
    final lower = tag.trim().toLowerCase();
    HapticFeedback.mediumImpact();
    setState(() {
      _includeTags.removeWhere((t) => t.toLowerCase() == lower);
      final existing = _excludeTags
          .where((t) => t.toLowerCase() == lower)
          .firstOrNull;
      if (existing != null) {
        _excludeTags.remove(existing);
      } else {
        _excludeTags.add(tag.trim());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryTag =
        _includeTags.isNotEmpty ? _includeTags.first : widget.tag;
    final isR18 = primaryTag.toLowerCase().contains('r-18');
    final accent = isR18 ? const Color(0xFFEF4444) : theme.colorScheme.primary;

    return RouteAwareListenableBuilder(
      listenable: widget.manager,
      builder: (context) {
        final matches = widget.manager.findAlbumsByTags(
          includeTags: _includeTags,
          excludeTags: _excludeTags,
        );
        final uniqueArtists =
            matches.map((m) => m.creatorFolder.toLowerCase()).toSet().length;
        final targets = matches.map((m) => m.toTarget()).toList(growable: false);

        // Co-occurring tags across currently matching albums for 1-tap multi-tag narrowing
        final selectedLower = {
          ..._includeTags.map((t) => t.toLowerCase()),
          ..._excludeTags.map((t) => t.toLowerCase()),
        };
        final relatedCounts = <String, int>{};
        final relatedDisplay = <String, String>{};
        for (final album in matches) {
          final seen = <String>{};
          for (final raw in album.tags) {
            final clean = raw.trim();
            final low = clean.toLowerCase();
            if (low.isEmpty ||
                selectedLower.contains(low) ||
                !seen.add(low)) {
              continue;
            }
            relatedDisplay.putIfAbsent(low, () => clean);
            relatedCounts[low] = (relatedCounts[low] ?? 0) + 1;
          }
        }
        final relatedTags = relatedCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));

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
                        _includeTags.length <= 1
                            ? primaryTag
                            : _includeTags.join(' + '),
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
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TagExplorerScreen(
                        manager: widget.manager,
                        initialIncludeTags: _includeTags,
                        initialExcludeTags: _excludeTags,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.filter_alt_outlined, size: 21),
                tooltip: 'Penjelajah Semua Tag',
              ),
              IconButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: primaryTag));
                  showTopToast(
                    context,
                    'Tag "#$primaryTag" disalin.',
                    icon: Icons.copy_rounded,
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 20),
                tooltip: 'Salin tag',
              ),
            ],
          ),
          body: Column(
            children: [
              // Active multi-tag filters + co-occurring tag suggestions
              if (_includeTags.length > 1 ||
                  _excludeTags.isNotEmpty ||
                  relatedTags.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: theme.colorScheme.outlineVariant
                            .withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final t in _includeTags)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: InputChip(
                              label: Text(
                                '+ #$t',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              selected: true,
                              visualDensity: VisualDensity.compact,
                              onDeleted: _includeTags.length > 1
                                  ? () => _toggleInclude(t)
                                  : null,
                            ),
                          ),
                        for (final t in _excludeTags)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: InputChip(
                              label: Text(
                                '- #$t',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  color: theme.colorScheme.error,
                                ),
                              ),
                              backgroundColor: theme.colorScheme.error
                                  .withValues(alpha: 0.14),
                              visualDensity: VisualDensity.compact,
                              onDeleted: () => _toggleExclude(t),
                            ),
                          ),
                        for (final entry in relatedTags.take(16))
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: GestureDetector(
                              onLongPress: () => _toggleExclude(
                                relatedDisplay[entry.key] ?? entry.key,
                              ),
                              child: ActionChip(
                                label: Text(
                                  '#${relatedDisplay[entry.key]} (${entry.value})',
                                  style: const TextStyle(fontSize: 11.5),
                                ),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _toggleInclude(
                                  relatedDisplay[entry.key] ?? entry.key,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

              Expanded(
                child: matches.isEmpty
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
                                'Belum ada album yang cocok dengan kombinasi tag ini.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
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
                                    manager: widget.manager,
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
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Global Tag Explorer & Multi-Tag Filter screen:
/// - Browse and search every tag across all albums sorted by popularity or A–Z.
/// - Tap chips to combine multiple required tags (AND logic).
/// - Toggle Exclude mode (or long-press any tag chip) to hide albums carrying a tag (NOT logic).
/// - Displays live matching album cards immediately below the filter bar.
class TagExplorerScreen extends StatefulWidget {
  final DownloadManager manager;
  final Set<String> initialIncludeTags;
  final Set<String> initialExcludeTags;

  const TagExplorerScreen({
    super.key,
    required this.manager,
    this.initialIncludeTags = const {},
    this.initialExcludeTags = const {},
  });

  @override
  State<TagExplorerScreen> createState() => _TagExplorerScreenState();
}

class _TagExplorerScreenState extends State<TagExplorerScreen> {
  final TextEditingController _searchController = TextEditingController();
  late final Set<String> _includeTags;
  late final Set<String> _excludeTags;
  bool _excludeTapMode = false;
  bool _sortAlpha = false;
  bool _tagsExpanded = true;

  @override
  void initState() {
    super.initState();
    _includeTags = Set<String>.from(widget.initialIncludeTags);
    _excludeTags = Set<String>.from(widget.initialExcludeTags);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _handleTagTap(String tag) {
    final lower = tag.trim().toLowerCase();
    HapticFeedback.selectionClick();
    setState(() {
      if (_excludeTapMode) {
        _includeTags.removeWhere((t) => t.toLowerCase() == lower);
        final existing =
            _excludeTags.where((t) => t.toLowerCase() == lower).firstOrNull;
        if (existing != null) {
          _excludeTags.remove(existing);
        } else {
          _excludeTags.add(tag.trim());
        }
      } else {
        _excludeTags.removeWhere((t) => t.toLowerCase() == lower);
        final existing =
            _includeTags.where((t) => t.toLowerCase() == lower).firstOrNull;
        if (existing != null) {
          _includeTags.remove(existing);
        } else {
          _includeTags.add(tag.trim());
        }
      }
    });
  }

  void _handleTagLongPress(String tag) {
    final lower = tag.trim().toLowerCase();
    HapticFeedback.mediumImpact();
    setState(() {
      _includeTags.removeWhere((t) => t.toLowerCase() == lower);
      final existing =
          _excludeTags.where((t) => t.toLowerCase() == lower).firstOrNull;
      if (existing != null) {
        _excludeTags.remove(existing);
      } else {
        _excludeTags.add(tag.trim());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RouteAwareListenableBuilder(
      listenable: widget.manager,
      builder: (context) {
        final allTags = widget.manager.getAllTagSummaries();
        final query = _searchController.text.trim().toLowerCase();
        final visibleTags = allTags.where((s) {
          if (query.isEmpty) return true;
          return s.tag.toLowerCase().contains(query);
        }).toList();
        if (_sortAlpha) {
          visibleTags.sort(
            (a, b) => a.tag.toLowerCase().compareTo(b.tag.toLowerCase()),
          );
        }

        final hasFilters = _includeTags.isNotEmpty || _excludeTags.isNotEmpty;
        final matches = widget.manager.findAlbumsByTags(
          includeTags: _includeTags,
          excludeTags: _excludeTags,
        );
        final targets = matches.map((m) => m.toTarget()).toList(growable: false);
        final includeLower =
            _includeTags.map((t) => t.toLowerCase()).toSet();
        final excludeLower =
            _excludeTags.map((t) => t.toLowerCase()).toSet();

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Penjelajah Tag',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                Text(
                  '${allTags.length} tag • ${matches.length} album cocok',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              if (hasFilters)
                TextButton(
                  onPressed: () => setState(() {
                    _includeTags.clear();
                    _excludeTags.clear();
                  }),
                  child: const Text('Reset'),
                ),
              IconButton(
                onPressed: () => setState(() => _sortAlpha = !_sortAlpha),
                icon: Icon(
                  _sortAlpha
                      ? Icons.sort_by_alpha_rounded
                      : Icons.trending_up_rounded,
                ),
                tooltip: _sortAlpha ? 'Urutkan Terbanyak' : 'Urutkan A–Z',
              ),
            ],
          ),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Search & Include/Exclude mode switch
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                hintText: 'Cari tag (mis. Original, R-18)...',
                                prefixIcon:
                                    const Icon(Icons.search_rounded, size: 20),
                                suffixIcon: _searchController.text.isNotEmpty
                                    ? IconButton(
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() {});
                                        },
                                        icon: const Icon(Icons.close_rounded,
                                            size: 18),
                                      )
                                    : null,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilterChip(
                            label: Text(
                              _excludeTapMode ? 'Kecualikan (-)' : 'Wajib (+)',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                color: _excludeTapMode
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.primary,
                              ),
                            ),
                            selected: _excludeTapMode,
                            selectedColor: theme.colorScheme.error
                                .withValues(alpha: 0.16),
                            onSelected: (v) =>
                                setState(() => _excludeTapMode = v),
                          ),
                        ],
                      ),

                      if (hasFilters) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final t in _includeTags)
                              InputChip(
                                label: Text(
                                  '+ #$t',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                selected: true,
                                visualDensity: VisualDensity.compact,
                                onDeleted: () => setState(
                                  () => _includeTags.remove(t),
                                ),
                              ),
                            for (final t in _excludeTags)
                              InputChip(
                                label: Text(
                                  '- #$t',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w800,
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                                backgroundColor: theme.colorScheme.error
                                    .withValues(alpha: 0.14),
                                visualDensity: VisualDensity.compact,
                                onDeleted: () => setState(
                                  () => _excludeTags.remove(t),
                                ),
                              ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () =>
                            setState(() => _tagsExpanded = !_tagsExpanded),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Text(
                                'Daftar Tag (${visibleTags.length}) — ketuk tambah, tahan kecualikan',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              Icon(
                                _tagsExpanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),

                      if (_tagsExpanded) ...[
                        const SizedBox(height: 6),
                        if (visibleTags.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              allTags.isEmpty
                                  ? 'Belum ada tag album tersimpan. Unduh karya Pixiv untuk menyimpan tag otomatis.'
                                  : 'Tidak ada tag yang cocok dengan pencarian.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        else
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 210),
                            child: SingleChildScrollView(
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final s in visibleTags)
                                    _ExplorerTagChip(
                                      summary: s,
                                      included: includeLower
                                          .contains(s.tag.toLowerCase()),
                                      excluded: excludeLower
                                          .contains(s.tag.toLowerCase()),
                                      onTap: () => _handleTagTap(s.tag),
                                      onLongPress: () =>
                                          _handleTagLongPress(s.tag),
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],

                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Text(
                            hasFilters
                                ? 'Hasil Filter (${matches.length} album)'
                                : 'Semua Album Bertag (${matches.length})',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              if (matches.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        hasFilters
                            ? 'Tidak ada album yang memenuhi semua kombinasi tag terpilih.'
                            : 'Belum ada album bertag untuk ditampilkan.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 28),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 0.72,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final album = matches[index];
                        return _TaggedAlbumCard(
                          album: album,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => PixivAlbumViewer(
                                  manager: widget.manager,
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
                      childCount: matches.length,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ExplorerTagChip extends StatelessWidget {
  final TagSummary summary;
  final bool included;
  final bool excluded;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ExplorerTagChip({
    required this.summary,
    required this.included,
    required this.excluded,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isR18 = summary.tag.toLowerCase().contains('r-18');
    final Color bg;
    final Color border;
    final Color fg;

    if (excluded) {
      bg = theme.colorScheme.error.withValues(alpha: 0.18);
      border = theme.colorScheme.error;
      fg = theme.colorScheme.error;
    } else if (included) {
      bg = theme.colorScheme.primary.withValues(alpha: 0.2);
      border = theme.colorScheme.primary;
      fg = theme.colorScheme.primary;
    } else if (isR18) {
      bg = const Color(0xFFEF4444).withValues(alpha: 0.12);
      border = const Color(0xFFEF4444).withValues(alpha: 0.45);
      fg = const Color(0xFFEF4444);
    } else {
      bg = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
      border = theme.colorScheme.outlineVariant.withValues(alpha: 0.4);
      fg = theme.colorScheme.onSurface;
    }

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: border,
              width: (included || excluded) ? 1.4 : 0.9,
            ),
          ),
          child: Text(
            '${excluded ? '- ' : (included ? '+ ' : '')}#${summary.tag} (${summary.albumCount})',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: (included || excluded)
                  ? FontWeight.w800
                  : FontWeight.w600,
              color: fg,
              decoration: excluded ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ),
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
