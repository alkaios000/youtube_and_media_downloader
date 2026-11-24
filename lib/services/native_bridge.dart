import 'package:flutter/services.dart';

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
        downloadFolder: 'Download/all_download',
      );

  factory EngineStatus.fromMap(Map<dynamic, dynamic> map) {
    return EngineStatus(
      initialized: map['initialized'] as bool? ?? false,
      version: map['version']?.toString() ?? 'bundled',
      ffmpegReady: map['ffmpegReady'] as bool? ?? false,
      aria2cReady: map['aria2cReady'] as bool? ?? false,
      downloadFolder: map['downloadFolder']?.toString() ?? 'Download/all_download',
    );
  }
}

class SavedFileResult {
  final String savedPath;
  final String contentUri;
  final String fileName;
  final int fileSize;
  final String mimeType;

  const SavedFileResult({
    required this.savedPath,
    required this.contentUri,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
  });

  factory SavedFileResult.fromMap(Map<dynamic, dynamic> map) {
    return SavedFileResult(
      savedPath: map['savedPath']?.toString() ?? '',
      contentUri: map['contentUri']?.toString() ?? '',
      fileName: map['fileName']?.toString() ?? 'media.mp4',
      fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
      mimeType: map['mimeType']?.toString() ?? 'video/mp4',
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

  Future<SavedFileResult> downloadWithYtDlp({
    required String taskId,
    required String url,
    String? formatSelector,
    required bool audioOnly,
    required String audioFormat,
    String? cookiesPath,
    required bool useAria2c,
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
      },
    );
    if (result == null) {
      throw Exception('Gagal menerima hasil file unduhan.');
    }
    return SavedFileResult.fromMap(result);
  }

  Future<bool> cancelDownload(String taskId) async {
    final ok = await _channel.invokeMethod<bool>('cancelDownload', {
      'taskId': taskId,
    });
    return ok ?? false;
  }

  Future<SavedFileResult> saveFileToDownloads({
    required String sourcePath,
    required String fileName,
    String? mimeType,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'saveFileToDownloads',
      {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
      },
    );
    if (result == null) {
      throw Exception('Gagal menyimpan file ke penyimpanan publik.');
    }
    return SavedFileResult.fromMap(result);
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
}
