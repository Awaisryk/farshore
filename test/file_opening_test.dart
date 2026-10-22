import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/file_preview.dart';
import 'package:farshore/main.dart';
import 'package:farshore/video_player.dart';

class OpeningBridge implements BridgeClient {
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add(method);
    if (method == 'prepare_preview') {
      return {
        'previewId': 'fixture-preview',
        'kind': 'text',
        'text': 'Read-only preview body.',
        'sourceBytes': 23,
        'mimeType': 'text/plain',
        'truncated': false,
      };
    }
    if (method == 'thumbnail') return {'status': 'unsupported'};
    if (method == 'release_preview') return {'released': true};
    return {};
  }

  @override
  void dispose() {}
}

RemoteEntry file(String name) => RemoteEntry(
  name: name,
  path: '/files/$name',
  isDirectory: false,
  size: 23,
  modified: '',
);

void main() {
  test(
    'common images, documents and source files have an internal opening intent',
    () {
      for (final name in [
        'photo.PNG',
        'scan.tiff',
        'portrait.heic',
        'drawing.svg',
        'image.avif',
        'report.pdf',
        'letter.docx',
        'table.xlsx',
        'deck.pptx',
        'notes.rtf',
        'README',
        '.env',
        'Dockerfile',
        'config.toml',
        'source.swift',
        'app.tsx',
        'page.html',
        'notebook.ipynb',
      ]) {
        expect(
          file(name).openIntent,
          EntryOpenIntent.previewInternally,
          reason: name,
        );
      }
      for (final name in [
        'track.mp3',
        'music.FLAC',
        'sound.ogg',
        'clip.mp4',
        'video.mkv',
      ]) {
        expect(
          file(name).openIntent,
          EntryOpenIntent.playInternally,
          reason: name,
        );
      }
      for (final name in [
        'archive.zip',
        'binary.exe',
        'disk.dmg',
        'file.unknown',
      ]) {
        expect(
          file(name).openIntent,
          EntryOpenIntent.openExternally,
          reason: name,
        );
      }
    },
  );

  for (final name in ['photo.png', 'notes.txt', 'report.pdf', 'letter.docx']) {
    testWidgets(
      'Return opens $name in Farshore and Escape preserves selection',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = OpeningBridge();
        final model = BrowserModel(bridge)..discovering = false;
        final entry = file(name);
        model.tab.host = const RemoteHost(
          'fixture',
          'fixture',
          'example.invalid',
          'reader',
          22,
        );
        model.tab.entries = [entry];
        model.resumeWorkspace();
        model.select(entry);
        await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(FilePreviewDialog), findsOneWidget);
        expect(find.text('Read-only preview body.'), findsOneWidget);
        expect(bridge.calls, contains('prepare_preview'));
        expect(bridge.calls, isNot(contains('open')));
        expect(bridge.calls, isNot(contains('applications')));
        if (name == 'notes.txt') {
          await tester.tap(find.text('Read-only preview body.'));
          await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(TextField, 'Remote folder path'),
            findsOneWidget,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(FilePreviewDialog), findsOneWidget);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(FilePreviewDialog), findsNothing);
        expect(model.tab.selection, {entry.path});
        expect(bridge.calls, contains('release_preview'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('unknown types retain external opening', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = OpeningBridge();
    final model = BrowserModel(bridge)..discovering = false;
    final entry = file('archive.zip');
    model.tab.host = const RemoteHost(
      'fixture',
      'fixture',
      'example.invalid',
      'reader',
      22,
    );
    model.tab.entries = [entry];
    model.resumeWorkspace();
    model.select(entry);
    await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(bridge.calls, contains('open'));
    expect(bridge.calls, isNot(contains('prepare_preview')));
    expect(find.byType(FilePreviewDialog), findsNothing);
    expect(find.byType(FarshoreVideoPlayer), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
