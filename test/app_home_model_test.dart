import 'dart:async';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:flutter_test/flutter_test.dart';

const alpha = RemoteHost('alpha', 'alpha-server', 'alpha', 'user', 22);
const beta = RemoteHost('beta', 'beta-server', 'beta', 'user', 22);
const selectedFile = RemoteEntry(
  name: 'clip.mp4',
  path: '/media/clip.mp4',
  isDirectory: false,
  size: 100,
  modified: '2026-10-22',
);

class HomeBridge implements BridgeClient {
  final calls = <({String method, Map<String, dynamic> params})>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? handler;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: Map.of(params)));
    if (handler != null) return handler!(method, params);
    return switch (method) {
      'hosts' => {
        'hosts': [
          for (final host in [alpha, beta])
            {'id': host.id, 'alias': host.alias, 'hostname': host.hostname},
        ],
        'favoriteHostIds': ['beta'],
        'recentPaths': [
          {'hostId': 'alpha', 'path': '/media'},
        ],
      },
      'status' => {
        'cache': {'bytesUsed': 100, 'budgetBytes': 1024},
        'activePreviews': 0,
      },
      'list' => directory(params['path'] as String),
      'record_path_visit' => {
        'recentPaths': [
          {'hostId': params['hostId'], 'path': params['path']},
        ],
      },
      _ => {},
    };
  }

  @override
  void dispose() {}
}

Map<String, dynamic> directory(String path) => {
  'path': path,
  'entries': [],
  'fresh': true,
};

BrowserTab seedWorkspace(BrowserModel model) {
  final target = model.tab;
  target.host = alpha;
  target.path = '/media';
  target.entries = [selectedFile];
  target.selection.add(selectedFile.path);
  target.focusedPath = selectedFile.path;
  target.back.addAll(['', '/']);
  target.forward.add('/archive');
  model.query = 'clip';
  model.resumeWorkspace();
  return target;
}

void main() {
  test(
    'startup Home discovers real metadata without connecting to a host',
    () async {
      final bridge = HomeBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      expect(model.isHome, isTrue);
      expect(model.canResumeWorkspace, isFalse);
      expect(model.resumeWorkspace(), isFalse);
      expect(model.lastStatusSuccess, isNull);
      expect(model.status, isEmpty);

      await model.initialize();

      expect(model.isHome, isTrue);
      expect(model.tab.host, isNull);
      expect(model.hosts.map((host) => host.id), ['alpha', 'beta']);
      expect(model.favoriteHostIds, {'beta'});
      expect(model.recentPaths.single.path, '/media');
      expect(bridge.calls.map((call) => call.method), ['hosts', 'status']);
      expect(model.lastStatusSuccess, isNotNull);
      expect(model.statusError, isNull);
    },
  );

  test(
    'Home round trip preserves tabs, selection, filter and remote history',
    () {
      final bridge = HomeBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final first = seedWorkspace(model);
      final second = BrowserTab(host: beta, path: '/data2');
      model.tabs.add(second);

      model.showHome();

      expect(model.isHome, isTrue);
      expect(model.canResumeWorkspace, isTrue);
      expect(model.tab, same(first));
      expect(model.tabs, [first, second]);
      expect(model.resumeWorkspace(), isTrue);
      expect(model.isHome, isFalse);
      expect(model.tab, same(first));
      expect(model.tab.path, '/media');
      expect(model.tab.selection, {selectedFile.path});
      expect(model.selected, same(selectedFile));
      expect(model.tab.back, ['', '/']);
      expect(model.tab.forward, ['/archive']);
      expect(model.query, 'clip');
      expect(bridge.calls, isEmpty);
    },
  );

  test('remote Home is a folder destination distinct from app Home', () async {
    final bridge = HomeBridge();
    final model = BrowserModel(bridge);
    addTearDown(model.dispose);

    await model.selectHost(alpha);

    expect(model.isHome, isFalse);
    expect(model.tab.host, same(alpha));
    expect(model.tab.path, '');
    final saved = model.tab;
    model.showHome();
    expect(model.isHome, isTrue);
    expect(model.tab, same(saved));
    expect(model.tab.path, '');
    expect(model.resumeWorkspace(), isTrue);
    expect(model.isHome, isFalse);
    expect(bridge.calls.map((call) => call.method), ['list']);
  });

  test(
    'Home host selection resumes existing tabs and preserves other work',
    () async {
      final bridge = HomeBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final first = seedWorkspace(model);
      model.showHome();

      await model.selectHost(alpha);
      expect(model.isHome, isFalse);
      expect(model.tab, same(first));
      expect(model.query, 'clip');
      expect(model.tab.selection, {selectedFile.path});
      expect(bridge.calls, isEmpty);

      model.showHome();
      await model.selectHost(beta);
      expect(model.isHome, isFalse);
      expect(model.tabs.length, 2);
      expect(model.tabs.first, same(first));
      expect(model.tab.host, same(beta));
      expect(first.back, ['', '/']);
      expect(first.selection, {selectedFile.path});
      expect(bridge.calls.map((call) => call.method), ['list']);
      model.showHome();
      model.activateTab(0);
      expect(model.isHome, isFalse);
      expect(model.tab, same(first));
      expect(bridge.calls.length, 1);
    },
  );

  test(
    'failed Home connection stays Home and allows retry or prior workspace',
    () async {
      final bridge = HomeBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final first = seedWorkspace(model);
      model.showHome();
      bridge.handler = (_, _) async => throw const BridgeFailure(
        'permission_denied',
        'The server could not be read.',
      );

      await model.selectHost(beta);

      expect(model.isHome, isTrue);
      expect(model.globalError?.code, 'permission_denied');
      expect(model.tabs.first, same(first));
      expect(model.resumeWorkspace(), isTrue);
      expect(model.tab, same(first));
      model.showHome();
      bridge.handler = null;
      await model.selectHost(beta);
      expect(model.isHome, isFalse);
      expect(model.tab.host, same(beta));
      expect(model.globalError, isNull);
      expect(model.tabs.length, 2);
      expect(
        bridge.calls.where((call) => call.method == 'record_path_visit'),
        isEmpty,
      );
    },
  );

  test(
    'explicit tab activation keeps its identity after a failed Home connection',
    () async {
      final bridge = HomeBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      seedWorkspace(model);
      model.showHome();
      bridge.handler = (_, _) async =>
          throw const BridgeFailure('connection_failed', 'Unavailable.');
      await model.selectHost(beta);
      final failed = model.tab;
      final failedIndex = model.activeTab;
      model.query = 'kept filter';
      expect(model.globalError, same(failed.error));

      model.activateTab(failedIndex, preserveQuery: true);

      expect(model.isHome, isFalse);
      expect(model.tab, same(failed));
      expect(model.tab.host, same(beta));
      expect(model.query, 'kept filter');
      expect(model.tab.error?.code, 'connection_failed');
      expect(model.globalError, isNull);
      expect(bridge.calls.length, 1);

      const unrelated = BridgeFailure(
        'preferences_write',
        'Favorites were not saved.',
      );
      model.globalError = unrelated;
      model.showHome();
      model.activateTab(failedIndex, preserveQuery: true);
      expect(model.globalError, same(unrelated));

      bridge.handler = null;
      await model.navigate(model.tab.path, record: false);
      expect(model.tab.error, isNull);
      expect(model.globalError, same(unrelated));
    },
  );

  test(
    'duplicate pending Home host selection waits for the original result',
    () async {
      final bridge = HomeBridge();
      final pending = Completer<Map<String, dynamic>>();
      bridge.handler = (_, _) => pending.future;
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final original = seedWorkspace(model);
      model.showHome();
      final request = model.selectHost(beta);
      final target = model.tab;

      await model.selectHost(beta);
      expect(model.isHome, isTrue);
      expect(target.loading, isTrue);
      expect(bridge.calls.length, 1);
      model.showHome();
      model.activateTab(0, preserveQuery: true);
      pending.complete(directory('/remote-home'));
      await request;

      expect(model.isHome, isFalse);
      expect(model.tab, same(original));
      expect(model.tabs, [original, target]);
      expect(original.path, '/media');
      expect(original.selection, {selectedFile.path});
      expect(target.path, '/remote-home');
      expect(target.loading, isFalse);
      expect(bridge.calls.map((call) => call.method), ['list']);
    },
  );

  test(
    'a failed Home launcher leaves every workspace tab and history untouched',
    () async {
      final bridge = HomeBridge()
        ..handler = (_, _) async => throw const BridgeFailure(
          'permission_denied',
          'Folder unavailable.',
        );
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final original = seedWorkspace(model);
      model.showHome();
      final result = await model.navigateFromLauncher(
        beta,
        '/root',
        PathNavigationAttempt(),
      );

      expect(result.success, isFalse);
      expect(result.error?.code, 'permission_denied');
      expect(model.isHome, isTrue);
      expect(model.tabs, [original]);
      expect(original.path, '/media');
      expect(original.back, ['', '/']);
      expect(original.selection, {selectedFile.path});
      expect(model.recentPaths, isEmpty);
      expect(bridge.calls.map((call) => call.method), ['list']);
    },
  );

  test(
    'accepted Home launcher navigation preserves tabs and saves only its visit',
    () async {
      final bridge = HomeBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final first = seedWorkspace(model);
      model.showHome();

      final result = await model.navigateFromLauncher(
        beta,
        '/data2',
        PathNavigationAttempt(),
      );
      await result.historySaved;

      expect(result.success, isTrue);
      expect(model.isHome, isFalse);
      expect(model.tabs.length, 2);
      expect(model.tabs.first, same(first));
      expect(model.tab.host, same(beta));
      expect(model.tab.path, '/data2');
      expect(model.tab.back, isEmpty);
      expect(first.selection, {selectedFile.path});
      expect(model.recentPaths.single.hostId, 'beta');
      expect(model.recentPaths.single.path, '/data2');
      expect(bridge.calls.map((call) => call.method), [
        'list',
        'record_path_visit',
      ]);

      model.showHome();
      final reopen = await model.navigateFromLauncher(
        alpha,
        '/archive',
        PathNavigationAttempt(),
      );
      await reopen.historySaved;
      expect(model.tab, same(first));
      expect(model.tabs.length, 2);
      expect(first.path, '/archive');
      expect(first.back, ['', '/', '/media']);
    },
  );

  for (final explicitlyCancelled in [true, false]) {
    test(
      'Home launcher ${explicitlyCancelled ? 'cancellation' : 'return then resume'} rejects late success',
      () async {
        final bridge = HomeBridge();
        final pending = Completer<Map<String, dynamic>>();
        bridge.handler = (_, _) => pending.future;
        final model = BrowserModel(bridge);
        addTearDown(model.dispose);
        final first = seedWorkspace(model);
        model.showHome();
        final attempt = PathNavigationAttempt();
        final request = model.navigateFromLauncher(beta, '/data', attempt);
        if (explicitlyCancelled) {
          attempt.cancel();
        } else {
          model.showHome();
          model.resumeWorkspace();
          model.showHome();
        }
        pending.complete(directory('/data'));
        final result = await request;

        expect(result.cancelled, isTrue);
        expect(result.success, isFalse);
        expect(model.isHome, isTrue);
        expect(model.tabs, [first]);
        expect(model.tab.path, '/media');
        expect(first.selection, {selectedFile.path});
        expect(bridge.calls.map((call) => call.method), ['list']);
        expect(model.recentPaths, isEmpty);
      },
    );
  }

  test(
    'a directory response can refresh hidden work without leaving Home',
    () async {
      final bridge = HomeBridge();
      final pending = Completer<Map<String, dynamic>>();
      bridge.handler = (_, _) => pending.future;
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      final first = seedWorkspace(model);
      final request = model.navigate('/archive');
      model.showHome();
      pending.complete(directory('/archive'));
      await request;

      expect(model.isHome, isTrue);
      expect(model.tab, same(first));
      expect(first.loading, isFalse);
      expect(first.path, '/archive');
      expect(model.resumeWorkspace(), isTrue);
      expect(model.tab.path, '/archive');
      expect(bridge.calls.map((call) => call.method), ['list']);
    },
  );

  test(
    'resume tolerates closing the remembered tab and an empty active tab',
    () {
      final bridge = HomeBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      seedWorkspace(model);
      final second = BrowserTab(host: beta, path: '/data');
      model.tabs.addAll([second, BrowserTab()]);
      model.showHome();
      model.closeTab(0);
      model.activeTab = 1;

      expect(model.canResumeWorkspace, isTrue);
      expect(model.resumeWorkspace(), isTrue);
      expect(model.tab, same(second));
      expect(model.isHome, isFalse);
      expect(bridge.calls, isEmpty);
    },
  );

  test(
    'status refreshes coalesce and notify only their narrow listener',
    () async {
      final bridge = HomeBridge();
      final pending = Completer<Map<String, dynamic>>();
      bridge.handler = (_, _) => pending.future;
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      var broad = 0, narrow = 0;
      model.addListener(() => broad++);
      model.statusChanges.addListener(() => narrow++);
      final first = model.refreshStatus();
      final second = model.refreshStatus();

      expect(model.statusRefreshing, isTrue);
      expect(narrow, 0);
      expect(bridge.calls.length, 1);
      pending.complete({'activePreviews': 2});
      await Future.wait([first, second]);

      expect(model.statusRefreshing, isFalse);
      expect(model.lastStatusSuccess, isNotNull);
      expect(model.statusError, isNull);
      expect(model.status['activePreviews'], 2);
      expect(narrow, 1);
      expect(broad, 0);
      bridge.handler = (_, _) async => {'activePreviews': 2};
      await model.refreshStatus();
      expect(narrow, 2);
      expect(broad, 0);
    },
  );

  test(
    'failed status keeps the last snapshot and foreground error, then recovers',
    () async {
      final bridge = HomeBridge();
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      const foreground = BridgeFailure(
        'host_identity_changed',
        'Check the trusted key.',
      );
      model.globalError = foreground;
      await model.refreshStatus();
      final checked = model.lastStatusSuccess;
      final snapshot = model.status;
      var changes = 0;
      model.statusChanges.addListener(() => changes++);
      bridge.handler = (_, _) async =>
          throw const BridgeFailure('bridge_closed', 'Unavailable.');

      await model.refreshStatus();

      expect(model.lastStatusSuccess, checked);
      expect(model.status, snapshot);
      expect(model.statusError?.code, 'bridge_closed');
      expect(model.statusRefreshing, isFalse);
      expect(model.globalError, same(foreground));
      expect(changes, 1);
      await model.refreshStatus();
      expect(changes, 1);
      bridge.handler = null;
      await model.refreshStatus();
      expect(model.statusError, isNull);
      expect(model.lastStatusSuccess, isNotNull);
      expect(changes, 2);
    },
  );

  test(
    'status unavailable before first success remains distinct from a zero snapshot',
    () async {
      final bridge = HomeBridge()
        ..handler = (_, _) async =>
            throw const BridgeFailure('bridge_closed', 'Unavailable.');
      final model = BrowserModel(bridge);
      addTearDown(model.dispose);
      await model.refreshStatus();
      expect(model.lastStatusSuccess, isNull);
      expect(model.status, isEmpty);
      expect(model.statusError?.code, 'bridge_closed');
      expect(model.statusRefreshing, isFalse);
    },
  );
}
