import 'dart:async';
import 'package:farshore/bridge.dart';
import 'package:farshore/file_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class PreviewBridge implements BridgeClient {
  final calls = <({String method, Map<String, dynamic> params})>[];
  final events = <String>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? handler;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: Map.of(params)));
    events.add(method);
    if (handler != null) return handler!(method, params);
    return method == 'prepare_preview' ? textPreview() : {'released': true};
  }

  @override
  void dispose() {}
}

Map<String, dynamic> textPreview({String text = 'A remote text file.'}) => {
  'previewId': 'private-preview-id',
  'localPath': '/private/state/previews/private-file.txt',
  'mimeType': 'text/plain',
  'sourceBytes': 42,
  'kind': 'text',
  'text': text,
};

Map<String, dynamic> nativePreview() => {
  'previewId': 'private-preview-id',
  'localPath': '/private/state/previews/private-file.pdf',
  'mimeType': 'application/pdf',
  'sourceBytes': 2048,
  'kind': 'document',
};

class PreviewEngine implements FilePreviewEngine {
  PreviewEngine(this.events);
  final List<String> events;
  bool available = true, closeAck = true;
  Completer<Map<String, dynamic>>? openGate;
  Completer<bool>? closeGate;
  @override
  Future<Map<String, dynamic>> availability() async {
    events.add('availability');
    return {
      'available': available,
      'message': 'Quick Look could not be loaded.',
    };
  }

  @override
  Future<Map<String, dynamic>> open(int viewId) async {
    events.add('open:$viewId');
    return openGate?.future ?? {'status': 'attached'};
  }

  @override
  Future<Map<String, dynamic>> state(int viewId) async => {
    'status': 'attached',
  };
  @override
  Future<bool> close(int viewId) async {
    events.add('close:$viewId');
    final result = await (closeGate?.future ?? Future.value(closeAck));
    if (result) events.add('closed:$viewId');
    return result;
  }
}

FilePreviewController controller(PreviewBridge bridge, PreviewEngine engine) =>
    FilePreviewController(
      bridge: bridge,
      hostId: 'ssh-host',
      remotePath: '/data/report.pdf',
      engine: engine,
    );

Future<void> nextMicrotask() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'text previews remain inert and do not initialize a native reader',
    () async {
      final bridge = PreviewBridge()
        ..handler = (method, _) async => method == 'prepare_preview'
            ? {
                ...textPreview(text: '<script>run()</script>\n# Markdown'),
                'truncated': true,
              }
            : {'released': true};
      final engine = PreviewEngine(bridge.events);
      final preview = controller(bridge, engine);
      addTearDown(preview.dispose);
      await preview.load();
      expect(preview.phase, FilePreviewPhase.ready);
      expect(preview.text, '<script>run()</script>\n# Markdown');
      expect(preview.truncated, true);
      expect(bridge.events, ['prepare_preview']);
      expect(await preview.close(), true);
      expect(bridge.events, ['prepare_preview', 'release_preview']);
    },
  );

  test(
    'native setup and close must finish before the snapshot is released',
    () async {
      final bridge = PreviewBridge()
        ..handler = (method, _) async =>
            method == 'prepare_preview' ? nativePreview() : {'released': true};
      final engine = PreviewEngine(bridge.events)
        ..openGate = Completer<Map<String, dynamic>>()
        ..closeGate = Completer<bool>();
      final preview = controller(bridge, engine);
      addTearDown(preview.dispose);
      await preview.load();
      final attaching = preview.attachView(7, preview.requestId!);
      final closing = preview.close();
      await nextMicrotask();
      expect(bridge.events, ['prepare_preview', 'availability', 'open:7']);
      engine.openGate!.complete({'status': 'attached'});
      await attaching;
      await nextMicrotask();
      expect(bridge.events.last, 'close:7');
      expect(bridge.calls.where((c) => c.method == 'release_preview'), isEmpty);
      engine.closeGate!.complete(true);
      expect(await closing, true);
      expect(bridge.events.sublist(3), [
        'close:7',
        'closed:7',
        'release_preview',
      ]);
    },
  );

  test(
    'cancel pending reads by request ID and release a late response again',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final bridge = PreviewBridge()
        ..handler = (method, _) async => method == 'prepare_preview'
            ? pending.future
            : {'released': true, 'pending': true};
      final engine = PreviewEngine(bridge.events);
      final preview = controller(bridge, engine);
      addTearDown(preview.dispose);
      final loading = preview.load();
      final request = bridge.calls.single.params['requestId'];
      expect(await preview.close(), true);
      expect(bridge.calls.last.params, {'requestId': request});
      pending.complete(nativePreview());
      await loading;
      expect(bridge.calls.last.params, {
        'requestId': request,
        'previewId': 'private-preview-id',
      });
      expect(
        bridge.events.where((event) => event.startsWith('open:')),
        isEmpty,
      );
      expect(preview.phase, FilePreviewPhase.closed);
    },
  );

  test(
    'a late native factory never starts reading after cancellation',
    () async {
      final bridge = PreviewBridge()
        ..handler = (method, _) async =>
            method == 'prepare_preview' ? nativePreview() : {'released': true};
      final engine = PreviewEngine(bridge.events);
      final preview = controller(bridge, engine);
      addTearDown(preview.dispose);
      await preview.load();
      final request = preview.requestId!;
      expect(await preview.close(), true);
      await preview.attachView(12, request);
      expect(bridge.events, [
        'prepare_preview',
        'availability',
        'release_preview',
        'close:12',
        'closed:12',
      ]);
    },
  );

  test(
    'retry cleans the failed attempt and uses a fresh cancellation ID',
    () async {
      var attempts = 0;
      final bridge = PreviewBridge()
        ..handler = (method, _) async {
          if (method != 'prepare_preview') return {'released': true};
          if (attempts++ == 0) {
            throw const BridgeFailure(
              'preview_too_large',
              'This file exceeds the preview limit.',
            );
          }
          return textPreview();
        };
      final preview = controller(bridge, PreviewEngine(bridge.events));
      addTearDown(preview.dispose);
      await preview.load();
      expect(preview.phase, FilePreviewPhase.failed);
      expect(preview.message, contains('preview limit'));
      await preview.load();
      expect(preview.phase, FilePreviewPhase.ready);
      final prepares = bridge.calls
          .where((c) => c.method == 'prepare_preview')
          .toList();
      expect(
        prepares[0].params['requestId'],
        isNot(prepares[1].params['requestId']),
      );
      expect(bridge.events, [
        'prepare_preview',
        'release_preview',
        'prepare_preview',
      ]);
      expect(bridge.calls.any((c) => c.method == 'open'), false);
      await preview.close();
    },
  );

  test(
    'unconfirmed native closure retains the snapshot and rejects navigation',
    () async {
      final bridge = PreviewBridge()
        ..handler = (method, _) async =>
            method == 'prepare_preview' ? nativePreview() : {'released': true};
      final engine = PreviewEngine(bridge.events)..closeAck = false;
      final preview = controller(bridge, engine);
      addTearDown(preview.dispose);
      await preview.load();
      await preview.attachView(3, preview.requestId!);
      expect(await preview.close(), false);
      expect(preview.leaseRetained, true);
      expect(bridge.calls.where((c) => c.method == 'release_preview'), isEmpty);
    },
  );

  test('backend cleanup false is not a release acknowledgment', () async {
    final bridge = PreviewBridge()
      ..handler = (method, _) async =>
          method == 'prepare_preview' ? textPreview() : {'released': false};
    final preview = controller(bridge, PreviewEngine(bridge.events));
    addTearDown(preview.dispose);
    await preview.load();
    expect(await preview.close(), false);
    expect(preview.leaseRetained, true);
    expect(preview.message, contains('cleanup could not be confirmed'));
  });

  testWidgets(
    'literal selectable source has a truncation notice and Escape closes',
    (tester) async {
      final bridge = PreviewBridge()
        ..handler = (method, _) async => method == 'prepare_preview'
            ? {
                ...textPreview(text: '<script>alert("literal")</script>'),
                'truncated': true,
              }
            : {'released': true};
      final harness = PreviewHarness(bridge);
      await harness.show(tester);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('<script>alert("literal")</script>'), findsOneWidget);
      expect(find.textContaining('bounded text excerpt'), findsOneWidget);
      expect(find.textContaining('/private/state'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(FilePreviewDialog), findsNothing);
      expect(await harness.result, false);
      expect(bridge.calls.last.method, 'release_preview');
    },
  );

  testWidgets(
    'Open With waits for cleanup and returns an explicit external request',
    (tester) async {
      final release = Completer<Map<String, dynamic>>();
      final bridge = PreviewBridge()
        ..handler = (method, _) async =>
            method == 'prepare_preview' ? textPreview() : release.future;
      final harness = PreviewHarness(bridge);
      await harness.show(tester);
      await tester.tap(find.text('Open With…'));
      await tester.pump();
      expect(find.byType(FilePreviewDialog), findsOneWidget);
      release.complete({'released': true});
      await tester.pumpAndSettle();
      expect(find.byType(FilePreviewDialog), findsNothing);
      expect(await harness.result, true);
      expect(bridge.calls.map((c) => c.method), [
        'prepare_preview',
        'release_preview',
      ]);
    },
  );

  testWidgets(
    'navigation removes its own preview route while leaving a palette above intact',
    (tester) async {
      final harness = PreviewHarness(PreviewBridge());
      await harness.show(tester);
      unawaited(
        showDialog<void>(
          context: harness.navigator.currentContext!,
          builder: (_) =>
              const Dialog(child: Text('Path palette above preview')),
        ),
      );
      await tester.pumpAndSettle();
      expect(await harness.guard!(), true);
      await tester.pumpAndSettle();
      expect(find.text('Path palette above preview'), findsOneWidget);
      expect(find.byType(FilePreviewDialog, skipOffstage: false), findsNothing);
      expect(harness.guard, null);
    },
  );

  testWidgets(
    'failed navigation cleanup leaves an explicit close action usable',
    (tester) async {
      final bridge = PreviewBridge()
        ..handler = (method, _) async =>
            method == 'prepare_preview' ? textPreview() : {'released': false};
      final harness = PreviewHarness(bridge);
      await harness.show(tester);
      expect(await harness.guard!(), false);
      await tester.pumpAndSettle();
      expect(find.byType(FilePreviewDialog), findsOneWidget);
      expect(harness.retainedWarnings, 1);
      await tester.tap(find.byTooltip('Close preview'));
      await tester.pumpAndSettle();
      expect(find.byType(FilePreviewDialog), findsNothing);
      expect(harness.retainedWarnings, 1);
      expect(
        bridge.calls.where((c) => c.method == 'release_preview'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'native preview uses inherited themes and fits a compact desktop',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(920, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final brightness in Brightness.values) {
        final bridge = PreviewBridge()
          ..handler = (method, _) async => method == 'prepare_preview'
              ? nativePreview()
              : {'released': true};
        ValueChanged<int>? attach;
        final engine = PreviewEngine(bridge.events);
        final harness = PreviewHarness(
          bridge,
          engine: engine,
          brightness: brightness,
          viewBuilder: (_, path, onCreated) {
            expect(path, '/private/state/previews/private-file.pdf');
            attach = onCreated;
            return const Center(child: Text('Native provider boundary'));
          },
        );
        await harness.show(tester, settle: false);
        await tester.pump();
        attach!(8);
        await tester.pumpAndSettle();
        expect(find.text('Native provider boundary'), findsOneWidget);
        expect(find.textContaining('Quick Look controls'), findsOneWidget);
        expect(tester.takeException(), null);
        await tester.tap(find.byTooltip('Close preview'));
        await tester.pumpAndSettle();
        expect(
          bridge.events.indexOf('closed:8'),
          lessThan(bridge.events.indexOf('release_preview')),
        );
      }
    },
  );
}

class PreviewHarness {
  PreviewHarness(
    this.bridge, {
    this.engine,
    this.brightness = Brightness.light,
    this.viewBuilder,
  });
  final PreviewBridge bridge;
  final PreviewEngine? engine;
  final Brightness brightness;
  final FilePreviewViewBuilder? viewBuilder;
  final navigator = GlobalKey<NavigatorState>();
  Future<bool> Function()? guard;
  Future<bool?>? result;
  int retainedWarnings = 0;
  Future<void> show(WidgetTester tester, {bool settle = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                result = showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => FilePreviewDialog(
                    bridge: bridge,
                    hostId: 'ssh-host',
                    remotePath: '/data/report.pdf',
                    filename: 'Report with spaces.pdf',
                    engine: engine ?? PreviewEngine(bridge.events),
                    onNavigationGuard: (value) => guard = value,
                    onLeaseRetained: () => retainedWarnings++,
                    viewBuilder: viewBuilder,
                  ),
                );
              },
              child: const Text('Show preview'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show preview'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }
}
