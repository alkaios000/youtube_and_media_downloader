import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/download_item.dart';

class StorageService {
  static const String _historyKey = 'linkdrop_download_history_v1';
  static const String _settingsKey = 'linkdrop_settings_v1';

  Future<List<DownloadItem>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => DownloadItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHistory(List<DownloadItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    // Only persist terminal states (completed/failed/cancelled), cap at 200 items.
    final toSave = items
        .where((item) => !item.isActive)
        .take(200)
        .map((e) => e.toJson())
        .toList();
    await prefs.setString(_historyKey, jsonEncode(toSave));
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
