import 'package:flutter/material.dart';

import 'media_metadata.dart';

enum DefaultQualityPreset {
  best,
  p1080,
  p720,
  p480,
  audioMp3,
}

extension DefaultQualityPresetMeta on DefaultQualityPreset {
  String get label {
    switch (this) {
      case DefaultQualityPreset.best:
        return 'Terbaik (Otomatis HD)';
      case DefaultQualityPreset.p1080:
        return 'Full HD 1080p';
      case DefaultQualityPreset.p720:
        return 'HD 720p';
      case DefaultQualityPreset.p480:
        return 'Hemat 480p';
      case DefaultQualityPreset.audioMp3:
        return 'Audio MP3 Saja';
    }
  }
}

class AppSettings {
  static const int minConcurrentAlbums = 1;
  static const int maxConcurrentAlbumsLimit = 6;
  static const List<int> rateLimitPresetsMs = [0, 300, 600, 1000, 2000];

  final ThemeMode themeMode;
  final DefaultQualityPreset defaultQuality;
  final bool useAria2c;
  final bool clipboardAutoDetect;
  final String updateChannel; // stable | nightly
  final String customCookies;

  /// Maximum number of albums/download tasks processed simultaneously (1..6).
  final int maxConcurrentAlbums;

  /// Optional cooldown delay in milliseconds between album/file requests
  /// to prevent HTTP 429 rate limits on Pixiv, TikTok, Instagram, etc.
  final int downloadRateLimitMs;

  /// Content visibility checklist filters (all enabled by default).
  final bool showNormalContent;
  final bool showEcchiContent;
  final bool showNsfwContent;

  /// Security & Privacy lock controls.
  final bool appLockEnabled;
  final String appLockPinHash;
  final bool appLockUseBiometric;

  /// `'app'` locks the whole app on launch/resume; `'vault'` locks the File tab
  /// and Content Visibility settings.
  final String appLockScope;
  final bool secureScreenEnabled;

  /// Recycle Bin / Trash settings (protects accidental Fast Delete taps).
  final bool trashEnabled;
  final int trashRetentionDays; // 0 = manual, 7, 14, 30

  /// Android Foreground Service & completion notification toggle.
  final bool notificationsEnabled;

  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.defaultQuality = DefaultQualityPreset.best,
    this.useAria2c = false,
    this.clipboardAutoDetect = true,
    this.updateChannel = 'stable',
    this.customCookies = '',
    this.maxConcurrentAlbums = 3,
    this.downloadRateLimitMs = 0,
    this.showNormalContent = true,
    this.showEcchiContent = true,
    this.showNsfwContent = true,
    this.appLockEnabled = false,
    this.appLockPinHash = '',
    this.appLockUseBiometric = true,
    this.appLockScope = 'app',
    this.secureScreenEnabled = false,
    this.trashEnabled = true,
    this.trashRetentionDays = 14,
    this.notificationsEnabled = true,
  });

  bool get hasCookies => customCookies.trim().isNotEmpty;
  bool get hasPinConfigured => appLockPinHash.trim().isNotEmpty;
  bool get isSecurityLockActive =>
      appLockEnabled && (hasPinConfigured || appLockUseBiometric);

  /// Deterministic salted multi-round 128-bit hash for local PIN storage.
  static String hashPin(String pin) {
    final clean = pin.trim();
    if (clean.isEmpty) return '';
    const salt = 'all_download_vault_pin_v1::';
    final input = '$salt$clean::$salt${clean.length}';
    int h1 = 0x811c9dc5;
    int h2 = 0x9e3779b9;
    int h3 = 0x85ebca6b;
    int h4 = 0xc2b2ae35;
    for (int round = 0; round < 64; round++) {
      for (int i = 0; i < input.length; i++) {
        final c = input.codeUnitAt(i) ^ ((round * 31 + i * 17) & 0xff);
        h1 = ((h1 ^ c) * 0x01000193) & 0xffffffff;
        h2 = (((h2 << 5) | (h2 >>> 27)) ^ h1 ^ c) & 0xffffffff;
        h3 = ((h3 * 33) ^ h2 ^ (c + round)) & 0xffffffff;
        h4 = (((h4 << 7) | (h4 >>> 25)) + h3 + h1) & 0xffffffff;
      }
    }
    return [h1, h2, h3, h4]
        .map((v) => v.toRadixString(16).padLeft(8, '0'))
        .join();
  }

  bool verifyPin(String candidate) {
    if (!hasPinConfigured) return false;
    return hashPin(candidate) == appLockPinHash;
  }

  String get trashRetentionLabel {
    if (trashRetentionDays <= 0) return 'Manual (tidak hapus otomatis)';
    return '$trashRetentionDays hari';
  }

  bool get showsAllContentRatings =>
      showNormalContent && showEcchiContent && showNsfwContent;

  bool isContentRatingVisible(ContentRating rating) {
    switch (rating) {
      case ContentRating.normal:
        return showNormalContent;
      case ContentRating.ecchi:
        return showEcchiContent;
      case ContentRating.nsfw:
        return showNsfwContent;
    }
  }

  String get contentVisibilitySummary {
    final active = <String>[
      if (showNormalContent) ContentRating.normal.label,
      if (showEcchiContent) ContentRating.ecchi.label,
      if (showNsfwContent) ContentRating.nsfw.label,
    ];
    if (active.length == 3) return 'Semua ditampilkan (Biasa, Ecchi, NSFW)';
    if (active.isEmpty) return 'Semua disembunyikan';
    return 'Ditampilkan: ${active.join(', ')}';
  }

  String get rateLimitLabel {
    if (downloadRateLimitMs <= 0) return 'Tanpa jeda (Maksimal)';
    if (downloadRateLimitMs >= 1000) {
      final sec = downloadRateLimitMs / 1000.0;
      return sec == sec.roundToDouble()
          ? '${sec.toInt()} detik / tugas'
          : '${sec.toStringAsFixed(1)} detik / tugas';
    }
    return '$downloadRateLimitMs ms / tugas';
  }

  AppSettings copyWith({
    ThemeMode? themeMode,
    DefaultQualityPreset? defaultQuality,
    bool? useAria2c,
    bool? clipboardAutoDetect,
    String? updateChannel,
    String? customCookies,
    int? maxConcurrentAlbums,
    int? downloadRateLimitMs,
    bool? showNormalContent,
    bool? showEcchiContent,
    bool? showNsfwContent,
    bool? appLockEnabled,
    String? appLockPinHash,
    bool? appLockUseBiometric,
    String? appLockScope,
    bool? secureScreenEnabled,
    bool? trashEnabled,
    int? trashRetentionDays,
    bool? notificationsEnabled,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      useAria2c: useAria2c ?? this.useAria2c,
      clipboardAutoDetect: clipboardAutoDetect ?? this.clipboardAutoDetect,
      updateChannel: updateChannel ?? this.updateChannel,
      customCookies: customCookies ?? this.customCookies,
      maxConcurrentAlbums: (maxConcurrentAlbums ?? this.maxConcurrentAlbums)
          .clamp(minConcurrentAlbums, maxConcurrentAlbumsLimit),
      downloadRateLimitMs: (downloadRateLimitMs ?? this.downloadRateLimitMs)
          .clamp(0, 10000),
      showNormalContent: showNormalContent ?? this.showNormalContent,
      showEcchiContent: showEcchiContent ?? this.showEcchiContent,
      showNsfwContent: showNsfwContent ?? this.showNsfwContent,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      appLockPinHash: appLockPinHash ?? this.appLockPinHash,
      appLockUseBiometric: appLockUseBiometric ?? this.appLockUseBiometric,
      appLockScope: (appLockScope == 'vault' || appLockScope == 'app')
          ? appLockScope!
          : this.appLockScope,
      secureScreenEnabled: secureScreenEnabled ?? this.secureScreenEnabled,
      trashEnabled: trashEnabled ?? this.trashEnabled,
      trashRetentionDays: (trashRetentionDays ?? this.trashRetentionDays)
          .clamp(0, 365),
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'themeMode': themeMode.name,
      'defaultQuality': defaultQuality.name,
      'useAria2c': useAria2c,
      'clipboardAutoDetect': clipboardAutoDetect,
      'updateChannel': updateChannel,
      'customCookies': customCookies,
      'maxConcurrentAlbums': maxConcurrentAlbums,
      'downloadRateLimitMs': downloadRateLimitMs,
      'showNormalContent': showNormalContent,
      'showEcchiContent': showEcchiContent,
      'showNsfwContent': showNsfwContent,
      'appLockEnabled': appLockEnabled,
      'appLockPinHash': appLockPinHash,
      'appLockUseBiometric': appLockUseBiometric,
      'appLockScope': appLockScope,
      'secureScreenEnabled': secureScreenEnabled,
      'trashEnabled': trashEnabled,
      'trashRetentionDays': trashRetentionDays,
      'notificationsEnabled': notificationsEnabled,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final parsedConcurrent = (json['maxConcurrentAlbums'] as num?)?.toInt() ?? 3;
    final parsedDelay = (json['downloadRateLimitMs'] as num?)?.toInt() ?? 0;
    final parsedRetention = (json['trashRetentionDays'] as num?)?.toInt() ?? 14;
    final rawScope = json['appLockScope']?.toString() ?? 'app';
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == json['themeMode'],
        orElse: () => ThemeMode.dark,
      ),
      defaultQuality: DefaultQualityPreset.values.firstWhere(
        (q) => q.name == json['defaultQuality'],
        orElse: () => DefaultQualityPreset.best,
      ),
      useAria2c: json['useAria2c'] as bool? ?? false,
      clipboardAutoDetect: json['clipboardAutoDetect'] as bool? ?? true,
      updateChannel: json['updateChannel']?.toString() ?? 'stable',
      customCookies: json['customCookies']?.toString() ?? '',
      maxConcurrentAlbums: parsedConcurrent.clamp(
        minConcurrentAlbums,
        maxConcurrentAlbumsLimit,
      ),
      downloadRateLimitMs: parsedDelay.clamp(0, 10000),
      showNormalContent: json['showNormalContent'] as bool? ?? true,
      showEcchiContent: json['showEcchiContent'] as bool? ?? true,
      showNsfwContent: json['showNsfwContent'] as bool? ?? true,
      appLockEnabled: json['appLockEnabled'] as bool? ?? false,
      appLockPinHash: json['appLockPinHash']?.toString() ?? '',
      appLockUseBiometric: json['appLockUseBiometric'] as bool? ?? true,
      appLockScope: rawScope == 'vault' ? 'vault' : 'app',
      secureScreenEnabled: json['secureScreenEnabled'] as bool? ?? false,
      trashEnabled: json['trashEnabled'] as bool? ?? true,
      trashRetentionDays: parsedRetention.clamp(0, 365),
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
    );
  }
}
