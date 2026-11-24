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
      throw Exception(
        'Link tidak valid. Tempelkan URL dari YouTube, TikTok, Douyin, Instagram, atau X.',
      );
    }

    final platform = UrlParser.detectPlatform(cleanUrl);

    // Strategy 1: Douyin (v.douyin.com / douyin.com / iesdouyin.com)
    // 1) Fast direct HTML/API attempt -> 2) Native Android Chromium WebView Sniffer
    // (solves v.douyin.com redirect + Argus JS challenge!) -> 3) yt-dlp fallback.
    if (platform == MediaPlatform.douyin) {
      final directDouyin = await _direct.extractDouyin(cleanUrl);
      if (directDouyin != null && directDouyin.options.isNotEmpty) {
        return directDouyin;
      }

      try {
        final sniffed = await bridge.sniffMedia(
          url: cleanUrl,
          platform: 'douyin',
          timeoutMs: 16000,
        );
        final fromSniffer = _buildMediaInfoFromSniff(
          originalUrl: cleanUrl,
          platform: MediaPlatform.douyin,
          sniffed: sniffed,
          extractorLabel: 'Douyin Browser Engine',
        );
        if (fromSniffer != null) return fromSniffer;
      } catch (_) {
        // Fall through to yt-dlp fallback
      }

      try {
        return await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
      } catch (e) {
        throw Exception(
          'Gagal mengambil video Douyin ($cleanUrl). Coba login singkat lewat Pengaturan -> Login Browser Douyin, lalu coba lagi.\n(${_friendlyError(e)})',
        );
      }
    }

    // Strategy 2: Instagram (Reels, Posts, Carousels, /share/ short links)
    // 1) Canonicalize /share/... -> 2) yt-dlp (uses synced browser cookies too!)
    // -> 3) Direct GraphQL/Embed -> 4) Native Android Chromium WebView Sniffer!
    if (platform == MediaPlatform.instagram) {
      final canonicalUrl = await _direct.resolveInstagramUrl(cleanUrl);

      // Try yt-dlp first (fast & supports HD audio+video merge when cookies or public API allow)
      try {
        final ytInfo = await _extractWithYtDlp(canonicalUrl, platform, cookiesPath);
        if (ytInfo.options.isNotEmpty) return ytInfo;
      } catch (_) {
        // Fall through to direct & WebView extractors
      }

      // Try direct anonymous GraphQL + Embed (handles photos & carousels too)
      final directIg = await _direct.extractInstagramDirect(canonicalUrl);
      if (directIg != null && directIg.options.isNotEmpty) {
        return directIg;
      }

      // Fallback to native Android Chromium WebView Sniffer
      try {
        final sniffed = await bridge.sniffMedia(
          url: canonicalUrl,
          platform: 'instagram',
          timeoutMs: 15000,
        );
        final fromSniffer = _buildMediaInfoFromSniff(
          originalUrl: canonicalUrl,
          platform: MediaPlatform.instagram,
          sniffed: sniffed,
          extractorLabel: 'Instagram Browser Engine',
        );
        if (fromSniffer != null) return fromSniffer;
      } catch (_) {}

      throw Exception(
        'Instagram membatasi akses anonim untuk konten ini. Buka tab Pengaturan -> Login Browser (Instagram) sekali saja, lalu tempel ulang link ini.',
      );
    }

    // Strategy 3: TikTok — try yt-dlp first, fall back to TikWM (slideshows & rate-limits).
    if (platform == MediaPlatform.tiktok) {
      try {
        final info = await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
        if (info.options.isNotEmpty) return info;
      } catch (_) {}
      final fallback = await _direct.extractTikTokFallback(cleanUrl);
      if (fallback != null && fallback.options.isNotEmpty) {
        return fallback;
      }
      throw Exception(
        'Gagal mengambil media TikTok. Pastikan tautan video publik dan coba lagi.',
      );
    }

    // Strategy 4: X (Twitter) — yt-dlp first, seamless fallback to vxtwitter/fxtwitter (videos + photos!).
    if (platform == MediaPlatform.x) {
      try {
        final info = await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
        if (info.options.isNotEmpty) return info;
      } catch (_) {}
      final fallback = await _direct.extractXFallback(cleanUrl);
      if (fallback != null && fallback.options.isNotEmpty) {
        return fallback;
      }
      throw Exception(
        'Tidak ditemukan video atau foto pada post X ini, atau post bersifat privat.',
      );
    }

    // Strategy 5: YouTube and all other supported sites via native yt-dlp engine.
    try {
      return await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
    } catch (e) {
      throw Exception(_friendlyError(e));
    }
  }

  MediaInfo? _buildMediaInfoFromSniff({
    required String originalUrl,
    required MediaPlatform platform,
    required SniffedMediaResult sniffed,
    required String extractorLabel,
  }) {
    final headers = <String, String>{
      if (sniffed.userAgent.isNotEmpty) 'User-Agent': sniffed.userAgent,
      if (sniffed.cookies.isNotEmpty) 'Cookie': sniffed.cookies,
      if (sniffed.finalUrl.startsWith('http')) 'Referer': sniffed.finalUrl,
    };

    final options = <MediaFormatOption>[];

    for (int i = 0; i < sniffed.videos.length && i < 4; i++) {
      final videoUrl = sniffed.videos[i];
      options.add(
        MediaFormatOption(
          id: 'sniff_vid_$i',
          label: sniffed.videos.length > 1
              ? 'Video Stream #${i + 1} (MP4)'
              : (platform == MediaPlatform.douyin
                  ? 'Video HD • Tanpa Watermark'
                  : 'Video HD MP4'),
          subtitle: 'MP4 • $extractorLabel',
          extension: 'mp4',
          kind: MediaKind.video,
          engine: DownloadEngine.directHttp,
          directUrl: videoUrl,
          headers: headers,
        ),
      );
    }

    if (sniffed.images.isNotEmpty) {
      final uniqueImages = sniffed.images.take(15).toList();
      options.add(
        MediaFormatOption(
          id: 'sniff_images',
          label: uniqueImages.length > 1
              ? 'Semua Foto (${uniqueImages.length} gambar)'
              : 'Foto HD',
          subtitle: 'JPG • $extractorLabel',
          extension: _guessImageExt(uniqueImages.first),
          kind: MediaKind.image,
          engine: DownloadEngine.directHttp,
          directUrl: uniqueImages.first,
          galleryUrls: uniqueImages,
          headers: headers,
        ),
      );
    }

    if (options.isEmpty) return null;

    final rawTitle = sniffed.title.trim();
    final title = rawTitle.isNotEmpty
        ? rawTitle
        : '${platform.label}_${DateTime.now().millisecondsSinceEpoch}';
    final author = sniffed.author.trim().isNotEmpty
        ? sniffed.author.trim()
        : platform.label;
    final thumb = sniffed.thumbnail.startsWith('http')
        ? sniffed.thumbnail
        : (sniffed.images.isNotEmpty ? sniffed.images.first : null);

    return MediaInfo(
      originalUrl: originalUrl,
      platform: platform,
      title: title,
      author: author,
      thumbnailUrl: thumb,
      extractorLabel: extractorLabel,
      options: options,
      thumbnailHeaders: headers,
    );
  }

  String _guessImageExt(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.png')) return 'png';
    if (lower.contains('.webp')) return 'webp';
    return 'jpg';
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
            'bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best[ext=mp4]/best',
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
    return text.isEmpty
        ? 'Terjadi kesalahan jaringan atau tautan tidak didukung.'
        : text;
  }
}
