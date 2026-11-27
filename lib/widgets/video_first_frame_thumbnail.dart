import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/native_bridge.dart';

/// Displays the **exact first frame (frame 0)** of a local Ugoira / video file
/// extracted natively via Android `MediaMetadataRetriever` (and pre-cached at
/// download time for newly converted Pixiv Ugoira!).
///
/// Features:
/// - Synchronous frame-0 rendering once cached in memory (ZERO flicker on scroll)
/// - Request deduplication so scrolling fast never duplicates native decodes
/// - Clean translucent play indicator overlay so animated Ugoira / videos remain
///   instantly distinguishable from still images
class VideoFirstFrameThumbnail extends StatefulWidget {
  final String filePath;
  final String? contentUri;
  final BoxFit fit;
  final int cacheWidth;
  final bool showPlayBadge;
  final double playBadgeSize;
  final String? badgeLabel;

  const VideoFirstFrameThumbnail({
    super.key,
    required this.filePath,
    this.contentUri,
    this.fit = BoxFit.cover,
    this.cacheWidth = 420,
    this.showPlayBadge = true,
    this.playBadgeSize = 36,
    this.badgeLabel,
  });

  static final NativeBridge _bridge = NativeBridge();
  static final Map<String, String> _memCache = <String, String>{};
  static final Map<String, Future<String?>> _inFlight =
      <String, Future<String?>>{};
  static final Set<String> _failedKeys = <String>{};

  static String _keyFor(String filePath, String? contentUri) {
    final p = filePath.trim();
    if (p.isNotEmpty) return p;
    return contentUri?.trim() ?? '';
  }

  /// Synchronously peeks a previously resolved thumbnail path (if still on disk).
  static String? peekCachedPath(String filePath, [String? contentUri]) {
    final key = _keyFor(filePath, contentUri);
    if (key.isEmpty) return null;
    final cached = _memCache[key];
    if (cached != null && File(cached).existsSync()) {
      return cached;
    }
    if (cached != null) _memCache.remove(key);
    return null;
  }

  /// Seeds a known thumbnail path (useful for tests or eager pre-warming).
  static void seedCache(String videoPath, String thumbPath) {
    final key = videoPath.trim();
    if (key.isEmpty || thumbPath.trim().isEmpty) return;
    _failedKeys.remove(key);
    _memCache[key] = thumbPath.trim();
  }

  static Future<String?> resolve(
    String filePath, {
    String? contentUri,
    int maxWidth = 540,
  }) {
    final key = _keyFor(filePath, contentUri);
    if (key.isEmpty) return Future.value(null);
    final hit = peekCachedPath(filePath, contentUri);
    if (hit != null) return Future.value(hit);
    if (_failedKeys.contains(key)) return Future.value(null);

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _bridge
        .getVideoThumbnail(
          filePath: filePath,
          contentUri: contentUri,
          maxWidth: maxWidth,
        )
        .then((thumbPath) {
      _inFlight.remove(key);
      if (thumbPath != null &&
          thumbPath.isNotEmpty &&
          File(thumbPath).existsSync()) {
        if (_memCache.length >= 600) {
          _memCache.remove(_memCache.keys.first);
        }
        _memCache[key] = thumbPath;
        return thumbPath;
      }
      if (_failedKeys.length >= 300) _failedKeys.clear();
      _failedKeys.add(key);
      return null;
    }).catchError((_) {
      _inFlight.remove(key);
      return null;
    });

    _inFlight[key] = future;
    return future;
  }

  @override
  State<VideoFirstFrameThumbnail> createState() =>
      _VideoFirstFrameThumbnailState();
}

class _VideoFirstFrameThumbnailState extends State<VideoFirstFrameThumbnail> {
  String? _thumbPath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VideoFirstFrameThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath ||
        oldWidget.contentUri != widget.contentUri) {
      _load();
    }
  }

  void _load() {
    final cached = VideoFirstFrameThumbnail.peekCachedPath(
      widget.filePath,
      widget.contentUri,
    );
    if (cached != null) {
      _thumbPath = cached;
      return;
    }
    _thumbPath = null;
    final reqPath = widget.filePath;
    final reqUri = widget.contentUri;
    unawaited(
      VideoFirstFrameThumbnail.resolve(
        reqPath,
        contentUri: reqUri,
        maxWidth: widget.cacheWidth.clamp(200, 540),
      ).then((resolved) {
        if (!mounted) return;
        if (widget.filePath != reqPath || widget.contentUri != reqUri) return;
        if (resolved != null && resolved != _thumbPath) {
          setState(() => _thumbPath = resolved);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _thumbPath;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumb != null)
          Image.file(
            File(thumb),
            cacheWidth: widget.cacheWidth,
            filterQuality: FilterQuality.medium,
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _buildFallback(),
          )
        else
          _buildFallback(),
        if (widget.showPlayBadge && thumb != null)
          Center(
            child: Container(
              width: widget.playBadgeSize,
              height: widget.playBadgeSize,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.48),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.72),
                  width: 1.4,
                ),
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                size: widget.playBadgeSize * 0.62,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFallback() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF0096FA).withValues(alpha: 0.35),
            const Color(0xFF1E293B),
          ],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.play_circle_filled_rounded,
            size: widget.playBadgeSize,
            color: Colors.white.withValues(alpha: 0.9),
          ),
          if (widget.badgeLabel != null && widget.badgeLabel!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              widget.badgeLabel!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
