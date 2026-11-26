import 'package:flutter/services.dart';

import '../models/managed_file.dart';

class EngineStatus {
  final bool initialized;
  final String version;
  final bool ffmpegReady;
  final bool aria2cReady;
  final String downloadFolder;

  const EngineStatus({
    required this.initialized,
    required this.version,
    required this.ffmpegReady,
    required this.aria2cReady,
    required this.downloadFolder,
  });

  factory EngineStatus.initial() => const EngineStatus(
        initialized: false,
        version: 'memuat...',
        ffmpegReady: false,
        aria2cReady: false,
        downloadFolder: 'Pictures/all_download/<Aplikasi>/<Username>',
      );

  factory EngineStatus.fromMap(Map<dynamic, dynamic> map) {
    return EngineStatus(
      initialized: map['initialized'] as bool? ?? false,
      version: map['version']?.toString() ?? 'bundled',
      ffmpegReady: map['ffmpegReady'] as bool? ?? false,
      aria2cReady: map['aria2cReady'] as bool? ?? false,
      downloadFolder: map['downloadFolder']?.toString() ??
          'Pictures/all_download/<Aplikasi>/<Username>',
    );
  }
}

class SavedFileResult {
  final String savedPath;
  final String contentUri;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final String folderLabel;
  final String platformFolder;
  final String creatorFolder;
  final String albumFolder;
  final bool isPrivate;
  final bool skipped;

  const SavedFileResult({
    required this.savedPath,
    required this.contentUri,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.folderLabel,
    required this.platformFolder,
    required this.creatorFolder,
    this.albumFolder = '',
    this.isPrivate = false,
    this.skipped = false,
  });

  factory SavedFileResult.fromMap(Map<dynamic, dynamic> map) {
    return SavedFileResult(
      savedPath: map['savedPath']?.toString() ?? '',
      contentUri: map['contentUri']?.toString() ?? '',
      fileName: map['fileName']?.toString() ?? 'media.mp4',
      fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
      mimeType: map['mimeType']?.toString() ?? 'video/mp4',
      folderLabel: map['folderLabel']?.toString() ?? 'Pictures/all_download',
      platformFolder: map['platformFolder']?.toString() ?? 'Lainnya',
      creatorFolder: map['creatorFolder']?.toString() ?? 'Umum',
      albumFolder: map['albumFolder']?.toString() ?? '',
      isPrivate: map['isPrivate'] as bool? ?? false,
      skipped: map['skipped'] as bool? ?? false,
    );
  }
}

class NativeProgressEvent {
  final String taskId;
  final double progress;
  final int etaSeconds;
  final String line;

  const NativeProgressEvent({
    required this.taskId,
    required this.progress,
    required this.etaSeconds,
    required this.line,
  });

  factory NativeProgressEvent.fromMap(Map<dynamic, dynamic> map) {
    return NativeProgressEvent(
      taskId: map['taskId']?.toString() ?? '',
      progress: (map['progress'] as num?)?.toDouble() ?? -1,
      etaSeconds: (map['etaSeconds'] as num?)?.toInt() ?? -1,
      line: map['line']?.toString() ?? '',
    );
  }
}

class EngineUpdateResult {
  final String status;
  final bool updated;
  final String version;

  const EngineUpdateResult({
    required this.status,
    required this.updated,
    required this.version,
  });
}

class PermissionStatusInfo {
  final bool granted;
  final bool permanentlyDenied;
  final int sdkInt;
  final List<String> missing;

  const PermissionStatusInfo({
    required this.granted,
    required this.permanentlyDenied,
    required this.sdkInt,
    required this.missing,
  });

  factory PermissionStatusInfo.unknown() => const PermissionStatusInfo(
        granted: true,
        permanentlyDenied: false,
        sdkInt: 33,
        missing: [],
      );

  factory PermissionStatusInfo.fromMap(Map<dynamic, dynamic> map) {
    return PermissionStatusInfo(
      granted: map['granted'] as bool? ?? false,
      permanentlyDenied: map['permanentlyDenied'] as bool? ?? false,
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 33,
      missing: (map['missing'] as List?)
              ?.map((e) => e.toString())
              .toList(growable: false) ??
          const [],
    );
  }
}

class SniffedMediaResult {
  final String finalUrl;
  final String title;
  final String author;
  final String thumbnail;
  final List<String> videos;
  final List<String> images;
  final String cookies;
  final String userAgent;

  const SniffedMediaResult({
    required this.finalUrl,
    required this.title,
    required this.author,
    required this.thumbnail,
    required this.videos,
    required this.images,
    required this.cookies,
    required this.userAgent,
  });

  factory SniffedMediaResult.fromMap(Map<dynamic, dynamic> map) {
    return SniffedMediaResult(
      finalUrl: map['finalUrl']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      author: map['author']?.toString() ?? '',
      thumbnail: map['thumbnail']?.toString() ?? '',
      videos: (map['videos'] as List?)
              ?.map((e) => e.toString())
              .where((u) => u.startsWith('http'))
              .toList(growable: false) ??
          const [],
      images: (map['images'] as List?)
              ?.map((e) => e.toString())
              .where((u) => u.startsWith('http'))
              .toList(growable: false) ??
          const [],
      cookies: map['cookies']?.toString() ?? '',
      userAgent: map['userAgent']?.toString() ?? '',
    );
  }
}

class SniffedProfileItem {
  final String id;
  final String url;
  final String title;
  final String thumbnail;
  final String badge;
  final String kind;
  final String author;

  const SniffedProfileItem({
    required this.id,
    required this.url,
    required this.title,
    required this.thumbnail,
    required this.badge,
    required this.kind,
    required this.author,
  });

  factory SniffedProfileItem.fromMap(Map<dynamic, dynamic> map) {
    return SniffedProfileItem(
      id: map['id']?.toString() ?? '',
      url: map['url']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      thumbnail: map['thumbnail']?.toString() ?? '',
      badge: map['badge']?.toString() ?? '',
      kind: map['kind']?.toString() ?? 'video',
      author: map['author']?.toString() ?? '',
    );
  }
}

class SniffedProfileResult {
  final String finalUrl;
  final String creator;
  final List<SniffedProfileItem> items;

  const SniffedProfileResult({
    required this.finalUrl,
    required this.creator,
    required this.items,
  });

  factory SniffedProfileResult.fromMap(Map<dynamic, dynamic> map) {
    final rawList = map['items'] as List?;
    final parsed = rawList
            ?.whereType<Map>()
            .map(SniffedProfileItem.fromMap)
            .where((e) => e.url.startsWith('http'))
            .toList(growable: false) ??
        const <SniffedProfileItem>[];
    return SniffedProfileResult(
      finalUrl: map['finalUrl']?.toString() ?? '',
      creator: map['creator']?.toString() ?? '',
      items: parsed,
    );
  }
}

class NativeBridge {
  static const MethodChannel _channel =
      MethodChannel('com.linkdrop.downloader/engine');
  static const EventChannel _progressChannel =
      EventChannel('com.linkdrop.downloader/progress');
  static const EventChannel _shareChannel =
      EventChannel('com.linkdrop.downloader/share');

  Stream<NativeProgressEvent>? _progressStream;
  Stream<String>? _shareStream;

  Stream<NativeProgressEvent> get progressStream {
    _progressStream ??= _progressChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => NativeProgressEvent.fromMap(event as Map));
    return _progressStream!;
  }

  Stream<String> get shareStream {
    _shareStream ??= _shareChannel
        .receiveBroadcastStream()
        .map((event) => event?.toString() ?? '')
        .where((text) => text.isNotEmpty);
    return _shareStream!;
  }

  Future<EngineStatus> initEngine() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('initEngine');
    if (result == null) return EngineStatus.initial();
    return EngineStatus.fromMap(result);
  }

  Future<PermissionStatusInfo> checkPermissions() async {
    final result =
        await _channel.invokeMethod<Map<dynamic, dynamic>>('checkPermissions');
    if (result == null) return PermissionStatusInfo.unknown();
    return PermissionStatusInfo.fromMap(result);
  }

  Future<PermissionStatusInfo> requestPermissions() async {
    final result =
        await _channel.invokeMethod<Map<dynamic, dynamic>>('requestPermissions');
    if (result == null) return PermissionStatusInfo.unknown();
    return PermissionStatusInfo.fromMap(result);
  }

  Future<bool> openAppSettings() async {
    final ok = await _channel.invokeMethod<bool>('openAppSettings');
    return ok ?? false;
  }

  Future<SniffedMediaResult> sniffMedia({
    required String url,
    required String platform,
    int timeoutMs = 16000,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'sniffMedia',
      {
        'url': url,
        'platform': platform,
        'timeoutMs': timeoutMs,
      },
    );
    if (result == null) {
      throw Exception('Browser extractor tidak mengembalikan hasil.');
    }
    return SniffedMediaResult.fromMap(result);
  }

  Future<SniffedProfileResult> sniffProfileItems({
    required String url,
    required String platform,
    int timeoutMs = 28000,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'sniffProfileItems',
      {
        'url': url,
        'platform': platform,
        'timeoutMs': timeoutMs,
      },
    );
    if (result == null) {
      throw Exception('Tidak ada item profil yang diterima dari browser.');
    }
    return SniffedProfileResult.fromMap(result);
  }

  Future<bool> openBrowserLogin(String platform) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'openBrowserLogin',
      {'platform': platform},
    );
    return result?['saved'] as bool? ?? false;
  }

  Future<Map<String, bool>> getBrowserSessionStatus() async {
    final result = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('getBrowserSessionStatus');
    return {
      'instagram': result?['instagram'] as bool? ?? false,
      'douyin': result?['douyin'] as bool? ?? false,
      'facebook': result?['facebook'] as bool? ?? false,
      'pixiv': result?['pixiv'] as bool? ?? false,
      'tiktok': result?['tiktok'] as bool? ?? false,
    };
  }

  Future<String> getCookieHeader(String url) async {
    final res = await _channel.invokeMethod<String>('getCookieHeader', {'url': url});
    return res ?? '';
  }

  Future<bool> clearBrowserSessions() async {
    final ok = await _channel.invokeMethod<bool>('clearBrowserSessions');
    return ok ?? false;
  }

  Future<EngineUpdateResult> updateEngine(String channel) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'updateEngine',
      {'channel': channel},
    );
    return EngineUpdateResult(
      status: result?['status']?.toString() ?? 'DONE',
      updated: result?['updated'] as bool? ?? false,
      version: result?['version']?.toString() ?? 'unknown',
    );
  }

  Future<String> extractInfo({
    required String url,
    String? cookiesPath,
  }) async {
    final result = await _channel.invokeMethod<String>('extractInfo', {
      'url': url,
      'cookiesPath': cookiesPath,
    });
    if (result == null || result.trim().isEmpty) {
      throw Exception('Engine tidak mengembalikan informasi media.');
    }
    return result;
  }

  Future<String> extractProfileItems({
    required String url,
    String? cookiesPath,
  }) async {
    final result = await _channel.invokeMethod<String>('extractProfileItems', {
      'url': url,
      'cookiesPath': cookiesPath,
    });
    if (result == null || result.trim().isEmpty) {
      throw Exception('Tidak ada daftar media ditemukan pada profil ini.');
    }
    return result;
  }

  Future<SavedFileResult> downloadWithYtDlp({
    required String taskId,
    required String url,
    String? formatSelector,
    required bool audioOnly,
    required String audioFormat,
    String? cookiesPath,
    required bool useAria2c,
    required String platformFolder,
    required String creatorFolder,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'downloadWithYtDlp',
      {
        'taskId': taskId,
        'url': url,
        'formatSelector': formatSelector,
        'audioOnly': audioOnly,
        'audioFormat': audioFormat,
        'cookiesPath': cookiesPath,
        'useAria2c': useAria2c,
        'platformFolder': platformFolder,
        'creatorFolder': creatorFolder,
      },
    );
    if (result == null) {
      throw Exception('Gagal menerima hasil file unduhan.');
    }
    return SavedFileResult.fromMap(result);
  }

  Future<bool> pauseDownload(String taskId) async {
    final ok = await _channel.invokeMethod<bool>('pauseDownload', {
      'taskId': taskId,
    });
    return ok ?? false;
  }

  Future<bool> cancelDownload(String taskId) async {
    final ok = await _channel.invokeMethod<bool>('cancelDownload', {
      'taskId': taskId,
    });
    return ok ?? false;
  }

  Future<SavedFileResult> convertUgoiraZip({
    required String zipPath,
    required List<Map<String, dynamic>> frames,
    required String outputFormat,
    required String fileName,
    required String platformFolder,
    required String creatorFolder,
    String? albumFolder,
    bool isPrivate = true,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'convertUgoiraZip',
      {
        'zipPath': zipPath,
        'frames': frames,
        'outputFormat': outputFormat,
        'fileName': fileName,
        'platformFolder': platformFolder,
        'creatorFolder': creatorFolder,
        'albumFolder': albumFolder,
        'isPrivate': isPrivate,
      },
    );
    if (result == null) {
      throw Exception('Gagal mengonversi animasi Ugoira.');
    }
    return SavedFileResult.fromMap(result);
  }

  Future<SavedFileResult> saveFileToDownloads({
    required String sourcePath,
    required String fileName,
    String? mimeType,
    required String platformFolder,
    required String creatorFolder,
    String? albumFolder,
    bool isPrivate = false,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'saveFileToDownloads',
      {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
        'platformFolder': platformFolder,
        'creatorFolder': creatorFolder,
        'albumFolder': albumFolder,
        'isPrivate': isPrivate,
      },
    );
    if (result == null) {
      throw Exception('Gagal menyimpan file ke penyimpanan.');
    }
    return SavedFileResult.fromMap(result);
  }

  Future<List<ManagedFile>> listManagedFiles() async {
    final result = await _channel.invokeMethod<List<dynamic>>('listManagedFiles');
    if (result == null) return const [];
    return result
        .whereType<Map>()
        .map(ManagedFile.fromMap)
        .toList(growable: false);
  }

  Future<bool> setWallpaper({
    String? filePath,
    String? contentUri,
    String target = 'home',
    double? cropLeft,
    double? cropTop,
    double? cropWidth,
    double? cropHeight,
  }) async {
    final ok = await _channel.invokeMethod<bool>('setWallpaper', {
      'filePath': filePath,
      'contentUri': contentUri,
      'target': target,
      'cropLeft': ?cropLeft,
      'cropTop': ?cropTop,
      'cropWidth': ?cropWidth,
      'cropHeight': ?cropHeight,
    });
    return ok ?? false;
  }

  Future<bool> openFile({
    String? filePath,
    String? contentUri,
    String? mimeType,
  }) async {
    final ok = await _channel.invokeMethod<bool>('openFile', {
      'filePath': filePath,
      'contentUri': contentUri,
      'mimeType': mimeType,
    });
    return ok ?? false;
  }

  Future<bool> shareFile({
    String? filePath,
    String? contentUri,
    String? mimeType,
    String? title,
  }) async {
    final ok = await _channel.invokeMethod<bool>('shareFile', {
      'filePath': filePath,
      'contentUri': contentUri,
      'mimeType': mimeType,
      'title': title,
    });
    return ok ?? false;
  }

  Future<bool> shareMultipleFiles(List<ManagedFile> files) async {
    if (files.isEmpty) return false;
    final payload = files
        .map((f) => <String, String>{
              'filePath': f.savedPath,
              'contentUri': f.contentUri,
              'mimeType': f.mimeType,
              'title': f.fileName,
            })
        .toList(growable: false);
    final ok = await _channel.invokeMethod<bool>('shareMultipleFiles', {
      'items': payload,
    });
    return ok ?? false;
  }

  Future<bool> deleteFile({
    String? filePath,
    String? contentUri,
  }) async {
    final ok = await _channel.invokeMethod<bool>('deleteFile', {
      'filePath': filePath,
      'contentUri': contentUri,
    });
    return ok ?? false;
  }

  Future<int> deleteMultipleFiles(List<ManagedFile> files) async {
    if (files.isEmpty) return 0;
    final payload = files
        .map((f) => <String, String>{
              'filePath': f.savedPath,
              'contentUri': f.contentUri,
            })
        .toList(growable: false);
    final count = await _channel.invokeMethod<int>('deleteMultipleFiles', {
      'items': payload,
    });
    return count ?? 0;
  }

  Future<int> unlockFiles(List<ManagedFile> files) async {
    final targets = files.where((f) => f.isPrivate).toList(growable: false);
    if (targets.isEmpty) return 0;
    final payload = targets
        .map((f) => <String, dynamic>{
              'filePath': f.savedPath,
              'contentUri': f.contentUri,
              'fileName': f.fileName,
              'mimeType': f.mimeType,
              'platformFolder': f.platformFolder,
              'creatorFolder': f.creatorFolder,
              'albumFolder': f.effectiveAlbumName,
              'isPrivate': true,
            })
        .toList(growable: false);
    final count = await _channel.invokeMethod<int>('unlockFiles', {
      'items': payload,
    });
    return count ?? 0;
  }

  Future<int> lockFiles(List<ManagedFile> files) async {
    final targets = files.where((f) => !f.isPrivate).toList(growable: false);
    if (targets.isEmpty) return 0;
    final payload = targets
        .map((f) => <String, dynamic>{
              'filePath': f.savedPath,
              'contentUri': f.contentUri,
              'fileName': f.fileName,
              'mimeType': f.mimeType,
              'platformFolder': f.platformFolder,
              'creatorFolder': f.creatorFolder,
              'albumFolder': f.effectiveAlbumName,
              'isPrivate': false,
            })
        .toList(growable: false);
    final count = await _channel.invokeMethod<int>('lockFiles', {
      'items': payload,
    });
    return count ?? 0;
  }

  Future<bool> fileExists({
    String? filePath,
    String? contentUri,
  }) async {
    final ok = await _channel.invokeMethod<bool>('fileExists', {
      'filePath': filePath,
      'contentUri': contentUri,
    });
    return ok ?? false;
  }

  Future<SavedFileResult?> findExistingFile({
    required String fileName,
    String? mimeType,
    required String platformFolder,
    required String creatorFolder,
    String? albumFolder,
    bool checkPrivateVault = true,
  }) async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'findExistingFile',
      {
        'fileName': fileName,
        'mimeType': mimeType,
        'platformFolder': platformFolder,
        'creatorFolder': creatorFolder,
        'albumFolder': albumFolder,
        'checkPrivateVault': checkPrivateVault,
      },
    );
    if (res == null) return null;
    return SavedFileResult.fromMap(res);
  }

  Future<String?> getInitialSharedText() async {
    return _channel.invokeMethod<String>('getInitialSharedText');
  }

  Future<Map<String, dynamic>> getStorageInfo() async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('getStorageInfo');
    return res?.map((k, v) => MapEntry(k.toString(), v)) ?? {};
  }

  Future<int> clearCache() async {
    final bytes = await _channel.invokeMethod<int>('clearCache');
    return bytes ?? 0;
  }

  Future<bool> exportBackupFile({
    required String jsonContent,
    required String fileName,
  }) async {
    final ok = await _channel.invokeMethod<bool>('exportBackupFile', {
      'jsonContent': jsonContent,
      'fileName': fileName,
    });
    return ok ?? false;
  }

  Future<String?> importBackupFile() async {
    return _channel.invokeMethod<String>('importBackupFile');
  }
}
