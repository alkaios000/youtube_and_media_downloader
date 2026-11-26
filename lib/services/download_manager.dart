import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/download_item.dart';
import '../models/managed_file.dart';
import '../models/media_info.dart';
import '../models/media_platform.dart';
import 'media_extractor_service.dart';
import 'native_bridge.dart';
import 'storage_service.dart';

/// Lightweight async semaphore to load-balance network & CPU-heavy downloads.
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
  static const int _directFileMaxConcurrency = 4;
  static const int _ytDlpMaxConcurrency = 1;
  static const int _bulkDirectTaskConcurrency = 3;

  final NativeBridge _bridge;
  final StorageService _storage;
  final MediaExtractorService _extractor;
  final Dio _dio;

  /// Separate notifier for theme so MaterialApp never rebuilds during downloads.
  final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.dark);

  final _AsyncSemaphore _directFilePool = _AsyncSemaphore(_directFileMaxConcurrency);
  final _AsyncSemaphore _ytDlpPool = _AsyncSemaphore(_ytDlpMaxConcurrency);

  EngineStatus _engineStatus = EngineStatus.initial();
  PermissionStatusInfo _permissionStatus = PermissionStatusInfo.unknown();
  AppSettings _settings = const AppSettings();
  List<DownloadItem> _items = [];
  List<ManagedFile> _managedFiles = [];
  Set<String> _downloadedMarkers = <String>{};

  bool _isInitializing = true;
  bool _isAnalyzing = false;
  bool _isUpdatingEngine = false;
  bool _isLoadingFiles = false;
  bool _permissionChecked = false;
  bool _instagramLoggedIn = false;
  bool _douyinLoggedIn = false;
  bool _facebookLoggedIn = false;
  bool _pixivLoggedIn = false;
  bool _isDisposed = false;
  String? _engineError;
  String? _analyzeError;
  MediaInfo? _currentPreview;
  int _cacheBytes = 0;

  final Map<String, CancelToken> _directCancelTokens = {};
  final Set<String> _cancelledTaskIds = {};
  StreamSubscription<NativeProgressEvent>? _progressSub;
  StreamSubscription<String>? _shareSub;
  Timer? _throttleNotifyTimer;
  bool _hasPendingNotify = false;
  Timer? _postSyncTimer;
  DateTime _lastHistoryFlush = DateTime.fromMillisecondsSinceEpoch(0);
  int _taskSeq = 0;

  void Function(String sharedText)? _onIncomingSharedLink;
  String? _pendingSharedText;

  void Function(String sharedText)? get onIncomingSharedLink => _onIncomingSharedLink;
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
        client.maxConnectionsPerHost = 6;
        client.idleTimeout = const Duration(seconds: 25);
        // Binary media streams (JPEG/PNG/MP4/MP3) are already compressed;
        // skipping gzip inspection reduces CPU overhead on mobile.
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
  List<ManagedFile> get managedFiles => List.unmodifiable(_managedFiles);
  Set<String> get downloadedMarkers => Set.unmodifiable(_downloadedMarkers);
  List<DownloadItem> get activeDownloads =>
      _items.where((i) => i.isActive).toList(growable: false);
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
  String? get engineError => _engineError;
  String? get analyzeError => _analyzeError;
  MediaInfo? get currentPreview => _currentPreview;
  int get cacheBytes => _cacheBytes;

  DownloadItem? findItemById(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

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
    _notifyImmediate();
    try {
      await _storage.saveDownloadedMarkers(_downloadedMarkers);
    } catch (_) {}
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
    final toRemove = keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toSet();
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

  Future<void> bootstrap() async {
    // 1. PRIORITY 0: Attach share stream & fetch any initial shared intent IMMEDIATELY
    // BEFORE waiting on preferences, permissions, WebView cookies, or yt-dlp/Python init!
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

    // 2. Load lightweight local SharedPreferences in parallel
    final localData = await Future.wait<dynamic>([
      _storage.loadSettings().catchError((_) => const AppSettings()),
      _storage.loadHistory().catchError((_) => <DownloadItem>[]),
      _storage.loadDownloadedMarkers().catchError((_) => null),
    ]);

    _settings = localData[0] as AppSettings;
    themeNotifier.value = _settings.themeMode;
    _items = localData[1] as List<DownloadItem>;

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

    _notifyImmediate();

    // 3. Fast permission check (< 2ms)
    await refreshPermissions();

    // 4. Warm up heavy native components strictly in the background so UI & Share stay instant!
    unawaited(_initEngineInBackground());
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 900), () {
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
      _notifyImmediate();
    } catch (_) {}
  }

  Future<void> refreshManagedFiles() async {
    if (_isLoadingFiles) return;
    _isLoadingFiles = true;
    _notifyImmediate();
    try {
      _managedFiles = await _bridge.listManagedFiles();
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
      final cookiesPath = await _storage.getCookiesFilePath(_settings.customCookies);
      final info = await _extractor.analyzeLink(
        rawInput: cleanUrl,
        cookiesPath: cookiesPath,
      );
      _currentPreview = info;
      _analyzeError = null;
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

  MediaFormatOption _closestVideoOption(List<MediaFormatOption> options, int targetHeight) {
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

  Future<DownloadItem> startDownload(
    MediaInfo info,
    MediaFormatOption option, {
    List<String> extraMarkerKeys = const [],
    bool markAlbumKey = true,
  }) async {
    if (_permissionChecked && !_permissionStatus.granted && _permissionStatus.sdkInt <= 28) {
      await requestStoragePermissions();
    }
    final taskId = _nextTaskId('dl');
    final markerKey = info.markerKey;
    final initialSubFiles = _buildInitialSubFiles(taskId, info, option);

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
    );

    _items = [initialItem, ..._items];
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

  /// Downloads ONLY the user-selected photos from a multi-photo post (Pixiv, X, IG, TikTok, Douyin).
  /// For Pixiv, any photo/album already marked downloaded is strictly skipped unless unmarked first.
  Future<int> downloadSelectedPhotos(
    MediaInfo info,
    List<SelectableMediaItem> selected,
  ) async {
    if (selected.isEmpty) return 0;
    if (_permissionChecked && !_permissionStatus.granted && _permissionStatus.sdkInt <= 28) {
      await requestStoragePermissions();
    }

    final isPixiv = info.platform == MediaPlatform.pixiv;
    if (isPixiv && isMarkedDownloaded(info.markerKey)) {
      return 0;
    }

    final eligible = isPixiv
        ? selected.where((item) => !isMarkedDownloaded(item.markerKey)).toList()
        : selected;
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

    // Mark parent album key only if ALL pages of this post will be downloaded
    final allPagesCovered = info.selectableItems.isEmpty ||
        info.selectableItems.every(
          (p) => extraKeys.contains(p.markerKey) || isMarkedDownloaded(p.markerKey),
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

  /// Bulk downloads selected items from a Profile or Playlist URL (Pixiv, YouTube, TikTok, IG, X, FB, Douyin).
  /// For Pixiv, any artwork already marked downloaded is strictly excluded unless its marker was removed first.
  Future<int> startBulkDownloads(
    MediaInfo collectionInfo,
    List<SelectableMediaItem> selected, {
    bool audioOnly = false,
  }) async {
    if (selected.isEmpty) return 0;
    if (_permissionChecked && !_permissionStatus.granted && _permissionStatus.sdkInt <= 28) {
      await requestStoragePermissions();
    }

    final isPixiv = collectionInfo.platform == MediaPlatform.pixiv;
    final eligible = isPixiv
        ? selected.where((sel) => !isMarkedDownloaded(sel.markerKey)).toList()
        : selected;
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
      final isDirect = (sel.pixivIllustId != null && sel.pixivIllustId!.isNotEmpty) ||
          (sel.engine == DownloadEngine.directHttp &&
              sel.directUrl != null &&
              sel.directUrl!.startsWith('http'));

      newItems.add(
        DownloadItem(
          id: taskId,
          sourceUrl: sel.sourcePostUrl ?? sel.directUrl ?? collectionInfo.originalUrl,
          markerKey: sel.markerKey,
          platform: collectionInfo.platform,
          title: sel.title,
          author: sel.author ?? collectionInfo.author,
          thumbnailUrl: sel.thumbnailUrl,
          formatLabel: isAudio ? 'Audio MP3 (Massal)' : 'Massal (${ext.toUpperCase()})',
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
        ),
      );

      if (isDirect) {
        directQueue.add((taskId, sel));
      } else {
        ytDlpQueue.add((taskId, sel));
      }
    }

    _items = [...newItems.reversed, ..._items];
    _notifyImmediate();

    if (directQueue.isNotEmpty) {
      unawaited(_processDirectBulkPool(collectionInfo, directQueue));
    }
    if (ytDlpQueue.isNotEmpty) {
      unawaited(_processYtDlpBulkQueue(collectionInfo, ytDlpQueue, audioOnly: audioOnly));
    }
    return eligible.length;
  }

  /// Concurrent worker pool (3 workers) for fast Pixiv & Direct HTTP bulk tasks.
  Future<void> _processDirectBulkPool(
    MediaInfo collectionInfo,
    List<(String, SelectableMediaItem)> queue,
  ) async {
    final pixivCookie = collectionInfo.platform == MediaPlatform.pixiv
        ? await _safeCookieHeader('https://www.pixiv.net/')
        : '';

    int cursor = 0;
    final workerCount = queue.length < _bulkDirectTaskConcurrency
        ? queue.length
        : _bulkDirectTaskConcurrency;

    Future<void> worker() async {
      while (true) {
        if (_isDisposed || cursor >= queue.length) return;
        final (taskId, sel) = queue[cursor++];

        if (_isTaskCancelled(taskId)) continue;

        final itemAuthor = sel.author ?? collectionInfo.author;
        final singleInfo = MediaInfo(
          originalUrl: sel.sourcePostUrl ?? sel.directUrl ?? collectionInfo.originalUrl,
          platform: collectionInfo.platform,
          title: sel.title,
          author: itemAuthor,
          thumbnailUrl: sel.thumbnailUrl,
          extractorLabel: collectionInfo.extractorLabel,
          options: const [],
        );

        // Pixiv artwork inside a profile: expand ALL original full-resolution pages!
        if (sel.pixivIllustId != null && sel.pixivIllustId!.isNotEmpty) {
          _updateItem(
            taskId,
            (item) => item.copyWith(
              status: DownloadStatus.downloading,
              statusText: 'Memuat daftar halaman Pixiv...',
            ),
          );

          final origUrls = await _extractor.directExtractors.fetchPixivIllustOriginalUrls(
            sel.pixivIllustId!,
            cookieHeader: pixivCookie,
          );
          if (_isTaskCancelled(taskId)) continue;

          if (origUrls.isEmpty) {
            _updateItem(
              taskId,
              (item) => item.copyWith(
                status: DownloadStatus.failed,
                statusText: 'Gagal mengambil halaman Pixiv',
                errorMessage:
                    'Karya mungkin khusus member/R-18 (login Pixiv di Pengaturan).',
                subFiles: item.subFiles
                    .map((s) => s.copyWith(
                          status: DownloadStatus.failed,
                          errorMessage: 'Halaman Pixiv tidak dapat diakses',
                        ))
                    .toList(growable: false),
              ),
            );
            _schedulePostDownloadSync(includeMediaRefresh: false);
            continue;
          }

          final ext = _detectExtFromUrlOrDefault(origUrls.first, 'jpg');
          final opt = MediaFormatOption(
            id: 'px_bulk_${sel.pixivIllustId}',
            label: origUrls.length > 1 ? '${origUrls.length} Halaman' : 'Original HD',
            subtitle: 'Pixiv',
            extension: ext,
            kind: MediaKind.image,
            engine: DownloadEngine.directHttp,
            directUrl: origUrls.first,
            galleryUrls: origUrls,
            headers: sel.headers,
          );
          await _runDirectHttpDownload(
            taskId,
            singleInfo,
            opt,
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
            galleryUrls: sel.kind == MediaKind.image ? [sel.directUrl!] : const [],
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

  /// Controlled sequential queue for heavy native yt-dlp/FFmpeg bulk items.
  Future<void> _processYtDlpBulkQueue(
    MediaInfo collectionInfo,
    List<(String, SelectableMediaItem)> queue, {
    required bool audioOnly,
  }) async {
    for (final (taskId, sel) in queue) {
      if (_isDisposed) return;
      if (_isTaskCancelled(taskId)) continue;

      final itemAuthor = sel.author ?? collectionInfo.author;
      final singleInfo = MediaInfo(
        originalUrl: sel.sourcePostUrl ?? sel.directUrl ?? collectionInfo.originalUrl,
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

  bool _isTaskCancelled(String taskId) {
    if (_cancelledTaskIds.contains(taskId)) return true;
    final item = findItemById(taskId);
    return item == null || item.status == DownloadStatus.cancelled;
  }

  Future<String> _safeCookieHeader(String url) async {
    try {
      return await _bridge.getCookieHeader(url);
    } catch (_) {
      return '';
    }
  }

  Future<void> _runYtDlpDownload(
    String taskId,
    MediaInfo info,
    MediaFormatOption option, {
    List<String> extraMarkerKeys = const [],
    bool markAlbumKey = true,
  }) async {
    await _ytDlpPool.run(() async {
      if (_isDisposed || _isTaskCancelled(taskId)) return;

      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: DownloadStatus.downloading,
          statusText: 'Memulai engine unduhan...',
          subFiles: item.subFiles.isEmpty
              ? [
                  SubFileTask(
                    id: '${taskId}_0',
                    fileName: '${_sanitizeBaseName(info.title)}.${option.extension}',
                    status: DownloadStatus.downloading,
                  ),
                ]
              : [
                  item.subFiles.first.copyWith(status: DownloadStatus.downloading),
                  ...item.subFiles.skip(1),
                ],
        ),
      );

      try {
        final cookiesPath = await _storage.getCookiesFilePath(_settings.customCookies);
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
          savedPath: saved.savedPath,
          contentUri: saved.contentUri,
          mimeType: saved.mimeType,
        );

        _updateItem(
          taskId,
          (item) => item.copyWith(
            status: DownloadStatus.completed,
            progress: 100,
            statusText: 'Tersimpan di ${saved.folderLabel}',
            savedPath: saved.savedPath,
            contentUri: saved.contentUri,
            fileName: saved.fileName,
            fileSize: saved.fileSize,
            mimeType: saved.mimeType,
            subFiles: [completedSub],
          ),
        );

        await markManyDownloaded([
          if (markAlbumKey) info.markerKey,
          ...extraMarkerKeys,
        ]);
        _schedulePostDownloadSync();
      } catch (e) {
        final rawMsg = e.toString();
        final isCancelled = rawMsg.contains('CANCELLED') || _isTaskCancelled(taskId);
        final cleanErr = rawMsg.replaceFirst('Exception: ', '').trim();
        _updateItem(
          taskId,
          (item) => item.copyWith(
            status: isCancelled ? DownloadStatus.cancelled : DownloadStatus.failed,
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

  /// High-speed concurrent Direct HTTP downloader with per-file live progress,
  /// rolling speed calculation, lightweight throttling, and automatic retry.
  Future<void> _runDirectHttpDownload(
    String taskId,
    MediaInfo info,
    MediaFormatOption option, {
    List<String> extraMarkerKeys = const [],
    bool markAlbumKey = true,
  }) async {
    if (_isDisposed || _isTaskCancelled(taskId)) return;

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

      // Initialize every individual SubFileTask upfront so Riwayat detail shows all files immediately!
      final subTasks = List<SubFileTask>.generate(totalFiles, (i) {
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

      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: DownloadStatus.downloading,
          progress: 0,
          statusText: totalFiles > 1
              ? 'Mengunduh 0/$totalFiles file...'
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
            statusLabel = 'Menyimpan ke folder ${info.platform.folderName}...';
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
              fileSize: totalDownloadedBytes > 0 ? totalDownloadedBytes : item.fileSize,
              subFiles: List<SubFileTask>.unmodifiable(subTasks),
            );
          },
          throttled: !immediate,
        );
      }

      // Download files concurrently through the shared global HTTP worker pool (max 4 streams)
      await Future.wait(
        List<Future<void>>.generate(totalFiles, (i) async {
          final targetUrl = urlsToDownload[i];
          final fileExt = _detectExtFromUrlOrDefault(targetUrl, option.extension);
          final fileName = subTasks[i].fileName;
          final tempPath = p.join(cacheDir.path, 'direct_${taskId}_$i.$fileExt');

          await _directFilePool.run(() async {
            if (cancelToken.isCancelled || _isTaskCancelled(taskId)) {
              subTasks[i] = subTasks[i].copyWith(
                status: DownloadStatus.cancelled,
                speedText: '',
              );
              return;
            }

            subTasks[i] = subTasks[i].copyWith(
              status: DownloadStatus.downloading,
              progress: 0,
            );
            syncParent();

            int lastTickMs = DateTime.now().millisecondsSinceEpoch;
            int lastTickBytes = 0;

            Future<void> performDownload() async {
              await _dio.download(
                targetUrl,
                tempPath,
                cancelToken: cancelToken,
                options: Options(
                  headers: option.headers,
                  followRedirects: true,
                  maxRedirects: 8,
                ),
                onReceiveProgress: (received, total) {
                  final nowMs = DateTime.now().millisecondsSinceEpoch;
                  final elapsedMs = nowMs - lastTickMs;
                  final isDone = total > 0 && received >= total;

                  // Only recompute & propagate at most every 220ms per file (huge CPU win!)
                  if (!isDone && elapsedMs < 220) return;

                  if (elapsedMs > 0) {
                    final deltaBytes = received - lastTickBytes;
                    if (deltaBytes >= 0) {
                      fileSpeedBps[i] = (deltaBytes * 1000.0) / elapsedMs;
                    }
                    lastTickMs = nowMs;
                    lastTickBytes = received;
                  }

                  final pct = total > 0 ? ((received / total) * 100.0).clamp(0.0, 100.0) : -1.0;
                  subTasks[i] = subTasks[i].copyWith(
                    status: DownloadStatus.downloading,
                    progress: pct,
                    downloadedBytes: received,
                    totalBytes: total > 0 ? total : subTasks[i].totalBytes,
                    speedText: fileSpeedBps[i] > 512 ? _formatSpeed(fileSpeedBps[i]) : '',
                  );
                  syncParent();
                },
              );
            }

            try {
              try {
                await performDownload();
              } on DioException catch (firstErr) {
                if (CancelToken.isCancel(firstErr) || cancelToken.isCancelled) {
                  rethrow;
                }
                // Automatic 1-time retry on transient network/429 glitches
                await Future<void>.delayed(const Duration(milliseconds: 700));
                if (cancelToken.isCancelled || _isTaskCancelled(taskId)) {
                  throw DioException.requestCancelled(
                    requestOptions: firstErr.requestOptions,
                    reason: 'Dibatalkan',
                  );
                }
                lastTickMs = DateTime.now().millisecondsSinceEpoch;
                lastTickBytes = 0;
                await performDownload();
              }

              if (cancelToken.isCancelled || _isTaskCancelled(taskId)) {
                subTasks[i] = subTasks[i].copyWith(
                  status: DownloadStatus.cancelled,
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

              final isPixivPrivate = info.platform == MediaPlatform.pixiv;
              final saved = await _bridge.saveFileToDownloads(
                sourcePath: tempPath,
                fileName: fileName,
                mimeType: _mimeForExtension(fileExt, option.kind),
                platformFolder: info.platform.folderName,
                creatorFolder: info.author,
                albumFolder: isPixivPrivate ? info.title : null,
                isPrivate: isPixivPrivate,
              );

              firstSaved ??= saved;
              lastSaved = saved;

              subTasks[i] = subTasks[i].copyWith(
                fileName: saved.fileName,
                status: DownloadStatus.completed,
                progress: 100,
                downloadedBytes: saved.fileSize,
                totalBytes: saved.fileSize,
                speedText: '',
                savedPath: saved.savedPath,
                contentUri: saved.contentUri,
                mimeType: saved.mimeType,
              );
              syncParent(immediate: true);
            } on DioException catch (e) {
              fileSpeedBps[i] = 0;
              final cancelled = CancelToken.isCancel(e) || cancelToken.isCancelled;
              subTasks[i] = subTasks[i].copyWith(
                status: cancelled ? DownloadStatus.cancelled : DownloadStatus.failed,
                speedText: '',
                errorMessage: cancelled ? null : (e.message ?? 'Koneksi terputus'),
              );
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
              final tempFile = File(tempPath);
              if (await tempFile.exists()) {
                await tempFile.delete().catchError((_) => tempFile);
              }
            }
          });
        }),
      );

      // Finalize overall DownloadItem state
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

      final completedSubs = subTasks.where((s) => s.status == DownloadStatus.completed).toList();
      final failedSubs = subTasks.where((s) => s.status == DownloadStatus.failed).toList();
      final totalSavedBytes = completedSubs.fold<int>(0, (acc, s) => acc + s.downloadedBytes);
      final representative = firstSaved ?? lastSaved;

      if (completedSubs.isNotEmpty && representative != null) {
        final String doneText;
        if (totalFiles == 1) {
          doneText = 'Tersimpan di ${representative.folderLabel}';
        } else if (failedSubs.isEmpty) {
          doneText = '${completedSubs.length} file tersimpan di ${representative.folderLabel}';
        } else {
          doneText =
              '${completedSubs.length}/$totalFiles file tersimpan (${failedSubs.length} gagal)';
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
          ),
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
    final idx = _items.indexWhere((i) => i.id == event.taskId);
    if (idx == -1) return;
    final current = _items[idx];
    if (!current.isActive) return;

    final statusLine = _prettifyYtDlpLine(event.line, event.progress, event.etaSeconds);
    final speedMatch = RegExp(r'at\s+([0-9.]+[KMG]i?B/s)', caseSensitive: false)
        .firstMatch(event.line);
    final speedText = speedMatch?.group(1) ?? '';

    final nextProgress =
        event.progress >= 0 ? event.progress.clamp(0.0, 100.0) : current.progress;
    final isMerging = event.line.toLowerCase().contains('[merger]') ||
        event.line.toLowerCase().contains('[extractaudio]');

    _updateItem(
      event.taskId,
      (item) {
        final updatedSubs = item.subFiles.isEmpty
            ? item.subFiles
            : [
                item.subFiles.first.copyWith(
                  status: isMerging ? DownloadStatus.saving : DownloadStatus.downloading,
                  progress: nextProgress,
                  speedText: speedText.isNotEmpty
                      ? speedText
                      : item.subFiles.first.speedText,
                ),
                ...item.subFiles.skip(1),
              ];
        return item.copyWith(
          status: isMerging ? DownloadStatus.saving : DownloadStatus.downloading,
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

  Future<void> cancelDownload(String taskId) async {
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
            .map((s) => s.isActive
                ? s.copyWith(status: DownloadStatus.cancelled, speedText: '')
                : s)
            .toList(growable: false),
      ),
    );
    _schedulePostDownloadSync(includeMediaRefresh: false);
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

  /// Unlocks private Pixiv files into public Android Gallery & WhatsApp (`Pictures/all_download/...`).
  Future<int> unlockManagedFiles(List<ManagedFile> files) async {
    final targets = files.where((f) => f.isPrivate).toList(growable: false);
    if (targets.isEmpty) return 0;
    final count = await _bridge.unlockFiles(targets);
    await refreshManagedFiles();
    return count;
  }

  /// Locks public files back into the app-private vault (hidden from Gallery & WhatsApp).
  Future<int> lockManagedFiles(List<ManagedFile> files) async {
    final targets = files.where((f) => !f.isPrivate).toList(growable: false);
    if (targets.isEmpty) return 0;
    final count = await _bridge.lockFiles(targets);
    await refreshManagedFiles();
    return count;
  }

  Future<void> removeHistoryItem(DownloadItem item, {bool deleteFromDevice = false}) async {
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
    _items = _items.where((i) => i.id != item.id).toList();
    _notifyImmediate();
    await _storage.saveHistory(_items);
  }

  Future<void> clearAllHistory() async {
    _items = _items.where((i) => i.isActive).toList();
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
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) return;
    _items[index] = updater(_items[index]);
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

  void _notifyThrottled() {
    if (_isDisposed) return;
    if (_throttleNotifyTimer != null && _throttleNotifyTimer!.isActive) {
      _hasPendingNotify = true;
      return;
    }
    notifyListeners();
    _throttleNotifyTimer = Timer(const Duration(milliseconds: 250), () {
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

    final hasActive = _items.any((i) => i.isActive);
    if (!hasActive) {
      unawaited(_runPostDownloadSync(includeMediaRefresh: includeMediaRefresh));
      return;
    }

    if (DateTime.now().difference(_lastHistoryFlush) > const Duration(seconds: 8)) {
      _lastHistoryFlush = DateTime.now();
      unawaited(_storage.saveHistory(_items));
    }

    _postSyncTimer = Timer(const Duration(milliseconds: 1800), () {
      if (_isDisposed) return;
      unawaited(_runPostDownloadSync(includeMediaRefresh: includeMediaRefresh));
    });
  }

  Future<void> _runPostDownloadSync({bool includeMediaRefresh = true}) async {
    _lastHistoryFlush = DateTime.now();
    try {
      await _storage.saveHistory(_items);
    } catch (_) {}
    if (includeMediaRefresh && !_isDisposed) {
      unawaited(refreshStorageInfo());
      unawaited(refreshManagedFiles());
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
    _progressSub?.cancel();
    _shareSub?.cancel();
    for (final token in _directCancelTokens.values) {
      if (!token.isCancelled) token.cancel();
    }
    themeNotifier.dispose();
    super.dispose();
  }
}
