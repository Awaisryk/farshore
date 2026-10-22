import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';

class FakeBridge implements BridgeClient {
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? handler;
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add(method);
    return handler?.call(method, params) ?? <String, dynamic>{};
  }

  @override
  void dispose() {}
}

const host = RemoteHost('h1', 'test-alias', 'example.invalid', 'user', 22);
RemoteEntry entry(String name, {bool folder = false}) => RemoteEntry(
  name: name,
  path: name,
  isDirectory: folder,
  size: 2048,
  modified: '2026-10-22',
);

void main() {
  test(
    'filter applies only loaded names, hides dotfiles, and keeps folders first',
    () {
      final m = BrowserModel(FakeBridge());
      addTearDown(m.dispose);
      m.tab.entries = [
        entry('z.png'),
        entry('.hidden.png'),
        entry('archive', folder: true),
        entry('a.mp4'),
      ];
      expect(m.visibleEntries.map((e) => e.name), [
        'archive',
        'a.mp4',
        'z.png',
      ]);
      m.kindFilter = FileKind.image;
      expect(m.visibleEntries.map((e) => e.name), ['z.png']);
      m.showHidden = true;
      expect(m.visibleEntries.length, 2);
      m.query = 'HIDDEN';
      expect(m.visibleEntries.single.name, '.hidden.png');
    },
  );

  test(
    'stale directory completion cannot overwrite a later location',
    () async {
      final bridge = FakeBridge();
      final first = Completer<Map<String, dynamic>>();
      bridge.handler = (method, params) async {
        if (params['path'] == 'first') return first.future;
        return {
          'path': 'second',
          'fresh': true,
          'entries': [
            {
              'name': 'new.txt',
              'path': 'second/new.txt',
              'isDirectory': false,
              'size': 3,
            },
          ],
        };
      };
      final m = BrowserModel(bridge);
      addTearDown(m.dispose);
      m.tab.host = host;
      final old = m.navigate('first');
      await m.navigate('second');
      first.complete({'path': 'first', 'entries': [], 'fresh': true});
      await old;
      expect(m.tab.path, 'second');
      expect(m.tab.entries.single.name, 'new.txt');
    },
  );

  test(
    'failed refresh preserves entries, selection, location and trust error',
    () async {
      final bridge = FakeBridge()
        ..handler = (method, params) async => throw const BridgeFailure(
          'host_identity_changed',
          'Trusted keys were preserved.',
        );
      final m = BrowserModel(bridge);
      addTearDown(m.dispose);
      m.tab.host = host;
      m.tab.path = 'media';
      m.tab.entries = [entry('clip.mp4')];
      m.tab.selection.add('clip.mp4');
      await m.navigate('media', record: false);
      expect(m.tab.path, 'media');
      expect(m.tab.entries.single.name, 'clip.mp4');
      expect(m.tab.selection, {'clip.mp4'});
      expect(m.tab.error?.code, 'host_identity_changed');
      expect(m.tab.fresh, false);
    },
  );

  test('selection supports keyboard range and additive selection', () {
    final m = BrowserModel(FakeBridge());
    addTearDown(m.dispose);
    m.tab.entries = [entry('a'), entry('b'), entry('c'), entry('d')];
    m.select(m.visibleEntries[1]);
    m.moveSelection(1, range: true);
    expect(m.tab.selection, {'b', 'c'});
    m.select(m.visibleEntries[3], additive: true);
    expect(m.tab.selection, {'b', 'c', 'd'});
  });

  test(
    'thumbnail workers are bounded and old-directory queue is deprioritized',
    () async {
      final bridge = FakeBridge();
      final pending = <Completer<Map<String, dynamic>>>[];
      bridge.handler = (method, params) {
        final result = Completer<Map<String, dynamic>>();
        pending.add(result);
        return result.future;
      };
      final m = BrowserModel(bridge);
      addTearDown(m.dispose);
      m.tab.host = host;
      m.resumeWorkspace();
      for (var i = 0; i < 10; i++) {
        m.requestThumbnail(entry('$i.png'));
      }
      expect(pending.length, 3);
      m.tab.generation++;
      for (final p in pending.toList()) {
        p.complete({'path': null});
      }
      await Future<void>.delayed(Duration.zero);
      expect(pending.length, 3);
    },
  );

  test(
    'refresh can request an unfinished visible thumbnail again without stale results winning',
    () async {
      final bridge = FakeBridge();
      final pending = <Completer<Map<String, dynamic>>>[];
      bridge.handler = (method, params) {
        final work = Completer<Map<String, dynamic>>();
        pending.add(work);
        return work.future;
      };
      final m = BrowserModel(bridge);
      addTearDown(m.dispose);
      m.tab.host = host;
      m.resumeWorkspace();
      final image = entry('preview.png');
      m.requestThumbnail(image);
      m.tab.generation++;
      m.requestThumbnail(image);
      expect(pending.length, 2);
      pending[0].complete({'path': '/tmp/stale.png'});
      await Future<void>.delayed(Duration.zero);
      expect(m.thumbnails.containsKey(m.thumbnailKey(image)), false);
      pending[1].complete({'path': '/tmp/current.png'});
      await Future<void>.delayed(Duration.zero);
      expect(m.thumbnailFor(image).value, '/tmp/current.png');
    },
  );

  test('closing browsing tab does not unmount external file access', () {
    final bridge = FakeBridge();
    final m = BrowserModel(bridge);
    addTearDown(m.dispose);
    m.addTab();
    m.closeTab(1);
    expect(bridge.calls, isNot(contains('unmount')));
  });
}
