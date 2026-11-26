import 'media_platform.dart';

/// Persists the canonical profile URL per (platform, artist/creator folder) so
/// users can 1-tap "Lanjut Unduh / Cek Karya Baru" directly from the File tab.
class CreatorProfileRecord {
  final MediaPlatform platform;
  final String creatorFolder;
  final String displayName;
  final String profileUrl;
  final DateTime lastSyncedAt;

  const CreatorProfileRecord({
    required this.platform,
    required this.creatorFolder,
    required this.displayName,
    required this.profileUrl,
    required this.lastSyncedAt,
  });

  String get lookupKey => buildLookupKey(platform.folderName, creatorFolder);

  static String buildLookupKey(String platformFolder, String creatorFolder) {
    final p = platformFolder.trim().toLowerCase();
    final c = sanitizeCreatorFolderKey(creatorFolder);
    return '$p::$c';
  }

  /// Matches Android MediaEngineBridge.sanitizeFolderSegment so saved profiles
  /// always map cleanly onto their real folder names in the File tab.
  static String sanitizeCreatorFolderKey(String raw) {
    final cleaned = raw
        .trim()
        .replaceFirst(RegExp(r'^@+'), '')
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^\.+|\.+$'), '');
    final clipped = cleaned.length > 48 ? cleaned.substring(0, 48).trim() : cleaned;
    return (clipped.isEmpty ? 'umum' : clipped).toLowerCase();
  }

  CreatorProfileRecord copyWith({
    String? displayName,
    String? profileUrl,
    DateTime? lastSyncedAt,
  }) {
    return CreatorProfileRecord(
      platform: platform,
      creatorFolder: creatorFolder,
      displayName: displayName ?? this.displayName,
      profileUrl: profileUrl ?? this.profileUrl,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'platform': platform.name,
      'creatorFolder': creatorFolder,
      'displayName': displayName,
      'profileUrl': profileUrl,
      'lastSyncedAt': lastSyncedAt.toIso8601String(),
    };
  }

  factory CreatorProfileRecord.fromJson(Map<String, dynamic> json) {
    return CreatorProfileRecord(
      platform: MediaPlatformMeta.fromKey(json['platform']?.toString()),
      creatorFolder: json['creatorFolder']?.toString() ?? 'Umum',
      displayName: json['displayName']?.toString() ??
          json['creatorFolder']?.toString() ??
          'Umum',
      profileUrl: json['profileUrl']?.toString() ?? '',
      lastSyncedAt:
          DateTime.tryParse(json['lastSyncedAt']?.toString() ?? '') ??
              DateTime.now(),
    );
  }
}
