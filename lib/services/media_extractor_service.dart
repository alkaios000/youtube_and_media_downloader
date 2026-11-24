import 'dart:convert';

import '../models/media_info.dart';
import '../models/media_platform.dart';
import 'direct_extractors.dart';
import 'native_bridge.dart';

class MediaExtractorService {
  final NativeBridge bridge;
  final DirectExtractors _direct;

  MediaExtractorService({
    required this.bridge,
    DirectExtractors? directExtractors,
  }) : _direct = directExtractors ?? DirectExtractors();

  Future<MediaInfo> analyzeLink({
    required String rawInput,
    String? cookiesPath,
  }) async {
    final cleanUrl = UrlParser.extractUrl(rawInput);
    if (cleanUrl == null) {
      throw Exception('Link tidak valid. Tempelkan URL dari YouTube, TikTok, Douyin, Instagram, atau X.');
    }

    final platform = UrlParser.detectPlatform(cleanUrl);

    // Strategy 1: Douyin works best via direct mobile share extractor (no cookies needed),
    // falling back to yt-dlp (e.g. if user supplied Douyin cookies).
    if (platform == MediaPlatform.douyin) {
      final directDouyin = await _direct.extractDouyin(cleanUrl);
      if (directDouyin != null && directDouyin.options.isNotEmpty) {
        return directDouyin;
      }
      try {
        return await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
      } catch (e) {
        throw Exception(
          'Gagal mengambil video Douyin. Pastikan link video bersifat publik, atau tambahkan cookies Douyin di menu Pengaturan.\n(${_friendlyError(e)})',
        );
      }
    }

    // Strategy 2: TikTok — try yt-dlp first, seamlessly fall back to TikWM (great for photo slideshows & rate-limits).
    if (platform == MediaPlatform.tiktok) {
      try {
        final info = await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
        if (info.options.isNotEmpty) return info;
      } catch (_) {
        // Fall through to TikWM fallback
      }
      final fallback = await _direct.extractTikTokFallback(cleanUrl);
      if (fallback != null && fallback.options.isNotEmpty) {
        return fallback;
      }
      throw Exception('Gagal mengambil media TikTok. Pastikan tautan video publik dan coba lagi.');
    }

    // Strategy 3: X (Twitter) — try yt-dlp first, seamlessly fall back to vxtwitter/fxtwitter
    // (automatically handles photo-only tweets, GIFs, and X rate-limits!).
    if (platform == MediaPlatform.x) {
      try {
        final info = await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
        if (info.options.isNotEmpty) return info;
      } catch (_) {
        // Fall through to X direct fallback
      }
      final fallback = await _direct.extractXFallback(cleanUrl);
      if (fallback != null && fallback.options.isNotEmpty) {
        return fallback;
      }
      throw Exception(
        'Tidak ditemukan video atau foto pada post X ini, atau post bersifat privat.',
      );
    }

    // Strategy 4: YouTube, Instagram, and any other supported URL via yt-dlp native engine.
    try {
      return await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
    } catch (e) {
      final msg = _friendlyError(e);
      if (platform == MediaPlatform.instagram &&
          (msg.toLowerCase().contains('login') ||
              msg.toLowerCase().contains('cookie') ||
              msg.toLowerCase().contains('rate-limit'))) {
        throw Exception(
          'Instagram meminta autentikasi untuk konten ini. Anda bisa menempelkan cookies.txt di menu Pengaturan -> Cookies.',
        );
      }
      throw Exception(msg);
    }
  }

  Future<MediaInfo> _extractWithYtDlp(
    String url,
    MediaPlatform platform,
    String? cookiesPath,
  ) async {
    final rawJson = await bridge.extractInfo(
      url: url,
      cookiesPath: cookiesPath,
    );
    return parseYtDlpJson(rawJson, url, platform);
  }

  /// Parses raw JSON returned by `yt-dlp --dump-single-json`.
  MediaInfo parseYtDlpJson(
    String rawJson,
    String originalUrl,
    MediaPlatform platform,
  ) {
    final dynamic decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw Exception('Format metadata yt-dlp tidak dikenali.');
    }

    Map<String, dynamic> data = Map<String, dynamic>.from(decoded);

    // Handle playlists/carousels by picking the first playable entry when top-level has no formats.
    final entries = data['entries'];
    if ((data['formats'] == null || (data['formats'] as List).isEmpty) &&
        entries is List &&
        entries.isNotEmpty &&
        entries.first is Map) {
      data = Map<String, dynamic>.from(entries.first as Map);
    }

    final title = (data['title']?.toString() ??
            data['fulltitle']?.toString() ??
            data['description']?.toString() ??
            'Media ${platform.label}')
        .trim();
    final author = (data['uploader']?.toString() ??
            data['channel']?.toString() ??
            data['creator']?.toString() ??
            platform.label)
        .trim();

    final durationSec = (data['duration'] as num?)?.round();
    final duration = (durationSec != null && durationSec > 0)
        ? Duration(seconds: durationSec)
        : null;

    String? thumbnailUrl = data['thumbnail']?.toString();
    if (thumbnailUrl == null || thumbnailUrl.isEmpty) {
      final thumbs = data['thumbnails'];
      if (thumbs is List && thumbs.isNotEmpty) {
        final lastThumb = thumbs.last;
        if (lastThumb is Map) {
          thumbnailUrl = lastThumb['url']?.toString();
        }
      }
    }

    final rawFormats = (data['formats'] as List?)?.whereType<Map>().toList() ?? [];

    // Discover best audio size & available video heights
    int? bestAudioBytes;
    final heightToVideoBytes = <int, int>{};
    final detectedHeights = <int>{};

    for (final fmt in rawFormats) {
      final vcodec = fmt['vcodec']?.toString() ?? '';
      final acodec = fmt['acodec']?.toString() ?? '';
      final size = (fmt['filesize'] as num?)?.toInt() ??
          (fmt['filesize_approx'] as num?)?.toInt();

      final hasVideo = vcodec.isNotEmpty && vcodec != 'none';
      final hasAudio = acodec.isNotEmpty && acodec != 'none';

      if (!hasVideo && hasAudio && size != null) {
        if (bestAudioBytes == null || size > bestAudioBytes) {
          bestAudioBytes = size;
        }
      }

      if (hasVideo) {
        final h = (fmt['height'] as num?)?.toInt();
        if (h != null && h >= 144) {
          detectedHeights.add(h);
          if (size != null) {
            final current = heightToVideoBytes[h];
            if (current == null || size > current) {
              heightToVideoBytes[h] = size;
            }
          }
        }
      }
    }

    final options = <MediaFormatOption>[];

    // Always offer "Best HD Auto" first
    final maxHeight = detectedHeights.isEmpty
        ? null
        : detectedHeights.reduce((a, b) => a > b ? a : b);
    final maxSize = maxHeight != null && heightToVideoBytes[maxHeight] != null
        ? heightToVideoBytes[maxHeight]! + (bestAudioBytes ?? 0)
        : null;

    options.add(
      MediaFormatOption(
        id: 'ytdlp_best',
        label: maxHeight != null
            ? 'Terbaik (${_qualityBadge(maxHeight)})'
            : 'Video Terbaik (Auto HD)',
        subtitle: [
          'MP4 • Kualitas Maksimal',
          if (maxSize != null && maxSize > 0) '~${formatBytes(maxSize)}',
        ].join(' • '),
        extension: 'mp4',
        kind: MediaKind.video,
        engine: DownloadEngine.ytDlp,
        height: maxHeight,
        estimatedBytes: maxSize,
        ytDlpFormatSelector:
            'bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best',
      ),
    );

    // Add clean standard resolution buckets actually supported by this media
    const standardTiers = [2160, 1440, 1080, 720, 480, 360];
    for (final tier in standardTiers) {
      final matchingHeights = detectedHeights
          .where((h) => h <= tier && h > (tier == 360 ? 240 : _lowerBound(tier)))
          .toList();
      if (matchingHeights.isEmpty) continue;
      if (maxHeight != null && tier == maxHeight && detectedHeights.length <= 1) {
        continue;
      }

      matchingHeights.sort();
      final exactH = matchingHeights.last;
      final vidBytes = heightToVideoBytes[exactH];
      final estBytes = vidBytes != null ? vidBytes + (bestAudioBytes ?? 0) : null;

      options.add(
        MediaFormatOption(
          id: 'ytdlp_${tier}p',
          label: 'Video ${_qualityBadge(tier)}',
          subtitle: [
            'MP4',
            if (estBytes != null && estBytes > 0) '~${formatBytes(estBytes)}',
          ].join(' • '),
          extension: 'mp4',
          kind: MediaKind.video,
          engine: DownloadEngine.ytDlp,
          height: tier,
          estimatedBytes: estBytes,
          ytDlpFormatSelector:
              'bestvideo[height<=$tier][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=$tier]+bestaudio/best[height<=$tier]/best',
        ),
      );
    }

    // Audio extraction presets
    options.add(
      MediaFormatOption(
        id: 'ytdlp_mp3',
        label: 'Audio MP3',
        subtitle: [
          'Konversi FFmpeg Kualitas Tinggi',
          if (bestAudioBytes != null && bestAudioBytes > 0)
            '~${formatBytes(bestAudioBytes)}',
        ].join(' • '),
        extension: 'mp3',
        kind: MediaKind.audio,
        engine: DownloadEngine.ytDlp,
        estimatedBytes: bestAudioBytes,
      ),
    );

    options.add(
      MediaFormatOption(
        id: 'ytdlp_m4a',
        label: 'Audio M4A',
        subtitle: 'Format AAC Ringan',
        extension: 'm4a',
        kind: MediaKind.audio,
        engine: DownloadEngine.ytDlp,
        estimatedBytes: bestAudioBytes,
      ),
    );

    final extractor = data['extractor_key']?.toString() ?? 'yt-dlp';

    return MediaInfo(
      originalUrl: originalUrl,
      platform: platform,
      title: title,
      author: author,
      thumbnailUrl: thumbnailUrl,
      duration: duration,
      extractorLabel: 'yt-dlp ($extractor)',
      options: options,
    );
  }

  int _lowerBound(int tier) {
    switch (tier) {
      case 2160:
        return 1440;
      case 1440:
        return 1080;
      case 1080:
        return 720;
      case 720:
        return 480;
      case 480:
        return 360;
      default:
        return 0;
    }
  }

  String _qualityBadge(int height) {
    if (height >= 2160) return '4K 2160p';
    if (height >= 1440) return '2K 1440p';
    if (height >= 1080) return '1080p Full HD';
    if (height >= 720) return '720p HD';
    return '${height}p';
  }

  String _friendlyError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '').trim();
    if (text.contains('PlatformException')) {
      final parts = text.split(',');
      if (parts.length >= 2) {
        return parts[1].trim();
      }
    }
    return text.isEmpty ? 'Terjadi kesalahan jaringan atau tautan tidak didukung.' : text;
  }
}
