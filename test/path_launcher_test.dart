import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/main.dart';
import 'package:farshore/path_launcher.dart';

const alpha = RemoteHost('a', 'alpha', 'alpha', 'user', 22);
const beta = RemoteHost('b', 'beta', 'beta', 'user', 22);

class LauncherBridge implements BridgeClient {
  final calls = <({String method, Map<String, dynamic> params})>[];
  List<Map<String, String>> recents = [
    {'hostId': 'b', 'path': '/data2'},
    {'hostId': 'a', 'path': ''},
    {'hostId': 'a', 'path': '/'},
    {'hostId': 'a', 'path': '/data/ spaced [folder] '},
    {'hostId': 'b', 'path': '/archive'},
  ];
  Completer<Map<String, dynamic>>? pending;
  bool failList = false, failRecord = false;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: Map.of(params)));
    if (method == 'hosts') {
      return {
        'hosts': [
          for (final h in [alpha, beta])
            {'id': h.id, 'alias': h.alias, 'hostname': h.hostname},
        ],
        'recentPaths': recents,
      };
    }
    if (method == 'list') {
      if (pending != null) return pending!.future;
      if (failList) {
        throw const BridgeFailure(
          'permission_denied',
          'This folder is not readable.',
        );
      }
      return {'path': params['path'], 'entries': [], 'fresh': true};
    }
    if (method == 'record_path_visit') {
      if (failRecord) {
        throw const BridgeFailure('preferences_write', 'Disk is read only.');
      }
      recents = [
        {
          'hostId': params['hostId'] as String,
          'path': params['path'] as String,
        },
        for (final r in recents)
          if (r['hostId'] != params['hostId'] || r['path'] != params['path']) r,
      ].take(5).toList();
      return {'recentPaths': recents};
    }
    return {};
  }

  @override
  void dispose() {}
}

void desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder get pathField => find.widgetWithText(TextField, 'Remote folder path');
Future<void> slash(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
  await tester.pumpAndSettle();
}

Future<void> escape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'launcher records accepted literal destinations, keeps Home and Root distinct, and reopens history',
    () async {
      final bridge = LauncherBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      await model.discover();
      model.tab.host = alpha;
      await model.navigate('/ordinary');
      expect(
        bridge.calls.where((c) => c.method == 'record_path_visit'),
        isEmpty,
      );
      for (final path in ['', '/', '/data/ spaced [folder] ']) {
        final result = await model.navigateFromLauncher(
          alpha,
          path,
          PathNavigationAttempt(),
        );
        expect(result.success, isTrue);
        await result.historySaved;
        expect(model.tab.path, path);
      }
      expect(model.recentPaths.take(3).map((r) => r.path), [
        '/data/ spaced [folder] ',
        '/',
        '',
      ]);
      final crossed = await model.navigateFromLauncher(
        beta,
        '/data2',
        PathNavigationAttempt(),
      );
      await crossed.historySaved;
      expect(model.tab.host?.id, 'b');
      expect(model.tab.path, '/data2');
      expect(
        model.tab.back,
        isEmpty,
        reason: 'A cross-server launch must not invent a Home visit.',
      );
      final reopened = BrowserModel(bridge);
      addTearDown(reopened.dispose);
      await reopened.discover();
      expect(reopened.recentPaths.length, 5);
      expect(
        (reopened.recentPaths.first.hostId, reopened.recentPaths.first.path),
        ('b', '/data2'),
      );
    },
  );

  test(
    'canceled and superseded listings never change the browser or recent history',
    () async {
      final bridge = LauncherBridge()
        ..pending = Completer<Map<String, dynamic>>();
      final model = BrowserModel(bridge)..tab.host = alpha;
      addTearDown(model.dispose);
      final attempt = PathNavigationAttempt();
      final result = model.navigateFromLauncher(beta, '/later', attempt);
      attempt.cancel();
      bridge.pending!.complete({'path': '/later', 'entries': []});
      expect((await result).cancelled, isTrue);
      expect(model.tab.host?.id, 'a');
      expect(model.tab.path, '');
      expect(
        bridge.calls.where((c) => c.method == 'record_path_visit'),
        isEmpty,
      );
      bridge.pending = Completer<Map<String, dynamic>>();
      final stale = model.navigateFromLauncher(
        beta,
        '/stale',
        PathNavigationAttempt(),
      );
      model.addTab();
      bridge.pending!.complete({'path': '/stale', 'entries': []});
      expect((await stale).cancelled, isTrue);
      expect(
        bridge.calls.where((c) => c.method == 'record_path_visit'),
        isEmpty,
      );
    },
  );

  test(
    'history save failure preserves a successful listing and reports persistence failure',
    () async {
      final bridge = LauncherBridge()..failRecord = true;
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final result = await model.navigateFromLauncher(
        beta,
        '/data2',
        PathNavigationAttempt(),
      );
      expect(result.success, isTrue);
      await result.historySaved;
      expect(model.tab.path, '/data2');
      expect(
        model.globalError?.message,
        contains('recent location could not be saved'),
      );
      expect(model.recentPaths, isEmpty);
    },
  );

  testWidgets(
    'global slash seeds Root from sidebar, avoids duplicates, excludes text editing, and Cmd+L still works',
    (tester) async {
      desktop(tester);
      final bridge = LauncherBridge();
      final model = BrowserModel(bridge);
      await model.discover();
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
      await tester.pump();
      expect(find.byType(PathPalette), findsNothing);
      // Some layouts produce '/' with Shift; use the character as the intent.
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(PathPalette),
          matching: find.text('Go to folder'),
        ),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(pathField).controller!.text, '/');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.slash, character: '/');
      await tester.pump();
      expect(find.byType(PathPalette), findsOneWidget);
      await escape(tester);
      await model.selectHost(alpha);
      await tester.pumpAndSettle();
      final filter = find.widgetWithText(TextField, 'Filter this folder');
      // File filtering is available once the browser workspace is open.
      await tester.tap(filter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
      await tester.pump();
      expect(find.byType(PathPalette), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byType(PathPalette), findsOneWidget);
      await escape(tester);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'five host-aware recent rows support arrows, literal paths, and cross-server pointer navigation',
    (tester) async {
      desktop(tester);
      final bridge = LauncherBridge();
      final model = BrowserModel(bridge);
      await model.discover();
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.pumpAndSettle();
      await slash(tester);
      expect(
        find.descendant(
          of: find.byType(PathPalette),
          matching: find.byType(ListTile),
        ),
        findsNWidgets(5),
      );
      final semantics = tester.ensureSemantics();
      expect(
        find.descendant(
          of: find.byType(PathPalette),
          matching: find.bySemanticsLabel('alpha · Home'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PathPalette),
          matching: find.bySemanticsLabel('alpha · /'),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(tester.widget<TextField>(pathField).controller!.text, '/data2');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(model.tab.host?.id, 'b');
      expect(model.tab.path, '/data2');
      expect(find.byType(PathPalette), findsNothing);
      await slash(tester);
      await tester.tap(
        find.bySemanticsLabel('alpha · /data/ spaced [folder] '),
      );
      await tester.pumpAndSettle();
      expect(model.tab.host?.id, 'a');
      expect(model.tab.path, '/data/ spaced [folder] ');
      expect(bridge.calls.where((c) => c.method == 'list').last.params, {
        'hostId': 'a',
        'path': '/data/ spaced [folder] ',
      });
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed destination stays open for retry without changing browser or history',
    (tester) async {
      desktop(tester);
      final bridge = LauncherBridge()..failList = true;
      final model = BrowserModel(bridge);
      await model.discover();
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.pumpAndSettle();
      await slash(tester);
      await tester.enterText(pathField, '/data2');
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(find.text('This folder is not readable.'), findsOneWidget);
      expect(model.tab.host, isNull);
      expect(
        bridge.calls.where((c) => c.method == 'record_path_visit'),
        isEmpty,
      );
      bridge.failList = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(model.tab.path, '/data2');
      expect(find.byType(PathPalette), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final barrier in [false, true]) {
    testWidgets(
      'cancel pending listing ${barrier ? 'by barrier' : 'with Escape'} before exit animation prevents commit and underlying route pop',
      (tester) async {
        desktop(tester);
        final bridge = LauncherBridge()
          ..pending = Completer<Map<String, dynamic>>();
        final model = BrowserModel(bridge);
        await model.discover();
        final key = GlobalKey<NavigatorState>();
        final launcher = PathLauncherCoordinator(model, key);
        addTearDown(launcher.dispose);
        addTearDown(model.dispose);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: key,
            home: const Scaffold(body: Text('Browser remains')),
          ),
        );
        unawaited(
          showDialog<void>(
            context: key.currentContext!,
            builder: (_) =>
                const AlertDialog(title: Text('Underlying preview')),
          ),
        );
        await tester.pumpAndSettle();
        await slash(tester);
        await tester.enterText(pathField, '/pending');
        await tester.tap(find.text('Go'));
        await tester.pump();
        if (barrier) {
          await tester.tapAt(const Offset(5, 5));
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        }
        await tester.pump(const Duration(milliseconds: 1));
        bridge.pending!.complete({'path': '/pending', 'entries': []});
        await tester.pumpAndSettle();
        expect(model.tab.host, isNull);
        expect(model.tab.path, '');
        expect(
          bridge.calls.where((c) => c.method == 'record_path_visit'),
          isEmpty,
        );
        expect(find.text('Underlying preview'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'palette cancel preserves media; submission waits for safe stop and removes older dialogs',
    (tester) async {
      desktop(tester);
      final bridge = LauncherBridge();
      final model = BrowserModel(bridge);
      await model.discover();
      final key = GlobalKey<NavigatorState>();
      final launcher = PathLauncherCoordinator(model, key);
      addTearDown(launcher.dispose);
      addTearDown(model.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          home: const Scaffold(body: Text('Browser')),
        ),
      );
      final stop = Completer<bool>();
      var stopCalls = 0;
      launcher.setMediaNavigationGuard(() {
        stopCalls++;
        return stop.future;
      });
      unawaited(
        showDialog<void>(
          context: key.currentContext!,
          builder: (_) => const AlertDialog(title: Text('Paused media')),
        ),
      );
      await tester.pumpAndSettle();
      await slash(tester);
      await escape(tester);
      expect(stopCalls, 0);
      expect(find.text('Paused media'), findsOneWidget);
      await slash(tester);
      await tester.enterText(pathField, '/data2');
      await tester.tap(find.text('Go'));
      await tester.pump();
      expect(stopCalls, 1);
      expect(bridge.calls.where((c) => c.method == 'list'), isEmpty);
      stop.complete(true);
      await tester.pumpAndSettle();
      expect(model.tab.host?.id, 'b');
      expect(model.tab.path, '/data2');
      expect(find.text('Paused media'), findsNothing);
      expect(find.byType(PathPalette), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
