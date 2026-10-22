import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/main.dart';

const server = RemoteHost('h', 'render', 'render.example.invalid', 'user', 22);
RemoteEntry clip(int index, {bool image = false}) => RemoteEntry(
  name: 'clip$index.${image ? 'png' : 'mp4'}',
  path: '/video/clip$index.${image ? 'png' : 'mp4'}',
  isDirectory: false,
  size: image ? 1024 : 4000000000,
  modified: '2026-10-22',
);

class ThumbnailBridge implements BridgeClient {
  final calls = <({String method, Map<String, dynamic> params})>[];
  final work = <Completer<Map<String, dynamic>>>[];
  Map<String, dynamic> snapshot = {};
  bool failStatus = false;
  int active = 0, maximum = 0;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: Map.of(params)));
    if (method == 'status') {
      if (failStatus) {
        throw const BridgeFailure('status_failed', 'Helper unavailable.');
      }
      return snapshot;
    }
    if (method == 'list') {
      return {'path': params['path'], 'entries': [], 'fresh': true};
    }
    if (method != 'thumbnail') return {};
    final result = Completer<Map<String, dynamic>>();
    work.add(result);
    active++;
    if (active > maximum) maximum = active;
    try {
      return await result.future;
    } finally {
      active--;
    }
  }

  void complete(
    int index, {
    String status = 'ready',
    String? reason,
    bool legacy = false,
  }) {
    work[index].complete({
      'path': status == 'ready' ? '/tmp/thumbnail-$index.png' : null,
      if (!legacy) 'status': status,
      'reason': ?reason,
      if (status == 'retryable' || status == 'deferred') 'retryAfterMs': 250,
    });
  }

  @override
  void dispose() {}
}

Future<void> flush() => Future<void>.delayed(Duration.zero);
BrowserModel modelFor(ThumbnailBridge bridge) => BrowserModel(bridge)
  ..tab.host = server
  ..resumeWorkspace();

void main() {
  test(
    'legacy null and transient failures never become permanent negative cache entries',
    () async {
      final bridge = ThumbnailBridge();
      final model = modelFor(bridge);
      addTearDown(model.dispose);
      final entry = clip(1);
      model.requestThumbnail(entry);
      bridge.complete(0, status: 'retryable', legacy: true);
      await flush();
      expect(model.thumbnails.containsKey(model.thumbnailKey(entry)), isFalse);
      expect(
        model.thumbnailStateFor(entry).value.status,
        ThumbnailStatus.retryable,
      );
      model.retryThumbnail(entry);
      expect(bridge.work.length, 2);
      bridge.complete(1);
      await flush();
      expect(model.thumbnailFor(entry).value, '/tmp/thumbnail-1.png');
    },
  );

  test(
    '300 listed videos can pre-generate without scrolling, with one video worker and no browser rebuilds or extra listing',
    () async {
      final bridge = ThumbnailBridge();
      final model = modelFor(bridge);
      addTearDown(model.dispose);
      model.tab.entries = List.generate(300, (i) => clip(i));
      model.kindFilter =
          FileKind.image; // Batch scope is the folder, not its current filter.
      var broadChanges = 0;
      model.addListener(() => broadChanges++);
      model.generateVideoThumbnails();
      expect(bridge.work.length, 1);
      for (var i = 0; i < 300; i++) {
        expect(bridge.work.length, i + 1);
        bridge.complete(i);
        await flush();
      }
      final progress = model.thumbnailBatch.value!;
      expect(
        (progress.total, progress.ready, progress.failed, progress.running),
        (300, 300, 0, false),
      );
      expect(bridge.maximum, 1);
      expect(broadChanges, 0);
      expect(bridge.calls.every((c) => c.method == 'thumbnail'), isTrue);
      expect(bridge.calls.last.params['path'], '/video/clip299.mp4');
    },
  );

  test(
    'newly visible previews take priority over a folder batch, and Cancel stops remaining work',
    () async {
      final bridge = ThumbnailBridge();
      final model = modelFor(bridge);
      addTearDown(model.dispose);
      model.tab.entries = List.generate(50, (i) => clip(i));
      model.generateVideoThumbnails();
      final unobserve = model.observeThumbnail(model.tab.entries.last);
      addTearDown(unobserve);
      bridge.complete(0);
      await flush();
      expect(bridge.calls.last.params['path'], '/video/clip49.mp4');
      model.cancelThumbnailBatch();
      bridge.complete(1);
      await flush();
      expect(bridge.work.length, 2);
      final progress = model.thumbnailBatch.value!;
      expect(
        (
          progress.cancelled,
          progress.running,
          progress.ready,
          progress.inFlight,
        ),
        (true, false, 2, 0),
      );
      model.generateVideoThumbnails(retryMissing: true);
      expect(bridge.calls.last.params['path'], '/video/clip1.mp4');
      model.cancelThumbnailBatch();
      bridge.complete(2);
      await flush();
    },
  );

  test(
    'navigation cancels queued generation and rejects stale results',
    () async {
      final bridge = ThumbnailBridge();
      final model = modelFor(bridge);
      addTearDown(model.dispose);
      final old = clip(0);
      model.tab.entries = List.generate(100, (i) => clip(i));
      model.generateVideoThumbnails();
      await model.navigate('/different');
      bridge.complete(0);
      await flush();
      expect(bridge.work.length, 1);
      expect(model.thumbnails.containsKey(model.thumbnailKey(old)), isFalse);
      expect(model.thumbnailBatch.value!.cancelled, isTrue);
    },
  );

  testWidgets(
    'visible transient failures retry three times with backoff, then require explicit retry',
    (tester) async {
      final bridge = ThumbnailBridge();
      final model = BrowserModel(
        bridge,
        thumbnailRetryBase: const Duration(milliseconds: 250),
        thumbnailNow: tester.binding.clock.now,
      )..tab.host = server;
      model.resumeWorkspace();
      addTearDown(model.dispose);
      final entry = clip(1);
      final unobserve = model.observeThumbnail(entry);
      addTearDown(unobserve);
      for (var i = 0; i < 3; i++) {
        bridge.complete(i, status: 'retryable', reason: 'thumbnail_timeout');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(bridge.work.length, 3);
      expect(model.thumbnailStateFor(entry).value.attempts, 3);
      await tester.pump(const Duration(minutes: 5));
      expect(bridge.work.length, 3);
      model.retryThumbnail(entry);
      bridge.complete(3);
      await tester.pump();
      expect(
        model.thumbnailStateFor(entry).value.status,
        ThumbnailStatus.ready,
      );
    },
  );

  testWidgets(
    'playback deferrals do not consume attempts and recover on idle even after their automatic limit',
    (tester) async {
      final bridge = ThumbnailBridge();
      final model = BrowserModel(bridge, thumbnailNow: tester.binding.clock.now)
        ..tab.host = server
        ..resumeWorkspace();
      addTearDown(model.dispose);
      final entry = clip(1);
      final unobserve = model.observeThumbnail(entry);
      addTearDown(unobserve);
      for (var i = 0; i < 3; i++) {
        bridge.complete(i, status: 'deferred', reason: 'playback_active');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(bridge.work.length, 3);
      expect(model.thumbnailStateFor(entry).value.attempts, 0);
      bridge.snapshot = {'activePreviews': 1};
      await model.refreshStatus();
      await tester.pump();
      bridge.snapshot = {'activePreviews': 0};
      await model.refreshStatus();
      await tester.pump();
      expect(bridge.work.length, 4);
      bridge.complete(3);
      await tester.pump();
      expect(
        model.thumbnailStateFor(entry).value.status,
        ThumbnailStatus.ready,
      );
    },
  );

  testWidgets(
    'a short player session can resume deferred previews even when no busy status poll was observed',
    (tester) async {
      final bridge = ThumbnailBridge()..snapshot = {'activePreviews': 0};
      final model = BrowserModel(bridge, thumbnailNow: tester.binding.clock.now)
        ..tab.host = server
        ..resumeWorkspace();
      addTearDown(model.dispose);
      final unobserve = model.observeThumbnail(clip(2));
      addTearDown(unobserve);
      bridge.complete(0, status: 'deferred', reason: 'playback_active');
      await tester.pump();
      await model.refreshStatus();
      model.resumeDeferredThumbnailsAfterPlayback();
      expect(bridge.work.length, 2);
      bridge.complete(1);
      await tester.pump();
    },
  );

  testWidgets(
    'offscreen previews stop automatic retries and unsupported files are terminal until explicit retry',
    (tester) async {
      final bridge = ThumbnailBridge();
      final model = BrowserModel(bridge, thumbnailNow: tester.binding.clock.now)
        ..tab.host = server
        ..resumeWorkspace();
      addTearDown(model.dispose);
      final entry = clip(1);
      final unobserve = model.observeThumbnail(entry);
      bridge.complete(0, status: 'retryable');
      await tester.pump();
      unobserve();
      await tester.pump(const Duration(minutes: 1));
      expect(bridge.work.length, 1);
      model.requestThumbnail(entry, retry: true);
      bridge.complete(1, status: 'unsupported', reason: 'unsupported_video');
      await tester.pump();
      model.requestThumbnail(entry);
      expect(bridge.work.length, 2);
      expect(
        model.thumbnailStateFor(entry).value.status,
        ThumbnailStatus.unsupported,
      );
    },
  );

  testWidgets(
    'a decode failure remains retryable after a new ready result at the same deterministic cache path',
    (tester) async {
      tester.view.physicalSize = const Size(920, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = ThumbnailBridge();
      final model = modelFor(bridge)..discovering = false;
      final entry = clip(1);
      model.tab.entries = [entry];
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.pumpAndSettle();
      ThumbnailSnapshot? previousReady;
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) model.retryThumbnail(entry);
        expect(bridge.work.length, attempt + 1);
        bridge.work[attempt].complete({
          'status': 'ready',
          'path': '/tmp/deterministic-preview.png',
        });
        await tester.pump();
        await tester.pump();
        await tester.pump();
        final ready = model.thumbnailStateFor(entry).value;
        expect(ready.status, ThumbnailStatus.ready);
        if (previousReady != null) {
          model.thumbnailFileUnavailable(entry, expected: previousReady);
          expect(
            model.thumbnails[model.thumbnailKey(entry)],
            '/tmp/deterministic-preview.png',
            reason:
                'An old decode callback must not overwrite the new ready result.',
          );
        }
        final imageFinder = find
            .byWidgetPredicate(
              (widget) => widget is Image && widget.errorBuilder != null,
            )
            .first;
        final image = tester.widget<Image>(imageFinder);
        // Simulate the framework's decode-error boundary. The filesystem/codec is
        // Flutter-owned; this regression covers our real widget callback and state.
        image.errorBuilder!(
          tester.element(imageFinder),
          StateError('Invalid PNG'),
          null,
        );
        image.errorBuilder!(
          tester.element(imageFinder),
          StateError('Invalid PNG'),
          null,
        );
        tester.binding.scheduleFrame();
        await tester.pump();
        await tester.pump();
        expect(
          model.thumbnailStateFor(entry).value.status,
          ThumbnailStatus.retryable,
          reason: 'Attempt $attempt should expose another manual retry.',
        );
        expect(
          find.byTooltip('Retry preview for ${entry.name}'),
          findsOneWidget,
        );
        previousReady = ready;
      }
      expect(
        bridge.work.length,
        2,
        reason: 'Decode errors cannot auto-loop requests.',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a playback-close recovery request survives failed status verification and is consumed only once',
    (tester) async {
      final bridge = ThumbnailBridge()..snapshot = {'activePreviews': 0};
      final model = BrowserModel(bridge, thumbnailNow: tester.binding.clock.now)
        ..tab.host = server
        ..resumeWorkspace();
      addTearDown(model.dispose);
      await model.refreshStatus();
      final unobserve = model.observeThumbnail(clip(4));
      addTearDown(unobserve);
      for (var i = 0; i < 3; i++) {
        bridge.complete(i, status: 'deferred', reason: 'playback_active');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(bridge.work.length, 3);
      bridge.failStatus = true;
      await model.refreshStatus();
      model.resumeDeferredThumbnailsAfterPlayback();
      expect(bridge.work.length, 3);
      bridge.failStatus = false;
      await model.refreshStatus();
      expect(bridge.work.length, 4);
      for (var i = 3; i < 6; i++) {
        bridge.complete(i, status: 'deferred', reason: 'playback_active');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(bridge.work.length, 6);
      await model.refreshStatus();
      await tester.pump(const Duration(minutes: 1));
      expect(
        bridge.work.length,
        6,
        reason:
            'Repeated idle polls cannot renew an already consumed close signal.',
      );
    },
  );

  testWidgets(
    'Home prevents retrying an old visible preview even before its observer is disposed',
    (tester) async {
      final bridge = ThumbnailBridge();
      final model = BrowserModel(bridge, thumbnailNow: tester.binding.clock.now)
        ..tab.host = server
        ..resumeWorkspace();
      addTearDown(model.dispose);
      final entry = clip(7);
      final unobserve = model.observeThumbnail(entry);
      addTearDown(unobserve);
      expect(bridge.work.length, 1);
      model.showHome();
      bridge.complete(0, status: 'retryable', reason: 'thumbnail_timeout');
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      model.requestThumbnail(entry, retry: true);
      await tester.pump();
      expect(model.isHome, isTrue);
      expect(bridge.work.length, 1);
      expect(bridge.calls.every((call) => call.method == 'thumbnail'), isTrue);
    },
  );

  testWidgets(
    'current-folder generation is explicit, filter-independent and cancelable in a narrow desktop window',
    (tester) async {
      tester.view.physicalSize = const Size(920, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = ThumbnailBridge();
      final model = modelFor(bridge)..discovering = false;
      model.tab.entries = List.generate(104, (i) => clip(i));
      model.resumeWorkspace();
      model.kindFilter = FileKind.document;
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.pumpAndSettle();
      expect(bridge.work, isEmpty);
      await tester.tap(find.byKey(const ValueKey('generate-video-thumbnails')));
      await tester.pump();
      expect(bridge.work.length, 1);
      expect(find.text('0 / 104 video thumbnails ready'), findsOneWidget);
      await tester.tap(find.text('Cancel generation'));
      bridge.complete(0, status: 'unsupported', reason: 'unsupported_video');
      await tester.pump();
      expect(find.text('Retry missing'), findsOneWidget);
      await tester.tap(find.text('Retry missing'));
      await tester.pump();
      expect(bridge.work.length, 2);
      expect(tester.takeException(), isNull);
      model.cancelThumbnailBatch();
      bridge.complete(1, status: 'unsupported');
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
