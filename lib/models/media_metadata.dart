import 'package:flutter/material.dart';

import 'managed_file.dart';

/// User-assigned content rating per photo.
/// Every photo defaults to [ContentRating.normal] ("Biasa") until changed.
enum ContentRating {
  normal,
  ecchi,
  nsfw,
}

extension ContentRatingMeta on ContentRating {
  String get label {
    switch (this) {
      case ContentRating.normal:
        return 'Biasa';
      case ContentRating.ecchi:
        return 'Ecchi';
      case ContentRating.nsfw:
        return 'NSFW';
    }
  }

  String get description {
    switch (this) {
      case ContentRating.normal:
        return 'Konten normal / umum (default)';
      case ContentRating.ecchi:
        return 'Konten ringan / sugestif';
      case ContentRating.nsfw:
        return 'Konten dewasa / R-18';
    }
  }

  IconData get icon {
    switch (this) {
      case ContentRating.normal:
        return Icons.label_outline_rounded;
      case ContentRating.ecchi:
        return Icons.local_fire_department_rounded;
      case ContentRating.nsfw:
        return Icons.explicit_rounded;
    }
  }

  Color get color {
    switch (this) {
      case ContentRating.normal:
        return const Color(0xFF38BDF8);
      case ContentRating.ecchi:
        return const Color(0xFFF59E0B);
      case ContentRating.nsfw:
        return const Color(0xFFEF4444);
    }
  }

  static ContentRating fromName(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'ecchi':
        return ContentRating.ecchi;
      case 'nsfw':
      case 'r18':
      case 'r-18':
        return ContentRating.nsfw;
      default:
        return ContentRating.normal;
    }
  }
}

/// Persistent per-album metadata (currently Pixiv tags & illust ID),
/// keyed by sanitized `(platformFolder, creatorFolder, albumFolder)`.
class AlbumMetadata {
  final String platformFolder;
  final String creatorFolder;
  final String albumFolder;
  final String? pixivIllustId;
  final List<String> tags;
  final DateTime updatedAt;

  const AlbumMetadata({
    required this.platformFolder,
    required this.creatorFolder,
    required this.albumFolder,
    this.pixivIllustId,
    this.tags = const [],
    required this.updatedAt,
  });

  String get lookupKey => buildLookupKey(
        platformFolder,
        creatorFolder,
        albumFolder,
      );

  static String buildLookupKey(
    String platformFolder,
    String creatorFolder,
    String albumFolder,
  ) {
    return '${platformFolder.trim().toLowerCase()}|${creatorFolder.trim().toLowerCase()}|${albumFolder.trim().toLowerCase()}';
  }

  Map<String, dynamic> toJson() {
    return {
      'platformFolder': platformFolder,
      'creatorFolder': creatorFolder,
      'albumFolder': albumFolder,
      'pixivIllustId': ?pixivIllustId,
      'tags': tags,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory AlbumMetadata.fromJson(Map<String, dynamic> json) {
    final rawTags = (json['tags'] as List?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final illust = json['pixivIllustId']?.toString().trim();
    return AlbumMetadata(
      platformFolder: json['platformFolder']?.toString().trim() ?? 'Pixiv',
      creatorFolder: json['creatorFolder']?.toString().trim() ?? 'Umum',
      albumFolder: json['albumFolder']?.toString().trim() ?? '',
      pixivIllustId: (illust != null && illust.isNotEmpty) ? illust : null,
      tags: List<String>.unmodifiable(rawTags),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

/// Lightweight identifier pointing to a specific album owned by an artist.
class AlbumTarget {
  final String platformFolder;
  final String creatorFolder;
  final String albumName;

  const AlbumTarget({
    required this.platformFolder,
    required this.creatorFolder,
    required this.albumName,
  });

  String get lookupKey => AlbumMetadata.buildLookupKey(
        platformFolder,
        creatorFolder,
        albumName,
      );
}

/// Resolved album match returned when searching all albums that share a tag.
class TaggedAlbumMatch {
  final String platformFolder;
  final String creatorFolder;
  final String albumName;
  final List<ManagedFile> pages;
  final List<String> tags;
  final DateTime latestModified;
  final int totalBytes;

  const TaggedAlbumMatch({
    required this.platformFolder,
    required this.creatorFolder,
    required this.albumName,
    required this.pages,
    required this.tags,
    required this.latestModified,
    required this.totalBytes,
  });

  ManagedFile get cover => pages.first;
  int get privateCount => pages.where((p) => p.isPrivate).length;
  int get publicCount => pages.length - privateCount;

  AlbumTarget toTarget() => AlbumTarget(
        platformFolder: platformFolder,
        creatorFolder: creatorFolder,
        albumName: albumName,
      );
}

/// Summary of a tag across all visible albums (for Global Tag Explorer).
class TagSummary {
  final String tag;
  final int albumCount;

  const TagSummary({
    required this.tag,
    required this.albumCount,
  });
}

/// A media item currently sitting in the app's Recycle Bin / Trash
/// (`Documents/.all_download_vault/.trash/`) ready to be restored or purged.
class TrashItem {
  final String id;
  final String trashPath;
  final String originalPath;
  final String fileName;
  final String mimeType;
  final String mediaKind;
  final int fileSize;
  final bool isPrivate;
  final String platformFolder;
  final String creatorFolder;
  final String albumFolder;
  final DateTime deletedAt;

  const TrashItem({
    required this.id,
    required this.trashPath,
    required this.originalPath,
    required this.fileName,
    required this.mimeType,
    required this.mediaKind,
    required this.fileSize,
    required this.isPrivate,
    required this.platformFolder,
    required this.creatorFolder,
    required this.albumFolder,
    required this.deletedAt,
  });

  bool get isVideo => mediaKind == 'video' || mimeType.startsWith('video/');
  bool get isAudio => mediaKind == 'audio' || mimeType.startsWith('audio/');
  bool get isImage => !isVideo && !isAudio;

  int remainingDays(int retentionDays) {
    if (retentionDays <= 0) return -1;
    final ageDays = DateTime.now().difference(deletedAt).inDays;
    return (retentionDays - ageDays).clamp(0, retentionDays);
  }

  factory TrashItem.fromMap(Map<dynamic, dynamic> map) {
    final deletedMs = (map['deletedAtMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    return TrashItem(
      id: map['id']?.toString() ?? '',
      trashPath: map['trashPath']?.toString() ?? '',
      originalPath: map['originalPath']?.toString() ?? '',
      fileName: map['fileName']?.toString() ?? 'media',
      mimeType: map['mimeType']?.toString() ?? 'image/jpeg',
      mediaKind: map['mediaKind']?.toString() ?? 'image',
      fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
      isPrivate: map['isPrivate'] as bool? ?? true,
      platformFolder: map['platformFolder']?.toString() ?? 'Pixiv',
      creatorFolder: map['creatorFolder']?.toString() ?? 'Umum',
      albumFolder: map['albumFolder']?.toString() ?? '',
      deletedAt: DateTime.fromMillisecondsSinceEpoch(deletedMs),
    );
  }
}

/// A single kept photo/media page inside a [CuratedWorkRecord].
/// Only files the user KEPT (not deleted or skipped) remain in this list.
class CuratedKeptFile {
  /// 0-based original page index in the artwork/post (e.g. 0 for page 1, 4 for page 5).
  final int pageIndex;

  /// Exact saved file name on disk (e.g. `Sunset_2.jpg`) so re-downloading
  /// restores the exact filename and preserves per-photo ratings (Ecchi/NSFW).
  final String fileName;

  /// Optional direct media URL for non-Pixiv multi-photo posts (X/IG/TikTok).
  final String? directUrl;

  const CuratedKeptFile({
    required this.pageIndex,
    required this.fileName,
    this.directUrl,
  });

  String get normalizedFileName => fileName.trim().toLowerCase();

  Map<String, dynamic> toJson() => {
        'i': pageIndex,
        'n': fileName,
        if (directUrl != null && directUrl!.isNotEmpty) 'u': directUrl,
      };

  factory CuratedKeptFile.fromJson(Map<String, dynamic> json) {
    final idx = (json['i'] as num?)?.toInt() ??
        (json['pageIndex'] as num?)?.toInt() ??
        0;
    final name = (json['n'] ?? json['fileName'])?.toString().trim() ?? '';
    final url = (json['u'] ?? json['directUrl'])?.toString().trim();
    return CuratedKeptFile(
      pageIndex: idx < 0 ? 0 : idx,
      fileName: name,
      directUrl: (url != null && url.isNotEmpty) ? url : null,
    );
  }
}

/// Curated "Keep-Only" ledger record for a single downloaded work/album.
///
/// Workflow:
/// - When a work is downloaded, its saved pages are recorded in [keptFiles].
/// - Whenever the user deletes a photo (or moves it to Trash), that photo is
///   removed from [keptFiles]. If all pages of the work are deleted, the entire
///   [CuratedWorkRecord] is removed while its [markerKey] stays in
///   `downloadedMarkers` (so it remains excluded & finished forever).
/// - On device wipe or phone migration, restoring replays ONLY [keptFiles]
///   (exact kept page indices & filenames), never re-downloading deleted or
///   excluded items.
class CuratedWorkRecord {
  final String markerKey;
  final String sourceUrl;
  final String platformFolder;
  final String creatorFolder;
  final String albumFolder;
  final String title;
  final String? pixivIllustId;
  final bool isUgoira;
  final bool isAudioOnly;
  final int totalPages;
  final List<CuratedKeptFile> keptFiles;
  final List<String> tags;
  final DateTime updatedAt;

  const CuratedWorkRecord({
    required this.markerKey,
    required this.sourceUrl,
    required this.platformFolder,
    required this.creatorFolder,
    required this.albumFolder,
    required this.title,
    this.pixivIllustId,
    this.isUgoira = false,
    this.isAudioOnly = false,
    this.totalPages = 1,
    required this.keptFiles,
    this.tags = const [],
    required this.updatedAt,
  });

  String get albumLookupKey => AlbumMetadata.buildLookupKey(
        platformFolder,
        creatorFolder,
        albumFolder.isNotEmpty ? albumFolder : title,
      );

  bool get isPixiv =>
      (pixivIllustId != null && pixivIllustId!.isNotEmpty) ||
      platformFolder.trim().toLowerCase() == 'pixiv';

  CuratedWorkRecord copyWith({
    String? sourceUrl,
    String? platformFolder,
    String? creatorFolder,
    String? albumFolder,
    String? title,
    String? pixivIllustId,
    bool? isUgoira,
    bool? isAudioOnly,
    int? totalPages,
    List<CuratedKeptFile>? keptFiles,
    List<String>? tags,
    DateTime? updatedAt,
  }) {
    return CuratedWorkRecord(
      markerKey: markerKey,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      platformFolder: platformFolder ?? this.platformFolder,
      creatorFolder: creatorFolder ?? this.creatorFolder,
      albumFolder: albumFolder ?? this.albumFolder,
      title: title ?? this.title,
      pixivIllustId: pixivIllustId ?? this.pixivIllustId,
      isUgoira: isUgoira ?? this.isUgoira,
      isAudioOnly: isAudioOnly ?? this.isAudioOnly,
      totalPages: totalPages ?? this.totalPages,
      keptFiles: keptFiles ?? this.keptFiles,
      tags: tags ?? this.tags,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'k': markerKey,
        'u': sourceUrl,
        'p': platformFolder,
        'c': creatorFolder,
        'a': albumFolder,
        't': title,
        if (pixivIllustId != null && pixivIllustId!.isNotEmpty)
          'id': pixivIllustId,
        if (isUgoira) 'ug': true,
        if (isAudioOnly) 'au': true,
        'tp': totalPages,
        'f': keptFiles.map((e) => e.toJson()).toList(growable: false),
        if (tags.isNotEmpty) 'tg': tags,
        'at': updatedAt.toIso8601String(),
      };

  factory CuratedWorkRecord.fromJson(Map<String, dynamic> json) {
    final key = (json['k'] ?? json['markerKey'])?.toString().trim() ?? '';
    final url = (json['u'] ?? json['sourceUrl'])?.toString().trim() ?? '';
    final plat =
        (json['p'] ?? json['platformFolder'])?.toString().trim() ?? 'Pixiv';
    final creator =
        (json['c'] ?? json['creatorFolder'])?.toString().trim() ?? 'Umum';
    final album = (json['a'] ?? json['albumFolder'])?.toString().trim() ?? '';
    final title = (json['t'] ?? json['title'])?.toString().trim() ?? album;
    final illust = (json['id'] ?? json['pixivIllustId'])?.toString().trim();
    final rawFiles = (json['f'] ?? json['keptFiles']) as List?;
    final files = rawFiles
            ?.whereType<Map>()
            .map((m) => CuratedKeptFile.fromJson(Map<String, dynamic>.from(m)))
            .where((f) => f.fileName.isNotEmpty)
            .toList(growable: false) ??
        const <CuratedKeptFile>[];
    final rawTags = (json['tg'] ?? json['tags']) as List?;
    final tags = rawTags
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final tp = (json['tp'] as num?)?.toInt() ??
        (json['totalPages'] as num?)?.toInt() ??
        (files.isNotEmpty ? files.length : 1);
    return CuratedWorkRecord(
      markerKey: key,
      sourceUrl: url,
      platformFolder: plat,
      creatorFolder: creator,
      albumFolder: album,
      title: title,
      pixivIllustId: (illust != null && illust.isNotEmpty) ? illust : null,
      isUgoira: (json['ug'] ?? json['isUgoira']) as bool? ?? false,
      isAudioOnly: (json['au'] ?? json['isAudioOnly']) as bool? ?? false,
      totalPages: tp < 1 ? 1 : tp,
      keptFiles: List<CuratedKeptFile>.unmodifiable(files),
      tags: List<String>.unmodifiable(tags),
      updatedAt: DateTime.tryParse(
            (json['at'] ?? json['updatedAt'])?.toString() ?? '',
          ) ??
          DateTime.now(),
    );
  }
}

/// Summary of the Curated Catalog vs files currently present on the device.
class CuratedCatalogStatus {
  final int keptWorksCount;
  final int keptFilesCount;
  final int presentOnDeviceCount;
  final int missingOnDeviceCount;
  final int missingWorksCount;
  final int excludedMarkersCount;

  const CuratedCatalogStatus({
    required this.keptWorksCount,
    required this.keptFilesCount,
    required this.presentOnDeviceCount,
    required this.missingOnDeviceCount,
    required this.missingWorksCount,
    required this.excludedMarkersCount,
  });
}

/// Result returned when reconciling the Curated Catalog against device files.
class CuratedSyncResult {
  final int addedFiles;
  final int prunedFiles;
  final int totalKeptWorks;
  final int totalKeptFiles;
  final bool skippedPruneBecauseDeviceEmpty;

  const CuratedSyncResult({
    required this.addedFiles,
    required this.prunedFiles,
    required this.totalKeptWorks,
    required this.totalKeptFiles,
    this.skippedPruneBecauseDeviceEmpty = false,
  });
}
