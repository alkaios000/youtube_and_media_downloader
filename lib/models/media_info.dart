import 'media_platform.dart';

enum DownloadEngine {
  ytDlp,
  directHttp,
}

enum MediaKind {
  video,
  audio,
  image,
}

class MediaFormatOption {
  final String id;
  final String label;
  final String subtitle;
  final String extension;
  final MediaKind kind;
  final DownloadEngine engine;
  final int? height;
  final int? estimatedBytes;

  /// For yt-dlp downloads
  final String? ytDlpFormatSelector;

  /// For direct HTTP downloads (Douyin no-watermark, TikWM, vxtwitter, images)
  final String? directUrl;
  final List<String> galleryUrls;
  final Map<String, String> headers;

  const MediaFormatOption({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.extension,
    required this.kind,
    required this.engine,
    this.height,
    this.estimatedBytes,
    this.ytDlpFormatSelector,
    this.directUrl,
    this.galleryUrls = const [],
    this.headers = const {},
  });

  bool get isAudio => kind == MediaKind.audio;
  bool get isImage => kind == MediaKind.image;
  bool get isMultiImage => kind == MediaKind.image && galleryUrls.length > 1;

  String get mimeType {
    switch (extension.toLowerCase()) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      default:
        return isAudio
            ? 'audio/mpeg'
            : (isImage ? 'image/jpeg' : 'video/mp4');
    }
  }
}

class MediaInfo {
  final String originalUrl;
  final MediaPlatform platform;
  final String title;
  final String author;
  final String? thumbnailUrl;
  final Duration? duration;
  final String extractorLabel;
  final List<MediaFormatOption> options;
  final Map<String, String> thumbnailHeaders;

  const MediaInfo({
    required this.originalUrl,
    required this.platform,
    required this.title,
    required this.author,
    required this.options,
    required this.extractorLabel,
    this.thumbnailUrl,
    this.duration,
    this.thumbnailHeaders = const {},
  });

  String get formattedDuration {
    final d = duration;
    if (d == null || d.inSeconds <= 0) return '';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString()}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  double size = bytes.toDouble();
  int unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  final decimals = unitIndex == 0 ? 0 : (size >= 100 ? 0 : 1);
  return '${size.toStringAsFixed(decimals)} ${units[unitIndex]}';
}
