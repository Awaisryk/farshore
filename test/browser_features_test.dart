import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/main.dart';

const featureHosts = [
  RemoteHost('a', 'alpha', 'alpha', 'u', 22),
  RemoteHost('b', 'beta', 'beta', 'u', 22),
  RemoteHost('c', 'gamma', 'gamma', 'u', 22),
];

class FeatureBridge implements BridgeClient {
  final calls = <({String method, Map<String, dynamic> params})>[];
  final favorites = <String>{'c'};
  bool deferFavorites = false;
  final writes =
      <
        ({Map<String, dynamic> params, Completer<Map<String, dynamic>> result})
      >[];
  Map<String, dynamic> get hostsResult => {
    'hosts': [
      for (final h in featureHosts)
        {
          'id': h.id,
          'alias': h.alias,
          'hostname': h.hostname,
          'user': h.user,
          'port': h.port,
        },
    ],
    'favoriteHostIds': favorites.toList(),
  };
  void completeWrite(int index) {
    final write = writes[index];
    if (write.params['favorite'] == true) {
      favorites.add(write.params['hostId'] as String);
    } else {
      favorites.remove(write.params['hostId']);
    }
    write.result.complete({'favoriteHostIds': favorites.toList()});
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: params));
    if (method == 'hosts') return hostsResult;
    if (method == 'list') {
      return {'path': params['path'], 'entries': [], 'fresh': true};
    }
    if (method == 'thumbnail') return {'path': null};
    if (method == 'set_favorite') {
      final result = Completer<Map<String, dynamic>>();
      writes.add((params: params, result: result));
      if (!deferFavorites) completeWrite(writes.length - 1);
      return result.future;
    }
    return {};
  }

  @override
  void dispose() {}
}

void desktopSize(WidgetTester tester, [Size size = const Size(1400, 900)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  test(
    'saved server favorites appear first with stable SSH configuration order after reopening',
    () async {
      final bridge = FeatureBridge();
      final m = BrowserModel(bridge);
      addTearDown(m.dispose);
      await m.discover();
      expect(m.orderedHosts.map((h) => h.id), ['c', 'a', 'b']);
      await m.toggleFavorite(featureHosts[1]);
      expect(m.orderedHosts.map((h) => h.id), ['b', 'c', 'a']);
      expect(m.tab.host, isNull);
      expect(bridge.calls.where((c) => c.method == 'list'), isEmpty);
      final reopened = BrowserModel(bridge);
      addTearDown(reopened.dispose);
      await reopened.discover();
      expect(reopened.orderedHosts.map((h) => h.id), ['b', 'c', 'a']);
      await reopened.toggleFavorite(featureHosts[2]);
      expect(reopened.orderedHosts.map((h) => h.id), ['b', 'a', 'c']);
    },
  );

  test(
    'rapid favorite changes stay optimistic and serialize writes without stale-response rollback',
    () async {
      final bridge = FeatureBridge()..deferFavorites = true;
      final m = BrowserModel(bridge);
      addTearDown(m.dispose);
      await m.discover();
      final first = m.setFavorite(featureHosts[1], true);
      final second = m.setFavorite(featureHosts[0], true);
      final third = m.setFavorite(featureHosts[1], false);
      expect(bridge.writes.length, 1);
      expect(m.favoriteHostIds, {'a', 'c'});
      bridge.completeWrite(0);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.writes.length, 2);
      expect(m.favoriteHostIds, {'a', 'c'});
      bridge.completeWrite(1);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.writes.length, 3);
      bridge.completeWrite(2);
      await Future.wait([first, second, third]);
      expect(m.favoriteHostIds, {'a', 'c'});
      expect(bridge.favorites, {'a', 'c'});
    },
  );

  test(
    'favorite persistence failure rolls back that change, keeps newer intents, and remains visible',
    () async {
      final bridge = FeatureBridge()..deferFavorites = true;
      final m = BrowserModel(bridge);
      addTearDown(m.dispose);
      await m.discover();
      final first = m.setFavorite(featureHosts[1], true);
      final next = m.setFavorite(featureHosts[0], true);
      bridge.writes[0].result.completeError(
        const BridgeFailure(
          'preferences_failed',
          'The preference file is not writable.',
        ),
      );
      await first;
      expect(m.favoriteHostIds, {'a', 'c'});
      expect(m.globalError?.message, contains('not writable'));
      bridge.completeWrite(1);
      await next;
      expect(m.favoriteHostIds, {'a', 'c'});
      expect(bridge.favorites, {'a', 'c'});
    },
  );

  test(
    'absolute folder navigation preserves root, home, parents, and history separately',
    () async {
      final m = BrowserModel(FeatureBridge());
      addTearDown(m.dispose);
      m.tab.host = featureHosts.first;
      await m.navigate('/');
      await m.navigate('/data/project one');
      await m.parent();
      expect(m.tab.path, '/data');
      await m.goBack();
      expect(m.tab.path, '/data/project one');
      await m.goForward();
      expect(m.tab.path, '/data');
      await m.parent();
      expect(m.tab.path, '/');
      await m.navigate('');
      expect(m.tab.path, '');
      await m.goBack();
      expect(m.tab.path, '/');
    },
  );

  testWidgets(
    'sidebar stars reorder saved servers without starting an SSH directory read',
    (tester) async {
      desktopSize(tester);
      final bridge = FeatureBridge();
      final m = BrowserModel(bridge);
      await m.discover();
      await tester.pumpWidget(FarshoreApp(model: m, initialize: false));
      final sidebar = find.byKey(const ValueKey('farshore-sidebar'));
      Finder sidebarText(String text) =>
          find.descendant(of: sidebar, matching: find.text(text));
      expect(
        tester.getTopLeft(sidebarText('gamma')).dy,
        lessThan(tester.getTopLeft(sidebarText('alpha')).dy),
      );
      await tester.tap(
        find.descendant(of: sidebar, matching: find.byTooltip('Favorite beta')),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove beta from favorites'), findsOneWidget);
      expect(
        tester.getTopLeft(sidebarText('beta')).dy,
        lessThan(tester.getTopLeft(sidebarText('gamma')).dy),
      );
      expect(m.tab.host, isNull);
      expect(bridge.calls.where((c) => c.method == 'list'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Home, Root, Cmd+L absolute path, and breadcrumbs navigate beyond SSH home',
    (tester) async {
      desktopSize(tester, const Size(920, 620));
      final bridge = FeatureBridge();
      final m = BrowserModel(bridge)..discovering = false;
      m.tab.host = featureHosts.first;
      m.resumeWorkspace();
      await tester.pumpWidget(FarshoreApp(model: m, initialize: false));
      await tester.tap(find.byTooltip('Go to filesystem root /'));
      await tester.pumpAndSettle();
      expect(m.tab.path, '/');
      expect(find.text('Root · alpha'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.text('Go to folder'), findsOneWidget);
      final field = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.labelText == 'Remote folder path',
      );
      await tester.enterText(field, '/data2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(m.tab.path, '/data2');
      expect(bridge.calls.last.params['path'], '/data2');
      await tester.tap(find.byTooltip('Go to SSH home folder'));
      await tester.pumpAndSettle();
      expect(m.tab.path, '');
      await m.goBack();
      await tester.pumpAndSettle();
      expect(m.tab.path, '/data2');
      await m.navigate('/data/project');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'data'));
      await tester.pumpAndSettle();
      expect(m.tab.path, '/data');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large video directories only enqueue visible thumbnails and never start playback to browse',
    (tester) async {
      desktopSize(tester);
      final bridge = FeatureBridge();
      final m = BrowserModel(bridge)..discovering = false;
      m.tab.host = featureHosts.first;
      m.tab.entries = List.generate(
        1200,
        (i) => RemoteEntry(
          name: 'video${i.toString().padLeft(4, '0')}.mp4',
          path: '/data/video$i.mp4',
          isDirectory: false,
          size: 4000000000,
          modified: '2026-10-22',
        ),
      );
      m.resumeWorkspace();
      await tester.pumpWidget(FarshoreApp(model: m, initialize: false));
      await tester.pumpAndSettle();
      final requests = bridge.calls
          .where((c) => c.method == 'thumbnail')
          .length;
      expect(requests, greaterThan(0));
      expect(requests, lessThan(100));
      expect(
        bridge.calls.where(
          (c) => c.method == 'open' || c.method == 'prepare_media',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
