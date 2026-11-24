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
    return ListenableBuilder(
      listenable: _manager,
      builder: (context, _) {
        return MaterialApp(
          title: 'all_download',
          debugShowCheckedModeBanner: false,
          themeMode: _manager.settings.themeMode,
          theme: AppTheme.lightTheme(),
          darkTheme: AppTheme.darkTheme(),
          home: HomeShell(manager: _manager),
        );
      },
    );
  }
}
