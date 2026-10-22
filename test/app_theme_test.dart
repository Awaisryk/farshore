import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/app_theme.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';

class ThemeBridge implements BridgeClient {
  String saved = 'shore';
  bool deferWrites = false;
  Completer<Map<String, dynamic>>? discovery;
  final calls = <({String method, Map<String, dynamic> params})>[];
  final writes = <({String id, Completer<Map<String, dynamic>> result})>[];
  void succeed(int index) {
    saved = writes[index].id;
    writes[index].result.complete({'themeId': saved});
  }

  void fail(int index) => writes[index].result.completeError(
    const BridgeFailure('preferences_write', 'Preferences are read only.'),
  );
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: Map.of(params)));
    if (method == 'hosts') {
      return discovery?.future ?? {'hosts': [], 'themeId': saved};
    }
    if (method == 'status') return {};
    if (method != 'set_theme') {
      throw StateError('Unexpected file operation: $method');
    }
    final result = Completer<Map<String, dynamic>>();
    writes.add((id: params['themeId'] as String, result: result));
    if (!deferWrites) succeed(writes.length - 1);
    return result.future;
  }

  @override
  void dispose() {}
}

double contrast(Color a, Color b) {
  final first = a.computeLuminance(), second = b.computeLuminance();
  final light = first > second ? first : second;
  final dark = first > second ? second : first;
  return (light + 0.05) / (dark + 0.05);
}

void main() {
  test(
    'catalog has stable identifiers, descriptive labels and the expected light/dark choices',
    () {
      expect(ShoreTheme.values.map((theme) => theme.id), [
        'shore',
        'deep-shore',
        'frost',
        'sand',
        'midnight',
        'orchid',
      ]);
      expect(ShoreTheme.values.where((theme) => theme.isDark), [
        ShoreTheme.deepShore,
        ShoreTheme.midnight,
        ShoreTheme.orchid,
      ]);
      for (final theme in ShoreTheme.values) {
        expect(ShoreTheme.fromId(theme.id), theme);
        expect(theme.label, isNotEmpty);
        expect(theme.description, isNotEmpty);
        expect(ShoreColors.forTheme(theme).dark, theme.isDark);
      }
      expect(ShoreTheme.fromId(null), ShoreTheme.shore);
      expect(ShoreTheme.fromId('future-theme'), ShoreTheme.shore);
      expect(const ShoreColors(false).canvas, const Color(0xfffaf9f6));
      expect(const ShoreColors(true).canvas, const Color(0xff141b1c));
    },
  );

  test(
    'every palette provides readable text, muted text and accent on its surfaces',
    () {
      final canvases = <Color>{};
      final accents = <Color>{};
      for (final theme in ShoreTheme.values) {
        final colors = ShoreColors.forTheme(theme);
        canvases.add(colors.canvas);
        accents.add(colors.accent);
        for (final surface in [
          colors.canvas,
          colors.sidebar,
          colors.surface,
          colors.soft,
          colors.selection,
        ]) {
          for (final ink in [colors.ink, colors.muted, colors.accent]) {
            expect(
              contrast(ink, surface),
              greaterThanOrEqualTo(4.5),
              reason: '${theme.label} foreground $ink on $surface',
            );
          }
        }
      }
      expect(canvases.length, 6);
      expect(accents.length, 6);
    },
  );

  test(
    'initial discovery restores the saved theme and a reopened model keeps the new choice',
    () async {
      final bridge = ThemeBridge()..saved = 'midnight';
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      await model.initialize();
      expect(model.theme, ShoreTheme.midnight);
      expect(model.dark, isTrue);
      await model.setTheme(ShoreTheme.sand);
      expect(bridge.saved, 'sand');
      final reopened = BrowserModel(bridge);
      addTearDown(reopened.dispose);
      await reopened.discover();
      expect(reopened.theme, ShoreTheme.sand);
      expect(reopened.dark, isFalse);
      expect(
        bridge.calls.every(
          (call) => ['hosts', 'status', 'set_theme'].contains(call.method),
        ),
        isTrue,
      );
    },
  );

  test(
    'successful theme changes notify appearance only and perform no remote reads',
    () async {
      final bridge = ThemeBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      var browser = 0, appearances = 0;
      model.addListener(() => browser++);
      model.appearance.addListener(() => appearances++);
      await model.setTheme(ShoreTheme.frost);
      await model.setTheme(ShoreTheme.orchid);
      await model.setTheme(ShoreTheme.orchid);
      expect((browser, appearances), (0, 2));
      expect(bridge.calls.map((call) => call.method), [
        'set_theme',
        'set_theme',
      ]);
    },
  );

  test(
    'rapid choices stay optimistic, serialize writes and never roll back to intermediate acknowledgments',
    () async {
      final bridge = ThemeBridge()..deferWrites = true;
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final first = model.setTheme(ShoreTheme.frost);
      final second = model.setTheme(ShoreTheme.sand);
      final third = model.setTheme(ShoreTheme.orchid);
      expect(model.theme, ShoreTheme.orchid);
      expect(bridge.writes.map((write) => write.id), ['frost']);
      bridge.succeed(0);
      await first;
      expect(model.theme, ShoreTheme.orchid);
      expect(bridge.writes.map((write) => write.id), ['frost', 'sand']);
      bridge.succeed(1);
      await second;
      expect(model.theme, ShoreTheme.orchid);
      bridge.succeed(2);
      await third;
      expect((model.theme, bridge.saved), (ShoreTheme.orchid, 'orchid'));
    },
  );

  test(
    'only the latest failed choice rolls back and exposes an inline persistence error',
    () async {
      final bridge = ThemeBridge()..deferWrites = true;
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final first = model.setTheme(ShoreTheme.frost);
      final latest = model.setTheme(ShoreTheme.orchid);
      bridge.fail(0);
      await first;
      expect(model.theme, ShoreTheme.orchid);
      expect(model.themeError, isNull);
      expect(model.globalError, isNull);
      bridge.fail(1);
      await latest;
      expect(model.theme, ShoreTheme.shore);
      expect(model.themeError?.message, contains('Preferences are read only'));
      expect(identical(model.themeError, model.globalError), isTrue);
      final retry = model.setTheme(ShoreTheme.midnight);
      expect(model.themeError, isNull);
      expect(model.globalError, isNull);
      bridge.succeed(2);
      await retry;
      expect(model.theme, ShoreTheme.midnight);
    },
  );

  test(
    'latest failure rolls back to the last confirmed saved choice',
    () async {
      final bridge = ThemeBridge()..deferWrites = true;
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final first = model.setTheme(ShoreTheme.sand);
      final second = model.setTheme(ShoreTheme.midnight);
      bridge.succeed(0);
      await first;
      bridge.fail(1);
      await second;
      expect(model.theme, ShoreTheme.sand);
      expect(bridge.saved, 'sand');
    },
  );

  test(
    'a late discovery result cannot overwrite a newer explicit theme choice',
    () async {
      final bridge = ThemeBridge()
        ..discovery = Completer<Map<String, dynamic>>();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final discovering = model.discover();
      await model.setTheme(ShoreTheme.orchid);
      bridge.discovery!.complete({'hosts': [], 'themeId': 'shore'});
      await discovering;
      expect(model.theme, ShoreTheme.orchid);
    },
  );

  test(
    'legacy unknown saved values fall back safely and dark compatibility maps to the original pair',
    () async {
      final bridge = ThemeBridge()..saved = 'unknown';
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      await model.discover();
      expect(model.theme, ShoreTheme.shore);
      model.dark = true;
      expect(model.theme, ShoreTheme.deepShore);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.saved, 'deep-shore');
      model.dark = false;
      expect(model.theme, ShoreTheme.shore);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.saved, 'shore');
    },
  );
}
