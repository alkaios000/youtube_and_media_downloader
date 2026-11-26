import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

/// Smooth hardware-accelerated in-app Video & Pixiv Ugoira player backed by
/// Flutter's `video_player` (Android Media3 ExoPlayer).
///
/// Supports two modes:
/// - **Inline Ugoira loop mode** (`inlineLoop: true`): auto-plays, loops muted
///   inside `PixivAlbumViewer` with natural aspect ratio & tap-to-fullscreen.
/// - **Fullscreen playback mode** (`inlineLoop: false`): used inside
///   `FileGalleryViewer` so videos & Ugoira swipe seamlessly alongside photos
///   with thumb-friendly seek slider, play/pause, mute, loop, and speed toggle.
class InAppVideoPlayer extends StatefulWidget {
  final String filePath;
  final bool inlineLoop;
  final bool autoLoop;
  final bool showControls;
  final VoidCallback? onTapSurface;
  final VoidCallback? onOpenExternal;

  const InAppVideoPlayer({
    super.key,
    required this.filePath,
    this.inlineLoop = false,
    this.autoLoop = true,
    this.showControls = true,
    this.onTapSurface,
    this.onOpenExternal,
  });

  @override
  State<InAppVideoPlayer> createState() => _InAppVideoPlayerState();
}

class _InAppVideoPlayerState extends State<InAppVideoPlayer> {
  static const List<double> _speeds = [0.5, 1.0, 1.5, 2.0];

  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _hasError = false;
  bool _muted = false;
  double _speed = 1.0;
  bool _isScrubbing = false;
  double _scrubMs = 0;

  @override
  void initState() {
    super.initState();
    _muted = widget.inlineLoop;
    unawaited(_initController());
  }

  @override
  void didUpdateWidget(covariant InAppVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      unawaited(_reinit());
    }
  }

  Future<void> _reinit() async {
    final old = _controller;
    _controller = null;
    if (mounted) {
      setState(() {
        _initialized = false;
        _hasError = false;
      });
    }
    await old?.dispose();
    await _initController();
  }

  Future<void> _initController() async {
    final path = widget.filePath.trim();
    if (path.isEmpty) {
      if (mounted) setState(() => _hasError = true);
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      if (mounted) setState(() => _hasError = true);
      return;
    }

    final ctrl = VideoPlayerController.file(file);
    _controller = ctrl;
    try {
      await ctrl.initialize();
      if (!mounted || _controller != ctrl) {
        await ctrl.dispose();
        return;
      }
      final shouldLoop =
          widget.inlineLoop || widget.autoLoop || ctrl.value.duration.inSeconds <= 20;
      await ctrl.setLooping(shouldLoop);
      await ctrl.setVolume(_muted ? 0.0 : 1.0);
      await ctrl.play();
      ctrl.addListener(_onPlayerTick);
      if (mounted) {
        setState(() {
          _initialized = true;
          _hasError = false;
        });
      }
    } catch (_) {
      await ctrl.dispose();
      if (_controller == ctrl) _controller = null;
      if (mounted) setState(() => _hasError = true);
    }
  }

  void _onPlayerTick() {
    if (!mounted || _isScrubbing) return;
    setState(() {});
  }

  @override
  void dispose() {
    final ctrl = _controller;
    _controller = null;
    ctrl?.removeListener(_onPlayerTick);
    ctrl?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    final ctrl = _controller;
    if (ctrl == null || !_initialized) return;
    HapticFeedback.selectionClick();
    if (ctrl.value.isPlaying) {
      ctrl.pause();
    } else {
      ctrl.play();
    }
    setState(() {});
  }

  void _toggleMute() {
    final ctrl = _controller;
    if (ctrl == null || !_initialized) return;
    HapticFeedback.selectionClick();
    setState(() => _muted = !_muted);
    ctrl.setVolume(_muted ? 0.0 : 1.0);
  }

  void _cycleSpeed() {
    final ctrl = _controller;
    if (ctrl == null || !_initialized) return;
    HapticFeedback.selectionClick();
    final nextIdx = (_speeds.indexOf(_speed) + 1) % _speeds.length;
    setState(() => _speed = _speeds[nextIdx]);
    ctrl.setPlaybackSpeed(_speed);
  }

  String _fmtDuration(Duration d) {
    final totalSec = d.inSeconds.clamp(0, 359999);
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return _buildErrorFallback(context);
    }

    final ctrl = _controller;
    if (!_initialized || ctrl == null) {
      return Container(
        height: widget.inlineLoop ? 260 : null,
        color: Colors.black,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            strokeWidth: 2.6,
            color: Colors.white70,
          ),
        ),
      );
    }

    final ratio = ctrl.value.aspectRatio > 0.05 ? ctrl.value.aspectRatio : 16 / 9;
    final isPlaying = ctrl.value.isPlaying;
    final durationMs = ctrl.value.duration.inMilliseconds.toDouble();
    final posMs = _isScrubbing
        ? _scrubMs
        : ctrl.value.position.inMilliseconds
            .toDouble()
            .clamp(0.0, durationMs > 0 ? durationMs : 1.0);

    if (widget.inlineLoop) {
      return AspectRatio(
        aspectRatio: ratio.clamp(0.35, 3.0),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: Colors.black,
              child: VideoPlayer(ctrl),
            ),
            // Subtle bottom-right inline controls (Play/Pause & Mute)
            Positioned(
              right: 8,
              bottom: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MiniOverlayPill(
                    icon: isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    onTap: _togglePlayPause,
                  ),
                  const SizedBox(width: 6),
                  _MiniOverlayPill(
                    icon: _muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    onTap: _toggleMute,
                  ),
                ],
              ),
            ),
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.animation_rounded,
                      size: 12,
                      color: Color(0xFF38BDF8),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _fmtDuration(ctrl.value.duration),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Fullscreen player (inside FileGalleryViewer)
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTapSurface ?? _togglePlayPause,
      onDoubleTap: _togglePlayPause,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: ratio,
              child: VideoPlayer(ctrl),
            ),
          ),
          if (widget.showControls) ...[
            // Center play/pause button
            Center(
              child: GestureDetector(
                onTap: _togglePlayPause,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 160),
                  opacity: isPlaying ? 0.72 : 0.96,
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.56),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.35),
                        width: 1.2,
                      ),
                    ),
                    child: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                ),
              ),
            ),
            // Compact scrubber bar seated directly above FileGalleryViewer's bottom action bar
            Positioned(
              left: 12,
              right: 12,
              bottom: 92,
              child: SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _fmtDuration(Duration(milliseconds: posMs.round())),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 13,
                            ),
                          ),
                          child: Slider(
                            value: durationMs > 0
                                ? posMs.clamp(0.0, durationMs)
                                : 0.0,
                            min: 0.0,
                            max: durationMs > 0 ? durationMs : 1.0,
                            activeColor: const Color(0xFF38BDF8),
                            inactiveColor: Colors.white24,
                            onChangeStart: (v) {
                              setState(() {
                                _isScrubbing = true;
                                _scrubMs = v;
                              });
                            },
                            onChanged: (v) {
                              setState(() => _scrubMs = v);
                            },
                            onChangeEnd: (v) {
                              ctrl.seekTo(Duration(milliseconds: v.round()));
                              setState(() => _isScrubbing = false);
                            },
                          ),
                        ),
                      ),
                      Text(
                        _fmtDuration(ctrl.value.duration),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: _cycleSpeed,
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${_speed == _speed.roundToDouble() ? _speed.toInt() : _speed}x',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: _toggleMute,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            _muted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorFallback(BuildContext context) {
    return Container(
      height: widget.inlineLoop ? 220 : null,
      color: const Color(0xFF0F172A),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.play_circle_outline_rounded,
            size: 52,
            color: Colors.white70,
          ),
          const SizedBox(height: 8),
          const Text(
            'Video / Ugoira tidak dapat diputar di sini',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
            ),
          ),
          if (widget.onOpenExternal != null) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: widget.onOpenExternal,
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Buka di App Lain'),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniOverlayPill extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _MiniOverlayPill({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.62),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}
