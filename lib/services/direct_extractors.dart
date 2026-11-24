import 'dart:convert';
import 'package:dio/dio.dart';

import '../models/media_info.dart';
import '../models/media_platform.dart';

class DirectExtractors {
  static const String _mobileSafariUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 '
      'Mobile/15E148 Safari/604.1';

  static const String _desktopChromeUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  final Dio _dio;

  DirectExtractors({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 25),
                sendTimeout: const Duration(seconds: 20),
                validateStatus: (status) => status != null && status < 500,
              ),
            );

  /// Direct watermark-free Douyin extractor via mobile share page `_ROUTER_DATA`.
  /// Works without requiring Douyin login cookies on most public videos & notes.
  Future<MediaInfo?> extractDouyin(String url) async {
    try {
      final resolvedUrl = await _resolveRedirects(url, userAgent: _mobileSafariUa);
      final awemeId = _extractDouyinId(resolvedUrl) ?? _extractDouyinId(url);
      if (awemeId == null) return null;

      final candidatePages = [
        'https://www.iesdouyin.com/share/video/$awemeId/',
        'https://www.iesdouyin.com/share/note/$awemeId/',
      ];

      Map<String, dynamic>? item;
      for (final shareUrl in candidatePages) {
        final response = await _dio.get<String>(
          shareUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: {
              'User-Agent': _mobileSafariUa,
              'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            },
          ),
        );

        final html = response.data ?? '';
        if (html.isEmpty) continue;

        final parsed = _parseDouyinRouterData(html);
        if (parsed != null) {
          item = parsed;
          break;
        }
      }

      if (item == null) return null;

      final desc = (item['desc']?.toString() ?? '').trim();
      final authorMap = item['author'] as Map?;
      final author = (authorMap?['nickname']?.toString() ?? 'Kreator Douyin').trim();
      final title = desc.isNotEmpty ? desc : 'Douyin_$awemeId';

      final videoMap = item['video'] as Map?;
      final durationMs = (item['duration'] as num?)?.toInt() ??
          (videoMap?['duration'] as num?)?.toInt() ??
          0;
      final duration = durationMs > 0
          ? Duration(milliseconds: durationMs > 1000 ? durationMs : durationMs * 1000)
          : null;

      String? coverUrl = _firstUrlFromMap(videoMap?['origin_cover'] as Map?) ??
          _firstUrlFromMap(videoMap?['cover'] as Map?);

      final options = <MediaFormatOption>[];
      const downloadHeaders = {'User-Agent': _mobileSafariUa};

      // 1. Check photo/note gallery posts first
      final rawImages = item['images'] as List?;
      if (rawImages != null && rawImages.isNotEmpty) {
        final imageUrls = <String>[];
        for (final img in rawImages) {
          if (img is Map) {
            final u = _pickBestImageUrl(img['url_list'] as List?);
            if (u != null) imageUrls.add(u);
          }
        }
        if (imageUrls.isNotEmpty) {
          coverUrl ??= imageUrls.first;
          options.add(
            MediaFormatOption(
              id: 'douyin_images_all',
              label: imageUrls.length > 1
                  ? 'Semua Foto (${imageUrls.length} gambar)'
                  : 'Foto HD',
              subtitle: 'JPG/WEBP • Tanpa Watermark',
              extension: _guessImageExt(imageUrls.first),
              kind: MediaKind.image,
              engine: DownloadEngine.directHttp,
              directUrl: imageUrls.first,
              galleryUrls: imageUrls,
              headers: downloadHeaders,
            ),
          );
        }
      }

      // 2. Video stream (replace playwm -> play for watermark-free video)
      if (videoMap != null) {
        final seenUrls = <String>{};
        final bitRates = videoMap['bit_rate'] as List?;
        if (bitRates != null && bitRates.isNotEmpty) {
          for (final br in bitRates) {
            if (br is! Map) continue;
            final playAddr = br['play_addr'] as Map?;
            final rawPlayUrl = _firstUrlFromMap(playAddr);
            if (rawPlayUrl == null) continue;
            final cleanUrl = _cleanDouyinVideoUrl(rawPlayUrl);
            if (!seenUrls.add(cleanUrl)) continue;

            final width = (playAddr?['width'] as num?)?.toInt();
            final height = (playAddr?['height'] as num?)?.toInt();
            final dataSize = (playAddr?['data_size'] as num?)?.toInt();
            final gearName = br['gear_name']?.toString() ?? '';
            final resLabel = (height != null && height > 0)
                ? '${height}p MP4'
                : (gearName.isNotEmpty ? 'Video ($gearName)' : 'Video HD');

            options.add(
              MediaFormatOption(
                id: 'douyin_br_${options.length}',
                label: '$resLabel • Tanpa Watermark',
                subtitle: [
                  if (width != null && height != null) '${width}x$height',
                  if (dataSize != null && dataSize > 0) formatBytes(dataSize),
                  'Direct CDN',
                ].join(' • '),
                extension: 'mp4',
                kind: MediaKind.video,
                engine: DownloadEngine.directHttp,
                height: height,
                estimatedBytes: dataSize,
                directUrl: cleanUrl,
                headers: downloadHeaders,
              ),
            );
          }
        }

        final primaryPlayUrl = _firstUrlFromMap(videoMap['play_addr'] as Map?);
        if (primaryPlayUrl != null) {
          final cleanUrl = _cleanDouyinVideoUrl(primaryPlayUrl);
          if (seenUrls.add(cleanUrl)) {
            final height = (videoMap['height'] as num?)?.toInt();
            final size = (videoMap['play_addr']?['data_size'] as num?)?.toInt();
            options.insert(
              0,
              MediaFormatOption(
                id: 'douyin_hd',
                label: 'Video HD • Tanpa Watermark',
                subtitle: [
                  'MP4',
                  if (height != null && height > 0) '${height}p',
                  if (size != null && size > 0) formatBytes(size),
                ].join(' • '),
                extension: 'mp4',
                kind: MediaKind.video,
                engine: DownloadEngine.directHttp,
                height: height,
                estimatedBytes: size,
                directUrl: cleanUrl,
                headers: downloadHeaders,
              ),
            );
          }
        }
      }

      // 3. Background music / audio stream
      final musicMap = item['music'] as Map?;
      final musicUrl = _firstUrlFromMap(musicMap?['play_url'] as Map?);
      if (musicUrl != null) {
        final secureAudio = musicUrl.replaceFirst('http://', 'https://');
        options.add(
          MediaFormatOption(
            id: 'douyin_audio',
            label: 'Audio Asli (MP3)',
            subtitle: musicMap?['title']?.toString().isNotEmpty == true
                ? musicMap!['title'].toString()
                : 'Musik Latar Douyin',
            extension: 'mp3',
            kind: MediaKind.audio,
            engine: DownloadEngine.directHttp,
            directUrl: secureAudio,
            headers: downloadHeaders,
          ),
        );
      }

      if (options.isEmpty) return null;

      return MediaInfo(
        originalUrl: url,
        platform: MediaPlatform.douyin,
        title: title,
        author: author,
        thumbnailUrl: coverUrl?.replaceFirst('http://', 'https://'),
        duration: duration,
        extractorLabel: 'Douyin Direct Engine',
        options: options,
        thumbnailHeaders: downloadHeaders,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fallback extractor for TikTok (no-watermark HD video, slideshow photos, and audio)
  /// via TikWM public JSON API if yt-dlp fails or for photo carousel posts.
  Future<MediaInfo?> extractTikTokFallback(String url) async {
    try {
      final response = await _dio.get<dynamic>(
        'https://www.tikwm.com/api/',
        queryParameters: {'url': url, 'hd': 1},
        options: Options(
          headers: {'User-Agent': _mobileSafariUa},
        ),
      );

      final body = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (body is! Map || body['code'] != 0) return null;

      final data = body['data'] as Map?;
      if (data == null) return null;

      final title = (data['title']?.toString() ?? '').trim();
      final authorMap = data['author'] as Map?;
      final author = (authorMap?['nickname']?.toString() ??
              authorMap?['unique_id']?.toString() ??
              'Kreator TikTok')
          .trim();
      final cover = data['cover']?.toString() ?? data['origin_cover']?.toString();
      final durSec = (data['duration'] as num?)?.toInt() ?? 0;

      final options = <MediaFormatOption>[];

      // Slideshow images
      final images = (data['images'] as List?)
          ?.map((e) => e.toString())
          .where((e) => e.startsWith('http'))
          .toList();
      if (images != null && images.isNotEmpty) {
        options.add(
          MediaFormatOption(
            id: 'tt_images',
            label: images.length > 1
                ? 'Slideshow Foto (${images.length} gambar)'
                : 'Foto TikTok HD',
            subtitle: 'JPG • Tanpa Watermark',
            extension: 'jpg',
            kind: MediaKind.image,
            engine: DownloadEngine.directHttp,
            directUrl: images.first,
            galleryUrls: images,
          ),
        );
      }

      // HD no-watermark video
      final hdPlay = data['hdplay']?.toString();
      if (hdPlay != null && hdPlay.startsWith('http')) {
        final hdSize = (data['hd_size'] as num?)?.toInt();
        options.add(
          MediaFormatOption(
            id: 'tt_hd',
            label: 'Video HD • Tanpa Watermark',
            subtitle: [
              'MP4 Full HD',
              if (hdSize != null && hdSize > 0) formatBytes(hdSize),
            ].join(' • '),
            extension: 'mp4',
            kind: MediaKind.video,
            engine: DownloadEngine.directHttp,
            height: 1080,
            estimatedBytes: hdSize,
            directUrl: hdPlay,
          ),
        );
      }

      // Standard no-watermark video
      final sdPlay = data['play']?.toString();
      if (sdPlay != null && sdPlay.startsWith('http') && sdPlay != hdPlay) {
        final sdSize = (data['size'] as num?)?.toInt();
        options.add(
          MediaFormatOption(
            id: 'tt_sd',
            label: 'Video Standar • Tanpa Watermark',
            subtitle: [
              'MP4 Hemat Kuota',
              if (sdSize != null && sdSize > 0) formatBytes(sdSize),
            ].join(' • '),
            extension: 'mp4',
            kind: MediaKind.video,
            engine: DownloadEngine.directHttp,
            height: 720,
            estimatedBytes: sdSize,
            directUrl: sdPlay,
          ),
        );
      }

      // Audio
      final music = data['music']?.toString();
      if (music != null && music.startsWith('http')) {
        options.add(
          MediaFormatOption(
            id: 'tt_audio',
            label: 'Audio MP3',
            subtitle: data['music_info']?['title']?.toString() ?? 'Suara Asli TikTok',
            extension: 'mp3',
            kind: MediaKind.audio,
            engine: DownloadEngine.directHttp,
            directUrl: music,
          ),
        );
      }

      if (options.isEmpty) return null;

      return MediaInfo(
        originalUrl: url,
        platform: MediaPlatform.tiktok,
        title: title.isNotEmpty ? title : 'TikTok_${data['id'] ?? 'video'}',
        author: author,
        thumbnailUrl: cover,
        duration: durSec > 0 ? Duration(seconds: durSec) : null,
        extractorLabel: 'TikTok Fast Engine',
        options: options,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fallback extractor for X (Twitter) supporting videos, GIFs, AND photo tweets
  /// via public vxtwitter / fxtwitter JSON endpoints.
  Future<MediaInfo?> extractXFallback(String url) async {
    try {
      final resolvedUrl = url.contains('t.co/')
          ? await _resolveRedirects(url, userAgent: _mobileSafariUa)
          : url;

      final statusMatch = RegExp(
        r'(?:x\.com|twitter\.com|fxtwitter\.com|vxtwitter\.com|fixupx\.com)/([^/\s]+)/status/(\d+)',
        caseSensitive: false,
      ).firstMatch(resolvedUrl);

      if (statusMatch == null) return null;
      final handle = statusMatch.group(1)!;
      final tweetId = statusMatch.group(2)!;

      // Try vxtwitter first, then fxtwitter
      final vxInfo = await _tryVxTwitter(url, handle, tweetId);
      if (vxInfo != null) return vxInfo;
      return await _tryFxTwitter(url, handle, tweetId);
    } catch (_) {
      return null;
    }
  }

  Future<MediaInfo?> _tryVxTwitter(String originalUrl, String handle, String tweetId) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://api.vxtwitter.com/$handle/status/$tweetId',
        options: Options(headers: {'User-Agent': 'all_download/1.0'}),
      );
      if (res.statusCode != 200) return null;
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (data is! Map) return null;

      final text = (data['text']?.toString() ?? '').trim();
      final authorName = (data['user_name']?.toString() ?? '@$handle').trim();
      final mediaExtended = data['media_extended'] as List?;
      if (mediaExtended == null || mediaExtended.isEmpty) return null;

      final options = <MediaFormatOption>[];
      final photoUrls = <String>[];
      String? thumb;
      Duration? duration;

      int videoIdx = 1;
      for (final item in mediaExtended) {
        if (item is! Map) continue;
        final type = item['type']?.toString().toLowerCase() ?? '';
        final mediaUrl = item['url']?.toString();
        final itemThumb = item['thumbnail_url']?.toString();
        if (mediaUrl == null || !mediaUrl.startsWith('http')) continue;

        if (type == 'video' || type == 'gif') {
          thumb ??= itemThumb;
          final durMs = (item['duration_millis'] as num?)?.toInt() ?? 0;
          if (durMs > 0) duration ??= Duration(milliseconds: durMs);

          final sizeMap = item['size'] as Map?;
          final height = (sizeMap?['height'] as num?)?.toInt();
          final width = (sizeMap?['width'] as num?)?.toInt();

          options.add(
            MediaFormatOption(
              id: 'x_vid_$videoIdx',
              label: type == 'gif'
                  ? 'GIF (MP4)'
                  : (mediaExtended.length > 1 ? 'Video #$videoIdx HD' : 'Video HD MP4'),
              subtitle: [
                'MP4',
                if (width != null && height != null) '${width}x$height',
                'X Direct',
              ].join(' • '),
              extension: 'mp4',
              kind: MediaKind.video,
              engine: DownloadEngine.directHttp,
              height: height,
              directUrl: mediaUrl,
            ),
          );
          videoIdx++;
        } else if (type == 'image') {
          thumb ??= mediaUrl;
          photoUrls.add(mediaUrl);
        }
      }

      if (photoUrls.isNotEmpty) {
        options.add(
          MediaFormatOption(
            id: 'x_photos',
            label: photoUrls.length > 1
                ? 'Semua Foto (${photoUrls.length} gambar)'
                : 'Foto HD',
            subtitle: 'JPG Resolusi Asli',
            extension: _guessImageExt(photoUrls.first),
            kind: MediaKind.image,
            engine: DownloadEngine.directHttp,
            directUrl: photoUrls.first,
            galleryUrls: photoUrls,
          ),
        );
      }

      if (options.isEmpty) return null;

      return MediaInfo(
        originalUrl: originalUrl,
        platform: MediaPlatform.x,
        title: text.isNotEmpty ? text : 'Post X @$handle ($tweetId)',
        author: authorName,
        thumbnailUrl: thumb,
        duration: duration,
        extractorLabel: 'X Direct Engine',
        options: options,
      );
    } catch (_) {
      return null;
    }
  }

  Future<MediaInfo?> _tryFxTwitter(String originalUrl, String handle, String tweetId) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://api.fxtwitter.com/$handle/status/$tweetId',
        options: Options(headers: {'User-Agent': 'all_download/1.0'}),
      );
      if (res.statusCode != 200) return null;
      final body = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (body is! Map) return null;
      final tweet = body['tweet'] as Map?;
      if (tweet == null) return null;

      final media = tweet['media'] as Map?;
      if (media == null) return null;

      final options = <MediaFormatOption>[];
      String? thumb;
      Duration? duration;

      final videos = media['videos'] as List?;
      if (videos != null) {
        for (int i = 0; i < videos.length; i++) {
          final v = videos[i];
          if (v is! Map) continue;
          final videoUrl = v['url']?.toString();
          if (videoUrl == null || !videoUrl.startsWith('http')) continue;
          thumb ??= v['thumbnail_url']?.toString();
          final durSec = (v['duration'] as num?)?.round() ?? 0;
          if (durSec > 0) duration ??= Duration(seconds: durSec);

          final height = (v['height'] as num?)?.toInt();
          options.add(
            MediaFormatOption(
              id: 'fx_vid_$i',
              label: videos.length > 1 ? 'Video #${i + 1} MP4' : 'Video HD MP4',
              subtitle: [
                if (height != null && height > 0) '${height}p',
                'MP4 • X Fallback',
              ].join(' • '),
              extension: 'mp4',
              kind: MediaKind.video,
              engine: DownloadEngine.directHttp,
              height: height,
              directUrl: videoUrl,
            ),
          );
        }
      }

      final photos = media['photos'] as List?;
      if (photos != null && photos.isNotEmpty) {
        final photoUrls = photos
            .whereType<Map>()
            .map((p) => p['url']?.toString() ?? '')
            .where((u) => u.startsWith('http'))
            .toList();
        if (photoUrls.isNotEmpty) {
          thumb ??= photoUrls.first;
          options.add(
            MediaFormatOption(
              id: 'fx_photos',
              label: photoUrls.length > 1
                  ? 'Semua Foto (${photoUrls.length} gambar)'
                  : 'Foto HD',
              subtitle: 'JPG Resolusi Asli',
              extension: _guessImageExt(photoUrls.first),
              kind: MediaKind.image,
              engine: DownloadEngine.directHttp,
              directUrl: photoUrls.first,
              galleryUrls: photoUrls,
            ),
          );
        }
      }

      if (options.isEmpty) return null;

      final text = (tweet['text']?.toString() ?? '').trim();
      final authorName =
          (tweet['author']?['name']?.toString() ?? '@$handle').trim();

      return MediaInfo(
        originalUrl: originalUrl,
        platform: MediaPlatform.x,
        title: text.isNotEmpty ? text : 'Post X @$handle ($tweetId)',
        author: authorName,
        thumbnailUrl: thumb,
        duration: duration,
        extractorLabel: 'X Direct Engine',
        options: options,
      );
    } catch (_) {
      return null;
    }
  }

  /// Resolves Instagram `/share/...` or `instagr.am` short links to canonical `/reel/{code}/` or `/p/{code}/`.
  Future<String> resolveInstagramUrl(String url) async {
    final lower = url.toLowerCase();
    if (!lower.contains('/share/') &&
        !lower.contains('instagr.am') &&
        !lower.contains('ig.me')) {
      return url;
    }
    try {
      return await _resolveRedirects(url, userAgent: _desktopChromeUa);
    } catch (_) {
      return url;
    }
  }

  /// Fast anonymous Instagram extractor (Embed Captioned + GraphQL API).
  /// Supports public Reels (MP4), Photo Posts, and Multi-slide Carousels.
  Future<MediaInfo?> extractInstagramDirect(String url) async {
    try {
      final canonical = await resolveInstagramUrl(url);
      final codeMatch = RegExp(
        r'/(?:reel|reels|p|tv)/([A-Za-z0-9_-]{5,30})',
        caseSensitive: false,
      ).firstMatch(canonical);
      if (codeMatch == null) return null;
      final shortcode = codeMatch.group(1)!;

      // 1. Try public GraphQL API with freshly extracted LSD token
      final gqlInfo = await _tryInstagramGraphQl(canonical, shortcode);
      if (gqlInfo != null && gqlInfo.options.isNotEmpty) {
        return gqlInfo;
      }

      // 2. Try /embed/captioned/ public HTML extraction
      final embedInfo = await _tryInstagramEmbed(canonical, shortcode);
      if (embedInfo != null && embedInfo.options.isNotEmpty) {
        return embedInfo;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<MediaInfo?> _tryInstagramGraphQl(
    String canonicalUrl,
    String shortcode,
  ) async {
    try {
      final pageRes = await _dio.get<String>(
        'https://www.instagram.com/p/$shortcode/',
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': _desktopChromeUa,
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
          },
        ),
      );

      final html = pageRes.data ?? '';
      final lsdMatch = RegExp(r'"LSD",\[\],\{"token":"([^"]+)"').firstMatch(html);
      final lsd = lsdMatch?.group(1) ?? 'AVqbxe3J_YA';

      final rawSetCookies = pageRes.headers['set-cookie'] ?? const <String>[];
      final cookiePairs = <String>[];
      String csrf = '';
      for (final sc in rawSetCookies) {
        final pair = sc.split(';').first.trim();
        if (pair.contains('=')) {
          cookiePairs.add(pair);
          if (pair.startsWith('csrftoken=')) {
            csrf = pair.substring('csrftoken='.length);
          }
        }
      }

      const docIds = ['10015901848480474', '8845758582119845'];
      for (final docId in docIds) {
        final variables = jsonEncode({
          'shortcode': shortcode,
          'fetch_comment_count': 0,
          'fetch_related_profile_media_count': 0,
          'parent_comment_count': 0,
          'child_comment_count': 0,
          'fetch_like_count': 0,
          'fetch_tagged_user_count': null,
          'fetch_preview_comment_count': 0,
          'has_threaded_comments': false,
          'hoisted_comment_id': null,
          'hoisted_reply_id': null,
        });

        final res = await _dio.post<dynamic>(
          'https://www.instagram.com/api/graphql',
          data: {
            'av': '0',
            '__d': 'www',
            '__user': '0',
            '__a': '1',
            'lsd': lsd,
            'fb_api_caller_class': 'RelayModern',
            'fb_api_req_friendly_name': 'PolarisPostActionLoadPostQueryQuery',
            'variables': variables,
            'server_timestamps': 'true',
            'doc_id': docId,
          },
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: {
              'User-Agent': _desktopChromeUa,
              'X-FB-LSD': lsd,
              'X-IG-App-ID': '936619743392459',
              'X-ASBD-ID': '129477',
              if (csrf.isNotEmpty) 'X-CSRFToken': csrf,
              if (cookiePairs.isNotEmpty) 'Cookie': cookiePairs.join('; '),
              'Origin': 'https://www.instagram.com',
              'Referer': 'https://www.instagram.com/p/$shortcode/',
              'Sec-Fetch-Site': 'same-origin',
            },
          ),
        );

        final body = res.data is String ? jsonDecode(res.data as String) : res.data;
        if (body is! Map) continue;
        final media = body['data']?['xdt_shortcode_media'];
        if (media is! Map) continue;

        final parsed = _parseInstagramMediaNode(canonicalUrl, shortcode, media);
        if (parsed != null) return parsed;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<MediaInfo?> _tryInstagramEmbed(
    String canonicalUrl,
    String shortcode,
  ) async {
    try {
      final res = await _dio.get<String>(
        'https://www.instagram.com/p/$shortcode/embed/captioned/',
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': _desktopChromeUa,
            'Accept-Language': 'en-US,en;q=0.9',
          },
        ),
      );

      final html = res.data ?? '';
      if (html.isEmpty) return null;

      final options = <MediaFormatOption>[];
      final videoMatch = RegExp(r'"video_url"\s*:\s*("(?:\\.|[^"\\])*")').firstMatch(html);
      String? thumb;
      final displayMatch = RegExp(r'"display_url"\s*:\s*("(?:\\.|[^"\\])*")').firstMatch(html);
      if (displayMatch != null) {
        thumb = jsonDecode(displayMatch.group(1)!).toString();
      }

      if (videoMatch != null) {
        final videoUrl = jsonDecode(videoMatch.group(1)!).toString();
        if (videoUrl.startsWith('http')) {
          options.add(
            MediaFormatOption(
              id: 'ig_embed_vid',
              label: 'Video HD MP4',
              subtitle: 'Instagram Direct',
              extension: 'mp4',
              kind: MediaKind.video,
              engine: DownloadEngine.directHttp,
              directUrl: videoUrl,
              headers: const {'User-Agent': _desktopChromeUa},
            ),
          );
        }
      } else if (thumb != null && thumb.startsWith('http')) {
        options.add(
          MediaFormatOption(
            id: 'ig_embed_img',
            label: 'Foto HD',
            subtitle: 'JPG Resolusi Asli',
            extension: 'jpg',
            kind: MediaKind.image,
            engine: DownloadEngine.directHttp,
            directUrl: thumb,
            galleryUrls: [thumb],
            headers: const {'User-Agent': _desktopChromeUa},
          ),
        );
      }

      if (options.isEmpty) return null;

      return MediaInfo(
        originalUrl: canonicalUrl,
        platform: MediaPlatform.instagram,
        title: 'Instagram_$shortcode',
        author: 'Instagram',
        thumbnailUrl: thumb,
        extractorLabel: 'Instagram Direct Engine',
        options: options,
      );
    } catch (_) {
      return null;
    }
  }

  MediaInfo? _parseInstagramMediaNode(
    String canonicalUrl,
    String shortcode,
    Map media,
  ) {
    final owner = media['owner'] as Map?;
    final author = (owner?['username']?.toString() ??
            owner?['full_name']?.toString() ??
            'Instagram')
        .trim();

    String title = 'Instagram_$shortcode';
    final captionEdges = media['edge_media_to_caption']?['edges'] as List?;
    if (captionEdges != null && captionEdges.isNotEmpty) {
      final captionText = captionEdges.first?['node']?['text']?.toString().trim();
      if (captionText != null && captionText.isNotEmpty) {
        title = captionText;
      }
    }

    final thumb = media['display_url']?.toString();
    final options = <MediaFormatOption>[];
    final photoUrls = <String>[];
    int vidIndex = 1;

    final sidecar = media['edge_sidecar_to_children']?['edges'] as List?;
    if (sidecar != null && sidecar.isNotEmpty) {
      for (final edge in sidecar) {
        final node = edge?['node'];
        if (node is! Map) continue;
        final isVid = node['is_video'] == true;
        if (isVid && node['video_url'] != null) {
          options.add(
            MediaFormatOption(
              id: 'ig_sc_vid_$vidIndex',
              label: 'Video Slide #$vidIndex HD',
              subtitle: 'MP4 • Instagram Carousel',
              extension: 'mp4',
              kind: MediaKind.video,
              engine: DownloadEngine.directHttp,
              directUrl: node['video_url'].toString(),
              headers: const {'User-Agent': _desktopChromeUa},
            ),
          );
          vidIndex++;
        } else if (node['display_url'] != null) {
          photoUrls.add(node['display_url'].toString());
        }
      }
    } else {
      final isVid = media['is_video'] == true;
      if (isVid && media['video_url'] != null) {
        final durSec = (media['video_duration'] as num?)?.round();
        options.add(
          MediaFormatOption(
            id: 'ig_vid',
            label: 'Video HD MP4',
            subtitle: 'MP4 • Instagram Direct',
            extension: 'mp4',
            kind: MediaKind.video,
            engine: DownloadEngine.directHttp,
            directUrl: media['video_url'].toString(),
            headers: const {'User-Agent': _desktopChromeUa},
          ),
        );
        return MediaInfo(
          originalUrl: canonicalUrl,
          platform: MediaPlatform.instagram,
          title: title,
          author: '@$author',
          thumbnailUrl: thumb,
          duration: durSec != null && durSec > 0 ? Duration(seconds: durSec) : null,
          extractorLabel: 'Instagram GraphQL',
          options: options,
        );
      } else if (thumb != null && thumb.startsWith('http')) {
        photoUrls.add(thumb);
      }
    }

    if (photoUrls.isNotEmpty) {
      options.add(
        MediaFormatOption(
          id: 'ig_photos',
          label: photoUrls.length > 1
              ? 'Semua Foto (${photoUrls.length} slide)'
              : 'Foto HD',
          subtitle: 'JPG Resolusi Asli',
          extension: 'jpg',
          kind: MediaKind.image,
          engine: DownloadEngine.directHttp,
          directUrl: photoUrls.first,
          galleryUrls: photoUrls,
          headers: const {'User-Agent': _desktopChromeUa},
        ),
      );
    }

    if (options.isEmpty) return null;

    return MediaInfo(
      originalUrl: canonicalUrl,
      platform: MediaPlatform.instagram,
      title: title,
      author: '@$author',
      thumbnailUrl: thumb ?? (photoUrls.isNotEmpty ? photoUrls.first : null),
      extractorLabel: 'Instagram GraphQL',
      options: options,
    );
  }

  Future<String> _resolveRedirects(String url, {required String userAgent}) async {
    String current = url;
    for (int hop = 0; hop < 5; hop++) {
      final response = await _dio.get<dynamic>(
        current,
        options: Options(
          followRedirects: false,
          responseType: ResponseType.plain,
          headers: {'User-Agent': userAgent},
          validateStatus: (s) => s != null && s < 400,
        ),
      );
      final location = response.headers.value('location');
      if (location == null || location.isEmpty) break;
      current = Uri.parse(current).resolve(location).toString();
      if (_extractDouyinId(current) != null) break;
    }
    return current;
  }

  String? _extractDouyinId(String url) {
    final patterns = [
      RegExp(r'/(?:video|note|slides)/(\d{15,22})'),
      RegExp(r'[?&]modal_id=(\d{15,22})'),
      RegExp(r'share/(?:video|note)/(\d{15,22})'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  Map<String, dynamic>? _parseDouyinRouterData(String html) {
    final marker = RegExp(r'window\._ROUTER_DATA\s*=\s*');
    final match = marker.firstMatch(html);
    if (match == null) return null;

    final start = match.end;
    final endTag = html.indexOf('</script>', start);
    if (endTag == -1) return null;

    var rawJson = html.substring(start, endTag).trim();
    if (rawJson.endsWith(';')) {
      rawJson = rawJson.substring(0, rawJson.length - 1).trim();
    }

    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) return null;
    final loaderData = decoded['loaderData'];
    if (loaderData is! Map) return null;

    for (final value in loaderData.values) {
      if (value is! Map) continue;
      final videoInfoRes = value['videoInfoRes'];
      if (videoInfoRes is Map) {
        final itemList = videoInfoRes['item_list'];
        if (itemList is List && itemList.isNotEmpty && itemList.first is Map) {
          return Map<String, dynamic>.from(itemList.first as Map);
        }
      }
    }
    return null;
  }

  String _cleanDouyinVideoUrl(String rawUrl) {
    return rawUrl
        .replaceAll('playwm', 'play')
        .replaceFirst('http://', 'https://');
  }

  String? _firstUrlFromMap(Map? obj) {
    if (obj == null) return null;
    final list = obj['url_list'];
    if (list is List) {
      for (final u in list) {
        final s = u?.toString() ?? '';
        if (s.startsWith('http')) return s;
      }
    }
    return null;
  }

  String? _pickBestImageUrl(List? list) {
    if (list == null || list.isEmpty) return null;
    final urls = list
        .map((e) => e?.toString() ?? '')
        .where((s) => s.startsWith('http'))
        .toList();
    if (urls.isEmpty) return null;
    final jpeg = urls.firstWhere(
      (u) => u.contains('.jpeg') || u.contains('.jpg') || u.contains('.png'),
      orElse: () => urls.first,
    );
    return jpeg.replaceFirst('http://', 'https://');
  }

  String _guessImageExt(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.png')) return 'png';
    if (lower.contains('.webp')) return 'webp';
    if (lower.contains('.gif')) return 'gif';
    return 'jpg';
  }
}
