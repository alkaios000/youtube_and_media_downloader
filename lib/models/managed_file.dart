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
  });

  MediaPlatform get platform => MediaPlatformMeta.fromKey(platformFolder);

  String get extension {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toUpperCase();
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
    );
  }
}
