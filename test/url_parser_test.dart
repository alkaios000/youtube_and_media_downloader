import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linkdrop_downloader/models/media_info.dart';
import 'package:linkdrop_downloader/models/media_platform.dart';
import 'package:linkdrop_downloader/services/media_extractor_service.dart';
import 'package:linkdrop_downloader/services/native_bridge.dart';

void main() {
  group('UrlParser.extractUrl & detectPlatform', () {
    test('detects YouTube standard, shorts, and youtu.be URLs', () {
      const urls = [
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://youtu.be/dQw4w9WgXcQ?si=abc123',
        'https://youtube.com/shorts/abcdefghijk',
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
      ];
      for (final u in urls) {
        expect(UrlParser.extractUrl(u), isNotNull);
        expect(UrlParser.detectPlatform(u), MediaPlatform.youtube);
      }
    });

    test('detects TikTok short and full share text', () {
      const shareText =
          'Lihat video keren ini! https://vt.tiktok.com/ZSF123abc/ #fyp';
      final extracted = UrlParser.extractUrl(shareText);
      expect(extracted, 'https://vt.tiktok.com/ZSF123abc/');
      expect(UrlParser.detectPlatform(shareText), MediaPlatform.tiktok);
    });

    test('extracts clean Douyin URL from Chinese share text', () {
      const douyinShare =
          '7.43 复制打开抖音，看看【摄影师的作品】太美了！ https://v.douyin.com/iRNB2xyz/ 复制此链接，打开Dou音搜索';
      final extracted = UrlParser.extractUrl(douyinShare);
      expect(extracted, 'https://v.douyin.com/iRNB2xyz/');
      expect(UrlParser.detectPlatform(douyinShare), MediaPlatform.douyin);
    });

    test('detects Instagram Reels and Posts', () {
      const reel = 'https://www.instagram.com/reel/C9xYz123AbC/?igsh=abcd==';
      expect(UrlParser.extractUrl(reel), reel);
      expect(UrlParser.detectPlatform(reel), MediaPlatform.instagram);
    });

    test('detects X and legacy Twitter links', () {
      const xPost = 'Check this out: https://x.com/flutterdev/status/1800000000000000000.';
      final extracted = UrlParser.extractUrl(xPost);
      expect(extracted, 'https://x.com/flutterdev/status/1800000000000000000');
      expect(UrlParser.detectPlatform(xPost), MediaPlatform.x);
      expect(
        UrlParser.detectPlatform('https://twitter.com/user/status/12345'),
        MediaPlatform.x,
      );
    });

    test('handles bare domains without https prefix', () {
      final extracted = UrlParser.extractUrl('youtu.be/abc123XYZ');
      expect(extracted, 'https://youtu.be/abc123XYZ');
      expect(UrlParser.detectPlatform(extracted!), MediaPlatform.youtube);
    });

    test('returns null for non-URL text', () {
      expect(UrlParser.extractUrl('halo dunia tanpa tautan'), isNull);
    });
  });

  group('MediaExtractorService.parseYtDlpJson', () {
    test('parses multi-resolution YouTube JSON into quality + audio options', () {
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
          {
            'format_id': '135',
            'vcodec': 'avc1.4d401e',
            'acodec': 'none',
            'height': 480,
            'filesize': 10000000,
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
      expect(info.options.any((o) => o.id == 'ytdlp_best'), isTrue);
      expect(info.options.any((o) => o.height == 1080), isTrue);
      expect(info.options.any((o) => o.height == 720), isTrue);
      expect(info.options.any((o) => o.height == 480), isTrue);
      expect(
        info.options.any((o) => o.kind == MediaKind.audio && o.extension == 'mp3'),
        isTrue,
      );
      expect(
        info.options.any((o) => o.kind == MediaKind.audio && o.extension == 'm4a'),
        isTrue,
      );
    });
  });
}
