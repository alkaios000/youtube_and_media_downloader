import 'package:flutter/material.dart';

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
  final ThemeMode themeMode;
  final DefaultQualityPreset defaultQuality;
  final bool useAria2c;
  final bool clipboardAutoDetect;
  final String updateChannel; // stable | nightly
  final String customCookies;

  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.defaultQuality = DefaultQualityPreset.best,
    this.useAria2c = false,
    this.clipboardAutoDetect = true,
    this.updateChannel = 'stable',
    this.customCookies = '',
  });

  bool get hasCookies => customCookies.trim().isNotEmpty;

  AppSettings copyWith({
    ThemeMode? themeMode,
    DefaultQualityPreset? defaultQuality,
    bool? useAria2c,
    bool? clipboardAutoDetect,
    String? updateChannel,
    String? customCookies,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      useAria2c: useAria2c ?? this.useAria2c,
      clipboardAutoDetect: clipboardAutoDetect ?? this.clipboardAutoDetect,
      updateChannel: updateChannel ?? this.updateChannel,
      customCookies: customCookies ?? this.customCookies,
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
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
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
    );
  }
}
