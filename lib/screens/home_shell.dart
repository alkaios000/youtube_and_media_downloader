import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_platform.dart';
import '../services/download_manager.dart';
import '../widgets/app_feedback.dart';
import '../widgets/security_lock_screen.dart';
import 'downloader_screen.dart';
import 'downloads_screen.dart';
import 'files_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  final DownloadManager manager;

  const HomeShell({super.key, required this.manager});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final TextEditingController _urlController = TextEditingController();
  final ValueNotifier<int> _historySectionNotifier = ValueNotifier<int>(0);
  int _tabIndex = 0;
  String? _detectedClipboardUrl;
  String? _lastDismissedClipboardUrl;
  bool _didAutoRequestPermission = false;
  bool _appLocked = false;
  bool _vaultUnlockedThisSession = false;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.manager.onIncomingSharedLink = _handleSharedLink;
    final s = widget.manager.settings;
    if (s.isSecurityLockActive && s.appLockScope == 'app') {
      _appLocked = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkClipboard();
      _promptPermissionIfNeeded();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _urlController.dispose();
    _historySectionNotifier.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      _checkClipboard();
      widget.manager.refreshPermissions();
      final s = widget.manager.settings;
      final away = _pausedAt != null
          ? DateTime.now().difference(_pausedAt!)
          : Duration.zero;
      _pausedAt = null;
      // 4-second grace period avoids annoying re-locks after system share/permission dialogs
      if (s.isSecurityLockActive && away.inSeconds >= 4) {
        if (s.appLockScope == 'app' && !_appLocked) {
          setState(() => _appLocked = true);
        } else if (s.appLockScope == 'vault') {
          _vaultUnlockedThisSession = false;
          if (_tabIndex == 1) {
            setState(() => _tabIndex = 0);
          }
        }
      }
    }
  }

  Future<void> _activateQuickStealth() async {
    final s = widget.manager.settings;
    if (!s.showEcchiContent && !s.showNsfwContent) return;
    HapticFeedback.heavyImpact();
    await widget.manager.updateSettings(
      s.copyWith(showEcchiContent: false, showNsfwContent: false),
    );
    if (mounted) {
      showTopToast(
        context,
        'Mode aman aktif — konten Ecchi & NSFW disembunyikan.',
        icon: Icons.visibility_off_rounded,
      );
    }
  }

  Future<void> _promptPermissionIfNeeded() async {
    if (_didAutoRequestPermission) return;
    _didAutoRequestPermission = true;
    final status = await widget.manager.refreshPermissions();
    if (!status.granted && mounted) {
      await widget.manager.requestStoragePermissions();
    }
  }

  void _handleSharedLink(String rawText) {
    final clean = UrlParser.extractUrl(rawText);
    if (clean == null) return;
    _openProfileAndAnalyze(clean);
  }

  void _openProfileAndAnalyze(String profileUrl) {
    final clean = UrlParser.extractUrl(profileUrl) ?? profileUrl.trim();
    if (clean.isEmpty) return;
    _urlController.value = TextEditingValue(
      text: clean,
      selection: TextSelection.collapsed(offset: clean.length),
    );
    if (mounted) {
      setState(() {
        _tabIndex = 0;
        _detectedClipboardUrl = null;
      });
    }
    Future<void>.microtask(() => widget.manager.analyzeLink(clean));
  }

  Future<void> _checkClipboard() async {
    if (!widget.manager.settings.clipboardAutoDetect) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final raw = data?.text?.trim() ?? '';
      if (raw.isEmpty) return;
      final clean = UrlParser.extractUrl(raw);
      if (clean == null) return;
      if (!UrlParser.isCorePlatformUrl(clean)) return;
      if (clean == _lastDismissedClipboardUrl ||
          clean == _urlController.text.trim()) {
        return;
      }
      if (mounted) {
        setState(() => _detectedClipboardUrl = clean);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_appLocked && widget.manager.settings.isSecurityLockActive) {
      return SecurityLockScreen(
        manager: widget.manager,
        onUnlocked: () {
          if (mounted) {
            setState(() {
              _appLocked = false;
              _vaultUnlockedThisSession = true;
            });
          }
        },
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: IndexedStack(
          index: _tabIndex,
          children: [
            _ActiveTabListener(
              active: _tabIndex == 0,
              listenable: widget.manager,
              builder: (_) => DownloaderScreen(
                manager: widget.manager,
                urlController: _urlController,
                clipboardUrl: _detectedClipboardUrl,
                onUseClipboard: () {
                  final url = _detectedClipboardUrl;
                  if (url == null) return;
                  setState(() {
                    _urlController.text = url;
                    _detectedClipboardUrl = null;
                  });
                  widget.manager.analyzeLink(url);
                },
                onDismissClipboard: () {
                  setState(() {
                    _lastDismissedClipboardUrl = _detectedClipboardUrl;
                    _detectedClipboardUrl = null;
                  });
                },
                onOpenHistoryTab: () {
                  _historySectionNotifier.value = 0;
                  setState(() => _tabIndex = 2);
                },
              ),
            ),
            _ActiveTabListener(
              active: _tabIndex == 1,
              listenable: widget.manager,
              builder: (_) => FilesScreen(
                manager: widget.manager,
                onOpenProfileUrl: _openProfileAndAnalyze,
              ),
            ),
            _ActiveTabListener(
              active: _tabIndex == 2,
              listenable: widget.manager,
              builder: (_) => DownloadsScreen(
                manager: widget.manager,
                sectionNotifier: _historySectionNotifier,
              ),
            ),
            _ActiveTabListener(
              active: _tabIndex == 3,
              listenable: widget.manager,
              builder: (_) => SettingsScreen(manager: widget.manager),
            ),
          ],
        ),
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: widget.manager,
        builder: (context, _) {
          final activeCount = widget.manager.activeDownloadCount;
          final pausedCount = widget.manager.pausedDownloadCount;
          final badgeCount = activeCount > 0 ? activeCount : pausedCount;
          final badgeBg = activeCount > 0 ? null : const Color(0xFFF59E0B);
          return NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (index) async {
              FocusManager.instance.primaryFocus?.unfocus();
              if (index == 1 &&
                  _tabIndex != 1 &&
                  widget.manager.settings.isSecurityLockActive &&
                  widget.manager.settings.appLockScope == 'vault' &&
                  !_vaultUnlockedThisSession) {
                final ok = await verifySecurityGate(
                  context,
                  widget.manager,
                  title: 'Buka Brankas File',
                  subtitle: 'Verifikasi PIN atau sidik jari untuk membuka koleksi',
                );
                if (!ok || !mounted) return;
                _vaultUnlockedThisSession = true;
              }
              if (index == 2 && _tabIndex != 2) {
                final hasLoading = widget.manager.activeDownloadCount > 0 ||
                    widget.manager.pausedDownloadCount > 0;
                _historySectionNotifier.value = hasLoading ? 0 : 1;
              }
              setState(() => _tabIndex = index);
              if (index == 1) {
                widget.manager.refreshManagedFiles();
                unawaited(widget.manager.refreshTrashItems());
              } else if (index == 3) {
                widget.manager.refreshStorageInfo();
              }
            },
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.download_outlined),
                selectedIcon: Icon(Icons.download_rounded),
                label: 'Unduh',
              ),
              NavigationDestination(
                icon: GestureDetector(
                  onLongPress: _activateQuickStealth,
                  child: const Icon(Icons.folder_outlined),
                ),
                selectedIcon: GestureDetector(
                  onLongPress: _activateQuickStealth,
                  child: const Icon(Icons.folder_rounded),
                ),
                label: 'File',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: badgeCount > 0,
                  backgroundColor: badgeBg,
                  label: Text('$badgeCount'),
                  child: const Icon(Icons.history_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: badgeCount > 0,
                  backgroundColor: badgeBg,
                  label: Text('$badgeCount'),
                  child: const Icon(Icons.history_rounded),
                ),
                label: 'Riwayat',
              ),
              const NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune_rounded),
                label: 'Pengaturan',
              ),
            ],
          );
        },
      ),
      ),
    );
  }
}

/// Only rebuilds the currently visible tab when [listenable] notifies,
/// keeping background tabs completely idle (0% CPU) during heavy bulk downloads
/// while preserving each tab's full scroll & navigation State.
class _ActiveTabListener extends StatefulWidget {
  final bool active;
  final Listenable listenable;
  final WidgetBuilder builder;

  const _ActiveTabListener({
    required this.active,
    required this.listenable,
    required this.builder,
  });

  @override
  State<_ActiveTabListener> createState() => _ActiveTabListenerState();
}

class _ActiveTabListenerState extends State<_ActiveTabListener> {
  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant _ActiveTabListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_onChanged);
      widget.listenable.addListener(_onChanged);
    }
  }

  void _onChanged() {
    if (widget.active && mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
