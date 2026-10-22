import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/main.dart';

class PerformanceBridge implements BridgeClient {
  final calls = <String>[];
  Map<String, dynamic> status = {
    'mounts': [],
    'activity': [],
    'cache': {'bytesUsed': 0, 'budgetBytes': 1024},
  };
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add(method);
    if (method == 'status') return status;
    if (method == 'list') {
      return {'path': params['path'], 'entries': [], 'fresh': true};
    }
    if (method == 'thumbnail') {
      return {'path': '/tmp/farshore-preview-${params['path']}.png'};
    }
    return {};
  }

  @override
  void dispose() {}
}

class CountedEntry extends RemoteEntry {
  CountedEntry(int index)
    : super(
        name: 'file_${((index * 7919) % 2000).toString().padLeft(4, '0')}.jpg',
        path: 'file-$index',
        isDirectory: false,
        size: index + 1,
        modified: '2026-10-22',
      );
  int nameReads = 0;
  @override
  String get name {
    nameReads++;
    return super.name;
  }
}

void main() {
  testWidgets(
    'benchmark: mouse selection latency with double-click opening enabled',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = BrowserModel(PerformanceBridge())..discovering = false;
      m.tab.host = const RemoteHost('h', 'host', 'host', 'user', 22);
      m.tab.entries = const [
        RemoteEntry(
          name: 'latency.txt',
          path: 'latency.txt',
          isDirectory: false,
          size: 1,
          modified: '',
        ),
      ];
      m.resumeWorkspace();
      await tester.pumpWidget(FarshoreApp(model: m, initialize: false));
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(
        location: tester.getCenter(find.text('latency.txt')),
      );
      await pointer.down(tester.getCenter(find.text('latency.txt')));
      await tester.pump(const Duration(milliseconds: 16));
      final downSelected = m.selected != null;
      expect(
        downSelected,
        true,
        reason: 'Selection must not wait for the double-click recognizer.',
      );
      await pointer.up();
      await tester.pump(const Duration(milliseconds: 16));
      final upSelected = m.selected != null;
      expect(upSelected, true);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      debugPrint(
        'SELECTION_LATENCY selectedAtPointerDown16ms=$downSelected selectedAtPointerUp16ms=$upSelected selectedAfterDoubleTapTimeout=${m.selected != null}',
      );
      await pointer.removePointer();
      expect(m.selected?.path, 'latency.txt');
    },
  );
  test(
    'benchmark: 200 selections with six view reads in a 2000-file directory',
    () {
      final m = BrowserModel(PerformanceBridge());
      addTearDown(m.dispose);
      final entries = List.generate(2000, CountedEntry.new);
      m.tab.entries = entries;
      final visible = m.visibleEntries;
      final warmNameReads = entries.fold<int>(0, (sum, e) => sum + e.nameReads);
      var checksum = 0;
      final timer = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        m.select(visible[(i * 17) % visible.length]);
        for (var read = 0; read < 3; read++) {
          checksum += m.visibleEntries.length;
          checksum += m.selected!.size;
        }
      }
      timer.stop();
      debugPrint(
        'BROWSER_BENCHMARK files=2000 selections=200 viewReads=1200 elapsedUs=${timer.elapsedMicroseconds} nameReads=${entries.fold<int>(0, (sum, e) => sum + e.nameReads)} checksum=$checksum',
      );
      expect(checksum, greaterThan(1200000));
      expect(
        entries.fold<int>(0, (sum, e) => sum + e.nameReads),
        warmNameReads,
        reason:
            'Selection and view reads must reuse the ordered directory rather than reread and resort metadata.',
      );
    },
  );

  test(
    '2000-entry directory invalidates correctly for filter, type, sort, hidden files, refresh, and tabs',
    () {
      final m = BrowserModel(PerformanceBridge());
      addTearDown(m.dispose);
      m.tab.entries = [
        ...List.generate(2000, CountedEntry.new),
        const RemoteEntry(
          name: '.private.jpg',
          path: '.private.jpg',
          isDirectory: false,
          size: 9000,
          modified: '',
        ),
        const RemoteEntry(
          name: 'folder',
          path: 'folder',
          isDirectory: true,
          size: 0,
          modified: '',
        ),
      ];
      expect(m.visibleEntries.first.isDirectory, true);
      m.query = 'file_00';
      expect(m.visibleEntries.length, 100);
      m.sort = EntrySort.largest;
      final sizes = m.visibleEntries.map((e) => e.size).toList();
      expect(sizes, orderedEquals([...sizes]..sort((a, b) => b.compareTo(a))));
      m.query = '';
      m.kindFilter = FileKind.image;
      expect(m.visibleEntries.length, 2000);
      m.showHidden = true;
      expect(m.visibleEntries.length, 2001);
      m.tab.entries = [
        ...m.tab.entries,
        const RemoteEntry(
          name: 'new.jpg',
          path: 'new.jpg',
          isDirectory: false,
          size: 10000,
          modified: '',
        ),
      ];
      expect(m.visibleEntries.first.name, 'new.jpg');
      m.addTab();
      expect(m.visibleEntries, isEmpty);
      m.activateTab(0);
      expect(m.visibleEntries.length, 2002);
      expect(m.visibleEntries.first.name, 'new.jpg');
    },
  );

  test(
    'unchanged status polls do not rebuild browser or reread directory metadata',
    () async {
      final bridge = PerformanceBridge();
      final m = BrowserModel(bridge);
      addTearDown(m.dispose);
      final entries = List.generate(2000, CountedEntry.new);
      m.tab.entries = entries;
      final visible = m.visibleEntries;
      final warmReads = entries.fold<int>(0, (sum, e) => sum + e.nameReads);
      var browserChanges = 0, statusChanges = 0, appearanceChanges = 0;
      m.addListener(() => browserChanges++);
      m.statusChanges.addListener(() => statusChanges++);
      m.appearance.addListener(() => appearanceChanges++);
      for (var i = 0; i < 40; i++) {
        m.select(visible[i * 23]);
        await m.refreshStatus();
        expect(m.selected, isNotNull);
      }
      expect(statusChanges, 40);
      expect(browserChanges, 0);
      expect(appearanceChanges, 0);
      expect(entries.fold<int>(0, (sum, e) => sum + e.nameReads), warmReads);
      bridge.status = {
        ...bridge.status,
        'cache': {'bytesUsed': 42, 'budgetBytes': 1024},
      };
      await m.refreshStatus();
      expect(statusChanges, 41);
      expect(browserChanges, 0);
    },
  );

  test(
    'thumbnail completion is coalesced and only its preview listeners update',
    () async {
      final bridge = PerformanceBridge();
      final scheduled = <VoidCallback>[];
      final m = BrowserModel(bridge, scheduleThumbnailUpdates: scheduled.add);
      addTearDown(m.dispose);
      m.tab.host = const RemoteHost('h', 'host', 'host', 'user', 22);
      m.resumeWorkspace();
      const first = RemoteEntry(
        name: 'a.jpg',
        path: 'a.jpg',
        isDirectory: false,
        size: 10,
        modified: '',
      );
      const second = RemoteEntry(
        name: 'b.jpg',
        path: 'b.jpg',
        isDirectory: false,
        size: 10,
        modified: '',
      );
      var firstUpdates = 0, secondUpdates = 0, browserUpdates = 0;
      m.thumbnailFor(first).addListener(() => firstUpdates++);
      m.thumbnailFor(second).addListener(() => secondUpdates++);
      m.addListener(() => browserUpdates++);
      m.requestThumbnail(first);
      m.requestThumbnail(second);
      m.requestThumbnail(first);
      await Future<void>.delayed(Duration.zero);
      expect(scheduled.length, 1);
      expect(firstUpdates, 0);
      expect(secondUpdates, 0);
      scheduled.single();
      expect(firstUpdates, 1);
      expect(secondUpdates, 1);
      expect(browserUpdates, 0);
      m.requestThumbnail(first);
      expect(bridge.calls.where((c) => c == 'thumbnail').length, 2);
    },
  );

  testWidgets(
    'selection and status preserve the application theme while an explicit theme change updates it',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = BrowserModel(PerformanceBridge())..discovering = false;
      m.tab.host = const RemoteHost('h', 'host', 'host', 'user', 22);
      m.tab.entries = List.generate(
        1200,
        (i) => RemoteEntry(
          name: 'file$i.txt',
          path: '$i',
          isDirectory: false,
          size: i,
          modified: '',
        ),
      );
      m.resumeWorkspace();
      await tester.pumpWidget(FarshoreApp(model: m, initialize: false));
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      for (var i = 0; i < 5; i++) {
        m.select(m.visibleEntries[i]);
        await m.refreshStatus();
        await tester.pump();
        expect(
          identical(tester.widget<MaterialApp>(find.byType(MaterialApp)), app),
          true,
        );
      }
      m.dark = true;
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!.brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final view in [BrowserView.grid, BrowserView.list]) {
    testWidgets(
      '${view.name}: immediate modifier selection toggles once and double-click still opens',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = PerformanceBridge();
        final m = BrowserModel(bridge)..discovering = false;
        m.view = view;
        m.tab.host = const RemoteHost('h', 'host', 'host', 'user', 22);
        m.tab.entries = const [
          RemoteEntry(
            name: 'alpha',
            path: 'alpha',
            isDirectory: true,
            size: 0,
            modified: '',
          ),
          RemoteEntry(
            name: 'beta',
            path: 'beta',
            isDirectory: true,
            size: 0,
            modified: '',
          ),
          RemoteEntry(
            name: 'gamma',
            path: 'gamma',
            isDirectory: true,
            size: 0,
            modified: '',
          ),
        ];
        m.resumeWorkspace();
        await tester.pumpWidget(FarshoreApp(model: m, initialize: false));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        Future<void> click(String name) async {
          await mouse.down(tester.getCenter(find.text(name).first));
          await tester.pump(const Duration(milliseconds: 16));
          await mouse.up();
          await tester.pump(
            kDoubleTapTimeout + const Duration(milliseconds: 20),
          );
        }

        await mouse.addPointer();
        await click('alpha');
        expect(m.tab.selection, {'alpha'});
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await click('alpha');
        expect(m.tab.selection, isEmpty);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await click('alpha');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await click('gamma');
        expect(m.tab.selection, {'alpha', 'beta', 'gamma'});
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        m.tab.selection.clear();
        m.selectionChanged();
        await tester.pump();
        var doubleClickSelectionChanges = 0;
        Set<String>? openedSelection;
        m.selectionChanges.addListener(() {
          doubleClickSelectionChanges++;
          openedSelection = Set.of(m.tab.selection);
        });
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        final target = tester.getCenter(find.text('beta').first);
        await mouse.down(target);
        await mouse.up();
        await tester.pump(const Duration(milliseconds: 70));
        await mouse.down(target);
        await mouse.up();
        await tester.pumpAndSettle();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        expect(doubleClickSelectionChanges, 1);
        expect(openedSelection, {'beta'});
        expect(m.tab.path, 'beta');
        expect(bridge.calls.where((c) => c == 'list').length, 1);
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
