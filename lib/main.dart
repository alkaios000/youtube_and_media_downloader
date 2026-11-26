import 'dart:ui';

import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'services/download_manager.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled error: $error');
    return true;
  };
  runApp(const LinkDropApp());
}

class LinkDropApp extends StatefulWidget {
  const LinkDropApp({super.key});

  @override
  State<LinkDropApp> createState() => _LinkDropAppState();
}

class _LinkDropAppState extends State<LinkDropApp> {
  late final DownloadManager _manager;

  @override
  void initState() {
    super.initState();
    _manager = DownloadManager();
    _manager.bootstrap();
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Only listen to themeNotifier so MaterialApp NEVER rebuilds during downloads!
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _manager.themeNotifier,
      builder: (context, themeMode, child) {
        return MaterialApp(
          title: 'all_download',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: AppTheme.lightTheme(),
          darkTheme: AppTheme.darkTheme(),
          builder: (context, appChild) => GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: appChild ?? const SizedBox.shrink(),
          ),
          home: child,
        );
      },
      child: HomeShell(manager: _manager),
    );
  }
}
