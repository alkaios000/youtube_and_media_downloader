import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';
import '../services/download_manager.dart';

/// Prompts the user to pass security verification (Biometric / Device Lock or
/// custom 4–6 digit PIN) before accessing protected content.
/// Returns `true` immediately when lock is disabled or upon successful unlock.
Future<bool> verifySecurityGate(
  BuildContext context,
  DownloadManager manager, {
  String title = 'Verifikasi Keamanan',
  String subtitle = 'Masukkan PIN atau sidik jari untuk melanjutkan',
}) async {
  final settings = manager.settings;
  if (!settings.isSecurityLockActive) return true;

  if (settings.appLockUseBiometric) {
    final canBio = await manager.canAuthenticateBiometric();
    if (canBio) {
      final ok = await manager.authenticateBiometric(
        title: title,
        subtitle: subtitle,
      );
      if (ok) return true;
      if (!settings.hasPinConfigured) return false;
    }
  }

  if (!context.mounted) return false;
  if (!settings.hasPinConfigured) return true;

  final ok = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => SecurityLockScreen(
        manager: manager,
        title: title,
        subtitle: subtitle,
        allowCancel: true,
        autoTriggerBiometric: false,
      ),
    ),
  );
  return ok == true;
}

/// Full-screen security lock gate (used both on app launch/resume when
/// `appLockScope == 'app'` and on-demand for protected actions).
class SecurityLockScreen extends StatefulWidget {
  final DownloadManager manager;
  final String title;
  final String subtitle;
  final bool allowCancel;
  final bool autoTriggerBiometric;
  final VoidCallback? onUnlocked;

  const SecurityLockScreen({
    super.key,
    required this.manager,
    this.title = 'all_download Terkunci',
    this.subtitle = 'Masukkan PIN atau gunakan sidik jari',
    this.allowCancel = false,
    this.autoTriggerBiometric = true,
    this.onUnlocked,
  });

  @override
  State<SecurityLockScreen> createState() => _SecurityLockScreenState();
}

class _SecurityLockScreenState extends State<SecurityLockScreen> {
  String _entered = '';
  String? _errorText;
  bool _biometricAvailable = false;
  bool _authenticatingBio = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkAndPromptBiometric());
  }

  Future<void> _checkAndPromptBiometric() async {
    final settings = widget.manager.settings;
    if (!settings.appLockUseBiometric) return;
    final canBio = await widget.manager.canAuthenticateBiometric();
    if (!mounted) return;
    setState(() => _biometricAvailable = canBio);
    if (canBio && widget.autoTriggerBiometric) {
      await _triggerBiometric();
    }
  }

  Future<void> _triggerBiometric() async {
    if (_authenticatingBio) return;
    setState(() {
      _authenticatingBio = true;
      _errorText = null;
    });
    final ok = await widget.manager.authenticateBiometric(
      title: widget.title,
      subtitle: widget.subtitle,
    );
    if (!mounted) return;
    setState(() => _authenticatingBio = false);
    if (ok) {
      _completeUnlock();
    }
  }

  void _completeUnlock() {
    HapticFeedback.mediumImpact();
    if (widget.onUnlocked != null) {
      widget.onUnlocked!();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  void _appendDigit(String digit) {
    if (_entered.length >= 6) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered += digit;
      _errorText = null;
    });
    if (widget.manager.settings.verifyPin(_entered)) {
      _completeUnlock();
    } else if (_entered.length == 6) {
      HapticFeedback.heavyImpact();
      setState(() {
        _errorText = 'PIN salah. Coba lagi.';
        _entered = '';
      });
    }
  }

  void _submitManual() {
    if (_entered.length < 4) {
      setState(() => _errorText = 'Masukkan minimal 4 digit PIN.');
      return;
    }
    if (widget.manager.settings.verifyPin(_entered)) {
      _completeUnlock();
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _errorText = 'PIN salah. Coba lagi.';
        _entered = '';
      });
    }
  }

  void _backspace() {
    if (_entered.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _errorText = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPin = widget.manager.settings.hasPinConfigured;

    return PopScope(
      canPop: widget.allowCancel,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.allowCancel)
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          onPressed: () => Navigator.pop(context, false),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.primary.withValues(alpha: 0.4),
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        Icons.lock_rounded,
                        size: 32,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.subtitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 22),

                    if (hasPin) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(6, (i) {
                          final filled = i < _entered.length;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            width: filled ? 15 : 12,
                            height: filled ? 15 : 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: filled
                                  ? theme.colorScheme.primary
                                  : Colors.transparent,
                              border: Border.all(
                                color: filled
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outlineVariant,
                                width: 1.6,
                              ),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 20,
                        child: _errorText != null
                            ? Text(
                                _errorText!,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(height: 12),
                      _PinKeypad(
                        onDigit: _appendDigit,
                        onBackspace: _backspace,
                        leftAction: _biometricAvailable
                            ? _KeypadIconBtn(
                                icon: Icons.fingerprint_rounded,
                                tooltip: 'Sidik Jari / Kunci HP',
                                onTap: _triggerBiometric,
                              )
                            : (_entered.length >= 4
                                ? _KeypadIconBtn(
                                    icon: Icons.check_rounded,
                                    tooltip: 'Konfirmasi PIN',
                                    onTap: _submitManual,
                                  )
                                : const SizedBox.shrink()),
                      ),
                    ] else ...[
                      FilledButton.icon(
                        onPressed: _triggerBiometric,
                        icon: const Icon(Icons.fingerprint_rounded),
                        label: const Text('Buka dengan Sidik Jari / Kunci HP'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Interactive 2-step bottom sheet for creating or changing a 4–6 digit PIN.
/// Returns the computed salted PIN hash, or `null` if cancelled.
Future<String?> showPinSetupSheet(
  BuildContext context, {
  bool isChange = false,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => _PinSetupSheetBody(isChange: isChange),
  );
}

class _PinSetupSheetBody extends StatefulWidget {
  final bool isChange;
  const _PinSetupSheetBody({required this.isChange});

  @override
  State<_PinSetupSheetBody> createState() => _PinSetupSheetBodyState();
}

class _PinSetupSheetBodyState extends State<_PinSetupSheetBody> {
  String _firstPin = '';
  String _current = '';
  bool _confirmStep = false;
  String? _error;

  void _onDigit(String d) {
    if (_current.length >= 6) return;
    HapticFeedback.selectionClick();
    setState(() {
      _current += d;
      _error = null;
    });
  }

  void _onBackspace() {
    if (_current.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _current = _current.substring(0, _current.length - 1);
      _error = null;
    });
  }

  void _onNext() {
    if (_current.length < 4) {
      setState(() => _error = 'PIN minimal 4 digit (maksimal 6 digit).');
      return;
    }
    if (!_confirmStep) {
      setState(() {
        _firstPin = _current;
        _current = '';
        _confirmStep = true;
        _error = null;
      });
      return;
    }
    if (_current != _firstPin) {
      HapticFeedback.heavyImpact();
      setState(() {
        _error = 'PIN tidak cocok. Ulangi konfirmasi.';
        _current = '';
      });
      return;
    }
    Navigator.pop(context, AppSettings.hashPin(_firstPin));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _confirmStep
                  ? 'Konfirmasi PIN Baru'
                  : (widget.isChange ? 'Buat PIN Baru' : 'Atur PIN Keamanan'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _confirmStep
                  ? 'Masukkan ulang PIN yang sama lalu ketuk Simpan'
                  : 'Pilih 4 hingga 6 angka lalu ketuk Lanjut',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(6, (i) {
                final filled = i < _current.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: filled ? 14 : 11,
                  height: filled ? 14 : 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    border: Border.all(
                      color: filled
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                      width: 1.5,
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 18,
              child: _error != null
                  ? Text(
                      _error!,
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: _PinKeypad(
                onDigit: _onDigit,
                onBackspace: _onBackspace,
                leftAction: const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Batal'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _current.length >= 4 ? _onNext : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(_confirmStep ? 'Simpan PIN' : 'Lanjut'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PinKeypad extends StatelessWidget {
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final Widget leftAction;

  const _PinKeypad({
    required this.onDigit,
    required this.onBackspace,
    required this.leftAction,
  });

  @override
  Widget build(BuildContext context) {
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final digit in row)
                _KeypadDigitBtn(digit: digit, onTap: () => onDigit(digit)),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            SizedBox(width: 68, height: 58, child: Center(child: leftAction)),
            _KeypadDigitBtn(digit: '0', onTap: () => onDigit('0')),
            SizedBox(
              width: 68,
              height: 58,
              child: Center(
                child: _KeypadIconBtn(
                  icon: Icons.backspace_outlined,
                  tooltip: 'Hapus',
                  onTap: onBackspace,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _KeypadDigitBtn extends StatelessWidget {
  final String digit;
  final VoidCallback onTap;

  const _KeypadDigitBtn({required this.digit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 68,
          height: 58,
          child: Center(
            child: Text(
              digit,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeypadIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _KeypadIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 24),
    );
  }
}
