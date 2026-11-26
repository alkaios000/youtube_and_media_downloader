import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkdrop_downloader/models/app_settings.dart';
import 'package:linkdrop_downloader/models/creator_profile.dart';
import 'package:linkdrop_downloader/models/download_item.dart';
import 'package:linkdrop_downloader/models/managed_file.dart';
import 'package:linkdrop_downloader/models/media_info.dart';
import 'package:linkdrop_downloader/models/media_platform.dart';
import 'package:linkdrop_downloader/services/media_extractor_service.dart';
import 'package:linkdrop_downloader/services/native_bridge.dart';
import 'package:linkdrop_downloader/services/storage_service.dart';

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
}
