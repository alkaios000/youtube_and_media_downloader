import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

OverlayEntry? _activeTopToastEntry;
VoidCallback? _dismissActiveTopToast;

/// Immediately removes any visible top toast notification.
void dismissTopToast() {
  _dismissActiveTopToast?.call();
}

/// Displays a sleek, non-blocking notification pill anchored at the **TOP** of
/// the screen (below the status bar) so it NEVER covers bottom action bars,
/// navigation controls, or thumb-zone buttons.
void showTopToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 2),
  IconData? icon,
  Color? accentColor,
  bool isError = false,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  // Replace any currently visible toast cleanly (no stacking).
  _activeTopToastEntry?.remove();
  _activeTopToastEntry = null;
  _dismissActiveTopToast = null;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) => _TopToastBanner(
      message: message,
      duration: duration,
      icon: icon,
      accentColor: accentColor,
      isError: isError,
      onRemove: () {
        if (_activeTopToastEntry == entry) {
          _activeTopToastEntry = null;
          _dismissActiveTopToast = null;
        }
        if (entry.mounted) {
          entry.remove();
        }
      },
      onRegisterDismiss: (fn) {
        if (_activeTopToastEntry == entry) {
          _dismissActiveTopToast = fn;
        }
      },
    ),
  );

  _activeTopToastEntry = entry;
  overlay.insert(entry);
}

class _TopToastBanner extends StatefulWidget {
  final String message;
  final Duration duration;
  final IconData? icon;
  final Color? accentColor;
  final bool isError;
  final VoidCallback onRemove;
  final ValueChanged<VoidCallback> onRegisterDismiss;

  const _TopToastBanner({
    required this.message,
    required this.duration,
    required this.onRemove,
    required this.onRegisterDismiss,
    this.icon,
    this.accentColor,
    this.isError = false,
  });

  @override
  State<_TopToastBanner> createState() => _TopToastBannerState();
}

class _TopToastBannerState extends State<_TopToastBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _fadeAnim;
  Timer? _autoDismissTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 170),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -1.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    widget.onRegisterDismiss(_dismiss);
    _controller.forward();
    _autoDismissTimer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    try {
      await _controller.reverse();
    } catch (_) {}
    if (mounted) {
      widget.onRemove();
    }
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final topPad = MediaQuery.paddingOf(context).top;
    final accent = widget.isError
        ? theme.colorScheme.error
        : (widget.accentColor ?? theme.colorScheme.primary);
    final bgColor = isDark
        ? const Color(0xFF181C24).withValues(alpha: 0.96)
        : theme.colorScheme.inverseSurface;
    final fgColor = isDark
        ? Colors.white
        : theme.colorScheme.onInverseSurface;

    return Positioned(
      top: topPad + 10,
      left: 14,
      right: 14,
      child: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Dismissible(
            key: const ValueKey<String>('app_top_toast_dismissible'),
            direction: DismissDirection.up,
            onDismissed: (_) {
              _autoDismissTimer?.cancel();
              widget.onRemove();
            },
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _dismiss,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.48),
                          width: 1.1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.34),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.icon ??
                                (widget.isError
                                    ? Icons.error_outline_rounded
                                    : Icons.check_circle_rounded),
                            size: 19,
                            color: accent,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              widget.message,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: fgColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thumb-friendly bottom-anchored delete / destructive confirmation sheet.
/// Always positioned near the bottom edge so the user never has to stretch
/// their thumb to the middle of the screen to confirm deletion.
Future<bool> showBottomDeleteConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Hapus',
  String cancelLabel = 'Batal',
  IconData icon = Icons.delete_outline_rounded,
  bool destructive = true,
}) async {
  HapticFeedback.selectionClick();
  final result = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final accent =
          destructive ? theme.colorScheme.error : theme.colorScheme.primary;
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: accent, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          message,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        cancelLabel,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        confirmLabel,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return result == true;
}

/// Generic multi-choice bottom confirmation sheet (e.g., History item delete:
/// Batal / Riwayat Saja / Hapus File) placed right in the thumb zone.
class BottomActionOption<T> {
  final T value;
  final String label;
  final bool destructive;
  final bool primary;

  const BottomActionOption({
    required this.value,
    required this.label,
    this.destructive = false,
    this.primary = false,
  });
}

Future<T?> showBottomChoiceConfirm<T>(
  BuildContext context, {
  required String title,
  required String message,
  required List<BottomActionOption<T>> options,
  String cancelLabel = 'Batal',
  IconData icon = Icons.delete_outline_rounded,
}) {
  HapticFeedback.selectionClick();
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final hasDestructive = options.any((o) => o.destructive);
      final accent = hasDestructive
          ? theme.colorScheme.error
          : theme.colorScheme.primary;
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: accent, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          message,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              for (final opt in options) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: opt.destructive
                      ? FilledButton(
                          onPressed: () => Navigator.pop(ctx, opt.value),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(46),
                            backgroundColor: theme.colorScheme.error,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            opt.label,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        )
                      : FilledButton.tonal(
                          onPressed: () => Navigator.pop(ctx, opt.value),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(46),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            opt.label,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                ),
              ],
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  cancelLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
