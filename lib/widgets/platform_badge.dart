import 'package:flutter/material.dart';

import '../models/media_platform.dart';

class PlatformBadge extends StatelessWidget {
  final MediaPlatform platform;
  final bool compact;

  const PlatformBadge({
    super.key,
    required this.platform,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 5,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: platform.gradientColors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            platform.icon,
            size: compact ? 13 : 15,
            color: Colors.white,
          ),
          const SizedBox(width: 5),
          Text(
            platform.label,
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

class SupportedPlatformsStrip extends StatelessWidget {
  final MediaPlatform? activePlatform;

  const SupportedPlatformsStrip({
    super.key,
    this.activePlatform,
  });

  static const List<MediaPlatform> _corePlatforms = [
    MediaPlatform.youtube,
    MediaPlatform.tiktok,
    MediaPlatform.douyin,
    MediaPlatform.instagram,
    MediaPlatform.x,
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _corePlatforms.map((platform) {
        final isActive = activePlatform == platform;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            gradient: isActive
                ? LinearGradient(colors: platform.gradientColors)
                : null,
            color: isActive
                ? null
                : (isDark
                    ? const Color(0xFF151E30)
                    : const Color(0xFFEAF0F8)),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive
                  ? Colors.white.withValues(alpha: 0.25)
                  : (isDark
                      ? const Color(0xFF26324A)
                      : const Color(0xFFD5DFEE)),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                platform.icon,
                size: 15,
                color: isActive ? Colors.white : platform.brandColor,
              ),
              const SizedBox(width: 6),
              Text(
                platform.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                  color: isActive
                      ? Colors.white
                      : (isDark
                          ? const Color(0xFFCBD5E1)
                          : const Color(0xFF334155)),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
