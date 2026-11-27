import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkdrop_downloader/models/app_settings.dart';
import 'package:linkdrop_downloader/models/creator_profile.dart';
import 'package:linkdrop_downloader/models/download_item.dart';
import 'package:linkdrop_downloader/models/managed_file.dart';
import 'package:linkdrop_downloader/models/media_info.dart';
import 'package:linkdrop_downloader/models/media_metadata.dart';
import 'package:linkdrop_downloader/models/media_platform.dart';
import 'package:linkdrop_downloader/services/direct_extractors.dart';
import 'package:linkdrop_downloader/services/download_manager.dart';
import 'package:linkdrop_downloader/services/media_extractor_service.dart';
import 'package:linkdrop_downloader/services/native_bridge.dart';
import 'package:linkdrop_downloader/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('UrlParser.extractUrl, detectPlatform & inspect', () {
    test('detects YouTube videos, shorts, channels, and playlists', () {
      final vid = UrlParser.inspect('https://youtu.be/dQw4w9WgXcQ?si=abc123');
      expect(vid?.platform, MediaPlatform.youtube);
      expect(vid?.isBulk, isFalse);

      final channel = UrlParser.inspect('https://www.youtube.com/@FlutterDev');
      expect(channel?.platform, MediaPlatform.youtube);
      expect(channel?.isBulk, isTrue);

      final playlist = UrlParser.inspect(
        'https://www.youtube.com/playlist?list=PLjxrf2q8roU23XGwz3Km7sQZFTdB996iG',
      );
      expect(playlist?.platform, MediaPlatform.youtube);
      expect(playlist?.kind, LinkKind.playlist);
      expect(playlist?.isBulk, isTrue);
    });

    test('detects TikTok single links and profiles', () {
      const shareText =
          'Lihat video keren ini! https://vt.tiktok.com/ZSF123abc/ #fyp';
      expect(UrlParser.extractUrl(shareText), 'https://vt.tiktok.com/ZSF123abc/');
      expect(UrlParser.detectPlatform(shareText), MediaPlatform.tiktok);

      final profile = UrlParser.inspect('https://www.tiktok.com/@khaby.lame');
      expect(profile?.platform, MediaPlatform.tiktok);
      expect(profile?.isBulk, isTrue);
      expect(profile?.usernameHint, 'khaby.lame');
    });

    test('extracts clean Douyin URL from Chinese share text including glued CJK', () {
      const douyinShare =
          '7.43 复制打开抖音，看看【摄影师的作品】太美了！ https://v.douyin.com/iRNB2xyz/ 复制此链接，打开Dou音搜索';
      expect(UrlParser.extractUrl(douyinShare), 'https://v.douyin.com/iRNB2xyz/');
      expect(UrlParser.detectPlatform(douyinShare), MediaPlatform.douyin);

      const gluedShare = '6.17 复制打开抖音 https://v.douyin.com/CeiJ8kL/复制此链接';
      expect(UrlParser.extractUrl(gluedShare), 'https://v.douyin.com/CeiJ8kL/');
      expect(UrlParser.detectPlatform(gluedShare), MediaPlatform.douyin);
    });

    test('detects Instagram Reels, /share/reel/, Posts, and Profiles', () {
      final reel = UrlParser.inspect(
        'https://www.instagram.com/reel/C9xYz123AbC/?igsh=abcd==',
      );
      expect(reel?.platform, MediaPlatform.instagram);
      expect(reel?.isBulk, isFalse);
      expect(reel?.contentLabel, contains('Reel'));

      final shareReel = UrlParser.inspect(
        'https://www.instagram.com/share/reel/BA123xyz456/',
      );
      expect(shareReel?.platform, MediaPlatform.instagram);
      expect(shareReel?.contentLabel, contains('Reel'));

      final profile = UrlParser.inspect('https://www.instagram.com/natgeo/');
      expect(profile?.platform, MediaPlatform.instagram);
      expect(profile?.isBulk, isTrue);
      expect(profile?.usernameHint, 'natgeo');
    });

    test('detects X posts and profiles', () {
      const xPost = 'Check this out: https://x.com/flutterdev/status/1800000000000000000.';
      expect(
        UrlParser.extractUrl(xPost),
        'https://x.com/flutterdev/status/1800000000000000000',
      );
      expect(UrlParser.detectPlatform(xPost), MediaPlatform.x);

      final xProfile = UrlParser.inspect('https://x.com/flutterdev');
      expect(xProfile?.platform, MediaPlatform.x);
      expect(xProfile?.isBulk, isTrue);
      expect(xProfile?.usernameHint, 'flutterdev');
    });

    test('detects Pixiv artworks, user profiles, and pixiv:username shortcut', () {
      final art = UrlParser.inspect('https://www.pixiv.net/en/artworks/100000000');
      expect(art?.platform, MediaPlatform.pixiv);
      expect(art?.isBulk, isFalse);

      final user = UrlParser.inspect('https://www.pixiv.net/users/11');
      expect(user?.platform, MediaPlatform.pixiv);
      expect(user?.isBulk, isTrue);

      final shortcut = UrlParser.inspect('pixiv:wlop');
      expect(shortcut?.platform, MediaPlatform.pixiv);
      expect(shortcut?.isBulk, isTrue);
      expect(shortcut?.cleanUrl, contains('search_user.php'));
    });

    test('detects Facebook reels, fb.watch, share links, and pages', () {
      final fbReel = UrlParser.inspect('https://www.facebook.com/reel/1234567890');
      expect(fbReel?.platform, MediaPlatform.facebook);
      expect(fbReel?.isBulk, isFalse);

      final fbWatch = UrlParser.inspect('https://fb.watch/abc123XYZ/');
      expect(fbWatch?.platform, MediaPlatform.facebook);
      expect(fbWatch?.isBulk, isFalse);

      final fbPage = UrlParser.inspect('https://www.facebook.com/nasa');
      expect(fbPage?.platform, MediaPlatform.facebook);
      expect(fbPage?.isBulk, isTrue);
    });

    test('returns null for non-URL text', () {
      expect(UrlParser.extractUrl('halo dunia tanpa tautan'), isNull);
    });
  });

  group('MediaExtractorService.parseYtDlpJson', () {
    test('parses multi-resolution YouTube JSON into H.264-preferred quality + audio options', () {
      final service = MediaExtractorService(bridge: NativeBridge());
      final sampleJson = jsonEncode({
        'title': 'Flutter 4K Demo Video',
        'uploader': 'Flutter Channel',
        'duration': 185,
        'thumbnail': 'https://i.ytimg.com/vi/abc/hqdefault.jpg',
        'extractor_key': 'Youtube',
        'formats': [
          {
            'format_id': '140',
            'vcodec': 'none',
            'acodec': 'mp4a.40.2',
            'filesize': 3000000,
          },
          {
            'format_id': '137',
            'vcodec': 'avc1.640028',
            'acodec': 'none',
            'height': 1080,
            'filesize': 40000000,
          },
          {
            'format_id': '136',
            'vcodec': 'avc1.4d401f',
            'acodec': 'none',
            'height': 720,
            'filesize': 20000000,
          },
        ],
      });

      final info = service.parseYtDlpJson(
        sampleJson,
        'https://youtu.be/abc',
        MediaPlatform.youtube,
      );

      expect(info.title, 'Flutter 4K Demo Video');
      expect(info.author, 'Flutter Channel');
      expect(info.formattedDuration, '03:05');
      expect(info.options.first.ytDlpFormatSelector, contains('vcodec^=avc1'));
      expect(
        info.options.any((o) => o.kind == MediaKind.audio && o.extension == 'mp3'),
        isTrue,
      );
    });
  });

  group('canonicalMarkerKey', () {
    test('produces identical keys across URL variants for downloaded markers', () {
      expect(
        canonicalMarkerKey('https://www.pixiv.net/en/artworks/123456789?ref=profile'),
        'pixiv:123456789',
      );
      expect(
        canonicalMarkerKey('https://www.pixiv.net/artworks/123456789'),
        'pixiv:123456789',
      );
      expect(
        canonicalMarkerKey('https://youtu.be/dQw4w9WgXcQ?si=xyz'),
        'yt:dQw4w9WgXcQ',
      );
      expect(
        canonicalMarkerKey('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        'yt:dQw4w9WgXcQ',
      );
      expect(
        canonicalMarkerKey('https://www.instagram.com/reel/C9xYz123AbC/?igsh=123'),
        'ig:C9xYz123AbC',
      );
      expect(
        canonicalMarkerKey('https://x.com/user/status/1800000000000000000'),
        'x:1800000000000000000',
      );
      expect(
        canonicalMarkerKey('https://www.tiktok.com/@creator/video/7345678901234567890'),
        'tt:7345678901234567890',
      );
    });
  });

  group('ManagedFile album grouping & natural page sorting', () {
    test('derives album name from albumFolder or legacy page filename and sorts pages naturally', () {
      final f1 = ManagedFile(
        fileName: 'Sunset_1.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 100,
        modifiedAt: DateTime(2026),
        relativePath: 'Privat/Pixiv/Artist/Sunset',
        savedPath: '/tmp/Sunset_1.jpg',
        contentUri: '',
        platformFolder: 'Pixiv',
        creatorFolder: 'Artist',
        albumFolder: 'Sunset Album',
        isPrivate: true,
      );
      final legacy = ManagedFile(
        fileName: 'Moonlight_10.jpg',
        mimeType: 'image/jpeg',
        mediaKind: MediaKind.image,
        fileSize: 100,
        modifiedAt: DateTime(2026),
        relativePath: 'Pictures/all_download/Pixiv/Artist',
        savedPath: '/tmp/Moonlight_10.jpg',
        contentUri: '',
        platformFolder: 'Pixiv',
        creatorFolder: 'Artist',
      );
      expect(f1.effectiveAlbumName, 'Sunset Album');
      expect(f1.isPrivate, isTrue);
      expect(legacy.effectiveAlbumName, 'Moonlight');
      expect(legacy.isPrivate, isFalse);

      final names = ['art_10.jpg', 'art_2.jpg', 'art_1.jpg', 'art_11.jpg'];
      names.sort(naturalCompareFileNames);
      expect(names, ['art_1.jpg', 'art_2.jpg', 'art_10.jpg', 'art_11.jpg']);
    });
  });

  group('CreatorProfileRecord & Settings Backup Export/Import', () {
    test('normalizes lookupKey consistently and round-trips backup JSON with paused items', () {
      final profile = CreatorProfileRecord(
        platform: MediaPlatform.pixiv,
        creatorFolder: 'WLOP / Artist:01',
        displayName: 'WLOP',
        profileUrl: 'https://www.pixiv.net/users/2188232',
        lastSyncedAt: DateTime(2026, 5, 1),
      );
      expect(
        profile.lookupKey,
        CreatorProfileRecord.buildLookupKey('Pixiv', 'WLOP _ Artist_01'),
      );

      final pausedItem = DownloadItem(
        id: 'task_paused_1',
        title: 'Demo Video',
        author: 'Creator',
        sourceUrl: 'https://www.tiktok.com/@creator/video/7345678901234567890',
        platform: MediaPlatform.tiktok,
        mediaKind: MediaKind.video,
        formatLabel: 'Video HD MP4',
        extension: 'mp4',
        status: DownloadStatus.paused,
        progress: 42.0,
        statusText: 'Dijeda (42%)',
        createdAt: DateTime(2026, 5, 1),
        markerKey: 'tt:7345678901234567890',
        resumePayload: const {
          'engine': 'ytDlp',
          'audioOnly': false,
        },
      );

      final storage = StorageService();
      final jsonText = storage.buildBackupJson(
        settings: const AppSettings(
          themeMode: ThemeMode.light,
          defaultQuality: DefaultQualityPreset.p1080,
          clipboardAutoDetect: false,
          useAria2c: true,
        ),
        downloadedMarkers: {'pixiv:101', 'tt:7345678901234567890'},
        creatorProfiles: [profile],
        history: [pausedItem],
      );

      final restored = storage.parseBackupJson(jsonText);
      expect(restored.settings.themeMode, ThemeMode.light);
      expect(restored.settings.defaultQuality, DefaultQualityPreset.p1080);
      expect(restored.settings.clipboardAutoDetect, isFalse);
      expect(restored.settings.useAria2c, isTrue);
      expect(restored.downloadedMarkers, containsAll(['pixiv:101', 'tt:7345678901234567890']));
      expect(restored.creatorProfiles.single.profileUrl, 'https://www.pixiv.net/users/2188232');
      expect(restored.history.single.status, DownloadStatus.paused);
      expect(restored.history.single.canResume, isTrue);
      expect(restored.history.single.resumePayload?['engine'], 'ytDlp');
    });
  });

  group('Pixiv R-18 cookie headers & Ugoira frames', () {
    test('merges Netscape & WebView Pixiv cookies and extracts x-user-id from PHPSESSID', () {
      const netscape = '''
# Netscape HTTP Cookie File
.pixiv.net\tTRUE\t/\tTRUE\t1999999999\tPHPSESSID\t98765432_secretTokenXYZ
.pixiv.net\tTRUE\t/\tTRUE\t1999999999\tdevice_token\tabcdef012345
.instagram.com\tTRUE\t/\tTRUE\t1999999999\tsessionid\tignored
''';
      final headers = DirectExtractors.buildPixivHeaders(
        cookieHeader: 'p_ab_id=3',
        customCookies: netscape,
      );
      expect(headers['Referer'], 'https://www.pixiv.net/');
      expect(headers['x-user-id'], '98765432');
      expect(headers['Cookie'], contains('PHPSESSID=98765432_secretTokenXYZ'));
      expect(headers['Cookie'], contains('device_token=abcdef012345'));
      expect(headers['Cookie'], contains('p_ab_id=3'));
      expect(headers['Cookie'], isNot(contains('sessionid=')));
    });

    test('round-trips PixivUgoiraFrame JSON', () {
      const frame = PixivUgoiraFrame(file: '000001.jpg', delayMs: 67);
      final restored = PixivUgoiraFrame.fromJson(frame.toJson());
      expect(restored.file, '000001.jpg');
      expect(restored.delayMs, 67);
    });
  });

  group('Uninstall-proof persistent vault state mirroring & auto-restore', () {
    test('mirrors settings, markers, profiles, album tags & photo ratings and restores cleanly after simulated reinstall', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});

      final tempVaultState =
          await Directory.systemTemp.createTemp('all_download_vault_test_');
      try {
        // 1) First install writes all state with persistent vault mirror enabled
        final storage1 = StorageService()
          ..setPersistentStateDir(tempVaultState.path);
        const savedSettings = AppSettings(
          themeMode: ThemeMode.light,
          maxConcurrentAlbums: 2,
          downloadRateLimitMs: 600,
          showNormalContent: true,
          showEcchiContent: true,
          showNsfwContent: false,
        );
        final profile = CreatorProfileRecord(
          platform: MediaPlatform.pixiv,
          creatorFolder: 'ArtistPersist',
          displayName: 'ArtistPersist',
          profileUrl: 'https://www.pixiv.net/users/77777',
          lastSyncedAt: DateTime(2026, 11, 26),
        );
        final albumMeta = AlbumMetadata(
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistPersist',
          albumFolder: 'Starlight',
          pixivIllustId: '55555',
          tags: const ['Original', 'Stars'],
          updatedAt: DateTime(2026, 11, 26),
        );
        final sampleFile = ManagedFile(
          fileName: 'Starlight_1.jpg',
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 2048,
          modifiedAt: DateTime(2026, 11, 26),
          relativePath: 'Privat/Pixiv/ArtistPersist/Starlight',
          savedPath: '/sdcard/Documents/.all_download_vault/media/Pixiv/ArtistPersist/Starlight/Starlight_1.jpg',
          contentUri: '',
          platformFolder: 'Pixiv',
          creatorFolder: 'ArtistPersist',
          albumFolder: 'Starlight',
          isPrivate: true,
        );

        await storage1.saveSettings(savedSettings);
        await storage1.saveDownloadedMarkers({'pixiv:55555', 'pixiv:55556'});
        await storage1.saveCreatorProfiles([profile]);
        await storage1.saveAlbumMetadata({albumMeta.lookupKey: albumMeta});
        await storage1.savePhotoRatings({sampleFile.ratingKey: ContentRating.nsfw});

        // 2) Simulate COMPLETE UNINSTALL + FRESH REINSTALL (empty SharedPreferences, brand new manager)
        SharedPreferences.setMockInitialValues({});
        final freshManager = DownloadManager(storage: StorageService());
        expect(freshManager.settings.themeMode, ThemeMode.dark);
        expect(freshManager.settings.showNsfwContent, isTrue);
        expect(freshManager.downloadedMarkers, isEmpty);

        // 3) Re-attach persistent vault directory -> EVERYTHING auto-restores!
        final ok = await freshManager.syncPersistentVaultAndState(
          overrideStateDir: tempVaultState.path,
        );
        expect(ok, isTrue);
        expect(freshManager.settings.themeMode, ThemeMode.light);
        expect(freshManager.settings.maxConcurrentAlbums, 2);
        expect(freshManager.settings.downloadRateLimitMs, 600);
        expect(freshManager.settings.showNsfwContent, isFalse);
        expect(freshManager.isMarkedDownloaded('pixiv:55555'), isTrue);
        expect(freshManager.isMarkedDownloaded('pixiv:55556'), isTrue);
        expect(
          freshManager.getCreatorProfile('Pixiv', 'ArtistPersist')?.profileUrl,
          'https://www.pixiv.net/users/77777',
        );
        expect(
          freshManager.getAlbumTags('Pixiv', 'ArtistPersist', 'Starlight'),
          ['Original', 'Stars'],
        );
        expect(freshManager.getPhotoRating(sampleFile), ContentRating.nsfw);

        freshManager.dispose();
      } finally {
        if (await tempVaultState.exists()) {
          await tempVaultState.delete(recursive: true);
        }
      }
    });
  });

  group('Extreme-scale ManagedFile packed TSV & zero-alloc natural sort', () {
    test('round-trips 5,000 ManagedFiles via packed TSV in background Isolate and sorts naturally without RegExp', () async {
      final files = List<ManagedFile>.generate(
        5000,
        (i) => ManagedFile(
          fileName: 'Artwork_${i % 25 + 1}.jpg',
          mimeType: 'image/jpeg',
          mediaKind: MediaKind.image,
          fileSize: 4096 + i,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000 + i * 1000),
          relativePath: 'Privat/Pixiv/Artist_${i % 40}/Album_${i % 200}',
          savedPath: '/sdcard/Documents/.all_download_vault/media/Pixiv/Artist_${i % 40}/Album_${i % 200}/Artwork_${i % 25 + 1}.jpg',
          contentUri: '',
          platformFolder: 'Pixiv',
          creatorFolder: 'Artist_${i % 40}',
          albumFolder: 'Album_${i % 200}',
          isPrivate: true,
        ),
      );

      final packed = await encodePackedManagedFilesInIsolate(files);
      expect(packed.length, greaterThan(65536));
      final parsed = await parsePackedManagedFilesInIsolate(packed);
      expect(parsed.length, 5000);
      expect(parsed.first.fileName, files.first.fileName);
      expect(parsed.first.ratingKey, files.first.ratingKey);
      expect(parsed.first.albumLookupKey, files.first.albumLookupKey);
      expect(parsed.last.isPrivate, isTrue);
      expect(parsed.last.fileSize, files.last.fileSize);

      final names = [
        'Page_100.jpg',
        'Page_2.jpg',
        'Page_02.jpg',
        'Page_10.jpg',
        'Page_1.jpg',
        'Page_11.jpg',
        'Page_9.jpg',
      ];
      names.sort(naturalCompareFileNames);
      expect(names, [
        'Page_1.jpg',
        'Page_2.jpg',
        'Page_02.jpg',
        'Page_9.jpg',
        'Page_10.jpg',
        'Page_11.jpg',
        'Page_100.jpg',
      ]);
    });
  });

  group('Curated Keep-Only Catalog ("Katalog Kurasi") workflow', () {
    test('records only kept pages, prunes deleted/excluded works while keeping markers finished, survives backup & reinstall', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});

      final tempVaultState =
          await Directory.systemTemp.createTemp('all_download_curated_test_');
      try {
        final storage1 = StorageService()
          ..setPersistentStateDir(tempVaultState.path);
        final manager1 = DownloadManager(storage: storage1);

        // Simulate 2 downloaded Pixiv albums + 1 skipped album ('pixiv:9003')
        await manager1.markManyDownloaded(['pixiv:9001', 'pixiv:9002', 'pixiv:9003']);
        await manager1.upsertCuratedWork(
          CuratedWorkRecord(
            markerKey: 'pixiv:9001',
            sourceUrl: 'https://www.pixiv.net/artworks/9001',
            platformFolder: 'Pixiv',
            creatorFolder: 'ArtistOne',
            albumFolder: 'Sunset',
            title: 'Sunset',
            pixivIllustId: '9001',
            totalPages: 10,
            keptFiles: const [
              CuratedKeptFile(pageIndex: 1, fileName: 'Sunset_2.jpg'),
              CuratedKeptFile(pageIndex: 4, fileName: 'Sunset_5.jpg'),
            ],
            tags: const ['Original', 'Sky'],
            updatedAt: DateTime(2026, 11, 27),
          ),
        );
        await manager1.upsertCuratedWork(
          CuratedWorkRecord(
            markerKey: 'pixiv:9002',
            sourceUrl: 'https://www.pixiv.net/artworks/9002',
            platformFolder: 'Pixiv',
            creatorFolder: 'ArtistOne',
            albumFolder: 'Cloud',
            title: 'Cloud',
            pixivIllustId: '9002',
            totalPages: 5,
            keptFiles: const [
              CuratedKeptFile(pageIndex: 0, fileName: 'Cloud_1.jpg'),
            ],
            updatedAt: DateTime(2026, 11, 27),
          ),
        );

        // User excludes Cloud ('pixiv:9002') — must disappear from curatedCatalog
        // while staying marked finished in downloadedMarkers!
        await manager1.removeCuratedWork('pixiv:9002');
        expect(manager1.curatedCatalogMap.containsKey('pixiv:9002'), isFalse);
        expect(manager1.isMarkedDownloaded('pixiv:9002'), isTrue);
        expect(manager1.isMarkedDownloaded('pixiv:9003'), isTrue);
        expect(manager1.curatedKeptWorksCount, 1);
        expect(manager1.curatedKeptFilesCount, 2);

        await manager1.flushPendingStateWrites();
        final backupJson = manager1.buildBackupJson();

        // Simulate brand-new phone (empty SharedPreferences, 0 files on disk)
        SharedPreferences.setMockInitialValues({});
        final newPhoneManager = DownloadManager(storage: StorageService());
        final parsed = newPhoneManager.parseBackupText(backupJson);
        await newPhoneManager.applyBackup(parsed, merge: false);

        // Verify ONLY the 2 kept pages of Sunset are queued as missing,
        // while Cloud ('pixiv:9002') & skipped ('pixiv:9003') stay excluded & finished!
        final status = newPhoneManager.computeCuratedCatalogStatus();
        expect(status.keptWorksCount, 1);
        expect(status.keptFilesCount, 2);
        expect(status.missingOnDeviceCount, 2);
        expect(status.excludedMarkersCount, 2);
        expect(newPhoneManager.isMarkedDownloaded('pixiv:9002'), isTrue);
        expect(newPhoneManager.isMarkedDownloaded('pixiv:9003'), isTrue);

        // Safety guard: syncing on an empty new phone MUST NOT wipe curated catalog!
        final syncEmpty =
            await newPhoneManager.syncCuratedCatalogWithDeviceFiles();
        expect(syncEmpty.skippedPruneBecauseDeviceEmpty, isTrue);
        expect(newPhoneManager.curatedKeptFilesCount, 2);

        // Persistent vault auto-restore check after simulated reinstall
        SharedPreferences.setMockInitialValues({});
        final reinstalled = DownloadManager(storage: StorageService());
        final syncedVault = await reinstalled.syncPersistentVaultAndState(
          overrideStateDir: tempVaultState.path,
        );
        expect(syncedVault, isTrue);
        expect(reinstalled.curatedKeptWorksCount, 1);
        expect(
          reinstalled.curatedCatalogMap['pixiv:9001']?.keptFiles
              .map((f) => '${f.pageIndex}:${f.fileName}')
              .toList(),
          ['1:Sunset_2.jpg', '4:Sunset_5.jpg'],
        );

        manager1.dispose();
        newPhoneManager.dispose();
        reinstalled.dispose();
      } finally {
        if (await tempVaultState.exists()) {
          await tempVaultState.delete(recursive: true);
        }
      }
    });
  });
}
