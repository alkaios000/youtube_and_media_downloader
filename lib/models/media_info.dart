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

/// Represents a single selectable photo (in a multi-photo post) OR a single
/// post/artwork inside a profile/playlist bulk collection.
class SelectableMediaItem {
  final String id;
  final String title;
  final String? thumbnailUrl;
  final String? directUrl;
  final String? sourcePostUrl;
  final String extension;
  final MediaKind kind;
  final DownloadEngine engine;
  final Map<String, String> headers;
  final String badgeLabel;
  final String? author;

  /// If non-null, downloading this item resolves all full-resolution pages of the Pixiv illust ID.
  final String? pixivIllustId;

  /// Stable canonical key used to remember & display "Sudah diunduh" badges across sessions.
  String get markerKey {
    if (pixivIllustId != null && pixivIllustId!.isNotEmpty) {
      return 'pixiv:$pixivIllustId';
    }
    return canonicalMarkerKey(sourcePostUrl ?? directUrl ?? id);
  }

  const SelectableMediaItem({
    required this.id,
    required this.title,
    required this.extension,
    required this.kind,
    required this.engine,
    this.thumbnailUrl,
    this.directUrl,
    this.sourcePostUrl,
    this.headers = const {},
    this.badgeLabel = '',
    this.author,
    this.pixivIllustId,
  });

  String get mimeType {
    switch (extension.toLowerCase()) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
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
        return kind == MediaKind.audio
            ? 'audio/mpeg'
            : (kind == MediaKind.image ? 'image/jpeg' : 'video/mp4');
    }
  }
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

  /// For direct HTTP downloads (Douyin no-watermark, TikWM, vxtwitter, Pixiv, images)
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

  /// Non-empty when a link contains multiple selectable photos OR a profile/playlist collection.
  final List<SelectableMediaItem> selectableItems;
  final bool isBulkProfile;

  /// Canonical profile URL of the creator/artist when derivable (for 1-tap "Lanjut Unduh").
  final String? creatorProfileUrl;

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
    this.selectableItems = const [],
    this.isBulkProfile = false,
    this.creatorProfileUrl,
  });

  bool get hasSelectableGallery => selectableItems.length > 1 || isBulkProfile;

  String get markerKey => canonicalMarkerKey(originalUrl);

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

String canonicalMarkerKey(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';

  final pixivArt = RegExp(r'pixiv\.net/(?:en/)?artworks/(\d+)').firstMatch(trimmed);
  if (pixivArt != null) return 'pixiv:${pixivArt.group(1)}';

  final ytWatch = RegExp(r'(?:youtu\.be/|youtube\.com/(?:watch\?v=|shorts/))([A-Za-z0-9_-]{6,20})')
      .firstMatch(trimmed);
  if (ytWatch != null) return 'yt:${ytWatch.group(1)}';

  final igCode = RegExp(r'instagram\.com/(?:reel|reels|p|tv)/([A-Za-z0-9_-]{5,30})')
      .firstMatch(trimmed);
  if (igCode != null) return 'ig:${igCode.group(1)}';

  final xTweet = RegExp(r'(?:x\.com|twitter\.com)/[^/]+/status/(\d+)').firstMatch(trimmed);
  if (xTweet != null) return 'x:${xTweet.group(1)}';

  final ttVideo = RegExp(r'tiktok\.com/[^/]+/(?:video|photo)/(\d+)').firstMatch(trimmed);
  if (ttVideo != null) return 'tt:${ttVideo.group(1)}';

  final dyVideo = RegExp(r'(?:douyin|iesdouyin)\.com/(?:share/)?(?:video|note)/(\d+)')
      .firstMatch(trimmed);
  if (dyVideo != null) return 'dy:${dyVideo.group(1)}';

  // Fallback: strip query params & trailing slashes for stable matching
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.isNotEmpty) {
    final cleanPath = uri.path.replaceAll(RegExp(r'/+$'), '');
    return 'url:${uri.host.toLowerCase()}$cleanPath';
  }
  return 'raw:${trimmed.toLowerCase()}';
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
