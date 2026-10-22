import 'dart:async';
import 'dart:convert';
import 'package:farshore/app_theme.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const alpha = {
  'id': 'alpha',
  'alias': 'Alpha',
  'hostname': 'alpha.invalid',
  'user': 'private-user',
  'port': 22,
};
const beta = {
  'id': 'beta',
  'alias': 'Beta',
  'hostname': 'beta.invalid',
  'user': 'other-user',
  'port': 22,
};

class WorkspaceBridge implements BridgeClient {
  List<Map<String, dynamic>> hosts = [alpha, beta];
  Map<String, dynamic> workspace = {
    'version': 1,
    'tabs': [
      {'hostId': 'alpha', 'path': ''},
      {'hostId': 'beta', 'path': '/data2/Folder with spaces'},
    ],
    'activeTab': 1,
    'isHome': false,
  };
  Map<String, dynamic> browserSettings = {
    'view': 'list',
    'tileSize': 180,
    'sort': 'newest',
    'showHidden': true,
    'inspector': false,
    'restoreWorkspace': true,
  };
  List<Map<String, String>> favoritePaths = [];
  int budget = 512 * 1024 * 1024;
  int used = 4096;
  final calls = <({String method, Map<String, dynamic> params})>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? handler;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: Map.from(params)));
    if (handler != null) return handler!(method, params);
    return response(method, params);
  }

  Map<String, dynamic> response(String method, Map<String, dynamic> params) {
    switch (method) {
      case 'hosts':
        return {
          'hosts': hosts,
          'workspace': workspace,
          'browserSettings': browserSettings,
          'favoritePaths': favoritePaths,
          'cacheSettings': {'thumbnailBudgetBytes': budget},
        };
      case 'status':
        return {
          'cache': {'bytesUsed': used, 'budgetBytes': budget},
          'activePreviews': 0,
        };
      case 'list':
        return {'path': params['path'], 'entries': [], 'fresh': true};
      case 'save_workspace':
        workspace = Map.from(params['workspace'] as Map);
        browserSettings = Map.from(params['browserSettings'] as Map);
        return {'workspace': workspace, 'browserSettings': browserSettings};
      case 'set_favorite_path':
        favoritePaths = favoritePaths
            .where(
              (item) =>
                  item['hostId'] != params['hostId'] ||
                  item['path'] != params['path'],
            )
            .toList();
        if (params['favorite'] == true) {
          favoritePaths.add({
            'hostId': params['hostId'] as String,
            'path': params['path'] as String,
          });
        }
        return {'favoritePaths': favoritePaths};
      case 'set_cache_settings':
        budget = params['thumbnailBudgetBytes'] as int;
        return {
          'cacheSettings': {'thumbnailBudgetBytes': budget},
          'cache': {'bytesUsed': used, 'budgetBytes': budget},
        };
      case 'clear_thumbnail_cache':
        used = 0;
        return {
          'cleared': true,
          'removedFiles': 1,
          'removedBytes': 4096,
          'cache': {'bytesUsed': 0, 'budgetBytes': budget},
        };
      case 'diagnostics':
        return {
          'version': 1,
          'runtime': {'platform': 'macos'},
          'counts': {'hosts': hosts.length},
        };
      default:
        return {};
    }
  }

  @override
  void dispose() {}
}

BrowserModel model(WorkspaceBridge bridge) =>
    BrowserModel(bridge, workspaceSaveDelay: const Duration(hours: 1));
Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'restore keeps Home versus root distinct and connects only the resumed tab',
    () async {
      final bridge = WorkspaceBridge();
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.initialize();
      expect(m.workspaceRestored, true);
      expect(m.isHome, false);
      expect(m.activeTab, 1);
      expect(m.tabs.map((tab) => tab.path), ['', '/data2/Folder with spaces']);
      expect(m.tabs.every((tab) => tab.needsLoad && tab.entries.isEmpty), true);
      expect(bridge.calls.map((call) => call.method), ['hosts', 'status']);
      expect(m.view, BrowserView.list);
      expect(m.tileSize, 180);
      expect(m.sort, EntrySort.newest);
      expect(m.showHidden, true);
      expect(m.inspector, false);
      m.resumeWorkspace();
      await tick();
      expect(
        bridge.calls.where((call) => call.method == 'list').single.params,
        {'hostId': 'beta', 'path': '/data2/Folder with spaces'},
      );
      expect(m.tabs[0].needsLoad, true);
      m.activateTab(0);
      await tick();
      final listings = bridge.calls
          .where((call) => call.method == 'list')
          .toList();
      expect(listings.last.params, {'hostId': 'alpha', 'path': ''});
      expect(m.tabs[0].needsLoad, false);
      m.activateTab(1);
      await tick();
      expect(bridge.calls.where((call) => call.method == 'list'), hasLength(2));
      expect(
        bridge.calls.any((call) => call.method == 'record_path_visit'),
        false,
      );
    },
  );

  test(
    'a missing saved host is retained and recoverable without a speculative connection',
    () async {
      final bridge = WorkspaceBridge()..hosts = [alpha];
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.discover();
      expect(m.tab.host!.id, 'beta');
      expect(m.tab.hostUnavailable, true);
      expect(m.tab.error!.code, 'saved_host_missing');
      expect(m.resumeWorkspace(), true);
      await tick();
      expect(bridge.calls.any((call) => call.method == 'list'), false);
      bridge.hosts = [alpha, beta];
      await m.discover();
      expect(m.tab.hostUnavailable, false);
      expect(m.tab.host!.alias, 'Beta');
      m.activateTab(m.activeTab);
      await tick();
      expect(bridge.calls.where((call) => call.method == 'list'), hasLength(1));
    },
  );

  test(
    'disabled restoration still restores display preferences and starts a fresh Home',
    () async {
      final bridge = WorkspaceBridge()
        ..browserSettings['restoreWorkspace'] = false;
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.discover();
      expect(m.restoreWorkspace, false);
      expect(m.workspaceRestored, false);
      expect(m.tabs.single.host, null);
      expect(m.isHome, true);
      expect(m.view, BrowserView.list);
      expect(bridge.calls.map((call) => call.method), ['hosts']);
    },
  );

  test(
    'coalesced workspace saves contain locations and preferences but no selections or SSH details',
    () async {
      final bridge = WorkspaceBridge();
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.discover();
      m.view = BrowserView.gallery;
      m.changed();
      m.tileSize = 225;
      m.sort = EntrySort.largest;
      m.showHidden = false;
      m.inspector = true;
      m.changed();
      m.tab.selection.add('private-selected-file.mp4');
      m.selectionChanged();
      await m.flushWorkspace();
      final saves = bridge.calls
          .where((call) => call.method == 'save_workspace')
          .toList();
      expect(saves, hasLength(1));
      final saved = saves.single.params;
      expect(saved['workspace'], {
        'version': 1,
        'tabs': [
          {'hostId': 'alpha', 'path': ''},
          {'hostId': 'beta', 'path': '/data2/Folder with spaces'},
        ],
        'activeTab': 1,
        'isHome': false,
      });
      expect(saved['browserSettings'], {
        'view': 'gallery',
        'tileSize': 225.0,
        'sort': 'largest',
        'showHidden': false,
        'inspector': true,
        'restoreWorkspace': true,
      });
      final serialized = jsonEncode(saved);
      expect(serialized, isNot(contains('private-selected-file')));
      expect(serialized, isNot(contains('private-user')));
      expect(serialized, isNot(contains('alpha.invalid')));
      m.selectionChanged();
      await m.flushWorkspace();
      expect(
        bridge.calls.where((call) => call.method == 'save_workspace'),
        hasLength(1),
      );
    },
  );

  test(
    'workspace writes serialize and an earlier failed save cannot override a newer intent',
    () async {
      final bridge = WorkspaceBridge();
      final first = Completer<Map<String, dynamic>>();
      var writes = 0;
      bridge.handler = (method, params) async {
        if (method == 'save_workspace' && writes++ == 0) return first.future;
        return bridge.response(method, params);
      };
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.discover();
      m.view = BrowserView.grid;
      m.changed();
      final flushing = m.flushWorkspace();
      await tick();
      m.view = BrowserView.gallery;
      m.changed();
      final secondFlush = m.flushWorkspace();
      expect(
        bridge.calls.where((call) => call.method == 'save_workspace'),
        hasLength(1),
      );
      first.completeError(
        const BridgeFailure('preferences_write', 'Disk unavailable.'),
      );
      await Future.wait([flushing, secondFlush]);
      final saves = bridge.calls
          .where((call) => call.method == 'save_workspace')
          .toList();
      expect(saves, hasLength(2));
      expect((saves.last.params['browserSettings'] as Map)['view'], 'gallery');
      expect(m.workspaceError, null);
      expect(m.globalError, null);
    },
  );

  test(
    'failed workspace writes are visible and can be retried after the storage recovers',
    () async {
      final bridge = WorkspaceBridge();
      var fail = true;
      bridge.handler = (method, params) async {
        if (method == 'save_workspace' && fail) {
          throw const BridgeFailure('preferences_write', 'Disk unavailable.');
        }
        return bridge.response(method, params);
      };
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.discover();
      m.inspector = true;
      m.changed();
      await m.flushWorkspace();
      expect(m.workspaceError!.message, contains('Disk unavailable'));
      fail = false;
      await m.retryWorkspaceSave();
      expect(m.workspaceError, null);
      expect(m.globalError, null);
      expect(bridge.browserSettings['inspector'], true);
    },
  );

  test(
    'a workspace preference selected during discovery wins over the late saved state',
    () async {
      final bridge = WorkspaceBridge();
      final pending = Completer<Map<String, dynamic>>();
      bridge.handler = (method, params) async =>
          method == 'hosts' ? pending.future : bridge.response(method, params);
      final m = model(bridge);
      addTearDown(m.dispose);
      final discovering = m.discover();
      m.setRestoreWorkspace(false);
      pending.complete(bridge.response('hosts', {}));
      await discovering;
      expect(m.restoreWorkspace, false);
      expect(m.tabs.single.host, null);
      await m.flushWorkspace();
      expect(bridge.browserSettings['restoreWorkspace'], false);
    },
  );

  test(
    'favorite folders distinguish Home and root, serialize writes, and never connect',
    () async {
      final bridge = WorkspaceBridge();
      final first = Completer<Map<String, dynamic>>();
      var writes = 0;
      bridge.handler = (method, params) async {
        if (method == 'set_favorite_path' && writes++ == 0) return first.future;
        return bridge.response(method, params);
      };
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.discover();
      final home = m.setFavoritePath('alpha', '', true);
      final root = m.setFavoritePath('alpha', '/', true);
      expect(m.favoritePaths.map((item) => item.path), ['', '/']);
      expect(
        bridge.calls.where((call) => call.method == 'set_favorite_path'),
        hasLength(1),
      );
      bridge.favoritePaths = [
        {'hostId': 'alpha', 'path': ''},
      ];
      first.complete({'favoritePaths': bridge.favoritePaths});
      await Future.wait([home, root]);
      expect(m.favoritePaths.map((item) => item.path), ['', '/']);
      expect(m.isFavoritePath('alpha', '/'), true);
      expect(bridge.calls.any((call) => call.method == 'list'), false);
    },
  );

  test(
    'cache and diagnostic actions use their dedicated local RPCs and surface failure',
    () async {
      final bridge = WorkspaceBridge();
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.initialize();
      expect(await m.setThumbnailBudget(128 * 1024 * 1024), true);
      expect(m.cacheSettings['thumbnailBudgetBytes'], 128 * 1024 * 1024);
      expect(await m.clearThumbnailCache(), true);
      expect((m.status['cache'] as Map)['bytesUsed'], 0);
      final report = await m.loadDiagnostics();
      expect(jsonDecode(report!)['version'], 1);
      bridge.handler = (method, params) async {
        if (method == 'clear_thumbnail_cache') return {'cleared': false};
        return bridge.response(method, params);
      };
      expect(await m.clearThumbnailCache(), false);
      expect(m.settingsError!.code, 'cache_clear_failed');
      expect(bridge.calls.any((call) => call.method == 'list'), false);
    },
  );

  test(
    'late discovery cannot overwrite a newly confirmed cache limit',
    () async {
      final bridge = WorkspaceBridge();
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.discover();
      final oldHosts = bridge.response('hosts', {});
      final pending = Completer<Map<String, dynamic>>();
      bridge.handler = (method, params) async =>
          method == 'hosts' ? pending.future : bridge.response(method, params);
      final discovering = m.discover();
      expect(await m.setThumbnailBudget(128 * 1024 * 1024), true);
      pending.complete(oldHosts);
      await discovering;
      expect(m.cacheSettings['thumbnailBudgetBytes'], 128 * 1024 * 1024);
    },
  );

  test(
    'the tab limit prevents silently losing the active folder from saved state',
    () async {
      final bridge = WorkspaceBridge();
      bridge.workspace['tabs'] = [
        for (var i = 0; i < 32; i++) {'hostId': 'alpha', 'path': '/folder-$i'},
      ];
      bridge.workspace['activeTab'] = 31;
      final m = model(bridge);
      addTearDown(m.dispose);
      await m.discover();
      m.addTab();
      expect(m.tabs, hasLength(32));
      expect(m.globalError?.code, 'workspace_tab_limit');
      expect(m.tab.path, '/folder-31');
      m.showHome();
      await m.selectHost(
        const RemoteHost('new', 'New', 'new.invalid', 'u', 22),
      );
      expect(m.tabs, hasLength(32));
      expect(bridge.calls.any((call) => call.method == 'list'), false);
      final launched = await m.navigateFromLauncher(
        const RemoteHost('new', 'New', 'new.invalid', 'u', 22),
        '/data',
        PathNavigationAttempt(),
      );
      expect(launched.success, false);
      expect(launched.error?.code, 'workspace_tab_limit');
      expect(bridge.calls.any((call) => call.method == 'list'), false);
      await m.flushWorkspace();
      expect((bridge.workspace['tabs'] as List).last, {
        'hostId': 'alpha',
        'path': '/folder-31',
      });
      expect(bridge.workspace['activeTab'], 31);
    },
  );

  testWidgets(
    'settings offers real folder, cache, and diagnostic actions in compact light and dark themes',
    (tester) async {
      tester.view.physicalSize = const Size(920, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      for (final theme in [ShoreTheme.shore, ShoreTheme.deepShore]) {
        final bridge = WorkspaceBridge()
          ..favoritePaths = [
            {'hostId': 'alpha', 'path': '/data'},
          ];
        final m = model(bridge);
        await m.initialize();
        await m.setTheme(theme);
        RecentPath? opened;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSettingsDialog(
                  context,
                  m,
                  onOpenFolder: (item) => opened = item,
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();
        expect(find.text('Settings'), findsOneWidget);
        expect(find.text('Remember open folders'), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Open Alpha · /data'));
        await tester.tap(find.byTooltip('Open Alpha · /data'));
        expect(opened!.hostId, 'alpha');
        expect(opened!.path, '/data');
        await tester.ensureVisible(find.text('Clear thumbnail cache'));
        await tester.tap(find.text('Clear thumbnail cache'));
        await tester.pumpAndSettle();
        expect(
          bridge.calls.where((call) => call.method == 'clear_thumbnail_cache'),
          hasLength(1),
        );
        await tester.ensureVisible(find.text('Copy diagnostics'));
        await tester.tap(find.text('Copy diagnostics'));
        await tester.pumpAndSettle();
        expect(jsonDecode(clipboard!)['counts']['hosts'], 2);
        expect(clipboard, isNot(contains('alpha.invalid')));
        expect(tester.takeException(), null);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(SettingsDialog), findsNothing);
        m.dispose();
      }
    },
  );
}
