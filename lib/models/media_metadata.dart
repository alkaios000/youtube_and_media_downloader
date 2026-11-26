import 'package:flutter/material.dart';

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
