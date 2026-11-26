import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkdrop_downloader/screens/home_shell.dart';
import 'package:linkdrop_downloader/services/download_manager.dart';
import 'package:linkdrop_downloader/theme/app_theme.dart';

void main() {
  testWidgets('all_download simplified UI has 4 tabs and live link detection',
      (WidgetTester tester) async {
    final manager = DownloadManager();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: HomeShell(manager: manager),
      ),
    );
    await tester.pump();

    // Ultra-clean screen checks (title, icon, and removed clutter must stay gone)
    expect(find.text('all_download'), findsNothing);
    expect(find.text('Engine Siap'), findsNothing);
    expect(find.text('Unduh Cepat (Kualitas Default)'), findsNothing);
    expect(find.text('Cara Tercepat Mengunduh'), findsNothing);
    expect(find.text('Proses Link'), findsOneWidget);

    // 4 NavigationBar destinations: Unduh, File, Riwayat, Pengaturan
    expect(find.text('Unduh'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Riwayat'), findsOneWidget);
    expect(find.text('Pengaturan'), findsOneWidget);

    // Pasting/typing a link shows live platform detection
    await tester.enterText(
      find.byType(TextField).first,
      'https://www.instagram.com/reel/C9xYz123AbC/',
    );
    await tester.pump();
    expect(find.text('Terdeteksi: Instagram'), findsOneWidget);
    expect(find.text('Reel (Video)'), findsOneWidget);

    // Entering a Pixiv profile switches CTA to bulk mode
    await tester.enterText(
      find.byType(TextField).first,
      'https://www.pixiv.net/users/11',
    );
    await tester.pump();
    expect(find.text('Terdeteksi: Pixiv'), findsOneWidget);
    expect(find.text('Muat Media Profil (Massal)'), findsOneWidget);

    // Switching to File tab renders cleanly
    await tester.tap(find.text('File'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('File Unduhan'), findsOneWidget);

    manager.dispose();
  });
}
