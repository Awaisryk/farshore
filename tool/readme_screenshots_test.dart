// Artifact generator, intentionally outside test/ and the regression suite.
// Run scripts/capture-readme.sh. Only this in-memory bridge is used; no SSH,
// subprocess bridge, user state, native viewer, or remote file is accessed.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:farshore/app_theme.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _hosts = [
  RemoteHost('studio', 'studio', 'studio.example.invalid', 'artist', 22),
  RemoteHost('render', 'render', 'render.example.invalid', 'worker', 22),
  RemoteHost('archive', 'archive', 'archive.example.invalid', 'reader', 22),
];
const _recents = [
  {'hostId': 'studio', 'path': '/studio/shoreline'},
  {'hostId': 'render', 'path': '/renders/dailies'},
  {'hostId': 'archive', 'path': '/collections/2026'},
  {'hostId': 'studio', 'path': '/studio/references'},
  {'hostId': 'render', 'path': '/renders/experiments'},
];
const _capture = ValueKey('readme-capture');
const _names = [
  '01 — Tidal geometry.png',
  '02 — Blue hour.png',
  '03 — Golden silence.png',
  '04 — Moonrise.png',
  '05 — Coastal lines.png',
  '06 — Orchid horizon.png',
  '07 — Northern light.png',
  '08 — Open water.png',
  '09 — Evening loop.mp4',
  '10 — Shoreline study.mov',
];

class _DemoBridge implements BridgeClient {
  _DemoBridge(this.artwork);
  final Map<String, String> artwork;
  String themeId = 'midnight';

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    switch (method) {
      case 'hosts':
        return {
          'hosts': [
            for (final host in _hosts)
              {
                'id': host.id,
                'alias': host.alias,
                'hostname': host.hostname,
                'user': host.user,
                'port': host.port,
              },
          ],
          'favoriteHostIds': ['studio', 'render'],
          'recentPaths': _recents,
          'themeId': themeId,
          'favoritePaths': [_recents[0], _recents[2]],
          'cacheSettings': {'thumbnailBudgetBytes': 512 * 1024 * 1024},
          'workspace': {
            'version': 1,
            'tabs': _recents.take(3).toList(),
            'activeTab': 0,
            'isHome': true,
          },
          'browserSettings': {
            'view': 'grid',
            'tileSize': 178,
            'sort': 'name',
            'showHidden': false,
            'inspector': true,
            'restoreWorkspace': true,
          },
        };
      case 'thumbnail':
        final path = artwork[params['path']];
        if (path == null) throw StateError('No demo artwork for this sample.');
        return {'status': 'ready', 'path': path, 'cached': true};
      case 'set_theme':
        themeId = params['themeId'] as String;
        return {'themeId': themeId};
      case 'save_workspace':
        return params;
      default:
        throw StateError(
          'Screenshot generation forbids bridge method $method.',
        );
    }
  }

  @override
  void dispose() {}
}

// Original procedural landscape studies. They are local sample thumbnails,
// generated here rather than copied from a user's files or a stock library.
Future<void> _artwork(File file, int index) async {
  const palettes = [
    [0xffefc8a1, 0xffcd8071, 0xff264e56, 0xff407a7c],
    [0xff99c9da, 0xff2c547c, 0xff172e50, 0xff456a8b],
    [0xfff4deba, 0xffd6a377, 0xffa76344, 0xffd4a078],
    [0xff2e3563, 0xffb78dbe, 0xff25294b, 0xff4a4c79],
    [0xff8fcfc4, 0xff406c79, 0xff183e4b, 0xff42878a],
    [0xffc1abe4, 0xff796baf, 0xff3d416a, 0xff7c629e],
    [0xffc5dbca, 0xff538c86, 0xff244d57, 0xff5d8f8d],
    [0xffaacddd, 0xff6999b9, 0xff254a74, 0xff42759c],
  ];
  final colors = palettes[index % palettes.length].map(Color.new).toList();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const width = 960.0, height = 640.0;
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(width * .65, height),
        [colors[0], colors[1]],
      ),
  );
  canvas.drawCircle(
    Offset(index.isEven ? 690 : 280, 205),
    index % 3 == 0 ? 104 : 78,
    Paint()..color = const Color(0xffffeccd).withValues(alpha: .88),
  );
  for (var layer = 0; layer < 4; layer++) {
    final y = 315.0 + layer * 72;
    final path = Path()..moveTo(0, y + 50);
    path.cubicTo(230, y - 120 + (index % 3) * 35, 430, y + 120, 670, y - 35);
    path.cubicTo(820, y - 105, 905, y + 35, width, y - 5);
    path.lineTo(width, height);
    path.lineTo(0, height);
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = Color.lerp(colors[3], colors[2], layer / 3)!,
    );
  }
  // Quiet contour lines give each study detail at full inspector size.
  for (var line = 0; line < 18; line++) {
    final y = 410.0 + line * 14;
    final path = Path()..moveTo(0, y);
    path.cubicTo(230, y - 30, 540, y + 55, width, y - 20);
    canvas.drawPath(
      path,
      Paint()
        ..color = colors[0].withValues(alpha: .13)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }
  // A few deterministic glints, never external/generated image assets.
  final random = math.Random(120 + index);
  for (var point = 0; point < 70; point++) {
    canvas.drawCircle(
      Offset(random.nextDouble() * width, random.nextDouble() * height),
      .5 + random.nextDouble(),
      Paint()..color = Colors.white.withValues(alpha: .12),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width.toInt(), height.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
}

Future<void> _captureImage(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('docs/images/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, path) in [
      ('.AppleSystemUIFont', '/System/Library/Fonts/SFNS.ttf'),
      // ThemeData's nested Material text styles retain the Roboto family;
      // the real macOS app falls back to its system face. Test engines use
      // Ahem instead, so supply the actual platform face for that alias too.
      ('Roboto', '/System/Library/Fonts/SFNS.ttf'),
      (
        'MaterialIcons',
        '.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    ]) {
      final font = File(path);
      if (!font.existsSync()) {
        throw StateError('Required screenshot font missing.');
      }
      await (FontLoader(
        family,
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  testWidgets(
    'render public README screenshots using only synthetic sample data',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final artwork = <String, String>{};
      await tester.runAsync(() async {
        for (var index = 0; index < _names.length; index++) {
          final file = File('.build/readme-artwork/study-$index.png');
          await _artwork(file, index);
          artwork['/studio/shoreline/${_names[index]}'] = file.absolute.path;
        }
      });
      final model = BrowserModel(_DemoBridge(artwork));
      await model.discover();
      for (final tab in model.tabs) {
        tab.needsLoad = false;
        tab.fresh = true;
      }
      model.tab.entries = [
        const RemoteEntry(
          name: 'References',
          path: '/studio/shoreline/References',
          isDirectory: true,
          size: 0,
          modified: '2026-10-20T09:30:00Z',
        ),
        for (var index = 0; index < _names.length; index++)
          RemoteEntry(
            name: _names[index],
            path: '/studio/shoreline/${_names[index]}',
            isDirectory: false,
            size: (index < 8 ? 2 : 86) * 1024 * 1024 + index * 13824,
            modified:
                '2026-10-21T14:${(10 + index).toString().padLeft(2, '0')}:00Z',
          ),
        const RemoteEntry(
          name: 'Project notes.md',
          path: '/studio/shoreline/Project notes.md',
          isDirectory: false,
          size: 18340,
          modified: '2026-10-21T16:20:00Z',
        ),
      ];
      model.statusChanges.value = {
        'cache': {
          'bytesUsed': 38 * 1024 * 1024,
          'budgetBytes': 512 * 1024 * 1024,
        },
        'mounts': [],
        'activePreviews': 0,
        'readBytes': null,
        'streamBytesServed': 0,
        'activity': [
          {
            'kind': 'playback',
            'message': 'Prepared a read-only document preview.',
          },
          {
            'kind': 'playback',
            'message': 'Released an in-app preview session.',
          },
        ],
      };
      model.lastStatusSuccess = DateTime(2026, 10, 22, 10, 24);
      model.resumeWorkspace();
      model.select(model.tab.entries[1]);
      // Decode in the real asynchronous zone before Image.file is inserted.
      // Waiting for an already pending fake-async image inside runAsync would
      // deadlock the test binding instead of publishing a loaded thumbnail.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final preloadContext = tester.element(find.byType(SizedBox).first);
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage('assets/branding/farshore-mark.png'),
          preloadContext,
        );
        for (final path in artwork.values) {
          for (final width in [80, 500]) {
            await precacheImage(
              ResizeImage(FileImage(File(path)), width: width),
              preloadContext,
            );
          }
        }
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: _capture,
          child: FarshoreApp(model: model, initialize: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(model.thumbnails.values.whereType<String>().length, _names.length);
      await _captureImage(tester, 'browser-midnight');

      model.showHome();
      await model.setTheme(ShoreTheme.shore);
      await _captureImage(tester, 'home-shore');

      await model.setTheme(ShoreTheme.midnight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close path launcher'), findsOneWidget);
      await _captureImage(tester, 'path-launcher');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await model.setTheme(ShoreTheme.shore);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Choose theme'));
      await _captureImage(tester, 'themes');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      // Keep Settings' complete policy/diagnostics/license content visible.
      tester.view.physicalSize = const Size(1440, 1240);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await _captureImage(tester, 'settings');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
