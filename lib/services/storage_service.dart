import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/creator_profile.dart';
import '../models/download_item.dart';
import '../models/managed_file.dart';
import '../models/media_metadata.dart';

List<Map<String, dynamic>> _decodeJsonMapList(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const <Map<String, dynamic>>[];
  final out = <Map<String, dynamic>>[];
  for (final entry in decoded) {
    if (entry is Map) {
      out.add(Map<String, dynamic>.from(entry));
    }
  }
  return out;
}

String _encodeJsonPayload(Object payload) => jsonEncode(payload);

/// Top-level isolate helpers so closures NEVER capture `StorageService` `this`.
Future<List<Map<String, dynamic>>> _decodeJsonMapListInIsolate(
  String raw,
) async {
  if (raw.length <= 65536) return _decodeJsonMapList(raw);
  try {
    return await Isolate.run(() => _decodeJsonMapList(raw));
  } catch (_) {
    return _decodeJsonMapList(raw);
  }
}

Future<String> _encodeJsonPayloadInIsolate(
  Object payload, {
  required bool useIsolate,
}) async {
  if (!useIsolate) return _encodeJsonPayload(payload);
  try {
    return await Isolate.run(() => _encodeJsonPayload(payload));
  } catch (_) {
    return _encodeJsonPayload(payload);
  }
}

class BackupDataBundle {
  final AppSettings settings;
  final Set<String> downloadedMarkers;
  final List<CreatorProfileRecord> creatorProfiles;
  final List<DownloadItem> history;
  final Map<String, AlbumMetadata> albumMetadata;
  final Map<String, ContentRating> photoRatings;
  final Map<String, CuratedWorkRecord> curatedCatalog;
  final DateTime? exportedAt;

  const BackupDataBundle({
    required this.settings,
    required this.downloadedMarkers,
    required this.creatorProfiles,
    required this.history,
    this.albumMetadata = const {},
    this.photoRatings = const {},
    this.curatedCatalog = const {},
    this.exportedAt,
  });
}

class PersistentStateSnapshot {
  final AppSettings? settings;
  final Set<String>? downloadedMarkers;
  final List<CreatorProfileRecord> creatorProfiles;
  final Map<String, AlbumMetadata> albumMetadata;
  final Map<String, ContentRating> photoRatings;
  final Map<String, CuratedWorkRecord> curatedCatalog;
  final List<DownloadItem> history;

  const PersistentStateSnapshot({
    this.settings,
    this.downloadedMarkers,
    this.creatorProfiles = const [],
    this.albumMetadata = const {},
    this.photoRatings = const {},
    this.curatedCatalog = const {},
    this.history = const [],
  });

  bool get hasAnyData =>
      settings != null ||
      (downloadedMarkers != null && downloadedMarkers!.isNotEmpty) ||
      creatorProfiles.isNotEmpty ||
      albumMetadata.isNotEmpty ||
      photoRatings.isNotEmpty ||
      curatedCatalog.isNotEmpty ||
      history.isNotEmpty;
}

class StorageService {
  static const String _historyKey = 'linkdrop_download_history_v1';
  static const String _settingsKey = 'linkdrop_settings_v1';
  static const String _downloadedMarkersKey = 'all_download_markers_v1';
  static const String _creatorProfilesKey = 'all_download_creator_profiles_v1';
  static const String _albumMetadataKey = 'all_download_album_metadata_v1';
  static const String _photoRatingsKey = 'all_download_photo_ratings_v1';
  static const String _curatedCatalogKey = 'all_download_curated_catalog_v1';

  /// Uninstall-proof shared state directory (`Documents/.all_download_vault/state`)
  /// provided by native Android once All Files Access is granted.
  String? _persistentStateDirPath;

  String? get persistentStateDirPath => _persistentStateDirPath;

  void setPersistentStateDir(String? dirPath) {
    final clean = dirPath?.trim();
    _persistentStateDirPath =
        (clean != null && clean.isNotEmpty) ? clean : null;
  }

  // Serialized coalescing writers prevent concurrent multi-MB JSON spikes in RAM.
  bool _isWritingHistory = false;
  List<DownloadItem>? _pendingHistoryWrite;
  bool _isWritingMarkers = false;
  Set<String>? _pendingMarkersWrite;
  bool _isWritingAlbumMeta = false;
  Map<String, AlbumMetadata>? _pendingAlbumMetaWrite;
  bool _isWritingRatings = false;
  Map<String, ContentRating>? _pendingRatingsWrite;
  bool _isWritingCurated = false;
  Map<String, CuratedWorkRecord>? _pendingCuratedWrite;
  bool _isWritingFileIndex = false;
  String? _pendingFileIndexWrite;

  File? _persistentFileOrNull(String fileName) {
    final dir = _persistentStateDirPath;
    if (dir == null || dir.isEmpty) return null;
    return File(p.join(dir, fileName));
  }

  Future<void> _mirrorToPersistentFile(String fileName, String content) async {
    final target = _persistentFileOrNull(fileName);
    if (target == null) return;
    try {
      final parent = target.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      await _writeAtomicFile(target, content);
    } catch (_) {}
  }

  Future<String?> _readPersistentText(String fileName) async {
    final target = _persistentFileOrNull(fileName);
    if (target == null) return null;
    try {
      if (await target.exists()) {
        final raw = await target.readAsString();
        if (raw.isNotEmpty) return raw;
      }
    } catch (_) {}
    return null;
  }

  Future<bool> hasLocalSavedSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_settingsKey);
      return raw != null && raw.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Reads all uninstall-proof state files directly from [_persistentStateDirPath]
  /// (used on reinstall / first activation of All Files Access to auto-restore
  /// settings, markers, artist links, album tags, photo ratings, and history).
  Future<PersistentStateSnapshot?> loadPersistentSnapshot() async {
    if (_persistentStateDirPath == null) return null;

    AppSettings? settings;
    final settingsRaw = await _readPersistentText('settings_v1.json');
    if (settingsRaw != null) {
      try {
        final decoded = jsonDecode(settingsRaw);
        if (decoded is Map) {
          settings = AppSettings.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }

    Set<String>? markers;
    final markersRaw = await _readPersistentText('downloaded_markers_v2.json');
    if (markersRaw != null) {
      try {
        final decoded = jsonDecode(markersRaw);
        if (decoded is List) {
          markers = decoded
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toSet();
        }
      } catch (_) {}
    }

    var profiles = <CreatorProfileRecord>[];
    final profilesRaw = await _readPersistentText('creator_profiles_v1.json');
    if (profilesRaw != null) {
      try {
        final decoded = jsonDecode(profilesRaw);
        if (decoded is List) {
          profiles = decoded
              .whereType<Map>()
              .map(
                (e) => CreatorProfileRecord.fromJson(
                  Map<String, dynamic>.from(e),
                ),
              )
              .where((r) => r.profileUrl.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }

    var albumMeta = <String, AlbumMetadata>{};
    final albumRaw = await _readPersistentText('album_metadata_v1.json');
    if (albumRaw != null) {
      try {
        albumMeta = _parseAlbumMetadataRaw(albumRaw);
      } catch (_) {}
    }

    var ratings = <String, ContentRating>{};
    final ratingsRaw = await _readPersistentText('photo_ratings_v1.json');
    if (ratingsRaw != null) {
      try {
        ratings = _parsePhotoRatingsRaw(ratingsRaw);
      } catch (_) {}
    }

    var curated = <String, CuratedWorkRecord>{};
    final curatedRaw = await _readPersistentText('curated_catalog_v1.json');
    if (curatedRaw != null) {
      try {
        curated = await _parseCuratedCatalogRaw(curatedRaw);
      } catch (_) {}
    }

    var history = <DownloadItem>[];
    final historyRaw = await _readPersistentText('download_history_v2.json');
    if (historyRaw != null) {
      try {
        history = await _parseHistoryRaw(historyRaw);
      } catch (_) {}
    }

    final snap = PersistentStateSnapshot(
      settings: settings,
      downloadedMarkers: markers,
      creatorProfiles: profiles,
      albumMetadata: albumMeta,
      photoRatings: ratings,
      curatedCatalog: curated,
      history: history,
    );
    return snap.hasAnyData ? snap : null;
  }

  Future<File?> _supportFileOrNull(String fileName) async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File(p.join(dir.path, fileName));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAtomicFile(File target, String content) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (await target.exists()) {
      await target.delete().catchError((_) => target);
    }
    await tmp.rename(target.path);
  }

  Future<List<DownloadItem>> _parseHistoryRaw(String raw) async {
    final maps = await _decodeJsonMapListInIsolate(raw);
    return maps.map((m) {
      final item = DownloadItem.fromJson(m);
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
      if (item.status == DownloadStatus.completed &&
          item.resumePayload != null) {
        return item.copyWith(clearResumePayload: true);
      }
      return item;
    }).toList();
  }

  Future<List<DownloadItem>> loadHistory() async {
    // 1) Primary crash-proof local file storage (no Android 1MB Binder limit!)
    final file = await _supportFileOrNull('download_history_v2.json');
    if (file != null && await file.exists()) {
      try {
        final raw = await file.readAsString();
        if (raw.isNotEmpty) {
          return await _parseHistoryRaw(raw);
        }
      } catch (_) {}
    }

    // 2) One-time migration from legacy SharedPreferences storage
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyKey);
      if (raw != null && raw.isNotEmpty) {
        final parsed = await _parseHistoryRaw(raw);
        if (file != null) {
          try {
            await saveHistory(parsed);
            await prefs.remove(_historyKey);
          } catch (_) {}
        }
        return parsed;
      }
    } catch (_) {}

    // 3) Uninstall-proof persistent vault fallback
    final persistentRaw = await _readPersistentText('download_history_v2.json');
    if (persistentRaw != null) {
      try {
        return await _parseHistoryRaw(persistentRaw);
      } catch (_) {}
    }
    return [];
  }

  /// Saves ALL items including paused & active checkpoints using serialized,
  /// off-thread JSON encoding into an atomic local file (never hits Android
  /// SharedPreferences Binder limits even with thousands of history entries).
  Future<void> saveHistory(List<DownloadItem> items) async {
    _pendingHistoryWrite = List<DownloadItem>.unmodifiable(items);
    if (_isWritingHistory) return;

    _isWritingHistory = true;
    try {
      while (_pendingHistoryWrite != null) {
        final batch = _pendingHistoryWrite!;
        _pendingHistoryWrite = null;
        await _persistHistoryBatch(batch);
      }
    } finally {
      _isWritingHistory = false;
    }
  }

  Future<void> _persistHistoryBatch(List<DownloadItem> items) async {
    final toSave = items.map((e) => e.toJson()).toList(growable: false);
    final encoded = await _encodeJsonPayloadInIsolate(
      toSave,
      useIsolate: items.length >= 60,
    );

    final file = await _supportFileOrNull('download_history_v2.json');
    if (file != null) {
      await _writeAtomicFile(file, encoded);
      await _mirrorToPersistentFile('download_history_v2.json', encoded);
      return;
    }

    await _mirrorToPersistentFile('download_history_v2.json', encoded);
    // Fallback when running in headless unit tests without path_provider
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, encoded);
  }

  /// Returns null when markers have never been saved yet (first run / upgrade).
  Future<Set<String>?> loadDownloadedMarkers() async {
    final file = await _supportFileOrNull('downloaded_markers_v2.json');
    if (file != null && await file.exists()) {
      try {
        final raw = await file.readAsString();
        if (raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            return decoded
                .map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toSet();
          }
        }
      } catch (_) {}
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_downloadedMarkersKey)) {
        final list = prefs.getStringList(_downloadedMarkersKey);
        if (list == null) return <String>{};
        final set = list.where((e) => e.isNotEmpty).toSet();
        if (file != null) {
          try {
            await saveDownloadedMarkers(set);
            await prefs.remove(_downloadedMarkersKey);
          } catch (_) {}
        }
        return set;
      }
    } catch (_) {}

    final persistentRaw =
        await _readPersistentText('downloaded_markers_v2.json');
    if (persistentRaw != null) {
      try {
        final decoded = jsonDecode(persistentRaw);
        if (decoded is List) {
          return decoded
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toSet();
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> saveDownloadedMarkers(Set<String> markers) async {
    _pendingMarkersWrite = Set<String>.unmodifiable(markers);
    if (_isWritingMarkers) return;

    _isWritingMarkers = true;
    try {
      while (_pendingMarkersWrite != null) {
        final batch = _pendingMarkersWrite!;
        _pendingMarkersWrite = null;
        final list = batch.toList(growable: false);
        final encoded = await _encodeJsonPayloadInIsolate(
          list,
          useIsolate: list.length >= 500,
        );
        final file = await _supportFileOrNull('downloaded_markers_v2.json');
        if (file != null) {
          await _writeAtomicFile(file, encoded);
        } else {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(_downloadedMarkersKey, list);
        }
        await _mirrorToPersistentFile('downloaded_markers_v2.json', encoded);
      }
    } finally {
      _isWritingMarkers = false;
    }
  }

  Future<List<CreatorProfileRecord>> loadCreatorProfiles() async {
    String? raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      raw = prefs.getString(_creatorProfilesKey);
    } catch (_) {}
    if (raw == null || raw.isEmpty) {
      raw = await _readPersistentText('creator_profiles_v1.json');
    }
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
    final encoded =
        jsonEncode(profiles.map((e) => e.toJson()).toList(growable: false));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_creatorProfilesKey, encoded);
    } catch (_) {}
    await _mirrorToPersistentFile('creator_profiles_v1.json', encoded);
  }

  Future<Map<String, AlbumMetadata>> loadAlbumMetadata() async {
    final file = await _supportFileOrNull('album_metadata_v1.json');
    if (file != null && await file.exists()) {
      try {
        final raw = await file.readAsString();
        if (raw.isNotEmpty) {
          return _parseAlbumMetadataRaw(raw);
        }
      } catch (_) {}
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_albumMetadataKey);
      if (raw != null && raw.isNotEmpty) {
        return _parseAlbumMetadataRaw(raw);
      }
    } catch (_) {}

    final persistentRaw = await _readPersistentText('album_metadata_v1.json');
    if (persistentRaw != null) {
      try {
        return _parseAlbumMetadataRaw(persistentRaw);
      } catch (_) {}
    }
    return {};
  }

  Map<String, AlbumMetadata> _parseAlbumMetadataRaw(String raw) {
    final decoded = jsonDecode(raw);
    final out = <String, AlbumMetadata>{};
    if (decoded is List) {
      for (final entry in decoded) {
        if (entry is Map) {
          final meta = AlbumMetadata.fromJson(Map<String, dynamic>.from(entry));
          if (meta.albumFolder.isNotEmpty && meta.tags.isNotEmpty) {
            out[meta.lookupKey] = meta;
          }
        }
      }
    } else if (decoded is Map) {
      decoded.forEach((_, value) {
        if (value is Map) {
          final meta = AlbumMetadata.fromJson(Map<String, dynamic>.from(value));
          if (meta.albumFolder.isNotEmpty && meta.tags.isNotEmpty) {
            out[meta.lookupKey] = meta;
          }
        }
      });
    }
    return out;
  }

  Future<void> saveAlbumMetadata(Map<String, AlbumMetadata> metadata) async {
    _pendingAlbumMetaWrite = Map<String, AlbumMetadata>.unmodifiable(metadata);
    if (_isWritingAlbumMeta) return;

    _isWritingAlbumMeta = true;
    try {
      while (_pendingAlbumMetaWrite != null) {
        final batch = _pendingAlbumMetaWrite!;
        _pendingAlbumMetaWrite = null;
        final list =
            batch.values.map((e) => e.toJson()).toList(growable: false);
        final encoded = await _encodeJsonPayloadInIsolate(
          list,
          useIsolate: list.length >= 150,
        );
        final file = await _supportFileOrNull('album_metadata_v1.json');
        if (file != null) {
          await _writeAtomicFile(file, encoded);
        } else {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_albumMetadataKey, encoded);
        }
        await _mirrorToPersistentFile('album_metadata_v1.json', encoded);
      }
    } finally {
      _isWritingAlbumMeta = false;
    }
  }

  Future<Map<String, ContentRating>> loadPhotoRatings() async {
    final file = await _supportFileOrNull('photo_ratings_v1.json');
    if (file != null && await file.exists()) {
      try {
        final raw = await file.readAsString();
        if (raw.isNotEmpty) {
          return _parsePhotoRatingsRaw(raw);
        }
      } catch (_) {}
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_photoRatingsKey);
      if (raw != null && raw.isNotEmpty) {
        return _parsePhotoRatingsRaw(raw);
      }
    } catch (_) {}

    final persistentRaw = await _readPersistentText('photo_ratings_v1.json');
    if (persistentRaw != null) {
      try {
        return _parsePhotoRatingsRaw(persistentRaw);
      } catch (_) {}
    }
    return {};
  }

  Map<String, ContentRating> _parsePhotoRatingsRaw(String raw) {
    final decoded = jsonDecode(raw);
    final out = <String, ContentRating>{};
    if (decoded is Map) {
      decoded.forEach((k, v) {
        final key = k.toString().trim();
        final rating = ContentRatingMeta.fromName(v?.toString());
        if (key.isNotEmpty && rating != ContentRating.normal) {
          out[key] = rating;
        }
      });
    }
    return out;
  }

  Future<void> savePhotoRatings(Map<String, ContentRating> ratings) async {
    _pendingRatingsWrite = Map<String, ContentRating>.unmodifiable(ratings);
    if (_isWritingRatings) return;

    _isWritingRatings = true;
    try {
      while (_pendingRatingsWrite != null) {
        final batch = _pendingRatingsWrite!;
        _pendingRatingsWrite = null;
        final serialized = <String, String>{};
        batch.forEach((k, v) {
          if (k.isNotEmpty && v != ContentRating.normal) {
            serialized[k] = v.name;
          }
        });
        final encoded = await _encodeJsonPayloadInIsolate(
          serialized,
          useIsolate: serialized.length >= 300,
        );
        final file = await _supportFileOrNull('photo_ratings_v1.json');
        if (file != null) {
          await _writeAtomicFile(file, encoded);
        } else {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_photoRatingsKey, encoded);
        }
        await _mirrorToPersistentFile('photo_ratings_v1.json', encoded);
      }
    } finally {
      _isWritingRatings = false;
    }
  }

  // ===========================================================================
  // MANAGED FILES PACKED INDEX CACHE (INSTANT COLD START FOR 30,000+ FILES)
  // ===========================================================================
  Future<List<ManagedFile>> loadManagedFilesCache() async {
    final file = await _supportFileOrNull('managed_files_index_v1.tsv');
    if (file == null || !await file.exists()) return const <ManagedFile>[];
    try {
      final raw = await file.readAsString();
      if (raw.isEmpty) return const <ManagedFile>[];
      return await parsePackedManagedFilesInIsolate(raw);
    } catch (_) {
      return const <ManagedFile>[];
    }
  }

  Future<void> saveManagedFilesCacheRaw(String packedTsv) async {
    _pendingFileIndexWrite = packedTsv;
    if (_isWritingFileIndex) return;
    _isWritingFileIndex = true;
    try {
      while (_pendingFileIndexWrite != null) {
        final payload = _pendingFileIndexWrite!;
        _pendingFileIndexWrite = null;
        final file = await _supportFileOrNull('managed_files_index_v1.tsv');
        if (file != null) {
          await _writeAtomicFile(file, payload);
        }
      }
    } catch (_) {
    } finally {
      _isWritingFileIndex = false;
    }
  }

  Future<void> saveManagedFilesCache(List<ManagedFile> files) async {
    try {
      final packed = await encodePackedManagedFilesInIsolate(files);
      await saveManagedFilesCacheRaw(packed);
    } catch (_) {}
  }

  // ===========================================================================
  // CURATED KEEP-ONLY CATALOG (RECORD ONLY KEPT PHOTOS/PAGES)
  // ===========================================================================
  Future<Map<String, CuratedWorkRecord>> loadCuratedCatalog() async {
    final file = await _supportFileOrNull('curated_catalog_v1.json');
    if (file != null && await file.exists()) {
      try {
        final raw = await file.readAsString();
        if (raw.isNotEmpty) {
          return await _parseCuratedCatalogRaw(raw);
        }
      } catch (_) {}
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_curatedCatalogKey);
      if (raw != null && raw.isNotEmpty) {
        return await _parseCuratedCatalogRaw(raw);
      }
    } catch (_) {}

    final persistentRaw = await _readPersistentText('curated_catalog_v1.json');
    if (persistentRaw != null) {
      try {
        return await _parseCuratedCatalogRaw(persistentRaw);
      } catch (_) {}
    }
    return {};
  }

  Future<Map<String, CuratedWorkRecord>> _parseCuratedCatalogRaw(
    String raw,
  ) async {
    final maps = await _decodeJsonMapListInIsolate(raw);
    final out = <String, CuratedWorkRecord>{};
    for (final m in maps) {
      final rec = CuratedWorkRecord.fromJson(m);
      if (rec.markerKey.isNotEmpty && rec.keptFiles.isNotEmpty) {
        out[rec.markerKey] = rec;
      }
    }
    return out;
  }

  Future<void> saveCuratedCatalog(
    Map<String, CuratedWorkRecord> catalog,
  ) async {
    _pendingCuratedWrite = Map<String, CuratedWorkRecord>.unmodifiable(catalog);
    if (_isWritingCurated) return;

    _isWritingCurated = true;
    try {
      while (_pendingCuratedWrite != null) {
        final batch = _pendingCuratedWrite!;
        _pendingCuratedWrite = null;
        final list = batch.values
            .where((r) => r.markerKey.isNotEmpty && r.keptFiles.isNotEmpty)
            .map((e) => e.toJson())
            .toList(growable: false);
        final encoded = await _encodeJsonPayloadInIsolate(
          list,
          useIsolate: list.length >= 120,
        );
        final file = await _supportFileOrNull('curated_catalog_v1.json');
        if (file != null) {
          await _writeAtomicFile(file, encoded);
        } else {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_curatedCatalogKey, encoded);
        }
        await _mirrorToPersistentFile('curated_catalog_v1.json', encoded);
      }
    } finally {
      _isWritingCurated = false;
    }
  }

  Future<AppSettings> loadSettings() async {
    String? raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      raw = prefs.getString(_settingsKey);
    } catch (_) {}
    if (raw == null || raw.isEmpty) {
      raw = await _readPersistentText('settings_v1.json');
    }
    if (raw == null || raw.isEmpty) return const AppSettings();
    try {
      final map = jsonDecode(raw) as Map;
      return AppSettings.fromJson(Map<String, dynamic>.from(map));
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings settings) async {
    final encoded = jsonEncode(settings.toJson());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_settingsKey, encoded);
    } catch (_) {}
    await _mirrorToPersistentFile('settings_v1.json', encoded);
    await syncCookiesFile(settings.customCookies);
  }

  /// Builds a portable JSON backup containing settings, downloaded markers,
  /// saved per-artist profile URLs, album tags, photo ratings, curated keep-only
  /// catalog, and download history.
  String buildBackupJson({
    required AppSettings settings,
    required Set<String> downloadedMarkers,
    required List<CreatorProfileRecord> creatorProfiles,
    required List<DownloadItem> history,
    Map<String, AlbumMetadata> albumMetadata = const {},
    Map<String, ContentRating> photoRatings = const {},
    Map<String, CuratedWorkRecord> curatedCatalog = const {},
  }) {
    final serializedRatings = <String, String>{};
    photoRatings.forEach((k, v) {
      if (k.isNotEmpty && v != ContentRating.normal) {
        serializedRatings[k] = v.name;
      }
    });
    final serializedCurated = curatedCatalog.values
        .where((r) => r.markerKey.isNotEmpty && r.keptFiles.isNotEmpty)
        .map((e) => e.toJson())
        .toList(growable: false);
    final payload = {
      'app': 'all_download',
      'schemaVersion': 4,
      'exportedAt': DateTime.now().toIso8601String(),
      'settings': settings.toJson(),
      'downloadedMarkers': downloadedMarkers.toList(growable: false),
      'creatorProfiles': creatorProfiles.map((e) => e.toJson()).toList(growable: false),
      'albumMetadata': albumMetadata.values.map((e) => e.toJson()).toList(growable: false),
      'photoRatings': serializedRatings,
      'curatedCatalog': serializedCurated,
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
        map.containsKey('albumMetadata') ||
        map.containsKey('photoRatings') ||
        map.containsKey('curatedCatalog') ||
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
    final albumMeta = <String, AlbumMetadata>{};
    if (map['albumMetadata'] is List) {
      for (final entry in map['albumMetadata'] as List) {
        if (entry is Map) {
          final meta = AlbumMetadata.fromJson(Map<String, dynamic>.from(entry));
          if (meta.albumFolder.isNotEmpty && meta.tags.isNotEmpty) {
            albumMeta[meta.lookupKey] = meta;
          }
        }
      }
    }
    final ratings = <String, ContentRating>{};
    if (map['photoRatings'] is Map) {
      (map['photoRatings'] as Map).forEach((k, v) {
        final key = k.toString().trim();
        final rating = ContentRatingMeta.fromName(v?.toString());
        if (key.isNotEmpty && rating != ContentRating.normal) {
          ratings[key] = rating;
        }
      });
    }
    final curated = <String, CuratedWorkRecord>{};
    if (map['curatedCatalog'] is List) {
      for (final entry in map['curatedCatalog'] as List) {
        if (entry is Map) {
          final rec =
              CuratedWorkRecord.fromJson(Map<String, dynamic>.from(entry));
          if (rec.markerKey.isNotEmpty && rec.keptFiles.isNotEmpty) {
            curated[rec.markerKey] = rec;
          }
        }
      }
    }
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
      albumMetadata: albumMeta,
      photoRatings: ratings,
      curatedCatalog: curated,
      exportedAt: DateTime.tryParse(map['exportedAt']?.toString() ?? ''),
    );
  }

  Future<String?> getCookiesFilePath(String cookiesContent) async {
    if (cookiesContent.trim().isEmpty) return null;
    final file = await _supportFileOrNull('user_cookies.txt');
    if (file == null) return null;
    if (!await file.exists()) {
      await file.writeAsString(cookiesContent.trim());
    }
    return file.path;
  }

  Future<void> syncCookiesFile(String cookiesContent) async {
    final file = await _supportFileOrNull('user_cookies.txt');
    if (file == null) return;
    if (cookiesContent.trim().isEmpty) {
      if (await file.exists()) {
        await file.delete();
      }
    } else {
      await file.writeAsString(cookiesContent.trim());
    }
  }
}
