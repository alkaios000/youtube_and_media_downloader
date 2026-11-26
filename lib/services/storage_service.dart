import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/creator_profile.dart';
import '../models/download_item.dart';

class BackupDataBundle {
  final AppSettings settings;
  final Set<String> downloadedMarkers;
  final List<CreatorProfileRecord> creatorProfiles;
  final List<DownloadItem> history;
  final DateTime? exportedAt;

  const BackupDataBundle({
    required this.settings,
    required this.downloadedMarkers,
    required this.creatorProfiles,
    required this.history,
    this.exportedAt,
  });
}

class StorageService {
  static const String _historyKey = 'linkdrop_download_history_v1';
  static const String _settingsKey = 'linkdrop_settings_v1';
  static const String _downloadedMarkersKey = 'all_download_markers_v1';
  static const String _creatorProfilesKey = 'all_download_creator_profiles_v1';

  Future<List<DownloadItem>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.whereType<Map>().map((e) {
        final item = DownloadItem.fromJson(Map<String, dynamic>.from(e));
        // If app was terminated mid-download, auto-convert into resumable Paused state!
        if (item.isActive) {
          return item.copyWith(
            status: DownloadStatus.paused,
            statusText: item.subFiles.length > 1
                ? 'Terjeda (${item.completedSubFilesCount}/${item.subFiles.length} selesai) — ketuk Lanjut'
                : 'Terjeda otomatis — ketuk Lanjut',
            subFiles: item.subFiles
                .map((s) => s.isActive
                    ? s.copyWith(status: DownloadStatus.paused, speedText: '')
                    : s)
                .toList(growable: false),
          );
        }
        return item;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// Saves ALL items including paused & active checkpoints so nothing is lost on pause/restart.
  Future<void> saveHistory(List<DownloadItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    final toSave = items.map((e) => e.toJson()).toList(growable: false);
    await prefs.setString(_historyKey, jsonEncode(toSave));
  }

  /// Returns null when markers have never been saved yet (first run / upgrade).
  Future<Set<String>?> loadDownloadedMarkers() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_downloadedMarkersKey)) return null;
    final list = prefs.getStringList(_downloadedMarkersKey);
    if (list == null) return <String>{};
    return list.where((e) => e.isNotEmpty).toSet();
  }

  Future<void> saveDownloadedMarkers(Set<String> markers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _downloadedMarkersKey,
      markers.toList(growable: false),
    );
  }

  Future<List<CreatorProfileRecord>> loadCreatorProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_creatorProfilesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => CreatorProfileRecord.fromJson(Map<String, dynamic>.from(e)))
          .where((r) => r.profileUrl.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveCreatorProfiles(List<CreatorProfileRecord> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _creatorProfilesKey,
      jsonEncode(profiles.map((e) => e.toJson()).toList(growable: false)),
    );
  }

  Future<AppSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_settingsKey);
    if (raw == null || raw.isEmpty) return const AppSettings();
    try {
      final map = jsonDecode(raw) as Map;
      return AppSettings.fromJson(Map<String, dynamic>.from(map));
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
    await syncCookiesFile(settings.customCookies);
  }

  /// Builds a portable JSON backup containing settings, downloaded markers,
  /// saved per-artist profile URLs, and download history/paused tasks.
  String buildBackupJson({
    required AppSettings settings,
    required Set<String> downloadedMarkers,
    required List<CreatorProfileRecord> creatorProfiles,
    required List<DownloadItem> history,
  }) {
    final payload = {
      'app': 'all_download',
      'schemaVersion': 2,
      'exportedAt': DateTime.now().toIso8601String(),
      'settings': settings.toJson(),
      'downloadedMarkers': downloadedMarkers.toList(growable: false),
      'creatorProfiles': creatorProfiles.map((e) => e.toJson()).toList(growable: false),
      'history': history.map((e) => e.toJson()).toList(growable: false),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Parses & validates a JSON backup exported by [buildBackupJson].
  BackupDataBundle parseBackupJson(String rawJson) {
    final trimmed = rawJson.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Isi file backup kosong.');
    }
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) {
      throw const FormatException('Format JSON backup tidak valid.');
    }
    final map = Map<String, dynamic>.from(decoded);
    final hasAnyExpectedKey = map.containsKey('settings') ||
        map.containsKey('downloadedMarkers') ||
        map.containsKey('creatorProfiles') ||
        map.containsKey('history');
    if (!hasAnyExpectedKey) {
      throw const FormatException(
        'File JSON ini bukan backup pengaturan all_download.',
      );
    }

    final settingsMap = map['settings'] is Map
        ? Map<String, dynamic>.from(map['settings'] as Map)
        : <String, dynamic>{};
    final markers = (map['downloadedMarkers'] as List?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toSet() ??
        <String>{};
    final profiles = (map['creatorProfiles'] as List?)
            ?.whereType<Map>()
            .map((e) => CreatorProfileRecord.fromJson(Map<String, dynamic>.from(e)))
            .where((r) => r.profileUrl.isNotEmpty)
            .toList() ??
        <CreatorProfileRecord>[];
    final history = (map['history'] as List?)
            ?.whereType<Map>()
            .map((e) {
              final it = DownloadItem.fromJson(Map<String, dynamic>.from(e));
              return it.isActive
                  ? it.copyWith(
                      status: DownloadStatus.paused,
                      statusText: 'Dijeda (hasil impor) — ketuk Lanjut',
                    )
                  : it;
            })
            .toList() ??
        <DownloadItem>[];

    return BackupDataBundle(
      settings: AppSettings.fromJson(settingsMap),
      downloadedMarkers: markers,
      creatorProfiles: profiles,
      history: history,
      exportedAt: DateTime.tryParse(map['exportedAt']?.toString() ?? ''),
    );
  }

  Future<String?> getCookiesFilePath(String cookiesContent) async {
    if (cookiesContent.trim().isEmpty) return null;
    final file = await _cookiesFile();
    if (!await file.exists()) {
      await file.writeAsString(cookiesContent.trim());
    }
    return file.path;
  }

  Future<void> syncCookiesFile(String cookiesContent) async {
    final file = await _cookiesFile();
    if (cookiesContent.trim().isEmpty) {
      if (await file.exists()) {
        await file.delete();
      }
    } else {
      await file.writeAsString(cookiesContent.trim());
    }
  }

  Future<File> _cookiesFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'user_cookies.txt'));
  }
}
