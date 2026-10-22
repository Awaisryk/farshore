import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/home_page.dart';
import 'package:farshore/main.dart';
import 'package:farshore/path_launcher.dart';

const _alpha = RemoteHost('home-a', 'home-alpha', 'alpha', 'u', 22);
const _beta = RemoteHost('home-b', 'home-beta', 'beta', 'u', 2222);

class _HomeBridge implements BridgeClient {
  final calls = <({String method, Map<String, dynamic> params})>[];
  bool failList = false;
  Completer<Map<String, dynamic>>? listing;
  List<Map<String, String>> recents = [
    {'hostId': _beta.id, 'path': '/data2/ exact [folder] '},
    {'hostId': _alpha.id, 'path': '/'},
  ];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: Map.of(params)));
    switch (method) {
      case 'hosts':
        return {
          'hosts': [
            for (final host in [_alpha, _beta])
              {
                'id': host.id,
                'alias': host.alias,
                'hostname': host.hostname,
                'user': host.user,
                'port': host.port,
              },
          ],
          'recentPaths': recents,
        };
      case 'list':
        if (listing != null) return listing!.future;
        if (failList) {
          throw const BridgeFailure(
            'permission_denied',
            'Folder access was denied.',
          );
        }
        return {
          'path': params['path'],
          'entries': [
            {
              'name': 'alpha.txt',
              'path': '${params['path']}/alpha.txt',
              'isDirectory': false,
              'size': 42,
              'modified': '',
            },
          ],
          'fresh': true,
        };
      case 'record_path_visit':
        recents = [
          {
            'hostId': params['hostId'] as String,
            'path': params['path'] as String,
          },
          ...recents.where(
            (r) =>
                r['hostId'] != params['hostId'] || r['path'] != params['path'],
          ),
        ].take(5).toList();
        return {'recentPaths': recents};
      default:
        return {};
    }
  }

  @override
  void dispose() {}
}

void _desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'Home starts without SSH reads and resumes the preserved folder',
    (tester) async {
      _desktop(tester);
      final bridge = _HomeBridge();
      final model = BrowserModel(bridge);
      await model.discover();
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.pumpAndSettle();
      expect(find.byType(FarshoreHomePage), findsOneWidget);
      expect(bridge.calls.where((c) => c.method == 'list'), isEmpty);

      await tester.tap(find.byKey(const ValueKey('home-server-home-a')));
      await tester.pumpAndSettle();
      expect(model.isHome, isFalse);
      await model.navigate('/data');
      model.query = 'alpha';
      model.select(model.tab.entries.single);
      model.changed();
      await tester.pumpAndSettle();
      final tab = model.tab;
      final selection = Set.of(tab.selection);
      final back = List.of(tab.back);
      final reads = bridge.calls.where((c) => c.method == 'list').length;

      await tester.tap(find.byTooltip('Go to Farshore Home'));
      await tester.pumpAndSettle();
      expect(model.isHome, isTrue);
      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.backspace,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pumpAndSettle();
      expect(tab.path, '/data');
      expect(tab.selection, selection);
      expect(tab.back, back);
      expect(bridge.calls.where((c) => c.method == 'list').length, reads);

      await tester.tap(find.byKey(const ValueKey('home-tab-0')));
      await tester.pumpAndSettle();
      expect(model.isHome, isFalse);
      expect(model.tab, same(tab));
      expect(model.query, 'alpha');
      expect(model.tab.selection, selection);
      expect(bridge.calls.where((c) => c.method == 'list').length, reads);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Home recent opens its exact server with retry and records only success',
    (tester) async {
      _desktop(tester);
      final bridge = _HomeBridge()..failList = true;
      final model = BrowserModel(bridge);
      await model.discover();
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-recent-0')));
      await tester.pumpAndSettle();
      expect(find.byType(PathPalette), findsOneWidget);
      expect(find.text('Folder access was denied.'), findsOneWidget);
      expect(model.isHome, isTrue);
      expect(model.tab.host, isNull);
      expect(
        bridge.calls.where((c) => c.method == 'record_path_visit'),
        isEmpty,
      );
      final failedRead = bridge.calls.lastWhere((c) => c.method == 'list');
      expect(failedRead.params, {
        'hostId': _beta.id,
        'path': '/data2/ exact [folder] ',
      });

      bridge.failList = false;
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(PathPalette), findsNothing);
      expect(find.byType(FarshoreHomePage), findsNothing);
      expect(model.tab.host?.id, _beta.id);
      expect(model.tab.path, '/data2/ exact [folder] ');
      expect(
        bridge.calls.where((c) => c.method == 'record_path_visit').length,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dismissing a pending Home recent cannot change destination or history',
    (tester) async {
      _desktop(tester);
      final bridge = _HomeBridge()..listing = Completer<Map<String, dynamic>>();
      final model = BrowserModel(bridge);
      await model.discover();
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-recent-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      bridge.listing!.complete({'path': '/late', 'entries': [], 'fresh': true});
      await tester.pumpAndSettle();
      expect(model.isHome, isTrue);
      expect(model.tab.host, isNull);
      expect(
        bridge.calls.where((c) => c.method == 'record_path_visit'),
        isEmpty,
      );
      expect(find.byType(PathPalette), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
