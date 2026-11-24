import 'media_info.dart';
import 'media_platform.dart';

enum DownloadStatus {
  queued,
  downloading,
  saving,
  completed,
  failed,
  cancelled,
}

class DownloadItem {
  final String id;
  final String sourceUrl;
  final MediaPlatform platform;
  final String title;
  final String author;
  final String? thumbnailUrl;
  final String formatLabel;
  final String extension;
  final MediaKind mediaKind;
  final DownloadStatus status;
  final double progress; // 0..100, negative = indeterminate
  final String statusText;
  final int? etaSeconds;
  final String? savedPath;
  final String? contentUri;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? errorMessage;
  final DateTime createdAt;

  const DownloadItem({
    required this.id,
    required this.sourceUrl,
    required this.platform,
    required this.title,
    required this.author,
    required this.formatLabel,
    required this.extension,
    required this.mediaKind,
    required this.status,
    required this.createdAt,
    this.thumbnailUrl,
    this.progress = 0,
    this.statusText = 'Menyiapkan...',
    this.etaSeconds,
    this.savedPath,
    this.contentUri,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.errorMessage,
  });

  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.saving;

  DownloadItem copyWith({
    DownloadStatus? status,
    double? progress,
    String? statusText,
    int? etaSeconds,
    String? savedPath,
    String? contentUri,
    String? fileName,
    int? fileSize,
    String? mimeType,
    String? errorMessage,
  }) {
    return DownloadItem(
      id: id,
      sourceUrl: sourceUrl,
      platform: platform,
      title: title,
      author: author,
      thumbnailUrl: thumbnailUrl,
      formatLabel: formatLabel,
      extension: extension,
      mediaKind: mediaKind,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      statusText: statusText ?? this.statusText,
      etaSeconds: etaSeconds ?? this.etaSeconds,
      savedPath: savedPath ?? this.savedPath,
      contentUri: contentUri ?? this.contentUri,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sourceUrl': sourceUrl,
      'platform': platform.name,
      'title': title,
      'author': author,
      'thumbnailUrl': thumbnailUrl,
      'formatLabel': formatLabel,
      'extension': extension,
      'mediaKind': mediaKind.name,
      'status': status.name,
      'progress': progress,
      'statusText': statusText,
      'savedPath': savedPath,
      'contentUri': contentUri,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'errorMessage': errorMessage,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    final parsedStatus = DownloadStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => DownloadStatus.completed,
    );
    final parsedKind = MediaKind.values.firstWhere(
      (k) => k.name == json['mediaKind'],
      orElse: () => MediaKind.video,
    );

    return DownloadItem(
      id: json['id']?.toString() ?? '',
      sourceUrl: json['sourceUrl']?.toString() ?? '',
      platform: MediaPlatformMeta.fromKey(json['platform']?.toString()),
      title: json['title']?.toString() ?? 'Media',
      author: json['author']?.toString() ?? '',
      thumbnailUrl: json['thumbnailUrl']?.toString(),
      formatLabel: json['formatLabel']?.toString() ?? 'MP4',
      extension: json['extension']?.toString() ?? 'mp4',
      mediaKind: parsedKind,
      status: parsedStatus,
      progress: (json['progress'] as num?)?.toDouble() ?? 100,
      statusText: json['statusText']?.toString() ?? '',
      savedPath: json['savedPath']?.toString(),
      contentUri: json['contentUri']?.toString(),
      fileName: json['fileName']?.toString(),
      fileSize: (json['fileSize'] as num?)?.toInt(),
      mimeType: json['mimeType']?.toString(),
      errorMessage: json['errorMessage']?.toString(),
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}
