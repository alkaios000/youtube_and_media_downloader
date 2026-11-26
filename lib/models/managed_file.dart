import 'media_info.dart';
import 'media_platform.dart';

class ManagedFile {
  final String fileName;
  final String mimeType;
  final MediaKind mediaKind;
  final int fileSize;
  final DateTime modifiedAt;
  final String relativePath;
  final String savedPath;
  final String contentUri;
  final String platformFolder;
  final String creatorFolder;
  final String albumFolder;
  final bool isPrivate;

  const ManagedFile({
    required this.fileName,
    required this.mimeType,
    required this.mediaKind,
    required this.fileSize,
    required this.modifiedAt,
    required this.relativePath,
    required this.savedPath,
    required this.contentUri,
    required this.platformFolder,
    required this.creatorFolder,
    this.albumFolder = '',
    this.isPrivate = false,
  });

  MediaPlatform get platform => MediaPlatformMeta.fromKey(platformFolder);

  String get uniqueKey => contentUri.isNotEmpty ? contentUri : savedPath;

  String get extension {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toUpperCase();
  }

  /// Resolves the logical album / artwork name for Pixiv per-page album grouping.
  /// Uses [albumFolder] when present, or automatically derives the album base title
  /// from legacy filenames (e.g. `Sunset_1.jpg`, `Sunset_2.jpg` -> `Sunset`).
  String get effectiveAlbumName {
    if (albumFolder.trim().isNotEmpty) return albumFolder.trim();
    final dot = fileName.lastIndexOf('.');
    var base = dot > 0 ? fileName.substring(0, dot) : fileName;
    base = base
        .replaceFirst(RegExp(r'\s*\(\d+\)$'), '')
        .replaceFirst(RegExp(r'(?:_p?|_hal|_page)\d+$', caseSensitive: false), '')
        .trim();
    return base.isNotEmpty ? base : fileName;
  }

  factory ManagedFile.fromMap(Map<dynamic, dynamic> map) {
    final kindStr = map['mediaKind']?.toString().toLowerCase() ?? 'video';
    final kind = switch (kindStr) {
      'image' => MediaKind.image,
      'audio' => MediaKind.audio,
      _ => MediaKind.video,
    };
    final modMs = (map['modifiedMs'] as num?)?.toInt() ?? 0;

    return ManagedFile(
      fileName: map['fileName']?.toString() ?? 'file',
      mimeType: map['mimeType']?.toString() ?? 'video/mp4',
      mediaKind: kind,
      fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
      modifiedAt: modMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(modMs)
          : DateTime.now(),
      relativePath: map['relativePath']?.toString() ?? '',
      savedPath: map['savedPath']?.toString() ?? '',
      contentUri: map['contentUri']?.toString() ?? '',
      platformFolder: map['platformFolder']?.toString() ?? 'Lainnya',
      creatorFolder: map['creatorFolder']?.toString() ?? 'Umum',
      albumFolder: map['albumFolder']?.toString() ?? '',
      isPrivate: map['isPrivate'] as bool? ?? false,
    );
  }
}

/// Natural numeric comparator so Pixiv album pages sort `1, 2, ..., 9, 10, 11`
/// instead of lexicographical `1, 10, 11, 2`.
int naturalCompareFileNames(String a, String b) {
  final reg = RegExp(r'(\d+)|(\D+)');
  final aMatches = reg.allMatches(a.toLowerCase()).toList();
  final bMatches = reg.allMatches(b.toLowerCase()).toList();
  final len = aMatches.length < bMatches.length ? aMatches.length : bMatches.length;

  for (int i = 0; i < len; i++) {
    final aPart = aMatches[i].group(0)!;
    final bPart = bMatches[i].group(0)!;
    final aNum = int.tryParse(aPart);
    final bNum = int.tryParse(bPart);
    final cmp = (aNum != null && bNum != null)
        ? aNum.compareTo(bNum)
        : aPart.compareTo(bPart);
    if (cmp != 0) return cmp;
  }
  return aMatches.length.compareTo(bMatches.length);
}
