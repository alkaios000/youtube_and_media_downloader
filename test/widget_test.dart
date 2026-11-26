import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkdrop_downloader/models/download_item.dart';
import 'package:linkdrop_downloader/models/media_info.dart';
import 'package:linkdrop_downloader/models/media_platform.dart';
import 'package:linkdrop_downloader/screens/downloads_screen.dart';
import 'package:linkdrop_downloader/screens/home_shell.dart';
import 'package:linkdrop_downloader/services/download_manager.dart';
import 'package:linkdrop_downloader/theme/app_theme.dart';
import 'package:linkdrop_downloader/widgets/media_preview_card.dart';

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

    await tester.tap(find.text('Hapus 2 Penanda'));
    await tester.pump();
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

  test('sortLoadingDownloads puts actively processing (saving/downloading) above queued & paused', () {
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

    final raw = [
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
      ['s1', 'd1', 'd2', 'q1', 'q2', 'p1'],
    );
  });
}
