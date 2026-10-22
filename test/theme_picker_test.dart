import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/app_theme.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/main.dart';

class ThemePickerBridge implements BridgeClient {
  final calls = <String>[];
  bool failSave = false;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add(method);
    if (method == 'set_theme') {
      if (failSave) {
        throw const BridgeFailure(
          'preferences_write',
          'Theme could not be saved.',
        );
      }
      return {'themeId': params['themeId']};
    }
    return {};
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, path) in [
      ('.AppleSystemUIFont', '/System/Library/Fonts/SFNS.ttf'),
      (
        'MaterialIcons',
        '.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    ]) {
      final font = File(path);
      if (font.existsSync()) {
        await (FontLoader(
          family,
        )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  testWidgets(
    'picker previews every theme live across Home and sidebar without remote work',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = ThemePickerBridge();
      final model = BrowserModel(bridge)..discovering = false;
      model.hosts = const [
        RemoteHost('studio', 'studio', 'studio.local', 'artist', 22),
      ];
      const capture = ValueKey('theme-review');
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: FarshoreApp(model: model, initialize: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Choose theme'));
      await tester.pumpAndSettle();
      for (final theme in ShoreTheme.values) {
        expect(find.text(theme.label), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('theme-card-${theme.id}')));
        await tester.pumpAndSettle();
        final c = ShoreColors.forTheme(theme);
        expect(model.theme, theme);
        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(
          app.theme!.brightness,
          theme.isDark ? Brightness.dark : Brightness.light,
        );
        expect(
          tester.widget<Dialog>(find.byType(Dialog)).backgroundColor,
          c.canvas,
        );
        expect(
          tester.widget<Text>(find.text('Your remote workspace.')).style!.color,
          c.ink,
        );
        final sidebar = tester.widget<Container>(
          find.byKey(const ValueKey('farshore-sidebar')),
        );
        expect((sidebar.decoration! as BoxDecoration).color, c.sidebar);
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final path = File('.build/themes/picker-${theme.id}.png');
          await path.parent.create(recursive: true);
          await path.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Choose your theme'), findsNothing);
      expect(model.theme, ShoreTheme.orchid);
      expect(model.isHome, true);
      expect(bridge.calls.every((method) => method == 'set_theme'), true);
    },
  );

  testWidgets('save failure is visible in the picker and restores the theme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(920, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = ThemePickerBridge()..failSave = true;
    final model = BrowserModel(bridge)..discovering = false;
    await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
    await tester.tap(find.byTooltip('Choose theme'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-card-midnight')));
    await tester.pumpAndSettle();
    expect(model.theme, ShoreTheme.shore);
    expect(
      find.textContaining('Your previous theme was restored.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Choose your theme'), findsNothing);
  });

  testWidgets(
    'theme picker scrolls at larger text scale in the minimum window',
    (tester) async {
      tester.view.physicalSize = const Size(920, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final model = BrowserModel(ThemePickerBridge())..discovering = false;
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.tap(find.byTooltip('Choose theme'));
      await tester.pumpAndSettle();
      final orchid = find.byKey(const ValueKey('theme-card-orchid'));
      await tester.ensureVisible(orchid);
      await tester.tap(orchid);
      await tester.pumpAndSettle();
      expect(model.theme, ShoreTheme.orchid);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your theme'), findsNothing);
    },
  );
}
