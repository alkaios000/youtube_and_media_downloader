import 'package:flutter/material.dart';

enum MediaPlatform {
  youtube,
  tiktok,
  douyin,
  instagram,
  x,
  pixiv,
  facebook,
  other,
}

enum LinkKind {
  singlePost,
  profile,
  playlist,
}

class LinkDetection {
  final String cleanUrl;
  final MediaPlatform platform;
  final LinkKind kind;
  final String contentLabel;
  final String? usernameHint;

  const LinkDetection({
    required this.cleanUrl,
    required this.platform,
    required this.kind,
    required this.contentLabel,
    this.usernameHint,
  });

  bool get isBulk => kind == LinkKind.profile || kind == LinkKind.playlist;

  String get summaryLabel => '${platform.label} • $contentLabel';
}

extension MediaPlatformMeta on MediaPlatform {
  String get label {
    switch (this) {
      case MediaPlatform.youtube:
        return 'YouTube';
      case MediaPlatform.tiktok:
        return 'TikTok';
      case MediaPlatform.douyin:
        return 'Douyin';
      case MediaPlatform.instagram:
        return 'Instagram';
      case MediaPlatform.x:
        return 'X';
      case MediaPlatform.pixiv:
        return 'Pixiv';
      case MediaPlatform.facebook:
        return 'Facebook';
      case MediaPlatform.other:
        return 'Lainnya';
    }
  }

  String get folderName => label;

  Color get brandColor {
    switch (this) {
      case MediaPlatform.youtube:
        return const Color(0xFFFF2D55);
      case MediaPlatform.tiktok:
        return const Color(0xFF00F2EA);
      case MediaPlatform.douyin:
        return const Color(0xFFFE2C55);
      case MediaPlatform.instagram:
        return const Color(0xFFE1306C);
      case MediaPlatform.x:
        return const Color(0xFF94A3B8);
      case MediaPlatform.pixiv:
        return const Color(0xFF0096FA);
      case MediaPlatform.facebook:
        return const Color(0xFF1877F2);
      case MediaPlatform.other:
        return const Color(0xFF38BDF8);
    }
  }

  List<Color> get gradientColors {
    switch (this) {
      case MediaPlatform.youtube:
        return const [Color(0xFFFF0033), Color(0xFFFF4D4D)];
      case MediaPlatform.tiktok:
        return const [Color(0xFF00D2D3), Color(0xFFFF2E63)];
      case MediaPlatform.douyin:
        return const [Color(0xFF1E293B), Color(0xFFFE2C55)];
      case MediaPlatform.instagram:
        return const [Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF)];
      case MediaPlatform.x:
        return const [Color(0xFF334155), Color(0xFF0F172A)];
      case MediaPlatform.pixiv:
        return const [Color(0xFF0096FA), Color(0xFF38BDF8)];
      case MediaPlatform.facebook:
        return const [Color(0xFF1877F2), Color(0xFF3B82F6)];
      case MediaPlatform.other:
        return const [Color(0xFF0284C7), Color(0xFF6366F1)];
    }
  }

  IconData get icon {
    switch (this) {
      case MediaPlatform.youtube:
        return Icons.play_circle_filled_rounded;
      case MediaPlatform.tiktok:
        return Icons.music_note_rounded;
      case MediaPlatform.douyin:
        return Icons.graphic_eq_rounded;
      case MediaPlatform.instagram:
        return Icons.camera_alt_rounded;
      case MediaPlatform.x:
        return Icons.alternate_email_rounded;
      case MediaPlatform.pixiv:
        return Icons.brush_rounded;
      case MediaPlatform.facebook:
        return Icons.facebook_rounded;
      case MediaPlatform.other:
        return Icons.language_rounded;
    }
  }

  static MediaPlatform fromKey(String? key) {
    final normalized = (key ?? '').trim().toLowerCase();
    for (final p in MediaPlatform.values) {
      if (p.name.toLowerCase() == normalized ||
          p.label.toLowerCase() == normalized) {
        return p;
      }
    }
    return MediaPlatform.other;
  }
}

class UrlParser {
  // Match strict ASCII URL characters so attached Chinese text / emojis from
  // Douyin or TikTok share captions never get glued onto the extracted URL.
  static final RegExp _httpUrlRegex = RegExp(
    r"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+",
    caseSensitive: false,
  );

  static final RegExp _bareHostRegex = RegExp(
    r"(?:^|[\s\u3000])((?:www\.|m\.|v\.|vt\.|vm\.|web\.|mobile\.)?(?:youtube\.com|youtu\.be|tiktok\.com|douyin\.com|iesdouyin\.com|instagram\.com|instagr\.am|ig\.me|x\.com|twitter\.com|pixiv\.net|facebook\.com|fb\.watch|fb\.com)/[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+)",
    caseSensitive: false,
  );

  static final RegExp _pixivUserShortcutRegex = RegExp(
    r'^(?:pixiv[:\s]+@?)(.+)$',
    caseSensitive: false,
  );

  /// Extracts a clean URL (or synthetic `pixiv-user://` query for `pixiv:username`).
  static String? extractUrl(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return null;

    // Support direct Pixiv username shortcut: "pixiv:wlop" or "pixiv:123456"
    final pixivShortcut = _pixivUserShortcutRegex.firstMatch(trimmed);
    if (pixivShortcut != null) {
      final query = pixivShortcut.group(1)?.trim() ?? '';
      if (query.isNotEmpty) {
        if (RegExp(r'^\d+$').hasMatch(query)) {
          return 'https://www.pixiv.net/users/$query';
        }
        return 'https://www.pixiv.net/search_user.php?s_mode=s_usr&nick=${Uri.encodeComponent(query)}';
      }
    }

    String? candidate;
    final match = _httpUrlRegex.firstMatch(trimmed);
    if (match != null) {
      candidate = match.group(0);
    } else {
      final bareMatch = _bareHostRegex.firstMatch(trimmed);
      if (bareMatch != null) {
        candidate = 'https://${bareMatch.group(1)}';
      }
    }

    if (candidate == null) return null;

    // Strip stray trailing punctuation that often clings to pasted share text.
    candidate = candidate.replaceAll(RegExp(r'[.,!?;:)\]]+$'), '');

    final uri = Uri.tryParse(candidate);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    return candidate;
  }

  static MediaPlatform detectPlatform(String rawInput) {
    final url = extractUrl(rawInput);
    if (url == null) return MediaPlatform.other;
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();

    if (_hostMatches(host, const [
      'youtube.com',
      'youtu.be',
      'youtube-nocookie.com',
    ])) {
      return MediaPlatform.youtube;
    }
    if (_hostMatches(host, const ['tiktok.com'])) {
      return MediaPlatform.tiktok;
    }
    if (_hostMatches(host, const ['douyin.com', 'iesdouyin.com'])) {
      return MediaPlatform.douyin;
    }
    if (_hostMatches(host, const [
      'instagram.com',
      'instagr.am',
      'ig.me',
      'ddinstagram.com',
    ])) {
      return MediaPlatform.instagram;
    }
    if (_hostMatches(host, const [
      'x.com',
      'twitter.com',
      'fxtwitter.com',
      'vxtwitter.com',
      'fixupx.com',
      't.co',
    ])) {
      return MediaPlatform.x;
    }
    if (_hostMatches(host, const ['pixiv.net', 'pximg.net'])) {
      return MediaPlatform.pixiv;
    }
    if (_hostMatches(host, const [
      'facebook.com',
      'fb.watch',
      'fb.com',
    ])) {
      return MediaPlatform.facebook;
    }
    return MediaPlatform.other;
  }

  /// Detailed live detection used in the UI & extractor orchestrator.
  static LinkDetection? inspect(String rawInput) {
    final url = extractUrl(rawInput);
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final platform = detectPlatform(url);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final lowerPath = uri.path.toLowerCase();

    switch (platform) {
      case MediaPlatform.youtube:
        if (lowerPath.startsWith('/playlist') &&
            (uri.queryParameters['list']?.isNotEmpty ?? false)) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.playlist,
            contentLabel: 'Playlist (Mode Massal)',
          );
        }
        if (lowerPath.startsWith('/@') ||
            lowerPath.startsWith('/channel/') ||
            lowerPath.startsWith('/c/') ||
            lowerPath.startsWith('/user/')) {
          final hint = segments.isNotEmpty ? segments.first : null;
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.profile,
            contentLabel: 'Channel (Mode Massal)',
            usernameHint: hint,
          );
        }
        if (lowerPath.startsWith('/shorts/')) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.singlePost,
            contentLabel: 'Shorts',
          );
        }
        return LinkDetection(
          cleanUrl: url,
          platform: platform,
          kind: LinkKind.singlePost,
          contentLabel: 'Video',
        );

      case MediaPlatform.tiktok:
        if (segments.isNotEmpty &&
            segments.first.startsWith('@') &&
            !lowerPath.contains('/video/') &&
            !lowerPath.contains('/photo/')) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.profile,
            contentLabel: 'Profil (Mode Massal)',
            usernameHint: segments.first.replaceFirst('@', ''),
          );
        }
        return LinkDetection(
          cleanUrl: url,
          platform: platform,
          kind: LinkKind.singlePost,
          contentLabel: 'Video / Slideshow',
        );

      case MediaPlatform.douyin:
        if (lowerPath.startsWith('/user/')) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.profile,
            contentLabel: 'Profil (Mode Massal)',
            usernameHint: segments.length > 1 ? segments[1] : null,
          );
        }
        return LinkDetection(
          cleanUrl: url,
          platform: platform,
          kind: LinkKind.singlePost,
          contentLabel: 'Video / Foto',
        );

      case MediaPlatform.instagram:
        if (lowerPath.contains('/reel/') ||
            lowerPath.contains('/reels/') ||
            lowerPath.contains('/share/reel/')) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.singlePost,
            contentLabel: 'Reel (Video)',
          );
        }
        if (lowerPath.contains('/p/') ||
            lowerPath.contains('/tv/') ||
            lowerPath.contains('/share/') ||
            lowerPath.contains('/stories/')) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.singlePost,
            contentLabel: 'Post / Media',
          );
        }
        const reservedIg = {
          'explore',
          'accounts',
          'direct',
          'about',
          'legal',
          'developer',
          'reels',
          'reel',
          'p',
          'tv',
          'share',
          'stories',
        };
        if (segments.isNotEmpty && !reservedIg.contains(segments.first.toLowerCase())) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.profile,
            contentLabel: 'Profil (Mode Massal)',
            usernameHint: segments.first,
          );
        }
        return LinkDetection(
          cleanUrl: url,
          platform: platform,
          kind: LinkKind.singlePost,
          contentLabel: 'Media',
        );

      case MediaPlatform.x:
        if (lowerPath.contains('/status/') || uri.host.toLowerCase() == 't.co') {
          final userHint = segments.isNotEmpty ? segments.first : null;
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.singlePost,
            contentLabel: 'Post (Video / Foto)',
            usernameHint: userHint,
          );
        }
        const reservedX = {
          'home',
          'explore',
          'search',
          'notifications',
          'messages',
          'i',
          'settings',
          'compose',
          'intent',
          'hashtag',
        };
        if (segments.isNotEmpty && !reservedX.contains(segments.first.toLowerCase())) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.profile,
            contentLabel: 'Profil (Mode Massal)',
            usernameHint: segments.first,
          );
        }
        return LinkDetection(
          cleanUrl: url,
          platform: platform,
          kind: LinkKind.singlePost,
          contentLabel: 'Post',
        );

      case MediaPlatform.pixiv:
        if (lowerPath.contains('/users/') ||
            lowerPath.contains('search_user.php') ||
            (lowerPath.contains('member.php') &&
                (uri.queryParameters['id']?.isNotEmpty ?? false))) {
          final uidMatch = RegExp(r'/users/(\d+)').firstMatch(lowerPath);
          final nick = uri.queryParameters['nick'];
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.profile,
            contentLabel: 'Profil Kreator (Mode Massal)',
            usernameHint: nick ?? uidMatch?.group(1),
          );
        }
        return LinkDetection(
          cleanUrl: url,
          platform: platform,
          kind: LinkKind.singlePost,
          contentLabel: 'Ilustrasi / Manga',
        );

      case MediaPlatform.facebook:
        if (uri.host.toLowerCase().contains('fb.watch') ||
            lowerPath.contains('/reel/') ||
            lowerPath.contains('/watch') ||
            lowerPath.contains('/share/') ||
            lowerPath.contains('/posts/') ||
            lowerPath.contains('/photo') ||
            RegExp(r'/videos/\d+').hasMatch(lowerPath)) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.singlePost,
            contentLabel: lowerPath.contains('/reel/') ? 'Reel' : 'Video / Post',
          );
        }
        const reservedFb = {
          'watch',
          'marketplace',
          'groups',
          'gaming',
          'events',
          'login',
          'help',
          'share',
          'reel',
          'reels',
          'photo',
          'photo.php',
          'permalink.php',
          'story.php',
        };
        if (segments.isNotEmpty && !reservedFb.contains(segments.first.toLowerCase())) {
          return LinkDetection(
            cleanUrl: url,
            platform: platform,
            kind: LinkKind.profile,
            contentLabel: 'Halaman / Profil (Mode Massal)',
            usernameHint: segments.first,
          );
        }
        return LinkDetection(
          cleanUrl: url,
          platform: platform,
          kind: LinkKind.singlePost,
          contentLabel: 'Video / Post',
        );

      case MediaPlatform.other:
        return LinkDetection(
          cleanUrl: url,
          platform: platform,
          kind: LinkKind.singlePost,
          contentLabel: uri.host,
        );
    }
  }

  static bool isCorePlatformUrl(String rawInput) {
    final url = extractUrl(rawInput);
    if (url == null) return false;
    final platform = detectPlatform(url);
    return platform != MediaPlatform.other;
  }

  static bool _hostMatches(String host, List<String> domains) {
    for (final domain in domains) {
      if (host == domain || host.endsWith('.$domain')) {
        return true;
      }
    }
    return false;
  }
}
