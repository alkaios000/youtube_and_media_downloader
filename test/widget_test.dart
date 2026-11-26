import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkdrop_downloader/models/app_settings.dart';
import 'package:linkdrop_downloader/models/creator_profile.dart';
import 'package:linkdrop_downloader/models/download_item.dart';
import 'package:linkdrop_downloader/models/managed_file.dart';
import 'package:linkdrop_downloader/models/media_info.dart';
import 'package:linkdrop_downloader/models/media_platform.dart';
import 'package:linkdrop_downloader/screens/downloads_screen.dart';
import 'package:linkdrop_downloader/screens/files_screen.dart';
import 'package:linkdrop_downloader/screens/home_shell.dart';
import 'package:linkdrop_downloader/screens/settings_screen.dart';
import 'package:linkdrop_downloader/services/download_manager.dart';
import 'package:linkdrop_downloader/theme/app_theme.dart';
import 'package:linkdrop_downloader/widgets/media_preview_card.dart';
import 'package:linkdrop_downloader/widgets/pixiv_album_viewer.dart';

class _FakeFilesManager extends DownloadManager {
  final List<ManagedFile> _fakeFiles;
  final Map<String, CreatorProfileRecord> _fakeProfiles;
  final List<DownloadItem> fakeItems;

  _FakeFilesManager(
    this._fakeFiles,
    this._fakeProfiles, {
    this.fakeItems = const [],
  });

  @override
  List<ManagedFile> get managedFiles => _fakeFiles;

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
}
