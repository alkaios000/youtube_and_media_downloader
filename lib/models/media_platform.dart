import 'package:flutter/material.dart';

enum MediaPlatform {
  youtube,
  tiktok,
  douyin,
  instagram,
  x,
  other,
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
      case MediaPlatform.other:
        return 'Link Media';
    }
  }

  String get shortTag {
    switch (this) {
      case MediaPlatform.youtube:
        return 'YT';
      case MediaPlatform.tiktok:
        return 'TT';
      case MediaPlatform.douyin:
        return 'DY';
      case MediaPlatform.instagram:
        return 'IG';
      case MediaPlatform.x:
        return 'X';
      case MediaPlatform.other:
        return 'WEB';
    }
  }

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
      case MediaPlatform.other:
        return Icons.language_rounded;
    }
  }

  static MediaPlatform fromKey(String? key) {
    return MediaPlatform.values.firstWhere(
      (p) => p.name == key,
      orElse: () => MediaPlatform.other,
    );
  }
}

class UrlParser {
  static final RegExp _httpUrlRegex = RegExp(
    r'https?://[^\s\u3000<>"{}|\\^`\[\]（）【】《》，。！？；：]+',
    caseSensitive: false,
  );

  static final RegExp _bareHostRegex = RegExp(
    r'(?:^|\s)((?:www\.|m\.|v\.|vt\.|vm\.|mobile\.)?(?:youtube\.com|youtu\.be|tiktok\.com|douyin\.com|iesdouyin\.com|instagram\.com|instagr\.am|x\.com|twitter\.com)/[^\s]+)',
    caseSensitive: false,
  );

  /// Extracts a clean URL even from messy share text (e.g., Douyin / TikTok / X captions).
  static String? extractUrl(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return null;

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
    return MediaPlatform.other;
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
