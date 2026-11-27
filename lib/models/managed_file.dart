import 'dart:isolate';

import 'media_info.dart';
import 'media_platform.dart';

class ManagedFile {
  static final RegExp _trailingParenNumReg = RegExp(r'\s*\(\d+\)$');
  static final RegExp _trailingPageNumReg = RegExp(
    r'(?:_p?|_hal|_page)\d+$',
    caseSensitive: false,
  );

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

  // Plain nullable cache fields (100% isolate-safe in Dart JIT & AOT release,
  // zero RegExp/string re-allocations across 30,000–50,000+ file operations).
  String? _uniqueKey;
  MediaPlatform? _platform;
  String? _extension;
  String? _effectiveAlbumName;
  String? _albumLookupKey;
  String? _ratingKey;

  ManagedFile({
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

  String get uniqueKey =>
      _uniqueKey ??= (contentUri.isNotEmpty ? contentUri : savedPath);

  MediaPlatform get platform =>
      _platform ??= MediaPlatformMeta.fromKey(platformFolder);

  String get extension => _extension ??= _computeExtension(fileName);

  /// Resolves the logical album / artwork name for Pixiv per-page album grouping.
  /// Uses [albumFolder] when present, or automatically derives the album base title
  /// from legacy filenames (e.g. `Sunset_1.jpg`, `Sunset_2.jpg` -> `Sunset`).
  String get effectiveAlbumName =>
      _effectiveAlbumName ??= _computeEffectiveAlbumName(albumFolder, fileName);

  /// Stable lowercase album lookup key matching [AlbumMetadata.buildLookupKey].
  String get albumLookupKey => _albumLookupKey ??=
      '${platformFolder.trim().toLowerCase()}|${creatorFolder.trim().toLowerCase()}|${effectiveAlbumName.trim().toLowerCase()}';

  /// Stable logical key across Private Vault <-> Public Gallery moves & backups,
  /// used to persist per-photo content ratings (Biasa / Ecchi / NSFW).
  String get ratingKey => _ratingKey ??= buildPhotoRatingKey(
        platformFolder: platformFolder,
        creatorFolder: creatorFolder,
        albumName: effectiveAlbumName,
        fileName: fileName,
      );

  static String buildPhotoRatingKey({
    required String platformFolder,
    required String creatorFolder,
    required String albumName,
    required String fileName,
  }) {
    return '${platformFolder.trim().toLowerCase()}|${creatorFolder.trim().toLowerCase()}|${albumName.trim().toLowerCase()}|${fileName.trim().toLowerCase()}';
  }

  static String _computeExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toUpperCase();
  }

  static String _computeEffectiveAlbumName(
    String albumFolder,
    String fileName,
  ) {
    final trimmedAlbum = albumFolder.trim();
    if (trimmedAlbum.isNotEmpty) return trimmedAlbum;
    final dot = fileName.lastIndexOf('.');
    var base = dot > 0 ? fileName.substring(0, dot) : fileName;
    base = base
        .replaceFirst(_trailingParenNumReg, '')
        .replaceFirst(_trailingPageNumReg, '')
        .trim();
    return base.isNotEmpty ? base : fileName;
  }

  /// Eagerly primes all derived keys inside a background worker isolate so the
  /// Flutter UI thread incurs zero string allocation cost on first build.
  void warmKeys() {
    uniqueKey;
    platform;
    extension;
    effectiveAlbumName;
    albumLookupKey;
    ratingKey;
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

  /// Compact 12-column TSV line format shared with native Kotlin
  /// `listManagedFilesPacked()` & local index cache (`managed_files_index_v1.tsv`).
  static ManagedFile? fromPackedLine(String line) {
    if (line.isEmpty) return null;
    final parts = line.split('\t');
    if (parts.length < 12) return null;
    final kind = switch (parts[2]) {
      'image' => MediaKind.image,
      'audio' => MediaKind.audio,
      _ => MediaKind.video,
    };
    final fileSize = int.tryParse(parts[3]) ?? 0;
    final modMs = int.tryParse(parts[4]) ?? 0;
    final file = ManagedFile(
      fileName: parts[0].isEmpty ? 'file' : parts[0],
      mimeType: parts[1].isEmpty ? 'image/jpeg' : parts[1],
      mediaKind: kind,
      fileSize: fileSize,
      modifiedAt: modMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(modMs)
          : DateTime.fromMillisecondsSinceEpoch(0),
      relativePath: parts[5],
      savedPath: parts[6],
      contentUri: parts[7],
      platformFolder: parts[8].isEmpty ? 'Lainnya' : parts[8],
      creatorFolder: parts[9].isEmpty ? 'Umum' : parts[9],
      albumFolder: parts[10],
      isPrivate: parts[11] == '1',
    );
    file.warmKeys();
    return file;
  }

  String toPackedLine() {
    String clean(String s) => s
        .replaceAll('\t', ' ')
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ');
    return '${clean(fileName)}\t'
        '${clean(mimeType)}\t'
        '${mediaKind.name}\t'
        '$fileSize\t'
        '${modifiedAt.millisecondsSinceEpoch}\t'
        '${clean(relativePath)}\t'
        '${clean(savedPath)}\t'
        '${clean(contentUri)}\t'
        '${clean(platformFolder)}\t'
        '${clean(creatorFolder)}\t'
        '${clean(albumFolder)}\t'
        '${isPrivate ? '1' : '0'}';
  }
}

/// Top-level isolate-safe parser for packed TSV managed files payload.
List<ManagedFile> parsePackedManagedFiles(String raw) {
  if (raw.isEmpty) return const <ManagedFile>[];
  final out = <ManagedFile>[];
  var start = 0;
  final len = raw.length;
  while (start < len) {
    var end = raw.indexOf('\n', start);
    if (end == -1) end = len;
    if (end > start) {
      final line = raw.substring(start, end);
      final parsed = ManagedFile.fromPackedLine(line);
      if (parsed != null) out.add(parsed);
    }
    start = end + 1;
  }
  return out;
}

/// Top-level isolate runner (captures ZERO enclosing `this` instance!).
Future<List<ManagedFile>> parsePackedManagedFilesInIsolate(String raw) async {
  if (raw.isEmpty) return const <ManagedFile>[];
  if (raw.length <= 65536) return parsePackedManagedFiles(raw);
  try {
    return await Isolate.run(() => parsePackedManagedFiles(raw));
  } catch (_) {
    return parsePackedManagedFiles(raw);
  }
}

/// Top-level isolate-safe serializer for caching [ManagedFile] lists to disk.
String encodePackedManagedFiles(List<ManagedFile> files) {
  if (files.isEmpty) return '';
  final sb = StringBuffer();
  for (int i = 0; i < files.length; i++) {
    if (i > 0) sb.write('\n');
    sb.write(files[i].toPackedLine());
  }
  return sb.toString();
}

/// Top-level isolate runner (captures ZERO enclosing `this` instance!).
Future<String> encodePackedManagedFilesInIsolate(
  List<ManagedFile> files,
) async {
  if (files.isEmpty) return '';
  if (files.length < 200) return encodePackedManagedFiles(files);
  try {
    return await Isolate.run(() => encodePackedManagedFiles(files));
  } catch (_) {
    return encodePackedManagedFiles(files);
  }
}

/// Zero-allocation natural numeric comparator so Pixiv album pages sort
/// `1, 2, ..., 9, 10, 11` instead of lexicographical `1, 10, 11, 2`,
/// without compiling RegExp or allocating Lists on every comparison.
int naturalCompareFileNames(String a, String b) {
  final lenA = a.length;
  final lenB = b.length;
  var ia = 0;
  var ib = 0;

  while (ia < lenA && ib < lenB) {
    var ca = a.codeUnitAt(ia);
    var cb = b.codeUnitAt(ib);

    final isDigitA = ca >= 48 && ca <= 57;
    final isDigitB = cb >= 48 && cb <= 57;

    if (isDigitA && isDigitB) {
      // Skip leading zeros while tracking run start for tie-breaking
      final startA = ia;
      final startB = ib;
      while (ia < lenA && a.codeUnitAt(ia) == 48) {
        ia++;
      }
      while (ib < lenB && b.codeUnitAt(ib) == 48) {
        ib++;
      }
      final sigStartA = ia;
      final sigStartB = ib;
      while (ia < lenA) {
        final c = a.codeUnitAt(ia);
        if (c < 48 || c > 57) break;
        ia++;
      }
      while (ib < lenB) {
        final c = b.codeUnitAt(ib);
        if (c < 48 || c > 57) break;
        ib++;
      }
      final sigLenA = ia - sigStartA;
      final sigLenB = ib - sigStartB;
      if (sigLenA != sigLenB) return sigLenA.compareTo(sigLenB);
      for (int k = 0; k < sigLenA; k++) {
        final da = a.codeUnitAt(sigStartA + k);
        final db = b.codeUnitAt(sigStartB + k);
        if (da != db) return da.compareTo(db);
      }
      // Equal numeric value: prefer fewer leading zeros if differing
      final totalLenA = ia - startA;
      final totalLenB = ib - startB;
      if (totalLenA != totalLenB) return totalLenA.compareTo(totalLenB);
      continue;
    }

    // Fast ASCII lowercase fold
    if (ca >= 65 && ca <= 90) ca += 32;
    if (cb >= 65 && cb <= 90) cb += 32;
    if (ca != cb) return ca.compareTo(cb);
    ia++;
    ib++;
  }

  return (lenA - ia).compareTo(lenB - ib);
}
