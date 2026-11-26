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

  DirectExtractors get directExtractors => _direct;

  Future<MediaInfo> analyzeLink({
    required String rawInput,
    String? cookiesPath,
  }) async {
    var detection = UrlParser.inspect(rawInput);
    if (detection == null) {
      throw Exception(
        'Link tidak valid. Tempelkan tautan media atau profil (YouTube, TikTok, Douyin, Instagram, X, Pixiv, Facebook).',
      );
    }

    // Resolve TikTok short links (vt.tiktok.com / vm.tiktok.com / tiktok.com/t/) first
    // so shared TikTok profile links are detected accurately as Bulk Profile!
    if (detection.platform == MediaPlatform.tiktok) {
      final resolved = await _direct.resolveTikTokUrl(detection.cleanUrl);
      if (resolved != detection.cleanUrl) {
        final reinspected = UrlParser.inspect(resolved);
        if (reinspected != null) {
          detection = reinspected;
        }
      }
    }

    final cleanUrl = detection.cleanUrl;
    final platform = detection.platform;

    // 1. Pixiv (single artwork OR user profile / username bulk!)
    if (platform == MediaPlatform.pixiv) {
      final cookieHeader = await _safeCookieHeader('https://www.pixiv.net/');
      final pixivInfo = await _direct.extractPixiv(
        cleanUrl,
        cookieHeader: cookieHeader,
      );
      if (pixivInfo != null) return pixivInfo;
      throw Exception(
        'Gagal memuat karya/profil Pixiv. Untuk karya khusus member/R-18, login dulu lewat Pengaturan -> Login Browser (Pixiv).',
      );
    }

    // 2. Profile / Playlist Bulk Extraction (YouTube, TikTok, Instagram, X, Facebook, Douyin)
    if (detection.isBulk) {
      return _analyzeProfileOrPlaylist(detection, cookiesPath: cookiesPath);
    }

    // 3. Douyin single post (v.douyin.com / douyin.com / iesdouyin.com)
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
          strictVideoOnly: false,
        );
        if (fromSniffer != null) return fromSniffer;
      } catch (_) {}

      try {
        return await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
      } catch (e) {
        throw Exception(
          'Gagal mengambil video Douyin. Coba login singkat lewat Pengaturan -> Login Browser (Douyin), lalu ulangi.\n(${_friendlyError(e)})',
        );
      }
    }

    // 4. Instagram single Reel / Post / Carousel
    if (platform == MediaPlatform.instagram) {
      final canonicalUrl = await _direct.resolveInstagramUrl(cleanUrl);
      final lowerCanon = canonicalUrl.toLowerCase();
      final isReelUrl = lowerCanon.contains('/reel/') ||
          lowerCanon.contains('/reels/') ||
          lowerCanon.contains('/tv/');

      // Attempt A: yt-dlp (returns real MP4 video+audio for Reels when accessible / logged in)
      try {
        final ytInfo = await _extractWithYtDlp(canonicalUrl, platform, cookiesPath);
        if (ytInfo.options.isNotEmpty) return ytInfo;
      } catch (_) {}

      // Attempt B: Direct GraphQL + Embed (with synced WebView IG cookies! Strictly rejects cover-only photo for Reels!)
      final igCookie = await _safeCookieHeader('https://www.instagram.com/');
      final directIg = await _direct.extractInstagramDirect(
        canonicalUrl,
        cookieHeader: igCookie,
      );
      if (directIg != null && directIg.options.isNotEmpty) {
        final hasVideo = directIg.options.any((o) => o.kind == MediaKind.video);
        if (!isReelUrl || hasVideo) {
          return directIg;
        }
      }

      // Attempt C: Native Android Chromium WebView Sniffer (extracts embedded `video_versions` JSON for Reels!)
      try {
        final sniffed = await bridge.sniffMedia(
          url: canonicalUrl,
          platform: 'instagram',
          timeoutMs: 16000,
        );
        final fromSniffer = _buildMediaInfoFromSniff(
          originalUrl: canonicalUrl,
          platform: MediaPlatform.instagram,
          sniffed: sniffed,
          extractorLabel: 'Instagram Browser Engine',
          strictVideoOnly: isReelUrl,
        );
        if (fromSniffer != null) return fromSniffer;
      } catch (_) {}

      throw Exception(
        isReelUrl
            ? 'Instagram membatasi stream video Reel ini tanpa login. Tekan tombol Login Browser Instagram sekali saja, lalu coba lagi.'
            : 'Instagram membatasi akses anonim untuk post ini. Login lewat Pengaturan -> Login Browser (Instagram) sekali saja, lalu ulangi.',
      );
    }

    // 5. Facebook Reel / Watch / Video / Photo
    if (platform == MediaPlatform.facebook) {
      final canonicalUrl = await _direct.resolveFacebookUrl(cleanUrl);
      try {
        final ytInfo = await _extractWithYtDlp(canonicalUrl, platform, cookiesPath);
        if (ytInfo.options.isNotEmpty) return ytInfo;
      } catch (_) {}

      try {
        final sniffed = await bridge.sniffMedia(
          url: canonicalUrl,
          platform: 'facebook',
          timeoutMs: 16000,
        );
        final fromSniffer = _buildMediaInfoFromSniff(
          originalUrl: canonicalUrl,
          platform: MediaPlatform.facebook,
          sniffed: sniffed,
          extractorLabel: 'Facebook Browser Engine',
          strictVideoOnly: false,
        );
        if (fromSniffer != null) return fromSniffer;
      } catch (_) {}

      throw Exception(
        'Gagal mengambil media Facebook. Pastikan postingan bersifat publik, atau login sekali di Pengaturan -> Login Browser (Facebook).',
      );
    }

    // 6. TikTok — yt-dlp first, fallback to TikWM (great for photo slideshows & rate-limits)
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
        'Gagal mengambil media TikTok. Pastikan tautan publik dan coba lagi.',
      );
    }

    // 7. X (Twitter) — yt-dlp first, fallback to vxtwitter/fxtwitter (videos + multi-photo picker!)
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

    // 8. YouTube and other supported sites via native yt-dlp engine
    try {
      return await _extractWithYtDlp(cleanUrl, platform, cookiesPath);
    } catch (e) {
      throw Exception(_friendlyError(e));
    }
  }

  Future<MediaInfo> _analyzeProfileOrPlaylist(
    LinkDetection detection, {
    String? cookiesPath,
  }) async {
    final cleanUrl = detection.cleanUrl;
    final platform = detection.platform;

    // 1. Try yt-dlp --flat-playlist without any artificial cap (loads ALL items!)
    try {
      final rawJson = await bridge.extractProfileItems(
        url: cleanUrl,
        cookiesPath: cookiesPath,
      );
      final parsed = parseYtDlpFlatPlaylistJson(
        rawJson,
        cleanUrl,
        platform,
        usernameHint: detection.usernameHint,
      );
      if (parsed != null && parsed.selectableItems.isNotEmpty) {
        return parsed;
      }
    } catch (_) {}

    // 2. TikTok profile fallback chain:
    //    (a) Native Android Chromium WebView Profile Scraper (scrolls real TikTok page -> ALL reels/videos!)
    //    (b) Direct SSR HTML hydration fallback
    //    (c) TikWM fallback (if reachable)
    if (platform == MediaPlatform.tiktok) {
      try {
        final sniffed = await bridge.sniffProfileItems(
          url: cleanUrl,
          platform: 'tiktok',
          timeoutMs: 32000,
        );
        final fromSniff = _buildProfileFromSniff(
          originalUrl: cleanUrl,
          platform: MediaPlatform.tiktok,
          sniffed: sniffed,
          usernameHint: detection.usernameHint,
        );
        if (fromSniff != null && fromSniff.selectableItems.isNotEmpty) {
          return fromSniff;
        }
      } catch (_) {}

      if (detection.usernameHint?.isNotEmpty ?? false) {
        final tkCookie = await _safeCookieHeader('https://www.tiktok.com/');
        final ssrProfile = await _direct.extractTikTokProfileDirectHtml(
          cleanUrl,
          detection.usernameHint!,
          cookieHeader: tkCookie,
        );
        if (ssrProfile != null && ssrProfile.selectableItems.isNotEmpty) {
          return ssrProfile;
        }

        final ttProfile = await _direct.extractTikTokProfileFallback(
          cleanUrl,
          detection.usernameHint!,
        );
        if (ttProfile != null && ttProfile.selectableItems.isNotEmpty) {
          return ttProfile;
        }
      }
    }

    // 3. Instagram / X WebView Profile Scraper fallback when yt-dlp cannot fetch profile
    if (platform == MediaPlatform.instagram || platform == MediaPlatform.x) {
      try {
        final sniffed = await bridge.sniffProfileItems(
          url: cleanUrl,
          platform: platform.name,
          timeoutMs: 28000,
        );
        final fromSniff = _buildProfileFromSniff(
          originalUrl: cleanUrl,
          platform: platform,
          sniffed: sniffed,
          usernameHint: detection.usernameHint,
        );
        if (fromSniff != null && fromSniff.selectableItems.isNotEmpty) {
          return fromSniff;
        }
      } catch (_) {}
    }

    throw Exception(
      'Gagal memuat daftar media dari profil ${platform.label}. Pastikan akun bersifat publik atau login lewat Pengaturan -> Login Browser (${platform.label}) terlebih dahulu.',
    );
  }

  MediaInfo? _buildProfileFromSniff({
    required String originalUrl,
    required MediaPlatform platform,
    required SniffedProfileResult sniffed,
    String? usernameHint,
  }) {
    if (sniffed.items.isEmpty) return null;
    final creator = (sniffed.creator.isNotEmpty
            ? sniffed.creator
            : (usernameHint ?? platform.label))
        .replaceFirst('@', '')
        .trim();
    final items = <SelectableMediaItem>[];
    for (int i = 0; i < sniffed.items.length; i++) {
      final raw = sniffed.items[i];
      final isImg = raw.kind.toLowerCase() == 'image';
      items.add(
        SelectableMediaItem(
          id: 'sniff_prof_${platform.name}_${raw.id.isNotEmpty ? raw.id : i}',
          title: raw.title.isNotEmpty ? raw.title : '${platform.label}_${raw.id}',
          thumbnailUrl: raw.thumbnail.startsWith('http') ? raw.thumbnail : null,
          sourcePostUrl: raw.url,
          extension: isImg ? 'jpg' : 'mp4',
          kind: isImg ? MediaKind.image : MediaKind.video,
          engine: DownloadEngine.ytDlp,
          badgeLabel: raw.badge.isNotEmpty ? raw.badge : '#${i + 1}',
          author: raw.author.isNotEmpty ? raw.author : creator,
        ),
      );
    }

    final profileUrl = sniffed.finalUrl.startsWith('http')
        ? sniffed.finalUrl
        : originalUrl;

    return MediaInfo(
      originalUrl: profileUrl,
      platform: platform,
      title: 'Profil ${platform.label} @$creator (${items.length} media)',
      author: creator,
      thumbnailUrl: items
          .map((e) => e.thumbnailUrl)
          .whereType<String>()
          .firstOrNull,
      extractorLabel: '${platform.label} Browser Profil',
      options: const [],
      selectableItems: items,
      isBulkProfile: true,
      creatorProfileUrl: profileUrl,
    );
  }

  MediaInfo? parseYtDlpFlatPlaylistJson(
    String rawJson,
    String originalUrl,
    MediaPlatform platform, {
    String? usernameHint,
  }) {
    final dynamic decoded = jsonDecode(rawJson);
    if (decoded is! Map) return null;

    final entries = decoded['entries'];
    if (entries is! List || entries.isEmpty) return null;

    final creator = (decoded['uploader']?.toString() ??
            decoded['channel']?.toString() ??
            decoded['title']?.toString() ??
            usernameHint ??
            platform.label)
        .replaceFirst('@', '')
        .trim();

    final items = <SelectableMediaItem>[];
    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry is! Map) continue;

      final id = entry['id']?.toString() ?? '$i';
      String? entryUrl = entry['webpage_url']?.toString() ?? entry['url']?.toString();
      if (entryUrl != null && !entryUrl.startsWith('http')) {
        if (platform == MediaPlatform.youtube) {
          entryUrl = 'https://www.youtube.com/watch?v=$entryUrl';
        }
      }
      if (entryUrl == null || !entryUrl.startsWith('http')) continue;

      String? thumb = entry['thumbnail']?.toString();
      if ((thumb == null || thumb.isEmpty) && entry['thumbnails'] is List) {
        final tList = entry['thumbnails'] as List;
        if (tList.isNotEmpty && tList.last is Map) {
          thumb = (tList.last as Map)['url']?.toString();
        }
      }

      final title = (entry['title']?.toString() ?? '${platform.label}_$id').trim();
      final durSec = (entry['duration'] as num?)?.round() ?? 0;
      final badge = durSec > 0 ? _fmtSec(durSec) : '#${i + 1}';

      items.add(
        SelectableMediaItem(
          id: 'bulk_${platform.name}_$id',
          title: title,
          thumbnailUrl: thumb,
          sourcePostUrl: entryUrl,
          extension: 'mp4',
          kind: MediaKind.video,
          engine: DownloadEngine.ytDlp,
          badgeLabel: badge,
          author: creator,
        ),
      );
    }

    if (items.isEmpty) return null;

    final collectionTitle = (decoded['title']?.toString() ?? 'Profil $creator').trim();
    return MediaInfo(
      originalUrl: originalUrl,
      platform: platform,
      title: '$collectionTitle (${items.length} media)',
      author: creator,
      thumbnailUrl: items.first.thumbnailUrl,
      extractorLabel: '${platform.label} Mode Massal',
      options: const [],
      selectableItems: items,
      isBulkProfile: true,
      creatorProfileUrl: originalUrl,
    );
  }

  MediaInfo? _buildMediaInfoFromSniff({
    required String originalUrl,
    required MediaPlatform platform,
    required SniffedMediaResult sniffed,
    required String extractorLabel,
    required bool strictVideoOnly,
  }) {
    final headers = <String, String>{
      if (sniffed.userAgent.isNotEmpty) 'User-Agent': sniffed.userAgent,
      if (sniffed.cookies.isNotEmpty) 'Cookie': sniffed.cookies,
      if (sniffed.finalUrl.startsWith('http')) 'Referer': sniffed.finalUrl,
    };

    final options = <MediaFormatOption>[];
    final selectableItems = <SelectableMediaItem>[];

    final rawTitle = sniffed.title.trim();
    final title = rawTitle.isNotEmpty
        ? rawTitle
        : '${platform.label}_${DateTime.now().millisecondsSinceEpoch}';
    final author = sniffed.author.trim().isNotEmpty
        ? sniffed.author.trim()
        : platform.label;

    for (int i = 0; i < sniffed.videos.length; i++) {
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

    if (!strictVideoOnly && sniffed.images.isNotEmpty) {
      final uniqueImages = sniffed.images.toList();
      for (int i = 0; i < uniqueImages.length; i++) {
        final ext = _guessImageExt(uniqueImages[i]);
        selectableItems.add(
          SelectableMediaItem(
            id: 'sniff_img_$i',
            title: uniqueImages.length > 1 ? '$title (${i + 1})' : title,
            thumbnailUrl: uniqueImages[i],
            directUrl: uniqueImages[i],
            extension: ext,
            kind: MediaKind.image,
            engine: DownloadEngine.directHttp,
            headers: headers,
            badgeLabel: 'Foto ${i + 1}',
            author: author,
          ),
        );
      }
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
      selectableItems: selectableItems,
      thumbnailHeaders: headers,
    );
  }

  Future<String> _safeCookieHeader(String url) async {
    try {
      return await bridge.getCookieHeader(url);
    } catch (_) {
      return '';
    }
  }

  String _guessImageExt(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.png')) return 'png';
    if (lower.contains('.webp')) return 'webp';
    return 'jpg';
  }

  String _fmtSec(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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
            data['uploader_id']?.toString() ??
            data['channel']?.toString() ??
            data['creator']?.toString() ??
            platform.label)
        .replaceFirst('@', '')
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
            'bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best[ext=mp4]/best',
      ),
    );

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
              'bestvideo[vcodec^=avc1][height<=$tier][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=$tier][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=$tier]+bestaudio/best[height<=$tier]/best',
        ),
      );
    }

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
    final channelUrl = (data['channel_url']?.toString() ??
            data['uploader_url']?.toString() ??
            '')
        .trim();

    return MediaInfo(
      originalUrl: originalUrl,
      platform: platform,
      title: title,
      author: author,
      thumbnailUrl: thumbnailUrl,
      duration: duration,
      extractorLabel: 'yt-dlp ($extractor)',
      options: options,
      creatorProfileUrl: channelUrl.startsWith('http') ? channelUrl : null,
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
