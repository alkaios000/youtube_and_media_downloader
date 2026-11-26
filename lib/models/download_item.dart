import 'media_info.dart';
import 'media_platform.dart';

enum DownloadStatus {
  queued,
  downloading,
  saving,
  paused,
  completed,
  failed,
  cancelled,
}

/// Tracks live download progress & saved location of each individual file
/// inside a single-file or multi-file (album/carousel/Pixiv) download task.
class SubFileTask {
  final String id;
  final String fileName;
  final DownloadStatus status;
  final double progress; // 0..100, negative = indeterminate
  final int downloadedBytes;
  final int totalBytes;
  final String speedText;
  final String? savedPath;
  final String? contentUri;
  final String? mimeType;
  final String? errorMessage;

  const SubFileTask({
    required this.id,
    required this.fileName,
    required this.status,
    this.progress = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speedText = '',
    this.savedPath,
    this.contentUri,
    this.mimeType,
    this.errorMessage,
  });

  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.saving;

  SubFileTask copyWith({
    String? fileName,
    DownloadStatus? status,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    String? speedText,
    String? savedPath,
    String? contentUri,
    String? mimeType,
    String? errorMessage,
  }) {
    return SubFileTask(
      id: id,
      fileName: fileName ?? this.fileName,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      speedText: speedText ?? this.speedText,
      savedPath: savedPath ?? this.savedPath,
      contentUri: contentUri ?? this.contentUri,
      mimeType: mimeType ?? this.mimeType,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fileName': fileName,
      'status': status.name,
      'progress': progress,
      'downloadedBytes': downloadedBytes,
      'totalBytes': totalBytes,
      'speedText': speedText,
      'savedPath': savedPath,
      'contentUri': contentUri,
      'mimeType': mimeType,
      'errorMessage': errorMessage,
    };
  }

  factory SubFileTask.fromJson(Map<String, dynamic> json) {
    final parsedStatus = DownloadStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => DownloadStatus.completed,
    );
    return SubFileTask(
      id: json['id']?.toString() ?? '',
      fileName: json['fileName']?.toString() ?? 'file',
      status: parsedStatus,
      progress: (json['progress'] as num?)?.toDouble() ?? 100,
      downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      speedText: json['speedText']?.toString() ?? '',
      savedPath: json['savedPath']?.toString(),
      contentUri: json['contentUri']?.toString(),
      mimeType: json['mimeType']?.toString(),
      errorMessage: json['errorMessage']?.toString(),
    );
  }
}

class DownloadItem {
  final String id;
  final String sourceUrl;
  final String markerKey;
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
  final List<SubFileTask> subFiles;

  /// Persisted parameters enabling full Pause/Resume & Retry even after app restarts.
  final Map<String, dynamic>? resumePayload;

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
    this.markerKey = '',
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
    this.subFiles = const [],
    this.resumePayload,
  });

  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.saving;

  bool get isPaused => status == DownloadStatus.paused;

  bool get canResume =>
      (status == DownloadStatus.paused ||
          status == DownloadStatus.failed ||
          status == DownloadStatus.cancelled) &&
      (resumePayload != null || sourceUrl.startsWith('http'));

  int get completedSubFilesCount =>
      subFiles.where((f) => f.status == DownloadStatus.completed).length;

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
    bool clearError = false,
    List<SubFileTask>? subFiles,
    Map<String, dynamic>? resumePayload,
  }) {
    return DownloadItem(
      id: id,
      sourceUrl: sourceUrl,
      markerKey: markerKey,
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
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      createdAt: createdAt,
      subFiles: subFiles ?? this.subFiles,
      resumePayload: resumePayload ?? this.resumePayload,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sourceUrl': sourceUrl,
      'markerKey': markerKey,
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
      'subFiles': subFiles.map((e) => e.toJson()).toList(),
      if (resumePayload != null) 'resumePayload': resumePayload,
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
    final rawSubs = json['subFiles'] as List?;
    final parsedSubs = rawSubs
            ?.whereType<Map>()
            .map((e) => SubFileTask.fromJson(Map<String, dynamic>.from(e)))
            .toList(growable: false) ??
        const <SubFileTask>[];
    final rawResume = json['resumePayload'];

    return DownloadItem(
      id: json['id']?.toString() ?? '',
      sourceUrl: json['sourceUrl']?.toString() ?? '',
      markerKey: json['markerKey']?.toString() ?? '',
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
      subFiles: parsedSubs,
      resumePayload: rawResume is Map
          ? Map<String, dynamic>.from(rawResume)
          : null,
    );
  }
}
