import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/download_item.dart';
import '../models/media_platform.dart';
import '../services/download_manager.dart';
import '../widgets/clipboard_banner.dart';
import '../widgets/download_tile.dart';
import '../widgets/media_preview_card.dart';
import '../widgets/platform_badge.dart';

class DownloaderScreen extends StatefulWidget {
  final DownloadManager manager;
  final TextEditingController urlController;
  final String? clipboardUrl;
  final VoidCallback onUseClipboard;
  final VoidCallback onDismissClipboard;
  final VoidCallback onOpenDownloadsTab;

  const DownloaderScreen({
    super.key,
    required this.manager,
    required this.urlController,
    required this.clipboardUrl,
    required this.onUseClipboard,
    required this.onDismissClipboard,
    required this.onOpenDownloadsTab,
  });

  @override
  State<DownloaderScreen> createState() => _DownloaderScreenState();
}

class _DownloaderScreenState extends State<DownloaderScreen> {
  MediaPlatform? _detectedPlatform;
  bool _quickDownloading = false;

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
    final clean = UrlParser.extractUrl(text);
    final nextPlatform = clean != null ? UrlParser.detectPlatform(clean) : null;
    if (nextPlatform != _detectedPlatform) {
      setState(() => _detectedPlatform = nextPlatform);
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
      _showSnack('Tempelkan link media terlebih dahulu.');
      return;
    }
    final clean = UrlParser.extractUrl(raw);
    if (clean != null && clean != raw) {
      widget.urlController.text = clean;
    }
    await widget.manager.analyzeLink(raw);
  }

  Future<void> _quickDownload() async {
    FocusScope.of(context).unfocus();
    final raw = widget.urlController.text.trim();
    if (raw.isEmpty) {
      _showSnack('Tempelkan link media terlebih dahulu.');
      return;
    }
    setState(() => _quickDownloading = true);
    try {
      final info = await widget.manager.analyzeLink(raw);
      if (info == null) return;
      final option = widget.manager.pickDefaultOption(info);
      await widget.manager.startDownload(info, option);
      widget.manager.clearPreview();
      widget.urlController.clear();
      _showSnack('Mulai mengunduh (${option.label})...');
    } finally {
      if (mounted) {
        setState(() => _quickDownloading = false);
      }
    }
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
    final activeDownloads = manager.activeDownloads;
    final preview = manager.currentPreview;
    final busy = manager.isAnalyzing || _quickDownloading;

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          title: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF38BDF8), Color(0xFF6366F1)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.download_for_offline_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Text('LinkDrop'),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: _EnginePill(manager: manager),
            ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Text(
                'Unduh video, audio, & foto hanya dari tautan.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              SupportedPlatformsStrip(activePlatform: _detectedPlatform),
              const SizedBox(height: 16),

              if (widget.clipboardUrl != null) ...[
                ClipboardLinkBanner(
                  detectedUrl: widget.clipboardUrl!,
                  platform: UrlParser.detectPlatform(widget.clipboardUrl!),
                  onUse: widget.onUseClipboard,
                  onDismiss: widget.onDismissClipboard,
                ),
                const SizedBox(height: 14),
              ],

              // Main Link Input Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Tempel Link Media',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          if (_detectedPlatform != null)
                            PlatformBadge(
                              platform: _detectedPlatform!,
                              compact: true,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: widget.urlController,
                        minLines: 1,
                        maxLines: 3,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        onSubmitted: (_) => _analyze(),
                        decoration: InputDecoration(
                          hintText:
                              'https://youtube.com / tiktok / douyin / ig / x.com...',
                          prefixIcon: const Icon(Icons.link_rounded),
                          suffixIcon: widget.urlController.text.isNotEmpty
                              ? IconButton(
                                  onPressed: () {
                                    widget.urlController.clear();
                                    manager.clearPreview();
                                    setState(() {});
                                  },
                                  icon: const Icon(Icons.clear_rounded),
                                  tooltip: 'Bersihkan',
                                )
                              : IconButton(
                                  onPressed: _pasteFromClipboard,
                                  icon: const Icon(Icons.content_paste_rounded),
                                  tooltip: 'Tempel dari clipboard',
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: busy ? null : _pasteFromClipboard,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 13,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(13),
                              ),
                            ),
                            icon: const Icon(Icons.content_paste_rounded, size: 18),
                            label: const Text('Tempel'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: busy ? null : _analyze,
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(13),
                                ),
                              ),
                              icon: busy
                                  ? const SizedBox(
                                      width: 17,
                                      height: 17,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.search_rounded, size: 19),
                              label: Text(
                                busy ? 'Menganalisis...' : 'Cek Kualitas',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: busy ? null : _quickDownload,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                          ),
                        ),
                        icon: const Icon(Icons.bolt_rounded, size: 19),
                        label: const Text(
                          'Unduh Cepat (Kualitas Default)',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Engine Init Error if any
              if (manager.engineError != null) ...[
                const SizedBox(height: 12),
                _ErrorBanner(
                  title: 'Engine yt-dlp belum siap',
                  message: manager.engineError!,
                ),
              ],

              // Link Analysis Error
              if (manager.analyzeError != null) ...[
                const SizedBox(height: 14),
                _ErrorBanner(
                  title: 'Gagal Memproses Tautan',
                  message: manager.analyzeError!,
                ),
              ],

              // Rich Media Preview & Quality Picker
              if (preview != null) ...[
                const SizedBox(height: 16),
                MediaPreviewCard(
                  info: preview,
                  initialOption: manager.pickDefaultOption(preview),
                  onDismiss: manager.clearPreview,
                  onDownload: (selected) async {
                    await manager.startDownload(preview, selected);
                    manager.clearPreview();
                    widget.urlController.clear();
                    _showSnack('Mengunduh ${selected.label}...');
                  },
                ),
              ],

              // Active Downloads live feed
              if (activeDownloads.isNotEmpty) ...[
                const SizedBox(height: 22),
                Row(
                  children: [
                    Text(
                      'Sedang Mengunduh (${activeDownloads.length})',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: widget.onOpenDownloadsTab,
                      child: const Text('Lihat Semua'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...activeDownloads.map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: DownloadTile(
                      item: item,
                      onCancel: () => manager.cancelDownload(item.id),
                    ),
                  ),
                ),
              ],

              // Recent 2 Completed items shortcut or Quick Tips when idle
              if (preview == null && activeDownloads.isEmpty) ...[
                const SizedBox(height: 20),
                if (manager.historyItems.isNotEmpty) ...[
                  Row(
                    children: [
                      Text(
                        'Unduhan Terakhir',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: widget.onOpenDownloadsTab,
                        child: const Text('Riwayat Lengkap'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ...manager.historyItems.take(2).map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: DownloadTile(
                            item: item,
                            onOpen: () => _openFile(item),
                            onShare: () => manager.shareDownloadedItem(item),
                            onDelete: () => manager.removeHistoryItem(item),
                          ),
                        ),
                      ),
                ] else ...[
                  const _TipsCard(),
                ],
              ],
            ]),
          ),
        ),
      ],
    );
  }

  Future<void> _openFile(DownloadItem item) async {
    final ok = await widget.manager.openDownloadedItem(item);
    if (!ok) {
      _showSnack('File tidak dapat dibuka atau sudah dipindahkan.');
    }
  }
}

class _EnginePill extends StatelessWidget {
  final DownloadManager manager;

  const _EnginePill({required this.manager});

  @override
  Widget build(BuildContext context) {
    final ready = manager.engineStatus.initialized;
    final loading = manager.isInitializing;
    final color = loading
        ? const Color(0xFFF59E0B)
        : (ready ? const Color(0xFF22C55E) : const Color(0xFFEF4444));
    final label = loading
        ? 'Menyiapkan...'
        : (ready ? 'Engine Siap' : 'Offline');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String title;
  final String message;

  const _ErrorBanner({required this.title, required this.message});

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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TipsCard extends StatelessWidget {
  const _TipsCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 19,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Cara Tercepat Mengunduh',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const _TipRow(
              number: '1',
              text:
                  'Salin tautan dari YouTube, TikTok, Douyin (teks share bahasa Mandarin otomatis dibersihkan), Instagram, atau X.',
            ),
            const SizedBox(height: 8),
            const _TipRow(
              number: '2',
              text:
                  'Atau langsung tekan "Bagikan / Share" di aplikasi media sosial lalu pilih LinkDrop.',
            ),
            const SizedBox(height: 8),
            const _TipRow(
              number: '3',
              text:
                  'Semua file otomatis tersimpan ke folder Download/LinkDrop dan siap diputar di Galeri.',
            ),
          ],
        ),
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  final String number;
  final String text;

  const _TipRow({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            number,
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
