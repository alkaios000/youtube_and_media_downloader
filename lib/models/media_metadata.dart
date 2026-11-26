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
