import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/download_item.dart';
import '../models/media_info.dart';
import '../models/media_platform.dart';
import 'media_extractor_service.dart';
import 'native_bridge.dart';
import 'storage_service.dart';

class DownloadManager extends ChangeNotifier {
  final NativeBridge _bridge;
  final StorageService _storage;
  final MediaExtractorService _extractor;
  final Dio _dio;

  EngineStatus _engineStatus = EngineStatus.initial();
  PermissionStatusInfo _permissionStatus = PermissionStatusInfo.unknown();
  AppSettings _settings = const AppSettings();
  List<DownloadItem> _items = [];

  bool _isInitializing = true;
  bool _isAnalyzing = false;
  bool _isUpdatingEngine = false;
  bool _permissionChecked = false;
  bool _instagramLoggedIn = false;
  bool _douyinLoggedIn = false;
  String? _engineError;
  String? _analyzeError;
  MediaInfo? _currentPreview;
  int _cacheBytes = 0;

  final Map<String, CancelToken> _directCancelTokens = {};
  StreamSubscription<NativeProgressEvent>? _progressSub;
  StreamSubscription<String>? _shareSub;
  void Function(String sharedText)? onIncomingSharedLink;

  DownloadManager({
    NativeBridge? bridge,
    StorageService? storage,
    Dio? dio,
  })  : _bridge = bridge ?? NativeBridge(),
        _storage = storage ?? StorageService(),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 25),
                receiveTimeout: const Duration(minutes: 10),
              ),
            ),
        _extractor = MediaExtractorService(
          bridge: bridge ?? NativeBridge(),
        );

  EngineStatus get engineStatus => _engineStatus;
  PermissionStatusInfo get permissionStatus => _permissionStatus;
  bool get permissionChecked => _permissionChecked;
  AppSettings get settings => _settings;
  List<DownloadItem> get items => List.unmodifiable(_items);
  List<DownloadItem> get activeDownloads =>
      _items.where((i) => i.isActive).toList(growable: false);
  List<DownloadItem> get historyItems =>
      _items.where((i) => !i.isActive).toList(growable: false);
  bool get isInitializing => _isInitializing;
  bool get isAnalyzing => _isAnalyzing;
  bool get isUpdatingEngine => _isUpdatingEngine;
  bool get instagramLoggedIn => _instagramLoggedIn;
  bool get douyinLoggedIn => _douyinLoggedIn;
  String? get engineError => _engineError;
  String? get analyzeError => _analyzeError;
  MediaInfo? get currentPreview => _currentPreview;
  int get cacheBytes => _cacheBytes;

  Future<void> bootstrap() async {
    try {
      _settings = await _storage.loadSettings();
    } catch (_) {
      _settings = const AppSettings();
    }
    try {
      _items = await _storage.loadHistory();
    } catch (_) {
      _items = [];
    }
    notifyListeners();

    try {
      _progressSub = _bridge.progressStream.listen(
        _handleNativeProgress,
        onError: (_) {},
      );
      _shareSub = _bridge.shareStream.listen(
        (sharedText) {
          onIncomingSharedLink?.call(sharedText);
        },
        onError: (_) {},
      );
    } catch (_) {}

    await refreshPermissions();
    await refreshBrowserSessions();

    try {
      _engineStatus = await _bridge.initEngine();
      _engineError = null;
      await refreshStorageInfo();
    } catch (e) {
      _engineError = e.toString();
    } finally {
      _isInitializing = false;
      notifyListeners();
    }

    // Check if app was launched via Android Share Sheet
    try {
      final initialShared = await _bridge.getInitialSharedText();
      if (initialShared != null && initialShared.trim().isNotEmpty) {
        onIncomingSharedLink?.call(initialShared);
      }
    } catch (_) {}
  }

  Future<PermissionStatusInfo> refreshPermissions() async {
    try {
      _permissionStatus = await _bridge.checkPermissions();
      _permissionChecked = true;
      notifyListeners();
    } catch (_) {}
    return _permissionStatus;
  }

  Future<PermissionStatusInfo> requestStoragePermissions() async {
    try {
      _permissionStatus = await _bridge.requestPermissions();
      _permissionChecked = true;
      notifyListeners();
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
      notifyListeners();
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
      notifyListeners();
    } catch (_) {}
  }

  void clearPreview() {
    _currentPreview = null;
    _analyzeError = null;
    notifyListeners();
  }

  Future<MediaInfo?> analyzeLink(String rawInput) async {
    final cleanUrl = UrlParser.extractUrl(rawInput);
    if (cleanUrl == null) {
      _analyzeError = 'Tautan tidak valid. Tempel link dari YouTube, TikTok, Douyin, Instagram, atau X.';
      _currentPreview = null;
      notifyListeners();
      return null;
    }

    _isAnalyzing = true;
    _analyzeError = null;
    _currentPreview = null;
    notifyListeners();

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
      notifyListeners();
    }
  }

  /// Picks the user's preferred default option from a MediaInfo and downloads immediately.
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

  Future<DownloadItem> startDownload(MediaInfo info, MediaFormatOption option) async {
    if (_permissionChecked && !_permissionStatus.granted && _permissionStatus.sdkInt <= 28) {
      await requestStoragePermissions();
    }
    final taskId = '${DateTime.now().millisecondsSinceEpoch}_${_items.length}';
    final initialItem = DownloadItem(
      id: taskId,
      sourceUrl: info.originalUrl,
      platform: info.platform,
      title: info.title,
      author: info.author,
      thumbnailUrl: info.thumbnailUrl,
      formatLabel: option.label,
      extension: option.extension,
      mediaKind: option.kind,
      status: DownloadStatus.downloading,
      progress: 0,
      statusText: 'Memulai unduhan...',
      createdAt: DateTime.now(),
    );

    _items = [initialItem, ..._items];
    notifyListeners();

    if (option.engine == DownloadEngine.directHttp) {
      unawaited(_runDirectHttpDownload(taskId, info, option));
    } else {
      unawaited(_runYtDlpDownload(taskId, info, option));
    }

    return initialItem;
  }

  Future<void> _runYtDlpDownload(
    String taskId,
    MediaInfo info,
    MediaFormatOption option,
  ) async {
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
        ),
      );
      await _storage.saveHistory(_items);
      await refreshStorageInfo();
    } catch (e) {
      final rawMsg = e.toString();
      final isCancelled = rawMsg.contains('CANCELLED');
      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: isCancelled ? DownloadStatus.cancelled : DownloadStatus.failed,
          statusText: isCancelled ? 'Dibatalkan' : 'Unduhan gagal',
          errorMessage: isCancelled
              ? null
              : rawMsg.replaceFirst('Exception: ', '').trim(),
        ),
      );
      await _storage.saveHistory(_items);
    }
  }

  Future<void> _runDirectHttpDownload(
    String taskId,
    MediaInfo info,
    MediaFormatOption option,
  ) async {
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

      SavedFileResult? lastSaved;
      int totalBytesSaved = 0;

      for (int i = 0; i < urlsToDownload.length; i++) {
        final targetUrl = urlsToDownload[i];
        final suffix = urlsToDownload.length > 1 ? '_${i + 1}' : '';
        final safeBase = _sanitizeBaseName(info.title);
        final fileName = '$safeBase$suffix.${option.extension}';
        final tempPath = p.join(cacheDir.path, 'direct_${taskId}_$i.${option.extension}');

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
            double pct;
            if (total > 0) {
              final singlePct = (received / total) * 100.0;
              pct = ((i + (singlePct / 100.0)) / urlsToDownload.length) * 100.0;
            } else {
              pct = -1;
            }
            final label = urlsToDownload.length > 1
                ? 'Mengunduh ${i + 1}/${urlsToDownload.length} (${formatBytes(received)})'
                : (total > 0
                    ? '${formatBytes(received)} / ${formatBytes(total)}'
                    : 'Mengunduh ${formatBytes(received)}...');
            _updateItem(
              taskId,
              (item) => item.copyWith(
                progress: pct,
                statusText: label,
              ),
            );
          },
        );

        _updateItem(
          taskId,
          (item) => item.copyWith(
            status: DownloadStatus.saving,
            statusText: urlsToDownload.length > 1
                ? 'Menyimpan file ${i + 1}/${urlsToDownload.length}...'
                : 'Menyimpan ke folder Download...',
          ),
        );

        lastSaved = await _bridge.saveFileToDownloads(
          sourcePath: tempPath,
          fileName: fileName,
          mimeType: option.mimeType,
        );
        totalBytesSaved += lastSaved.fileSize;

        // Clean temp file just in case native didn't delete it
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.delete().catchError((_) => tempFile);
        }
      }

      final finalSaved = lastSaved;
      if (finalSaved == null) {
        throw Exception('Gagal menyimpan file.');
      }

      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: DownloadStatus.completed,
          progress: 100,
          statusText: urlsToDownload.length > 1
              ? '${urlsToDownload.length} gambar tersimpan di ${finalSaved.folderLabel}'
              : 'Tersimpan di ${finalSaved.folderLabel}',
          savedPath: finalSaved.savedPath,
          contentUri: finalSaved.contentUri,
          fileName: finalSaved.fileName,
          fileSize: totalBytesSaved,
          mimeType: finalSaved.mimeType,
        ),
      );
      await _storage.saveHistory(_items);
      await refreshStorageInfo();
    } on DioException catch (e) {
      final cancelled = CancelToken.isCancel(e);
      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: cancelled ? DownloadStatus.cancelled : DownloadStatus.failed,
          statusText: cancelled ? 'Dibatalkan' : 'Gagal mengunduh file',
          errorMessage: cancelled ? null : (e.message ?? 'Koneksi terputus'),
        ),
      );
      await _storage.saveHistory(_items);
    } catch (e) {
      _updateItem(
        taskId,
        (item) => item.copyWith(
          status: DownloadStatus.failed,
          statusText: 'Unduhan gagal',
          errorMessage: e.toString().replaceFirst('Exception: ', ''),
        ),
      );
      await _storage.saveHistory(_items);
    } finally {
      _directCancelTokens.remove(taskId);
    }
  }

  void _handleNativeProgress(NativeProgressEvent event) {
    final idx = _items.indexWhere((i) => i.id == event.taskId);
    if (idx == -1) return;
    final current = _items[idx];
    if (!current.isActive) return;

    final statusLine = _prettifyYtDlpLine(event.line, event.progress, event.etaSeconds);
    _updateItem(
      event.taskId,
      (item) => item.copyWith(
        progress: event.progress >= 0 ? event.progress.clamp(0, 100) : item.progress,
        etaSeconds: event.etaSeconds >= 0 ? event.etaSeconds : item.etaSeconds,
        statusText: statusLine,
      ),
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
    if (lower.contains('[extractaudio]') || lower.contains('destination:') && lower.contains('.mp3')) {
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
    final directToken = _directCancelTokens[taskId];
    if (directToken != null && !directToken.isCancelled) {
      directToken.cancel('Dibatalkan oleh pengguna');
    } else {
      await _bridge.cancelDownload(taskId);
    }
    _updateItem(
      taskId,
      (item) => item.copyWith(
        status: DownloadStatus.cancelled,
        statusText: 'Dibatalkan',
      ),
    );
    await _storage.saveHistory(_items);
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

  Future<void> removeHistoryItem(DownloadItem item, {bool deleteFromDevice = false}) async {
    if (deleteFromDevice) {
      await _bridge.deleteFile(
        filePath: item.savedPath,
        contentUri: item.contentUri,
      );
    }
    _items = _items.where((i) => i.id != item.id).toList();
    notifyListeners();
    await _storage.saveHistory(_items);
  }

  Future<void> clearAllHistory() async {
    _items = _items.where((i) => i.isActive).toList();
    notifyListeners();
    await _storage.saveHistory(_items);
  }

  Future<void> updateSettings(AppSettings updated) async {
    _settings = updated;
    notifyListeners();
    await _storage.saveSettings(updated);
  }

  Future<EngineUpdateResult> updateYtDlpEngine() async {
    _isUpdatingEngine = true;
    notifyListeners();
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
      notifyListeners();
    }
  }

  Future<void> refreshStorageInfo() async {
    try {
      final info = await _bridge.getStorageInfo();
      _cacheBytes = (info['cacheBytes'] as num?)?.toInt() ?? 0;
      notifyListeners();
    } catch (_) {}
  }

  Future<int> clearCache() async {
    final freed = await _bridge.clearCache();
    await refreshStorageInfo();
    return freed;
  }

  void _updateItem(String id, DownloadItem Function(DownloadItem) updater) {
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) return;
    final copy = List<DownloadItem>.from(_items);
    copy[index] = updater(copy[index]);
    _items = copy;
    notifyListeners();
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
    _progressSub?.cancel();
    _shareSub?.cancel();
    for (final token in _directCancelTokens.values) {
      if (!token.isCancelled) token.cancel();
    }
    super.dispose();
  }
}
