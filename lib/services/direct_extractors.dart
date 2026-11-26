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

  static const Map<String, String> pixivHeaders = {
    'User-Agent': _desktopChromeUa,
    'Referer': 'https://www.pixiv.net/',
  };

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

  // ===========================================================================
  // PIXIV: Single Artwork (multi-page selectable!) & User Profile / Username Bulk
  // ===========================================================================

  Future<MediaInfo?> extractPixiv(String url, {String cookieHeader = ''}) async {
    final headers = <String, String>{
      ...pixivHeaders,
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };

    // 1. Check if artwork link
    final illustId = _extractPixivIllustId(url);
    if (illustId != null) {
      return _extractPixivArtwork(url, illustId, headers);
    }

    // 2. Check if user profile link or username search
    String? userId = _extractPixivUserId(url);
    if (userId == null) {
      final uri = Uri.tryParse(url);
      final nick = uri?.queryParameters['nick']?.trim();
      if (nick != null && nick.isNotEmpty) {
        userId = await _findPixivUserIdByName(nick, headers);
      }
    }
    if (userId != null) {
      return _extractPixivUserProfile(url, userId, headers);
    }

    // 3. Direct i.pximg.net image URL
    if (url.toLowerCase().contains('pximg.net')) {
      final ext = _guessImageExt(url);
      final item = SelectableMediaItem(
        id: 'pximg_0',
        title: 'Pixiv Image',
        thumbnailUrl: url,
        directUrl: url,
        extension: ext,
        kind: MediaKind.image,
        engine: DownloadEngine.directHttp,
        headers: headers,
        badgeLabel: 'Foto 1',
      );
      return MediaInfo(
        originalUrl: url,
        platform: MediaPlatform.pixiv,
        title: 'Pixiv Image',
        author: 'Pixiv',
        thumbnailUrl: url,
        thumbnailHeaders: headers,
        extractorLabel: 'Pixiv Direct',
        selectableItems: [item],
        options: [
          MediaFormatOption(
            id: 'pximg_dl',
            label: 'Foto Original',
            subtitle: ext.toUpperCase(),
            extension: ext,
            kind: MediaKind.image,
            engine: DownloadEngine.directHttp,
            directUrl: url,
            galleryUrls: [url],
            headers: headers,
          ),
        ],
      );
    }

    return null;
  }

  Future<MediaInfo?> _extractPixivArtwork(
    String originalUrl,
    String illustId,
    Map<String, String> headers,
  ) async {
    try {
      final infoRes = await _dio.get<dynamic>(
        'https://www.pixiv.net/ajax/illust/$illustId',
        options: Options(headers: headers),
      );
      final infoBody =
          infoRes.data is String ? jsonDecode(infoRes.data as String) : infoRes.data;
      if (infoBody is! Map || infoBody['error'] == true) return null;
      final meta = infoBody['body'] as Map?;
      if (meta == null) return null;

      final title = (meta['illustTitle']?.toString() ??
              meta['title']?.toString() ??
              'Pixiv_$illustId')
          .trim();
      final author = (meta['userName']?.toString() ??
              meta['userAccount']?.toString() ??
              'Pixiv')
          .trim();

      final pagesRes = await _dio.get<dynamic>(
        'https://www.pixiv.net/ajax/illust/$illustId/pages',
        options: Options(headers: headers),
      );
      final pagesBody = pagesRes.data is String
          ? jsonDecode(pagesRes.data as String)
          : pagesRes.data;

      final items = <SelectableMediaItem>[];
      final fullUrls = <String>[];

      if (pagesBody is Map && pagesBody['error'] != true && pagesBody['body'] is List) {
        final pages = pagesBody['body'] as List;
        for (int i = 0; i < pages.length; i++) {
          final page = pages[i];
          if (page is! Map) continue;
          final urls = page['urls'] as Map?;
          final orig = urls?['original']?.toString() ??
              urls?['regular']?.toString() ??
              '';
          final thumb = urls?['small']?.toString() ??
              urls?['thumb_mini']?.toString() ??
              orig;
          if (!orig.startsWith('http')) continue;
          fullUrls.add(orig);
          final ext = _guessImageExt(orig);
          items.add(
            SelectableMediaItem(
              id: 'pixiv_${illustId}_p$i',
              title: pages.length > 1 ? '$title (Hal ${i + 1})' : title,
              thumbnailUrl: thumb,
              directUrl: orig,
              extension: ext,
              kind: MediaKind.image,
              engine: DownloadEngine.directHttp,
              headers: headers,
              badgeLabel: 'Hal ${i + 1}',
              author: author,
            ),
          );
        }
      }

      // Fallback to meta.urls.original if /pages returned empty
      if (items.isEmpty) {
        final urls = meta['urls'] as Map?;
        final orig = urls?['original']?.toString() ??
            urls?['regular']?.toString() ??
            '';
        if (orig.startsWith('http')) {
          fullUrls.add(orig);
          final ext = _guessImageExt(orig);
          items.add(
            SelectableMediaItem(
              id: 'pixiv_${illustId}_p0',
              title: title,
              thumbnailUrl: urls?['small']?.toString() ?? orig,
              directUrl: orig,
              extension: ext,
              kind: MediaKind.image,
              engine: DownloadEngine.directHttp,
              headers: headers,
              badgeLabel: 'Foto 1',
              author: author,
            ),
          );
        }
      }

      if (items.isEmpty) return null;

      final firstExt = items.first.extension;
      return MediaInfo(
        originalUrl: originalUrl,
        platform: MediaPlatform.pixiv,
        title: title,
        author: author,
        thumbnailUrl: items.first.thumbnailUrl,
        thumbnailHeaders: headers,
        extractorLabel: 'Pixiv Original Engine',
        selectableItems: items,
        options: [
          MediaFormatOption(
            id: 'pixiv_all',
            label: items.length > 1
                ? 'Semua Halaman (${items.length} foto)'
                : 'Gambar Original HD',
            subtitle: '${firstExt.toUpperCase()} • Resolusi Asli Pixiv',
            extension: firstExt,
            kind: MediaKind.image,
            engine: DownloadEngine.directHttp,
            directUrl: fullUrls.first,
            galleryUrls: fullUrls,
            headers: headers,
          ),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  Future<MediaInfo?> _extractPixivUserProfile(
    String originalUrl,
    String userId,
    Map<String, String> headers,
  ) async {
    try {
      final profileRes = await _dio.get<dynamic>(
        'https://www.pixiv.net/ajax/user/$userId/profile/all',
        options: Options(headers: headers),
      );
      final profileBody = profileRes.data is String
          ? jsonDecode(profileRes.data as String)
          : profileRes.data;
      if (profileBody is! Map || profileBody['error'] == true) return null;
      final body = profileBody['body'] as Map?;
      if (body == null) return null;

      final ids = <String>[];
      if (body['illusts'] is Map) {
        ids.addAll((body['illusts'] as Map).keys.map((e) => e.toString()));
      }
      if (body['manga'] is Map) {
        ids.addAll((body['manga'] as Map).keys.map((e) => e.toString()));
      }

      // Sort newest artwork ID first — NO cap, load ALL works in parallel chunks of 48!
      ids.sort((a, b) => (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0));
      if (ids.isEmpty) return null;

      const chunkSize = 48;
      final chunks = <List<String>>[];
      for (int start = 0; start < ids.length; start += chunkSize) {
        final end = (start + chunkSize > ids.length) ? ids.length : start + chunkSize;
        chunks.add(ids.sublist(start, end));
      }

      // Fetch up to 4 chunks concurrently so even hundreds/thousands of artworks load quickly.
      final allWorksMap = <String, Map>{};
      const concurrency = 4;
      for (int i = 0; i < chunks.length; i += concurrency) {
        final group = chunks.sublist(
          i,
          (i + concurrency > chunks.length) ? chunks.length : i + concurrency,
        );
        final groupResults = await Future.wait(
          group.map((chunk) async {
            try {
              final queryIds = chunk.map((id) => 'ids[]=$id').join('&');
              final worksRes = await _dio.get<dynamic>(
                'https://www.pixiv.net/ajax/user/$userId/profile/illusts?$queryIds&work_category=illustManga&is_first_page=0',
                options: Options(headers: headers),
              );
              final worksBody = worksRes.data is String
                  ? jsonDecode(worksRes.data as String)
                  : worksRes.data;
              if (worksBody is Map && worksBody['error'] != true) {
                final works = worksBody['body']?['works'];
                if (works is Map) {
                  return works;
                }
              }
            } catch (_) {}
            return null;
          }),
        );
        for (final wMap in groupResults) {
          if (wMap == null) continue;
          wMap.forEach((key, value) {
            if (value is Map) {
              allWorksMap[key.toString()] = value;
            }
          });
        }
      }

      if (allWorksMap.isEmpty) return null;

      String creatorName = 'Pixiv_$userId';
      final items = <SelectableMediaItem>[];

      for (final id in ids) {
        final work = allWorksMap[id];
        if (work == null) continue;
        final uName = work['userName']?.toString().trim() ?? '';
        if (uName.isNotEmpty) creatorName = uName;

        final workTitle = (work['title']?.toString() ?? 'Pixiv_$id').trim();
        final thumb = work['url']?.toString() ?? '';
        final pageCount = (work['pageCount'] as num?)?.toInt() ?? 1;

        items.add(
          SelectableMediaItem(
            id: 'pixiv_work_$id',
            title: workTitle,
            thumbnailUrl: thumb.startsWith('http') ? thumb : null,
            sourcePostUrl: 'https://www.pixiv.net/artworks/$id',
            extension: 'jpg',
            kind: MediaKind.image,
            engine: DownloadEngine.directHttp,
            headers: headers,
            badgeLabel: pageCount > 1 ? '$pageCount Hal' : '1 Hal',
            author: creatorName,
            pixivIllustId: id,
          ),
        );
      }

      if (items.isEmpty) return null;

      return MediaInfo(
        originalUrl: 'https://www.pixiv.net/users/$userId',
        platform: MediaPlatform.pixiv,
        title: 'Karya $creatorName (${items.length} karya)',
        author: creatorName,
        thumbnailUrl: items.first.thumbnailUrl,
        thumbnailHeaders: headers,
        extractorLabel: 'Pixiv Profil Massal',
        options: const [],
        selectableItems: items,
        isBulkProfile: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Resolves all full-resolution page URLs for a Pixiv artwork ID (used during bulk downloads).
  Future<List<String>> fetchPixivIllustOriginalUrls(
    String illustId, {
    String cookieHeader = '',
  }) async {
    final headers = <String, String>{
      ...pixivHeaders,
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };
    try {
      final res = await _dio.get<dynamic>(
        'https://www.pixiv.net/ajax/illust/$illustId/pages',
        options: Options(headers: headers),
      );
      final body = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (body is Map && body['error'] != true && body['body'] is List) {
        final urls = <String>[];
        for (final p in (body['body'] as List)) {
          if (p is! Map) continue;
          final u = p['urls']?['original']?.toString() ??
              p['urls']?['regular']?.toString() ??
              '';
          if (u.startsWith('http')) urls.add(u);
        }
        return urls;
      }
    } catch (_) {}
    return const [];
  }

  Future<String?> _findPixivUserIdByName(
    String nickname,
    Map<String, String> headers,
  ) async {
    try {
      final res = await _dio.get<String>(
        'https://www.pixiv.net/search_user.php',
        queryParameters: {'s_mode': 's_usr', 'nick': nickname},
        options: Options(
          responseType: ResponseType.plain,
          headers: headers,
        ),
      );
      final html = res.data ?? '';
      final match = RegExp(r'/users/(\d+)').firstMatch(html);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  String? _extractPixivIllustId(String url) {
    final patterns = [
      RegExp(r'pixiv\.net/(?:en/)?artworks/(\d+)'),
      RegExp(r'[?&]illust_id=(\d+)'),
      RegExp(r'pixiv\.net/i/(\d+)'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  String? _extractPixivUserId(String url) {
    final patterns = [
      RegExp(r'pixiv\.net/(?:en/)?users/(\d+)'),
      RegExp(r'member\.php\?[^#]*id=(\d+)'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  // ===========================================================================
  // FACEBOOK: Share redirect resolution
  // ===========================================================================

  Future<String> resolveFacebookUrl(String url) async {
    final lower = url.toLowerCase();
    if (!lower.contains('fb.watch') && !lower.contains('/share/')) {
      return url;
    }
    try {
      return await _resolveRedirects(url, userAgent: _desktopChromeUa);
    } catch (_) {
      return url;
    }
  }

  // ===========================================================================
  // DOUYIN: Direct mobile share extractor
  // ===========================================================================

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
      final author = (authorMap?['nickname']?.toString() ?? 'Douyin').trim();
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
      final selectableItems = <SelectableMediaItem>[];
      const downloadHeaders = {'User-Agent': _mobileSafariUa};

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
          for (int i = 0; i < imageUrls.length; i++) {
            final ext = _guessImageExt(imageUrls[i]);
            selectableItems.add(
              SelectableMediaItem(
                id: 'dy_img_$i',
                title: imageUrls.length > 1 ? '$title (${i + 1})' : title,
                thumbnailUrl: imageUrls[i],
                directUrl: imageUrls[i],
                extension: ext,
                kind: MediaKind.image,
                engine: DownloadEngine.directHttp,
                headers: downloadHeaders,
                badgeLabel: 'Foto ${i + 1}',
                author: author,
              ),
            );
          }
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

      if (videoMap != null) {
        final seenUrls = <String>{};
        final primaryPlayUrl = _firstUrlFromMap(videoMap['play_addr'] as Map?);
        if (primaryPlayUrl != null) {
          final cleanUrl = _cleanDouyinVideoUrl(primaryPlayUrl);
          if (seenUrls.add(cleanUrl)) {
            final height = (videoMap['height'] as num?)?.toInt();
            final size = (videoMap['play_addr']?['data_size'] as num?)?.toInt();
            options.add(
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

      final musicMap = item['music'] as Map?;
      final musicUrl = _firstUrlFromMap(musicMap?['play_url'] as Map?);
      if (musicUrl != null) {
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
            directUrl: musicUrl.replaceFirst('http://', 'https://'),
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
        selectableItems: selectableItems,
        thumbnailHeaders: downloadHeaders,
      );
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // TIKTOK: Fallback single post & profile bulk extractor (TikWM)
  // ===========================================================================

  Future<MediaInfo?> extractTikTokFallback(String url) async {
    try {
      final response = await _dio.get<dynamic>(
        'https://www.tikwm.com/api/',
        queryParameters: {'url': url, 'hd': 1},
        options: Options(headers: {'User-Agent': _mobileSafariUa}),
      );

      final body = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (body is! Map || body['code'] != 0) return null;
      final data = body['data'] as Map?;
      if (data == null) return null;

      final title = (data['title']?.toString() ?? '').trim();
      final authorMap = data['author'] as Map?;
      final author = (authorMap?['unique_id']?.toString() ??
              authorMap?['nickname']?.toString() ??
              'TikTok')
          .trim();
      final cover = data['cover']?.toString() ?? data['origin_cover']?.toString();
      final durSec = (data['duration'] as num?)?.toInt() ?? 0;

      final options = <MediaFormatOption>[];
      final selectableItems = <SelectableMediaItem>[];

      final images = (data['images'] as List?)
          ?.map((e) => e.toString())
          .where((e) => e.startsWith('http'))
          .toList();
      if (images != null && images.isNotEmpty) {
        for (int i = 0; i < images.length; i++) {
          selectableItems.add(
            SelectableMediaItem(
              id: 'tt_img_$i',
              title: images.length > 1 ? '${title.isNotEmpty ? title : 'TikTok'} (${i + 1})' : (title.isNotEmpty ? title : 'TikTok'),
              thumbnailUrl: images[i],
              directUrl: images[i],
              extension: 'jpg',
              kind: MediaKind.image,
              engine: DownloadEngine.directHttp,
              badgeLabel: 'Foto ${i + 1}',
              author: author,
            ),
          );
        }
        options.add(
          MediaFormatOption(
            id: 'tt_images',
            label: images.length > 1
                ? 'Semua Foto (${images.length} gambar)'
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
        selectableItems: selectableItems,
      );
    } catch (_) {
      return null;
    }
  }

  Future<MediaInfo?> extractTikTokProfileFallback(String originalUrl, String username) async {
    try {
      final cleanUser = username.replaceFirst('@', '').trim();
      if (cleanUser.isEmpty) return null;

      final items = <SelectableMediaItem>[];
      final seenIds = <String>{};
      String cursor = '0';
      bool hasMore = true;

      // Paginate through ALL pages of the TikTok profile until hasMore is false.
      while (hasMore) {
        final res = await _dio.get<dynamic>(
          'https://www.tikwm.com/api/user/posts',
          queryParameters: {
            'unique_id': cleanUser,
            'count': 33,
            'cursor': cursor,
          },
          options: Options(headers: {'User-Agent': _mobileSafariUa}),
        );
        final body = res.data is String ? jsonDecode(res.data as String) : res.data;
        if (body is! Map || body['code'] != 0) break;
        final data = body['data'] as Map?;
        if (data == null) break;

        final videos = data['videos'] as List?;
        if (videos == null || videos.isEmpty) break;

        int addedThisPage = 0;
        for (final v in videos) {
          if (v is! Map) continue;
          final vidId = v['video_id']?.toString() ?? '';
          final playUrl = v['play']?.toString() ?? '';
          if (!playUrl.startsWith('http')) continue;
          if (vidId.isNotEmpty && !seenIds.add(vidId)) continue;
          final title = (v['title']?.toString() ?? 'TikTok_$vidId').trim();
          final cover = v['cover']?.toString();
          final dur = (v['duration'] as num?)?.toInt() ?? 0;
          items.add(
            SelectableMediaItem(
              id: 'ttp_${vidId.isNotEmpty ? vidId : items.length}',
              title: title.isNotEmpty ? title : 'TikTok_$vidId',
              thumbnailUrl: cover,
              directUrl: playUrl,
              sourcePostUrl: 'https://www.tiktok.com/@$cleanUser/video/$vidId',
              extension: 'mp4',
              kind: MediaKind.video,
              engine: DownloadEngine.directHttp,
              badgeLabel: dur > 0 ? '${dur}s' : 'MP4',
              author: cleanUser,
            ),
          );
          addedThisPage++;
        }

        final nextHasMore = data['hasMore'] == true;
        final nextCursor = data['cursor']?.toString() ?? '';
        if (!nextHasMore ||
            nextCursor.isEmpty ||
            nextCursor == cursor ||
            addedThisPage == 0) {
          hasMore = false;
        } else {
          cursor = nextCursor;
          await Future<void>.delayed(const Duration(milliseconds: 220));
        }
      }

      if (items.isEmpty) return null;

      return MediaInfo(
        originalUrl: originalUrl,
        platform: MediaPlatform.tiktok,
        title: 'Profil TikTok @$cleanUser (${items.length} video)',
        author: cleanUser,
        thumbnailUrl: items.first.thumbnailUrl,
        extractorLabel: 'TikTok Profil Massal',
        options: const [],
        selectableItems: items,
        isBulkProfile: true,
      );
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // X (TWITTER): Direct fallback for videos, GIFs, and multi-photo tweets
  // ===========================================================================

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
      final authorName = (data['user_screen_name']?.toString() ?? handle).trim();
      final mediaExtended = data['media_extended'] as List?;
      if (mediaExtended == null || mediaExtended.isEmpty) return null;

      final options = <MediaFormatOption>[];
      final selectableItems = <SelectableMediaItem>[];
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
        final baseTitle = text.isNotEmpty ? text : 'Post X @$authorName';
        for (int i = 0; i < photoUrls.length; i++) {
          final ext = _guessImageExt(photoUrls[i]);
          selectableItems.add(
            SelectableMediaItem(
              id: 'x_photo_$i',
              title: photoUrls.length > 1 ? '$baseTitle (${i + 1})' : baseTitle,
              thumbnailUrl: photoUrls[i],
              directUrl: photoUrls[i],
              extension: ext,
              kind: MediaKind.image,
              engine: DownloadEngine.directHttp,
              badgeLabel: 'Foto ${i + 1}',
              author: authorName,
            ),
          );
        }
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
        title: text.isNotEmpty ? text : 'Post X @$authorName ($tweetId)',
        author: authorName,
        thumbnailUrl: thumb,
        duration: duration,
        extractorLabel: 'X Direct Engine',
        options: options,
        selectableItems: selectableItems,
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
      final selectableItems = <SelectableMediaItem>[];
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

      final text = (tweet['text']?.toString() ?? '').trim();
      final authorName =
          (tweet['author']?['screen_name']?.toString() ?? handle).trim();

      final photos = media['photos'] as List?;
      if (photos != null && photos.isNotEmpty) {
        final photoUrls = photos
            .whereType<Map>()
            .map((p) => p['url']?.toString() ?? '')
            .where((u) => u.startsWith('http'))
            .toList();
        if (photoUrls.isNotEmpty) {
          thumb ??= photoUrls.first;
          final baseTitle = text.isNotEmpty ? text : 'Post X @$authorName';
          for (int i = 0; i < photoUrls.length; i++) {
            final ext = _guessImageExt(photoUrls[i]);
            selectableItems.add(
              SelectableMediaItem(
                id: 'fx_photo_$i',
                title: photoUrls.length > 1 ? '$baseTitle (${i + 1})' : baseTitle,
                thumbnailUrl: photoUrls[i],
                directUrl: photoUrls[i],
                extension: ext,
                kind: MediaKind.image,
                engine: DownloadEngine.directHttp,
                badgeLabel: 'Foto ${i + 1}',
                author: authorName,
              ),
            );
          }
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

      return MediaInfo(
        originalUrl: originalUrl,
        platform: MediaPlatform.x,
        title: text.isNotEmpty ? text : 'Post X @$authorName ($tweetId)',
        author: authorName,
        thumbnailUrl: thumb,
        duration: duration,
        extractorLabel: 'X Direct Engine',
        options: options,
        selectableItems: selectableItems,
      );
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // INSTAGRAM: Canonical /share/ resolver + GraphQL + Embed (NEVER photo for Reel!)
  // ===========================================================================

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

  Future<MediaInfo?> extractInstagramDirect(
    String url, {
    String cookieHeader = '',
  }) async {
    try {
      final canonical = await resolveInstagramUrl(url);
      final lowerCanon = canonical.toLowerCase();
      final isReelUrl = lowerCanon.contains('/reel/') ||
          lowerCanon.contains('/reels/') ||
          lowerCanon.contains('/tv/');

      final codeMatch = RegExp(
        r'/(?:reel|reels|p|tv)/([A-Za-z0-9_-]{5,30})',
        caseSensitive: false,
      ).firstMatch(canonical);
      if (codeMatch == null) return null;
      final shortcode = codeMatch.group(1)!;

      final gqlInfo = await _tryInstagramGraphQl(
        canonical,
        shortcode,
        isReelUrl: isReelUrl,
        cookieHeader: cookieHeader,
      );
      if (gqlInfo != null && gqlInfo.options.isNotEmpty) {
        return gqlInfo;
      }

      final embedInfo = await _tryInstagramEmbed(
        canonical,
        shortcode,
        isReelUrl: isReelUrl,
      );
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
    String shortcode, {
    required bool isReelUrl,
    String cookieHeader = '',
  }) async {
    try {
      final pageRes = await _dio.get<String>(
        'https://www.instagram.com/p/$shortcode/',
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': _desktopChromeUa,
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
          },
        ),
      );

      final html = pageRes.data ?? '';
      final lsdMatch = RegExp(r'"LSD",\[\],\{"token":"([^"]+)"').firstMatch(html);
      final lsd = lsdMatch?.group(1) ?? 'AVqbxe3J_YA';

      final rawSetCookies = pageRes.headers['set-cookie'] ?? const <String>[];
      final cookiePairs = <String>[];
      if (cookieHeader.isNotEmpty) cookiePairs.add(cookieHeader);
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

        final parsed = _parseInstagramMediaNode(
          canonicalUrl,
          shortcode,
          media,
          isReelUrl: isReelUrl,
        );
        if (parsed != null) return parsed;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<MediaInfo?> _tryInstagramEmbed(
    String canonicalUrl,
    String shortcode, {
    required bool isReelUrl,
  }) async {
    try {
      final pathSegment = isReelUrl ? 'reel' : 'p';
      final res = await _dio.get<String>(
        'https://www.instagram.com/$pathSegment/$shortcode/embed/captioned/',
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
      String author = 'Instagram';
      final userMatch = RegExp(r'"username"\s*:\s*"([^"]+)"').firstMatch(html);
      if (userMatch != null) {
        author = userMatch.group(1)!;
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
      } else if (!isReelUrl && thumb != null && thumb.startsWith('http')) {
        // CRITICAL FIX: Never return cover photo for a Reel URL when video_url is missing!
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
        author: author,
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
    Map media, {
    required bool isReelUrl,
  }) {
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
    final selectableItems = <SelectableMediaItem>[];
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
      final isVid = media['is_video'] == true || media['video_url'] != null;
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
          author: author,
          thumbnailUrl: thumb,
          duration: durSec != null && durSec > 0 ? Duration(seconds: durSec) : null,
          extractorLabel: 'Instagram GraphQL',
          options: options,
        );
      } else if (!isReelUrl && thumb != null && thumb.startsWith('http')) {
        photoUrls.add(thumb);
      }
    }

    if (photoUrls.isNotEmpty) {
      for (int i = 0; i < photoUrls.length; i++) {
        selectableItems.add(
          SelectableMediaItem(
            id: 'ig_photo_$i',
            title: photoUrls.length > 1 ? '$title (${i + 1})' : title,
            thumbnailUrl: photoUrls[i],
            directUrl: photoUrls[i],
            extension: 'jpg',
            kind: MediaKind.image,
            engine: DownloadEngine.directHttp,
            headers: const {'User-Agent': _desktopChromeUa},
            badgeLabel: 'Foto ${i + 1}',
            author: author,
          ),
        );
      }
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
      author: author,
      thumbnailUrl: thumb ?? (photoUrls.isNotEmpty ? photoUrls.first : null),
      extractorLabel: 'Instagram GraphQL',
      options: options,
      selectableItems: selectableItems,
    );
  }

  Future<String> _resolveRedirects(String url, {required String userAgent}) async {
    String current = url;
    for (int hop = 0; hop < 6; hop++) {
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
