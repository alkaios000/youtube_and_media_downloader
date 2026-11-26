import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_platform.dart';
import '../services/download_manager.dart';
import '../widgets/clipboard_banner.dart';
import '../widgets/media_preview_card.dart';

class DownloaderScreen extends StatefulWidget {
  final DownloadManager manager;
  final TextEditingController urlController;
  final String? clipboardUrl;
  final VoidCallback onUseClipboard;
  final VoidCallback onDismissClipboard;
  final VoidCallback onOpenHistoryTab;

  const DownloaderScreen({
    super.key,
    required this.manager,
    required this.urlController,
    required this.clipboardUrl,
    required this.onUseClipboard,
    required this.onDismissClipboard,
    required this.onOpenHistoryTab,
  });

  @override
  State<DownloaderScreen> createState() => _DownloaderScreenState();
}

class _DownloaderScreenState extends State<DownloaderScreen> {
  LinkDetection? _detection;

  @override
  void initState() {
    super.initState();
    widget.urlController.addListener(_onTextChanged);
    _onTextChanged();
  }

  @override
  void dispose() {
    widget.urlController.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final text = widget.urlController.text;
    final next = UrlParser.inspect(text);
    if (next?.cleanUrl != _detection?.cleanUrl ||
        next?.platform != _detection?.platform ||
        next?.contentLabel != _detection?.contentLabel) {
      setState(() => _detection = next);
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      _showSnack('Clipboard kosong. Salin tautan terlebih dahulu.');
      return;
    }
    final clean = UrlParser.extractUrl(raw) ?? raw;
    widget.urlController.text = clean;
    widget.urlController.selection = TextSelection.collapsed(
      offset: clean.length,
    );
    widget.onDismissClipboard();
  }

  Future<void> _analyze() async {
    FocusScope.of(context).unfocus();
    final raw = widget.urlController.text.trim();
    if (raw.isEmpty) {
      _showSnack('Tempelkan tautan atau username Pixiv terlebih dahulu.');
      return;
    }
    final clean = UrlParser.extractUrl(raw);
    if (clean != null && clean != raw && !raw.toLowerCase().startsWith('pixiv:')) {
      widget.urlController.text = clean;
    }
    await widget.manager.analyzeLink(raw);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manager = widget.manager;
    final preview = manager.currentPreview;
    final busy = manager.isAnalyzing;
    final hasText = widget.urlController.text.trim().isNotEmpty;
    final activeCount = manager.activeDownloads.length;
    final pausedCount = manager.pausedDownloads.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCenteredIdle = preview == null;
        final bottomInset =
            isCenteredIdle ? 0.0 : MediaQuery.viewInsetsOf(context).bottom;

        return SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(18, 12, 18, 24 + bottomInset),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - 36).clamp(0, double.infinity),
            ),
            child: Column(
              mainAxisAlignment: isCenteredIdle
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (manager.permissionChecked &&
                    !manager.permissionStatus.granted) ...[
                  _PermissionBanner(
                    permanentlyDenied:
                        manager.permissionStatus.permanentlyDenied,
                    onGrant: () async {
                      if (manager.permissionStatus.permanentlyDenied) {
                        await manager.openAppSettings();
                      } else {
                        final updated =
                            await manager.requestStoragePermissions();
                        if (!updated.granted && updated.permanentlyDenied) {
                          _showSnack(
                            'Buka Pengaturan HP untuk mengaktifkan izin media.',
                          );
                        }
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                ],

                if (widget.clipboardUrl != null && preview == null) ...[
                  ClipboardLinkBanner(
                    detectedUrl: widget.clipboardUrl!,
                    platform: UrlParser.detectPlatform(widget.clipboardUrl!),
                    onUse: widget.onUseClipboard,
                    onDismiss: widget.onDismissClipboard,
                  ),
                  const SizedBox(height: 12),
                ],

                // Centered Thumb-Friendly Link Input Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Live platform & link-type detection banner when link pasted!
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: _detection != null
                              ? Padding(
                                  key: ValueKey(_detection!.summaryLabel),
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: _DetectedPlatformStrip(
                                    detection: _detection!,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),

                        // Input with Paste button ONLY inside the field (and Clear when filled)
                        TextField(
                          controller: widget.urlController,
                          scrollPadding: EdgeInsets.zero,
                          minLines: 1,
                          maxLines: 3,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.go,
                          onSubmitted: (_) => _analyze(),
                          decoration: InputDecoration(
                            hintText: 'Paste link',
                            prefixIcon: Icon(
                              _detection?.platform.icon ?? Icons.link_rounded,
                              color: _detection?.platform.brandColor,
                            ),
                            suffixIcon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (hasText)
                                  IconButton(
                                    onPressed: () {
                                      widget.urlController.clear();
                                      manager.clearPreview();
                                      setState(() {});
                                    },
                                    icon: const Icon(Icons.close_rounded, size: 20),
                                    tooltip: 'Hapus',
                                  ),
                                IconButton(
                                  onPressed: busy ? null : _pasteFromClipboard,
                                  icon: const Icon(
                                    Icons.content_paste_rounded,
                                    size: 20,
                                  ),
                                  tooltip: 'Tempel',
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Single clean primary CTA (no Paste button below, no Quick Download)
                        SizedBox(
                          height: 48,
                          child: FilledButton.icon(
                            onPressed: busy ? null : _analyze,
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            icon: busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(
                                    _detection?.isBulk == true
                                        ? Icons.collections_rounded
                                        : Icons.download_rounded,
                                    size: 20,
                                  ),
                            label: Text(
                              busy
                                  ? 'Memeriksa tautan...'
                                  : (_detection?.isBulk == true
                                      ? 'Muat Media Profil (Massal)'
                                      : 'Proses Link'),
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Compact live download pill linking to Riwayat tab (keeps Unduh clean of history!)
                if (activeCount > 0 && preview == null) ...[
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: widget.onOpenHistoryTab,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: theme.colorScheme.primary.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Sedang mengunduh $activeCount media...',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            'Lihat Riwayat',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                if (activeCount == 0 && pausedCount > 0 && preview == null) ...[
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: widget.onOpenHistoryTab,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.pause_circle_filled_rounded,
                            size: 18,
                            color: Color(0xFFF59E0B),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '$pausedCount unduhan terjeda',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFFF59E0B),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: manager.resumeAllPaused,
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                            ),
                            icon: const Icon(Icons.play_arrow_rounded, size: 16),
                            label: const Text('Lanjut'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                if (manager.engineError != null) ...[
                  const SizedBox(height: 12),
                  _ErrorBanner(
                    title: 'Engine belum siap',
                    message: manager.engineError!,
                  ),
                ],

                if (manager.analyzeError != null) ...[
                  const SizedBox(height: 12),
                  _ErrorBanner(
                    title: 'Gagal Memproses Tautan',
                    message: manager.analyzeError!,
                    actionLabel: _loginActionLabel(_detection?.platform),
                    onAction: _canBrowserLogin(_detection?.platform)
                        ? () async {
                            final p = _detection!.platform.name;
                            final saved = await manager.openBrowserLogin(p);
                            if (saved && mounted) {
                              _showSnack('Sesi tersimpan! Mencoba ulang...');
                              await _analyze();
                            }
                          }
                        : null,
                  ),
                ],

                // Media Preview / Multi-Photo Picker / Profile Bulk Picker
                if (preview != null) ...[
                  const SizedBox(height: 14),
                  MediaPreviewCard(
                    info: preview,
                    initialOption: preview.options.isNotEmpty
                        ? manager.pickDefaultOption(preview)
                        : null,
                    isDownloaded: manager.isMarkedDownloaded,
                    onUnmarkKey: (key) async {
                      await manager.unmarkDownloaded(key);
                      _showSnack('Penandaan "Sudah diunduh" dihapus.');
                    },
                    onUnmarkKeys: (keys) async {
                      await manager.unmarkMany(keys);
                      _showSnack('Penandaan terpilih berhasil dihapus.');
                    },
                    onMarkKeys: (keys) async {
                      await manager.markManyDownloaded(keys);
                    },
                    onDismiss: manager.clearPreview,
                    onDownloadOption: (selected) async {
                      if (manager.isMarkedDownloaded(preview.markerKey)) {
                        _showSnack(
                          'Media ini sudah ditandai terunduh. Hapus tanda dulu untuk mengunduh ulang.',
                        );
                        return;
                      }
                      await manager.startDownload(preview, selected);
                      manager.clearPreview();
                      widget.urlController.clear();
                      _showSnack('Mulai mengunduh ${selected.label}...');
                    },
                    onDownloadSelectedPhotos: (selected) async {
                      final started =
                          await manager.downloadSelectedPhotos(preview, selected);
                      if (started == 0) {
                        _showSnack(
                          'Semua foto terpilih sudah ditandai terunduh. Hapus tanda dulu untuk mengunduh ulang.',
                        );
                        return;
                      }
                      manager.clearPreview();
                      widget.urlController.clear();
                      _showSnack(
                        'Mulai mengunduh $started foto terpilih...',
                      );
                    },
                    onDownloadBulkProfile: (selected, audioOnly) async {
                      final started = await manager.startBulkDownloads(
                        preview,
                        selected,
                        audioOnly: audioOnly,
                      );
                      if (started == 0) {
                        _showSnack(
                          'Semua karya terpilih sudah ditandai terunduh. Hapus tanda dulu untuk mengunduh ulang.',
                        );
                        return;
                      }
                      manager.clearPreview();
                      widget.urlController.clear();
                      _showSnack(
                        'Antrean unduh massal dimulai ($started media)...',
                      );
                    },
                  ),
                ],

                // Gentle lower thumb balance when centered idle
                if (isCenteredIdle) const SizedBox(height: 48),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _canBrowserLogin(MediaPlatform? platform) {
    return platform == MediaPlatform.instagram ||
        platform == MediaPlatform.tiktok ||
        platform == MediaPlatform.douyin ||
        platform == MediaPlatform.facebook ||
        platform == MediaPlatform.pixiv;
  }

  String? _loginActionLabel(MediaPlatform? platform) {
    switch (platform) {
      case MediaPlatform.instagram:
        return 'Login Browser Instagram';
      case MediaPlatform.tiktok:
        return 'Login Browser TikTok';
      case MediaPlatform.douyin:
        return 'Login Browser Douyin';
      case MediaPlatform.facebook:
        return 'Login Browser Facebook';
      case MediaPlatform.pixiv:
        return 'Login Browser Pixiv';
      default:
        return null;
    }
  }
}

class _DetectedPlatformStrip extends StatelessWidget {
  final LinkDetection detection;

  const _DetectedPlatformStrip({required this.detection});

  @override
  Widget build(BuildContext context) {
    final platform = detection.platform;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: platform.gradientColors
              .map((c) => c.withValues(alpha: 0.16))
              .toList(),
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: platform.brandColor.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: platform.gradientColors),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(platform.icon, size: 15, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Terdeteksi: ${platform.label}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: platform.brandColor,
                  ),
                ),
                Text(
                  detection.contentLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                      ),
                ),
              ],
            ),
          ),
          if (detection.isBulk)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: platform.brandColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'MASSAL',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: platform.brandColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  final bool permanentlyDenied;
  final VoidCallback onGrant;

  const _PermissionBanner({
    required this.permanentlyDenied,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const accent = Color(0xFFF59E0B);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_shared_outlined, color: accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              permanentlyDenied
                  ? 'Aktifkan izin media di Pengaturan HP.'
                  : 'Izinkan akses media agar unduhan tersimpan lancar.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: onGrant,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              backgroundColor: accent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: Text(permanentlyDenied ? 'Pengaturan' : 'Izinkan'),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _ErrorBanner({
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: theme.colorScheme.error,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    height: 1.35,
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: onAction,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.login_rounded, size: 17),
                    label: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
