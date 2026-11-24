import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkdrop_downloader/screens/home_shell.dart';
import 'package:linkdrop_downloader/services/download_manager.dart';
import 'package:linkdrop_downloader/theme/app_theme.dart';

void main() {
  testWidgets('LinkDrop home renders all 5 supported platforms and controls',
      (WidgetTester tester) async {
    final manager = DownloadManager();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: HomeShell(manager: manager),
      ),
    );
    await tester.pump();

    expect(find.text('LinkDrop'), findsOneWidget);
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('TikTok'), findsOneWidget);
    expect(find.text('Douyin'), findsOneWidget);
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    expect(find.text('Cek Kualitas'), findsOneWidget);
    expect(find.text('Unduh Cepat (Kualitas Default)'), findsOneWidget);

    manager.dispose();
  });
}
