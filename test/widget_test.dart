import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkdrop_downloader/models/app_settings.dart';
import 'package:linkdrop_downloader/models/creator_profile.dart';
import 'package:linkdrop_downloader/models/download_item.dart';
import 'package:linkdrop_downloader/models/managed_file.dart';
import 'package:linkdrop_downloader/models/media_info.dart';
import 'package:linkdrop_downloader/models/media_metadata.dart';
import 'package:linkdrop_downloader/models/media_platform.dart';
import 'package:linkdrop_downloader/screens/curated_catalog_screen.dart';
import 'package:linkdrop_downloader/screens/downloads_screen.dart';
import 'package:linkdrop_downloader/screens/files_screen.dart';
import 'package:linkdrop_downloader/screens/home_shell.dart';
import 'package:linkdrop_downloader/screens/settings_screen.dart';
import 'package:linkdrop_downloader/screens/trash_screen.dart';
import 'package:linkdrop_downloader/services/direct_extractors.dart';
import 'package:linkdrop_downloader/services/download_manager.dart';
import 'package:linkdrop_downloader/services/native_bridge.dart';
import 'package:linkdrop_downloader/services/storage_service.dart';
import 'package:linkdrop_downloader/theme/app_theme.dart';
import 'package:linkdrop_downloader/widgets/app_feedback.dart';
import 'package:linkdrop_downloader/widgets/file_gallery_viewer.dart';
import 'package:linkdrop_downloader/widgets/media_preview_card.dart';
import 'package:linkdrop_downloader/widgets/pixiv_album_viewer.dart';
import 'package:linkdrop_downloader/widgets/route_aware_listener.dart';
import 'package:linkdrop_downloader/widgets/security_lock_screen.dart';
import 'package:linkdrop_downloader/widgets/sharp_original_image.dart';
import 'package:linkdrop_downloader/widgets/tag_albums_screen.dart';
import 'package:linkdrop_downloader/widgets/video_first_frame_thumbnail.dart';

class _MemoryStorageService extends StorageService {
  @override
  Future<void> saveHistory(List<DownloadItem> items) async {}

  @override
  Future<void> saveDownloadedMarkers(Set<String> markers) async {}

  @override
  Future<void> saveCreatorProfiles(List<CreatorProfileRecord> profiles) async {}

  @override
  Future<void> saveAlbumMetadata(Map<String, AlbumMetadata> metadata) async {}

  @override
  Future<void> savePhotoRatings(Map<String, ContentRating> ratings) async {}

  @override
  Future<void> saveCuratedCatalog(
    Map<String, CuratedWorkRecord> catalog,
  ) async {}

  @override
  Future<void> saveManagedFilesCache(List<ManagedFile> files) async {}

  @override
  Future<void> saveManagedFilesCacheRaw(String packedTsv) async {}

  @override
  Future<List<ManagedFile>> loadManagedFilesCache() async => const [];

  @override
  Future<void> saveSettings(AppSettings settings) async {}

  @override
  Future<void> syncCookiesFile(String cookiesContent) async {}
}

class _FakeFilesManager extends DownloadManager {
  final List<ManagedFile> _fakeFiles;
  final Map<String, CreatorProfileRecord> _fakeProfiles;
  final List<DownloadItem> fakeItems;
  final List<TrashItem> _fakeTrash = [];
  final Map<String, ManagedFile> _trashedOriginals = {};

  _FakeFilesManager(
    List<ManagedFile> fakeFiles,
    this._fakeProfiles, {
    this.fakeItems = const [],
  })  : _fakeFiles = List<ManagedFile>.from(fakeFiles),
        super(storage: _MemoryStorageService());

  @override
  List<ManagedFile> get managedFiles => _fakeFiles;

  @override
  List<TrashItem> get trashItems => List<TrashItem>.unmodifiable(_fakeTrash);

  @override
  int get trashCount => _fakeTrash.length;

  @override
  Future<bool> deleteManagedFile(
    ManagedFile file, {
    bool permanent = false,
  }) async {
    _fakeFiles.removeWhere((f) => f.uniqueKey == file.uniqueKey);
    notifyListeners();
    return true;
  }

  @override
  Future<List<TrashItem>> moveManagedFilesToTrash(List<ManagedFile> files) async {
    final created = <TrashItem>[];
    for (final f in files) {
      _fakeFiles.removeWhere((x) => x.uniqueKey == f.uniqueKey);
      final id = 'trash_${_fakeTrash.length + created.length + 1}';
      final item = TrashItem(
        id: id,
        trashPath: f.savedPath,
        originalPath: f.savedPath,
        fileName: f.fileName,
        mimeType: f.mimeType,
        mediaKind: f.mediaKind.name,
        fileSize: f.fileSize,
        isPrivate: f.isPrivate,
        platformFolder: f.platformFolder,
        creatorFolder: f.creatorFolder,
        albumFolder: f.effectiveAlbumName,
        deletedAt: DateTime.now(),
      );
      _trashedOriginals[id] = f;
      created.add(item);
    }
    _fakeTrash.insertAll(0, created);
    notifyListeners();
    return created;
  }

  @override
  Future<int> restoreTrashItems(List<String> ids) async {
    int count = 0;
    for (final id in ids) {
      final orig = _trashedOriginals.remove(id);
      _fakeTrash.removeWhere((t) => t.id == id);
      if (orig != null) {
        _fakeFiles.add(orig);
        count++;
      }
    }
    notifyListeners();
    return count;
  }

  @override
  Future<void> refreshTrashItems() async {}

  @override
  Future<int> emptyTrash() async {
    final n = _fakeTrash.length;
    _fakeTrash.clear();
    _trashedOriginals.clear();
    notifyListeners();
    return n;
  }

  @override
  List<DownloadItem> get items => fakeItems;

  @override
  int get activeDownloadCount =>
      fakeItems.where((i) => i.isActive).length;

  @override
  int get pausedDownloadCount =>
      fakeItems.where((i) => i.isPaused).length;

  @override
  CreatorProfileRecord? getCreatorProfile(
    String platformFolder,
    String creatorFolder,
  ) =>
      _fakeProfiles[
          CreatorProfileRecord.buildLookupKey(platformFolder, creatorFolder)];
}

void main() {
  testWidgets('all_download simplified UI has 4 tabs and live link detection',
      (WidgetTester tester) async {
    final manager = DownloadManager();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: HomeShell(manager: manager),
      ),
    );
    await tester.pump();

    // Ultra-clean screen checks (title, icon, and removed clutter must stay gone)
    expect(find.text('all_download'), findsNothing);
    expect(find.text('Engine Siap'), findsNothing);
    expect(find.text('Unduh Cepat (Kualitas Default)'), findsNothing);
    expect(find.text('Cara Tercepat Mengunduh'), findsNothing);
    expect(find.text('Paste link'), findsOneWidget);
    expect(find.text('Proses Link'), findsOneWidget);

    // 4 NavigationBar destinations: Unduh, File, Riwayat, Pengaturan
    expect(find.text('Unduh'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Riwayat'), findsOneWidget);
    expect(find.text('Pengaturan'), findsOneWidget);

    // Pasting/typing a link shows live platform detection
    await tester.enterText(
      find.byType(TextField).first,
      'https://www.instagram.com/reel/C9xYz123AbC/',
    );
    await tester.pump();
    expect(find.text('Terdeteksi: Instagram'), findsOneWidget);
    expect(find.text('Reel (Video)'), findsOneWidget);

    // Tapping outside the input dismisses keyboard / unfocuses TextField
    final editable = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(editable.focusNode.hasFocus, isTrue);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(editable.focusNode.hasFocus, isFalse);

    // Entering a Pixiv profile switches CTA to bulk mode
    await tester.enterText(
      find.byType(TextField).first,
      'https://www.pixiv.net/users/11',
    );
    await tester.pump();
    expect(find.text('Terdeteksi: Pixiv'), findsOneWidget);
    expect(find.text('Muat Media Profil (Massal)'), findsOneWidget);

    // Switching to File tab renders cleanly
    await tester.tap(find.text('File'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('File Unduhan'), findsOneWidget);

    manager.dispose();
  });

  testWidgets('Pixiv marked items cannot be checked/downloaded until unmarked (single or bulk)',
      (WidgetTester tester) async {
    final markers = <String>{'pixiv:101', 'pixiv:102'};
    List<SelectableMediaItem>? downloadedBulk;

    final pixivProfile = MediaInfo(
      originalUrl: 'https://www.pixiv.net/users/11',
      platform: MediaPlatform.pixiv,
      title: 'Karya Artist (3 karya)',
      author: 'Artist',
      extractorLabel: 'Pixiv',
      options: const [],
      isBulkProfile: true,
      selectableItems: const [
        SelectableMediaItem(
          id: 'w1',
          title: 'Work 101',
          sourcePostUrl: 'https://www.pixiv.net/artworks/101',
          extension: 'jpg',
          kind: MediaKind.image,
          engine: DownloadEngine.directHttp,
          badgeLabel: '1 Hal',
          pixivIllustId: '101',
        ),
        SelectableMediaItem(
          id: 'w2',
          title: 'Work 102',
          sourcePostUrl: 'https://www.pixiv.net/artworks/102',
          extension: 'jpg',
          kind: MediaKind.image,
          engine: DownloadEngine.directHttp,
          badgeLabel: '2 Hal',
          pixivIllustId: '102',
        ),
        SelectableMediaItem(
          id: 'w3',
          title: 'Work 103',
          sourcePostUrl: 'https://www.pixiv.net/artworks/103',
          extension: 'jpg',
          kind: MediaKind.image,
          engine: DownloadEngine.directHttp,
          badgeLabel: '3 Hal',
          pixivIllustId: '103',
        ),
      ],
    );

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setOuterState) {
          return MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: MediaPreviewCard(
                  info: pixivProfile,
                  initialOption: null,
                  isDownloaded: (key) => markers.contains(key),
                  onUnmarkKey: (key) async => setOuterState(() => markers.remove(key)),
                  onUnmarkKeys: (keys) async =>
                      setOuterState(() => markers.removeAll(keys)),
                  onDownloadOption: (_) {},
                  onDownloadSelectedPhotos: (_) {},
                  onDownloadBulkProfile: (chosen, _) => downloadedBulk = chosen,
                  onDismiss: () {},
                ),
              ),
            ),
          );
        },
      ),
    );
    await tester.pump();

    // Only the 1 unmarked work (Work 103) is selected; marked items (101, 102) are locked!
    expect(find.text('1 / 1 dipilih'), findsOneWidget);
    expect(find.text('Unduh Massal (1 Media)'), findsOneWidget);

    // Tapping a marked tile ('1 Hal' / Work 101) MUST NOT select it!
    await tester.tap(find.text('1 Hal'));
    await tester.pump();
    expect(find.text('1 / 1 dipilih'), findsOneWidget);

    // Enter Bulk Unmark Mode -> Select All Marked -> Remove selected markers!
    await tester.tap(find.text('Hapus Tanda Massal'));
    await tester.pump();
    expect(find.text('Mode Hapus Penanda (0 / 2 dipilih)'), findsOneWidget);

    await tester.tap(find.text('Pilih Semua Tanda (2)'));
    await tester.pump();
    expect(find.text('Hapus 2 Penanda'), findsOneWidget);

    // Tapping "Hapus 2 Penanda" MUST show a confirmation dialog before deleting markers!
    await tester.tap(find.text('Hapus 2 Penanda'));
    await tester.pumpAndSettle();
    expect(find.text('Hapus Penandaan?'), findsOneWidget);
    expect(markers.length, 2);

    // Confirm deletion
    await tester.tap(find.text('Hapus Tanda'));
    await tester.pumpAndSettle();
    expect(markers, isEmpty);

    // Now all 3 items are unlocked and can be selected & downloaded!
    await tester.tap(find.text('Pilih Semua'));
    await tester.pump();
    expect(find.text('3 / 3 dipilih'), findsOneWidget);

    await tester.tap(find.text('Unduh Massal (3 Media)'));
    await tester.pump();
    expect(downloadedBulk?.length, 3);
  });

  testWidgets('Universal marker lock also locks TikTok bulk profile items until unmarked',
      (WidgetTester tester) async {
    final markers = <String>{'tt:9990001'};
    final tiktokProfile = MediaInfo(
      originalUrl: 'https://www.tiktok.com/@creator',
      platform: MediaPlatform.tiktok,
      title: 'Profil @creator (2 video)',
      author: '@creator',
      extractorLabel: 'TikTok',
      options: const [],
      isBulkProfile: true,
      selectableItems: const [
        SelectableMediaItem(
          id: 'v1',
          title: 'Reel 1',
          sourcePostUrl: 'https://www.tiktok.com/@creator/video/9990001',
          extension: 'mp4',
          kind: MediaKind.video,
          engine: DownloadEngine.ytDlp,
          badgeLabel: 'Video',
        ),
        SelectableMediaItem(
          id: 'v2',
          title: 'Reel 2',
          sourcePostUrl: 'https://www.tiktok.com/@creator/video/9990002',
          extension: 'mp4',
          kind: MediaKind.video,
          engine: DownloadEngine.ytDlp,
          badgeLabel: 'Video',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaPreviewCard(
              info: tiktokProfile,
              initialOption: null,
              isDownloaded: (key) => markers.contains(key),
              onDownloadOption: (_) {},
              onDownloadSelectedPhotos: (_) {},
              onDownloadBulkProfile: (_, _) {},
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Only the 1 unmarked TikTok reel is selectable; marked reel is locked!
    expect(find.text('1 / 1 dipilih'), findsOneWidget);
    expect(find.text('Unduh Massal (1 Media)'), findsOneWidget);
  });

  test('sortLoadingDownloads puts actively processing first and failed at bottom of loading', () {
    DownloadItem makeItem(String id, DownloadStatus status) => DownloadItem(
          id: id,
          title: id,
          author: 'Creator',
          sourceUrl: 'https://example.com/$id',
          platform: MediaPlatform.pixiv,
          mediaKind: MediaKind.image,
          formatLabel: 'HD',
          extension: 'jpg',
          status: status,
          createdAt: DateTime(2026),
        );

    final failedItem = makeItem('f1', DownloadStatus.failed);
    final completedItem = makeItem('c1', DownloadStatus.completed);
    expect(isLoadingHistoryItem(failedItem), isTrue);
    expect(isLoadingHistoryItem(completedItem), isFalse);

    final raw = [
      failedItem,
      makeItem('q1', DownloadStatus.queued),
      makeItem('p1', DownloadStatus.paused),
      makeItem('d1', DownloadStatus.downloading),
      makeItem('q2', DownloadStatus.queued),
      makeItem('s1', DownloadStatus.saving),
      makeItem('d2', DownloadStatus.downloading),
    ];

    final sorted = sortLoadingDownloads(raw);
    expect(
      sorted.map((e) => e.id).toList(),
      ['s1', 'd1', 'd2', 'q1', 'q2', 'p1', 'f1'],
    );
  });

  testWidgets(
      'FilesScreen Pixiv album view hides saved profile bar, album search & hint text, and keeps album toolbar sticky',
      (WidgetTester tester) async {
    final files = List<ManagedFile>.generate(
      14,
      (i) => ManagedFile(
        fileName: 'art_${i}_p0.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 1024 * (i + 1),
        modifiedAt: DateTime(2026, 11, 26, 12, i),
        relativePath: 'Pixiv/ArtistAlpha/Album_$i',
        savedPath: '',
        contentUri: 'content://test/pixiv/$i',
        platformFolder: 'Pixiv',
        creatorFolder: 'ArtistAlpha',
        albumFolder: 'Album_$i',
        isPrivate: true,
      ),
    );

    final profile = CreatorProfileRecord(
      platform: MediaPlatform.pixiv,
      creatorFolder: 'ArtistAlpha',
      displayName: 'ArtistAlpha',
      profileUrl: 'https://www.pixiv.net/users/12345',
      lastSyncedAt: DateTime(2026, 11, 26),
    );
    final manager = _FakeFilesManager(
      files,
      {profile.lookupKey: profile},
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: SafeArea(
            child: FilesScreen(manager: manager),
          ),
        ),
      ),
    );
    await tester.pump();

    // Level 0 -> open Pixiv folder
    await tester.tap(find.text('Pixiv'));
    await tester.pumpAndSettle();

    // Level 1 (Artist list): search artist & saved profile indicator MUST be present
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Cari artist Pixiv...'), findsOneWidget);
    expect(find.textContaining('Link tersimpan'), findsOneWidget);

    // Open ArtistAlpha -> Level 2 (Album list)
    await tester.tap(find.text('ArtistAlpha'));
    await tester.pumpAndSettle();

    // No saved profile bar, no album search box, no hint line!
    expect(find.text('Profil Tersimpan'), findsNothing);
    expect(find.text('Lanjut Unduh'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('Ketuk album lalu geser'), findsNothing);
    expect(find.textContaining('Tahan & geser'), findsNothing);

    // Sticky album toolbar is present with Album, Semua Foto, Acak, and Grid/List toggle
    expect(find.text('Album (14)'), findsOneWidget);
    expect(find.text('Semua Foto (14)'), findsOneWidget);
    expect(find.text('Acak'), findsOneWidget);

    // Scroll far down — sticky toolbar MUST stay pinned near top of viewport!
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();

    final albumChipRect = tester.getRect(find.text('Album (14)'));
    expect(albumChipRect.top, greaterThanOrEqualTo(0));
    expect(albumChipRect.bottom, lessThan(80));

    manager.dispose();
  });

  testWidgets(
      'DownloadsScreen load balancer windows 2,000 items cleanly and strips completed resumePayload',
      (WidgetTester tester) async {
    final heavyPayload = {
      'headers': {'Cookie': 'PHPSESSID=secret_token_value'},
      'galleryUrls': List.generate(30, (i) => 'https://i.pximg.net/p$i.jpg'),
    };
    final completedSample = DownloadItem(
      id: 'done_check',
      title: 'Completed Check',
      author: 'Artist',
      sourceUrl: 'https://www.pixiv.net/artworks/999',
      platform: MediaPlatform.pixiv,
      mediaKind: MediaKind.image,
      formatLabel: 'HD',
      extension: 'jpg',
      status: DownloadStatus.completed,
      createdAt: DateTime(2026, 11, 26),
      resumePayload: heavyPayload,
    );
    final pausedSample = completedSample.copyWith(status: DownloadStatus.paused);
    expect(completedSample.toJson().containsKey('resumePayload'), isFalse);
    expect(pausedSample.toJson().containsKey('resumePayload'), isTrue);

    final items = <DownloadItem>[
      // 2 actively processing items
      for (int i = 0; i < 2; i++)
        DownloadItem(
          id: 'proc_$i',
          title: 'Active Work $i',
          author: 'Artist',
          sourceUrl: 'https://www.pixiv.net/artworks/10$i',
          platform: MediaPlatform.pixiv,
          mediaKind: MediaKind.image,
          formatLabel: 'HD',
          extension: 'jpg',
          status: DownloadStatus.downloading,
          progress: 50,
          createdAt: DateTime(2026, 11, 26),
        ),
      // 1,195 queued items
      for (int i = 0; i < 1195; i++)
        DownloadItem(
          id: 'q_$i',
          title: 'Queued Work $i',
          author: 'Artist',
          sourceUrl: 'https://www.pixiv.net/artworks/2000$i',
          platform: MediaPlatform.pixiv,
          mediaKind: MediaKind.image,
          formatLabel: 'HD',
          extension: 'jpg',
          status: DownloadStatus.queued,
          createdAt: DateTime(2026, 11, 26),
        ),
      // 3 failed items (must remain at bottom of Berjalan!)
      for (int i = 0; i < 3; i++)
        DownloadItem(
          id: 'fail_$i',
          title: 'Failed Work $i',
          author: 'Artist',
          sourceUrl: 'https://www.pixiv.net/artworks/30$i',
          platform: MediaPlatform.pixiv,
          mediaKind: MediaKind.image,
          formatLabel: 'HD',
          extension: 'jpg',
          status: DownloadStatus.failed,
          errorMessage: 'Timeout',
          createdAt: DateTime(2026, 11, 26),
        ),
      // 800 completed items
      for (int i = 0; i < 800; i++)
        DownloadItem(
          id: 'done_$i',
          title: 'Finished Work $i',
          author: 'Artist',
          sourceUrl: 'https://www.pixiv.net/artworks/4000$i',
          platform: MediaPlatform.pixiv,
          mediaKind: MediaKind.image,
          formatLabel: 'HD',
          extension: 'jpg',
          status: DownloadStatus.completed,
          progress: 100,
          createdAt: DateTime(2026, 11, 26),
        ),
    ];

    final manager = _FakeFilesManager(const [], const {}, fakeItems: items);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: SafeArea(
            child: DownloadsScreen(manager: manager),
          ),
        ),
      ),
    );
    await tester.pump();

    // Berjalan tab shows 1200 total, but load balancer renders only 2 + 40 + 3 = 45!
    expect(find.text('Berjalan (1200)'), findsOneWidget);
    expect(find.text('Selesai (800)'), findsOneWidget);
    expect(
      find.text('Load Balancer Aktif • menampilkan 45 dari 1200 item'),
      findsOneWidget,
    );
    expect(find.text('Sedang Diproses (2)'), findsOneWidget);

    // Switch to Selesai tab -> load balancer caps initial render to 60 of 800!
    await tester.tap(find.text('Selesai (800)'));
    await tester.pumpAndSettle();
    expect(
      find.text('Load Balancer Aktif • menampilkan 60 dari 800 item'),
      findsOneWidget,
    );

    manager.dispose();
  });

  testWidgets(
      'SettingsScreen displays clean main menu + submenus and persists rate-limit settings',
      (WidgetTester tester) async {
    final original = const AppSettings(
      maxConcurrentAlbums: 2,
      downloadRateLimitMs: 600,
    );
    final roundTrip = AppSettings.fromJson(original.toJson());
    expect(roundTrip.maxConcurrentAlbums, 2);
    expect(roundTrip.downloadRateLimitMs, 600);
    expect(
      AppSettings.fromJson({'maxConcurrentAlbums': 99}).maxConcurrentAlbums,
      AppSettings.maxConcurrentAlbumsLimit,
    );

    final manager = DownloadManager();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: SafeArea(
            child: SettingsScreen(manager: manager),
          ),
        ),
      ),
    );
    await tester.pump();

    // Main Settings menu shows 5 clean categories instead of a cluttered wall
    expect(find.text('Unduhan & Rate Limiting'), findsOneWidget);
    expect(find.text('Akun & Login Platform'), findsOneWidget);
    expect(find.text('Tampilan & Umum'), findsOneWidget);
    expect(find.text('Backup, Migrasi & Data'), findsOneWidget);
    expect(find.text('Mesin & Izin Sistem'), findsOneWidget);
    expect(find.text('Maksimal Album Bersamaan'), findsNothing);

    // Open Unduhan & Rate Limiting submenu
    await tester.tap(find.text('Unduhan & Rate Limiting'));
    await tester.pumpAndSettle();

    expect(find.text('Maksimal Album Bersamaan'), findsOneWidget);
    expect(find.text('Jeda Rate Limit Antar Album'), findsOneWidget);
    expect(find.text('3 album'), findsOneWidget);

    manager.dispose();
  });

  testWidgets(
      'Artist list displays top Semua Foto menu with shuffled photos, refresh & slide viewer',
      (WidgetTester tester) async {
    final files = <ManagedFile>[
      for (int i = 0; i < 4; i++)
        ManagedFile(
          fileName: 'alpha_$i.jpg',
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 2048,
          modifiedAt: DateTime(2026, 11, 26, 10, i),
          relativePath: 'Pixiv/ArtistAlpha/AlbumA',
          savedPath: '/nonexistent/alpha_$i.jpg',
          contentUri: 'content://test/pixiv/alpha/$i',
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistAlpha',
          albumFolder: 'AlbumA',
          isPrivate: true,
        ),
      for (int i = 0; i < 3; i++)
        ManagedFile(
          fileName: 'beta_$i.jpg',
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 2048,
          modifiedAt: DateTime(2026, 11, 26, 11, i),
          relativePath: 'Pixiv/ArtistBeta/AlbumB',
          savedPath: '/nonexistent/beta_$i.jpg',
          contentUri: 'content://test/pixiv/beta/$i',
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistBeta',
          albumFolder: 'AlbumB',
          isPrivate: true,
        ),
    ];

    final manager = _FakeFilesManager(files, const {});

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: SafeArea(
            child: FilesScreen(manager: manager),
          ),
        ),
      ),
    );
    await tester.pump();

    // Open Pixiv -> Artist list (Level 1)
    await tester.tap(find.text('Pixiv'));
    await tester.pumpAndSettle();

    // Top menu card "Semua Foto" MUST appear above artists
    expect(find.text('Semua Foto'), findsOneWidget);
    expect(find.text('7 foto • 2 artist • Acak & slide'), findsOneWidget);
    expect(find.text('ArtistAlpha'), findsOneWidget);
    expect(find.text('ArtistBeta'), findsOneWidget);

    // Long-press an artist -> opens read-only Info Artist sheet (size, photos, albums; NO delete!)
    await tester.longPress(find.text('ArtistAlpha'));
    await tester.pumpAndSettle();
    expect(find.text('Informasi Artist • Pixiv'), findsOneWidget);
    expect(find.text('Total Ukuran'), findsOneWidget);
    expect(find.text('8.0 KB'), findsOneWidget);
    expect(find.text('4 foto'), findsOneWidget);
    expect(find.text('4 privat • 0 galeri'), findsOneWidget);
    expect(find.textContaining('Hapus'), findsNothing);
    await tester.tap(find.text('Tutup'));
    await tester.pumpAndSettle();

    // Tap "Semua Foto" -> opens PlatformAllPhotosScreen (shuffled by default)
    await tester.tap(find.text('Semua Foto'));
    await tester.pumpAndSettle();

    expect(find.text('Semua Foto • Pixiv'), findsOneWidget);
    expect(find.text('Acak Aktif'), findsOneWidget);
    expect(find.text('Acak Lagi'), findsOneWidget);
    expect(find.text('Slide'), findsOneWidget);
    expect(find.text('7 foto'), findsOneWidget);

    // Tap "Acak Lagi" to reshuffle cleanly
    await tester.tap(find.text('Acak Lagi'));
    await tester.pumpAndSettle();
    expect(find.text('Acak Aktif'), findsOneWidget);

    // Tap "Slide" -> opens full-screen swipeable FileGalleryViewer with in-viewer shuffle button
    await tester.tap(find.text('Slide'));
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsOneWidget);
    expect(find.byTooltip('Acak ulang & segarkan'), findsOneWidget);

    manager.dispose();
  });

  testWidgets(
      'Artist list sorts by largest size & most photos, and finished history puts newest completed on top',
      (WidgetTester tester) async {
    // 1) Verify sortFinishedDownloads orders by completedAt descending (even when createdAt was older!)
    final oldCreatedNewlyDone = DownloadItem(
      id: 'resumed_old',
      title: 'Resumed Old',
      author: 'A',
      sourceUrl: 'https://example.com/1',
      platform: MediaPlatform.pixiv,
      mediaKind: MediaKind.image,
      formatLabel: 'HD',
      extension: 'jpg',
      status: DownloadStatus.completed,
      createdAt: DateTime(2026, 11, 20, 8, 0),
      completedAt: DateTime(2026, 11, 26, 15, 50),
    );
    final newerCreatedEarlierDone = DownloadItem(
      id: 'earlier_done',
      title: 'Earlier Done',
      author: 'B',
      sourceUrl: 'https://example.com/2',
      platform: MediaPlatform.pixiv,
      mediaKind: MediaKind.image,
      formatLabel: 'HD',
      extension: 'jpg',
      status: DownloadStatus.completed,
      createdAt: DateTime(2026, 11, 26, 15, 0),
      completedAt: DateTime(2026, 11, 26, 15, 10),
    );
    final legacyNoCompletedAt = DownloadItem(
      id: 'legacy',
      title: 'Legacy',
      author: 'C',
      sourceUrl: 'https://example.com/3',
      platform: MediaPlatform.pixiv,
      mediaKind: MediaKind.image,
      formatLabel: 'HD',
      extension: 'jpg',
      status: DownloadStatus.completed,
      createdAt: DateTime(2026, 11, 25, 12, 0),
    );
    final sortedFinished = sortFinishedDownloads([
      legacyNoCompletedAt,
      newerCreatedEarlierDone,
      oldCreatedNewlyDone,
    ]);
    expect(
      sortedFinished.map((e) => e.id).toList(),
      ['resumed_old', 'earlier_done', 'legacy'],
    );
    // completedAt survives JSON round-trip
    final rt = DownloadItem.fromJson(oldCreatedNewlyDone.toJson());
    expect(rt.completedAt, oldCreatedNewlyDone.completedAt);

    // 2) Verify Artist list sorting: Terbesar (size desc) & Foto Terbanyak (photo count desc)
    final files = <ManagedFile>[
      // ArtistHugeSize: 1 giant photo (50 MB), oldest
      ManagedFile(
        fileName: 'huge.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 50 * 1024 * 1024,
        modifiedAt: DateTime(2026, 11, 20),
        relativePath: 'Pixiv/ArtistHugeSize/A1',
        savedPath: '/nonexistent/huge.jpg',
        contentUri: 'content://test/huge',
        platformFolder: 'Pixiv',
        creatorFolder: 'ArtistHugeSize',
        albumFolder: 'A1',
        isPrivate: true,
      ),
      // ArtistManyPhotos: 5 tiny photos (5 KB total), middle date
      for (int i = 0; i < 5; i++)
        ManagedFile(
          fileName: 'many_$i.jpg',
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 1024,
          modifiedAt: DateTime(2026, 11, 22),
          relativePath: 'Pixiv/ArtistManyPhotos/M$i',
          savedPath: '/nonexistent/many_$i.jpg',
          contentUri: 'content://test/many_$i',
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistManyPhotos',
          albumFolder: 'M$i',
          isPrivate: true,
        ),
      // ArtistNewest: 2 medium photos (2 MB total), newest date
      for (int i = 0; i < 2; i++)
        ManagedFile(
          fileName: 'new_$i.jpg',
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 1024 * 1024,
          modifiedAt: DateTime(2026, 11, 26),
          relativePath: 'Pixiv/ArtistNewest/N1',
          savedPath: '/nonexistent/new_$i.jpg',
          contentUri: 'content://test/new_$i',
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistNewest',
          albumFolder: 'N1',
          isPrivate: true,
        ),
    ];

    final manager = _FakeFilesManager(files, const {});
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: SafeArea(
            child: FilesScreen(manager: manager),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Pixiv'));
    await tester.pumpAndSettle();

    // Default (Terbaru): ArtistNewest is above ArtistHugeSize
    expect(
      tester.getTopLeft(find.text('ArtistNewest')).dy,
      lessThan(tester.getTopLeft(find.text('ArtistHugeSize')).dy),
    );

    // Sort by Terbesar -> ArtistHugeSize (50 MB) jumps above ArtistNewest (2 MB) & ArtistManyPhotos (5 KB)
    await tester.tap(find.text('Terbesar'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('ArtistHugeSize')).dy,
      lessThan(tester.getTopLeft(find.text('ArtistNewest')).dy),
    );
    expect(
      tester.getTopLeft(find.text('ArtistNewest')).dy,
      lessThan(tester.getTopLeft(find.text('ArtistManyPhotos')).dy),
    );

    // Sort by Foto Terbanyak -> ArtistManyPhotos (5) jumps above ArtistNewest (2) & ArtistHugeSize (1)
    await tester.tap(find.text('Foto Terbanyak'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('ArtistManyPhotos')).dy,
      lessThan(tester.getTopLeft(find.text('ArtistNewest')).dy),
    );
    expect(
      tester.getTopLeft(find.text('ArtistNewest')).dy,
      lessThan(tester.getTopLeft(find.text('ArtistHugeSize')).dy),
    );

    manager.dispose();
  });

  testWidgets(
      'PixivAlbumViewer switches smoothly to next album with only a short (~20%) horizontal slide',
      (WidgetTester tester) async {
    final files = <ManagedFile>[
      ManagedFile(
        fileName: 'a1_0.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 1024,
        modifiedAt: DateTime(2026, 11, 26, 10, 0),
        relativePath: 'Pixiv/ArtistSwipe/Album Satu',
        savedPath: '/nonexistent/a1_0.jpg',
        contentUri: 'content://test/swipe/1',
        platformFolder: 'Pixiv',
        creatorFolder: 'ArtistSwipe',
        albumFolder: 'Album Satu',
        isPrivate: true,
      ),
      ManagedFile(
        fileName: 'a2_0.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 1024,
        modifiedAt: DateTime(2026, 11, 26, 10, 1),
        relativePath: 'Pixiv/ArtistSwipe/Album Dua',
        savedPath: '/nonexistent/a2_0.jpg',
        contentUri: 'content://test/swipe/2',
        platformFolder: 'Pixiv',
        creatorFolder: 'ArtistSwipe',
        albumFolder: 'Album Dua',
        isPrivate: true,
      ),
    ];

    final manager = _FakeFilesManager(files, const {});
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: PixivAlbumViewer(
          manager: manager,
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistSwipe',
          albumName: 'Album Satu',
          albumNames: const ['Album Satu', 'Album Dua'],
          initialAlbumIndex: 0,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Album Satu'), findsOneWidget);

    // Quick flick switches smoothly to Album Dua
    final width = tester.getSize(find.byType(PageView)).width;
    await tester.fling(
      find.byType(PageView),
      Offset(-width * 0.16, 0),
      350,
    );
    await tester.pumpAndSettle();

    // Must immediately land on Album Dua!
    expect(find.text('Album Dua'), findsOneWidget);

    // Deliberate 1/4-screen (28%) slow drag back right switches cleanly to Album Satu!
    await tester.timedDrag(
      find.byType(PageView),
      Offset(width * 0.28, 0),
      const Duration(milliseconds: 420),
    );
    await tester.pumpAndSettle();
    expect(find.text('Album Satu'), findsOneWidget);

    manager.dispose();
  });

  testWidgets(
      'Pixiv bulk profile marks unchecked albums as skipped/downloaded and supports skip-only submit',
      (WidgetTester tester) async {
    final manager = DownloadManager(storage: _MemoryStorageService());
    List<SelectableMediaItem>? submittedChosen;

    const item1 = SelectableMediaItem(
      id: 'px_1',
      title: 'Album One',
      sourcePostUrl: 'https://www.pixiv.net/artworks/7001',
      extension: 'jpg',
      kind: MediaKind.image,
      engine: DownloadEngine.directHttp,
      badgeLabel: '1 Hal',
      pixivIllustId: '7001',
      tags: ['Original', 'Anime'],
    );
    const item2 = SelectableMediaItem(
      id: 'px_2',
      title: 'Album Two',
      sourcePostUrl: 'https://www.pixiv.net/artworks/7002',
      extension: 'jpg',
      kind: MediaKind.image,
      engine: DownloadEngine.directHttp,
      badgeLabel: '2 Hal',
      pixivIllustId: '7002',
      tags: ['Landscape'],
    );
    const item3 = SelectableMediaItem(
      id: 'px_3',
      title: 'Album Three',
      sourcePostUrl: 'https://www.pixiv.net/artworks/7003',
      extension: 'jpg',
      kind: MediaKind.image,
      engine: DownloadEngine.directHttp,
      badgeLabel: '3 Hal',
      pixivIllustId: '7003',
    );

    const profile = MediaInfo(
      originalUrl: 'https://www.pixiv.net/users/888',
      platform: MediaPlatform.pixiv,
      title: 'Karya Artist (3 karya)',
      author: 'PixivArtist',
      extractorLabel: 'Pixiv',
      options: [],
      isBulkProfile: true,
      selectableItems: [item1, item2, item3],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaPreviewCard(
              info: profile,
              initialOption: null,
              isDownloaded: manager.isMarkedDownloaded,
              onDownloadOption: (_) {},
              onDownloadSelectedPhotos: (_) {},
              onDownloadBulkProfile: (chosen, _) => submittedChosen = chosen,
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Uncheck Album Two -> button switches to "Unduh 2 • Skip 1"
    await tester.tap(find.text('2 Hal'));
    await tester.pump();
    expect(find.text('Unduh 2 • Skip 1'), findsOneWidget);
    expect(find.textContaining('1 album tidak dicentang'), findsOneWidget);

    // Uncheck all remaining -> button stays enabled as "Tandai Dilewati (3 Album)"!
    await tester.tap(find.text('1 Hal'));
    await tester.tap(find.text('3 Hal'));
    await tester.pump();
    expect(find.text('Tandai Dilewati (3 Album)'), findsOneWidget);

    await tester.tap(find.text('Tandai Dilewati (3 Album)'));
    await tester.pump();
    expect(submittedChosen, isEmpty);

    // Executing skip-only bulk call marks unchecked albums as downloaded with 0 queued downloads!
    final started = await manager.startBulkDownloads(
      profile,
      const [],
      skipped: const [item2, item3],
    );
    expect(started, 0);
    expect(manager.items, isEmpty);
    expect(manager.isMarkedDownloaded('pixiv:7002'), isTrue);
    expect(manager.isMarkedDownloaded('pixiv:7003'), isTrue);
    expect(manager.isMarkedDownloaded('pixiv:7001'), isFalse);

    manager.dispose();
  });

  testWidgets(
      'Pixiv album tags, FileGalleryViewer Tandai button (left of Hapus), and Settings Visibilitas Konten checklist work end-to-end',
      (WidgetTester tester) async {
    // 1) Verify DirectExtractors.parsePixivTags handles both Pixiv API response formats
    final parsedDetailed = DirectExtractors.parsePixivTags({
      'tags': [
        {
          'tag': 'オリジナル',
          'translation': {'en': 'original'},
        },
        {'tag': 'R-18'},
        {'tag': 'R-18'},
      ],
    });
    expect(parsedDetailed, ['オリジナル (original)', 'R-18']);
    expect(
      DirectExtractors.parsePixivTags(['Genshin', 'Lumine', 'genshin']),
      ['Genshin', 'Lumine'],
    );

    final photoNormal = ManagedFile(
      fileName: 'p1.jpg',
      mimeType: 'image/jpeg',
      mediaKind: MediaKind.image,
      fileSize: 1024,
      modifiedAt: DateTime(2026, 11, 26, 10, 0),
      relativePath: 'Pixiv/ArtistTag/AlbumTag',
      savedPath: '/nonexistent/p1.jpg',
      contentUri: 'content://test/tag/1',
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistTag',
      albumFolder: 'AlbumTag',
      isPrivate: true,
    );
    final photoToMark = ManagedFile(
      fileName: 'p2.jpg',
      mimeType: 'image/jpeg',
      mediaKind: MediaKind.image,
      fileSize: 1024,
      modifiedAt: DateTime(2026, 11, 26, 10, 1),
      relativePath: 'Pixiv/ArtistTag/AlbumTag',
      savedPath: '/nonexistent/p2.jpg',
      contentUri: 'content://test/tag/2',
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistTag',
      albumFolder: 'AlbumTag',
      isPrivate: true,
    );

    final manager = _FakeFilesManager([photoNormal, photoToMark], const {});
    await manager.saveAlbumMetadata(
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistTag',
      albumFolder: 'AlbumTag',
      pixivIllustId: '9999',
      tags: const ['Original', 'Fantasy'],
    );
    expect(
      manager.getAlbumTags('Pixiv', 'ArtistTag', 'AlbumTag'),
      ['Original', 'Fantasy'],
    );

    // 2) Verify PixivAlbumViewer renders per-album tags BELOW the album when scrolled
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: PixivAlbumViewer(
          manager: manager,
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistTag',
          albumName: 'AlbumTag',
          albumNames: const ['AlbumTag'],
          initialAlbumIndex: 0,
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('album_tags_footer')), findsOneWidget);
    expect(find.text('#Original'), findsOneWidget);
    expect(find.text('#Fantasy'), findsOneWidget);

    // 3) Open FileGalleryViewer -> verify Tandai button sits directly to the LEFT of Hapus
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: FileGalleryViewer(
          manager: manager,
          images: [photoNormal, photoToMark],
          initialIndex: 1,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Bagikan'), findsOneWidget);
    expect(find.text('Tandai'), findsOneWidget);
    expect(find.text('Hapus'), findsOneWidget);

    final bagikanX = tester.getCenter(find.text('Bagikan')).dx;
    final tandaiX = tester.getCenter(find.text('Tandai')).dx;
    final hapusX = tester.getCenter(find.text('Hapus')).dx;
    expect(tandaiX, greaterThan(bagikanX));
    expect(tandaiX, lessThan(hapusX));

    // Default rating is Biasa -> tap Tandai -> pick NSFW
    expect(manager.getPhotoRating(photoToMark), ContentRating.normal);
    await tester.tap(find.text('Tandai'));
    await tester.pumpAndSettle();
    expect(find.text('Tandai Konten Foto'), findsOneWidget);
    expect(find.text('Biasa'), findsOneWidget);
    expect(find.text('Ecchi'), findsOneWidget);
    expect(find.text('NSFW'), findsOneWidget);

    await tester.tap(find.text('NSFW'));
    await tester.pumpAndSettle();
    expect(manager.getPhotoRating(photoToMark), ContentRating.nsfw);
    // Notification MUST appear at the TOP of the screen (never covering bottom buttons!)
    final toastFinder = find.text('Foto ditandai sebagai NSFW.');
    expect(toastFinder, findsOneWidget);
    expect(tester.getTopLeft(toastFinder).dy, lessThan(140));
    dismissTopToast();
    await tester.pumpAndSettle();

    // Rating survives Private <-> Public Gallery move because ratingKey is logical!
    final unlockedCopy = ManagedFile(
      fileName: photoToMark.fileName,
      mimeType: photoToMark.mimeType,
      mediaKind: photoToMark.mediaKind,
      fileSize: photoToMark.fileSize,
      modifiedAt: photoToMark.modifiedAt,
      relativePath: 'Pictures/all_download/Pixiv/ArtistTag/AlbumTag',
      savedPath: '/storage/emulated/0/Pictures/all_download/Pixiv/ArtistTag/AlbumTag/p2.jpg',
      contentUri: 'content://media/external/images/999',
      platformFolder: photoToMark.platformFolder,
      creatorFolder: photoToMark.creatorFolder,
      albumFolder: photoToMark.albumFolder,
      isPrivate: false,
    );
    expect(manager.getPhotoRating(unlockedCopy), ContentRating.nsfw);

    // 4) Open Settings -> Visibilitas Konten checklist -> uncheck NSFW -> filters visibleManagedFiles!
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: SafeArea(
            child: SettingsScreen(manager: manager),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Visibilitas Konten'), findsOneWidget);

    await tester.tap(find.text('Visibilitas Konten'));
    await tester.pumpAndSettle();

    expect(find.byType(CheckboxListTile), findsNWidgets(3));
    expect(manager.visibleManagedFiles.length, 2);

    // Uncheck NSFW
    await tester.tap(find.text('NSFW'));
    await tester.pumpAndSettle();
    expect(manager.settings.showNsfwContent, isFalse);
    expect(manager.visibleManagedFiles.length, 1);
    expect(manager.visibleManagedFiles.first.fileName, 'p1.jpg');

    // 5) Backup JSON round-trip preserves visibility settings, album tags, and photo ratings!
    final backup = manager.parseBackupText(manager.buildBackupJson());
    expect(backup.settings.showNsfwContent, isFalse);
    expect(backup.albumMetadata.length, 1);
    expect(backup.photoRatings[photoToMark.ratingKey], ContentRating.nsfw);

    manager.dispose();
  });

  testWidgets(
      'SharpOriginalImage uses untouched native FileImage for full-res quality and upgrades immediately on zoom',
      (WidgetTester tester) async {
    // 1) Normal & high-res Pixiv original (e.g. 3840x5120 = 19.6 MP) stays 100% untouched FileImage!
    final untouched = buildOriginalQualityProvider(
      '/nonexistent/hq.png',
      naturalSize: (width: 3840, height: 5120),
      maxOriginalDimension: 6144,
      maxOriginalPixels: 32 * 1000 * 1000,
    );
    expect(untouched, isA<FileImage>());

    // 2) Extreme 12000x16000 (192 MP) canvas is safely bounded within GPU limits without OOM
    final bounded = buildOriginalQualityProvider(
      '/nonexistent/giant.png',
      naturalSize: (width: 12000, height: 16000),
      maxOriginalDimension: 6144,
      maxOriginalPixels: 32 * 1000 * 1000,
    );
    expect(bounded, isA<ResizeImage>());
    final resized = bounded as ResizeImage;
    expect(resized.width, lessThanOrEqualTo(6144));
    expect(resized.height, lessThanOrEqualTo(6144));
    expect(resized.allowUpscaling, isFalse);

    // 3) Widget starts at screen-sharp preview (FilterQuality.medium), then promotes to
    // untouched FileImage after settle delay — and switches to FilterQuality.high when zoomed!
    bool zoomed = false;
    late StateSetter setOuter;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return MaterialApp(
            home: SharpOriginalImage(
              filePath: '/nonexistent/test.jpg',
              highZoomActive: zoomed,
              originalUpgradeDelay: const Duration(milliseconds: 100),
            ),
          );
        },
      ),
    );
    await tester.pump();

    var img = tester.widget<Image>(find.byType(Image));
    expect(img.filterQuality, FilterQuality.medium);
    expect(img.gaplessPlayback, isTrue);
    expect(img.image, isA<ResizeImage>());

    // Promote immediately when user zooms in -> raw FileImage + FilterQuality.high!
    setOuter(() => zoomed = true);
    await tester.pump();
    img = tester.widget<Image>(find.byType(Image));
    expect(img.filterQuality, FilterQuality.high);
    expect(img.image, isA<FileImage>());
  });

  testWidgets(
      'PixivAlbumViewer grid mode uses original-aspect Masonry layout and in select-all mode unchecks only on circle while photo tap opens enlarged preview',
      (WidgetTester tester) async {
    // Seed real natural dimensions: tall portrait (1:2), wide landscape (2:1), square (1:1), plus 4th photo
    ImageDimensionCache.seedForTest(
      '/nonexistent/m_portrait.jpg',
      width: 600,
      height: 1200,
    );
    ImageDimensionCache.seedForTest(
      '/nonexistent/m_landscape.jpg',
      width: 1600,
      height: 800,
    );
    ImageDimensionCache.seedForTest(
      '/nonexistent/m_square.jpg',
      width: 1000,
      height: 1000,
    );
    ImageDimensionCache.seedForTest(
      '/nonexistent/m_fourth.jpg',
      width: 1000,
      height: 1000,
    );

    final pages = [
      ManagedFile(
        fileName: 'p1.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 1024,
        modifiedAt: DateTime(2026, 11, 26, 10, 0),
        relativePath: 'Pixiv/ArtistMasonry/AlbumM',
        savedPath: '/nonexistent/m_portrait.jpg',
        contentUri: 'content://test/m/1',
        platformFolder: 'Pixiv',
        creatorFolder: 'ArtistMasonry',
        albumFolder: 'AlbumM',
        isPrivate: true,
      ),
      ManagedFile(
        fileName: 'p2.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 1024,
        modifiedAt: DateTime(2026, 11, 26, 10, 1),
        relativePath: 'Pixiv/ArtistMasonry/AlbumM',
        savedPath: '/nonexistent/m_landscape.jpg',
        contentUri: 'content://test/m/2',
        platformFolder: 'Pixiv',
        creatorFolder: 'ArtistMasonry',
        albumFolder: 'AlbumM',
        isPrivate: true,
      ),
      ManagedFile(
        fileName: 'p3.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 1024,
        modifiedAt: DateTime(2026, 11, 26, 10, 2),
        relativePath: 'Pixiv/ArtistMasonry/AlbumM',
        savedPath: '/nonexistent/m_square.jpg',
        contentUri: 'content://test/m/3',
        platformFolder: 'Pixiv',
        creatorFolder: 'ArtistMasonry',
        albumFolder: 'AlbumM',
        isPrivate: true,
      ),
      ManagedFile(
        fileName: 'p4.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 1024,
        modifiedAt: DateTime(2026, 11, 26, 10, 3),
        relativePath: 'Pixiv/ArtistMasonry/AlbumM',
        savedPath: '/nonexistent/m_fourth.jpg',
        contentUri: 'content://test/m/4',
        platformFolder: 'Pixiv',
        creatorFolder: 'ArtistMasonry',
        albumFolder: 'AlbumM',
        isPrivate: true,
      ),
    ];

    final manager = _FakeFilesManager(pages, const {});
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: PixivAlbumViewer(
          manager: manager,
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistMasonry',
          albumName: 'AlbumM',
          albumNames: const ['AlbumM'],
          initialAlbumIndex: 0,
        ),
      ),
    );
    await tester.pump();

    // Switch to Grid view
    await tester.tap(find.byTooltip('Mode Album / Galeri'));
    await tester.pumpAndSettle();

    // 1) Verify Masonry layout preserves distinct original aspect ratios (NOT uniform squares!)
    // and packs item #4 into the shortest column (column 1 = directly beneath the wide landscape item #2)!
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(grid.gridDelegate, isA<MasonrySliverGridDelegate>());
    final layout = (grid.gridDelegate as MasonrySliverGridDelegate).getLayout(
      const SliverConstraints(
        axisDirection: AxisDirection.down,
        growthDirection: GrowthDirection.forward,
        userScrollDirection: ScrollDirection.idle,
        scrollOffset: 0,
        precedingScrollExtent: 0,
        overlap: 0,
        remainingPaintExtent: 800,
        crossAxisExtent: 360,
        crossAxisDirection: AxisDirection.right,
        viewportMainAxisExtent: 800,
        remainingCacheExtent: 800,
        cacheOrigin: 0,
      ),
    );
    final g0 = layout.getGeometryForChildIndex(0); // Portrait 1:2 (tall)
    final g1 = layout.getGeometryForChildIndex(1); // Landscape 2:1 (short)
    final g2 = layout.getGeometryForChildIndex(2); // Square 1:1 (medium)
    final g3 = layout.getGeometryForChildIndex(3); // Should pack under g1 (shortest column!)

    expect(g0.mainAxisExtent, greaterThan(g2.mainAxisExtent * 1.8));
    expect(g1.mainAxisExtent, lessThan(g2.mainAxisExtent * 0.6));
    expect(g3.crossAxisOffset, closeTo(g1.crossAxisOffset, 0.1));
    expect(g3.scrollOffset, closeTo(g1.mainAxisExtent + 6.0, 0.1));

    // 2) Enter Selection Mode -> tap "Semua" (Pilih Semua)
    await tester.tap(find.byTooltip('Pilih banyak'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Semua'));
    await tester.pumpAndSettle();
    expect(find.text('4 dipilih'), findsOneWidget);

    // 3) Tapping ONLY the checklist circle unchecks that photo (4 -> 3 dipilih) without opening preview!
    await tester.tap(find.byKey(const ValueKey<String>('grid_select_circle_0')));
    await tester.pumpAndSettle();
    expect(find.text('3 dipilih'), findsOneWidget);
    expect(find.byType(FileGalleryViewer), findsNothing);

    // 4) Tapping the photo area itself (bottom-left of tile #1) opens enlarged FileGalleryViewer preview
    // and DOES NOT uncheck it!
    final tile1Rect = tester.getRect(find.text('2'));
    await tester.tapAt(tile1Rect.center);
    await tester.pumpAndSettle();
    expect(find.byType(FileGalleryViewer), findsOneWidget);

    // Return back -> selection count MUST still be 3 dipilih!
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(FileGalleryViewer), findsNothing);
    expect(find.text('3 dipilih'), findsOneWidget);

    manager.dispose();
  });

  testWidgets(
      'Bottom album tags open all albums with same tag, delete confirm stays at bottom, and Fast Delete skips confirm',
      (WidgetTester tester) async {
    ManagedFile mkFile(String artist, String album, String name, int minute) =>
        ManagedFile(
          fileName: name,
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 2048,
          modifiedAt: DateTime(2026, 11, 26, 10, minute),
          relativePath: 'Pixiv/$artist/$album',
          savedPath: '/nonexistent/$artist/$album/$name',
          contentUri: 'content://test/$artist/$album/$name',
          platformFolder: 'Pixiv',
          creatorFolder: artist,
          albumFolder: album,
          isPrivate: true,
        );

    final f1 = mkFile('ArtistOne', 'AlbumAlpha', 'a1.jpg', 10);
    final f2 = mkFile('ArtistOne', 'AlbumAlpha', 'a2.jpg', 11);
    final f3 = mkFile('ArtistTwo', 'AlbumBeta', 'b1.jpg', 12);
    final f4 = mkFile('ArtistTwo', 'AlbumOther', 'c1.jpg', 13);

    final manager = _FakeFilesManager([f1, f2, f3, f4], const {});
    await manager.saveAlbumMetadata(
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistOne',
      albumFolder: 'AlbumAlpha',
      tags: const ['Fantasy', 'Knight'],
    );
    await manager.saveAlbumMetadata(
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistTwo',
      albumFolder: 'AlbumBeta',
      tags: const ['fantasy', 'Magic'],
    );
    await manager.saveAlbumMetadata(
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistTwo',
      albumFolder: 'AlbumOther',
      tags: const ['SciFi'],
    );

    // 1) Open PixivAlbumViewer on AlbumAlpha -> scroll down -> tap #Fantasy -> opens TagAlbumsScreen with BOTH matching albums!
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: PixivAlbumViewer(
          manager: manager,
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistOne',
          albumName: 'AlbumAlpha',
          albumNames: const ['AlbumAlpha'],
          initialAlbumIndex: 0,
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -650));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('album_tags_footer')), findsOneWidget);
    await tester.tap(find.text('#Fantasy'));
    await tester.pumpAndSettle();

    expect(find.byType(TagAlbumsScreen), findsOneWidget);
    expect(find.text('2 album • 2 artist'), findsOneWidget);
    expect(find.text('AlbumAlpha'), findsOneWidget);
    expect(find.text('AlbumBeta'), findsOneWidget);
    expect(find.text('AlbumOther'), findsNothing);

    // 2) Open FileGalleryViewer -> verify bottom-anchored delete confirm when Fast Delete is OFF
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey<String>('fast_delete_gallery_app'),
        theme: AppTheme.darkTheme(),
        home: FileGalleryViewer(
          manager: manager,
          images: [f1, f2, f3],
          initialIndex: 0,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('fast_delete_toggle')), findsOneWidget);
    expect(find.text('Fast Delete'), findsOneWidget);

    await tester.tap(find.text('Hapus'));
    await tester.pumpAndSettle();

    // Bottom sheet confirmation (NOT centered AlertDialog!) — buttons sit in lower thumb zone
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Pindahkan ke Sampah?'), findsOneWidget);
    final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final confirmBtnY = tester.getCenter(find.text('Batal')).dy;
    expect(confirmBtnY, greaterThan(screenH * 0.6));

    // Cancel leaves all 4 files intact
    await tester.tap(find.text('Batal'));
    await tester.pumpAndSettle();
    expect(manager.managedFiles.length, 4);

    // 3) Check Fast Delete at the top -> tapping Hapus moves to Trash IMMEDIATELY with ZERO confirmation + top Undo!
    await tester.tap(find.byKey(const ValueKey<String>('fast_delete_toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Fast Delete Aktif (hapus langsung)'), findsOneWidget);

    await tester.tap(find.text('Hapus'));
    await tester.pumpAndSettle();

    expect(find.text('Pindahkan ke Sampah?'), findsNothing);
    expect(manager.managedFiles.length, 3);
    expect(manager.trashCount, 1);
    expect(find.text('a2.jpg'), findsOneWidget);

    // Tap Urungkan on the top toast -> restores a1.jpg right back!
    expect(find.text('Urungkan'), findsOneWidget);
    await tester.tap(find.text('Urungkan'));
    await tester.pumpAndSettle();
    expect(manager.managedFiles.length, 4);
    expect(manager.trashCount, 0);
    expect(find.text('a1.jpg'), findsOneWidget);

    manager.dispose();
  });

  testWidgets(
      'Global TagExplorerScreen multi-tag AND/Exclude filter, Security PIN lock, and TrashScreen work end-to-end',
      (WidgetTester tester) async {
    ManagedFile mkFile(String artist, String album, String name, int minute) =>
        ManagedFile(
          fileName: name,
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 2048,
          modifiedAt: DateTime(2026, 11, 26, 10, minute),
          relativePath: 'Pixiv/$artist/$album',
          savedPath: '/nonexistent/$artist/$album/$name',
          contentUri: 'content://test/$artist/$album/$name',
          platformFolder: 'Pixiv',
          creatorFolder: artist,
          albumFolder: album,
          isPrivate: true,
        );

    final f1 = mkFile('ArtistOne', 'AlbumBoth', 'a1.jpg', 10);
    final f2 = mkFile('ArtistTwo', 'AlbumFantasyOnly', 'b1.jpg', 11);
    final f3 = mkFile('ArtistTwo', 'AlbumWithSketch', 'c1.jpg', 12);

    final manager = _FakeFilesManager([f1, f2, f3], const {});
    await manager.saveAlbumMetadata(
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistOne',
      albumFolder: 'AlbumBoth',
      tags: const ['Fantasy', 'Original'],
    );
    await manager.saveAlbumMetadata(
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistTwo',
      albumFolder: 'AlbumFantasyOnly',
      tags: const ['Fantasy'],
    );
    await manager.saveAlbumMetadata(
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistTwo',
      albumFolder: 'AlbumWithSketch',
      tags: const ['Fantasy', 'Original', 'Sketch'],
    );

    // 1) Multi-tag AND + Exclude in DownloadManager & TagExplorerScreen
    expect(manager.getAllTagSummaries().first.tag, 'Fantasy');
    expect(manager.getAllTagSummaries().first.albumCount, 3);
    expect(
      manager.findAlbumsByTags(
        includeTags: {'Fantasy', 'Original'},
        excludeTags: {'Sketch'},
      ).map((e) => e.albumName).toList(),
      ['AlbumBoth'],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: TagExplorerScreen(manager: manager),
      ),
    );
    await tester.pump();
    expect(find.text('Penjelajah Tag'), findsOneWidget);
    expect(find.text('#Fantasy (3)'), findsOneWidget);
    expect(find.text('#Original (2)'), findsOneWidget);

    // Tap #Fantasy and #Original -> narrows from 3 albums down to 2 (AlbumBoth + AlbumWithSketch)
    await tester.tap(find.text('#Fantasy (3)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#Original (2)'));
    await tester.pumpAndSettle();
    expect(find.text('AlbumFantasyOnly'), findsNothing);
    expect(find.text('AlbumBoth'), findsOneWidget);
    expect(find.text('AlbumWithSketch'), findsOneWidget);

    // Long-press #Sketch -> excludes AlbumWithSketch -> only AlbumBoth remains!
    await tester.longPress(find.text('#Sketch (1)'));
    await tester.pumpAndSettle();
    expect(find.text('AlbumWithSketch'), findsNothing);
    expect(find.text('AlbumBoth'), findsOneWidget);

    // 2) Security PIN hashing & SecurityLockScreen unlock
    final pinHash = AppSettings.hashPin('2468');
    await manager.updateSettings(
      manager.settings.copyWith(
        appLockEnabled: true,
        appLockPinHash: pinHash,
        appLockUseBiometric: false,
      ),
    );
    expect(manager.settings.verifyPin('2468'), isTrue);
    expect(manager.settings.verifyPin('1111'), isFalse);

    bool unlocked = false;
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey<String>('security_lock_app'),
        theme: AppTheme.darkTheme(),
        home: SecurityLockScreen(
          manager: manager,
          autoTriggerBiometric: false,
          onUnlocked: () => unlocked = true,
        ),
      ),
    );
    await tester.pump();
    for (final digit in ['2', '4', '6', '8']) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    expect(unlocked, isTrue);

    // 3) TrashScreen displays trashed items and restores cleanly
    await manager.moveManagedFilesToTrash([f2]);
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey<String>('trash_screen_app'),
        theme: AppTheme.darkTheme(),
        home: TrashScreen(manager: manager),
      ),
    );
    await tester.pump();
    expect(find.text('Tempat Sampah'), findsOneWidget);
    expect(find.text('b1.jpg'), findsOneWidget);

    await tester.tap(find.text('b1.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pulihkan').last);
    await tester.pumpAndSettle();
    expect(manager.trashCount, 0);
    expect(find.text('Tempat Sampah Kosong'), findsOneWidget);
    dismissTopToast();
    await tester.pumpAndSettle();

    manager.dispose();
  });

  testWidgets(
      'RouteAwareListenableBuilder suppresses hidden rebuilds when covered by a pushed route',
      (WidgetTester tester) async {
    final notifier = ChangeNotifier();
    var baseBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: RouteAwareListenableBuilder(
              listenable: notifier,
              builder: (_) {
                baseBuilds++;
                return ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (ctx) => Scaffold(
                          body: ElevatedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('PopBack'),
                          ),
                        ),
                      ),
                    );
                  },
                  child: Text('Builds: $baseBuilds'),
                );
              },
            ),
          ),
        ),
      ),
    );
    expect(baseBuilds, 1);

    // Push a second screen on top -> base route is no longer current
    await tester.tap(find.text('Builds: 1'));
    await tester.pumpAndSettle();
    final buildsAfterPush = baseBuilds;

    // Fire 10 notifications while covered -> base route MUST do 0 rebuilds!
    for (int i = 0; i < 10; i++) {
      notifier.notifyListeners();
    }
    await tester.pump();
    expect(baseBuilds, buildsAfterPush);

    // Pop back -> rebuilds cleanly once!
    await tester.tap(find.text('PopBack'));
    await tester.pumpAndSettle();
    expect(baseBuilds, greaterThan(buildsAfterPush));

    notifier.dispose();
  });

  testWidgets(
      'FilesScreen progressive windowing handles 200+ artists & non-blocking setPhotoRating preserves visible list',
      (WidgetTester tester) async {
    final files = List<ManagedFile>.generate(
      240,
      (i) => ManagedFile(
        fileName: 'photo_$i.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 4096,
        modifiedAt: DateTime(2026, 11, 27, 10, i % 60),
        relativePath: 'Privat/Pixiv/Artist_${i.toString().padLeft(3, '0')}/AlbumA',
        savedPath: '/nonexistent/a_$i.jpg',
        contentUri: 'content://test/scale/$i',
        platformFolder: 'Pixiv',
        creatorFolder: 'Artist_${i.toString().padLeft(3, '0')}',
        albumFolder: 'AlbumA',
        isPrivate: true,
      ),
    );
    final manager = _FakeFilesManager(files, const {});

    // Verify incremental visibleManagedFiles cache preserves identical() when rating changes between two visible states
    await manager.updateSettings(
      manager.settings.copyWith(
        showNormalContent: true,
        showEcchiContent: true,
        showNsfwContent: false,
      ),
    );
    final beforeRef = manager.visibleManagedFiles;
    await manager.setPhotoRating(files.first, ContentRating.ecchi);
    final afterVisibleChangeRef = manager.visibleManagedFiles;
    expect(identical(beforeRef, afterVisibleChangeRef), isTrue);

    // Changing to hidden NSFW incrementally removes ONLY that 1 photo!
    await manager.setPhotoRating(files.first, ContentRating.nsfw);
    expect(manager.visibleManagedFiles.length, 239);

    // Restore all visible and open Pixiv artist list -> progressive windowing caps initial render to 150 of 240!
    await manager.updateSettings(
      manager.settings.copyWith(showNsfwContent: true),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: SafeArea(child: FilesScreen(manager: manager)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Pixiv'));
    await tester.pumpAndSettle();

    expect(find.text('Semua Foto'), findsOneWidget);
    expect(find.text('240 foto • 240 artist • Acak & slide'), findsOneWidget);

    manager.dispose();
  });

  testWidgets(
      'Real DownloadManager auto-prunes Curated Catalog on delete/trash, restores on Undo, and renders CuratedCatalogScreen',
      (WidgetTester tester) async {
    final mockBridge = _CuratedMockBridge();
    final files = [
      for (int i = 1; i <= 4; i++)
        ManagedFile(
          fileName: 'Sunset_$i.jpg',
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 2048,
          modifiedAt: DateTime(2026, 11, 27, 10, i),
          relativePath: 'Privat/Pixiv/ArtistOne/Sunset',
          savedPath: '/vault/Pixiv/ArtistOne/Sunset/Sunset_$i.jpg',
          contentUri: '',
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistOne',
          albumFolder: 'Sunset',
          isPrivate: true,
        ),
    ];
    mockBridge.diskFiles.addAll(files);

    final manager = DownloadManager(
      bridge: mockBridge,
      storage: _MemoryStorageService(),
    );
    await manager.refreshManagedFiles(force: true);
    expect(manager.managedFiles.length, 4);

    // Seed album metadata with pixivIllustId -> Sync from Device captures all 4 kept files!
    await manager.saveAlbumMetadata(
      platformFolder: 'Pixiv',
      creatorFolder: 'ArtistOne',
      albumFolder: 'Sunset',
      pixivIllustId: '77001',
      tags: const ['Sky'],
    );
    final syncRes = await manager.syncCuratedCatalogWithDeviceFiles();
    expect(syncRes.addedFiles, 4);
    expect(manager.curatedKeptFilesCount, 4);
    expect(manager.isMarkedDownloaded('pixiv:77001'), isTrue);

    // Permanently delete Sunset_1.jpg -> pruned immediately from curatedCatalog!
    await manager.deleteManagedFile(files[0], permanent: true);
    expect(manager.curatedKeptFilesCount, 3);
    expect(
      manager.curatedCatalogMap['pixiv:77001']!.keptFiles
          .map((e) => e.fileName)
          .toList(),
      ['Sunset_2.jpg', 'Sunset_3.jpg', 'Sunset_4.jpg'],
    );

    // Move Sunset_3.jpg to Trash -> pruned from curatedCatalog, then Undo restores it!
    final trashed = await manager.moveManagedFilesToTrash([files[2]]);
    expect(trashed.length, 1);
    expect(manager.curatedKeptFilesCount, 2);
    expect(
      manager.curatedCatalogMap['pixiv:77001']!.keptFiles
          .map((e) => e.fileName)
          .toList(),
      ['Sunset_2.jpg', 'Sunset_4.jpg'],
    );

    await manager.restoreTrashItems([trashed.first.id]);
    expect(manager.curatedKeptFilesCount, 3);
    expect(
      manager.curatedCatalogMap['pixiv:77001']!.keptFiles
          .map((e) => e.fileName)
          .toList(),
      ['Sunset_2.jpg', 'Sunset_3.jpg', 'Sunset_4.jpg'],
    );

    // Simulate all photos wiped from phone -> CuratedCatalogScreen shows 3 hilang!
    mockBridge.diskFiles.clear();
    await manager.refreshManagedFiles(force: true);
    expect(manager.managedFiles, isEmpty);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: CuratedCatalogScreen(manager: manager),
      ),
    );
    await tester.pump();

    expect(find.text('Katalog Kurasi'), findsOneWidget);
    expect(find.text('Pulihkan 3 Foto Pilihan Yang Hilang'), findsOneWidget);
    expect(find.text('Sunset'), findsOneWidget);
    expect(find.text('3 hilang'), findsOneWidget);

    // Tap Sunset -> shows exact kept filenames & page numbers
    await tester.tap(find.text('Sunset'));
    await tester.pumpAndSettle();
    expect(find.text('Sunset_2.jpg'), findsOneWidget);
    expect(find.text('Sunset_3.jpg'), findsOneWidget);
    expect(find.text('Sunset_4.jpg'), findsOneWidget);
    expect(find.text('Sunset_1.jpg'), findsNothing);

    // Regression test: real DownloadManager.refreshManagedFiles with 1,500 files (>200KB packed TSV)
    // MUST parse cleanly via background Isolate.run without capturing DownloadManager `this`!
    mockBridge.diskFiles.clear();
    for (int i = 0; i < 1500; i++) {
      mockBridge.diskFiles.add(
        ManagedFile(
          fileName: 'LargeCollection_${i}_page.jpg',
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 8192 + i,
          modifiedAt: DateTime(2026, 11, 27, 10, i % 60),
          relativePath: 'Privat/Pixiv/BigArtist/Album_${i % 100}',
          savedPath: '/sdcard/Documents/.all_download_vault/media/Pixiv/BigArtist/Album_${i % 100}/LargeCollection_${i}_page.jpg',
          contentUri: '',
          platformFolder: 'Pixiv',
          creatorFolder: 'BigArtist',
          albumFolder: 'Album_${i % 100}',
          isPrivate: true,
        ),
      );
    }
    await tester.runAsync(() => manager.refreshManagedFiles(force: true));
    expect(manager.managedFiles.length, 1500);

    manager.dispose();
  });

  testWidgets(
      'Pixiv Ugoira album cover and gallery tiles render frame-0 VideoFirstFrameThumbnail',
      (WidgetTester tester) async {
    final tmpDir = Directory.systemTemp.createTempSync('ugoira_thumb_test_');
    addTearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });
    // Minimal valid 1x1 transparent PNG bytes for frame-0 cache fixture.
    final frame0File = File('${tmpDir.path}/frame0.png')
      ..writeAsBytesSync(const <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ]);

    final ugoiraPath = '${tmpDir.path}/AnimatedDance_ugoira.mp4';
    VideoFirstFrameThumbnail.seedCache(ugoiraPath, frame0File.path);
    expect(
      VideoFirstFrameThumbnail.peekCachedPath(ugoiraPath),
      frame0File.path,
    );

    final ugoiraFile = ManagedFile(
      fileName: 'AnimatedDance_ugoira.mp4',
      mimeType: 'video/mp4',
      mediaKind: MediaKind.video,
      fileSize: 512000,
      modifiedAt: DateTime(2026, 11, 27, 10, 0),
      relativePath: 'Privat/Pixiv/UgoiraArtist/AnimatedDance',
      savedPath: ugoiraPath,
      contentUri: '',
      platformFolder: 'Pixiv',
      creatorFolder: 'UgoiraArtist',
      albumFolder: 'AnimatedDance',
      isPrivate: true,
    );

    final manager = _FakeFilesManager([ugoiraFile], const {});

    // 1) FilesScreen -> Pixiv -> UgoiraArtist -> Album grid shows VideoFirstFrameThumbnail with frame-0 Image!
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(body: FilesScreen(manager: manager)),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Pixiv'));
    await tester.pumpAndSettle();
    expect(find.byType(VideoFirstFrameThumbnail), findsOneWidget);

    await tester.tap(find.text('UgoiraArtist'));
    await tester.pumpAndSettle();

    expect(find.text('AnimatedDance'), findsOneWidget);
    expect(find.byType(VideoFirstFrameThumbnail), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    // 2) PixivAlbumViewer Grid view also renders VideoFirstFrameThumbnail for Ugoira pages!
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey<String>('ugoira_album_viewer_app'),
        theme: AppTheme.darkTheme(),
        home: PixivAlbumViewer(
          manager: manager,
          platformFolder: 'Pixiv',
          creatorFolder: 'UgoiraArtist',
          albumName: 'AnimatedDance',
          albumNames: const ['AnimatedDance'],
          initialAlbumIndex: 0,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Mode Album / Galeri'));
    await tester.pumpAndSettle();

    expect(find.byType(VideoFirstFrameThumbnail), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    manager.dispose();
  });
}

class _CuratedMockBridge extends NativeBridge {
  final List<ManagedFile> diskFiles = [];
  final Map<String, ManagedFile> trashedById = {};
  int _seq = 0;

  @override
  Future<String?> listManagedFilesPacked() async =>
      encodePackedManagedFiles(diskFiles);

  @override
  Future<List<ManagedFile>> listManagedFiles() async =>
      List<ManagedFile>.from(diskFiles);

  @override
  Future<bool> deleteFile({String? filePath, String? contentUri}) async {
    diskFiles.removeWhere((f) => f.savedPath == filePath);
    return true;
  }

  @override
  Future<List<TrashItem>> moveFilesToTrash(List<ManagedFile> files) async {
    final out = <TrashItem>[];
    for (final f in files) {
      diskFiles.removeWhere((x) => x.savedPath == f.savedPath);
      final id = 'mock_trash_${++_seq}';
      trashedById[id] = f;
      out.add(
        TrashItem(
          id: id,
          trashPath: '/trash/$id',
          originalPath: f.savedPath,
          fileName: f.fileName,
          mimeType: f.mimeType,
          mediaKind: f.mediaKind.name,
          fileSize: f.fileSize,
          isPrivate: f.isPrivate,
          platformFolder: f.platformFolder,
          creatorFolder: f.creatorFolder,
          albumFolder: f.effectiveAlbumName,
          deletedAt: DateTime.now(),
        ),
      );
    }
    return out;
  }

  @override
  Future<int> restoreTrashItems(List<String> ids) async {
    var count = 0;
    for (final id in ids) {
      final f = trashedById.remove(id);
      if (f != null) {
        diskFiles.add(f);
        count++;
      }
    }
    return count;
  }
}
