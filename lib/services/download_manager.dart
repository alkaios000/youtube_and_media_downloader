import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/creator_profile.dart';
import '../models/download_item.dart';
import '../models/managed_file.dart';
import '../models/media_info.dart';
import '../models/media_platform.dart';
import 'direct_extractors.dart';
import 'media_extractor_service.dart';
import 'native_bridge.dart';
import 'storage_service.dart';

/// Lightweight async semaphore to load-balance concurrent network & CPU-heavy downloads.
class _AsyncSemaphore {
  final int maxConcurrent;
  int _current = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  _AsyncSemaphore(this.maxConcurrent);

  Future<void> acquire() {
    if (_current < maxConcurrent) {
      _current++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.addLast(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      if (!next.isCompleted) {
        next.complete();
      }
    } else if (_current > 0) {
      _current--;
    }
  }

  Future<T> run<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }
}

class DownloadManager extends ChangeNotifier {
  static const int _directFileMaxConcurrency = 5;
  static const int _ytDlpMaxConcurrency = 1;
  static const int _bulkDirectTaskConcurrency = 4;

  final NativeBridge _bridge;
  final StorageService _storage;
  final MediaExtractorService _extractor;
  final Dio _dio;

  /// Separate notifier for theme so MaterialApp NEVER rebuilds during downloads.
  final ValueNotifier<ThemeMode> themeNotifier =
      ValueNotifier<ThemeMode>(ThemeMode.dark);

  final _AsyncSemaphore _directFilePool =
      _AsyncSemaphore(_directFileMaxConcurrency);
  final _AsyncSemaphore _ytDlpPool = _AsyncSemaphore(_ytDlpMaxConcurrency);

  EngineStatus _engineStatus = EngineStatus.initial();
  PermissionStatusInfo _permissionStatus = PermissionStatusInfo.unknown();
  AppSettings _settings = const AppSettings();
  List<DownloadItem> _items = [];
  final Map<String, int> _itemIndexById = <String, int>{};
  int _itemsRevision = 0;
  int _activeDownloadCount = 0;
  int _pausedDownloadCount = 0;
  List<ManagedFile> _managedFiles = const [];
  Set<String> _downloadedMarkers = <String>{};
  final Map<String, CreatorProfileRecord> _creatorProfiles = {};
  final Map<String, List<String>> _pixivPagesCache = {};

  bool _isInitializing = true;
  bool _isAnalyzing = false;
  bool _isUpdatingEngine = false;
  bool _isLoadingFiles = false;
  bool _permissionChecked = false;
  bool _instagramLoggedIn = false;
  bool _douyinLoggedIn = false;
  bool _facebookLoggedIn = false;
  bool _pixivLoggedIn = false;
  bool _tiktokLoggedIn = false;
  bool _isDisposed = false;
  String? _engineError;
  String? _analyzeError;
  MediaInfo? _currentPreview;
  int _cacheBytes = 0;

  final Map<String, CancelToken> _directCancelTokens = {};
  final Set<String> _cancelledTaskIds = {};
  final Set<String> _pausedTaskIds = {};
  StreamSubscription<NativeProgressEvent>? _progressSub;
  StreamSubscription<String>? _shareSub;
  Timer? _throttleNotifyTimer;
  bool _hasPendingNotify = false;
  Timer? _postSyncTimer;
  Timer? _markersFlushTimer;
  DateTime _lastHistoryFlush = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastManagedFilesRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  int _taskSeq = 0;

  void Function(String sharedText)? _onIncomingSharedLink;
  String? _pendingSharedText;

  void Function(String sharedText)? get onIncomingSharedLink =>
      _onIncomingSharedLink;
  set onIncomingSharedLink(void Function(String sharedText)? handler) {
    _onIncomingSharedLink = handler;
    if (handler != null && _pendingSharedText != null) {
      final pending = _pendingSharedText!;
      _pendingSharedText = null;
      Future<void>.microtask(() {
        if (!_isDisposed && _onIncomingSharedLink == handler) {
          handler(pending);
        }
      });
    }
  }

  void _dispatchIncomingSharedLink(String rawText) {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) return;
    final handler = _onIncomingSharedLink;
    if (handler != null) {
      handler(trimmed);
    } else {
      _pendingSharedText = trimmed;
    }
  }

  DownloadManager({
    NativeBridge? bridge,
    StorageService? storage,
    Dio? dio,
  })  : _bridge = bridge ?? NativeBridge(),
        _storage = storage ?? StorageService(),
        _dio = dio ?? _createOptimizedDio(),
        _extractor = MediaExtractorService(
          bridge: bridge ?? NativeBridge(),
        );

  static Dio _createOptimizedDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 10),
        persistentConnection: true,
      ),
    );
    final adapter = dio.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      adapter.createHttpClient = () {
        final client = HttpClient();
        client.maxConnectionsPerHost = 8;
        client.idleTimeout = const Duration(seconds: 30);
        // Binary media streams (JPEG/PNG/MP4/MP3) are already compressed.
        client.autoUncompress = false;
        return client;
      };
    }
    return dio;
  }

  EngineStatus get engineStatus => _engineStatus;
  PermissionStatusInfo get permissionStatus => _permissionStatus;
  bool get permissionChecked => _permissionChecked;
  AppSettings get settings => _settings;
  List<DownloadItem> get items => List.unmodifiable(_items);
  int get itemsRevision => _itemsRevision;
  int get activeDownloadCount => _activeDownloadCount;
  int get pausedDownloadCount => _pausedDownloadCount;
  List<ManagedFile> get managedFiles => _managedFiles;
  Set<String> get downloadedMarkers => Set.unmodifiable(_downloadedMarkers);
  List<CreatorProfileRecord> get creatorProfiles =>
      List.unmodifiable(_creatorProfiles.values);
  List<DownloadItem> get activeDownloads =>
      _items.where((i) => i.isActive).toList(growable: false);
  List<DownloadItem> get pausedDownloads =>
      _items.where((i) => i.isPaused).toList(growable: false);
  List<DownloadItem> get historyItems =>
      _items.where((i) => !i.isActive).toList(growable: false);
  bool get isInitializing => _isInitializing;
  bool get isAnalyzing => _isAnalyzing;
  bool get isUpdatingEngine => _isUpdatingEngine;
  bool get isLoadingFiles => _isLoadingFiles;
  bool get instagramLoggedIn => _instagramLoggedIn;
  bool get douyinLoggedIn => _douyinLoggedIn;
  bool get facebookLoggedIn => _facebookLoggedIn;
  bool get pixivLoggedIn => _pixivLoggedIn;
  bool get tiktokLoggedIn => _tiktokLoggedIn;
  String? get engineError => _engineError;
  String? get analyzeError => _analyzeError;
  MediaInfo? get currentPreview => _currentPreview;
  int get cacheBytes => _cacheBytes;

  DownloadItem? findItemById(String id) {
    final idx = _itemIndexById[id];
    if (idx != null && idx >= 0 && idx < _items.length && _items[idx].id == id) {
      return _items[idx];
    }
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _setItems(List<DownloadItem> next) {
    _items = next;
    _itemIndexById.clear();
    var active = 0;
    var paused = 0;
    for (int i = 0; i < _items.length; i++) {
      final it = _items[i];
      _itemIndexById[it.id] = i;
      if (it.isActive) {
        active++;
      } else if (it.isPaused) {
        paused++;
      }
    }
    _activeDownloadCount = active;
    _pausedDownloadCount = paused;
    _itemsRevision++;
  }

  // ===========================================================================
  // PER-ARTIST SAVED PROFILE LINKS ("Lanjut Unduh")
  // ===========================================================================
  CreatorProfileRecord? getCreatorProfile(
    String platformFolder,
    String creatorFolder,
  ) {
    final key = CreatorProfileRecord.buildLookupKey(platformFolder, creatorFolder);
    return _creatorProfiles[key];
  }

  Future<void> saveCreatorProfile({
    required MediaPlatform platform,
    required String creatorFolder,
    required String profileUrl,
    String? displayName,
  }) async {
    final cleanUrl = UrlParser.extractUrl(profileUrl) ?? profileUrl.trim();
    if (cleanUrl.isEmpty || creatorFolder.trim().isEmpty) return;
    final record = CreatorProfileRecord(
      platform: platform,
      creatorFolder: creatorFolder.trim(),
      displayName: (displayName?.trim().isNotEmpty ?? false)
          ? displayName!.trim()
          : creatorFolder.trim(),
      profileUrl: cleanUrl,
      lastSyncedAt: DateTime.now(),
    );
    _creatorProfiles[record.lookupKey] = record;
    _notifyImmediate();
    try {
      await _storage.saveCreatorProfiles(_creatorProfiles.values.toList());
    } catch (_) {}
  }

  Future<void> removeCreatorProfile(
    String platformFolder,
    String creatorFolder,
  ) async {
    final key = CreatorProfileRecord.buildLookupKey(platformFolder, creatorFolder);
    if (_creatorProfiles.remove(key) == null) return;
    _notifyImmediate();
    try {
      await _storage.saveCreatorProfiles(_creatorProfiles.values.toList());
    } catch (_) {}
  }

  void _autoRememberCreatorProfile(MediaInfo info) {
    final candidateUrl = info.creatorProfileUrl?.trim().isNotEmpty == true
        ? info.creatorProfileUrl!.trim()
        : (info.isBulkProfile ? info.originalUrl.trim() : '');
    if (candidateUrl.isEmpty || !candidateUrl.startsWith('http')) return;
    final author = info.author.trim();
    if (author.isEmpty ||
        author.toLowerCase() == info.platform.label.toLowerCase() ||
        author.toLowerCase() == 'umum') {
      return;
    }
    unawaited(
      saveCreatorProfile(
        platform: info.platform,
        creatorFolder: author,
        profileUrl: candidateUrl,
        displayName: author,
      ),
    );
  }

  // ===========================================================================
  // DOWNLOADED MARKERS (ALL PLATFORMS)
  // ===========================================================================
  bool isMarkedDownloaded(String markerKey) {
    return markerKey.isNotEmpty && _downloadedMarkers.contains(markerKey);
  }

  Future<void> markDownloaded(String markerKey) async {
    final key = markerKey.trim();
    if (key.isEmpty || _downloadedMarkers.contains(key)) return;
    _downloadedMarkers = {..._downloadedMarkers, key};
    _notifyImmediate();
    try {
      await _storage.saveDownloadedMarkers(_downloadedMarkers);
    } catch (_) {}
  }

  Future<void> markManyDownloaded(Iterable<String> keys) async {
    final cleaned = keys.map((k) => k.trim()).where((k) => k.isNotEmpty);
    final next = {..._downloadedMarkers, ...cleaned};
    if (next.length == _downloadedMarkers.length) return;
    _downloadedMarkers = next;
    // Coalesce UI & disk writes during active bulk downloads so finishing
    // hundreds of items rapidly never freezes the UI or hammers storage.
    if (_activeDownloadCount > 0 && _items.length >= 40) {
      _notifyThrottled();
      _scheduleMarkersFlush();
      return;
    }
    _notifyImmediate();
    try {
      await _storage.saveDownloadedMarkers(_downloadedMarkers);
    } catch (_) {}
  }

  void _scheduleMarkersFlush() {
    if (_isDisposed) return;
    if (_markersFlushTimer?.isActive ?? false) return;
    _markersFlushTimer = Timer(const Duration(milliseconds: 1200), () {
      _markersFlushTimer = null;
      if (_isDisposed) return;
      unawaited(_storage.saveDownloadedMarkers(_downloadedMarkers));
    });
  }

  Future<void> unmarkDownloaded(String markerKey) async {
    final key = markerKey.trim();
    if (key.isEmpty || !_downloadedMarkers.contains(key)) return;
    final next = Set<String>.from(_downloadedMarkers)..remove(key);
    _downloadedMarkers = next;
    _notifyImmediate();
    try {
      await _storage.saveDownloadedMarkers(_downloadedMarkers);
    } catch (_) {}
  }

  Future<void> unmarkMany(Iterable<String> keys) async {
    final toRemove =
        keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toSet();
    if (toRemove.isEmpty) return;
    final next = Set<String>.from(_downloadedMarkers)..removeAll(toRemove);
    if (next.length == _downloadedMarkers.length) return;
    _downloadedMarkers = next;
    _notifyImmediate();
    try {
      await _storage.saveDownloadedMarkers(_downloadedMarkers);
    } catch (_) {}
  }

  Future<void> clearAllDownloadedMarkers() async {
    if (_downloadedMarkers.isEmpty) return;
    _downloadedMarkers = <String>{};
    _notifyImmediate();
    try {
      await _storage.saveDownloadedMarkers(_downloadedMarkers);
    } catch (_) {}
  }

  // ===========================================================================
  // EXPORT / IMPORT BACKUP (SETTINGS + MARKERS + ARTIST PROFILES + HISTORY)
  // ===========================================================================
  String buildBackupJson() {
    return _storage.buildBackupJson(
      settings: _settings,
      downloadedMarkers: _downloadedMarkers,
      creatorProfiles: _creatorProfiles.values.toList(growable: false),
      history: _items,
    );
  }

  Future<bool> exportBackupToFile() async {
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final json = buildBackupJson();
    return _bridge.exportBackupFile(
      jsonContent: json,
      fileName: 'all_download_backup_$stamp.json',
    );
  }

  Future<BackupDataBundle?> pickAndParseBackupFile() async {
    final raw = await _bridge.importBackupFile();
    if (raw == null || raw.trim().isEmpty) return null;
    return _storage.parseBackupJson(raw);
  }

  BackupDataBundle parseBackupText(String rawJson) {
    return _storage.parseBackupJson(rawJson);
  }

  Future<void> applyBackup(
    BackupDataBundle bundle, {
    required bool merge,
  }) async {
    _settings = bundle.settings;
    themeNotifier.value = _settings.themeMode;

    if (merge) {
      _downloadedMarkers = {..._downloadedMarkers, ...bundle.downloadedMarkers};
      for (final rec in bundle.creatorProfiles) {
        _creatorProfiles.putIfAbsent(rec.lookupKey, () => rec);
      }
      final existingIds = _items.map((e) => e.id).toSet();
      final incoming = bundle.history
          .where((e) => !existingIds.contains(e.id))
          .toList(growable: false);
      _setItems([..._items, ...incoming]);
    } else {
      _downloadedMarkers = Set<String>.from(bundle.downloadedMarkers);
      _creatorProfiles
        ..clear()
        ..addEntries(
          bundle.creatorProfiles.map((r) => MapEntry(r.lookupKey, r)),
        );
      final activeNow = _items.where((i) => i.isActive).toList(growable: false);
      _setItems([...activeNow, ...bundle.history]);
    }

    _notifyImmediate();

    await Future.wait([
      _storage.saveSettings(_settings),
      _storage.saveDownloadedMarkers(_downloadedMarkers),
      _storage.saveCreatorProfiles(_creatorProfiles.values.toList()),
      _storage.saveHistory(_items),
    ]);
  }

  // ===========================================================================
  // BOOTSTRAP (NON-BLOCKING INSTANT SHARE & STARTUP)
  // ===========================================================================
  Future<void> bootstrap() async {
    try {
      _progressSub = _bridge.progressStream.listen(
        _handleNativeProgress,
        onError: (_) {},
      );
      _shareSub = _bridge.shareStream.listen(
        _dispatchIncomingSharedLink,
        onError: (_) {},
      );
    } catch (_) {}

    unawaited(_checkInitialSharedLink());

    final localData = await Future.wait<dynamic>([
      _storage.loadSettings().catchError((_) => const AppSettings()),
      _storage.loadHistory().catchError((_) => <DownloadItem>[]),
      _storage.loadDownloadedMarkers().catchError((_) => null),
      _storage
          .loadCreatorProfiles()
          .catchError((_) => <CreatorProfileRecord>[]),
    ]);

    _settings = localData[0] as AppSettings;
    themeNotifier.value = _settings.themeMode;
    _setItems(localData[1] as List<DownloadItem>);

    final savedMarkers = localData[2] as Set<String>?;
    if (savedMarkers != null) {
      _downloadedMarkers = savedMarkers;
    } else {
      final seeded = <String>{};
      for (final it in _items) {
        if (it.status == DownloadStatus.completed) {
          final key = it.markerKey.isNotEmpty
              ? it.markerKey
              : canonicalMarkerKey(it.sourceUrl);
          if (key.isNotEmpty) seeded.add(key);
        }
      }
      _downloadedMarkers = seeded;
      unawaited(_storage.saveDownloadedMarkers(_downloadedMarkers));
    }

    final loadedProfiles = localData[3] as List<CreatorProfileRecord>;
    _creatorProfiles
      ..clear()
      ..addEntries(loadedProfiles.map((r) => MapEntry(r.lookupKey, r)));

    _notifyImmediate();

    await refreshPermissions();

    unawaited(_initEngineInBackground());
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (_isDisposed) return;
        unawaited(refreshManagedFiles());
        unawaited(refreshBrowserSessions());
      }),
    );
  }

  Future<void> _checkInitialSharedLink() async {
    try {
      final initialShared = await _bridge.getInitialSharedText();
      if (initialShared != null && initialShared.trim().isNotEmpty) {
        _dispatchIncomingSharedLink(initialShared);
      }
    } catch (_) {}
  }

  Future<void> _initEngineInBackground() async {
    try {
      _engineStatus = await _bridge.initEngine();
      _engineError = null;
      unawaited(refreshStorageInfo());
    } catch (e) {
      _engineError = e.toString();
    } finally {
      _isInitializing = false;
      _notifyImmediate();
    }
  }

  Future<PermissionStatusInfo> refreshPermissions() async {
    try {
      _permissionStatus = await _bridge.checkPermissions();
      _permissionChecked = true;
      _notifyImmediate();
    } catch (_) {}
    return _permissionStatus;
  }

  Future<PermissionStatusInfo> requestStoragePermissions() async {
    try {
      _permissionStatus = await _bridge.requestPermissions();
      _permissionChecked = true;
      _notifyImmediate();
      unawaited(refreshManagedFiles());
    } catch (_) {}
    return _permissionStatus;
  }

  Future<bool> openAppSettings() async {
    try {
      return await _bridge.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  Future<void> refreshBrowserSessions() async {
    try {
      final status = await _bridge.getBrowserSessionStatus();
      _instagramLoggedIn = status['instagram'] ?? false;
      _douyinLoggedIn = status['douyin'] ?? false;
      _facebookLoggedIn = status['facebook'] ?? false;
      _pixivLoggedIn = status['pixiv'] ?? false;
      _tiktokLoggedIn = status['tiktok'] ?? false;
      _notifyImmediate();
    } catch (_) {}
  }

  Future<bool> openBrowserLogin(String platform) async {
    try {
      final saved = await _bridge.openBrowserLogin(platform);
      await refreshBrowserSessions();
      return saved;
    } catch (_) {
      return false;
    }
  }

  Future<void> clearBrowserSessions() async {
    try {
      await _bridge.clearBrowserSessions();
      _instagramLoggedIn = false;
      _douyinLoggedIn = false;
      _facebookLoggedIn = false;
      _pixivLoggedIn = false;
      _tiktokLoggedIn = false;
      _notifyImmediate();
    } catch (_) {}
  }

  Future<void> refreshManagedFiles() async {
    if (_isLoadingFiles) return;
    _isLoadingFiles = true;
    _notifyImmediate();
    try {
      _managedFiles = List<ManagedFile>.unmodifiable(
        await _bridge.listManagedFiles(),
      );
    } catch (_) {
      // Keep previous list if plugin unavailable (e.g. unit tests)
    } finally {
      _isLoadingFiles = false;
      _notifyImmediate();
    }
  }

  void clearPreview() {
    _currentPreview = null;
    _analyzeError = null;
    _notifyImmediate();
  }

  Future<MediaInfo?> analyzeLink(String rawInput) async {
    final cleanUrl = UrlParser.extractUrl(rawInput);
    if (cleanUrl == null) {
      _analyzeError =
          'Tautan tidak valid. Tempel link dari YouTube, TikTok, Douyin, Instagram, X, Pixiv, atau Facebook.';
      _currentPreview = null;
      _notifyImmediate();
      return null;
    }

    _isAnalyzing = true;
    _analyzeError = null;
    _currentPreview = null;
    _notifyImmediate();

    try {
      final cookiesPath =
          await _storage.getCookiesFilePath(_settings.customCookies);
      final info = await _extractor.analyzeLink(
        rawInput: cleanUrl,
        cookiesPath: cookiesPath,
      );
      _currentPreview = info;
      _analyzeError = null;
      _autoRememberCreatorProfile(info);
      return info;
    } catch (e) {
      _analyzeError = e.toString().replaceFirst('Exception: ', '');
      _currentPreview = null;
      return null;
    } finally {
      _isAnalyzing = false;
      _notifyImmediate();
    }
  }

  MediaFormatOption pickDefaultOption(MediaInfo info) {
    final options = info.options;
    if (options.isEmpty) {
      throw Exception('Tidak ada format unduhan tersedia.');
    }

    switch (_settings.defaultQuality) {
      case DefaultQualityPreset.audioMp3:
        return options.firstWhere(
          (o) => o.isAudio && o.extension == 'mp3',
          orElse: () => options.firstWhere(
            (o) => o.isAudio,
            orElse: () => options.first,
          ),
        );
      case DefaultQualityPreset.p1080:
        return _closestVideoOption(options, 1080);
      case DefaultQualityPreset.p720:
        return _closestVideoOption(options, 720);
      case DefaultQualityPreset.p480:
        return _closestVideoOption(options, 480);
      case DefaultQualityPreset.best:
        return options.first;
    }
  }

  MediaFormatOption _closestVideoOption(
    List<MediaFormatOption> options,
    int targetHeight,
  ) {
    final videos = options.where((o) => o.kind == MediaKind.video).toList();
    if (videos.isEmpty) return options.first;
    final exact = videos.where((o) => o.height == targetHeight).toList();
    if (exact.isNotEmpty) return exact.first;
    final lower = videos
        .where((o) => o.height != null && o.height! <= targetHeight)
        .toList()
      ..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    if (lower.isNotEmpty) return lower.first;
    return videos.first;
  }

  String _nextTaskId(String prefix) {
    _taskSeq++;
    return '${DateTime.now().millisecondsSinceEpoch}_${prefix}_$_taskSeq';
  }

  Map<String, dynamic> _encodeResumePayload({
    required MediaFormatOption option,
    String? pixivIllustId,
    bool isPixivUgoira = false,
    List<String> extraMarkerKeys = const [],
    bool markAlbumKey = true,
  }) {
    return {
      'engine': option.engine.name,
      'directUrl': option.directUrl,
      'galleryUrls': option.galleryUrls,
      'headers': option.headers,
      'ytDlpFormatSelector': option.ytDlpFormatSelector,
      'audioOnly': option.isAudio,
      'extension': option.extension,
      'mediaKind': option.kind.name,
      if (option.isUgoira) 'isUgoira': true,
      if (option.ugoiraFrames.isNotEmpty)
        'ugoiraFrames':
            option.ugoiraFrames.map((f) => f.toJson()).toList(growable: false),
      if (pixivIllustId != null && pixivIllustId.isNotEmpty)
        'pixivIllustId': pixivIllustId,
      if (isPixivUgoira) 'isPixivUgoira': true,
      if (extraMarkerKeys.isNotEmpty) 'extraMarkerKeys': extraMarkerKeys,
      'markAlbumKey': markAlbumKey,
    };
  }

  Future<DownloadItem> startDownload(
    MediaInfo info,
    MediaFormatOption option, {
    List<String> extraMarkerKeys = const [],
    bool markAlbumKey = true,
  }) async {
    if (_permissionChecked &&
        !_permissionStatus.granted &&
        _permissionStatus.sdkInt <= 28) {
      await requestStoragePermissions();
    }
    _autoRememberCreatorProfile(info);

    final taskId = _nextTaskId('dl');
    final markerKey = info.markerKey;
    final initialSubFiles = _buildInitialSubFiles(taskId, info, option);
    final resumePayload = _encodeResumePayload(
      option: option,
      extraMarkerKeys: extraMarkerKeys,
      markAlbumKey: markAlbumKey,
    );

    final initialItem = DownloadItem(
      id: taskId,
      sourceUrl: info.originalUrl,
      markerKey: markerKey,
      platform: info.platform,
      title: info.title,
      author: info.author,
      thumbnailUrl: info.thumbnailUrl,
      formatLabel: option.label,
      extension: option.extension,
      mediaKind: option.kind,
      status: DownloadStatus.queued,
      progress: 0,
      statusText: initialSubFiles.length > 1
          ? 'Menyiapkan ${initialSubFiles.length} file...'
          : 'Menyiapkan unduhan...',
      createdAt: DateTime.now(),
      subFiles: initialSubFiles,
      resumePayload: resumePayload,
    );

    _setItems([initialItem, ..._items]);
    _notifyImmediate();

    if (option.engine == DownloadEngine.directHttp) {
      unawaited(
        _runDirectHttpDownload(
          taskId,
          info,
          option,
          extraMarkerKeys: extraMarkerKeys,
          markAlbumKey: markAlbumKey,
        ),
      );
    } else {
      unawaited(
        _runYtDlpDownload(
          taskId,
          info,
          option,
          extraMarkerKeys: extraMarkerKeys,
          markAlbumKey: markAlbumKey,
        ),
      );
    }

    return initialItem;
  }

  List<SubFileTask> _buildInitialSubFiles(
    String taskId,
    MediaInfo info,
    MediaFormatOption option,
  ) {
    final safeBase = _sanitizeBaseName(info.title);
    if (option.engine == DownloadEngine.directHttp) {
      final urls = option.isMultiImage
          ? option.galleryUrls
          : [if (option.directUrl != null) option.directUrl!];
      if (urls.isNotEmpty) {
        return List<SubFileTask>.generate(urls.length, (i) {
          final suffix = urls.length > 1 ? '_${i + 1}' : '';
          final ext = _detectExtFromUrlOrDefault(urls[i], option.extension);
          return SubFileTask(
            id: '${taskId}_$i',
            fileName: '$safeBase$suffix.$ext',
            status: DownloadStatus.queued,
          );
        }, growable: false);
      }
    }
    return [
      SubFileTask(
        id: '${taskId}_0',
        fileName: '$safeBase.${option.extension}',
        status: DownloadStatus.queued,
      ),
    ];
  }

  /// Downloads ONLY the user-selected photos from a multi-photo post (ALL platforms).
  /// Any photo/album already marked downloaded is strictly skipped unless unmarked first!
  Future<int> downloadSelectedPhotos(
    MediaInfo info,
    List<SelectableMediaItem> selected,
  ) async {
    if (selected.isEmpty) return 0;
    if (_permissionChecked &&
        !_permissionStatus.granted &&
        _permissionStatus.sdkInt <= 28) {
      await requestStoragePermissions();
    }

    if (isMarkedDownloaded(info.markerKey)) {
      return 0;
    }

    final eligible =
        selected.where((item) => !isMarkedDownloaded(item.markerKey)).toList();
    if (eligible.isEmpty) return 0;

    final urls = <String>[];
    final extraKeys = <String>[];
    for (final item in eligible) {
      final u = item.directUrl;
      if (u != null && u.startsWith('http')) {
        urls.add(u);
        if (item.markerKey.isNotEmpty) extraKeys.add(item.markerKey);
      }
    }
    if (urls.isEmpty) return 0;

    final allPagesCovered = info.selectableItems.isEmpty ||
        info.selectableItems.every(
          (p) =>
              extraKeys.contains(p.markerKey) ||
              isMarkedDownloaded(p.markerKey),
        );

    final first = eligible.first;
    final customOption = MediaFormatOption(
      id: 'selected_photos_${DateTime.now().millisecondsSinceEpoch}',
      label: eligible.length > 1
          ? '${eligible.length} Foto Terpilih'
          : 'Foto Terpilih',
      subtitle: '${first.extension.toUpperCase()} • ${info.author}',
      extension: first.extension,
      kind: MediaKind.image,
      engine: DownloadEngine.directHttp,
      directUrl: urls.first,
      galleryUrls: urls,
      headers: first.headers,
    );

    await startDownload(
      info,
      customOption,
      extraMarkerKeys: extraKeys,
      markAlbumKey: allPagesCovered,
    );
    return urls.length;
  }

  /// Bulk downloads selected items from ANY Profile or Playlist URL
  /// (Pixiv, YouTube, TikTok, IG, X, FB, Douyin).
  /// Any item already marked downloaded is strictly skipped unless unmarked first!
  Future<int> startBulkDownloads(
    MediaInfo collectionInfo,
    List<SelectableMediaItem> selected, {
    bool audioOnly = false,
  }) async {
    if (selected.isEmpty) return 0;
    if (_permissionChecked &&
        !_permissionStatus.granted &&
        _permissionStatus.sdkInt <= 28) {
      await requestStoragePermissions();
    }
    _autoRememberCreatorProfile(collectionInfo);

    final eligible =
        selected.where((sel) => !isMarkedDownloaded(sel.markerKey)).toList();
    if (eligible.isEmpty) return 0;

    final directQueue = <(String, SelectableMediaItem)>[];
    final ytDlpQueue = <(String, SelectableMediaItem)>[];
    final newItems = <DownloadItem>[];

    for (int i = 0; i < eligible.length; i++) {
      final sel = eligible[i];
      final taskId = _nextTaskId('bulk');
      final isAudio = audioOnly && sel.kind == MediaKind.video;
      final ext = isAudio ? 'mp3' : sel.extension;
      final kind = isAudio ? MediaKind.audio : sel.kind;
      final isDirect =
          (sel.pixivIllustId != null && sel.pixivIllustId!.isNotEmpty) ||
              (sel.engine == DownloadEngine.directHttp &&
                  sel.directUrl != null &&
                  sel.directUrl!.startsWith('http'));

      final resumePayload = <String, dynamic>{
        'engine': isDirect ? DownloadEngine.directHttp.name : DownloadEngine.ytDlp.name,
        if (sel.pixivIllustId != null && sel.pixivIllustId!.isNotEmpty)
          'pixivIllustId': sel.pixivIllustId,
        if (sel.isPixivUgoira) 'isPixivUgoira': true,
        if (sel.directUrl != null) 'directUrl': sel.directUrl,
        'galleryUrls': sel.kind == MediaKind.image && sel.directUrl != null
            ? [sel.directUrl!]
            : const <String>[],
        'headers': sel.headers,
        'ytDlpFormatSelector': isAudio
            ? null
            : 'bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
        'audioOnly': isAudio,
        'extension': ext,
        'mediaKind': kind.name,
        'extraMarkerKeys': [sel.markerKey],
        'markAlbumKey': true,
      };

      newItems.add(
        DownloadItem(
          id: taskId,
          sourceUrl:
              sel.sourcePostUrl ?? sel.directUrl ?? collectionInfo.originalUrl,
          markerKey: sel.markerKey,
          platform: collectionInfo.platform,
          title: sel.title,
          author: sel.author ?? collectionInfo.author,
          thumbnailUrl: sel.thumbnailUrl,
          formatLabel:
              isAudio ? 'Audio MP3 (Massal)' : 'Massal (${ext.toUpperCase()})',
          extension: ext,
          mediaKind: kind,
          status: DownloadStatus.queued,
          progress: 0,
          statusText: 'Dalam antrean (${i + 1}/${eligible.length})...',
          createdAt: DateTime.now(),
          subFiles: [
            SubFileTask(
              id: '${taskId}_0',
              fileName: '${_sanitizeBaseName(sel.title)}.$ext',
              status: DownloadStatus.queued,
            ),
          ],
          resumePayload: resumePayload,
        ),
      );

      if (isDirect) {
        directQueue.add((taskId, sel));
      } else {
        ytDlpQueue.add((taskId, sel));
      }
    }

    _setItems([...newItems.reversed, ..._items]);
    _notifyImmediate();

    if (directQueue.isNotEmpty) {
      unawaited(_processDirectBulkPool(collectionInfo, directQueue));
    }
    if (ytDlpQueue.isNotEmpty) {
      unawaited(
        _processYtDlpBulkQueue(
          collectionInfo,
          ytDlpQueue,
          audioOnly: audioOnly,
        ),
      );
    }
    return eligible.length;
  }

  /// High-throughput load-balanced worker pool (4 tasks sharing 5 HTTP streams).
  Future<void> _processDirectBulkPool(
    MediaInfo collectionInfo,
    List<(String, SelectableMediaItem)> queue,
  ) async {
    final pixivCookie = collectionInfo.platform == MediaPlatform.pixiv
        ? await _resolvePixivCookieHeader()
        : '';

    int cursor = 0;
    final workerCount = queue.length < _bulkDirectTaskConcurrency
        ? queue.length
        : _bulkDirectTaskConcurrency;

    Future<void> worker() async {
      while (true) {
        if (_isDisposed || cursor >= queue.length) return;
        final (taskId, sel) = queue[cursor++];

        if (_isTaskStopped(taskId)) continue;

        final itemAuthor = sel.author ?? collectionInfo.author;
        final singleInfo = MediaInfo(
          originalUrl:
              sel.sourcePostUrl ?? sel.directUrl ?? collectionInfo.originalUrl,
          platform: collectionInfo.platform,
          title: sel.title,
          author: itemAuthor,
          thumbnailUrl: sel.thumbnailUrl,
          extractorLabel: collectionInfo.extractorLabel,
          options: const [],
        );

        if (sel.pixivIllustId != null && sel.pixivIllustId!.isNotEmpty) {
          await _executePixivArtworkTask(
            taskId: taskId,
            illustId: sel.pixivIllustId!,
            info: singleInfo,
            headers: sel.headers,
            pixivCookie: pixivCookie,
            isUgoiraHint: sel.isPixivUgoira,
            extraMarkerKeys: [sel.markerKey],
          );
          continue;
        }

        if (sel.directUrl != null && sel.directUrl!.startsWith('http')) {
          final opt = MediaFormatOption(
            id: 'bulk_direct_${sel.id}',
            label: sel.extension.toUpperCase(),
            subtitle: 'Direct',
            extension: sel.extension,
            kind: sel.kind,
            engine: DownloadEngine.directHttp,
            directUrl: sel.directUrl,
            galleryUrls:
                sel.kind == MediaKind.image ? [sel.directUrl!] : const [],
            headers: sel.headers,
          );
          await _runDirectHttpDownload(
            taskId,
            singleInfo,
            opt,
            extraMarkerKeys: [sel.markerKey],
          );
        }
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<void> _executePixivArtworkTask({
    required String taskId,
    required String illustId,
    required MediaInfo info,
    required Map<String, String> headers,
    required String pixivCookie,
    bool isUgoiraHint = false,
    required List<String> extraMarkerKeys,
  }) async {
    if (_isTaskStopped(taskId)) return;

    final effectiveHeaders = {
      ...headers,
      ...DirectExtractors.buildPixivCdnHeaders(
        cookieHeader: pixivCookie,
        customCookies: _settings.customCookies,
      ),
    };

    Future<bool> tryRunUgoira() async {
      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: DownloadStatus.downloading,
          statusText: 'Memuat metadata animasi Ugoira...',
        ),
      );
      final ugoira = await _extractor.directExtractors.fetchPixivUgoiraMeta(
        illustId,
        cookieHeader: pixivCookie,
        customCookies: _settings.customCookies,
      );
      if (_isTaskStopped(taskId)) return true;
      if (ugoira == null) return false;

      final opt = MediaFormatOption(
        id: 'px_ugoira_$illustId',
        label: 'Ugoira MP4',
        subtitle: 'Pixiv Ugoira',
        extension: 'mp4',
        kind: MediaKind.video,
        engine: DownloadEngine.directHttp,
        directUrl: ugoira.zipUrl,
        headers: effectiveHeaders,
        isUgoira: true,
        ugoiraFrames: ugoira.frames,
      );
      final safeBase = _sanitizeBaseName(info.title);
      _updateItem(
        taskId,
        (item) => item.copyWith(
          extension: 'mp4',
          mediaKind: MediaKind.video,
          formatLabel: 'Ugoira MP4',
          subFiles: [
            SubFileTask(
              id: '${taskId}_0',
              fileName: '$safeBase.mp4',
              status: DownloadStatus.queued,
            ),
          ],
          resumePayload: _encodeResumePayload(
            option: opt,
            pixivIllustId: illustId,
            isPixivUgoira: true,
            extraMarkerKeys: extraMarkerKeys,
          ),
        ),
      );
      await _runDirectHttpDownload(
        taskId,
        info,
        opt,
        extraMarkerKeys: extraMarkerKeys,
      );
      return true;
    }

    if (isUgoiraHint) {
      final ran = await tryRunUgoira();
      if (ran) return;
    }

    _updateItem(
      taskId,
      (item) => item.copyWith(
        status: DownloadStatus.downloading,
        statusText: 'Memuat daftar halaman Pixiv...',
      ),
    );

    final cached = _pixivPagesCache[illustId];
    final origUrls = (cached != null && cached.isNotEmpty)
        ? cached
        : await _extractor.directExtractors.fetchPixivIllustOriginalUrls(
            illustId,
            cookieHeader: pixivCookie,
            customCookies: _settings.customCookies,
          );

    if (_isTaskStopped(taskId)) return;

    // Auto-detect Ugoira even if bulk metadata wasn't available (Pixiv Ugoira cover contains `_ugoira`)!
    final looksLikeUgoira = origUrls.length == 1 &&
        origUrls.first.toLowerCase().contains('_ugoira');
    if (origUrls.isEmpty || looksLikeUgoira) {
      final ran = await tryRunUgoira();
      if (ran) return;
    }

    if (origUrls.isNotEmpty) {
      _pixivPagesCache[illustId] = origUrls;
    }

    if (origUrls.isEmpty) {
      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: DownloadStatus.failed,
          statusText: 'Gagal mengambil halaman Pixiv',
          errorMessage:
              'Karya R-18 / member Pixiv memerlukan login di Pengaturan (dan aktifkan tampilan R-18 di akun Pixiv).',
          subFiles: item.subFiles
              .map((s) => s.copyWith(
                    status: DownloadStatus.failed,
                    errorMessage: 'Halaman Pixiv tidak dapat diakses',
                  ))
              .toList(growable: false),
        ),
      );
      _schedulePostDownloadSync(includeMediaRefresh: false);
      return;
    }

    final ext = _detectExtFromUrlOrDefault(origUrls.first, 'jpg');
    final opt = MediaFormatOption(
      id: 'px_bulk_$illustId',
      label: origUrls.length > 1 ? '${origUrls.length} Halaman' : 'Original HD',
      subtitle: 'Pixiv',
      extension: ext,
      kind: MediaKind.image,
      engine: DownloadEngine.directHttp,
      directUrl: origUrls.first,
      galleryUrls: origUrls,
      headers: effectiveHeaders,
    );

    // Save resolved galleryUrls into resumePayload so Pause/Resume skips /pages API!
    _updateItem(
      taskId,
      (item) => item.copyWith(
        resumePayload: _encodeResumePayload(
          option: opt,
          pixivIllustId: illustId,
          extraMarkerKeys: extraMarkerKeys,
        ),
      ),
    );

    await _runDirectHttpDownload(
      taskId,
      info,
      opt,
      extraMarkerKeys: extraMarkerKeys,
    );
  }

  /// Controlled sequential queue for CPU-heavy native yt-dlp/FFmpeg bulk items.
  Future<void> _processYtDlpBulkQueue(
    MediaInfo collectionInfo,
    List<(String, SelectableMediaItem)> queue, {
    required bool audioOnly,
  }) async {
    for (final (taskId, sel) in queue) {
      if (_isDisposed) return;
      if (_isTaskStopped(taskId)) continue;

      final itemAuthor = sel.author ?? collectionInfo.author;
      final singleInfo = MediaInfo(
        originalUrl:
            sel.sourcePostUrl ?? sel.directUrl ?? collectionInfo.originalUrl,
        platform: collectionInfo.platform,
        title: sel.title,
        author: itemAuthor,
        thumbnailUrl: sel.thumbnailUrl,
        extractorLabel: collectionInfo.extractorLabel,
        options: const [],
      );

      final isAudio = audioOnly && sel.kind == MediaKind.video;
      final opt = MediaFormatOption(
        id: 'bulk_ytdlp_${sel.id}',
        label: isAudio ? 'Audio MP3' : 'Video HD MP4',
        subtitle: 'yt-dlp',
        extension: isAudio ? 'mp3' : 'mp4',
        kind: isAudio ? MediaKind.audio : MediaKind.video,
        engine: DownloadEngine.ytDlp,
        ytDlpFormatSelector: isAudio
            ? null
            : 'bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
      );
      await _runYtDlpDownload(
        taskId,
        singleInfo,
        opt,
        extraMarkerKeys: [sel.markerKey],
      );
    }
  }

  // ===========================================================================
  // PAUSE / RESUME / RETRY / CANCEL CONTROLS
  // ===========================================================================
  bool _isTaskCancelled(String taskId) {
    if (_cancelledTaskIds.contains(taskId)) return true;
    final item = findItemById(taskId);
    return item == null || item.status == DownloadStatus.cancelled;
  }

  bool _isTaskPaused(String taskId) {
    if (_pausedTaskIds.contains(taskId)) return true;
    final item = findItemById(taskId);
    return item != null && item.status == DownloadStatus.paused;
  }

  bool _isTaskStopped(String taskId) =>
      _isTaskCancelled(taskId) || _isTaskPaused(taskId);

  Future<void> pauseDownload(String taskId) async {
    final item = findItemById(taskId);
    if (item == null || !item.isActive) return;

    _pausedTaskIds.add(taskId);
    final directToken = _directCancelTokens[taskId];
    if (directToken != null && !directToken.isCancelled) {
      directToken.cancel('PAUSED_BY_USER');
    } else {
      try {
        await _bridge.pauseDownload(taskId);
      } catch (_) {}
    }

    _updateItem(
      taskId,
      (it) => it.copyWith(
        status: DownloadStatus.paused,
        statusText: it.subFiles.length > 1
            ? 'Dijeda (${it.completedSubFilesCount}/${it.subFiles.length} selesai)'
            : 'Dijeda (${it.progress.clamp(0, 100).toStringAsFixed(0)}%)',
        subFiles: it.subFiles
            .map((s) => s.isActive
                ? s.copyWith(status: DownloadStatus.paused, speedText: '')
                : s)
            .toList(growable: false),
      ),
    );
    await _storage.saveHistory(_items);
  }

  Future<void> pauseAllDownloads() async {
    final actives = activeDownloads;
    for (final item in actives) {
      await pauseDownload(item.id);
    }
  }

  Future<void> resumeDownload(String taskId) async {
    final item = findItemById(taskId);
    if (item == null || item.isActive || item.status == DownloadStatus.completed) {
      return;
    }

    _pausedTaskIds.remove(taskId);
    _cancelledTaskIds.remove(taskId);

    _updateItem(
      taskId,
      (it) => it.copyWith(
        status: DownloadStatus.queued,
        clearError: true,
        statusText: 'Melanjutkan unduhan...',
        subFiles: it.subFiles
            .map((s) => s.status == DownloadStatus.completed
                ? s
                : s.copyWith(
                    status: DownloadStatus.queued,
                    speedText: '',
                  ))
            .toList(growable: false),
      ),
    );

    final payload = item.resumePayload ?? const <String, dynamic>{};
    final info = MediaInfo(
      originalUrl: item.sourceUrl,
      platform: item.platform,
      title: item.title,
      author: item.author,
      thumbnailUrl: item.thumbnailUrl,
      extractorLabel: 'Resume',
      options: const [],
    );

    final extraKeys = (payload['extraMarkerKeys'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList() ??
        <String>[if (item.markerKey.isNotEmpty) item.markerKey];
    final markAlbumKey = payload['markAlbumKey'] as bool? ?? true;

    final rawHeaders = payload['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k != null && v != null) headers[k.toString()] = v.toString();
      });
    }
    if (item.platform == MediaPlatform.pixiv && !headers.containsKey('Referer')) {
      headers['Referer'] = 'https://www.pixiv.net/';
    }

    final pixivIllustId = payload['pixivIllustId']?.toString();
    final isPixivUgoira = payload['isPixivUgoira'] as bool? ?? false;
    final isUgoira = payload['isUgoira'] as bool? ?? false;
    final ugoiraFrames = (payload['ugoiraFrames'] as List?)
            ?.whereType<Map>()
            .map((e) => PixivUgoiraFrame.fromJson(Map<String, dynamic>.from(e)))
            .toList(growable: false) ??
        const <PixivUgoiraFrame>[];
    final galleryUrls = (payload['galleryUrls'] as List?)
            ?.map((e) => e.toString())
            .where((u) => u.startsWith('http'))
            .toList() ??
        const <String>[];
    final directUrl = payload['directUrl']?.toString();
    final engineStr = payload['engine']?.toString() ?? '';

    if (item.platform == MediaPlatform.pixiv) {
      final freshCookie = await _resolvePixivCookieHeader();
      headers.addAll(
        DirectExtractors.buildPixivCdnHeaders(
          cookieHeader: freshCookie,
          customCookies: _settings.customCookies,
        ),
      );
    }

    if (pixivIllustId != null &&
        pixivIllustId.isNotEmpty &&
        galleryUrls.isEmpty &&
        !isUgoira) {
      final pixivCookie = await _resolvePixivCookieHeader();
      unawaited(
        _executePixivArtworkTask(
          taskId: taskId,
          illustId: pixivIllustId,
          info: info,
          headers: headers,
          pixivCookie: pixivCookie,
          isUgoiraHint: isPixivUgoira,
          extraMarkerKeys: extraKeys,
        ),
      );
      return;
    }

    if (engineStr == DownloadEngine.directHttp.name &&
        ((directUrl != null && directUrl.startsWith('http')) ||
            galleryUrls.isNotEmpty)) {
      final opt = MediaFormatOption(
        id: 'resume_$taskId',
        label: item.formatLabel,
        subtitle: 'Resume',
        extension: item.extension,
        kind: item.mediaKind,
        engine: DownloadEngine.directHttp,
        directUrl:
            (directUrl != null && directUrl.startsWith('http'))
                ? directUrl
                : galleryUrls.first,
        galleryUrls: galleryUrls,
        headers: headers,
        isUgoira: isUgoira,
        ugoiraFrames: ugoiraFrames,
      );
      unawaited(
        _runDirectHttpDownload(
          taskId,
          info,
          opt,
          extraMarkerKeys: extraKeys,
          markAlbumKey: markAlbumKey,
        ),
      );
      return;
    }

    // Resume via yt-dlp (--continue automatically picks up .part file!)
    final isAudio = payload['audioOnly'] as bool? ??
        item.mediaKind == MediaKind.audio;
    final opt = MediaFormatOption(
      id: 'resume_ytdlp_$taskId',
      label: item.formatLabel,
      subtitle: 'yt-dlp',
      extension: item.extension,
      kind: isAudio ? MediaKind.audio : item.mediaKind,
      engine: DownloadEngine.ytDlp,
      ytDlpFormatSelector: payload['ytDlpFormatSelector']?.toString() ??
          (isAudio
              ? null
              : 'bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best'),
    );
    unawaited(
      _runYtDlpDownload(
        taskId,
        info,
        opt,
        extraMarkerKeys: extraKeys,
        markAlbumKey: markAlbumKey,
      ),
    );
  }

  Future<void> resumeAllPaused() async {
    final toResume = pausedDownloads;
    for (final item in toResume) {
      await resumeDownload(item.id);
    }
  }

  Future<void> retryAllFailed() async {
    final failed = _items
        .where((i) => i.status == DownloadStatus.failed && i.canResume)
        .toList(growable: false);
    for (final item in failed) {
      await resumeDownload(item.id);
    }
  }

  Future<void> cancelDownload(String taskId) async {
    _pausedTaskIds.remove(taskId);
    _cancelledTaskIds.add(taskId);
    final directToken = _directCancelTokens[taskId];
    if (directToken != null && !directToken.isCancelled) {
      directToken.cancel('Dibatalkan oleh pengguna');
    } else {
      try {
        await _bridge.cancelDownload(taskId);
      } catch (_) {}
    }
    _updateItem(
      taskId,
      (item) => item.copyWith(
        status: DownloadStatus.cancelled,
        statusText: 'Dibatalkan',
        subFiles: item.subFiles
            .map((s) => s.isActive || s.status == DownloadStatus.paused
                ? s.copyWith(status: DownloadStatus.cancelled, speedText: '')
                : s)
            .toList(growable: false),
      ),
    );
    _schedulePostDownloadSync(includeMediaRefresh: false);
  }

  Future<String> _safeCookieHeader(String url) async {
    try {
      return await _bridge.getCookieHeader(url);
    } catch (_) {
      return '';
    }
  }

  Future<String> _resolvePixivCookieHeader() async {
    final webViewCookie = await _safeCookieHeader('https://www.pixiv.net/');
    return DirectExtractors.mergePixivCookies(
      cookieHeader: webViewCookie,
      customCookies: _settings.customCookies,
    );
  }

  Future<void> _runYtDlpDownload(
    String taskId,
    MediaInfo info,
    MediaFormatOption option, {
    List<String> extraMarkerKeys = const [],
    bool markAlbumKey = true,
  }) async {
    await _ytDlpPool.run(() async {
      if (_isDisposed || _isTaskStopped(taskId)) return;

      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: DownloadStatus.downloading,
          statusText: 'Memulai engine unduhan...',
          subFiles: item.subFiles.isEmpty
              ? [
                  SubFileTask(
                    id: '${taskId}_0',
                    fileName:
                        '${_sanitizeBaseName(info.title)}.${option.extension}',
                    status: DownloadStatus.downloading,
                  ),
                ]
              : [
                  item.subFiles.first
                      .copyWith(status: DownloadStatus.downloading),
                  ...item.subFiles.skip(1),
                ],
        ),
      );

      try {
        final cookiesPath =
            await _storage.getCookiesFilePath(_settings.customCookies);
        final saved = await _bridge.downloadWithYtDlp(
          taskId: taskId,
          url: info.originalUrl,
          formatSelector: option.ytDlpFormatSelector,
          audioOnly: option.isAudio,
          audioFormat: option.extension,
          cookiesPath: cookiesPath,
          useAria2c: _settings.useAria2c,
          platformFolder: info.platform.folderName,
          creatorFolder: info.author,
        );

        final completedSub = SubFileTask(
          id: '${taskId}_0',
          fileName: saved.fileName,
          status: DownloadStatus.completed,
          progress: 100,
          downloadedBytes: saved.fileSize,
          totalBytes: saved.fileSize,
          speedText: saved.skipped ? 'Dilewati (sudah ada)' : '',
          savedPath: saved.savedPath,
          contentUri: saved.contentUri,
          mimeType: saved.mimeType,
        );

        _updateItem(
          taskId,
          (item) => item.copyWith(
            status: DownloadStatus.completed,
            progress: 100,
            statusText: saved.skipped
                ? 'Dilewati — file sudah ada di ${saved.folderLabel}'
                : 'Tersimpan di ${saved.folderLabel}',
            savedPath: saved.savedPath,
            contentUri: saved.contentUri,
            fileName: saved.fileName,
            fileSize: saved.fileSize,
            mimeType: saved.mimeType,
            subFiles: [completedSub],
            clearResumePayload: true,
          ),
        );

        await markManyDownloaded([
          if (markAlbumKey) info.markerKey,
          ...extraMarkerKeys,
        ]);
        _schedulePostDownloadSync();
      } catch (e) {
        final rawMsg = e.toString();
        final isPaused = rawMsg.contains('PAUSED') || _isTaskPaused(taskId);
        if (isPaused) {
          _updateItem(
            taskId,
            (item) => item.copyWith(
              status: DownloadStatus.paused,
              statusText:
                  'Dijeda (${item.progress.clamp(0, 100).toStringAsFixed(0)}%)',
              subFiles: item.subFiles
                  .map((s) => s.isActive
                      ? s.copyWith(status: DownloadStatus.paused, speedText: '')
                      : s)
                  .toList(growable: false),
            ),
          );
          _schedulePostDownloadSync(includeMediaRefresh: false);
          return;
        }

        final isCancelled =
            rawMsg.contains('CANCELLED') || _isTaskCancelled(taskId);
        final cleanErr = rawMsg.replaceFirst('Exception: ', '').trim();
        _updateItem(
          taskId,
          (item) => item.copyWith(
            status:
                isCancelled ? DownloadStatus.cancelled : DownloadStatus.failed,
            statusText: isCancelled ? 'Dibatalkan' : 'Unduhan gagal',
            errorMessage: isCancelled ? null : cleanErr,
            subFiles: item.subFiles
                .map((s) => s.copyWith(
                      status: isCancelled
                          ? DownloadStatus.cancelled
                          : DownloadStatus.failed,
                      speedText: '',
                      errorMessage: isCancelled ? null : cleanErr,
                    ))
                .toList(growable: false),
          ),
        );
        _schedulePostDownloadSync(includeMediaRefresh: false);
      }
    });
  }

  /// High-speed load-balanced Direct HTTP downloader with:
  /// - 5 concurrent HTTP streams
  /// - Pre-download duplicate check (zero `(1)` files!)
  /// - Full Pause / Resume preserving completed pages & HTTP Range `.part` resume!
  Future<void> _runDirectHttpDownload(
    String taskId,
    MediaInfo info,
    MediaFormatOption option, {
    List<String> extraMarkerKeys = const [],
    bool markAlbumKey = true,
  }) async {
    if (_isDisposed || _isTaskStopped(taskId)) return;

    final cancelToken = CancelToken();
    _directCancelTokens[taskId] = cancelToken;

    try {
      final cacheDir = await getTemporaryDirectory();
      final urlsToDownload = option.isMultiImage
          ? option.galleryUrls
          : [if (option.directUrl != null) option.directUrl!];

      if (urlsToDownload.isEmpty) {
        throw Exception('URL unduhan langsung tidak tersedia.');
      }

      final safeBase = _sanitizeBaseName(info.title);
      final totalFiles = urlsToDownload.length;
      final existingItem = findItemById(taskId);
      final prevSubs = existingItem?.subFiles ?? const <SubFileTask>[];

      // Preserve already-completed sub-files when resuming a paused/failed album!
      final subTasks = List<SubFileTask>.generate(totalFiles, (i) {
        if (i < prevSubs.length && prevSubs[i].status == DownloadStatus.completed) {
          return prevSubs[i];
        }
        final suffix = totalFiles > 1 ? '_${i + 1}' : '';
        final fileExt = _detectExtFromUrlOrDefault(urlsToDownload[i], option.extension);
        return SubFileTask(
          id: '${taskId}_$i',
          fileName: '$safeBase$suffix.$fileExt',
          status: DownloadStatus.queued,
        );
      });

      final fileSpeedBps = List<double>.filled(totalFiles, 0.0);
      SavedFileResult? firstSaved;
      SavedFileResult? lastSaved;
      int skippedCount = 0;

      // Seed representative from previously completed sub-files if resuming
      for (final s in subTasks) {
        if (s.status == DownloadStatus.completed &&
            (s.savedPath != null && s.savedPath!.isNotEmpty)) {
          firstSaved ??= SavedFileResult(
            savedPath: s.savedPath!,
            contentUri: s.contentUri ?? '',
            fileName: s.fileName,
            fileSize: s.downloadedBytes,
            mimeType: s.mimeType ?? option.mimeType,
            folderLabel: info.platform == MediaPlatform.pixiv
                ? 'Privat/Pixiv/${info.author}'
                : 'Pictures/all_download/${info.platform.folderName}/${info.author}',
            platformFolder: info.platform.folderName,
            creatorFolder: info.author,
          );
        }
      }

      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: DownloadStatus.downloading,
          statusText: totalFiles > 1
              ? 'Mengunduh ${subTasks.where((s) => s.status == DownloadStatus.completed).length}/$totalFiles file...'
              : 'Menghubungkan...',
          subFiles: List<SubFileTask>.unmodifiable(subTasks),
        ),
      );

      void syncParent({bool immediate = false}) {
        double progressSum = 0;
        int completedCount = 0;
        int savingCount = 0;
        int downloadingCount = 0;
        double combinedSpeedBps = 0;
        int totalDownloadedBytes = 0;

        for (int idx = 0; idx < subTasks.length; idx++) {
          final st = subTasks[idx];
          totalDownloadedBytes += st.downloadedBytes;
          if (st.status == DownloadStatus.completed) {
            completedCount++;
            progressSum += 100.0;
          } else if (st.status == DownloadStatus.saving) {
            savingCount++;
            progressSum += 98.0;
          } else if (st.status == DownloadStatus.downloading) {
            downloadingCount++;
            combinedSpeedBps += fileSpeedBps[idx];
            progressSum += st.progress > 0 ? st.progress.clamp(0.0, 96.0) : 5.0;
          }
        }

        final overallPct = totalFiles > 0 ? (progressSum / totalFiles) : 0.0;
        final speedLabel = combinedSpeedBps > 512
            ? ' • ${_formatSpeed(combinedSpeedBps)}'
            : '';

        String statusLabel;
        if (totalFiles > 1) {
          statusLabel = '$completedCount/$totalFiles file selesai$speedLabel';
        } else {
          final single = subTasks.first;
          if (single.status == DownloadStatus.saving) {
            statusLabel = option.isUgoira
                ? 'Mengonversi Ugoira ke ${option.extension.toUpperCase()} (FFmpeg)...'
                : 'Menyimpan ke folder ${info.platform.folderName}...';
          } else if (single.totalBytes > 0) {
            statusLabel =
                '${formatBytes(single.downloadedBytes)} / ${formatBytes(single.totalBytes)}$speedLabel';
          } else if (single.downloadedBytes > 0) {
            statusLabel = 'Mengunduh ${formatBytes(single.downloadedBytes)}$speedLabel';
          } else {
            statusLabel = 'Mengunduh...';
          }
        }

        _updateItem(
          taskId,
          (item) {
            if (!item.isActive) return item;
            return item.copyWith(
              status: (downloadingCount == 0 && savingCount > 0)
                  ? DownloadStatus.saving
                  : DownloadStatus.downloading,
              progress: overallPct.clamp(0.0, 99.5),
              statusText: statusLabel,
              fileSize:
                  totalDownloadedBytes > 0 ? totalDownloadedBytes : item.fileSize,
              subFiles: List<SubFileTask>.unmodifiable(subTasks),
            );
          },
          throttled: !immediate,
        );
      }

      await Future.wait(
        List<Future<void>>.generate(totalFiles, (i) async {
          if (subTasks[i].status == DownloadStatus.completed) {
            return;
          }

          final targetUrl = urlsToDownload[i];
          final fileExt = _detectExtFromUrlOrDefault(targetUrl, option.extension);
          final fileName = subTasks[i].fileName;
          final partPath = p.join(cacheDir.path, 'direct_${taskId}_$i.$fileExt.part');

          await _directFilePool.run(() async {
            if (cancelToken.isCancelled || _isTaskStopped(taskId)) {
              subTasks[i] = subTasks[i].copyWith(
                status: _isTaskPaused(taskId)
                    ? DownloadStatus.paused
                    : DownloadStatus.cancelled,
                speedText: '',
              );
              return;
            }

            final isPixivPrivate = info.platform == MediaPlatform.pixiv;
            final mime = _mimeForExtension(fileExt, option.kind);

            // Fast pre-download check: if exact file already exists, SKIP immediately!
            try {
              final existing = await _bridge.findExistingFile(
                fileName: fileName,
                mimeType: mime,
                platformFolder: info.platform.folderName,
                creatorFolder: info.author,
                albumFolder: isPixivPrivate ? info.title : null,
                checkPrivateVault: true,
              );
              if (existing != null) {
                skippedCount++;
                firstSaved ??= existing;
                lastSaved = existing;
                subTasks[i] = subTasks[i].copyWith(
                  fileName: existing.fileName,
                  status: DownloadStatus.completed,
                  progress: 100,
                  downloadedBytes: existing.fileSize,
                  totalBytes: existing.fileSize,
                  speedText: 'Dilewati (sudah ada)',
                  savedPath: existing.savedPath,
                  contentUri: existing.contentUri,
                  mimeType: existing.mimeType,
                );
                syncParent(immediate: true);
                return;
              }
            } catch (_) {}

            subTasks[i] = subTasks[i].copyWith(
              status: DownloadStatus.downloading,
            );
            syncParent();

            int lastTickMs = DateTime.now().millisecondsSinceEpoch;
            int lastTickBytes = 0;

            Future<void> performResumableDownload() async {
              final partFile = File(partPath);
              int existingBytes = 0;
              if (await partFile.exists()) {
                existingBytes = await partFile.length();
              }
              lastTickBytes = existingBytes;

              final reqHeaders = <String, dynamic>{
                ...option.headers,
                if (existingBytes > 0) 'Range': 'bytes=$existingBytes-',
              };

              final response = await _dio.get<ResponseBody>(
                targetUrl,
                cancelToken: cancelToken,
                options: Options(
                  responseType: ResponseType.stream,
                  headers: reqHeaders,
                  followRedirects: true,
                  maxRedirects: 8,
                  validateStatus: (s) => s != null && s < 400,
                ),
              );

              final statusCode = response.statusCode ?? 200;
              final isPartialResume = statusCode == 206 && existingBytes > 0;
              int received = isPartialResume ? existingBytes : 0;

              final contentLength =
                  int.tryParse(response.headers.value('content-length') ?? '') ?? -1;
              final total = contentLength > 0
                  ? (isPartialResume ? existingBytes + contentLength : contentLength)
                  : -1;

              final sink = partFile.openWrite(
                mode: isPartialResume ? FileMode.append : FileMode.write,
              );
              try {
                final stream = response.data?.stream;
                if (stream == null) {
                  throw Exception('Stream kosong dari server.');
                }
                await for (final chunk in stream) {
                  if (cancelToken.isCancelled || _isTaskStopped(taskId)) {
                    throw DioException.requestCancelled(
                      requestOptions: response.requestOptions,
                      reason: _isTaskPaused(taskId)
                          ? 'PAUSED_BY_USER'
                          : 'Dibatalkan',
                    );
                  }
                  sink.add(chunk);
                  received += chunk.length;

                  final nowMs = DateTime.now().millisecondsSinceEpoch;
                  final elapsedMs = nowMs - lastTickMs;
                  final isDone = total > 0 && received >= total;
                  if (!isDone && elapsedMs < 220) continue;

                  if (elapsedMs > 0) {
                    final deltaBytes = received - lastTickBytes;
                    if (deltaBytes >= 0) {
                      fileSpeedBps[i] = (deltaBytes * 1000.0) / elapsedMs;
                    }
                    lastTickMs = nowMs;
                    lastTickBytes = received;
                  }

                  final pct = total > 0
                      ? ((received / total) * 100.0).clamp(0.0, 100.0)
                      : -1.0;
                  subTasks[i] = subTasks[i].copyWith(
                    status: DownloadStatus.downloading,
                    progress: pct,
                    downloadedBytes: received,
                    totalBytes: total > 0 ? total : subTasks[i].totalBytes,
                    speedText: fileSpeedBps[i] > 512
                        ? _formatSpeed(fileSpeedBps[i])
                        : '',
                  );
                  syncParent();
                }
                await sink.flush();
              } finally {
                await sink.close();
              }
            }

            bool keepPartOnExit = false;
            try {
              try {
                await performResumableDownload();
              } on DioException catch (firstErr) {
                if (CancelToken.isCancel(firstErr) ||
                    cancelToken.isCancelled ||
                    _isTaskStopped(taskId)) {
                  rethrow;
                }
                await Future<void>.delayed(const Duration(milliseconds: 650));
                if (cancelToken.isCancelled || _isTaskStopped(taskId)) {
                  throw DioException.requestCancelled(
                    requestOptions: firstErr.requestOptions,
                    reason: _isTaskPaused(taskId) ? 'PAUSED_BY_USER' : 'Dibatalkan',
                  );
                }
                lastTickMs = DateTime.now().millisecondsSinceEpoch;
                await performResumableDownload();
              }

              if (cancelToken.isCancelled || _isTaskStopped(taskId)) {
                keepPartOnExit = _isTaskPaused(taskId);
                subTasks[i] = subTasks[i].copyWith(
                  status: keepPartOnExit
                      ? DownloadStatus.paused
                      : DownloadStatus.cancelled,
                  speedText: '',
                );
                return;
              }

              fileSpeedBps[i] = 0;
              subTasks[i] = subTasks[i].copyWith(
                status: DownloadStatus.saving,
                progress: 99,
                speedText: '',
              );
              syncParent();

              final saved = option.isUgoira
                  ? await _ytDlpPool.run(
                      () => _bridge.convertUgoiraZip(
                        zipPath: partPath,
                        frames: option.ugoiraFrames
                            .map((f) => f.toJson())
                            .toList(growable: false),
                        outputFormat: option.extension,
                        fileName: fileName,
                        platformFolder: info.platform.folderName,
                        creatorFolder: info.author,
                        albumFolder: isPixivPrivate ? info.title : null,
                        isPrivate: isPixivPrivate,
                      ),
                    )
                  : await _bridge.saveFileToDownloads(
                      sourcePath: partPath,
                      fileName: fileName,
                      mimeType: mime,
                      platformFolder: info.platform.folderName,
                      creatorFolder: info.author,
                      albumFolder: isPixivPrivate ? info.title : null,
                      isPrivate: isPixivPrivate,
                    );
              if (saved.skipped) skippedCount++;

              firstSaved ??= saved;
              lastSaved = saved;

              subTasks[i] = subTasks[i].copyWith(
                fileName: saved.fileName,
                status: DownloadStatus.completed,
                progress: 100,
                downloadedBytes: saved.fileSize,
                totalBytes: saved.fileSize,
                speedText: saved.skipped ? 'Dilewati (sudah ada)' : '',
                savedPath: saved.savedPath,
                contentUri: saved.contentUri,
                mimeType: saved.mimeType,
              );
              syncParent(immediate: true);
            } on DioException catch (e) {
              fileSpeedBps[i] = 0;
              final paused = _isTaskPaused(taskId) ||
                  (e.error?.toString().contains('PAUSED_BY_USER') ?? false);
              if (paused) {
                keepPartOnExit = true;
                subTasks[i] = subTasks[i].copyWith(
                  status: DownloadStatus.paused,
                  speedText: '',
                );
              } else {
                final cancelled =
                    CancelToken.isCancel(e) || cancelToken.isCancelled;
                subTasks[i] = subTasks[i].copyWith(
                  status: cancelled
                      ? DownloadStatus.cancelled
                      : DownloadStatus.failed,
                  speedText: '',
                  errorMessage:
                      cancelled ? null : (e.message ?? 'Koneksi terputus'),
                );
              }
              syncParent(immediate: true);
            } catch (e) {
              fileSpeedBps[i] = 0;
              subTasks[i] = subTasks[i].copyWith(
                status: DownloadStatus.failed,
                speedText: '',
                errorMessage: e.toString().replaceFirst('Exception: ', ''),
              );
              syncParent(immediate: true);
            } finally {
              if (!keepPartOnExit) {
                final tempFile = File(partPath);
                if (await tempFile.exists()) {
                  await tempFile.delete().catchError((_) => tempFile);
                }
              }
            }
          });
        }),
      );

      // Finalize overall DownloadItem state
      if (_isTaskPaused(taskId)) {
        final pausedSubs = subTasks
            .map((s) => s.isActive
                ? s.copyWith(status: DownloadStatus.paused, speedText: '')
                : s)
            .toList(growable: false);
        final doneNow =
            pausedSubs.where((s) => s.status == DownloadStatus.completed).length;
        _updateItem(
          taskId,
          (item) => item.copyWith(
            status: DownloadStatus.paused,
            statusText: totalFiles > 1
                ? 'Dijeda ($doneNow/$totalFiles selesai)'
                : 'Dijeda (${item.progress.clamp(0, 100).toStringAsFixed(0)}%)',
            subFiles: pausedSubs,
          ),
        );
        _schedulePostDownloadSync(includeMediaRefresh: false);
        return;
      }

      if (cancelToken.isCancelled || _isTaskCancelled(taskId)) {
        final cancelledSubs = subTasks
            .map((s) => s.isActive
                ? s.copyWith(status: DownloadStatus.cancelled, speedText: '')
                : s)
            .toList(growable: false);
        _updateItem(
          taskId,
          (item) => item.copyWith(
            status: DownloadStatus.cancelled,
            statusText: 'Dibatalkan',
            subFiles: cancelledSubs,
          ),
        );
        _schedulePostDownloadSync(includeMediaRefresh: false);
        return;
      }

      final completedSubs =
          subTasks.where((s) => s.status == DownloadStatus.completed).toList();
      final failedSubs =
          subTasks.where((s) => s.status == DownloadStatus.failed).toList();
      final totalSavedBytes =
          completedSubs.fold<int>(0, (acc, s) => acc + s.downloadedBytes);
      final representative = firstSaved ?? lastSaved;

      if (completedSubs.isNotEmpty && representative != null) {
        final newlySavedCount = completedSubs.length - skippedCount;
        final String doneText;
        if (totalFiles == 1) {
          doneText = skippedCount > 0
              ? 'Dilewati — file sudah ada di ${representative.folderLabel}'
              : 'Tersimpan di ${representative.folderLabel}';
        } else if (failedSubs.isEmpty) {
          if (skippedCount == completedSubs.length) {
            doneText =
                'Semua ${completedSubs.length} file sudah ada (dilewati)';
          } else if (skippedCount > 0) {
            doneText =
                '$newlySavedCount file baru, $skippedCount sudah ada (dilewati)';
          } else {
            doneText =
                '${completedSubs.length} file tersimpan di ${representative.folderLabel}';
          }
        } else {
          doneText =
              '${completedSubs.length}/$totalFiles file selesai (${failedSubs.length} gagal)';
        }

        _updateItem(
          taskId,
          (item) => item.copyWith(
            status: DownloadStatus.completed,
            progress: 100,
            statusText: doneText,
            savedPath: representative.savedPath,
            contentUri: representative.contentUri,
            fileName: representative.fileName,
            fileSize: totalSavedBytes,
            mimeType: representative.mimeType,
            subFiles: List<SubFileTask>.unmodifiable(subTasks),
            clearResumePayload: true,
          ),
          throttled: _activeDownloadCount > 1 && _items.length >= 60,
        );

        await markManyDownloaded([
          if (markAlbumKey) info.markerKey,
          ...extraMarkerKeys,
        ]);
        _schedulePostDownloadSync();
      } else {
        final firstErr = failedSubs.isNotEmpty
            ? (failedSubs.first.errorMessage ?? 'Gagal mengunduh file')
            : 'Gagal menyimpan file.';
        _updateItem(
          taskId,
          (item) => item.copyWith(
            status: DownloadStatus.failed,
            statusText: 'Unduhan gagal',
            errorMessage: firstErr,
            subFiles: List<SubFileTask>.unmodifiable(subTasks),
          ),
        );
        _schedulePostDownloadSync(includeMediaRefresh: false);
      }
    } catch (e) {
      if (_isTaskPaused(taskId)) return;
      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: DownloadStatus.failed,
          statusText: 'Unduhan gagal',
          errorMessage: e.toString().replaceFirst('Exception: ', ''),
        ),
      );
      _schedulePostDownloadSync(includeMediaRefresh: false);
    } finally {
      _directCancelTokens.remove(taskId);
      _cancelledTaskIds.remove(taskId);
    }
  }

  String _detectExtFromUrlOrDefault(String url, String fallback) {
    final lower = url.toLowerCase();
    if (fallback == 'jpg' || fallback == 'png' || fallback == 'webp') {
      if (lower.contains('.png')) return 'png';
      if (lower.contains('.webp')) return 'webp';
      if (lower.contains('.gif')) return 'gif';
      if (lower.contains('.jpg') || lower.contains('.jpeg')) return 'jpg';
    }
    return fallback;
  }

  String _mimeForExtension(String ext, MediaKind kind) {
    switch (ext.toLowerCase()) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      default:
        return kind == MediaKind.audio
            ? 'audio/mpeg'
            : (kind == MediaKind.image ? 'image/jpeg' : 'video/mp4');
    }
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  }

  void _handleNativeProgress(NativeProgressEvent event) {
    final idx = _itemIndexById[event.taskId];
    if (idx == null || idx < 0 || idx >= _items.length) return;
    final current = _items[idx];
    if (!current.isActive) return;

    final statusLine =
        _prettifyYtDlpLine(event.line, event.progress, event.etaSeconds);
    final speedMatch =
        RegExp(r'at\s+([0-9.]+[KMG]i?B/s)', caseSensitive: false)
            .firstMatch(event.line);
    final speedText = speedMatch?.group(1) ?? '';

    final nextProgress = event.progress >= 0
        ? event.progress.clamp(0.0, 100.0)
        : current.progress;
    final isMerging = event.line.toLowerCase().contains('[merger]') ||
        event.line.toLowerCase().contains('[extractaudio]');

    _updateItem(
      event.taskId,
      (item) {
        final updatedSubs = item.subFiles.isEmpty
            ? item.subFiles
            : [
                item.subFiles.first.copyWith(
                  status: isMerging
                      ? DownloadStatus.saving
                      : DownloadStatus.downloading,
                  progress: nextProgress,
                  speedText: speedText.isNotEmpty
                      ? speedText
                      : item.subFiles.first.speedText,
                ),
                ...item.subFiles.skip(1),
              ];
        return item.copyWith(
          status:
              isMerging ? DownloadStatus.saving : DownloadStatus.downloading,
          progress: nextProgress,
          etaSeconds: event.etaSeconds >= 0 ? event.etaSeconds : item.etaSeconds,
          statusText: statusLine,
          subFiles: updatedSubs,
        );
      },
      throttled: true,
    );
  }

  String _prettifyYtDlpLine(String rawLine, double progress, int etaSec) {
    if (rawLine.startsWith('Mencoba ') || rawLine.startsWith('Memperbarui ')) {
      return rawLine;
    }
    final lower = rawLine.toLowerCase();
    if (lower.contains('[merger]') || lower.contains('merging formats')) {
      return 'Menggabungkan video & audio (FFmpeg)...';
    }
    if (lower.contains('[extractaudio]') ||
        (lower.contains('destination:') && lower.contains('.mp3'))) {
      return 'Mengonversi audio (FFmpeg)...';
    }
    if (progress >= 0) {
      final pctText = '${progress.toStringAsFixed(0)}%';
      if (etaSec > 0) {
        return 'Mengunduh $pctText • Sisa ${_formatEta(etaSec)}';
      }
      return 'Mengunduh $pctText';
    }
    return 'Memproses media...';
  }

  String _formatEta(int seconds) {
    if (seconds < 60) return '${seconds}d';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m}m ${s}d';
  }

  Future<bool> openDownloadedItem(DownloadItem item) async {
    return _bridge.openFile(
      filePath: item.savedPath,
      contentUri: item.contentUri,
      mimeType: item.mimeType,
    );
  }

  Future<bool> shareDownloadedItem(DownloadItem item) async {
    return _bridge.shareFile(
      filePath: item.savedPath,
      contentUri: item.contentUri,
      mimeType: item.mimeType,
      title: item.title,
    );
  }

  Future<bool> openSubFile(SubFileTask file) async {
    return _bridge.openFile(
      filePath: file.savedPath,
      contentUri: file.contentUri,
      mimeType: file.mimeType,
    );
  }

  Future<bool> shareSubFile(SubFileTask file, {required String title}) async {
    return _bridge.shareFile(
      filePath: file.savedPath,
      contentUri: file.contentUri,
      mimeType: file.mimeType,
      title: title,
    );
  }

  Future<bool> setManagedFileAsWallpaper(
    ManagedFile file, {
    String target = 'crop',
  }) async {
    return _bridge.setWallpaper(
      filePath: file.savedPath,
      contentUri: file.contentUri,
      target: target,
    );
  }

  Future<bool> openManagedFile(ManagedFile file) async {
    return _bridge.openFile(
      filePath: file.savedPath,
      contentUri: file.contentUri,
      mimeType: file.mimeType,
    );
  }

  Future<bool> shareManagedFile(ManagedFile file) async {
    return _bridge.shareFile(
      filePath: file.savedPath,
      contentUri: file.contentUri,
      mimeType: file.mimeType,
      title: file.fileName,
    );
  }

  Future<bool> shareMultipleManagedFiles(List<ManagedFile> files) async {
    if (files.isEmpty) return false;
    if (files.length == 1) {
      return shareManagedFile(files.first);
    }
    return _bridge.shareMultipleFiles(files);
  }

  Future<bool> deleteManagedFile(ManagedFile file) async {
    final ok = await _bridge.deleteFile(
      filePath: file.savedPath,
      contentUri: file.contentUri,
    );
    await refreshManagedFiles();
    return ok;
  }

  Future<int> deleteMultipleManagedFiles(List<ManagedFile> files) async {
    if (files.isEmpty) return 0;
    final deletedCount = await _bridge.deleteMultipleFiles(files);
    await refreshManagedFiles();
    return deletedCount;
  }

  Future<int> unlockManagedFiles(List<ManagedFile> files) async {
    final targets = files.where((f) => f.isPrivate).toList(growable: false);
    if (targets.isEmpty) return 0;
    final count = await _bridge.unlockFiles(targets);
    await refreshManagedFiles();
    return count;
  }

  Future<int> lockManagedFiles(List<ManagedFile> files) async {
    final targets = files.where((f) => !f.isPrivate).toList(growable: false);
    if (targets.isEmpty) return 0;
    final count = await _bridge.lockFiles(targets);
    await refreshManagedFiles();
    return count;
  }

  Future<void> removeHistoryItem(
    DownloadItem item, {
    bool deleteFromDevice = false,
  }) async {
    if (deleteFromDevice) {
      if (item.subFiles.isNotEmpty) {
        for (final sub in item.subFiles) {
          if ((sub.savedPath != null && sub.savedPath!.isNotEmpty) ||
              (sub.contentUri != null && sub.contentUri!.isNotEmpty)) {
            await _bridge.deleteFile(
              filePath: sub.savedPath,
              contentUri: sub.contentUri,
            );
          }
        }
      } else {
        await _bridge.deleteFile(
          filePath: item.savedPath,
          contentUri: item.contentUri,
        );
      }
      unawaited(refreshManagedFiles());
    }
    _setItems(_items.where((i) => i.id != item.id).toList());
    _notifyImmediate();
    await _storage.saveHistory(_items);
  }

  Future<void> clearAllHistory() async {
    _setItems(
      _items
          .where((i) =>
              i.isActive || i.isPaused || i.status == DownloadStatus.failed)
          .toList(),
    );
    _notifyImmediate();
    await _storage.saveHistory(_items);
  }

  Future<void> updateSettings(AppSettings updated) async {
    _settings = updated;
    themeNotifier.value = updated.themeMode;
    _notifyImmediate();
    await _storage.saveSettings(updated);
  }

  Future<EngineUpdateResult> updateYtDlpEngine() async {
    _isUpdatingEngine = true;
    _notifyImmediate();
    try {
      final result = await _bridge.updateEngine(_settings.updateChannel);
      _engineStatus = EngineStatus(
        initialized: _engineStatus.initialized,
        version: result.version,
        ffmpegReady: _engineStatus.ffmpegReady,
        aria2cReady: _engineStatus.aria2cReady,
        downloadFolder: _engineStatus.downloadFolder,
      );
      return result;
    } finally {
      _isUpdatingEngine = false;
      _notifyImmediate();
    }
  }

  Future<void> refreshStorageInfo() async {
    try {
      final info = await _bridge.getStorageInfo();
      _cacheBytes = (info['cacheBytes'] as num?)?.toInt() ?? 0;
      _notifyImmediate();
    } catch (_) {}
  }

  Future<int> clearCache() async {
    final freed = await _bridge.clearCache();
    await refreshStorageInfo();
    return freed;
  }

  void _updateItem(
    String id,
    DownloadItem Function(DownloadItem) updater, {
    bool throttled = false,
  }) {
    if (_isDisposed) return;
    var index = _itemIndexById[id];
    if (index == null || index < 0 || index >= _items.length || _items[index].id != id) {
      index = _items.indexWhere((i) => i.id == id);
      if (index == -1) return;
      _itemIndexById[id] = index;
    }
    final prev = _items[index];
    final next = updater(prev);
    _items[index] = next;
    if (prev.isActive != next.isActive) {
      _activeDownloadCount += next.isActive ? 1 : -1;
      if (_activeDownloadCount < 0) _activeDownloadCount = 0;
    }
    if (prev.isPaused != next.isPaused) {
      _pausedDownloadCount += next.isPaused ? 1 : -1;
      if (_pausedDownloadCount < 0) _pausedDownloadCount = 0;
    }
    _itemsRevision++;
    if (throttled) {
      _notifyThrottled();
    } else {
      _notifyImmediate();
    }
  }

  void _notifyImmediate() {
    if (_isDisposed) return;
    _throttleNotifyTimer?.cancel();
    _throttleNotifyTimer = null;
    _hasPendingNotify = false;
    notifyListeners();
  }

  /// Adaptive UI notification load balancer: scales refresh interval smoothly
  /// as history grows so thousands of items never cause UI frame drops or ANR.
  Duration get _adaptiveThrottleInterval {
    final n = _items.length;
    if (n >= 1000) return const Duration(milliseconds: 900);
    if (n >= 300) return const Duration(milliseconds: 600);
    if (n >= 80) return const Duration(milliseconds: 380);
    return const Duration(milliseconds: 250);
  }

  void _notifyThrottled() {
    if (_isDisposed) return;
    if (_throttleNotifyTimer != null && _throttleNotifyTimer!.isActive) {
      _hasPendingNotify = true;
      return;
    }
    notifyListeners();
    _throttleNotifyTimer = Timer(_adaptiveThrottleInterval, () {
      _throttleNotifyTimer = null;
      if (_hasPendingNotify && !_isDisposed) {
        _hasPendingNotify = false;
        notifyListeners();
      }
    });
  }

  void _schedulePostDownloadSync({bool includeMediaRefresh = true}) {
    if (_isDisposed) return;
    _postSyncTimer?.cancel();

    final hasActive = _activeDownloadCount > 0;
    if (!hasActive) {
      _markersFlushTimer?.cancel();
      _markersFlushTimer = null;
      unawaited(_storage.saveDownloadedMarkers(_downloadedMarkers));
      unawaited(_runPostDownloadSync(
        includeMediaRefresh: includeMediaRefresh,
        forceMediaRefresh: true,
      ));
      return;
    }

    final flushInterval = _items.length >= 300
        ? const Duration(seconds: 14)
        : const Duration(seconds: 8);
    if (DateTime.now().difference(_lastHistoryFlush) > flushInterval) {
      _lastHistoryFlush = DateTime.now();
      unawaited(_storage.saveHistory(_items));
    }

    _postSyncTimer = Timer(const Duration(milliseconds: 2200), () {
      if (_isDisposed) return;
      unawaited(_runPostDownloadSync(
        includeMediaRefresh: includeMediaRefresh,
        forceMediaRefresh: false,
      ));
    });
  }

  Future<void> _runPostDownloadSync({
    bool includeMediaRefresh = true,
    bool forceMediaRefresh = false,
  }) async {
    _lastHistoryFlush = DateTime.now();
    try {
      await _storage.saveHistory(_items);
    } catch (_) {}
    if (includeMediaRefresh && !_isDisposed) {
      final now = DateTime.now();
      // Avoid rescanning thousands of files on MediaStore every 2s during bulk loads!
      if (forceMediaRefresh ||
          now.difference(_lastManagedFilesRefresh) >
              const Duration(seconds: 15)) {
        _lastManagedFilesRefresh = now;
        unawaited(refreshStorageInfo());
        unawaited(refreshManagedFiles());
      }
    }
  }

  String _sanitizeBaseName(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return 'all_download_media';
    return cleaned.length > 64 ? cleaned.substring(0, 64).trim() : cleaned;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _throttleNotifyTimer?.cancel();
    _postSyncTimer?.cancel();
    _markersFlushTimer?.cancel();
    _progressSub?.cancel();
    _shareSub?.cancel();
    for (final token in _directCancelTokens.values) {
      if (!token.isCancelled) token.cancel();
    }
    themeNotifier.dispose();
    super.dispose();
  }
}
