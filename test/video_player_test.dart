import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/video_player.dart';

class MediaBridge implements BridgeClient {
  final calls = <({String method, Map<String, dynamic> params})>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? handler;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: params));
    return handler?.call(method, params) ??
        (method == 'prepare_media'
            ? {
                'streamUrl':
                    'http://127.0.0.1:49199/media/abcdefghijklmnopqrstuvwxyz0123456789',
                'leaseId': 'lease-1',
              }
            : {});
  }

  @override
  void dispose() {}
}

class TestMediaEngine implements MediaEngine {
  bool available = true;
  bool failStop = false;
  Completer<void>? stopGate;
  Completer<void>? resumeGate;
  bool observeResume = true;
  bool failResume = false;
  int inputGeneration = 1;
  Map<String, dynamic> snapshot = {
    'playing': true,
    'state': 3,
    'position': 0.25,
    'timeMs': 2500,
    'lengthMs': 10000,
  };
  final controls =
      <({int viewId, String action, double? position, int? volume})>[];
  @override
  Future<Map<String, dynamic>> availability() async => {
    'available': available,
    'engine': 'LibVLC',
    'version': 'test',
    if (!available) 'message': 'LibVLC could not be loaded.',
  };
  @override
  Future<Map<String, dynamic>> state(int viewId) async => snapshot;
  @override
  Future<void> control(
    int viewId,
    String action, {
    double? position,
    int? volume,
  }) async {
    if (action == 'stop' && failStop) {
      throw PlatformException(code: 'stop-failed');
    }
    if (action == 'stop' && stopGate != null) await stopGate!.future;
    controls.add((
      viewId: viewId,
      action: action,
      position: position,
      volume: volume,
    ));
    if (action == 'resume' && failResume) {
      throw PlatformException(
        code: 'resume-failed',
        message: 'The input could not resume.',
      );
    }
    if (action == 'resume' && resumeGate != null) await resumeGate!.future;
    if (snapshot['state'] == 7) return;
    if (action == 'pause') {
      snapshot = {...snapshot, 'playing': false, 'state': 4};
    } else if (action == 'replay') {
      inputGeneration++;
      snapshot = {
        ...snapshot,
        'playing': true,
        'state': 3,
        'timeMs': 0,
        'position': 0.0,
      };
    } else if (action == 'play' || (action == 'resume' && observeResume)) {
      snapshot = {...snapshot, 'playing': true, 'state': 3};
    } else if (action == 'seek' && snapshot['state'] != 6) {
      snapshot = {
        ...snapshot,
        'position': position,
        'timeMs': ((snapshot['lengthMs'] as num) * position!).round(),
      };
    }
  }
}

void main() {
  MediaPlaybackController controller(
    MediaBridge bridge,
    TestMediaEngine engine,
  ) => MediaPlaybackController(
    bridge: bridge,
    hostId: 'logical-host',
    remotePath: 'remote/video.mp4',
    engine: engine,
    pollInterval: const Duration(hours: 1),
  );

  test(
    'common media and documents stay internal while unknown files use external opening',
    () {
      RemoteEntry entry(String name, {bool folder = false}) => RemoteEntry(
        name: name,
        path: name,
        isDirectory: folder,
        size: 10,
        modified: '',
      );
      expect(entry('clip.MP4').openIntent, EntryOpenIntent.playInternally);
      expect(entry('movie', folder: true).openIntent, EntryOpenIntent.navigate);
      expect(entry('photo.png').openIntent, EntryOpenIntent.previewInternally);
      expect(entry('notes.txt').openIntent, EntryOpenIntent.previewInternally);
      expect(entry('audio.FLAC').openIntent, EntryOpenIntent.playInternally);
      expect(entry('archive.zip').openIntent, EntryOpenIntent.openExternally);
    },
  );

  test(
    'missing LibVLC never mounts or launches another application automatically',
    () async {
      final bridge = MediaBridge();
      final engine = TestMediaEngine()..available = false;
      final player = controller(bridge, engine);
      addTearDown(player.dispose);
      await player.initialize();
      expect(player.phase, PlaybackPhase.failed);
      expect(player.message, contains('LibVLC'));
      expect(bridge.calls, isEmpty);
      expect(engine.controls, isEmpty);
    },
  );

  test(
    'mount error preserves its explanation and does not launch external app',
    () async {
      final bridge = MediaBridge()
        ..handler = (method, params) async => throw const BridgeFailure(
          'mount_access_denied',
          'Allow access to network volumes.',
        );
      final player = controller(bridge, TestMediaEngine());
      addTearDown(player.dispose);
      await player.initialize();
      expect(player.phase, PlaybackPhase.failed);
      expect(player.message, 'Allow access to network volumes.');
      expect(bridge.calls.map((c) => c.method), ['prepare_media']);
    },
  );

  test('only protected loopback URLs are accepted as media capabilities', () {
    const token = 'abcdefghijklmnopqrstuvwxyz0123456789';
    expect(isPrivateMediaUrl('http://127.0.0.1:49201/media/$token'), true);
    for (final value in [
      'https://127.0.0.1:49201/media/$token',
      'http://example.com:49201/media/$token',
      'http://127.0.0.1.evil.test:49201/media/$token',
      'http://localhost:49201/media/$token',
      'http://user@127.0.0.1:49201/media/$token',
      'http://127.0.0.1:49201/media/short',
      'http://127.0.0.1:49201/media/$token?path=/etc/passwd',
      'http://127.0.0.1:49201/media/$token#fragment',
      'http://127.0.0.1/media/$token',
      'http://127.0.0.1:80/media/$token',
      'http://127.0.0.1:49201/media/${'a' * 129}',
      'http://127.0.0.1:49201/%6dedia/$token',
      'file:///mounted/video.mp4',
    ]) {
      expect(isPrivateMediaUrl(value), false, reason: value);
    }
  });

  test(
    'invalid remote URL is rejected without downgrading to a mounted path',
    () async {
      final bridge = MediaBridge()
        ..handler = (method, params) async => {
          'streamUrl':
              'http://remote.example:49201/media/abcdefghijklmnopqrstuvwxyz0123456789',
          'mountPath': '/mounted/video.mp4',
          'leaseId': 'invalid-url-lease',
        };
      final engine = TestMediaEngine();
      final player = controller(bridge, engine);
      addTearDown(player.dispose);
      await player.initialize();
      expect(player.phase, PlaybackPhase.failed);
      expect(player.message, contains('protected local playback source'));
      expect(engine.controls, isEmpty);
      await player.close();
      expect(bridge.calls.last.params, {'leaseId': 'invalid-url-lease'});
    },
  );

  test(
    'stream URL is preferred while legacy mounted source remains supported',
    () async {
      final bridge = MediaBridge()
        ..handler = (method, params) async => {
          'streamUrl':
              'http://127.0.0.1:49201/media/abcdefghijklmnopqrstuvwxyz0123456789',
          'mountPath': '/mounted/video.mp4',
          'leaseId': 'stream-lease',
        };
      final player = controller(bridge, TestMediaEngine());
      addTearDown(player.dispose);
      await player.initialize();
      expect(player.nativeSource.keys, ['url']);
      await player.close();
      final legacyBridge = MediaBridge()
        ..handler = (method, params) async => {
          'mountPath': '/mounted/video.mp4',
          'leaseId': 'legacy-lease',
        };
      final legacy = controller(legacyBridge, TestMediaEngine());
      addTearDown(legacy.dispose);
      await legacy.initialize();
      expect(legacy.nativeSource, {'path': '/mounted/video.mp4'});
      await legacy.close();
      expect(legacyBridge.calls.last.params, {'leaseId': 'legacy-lease'});
    },
  );

  test(
    'SSH streamed playback controls native view and closes its lease after stopping',
    () async {
      final bridge = MediaBridge();
      final engine = TestMediaEngine();
      final player = controller(bridge, engine);
      addTearDown(player.dispose);
      await player.initialize();
      expect(player.phase, PlaybackPhase.ready);
      expect(player.nativeSource.keys, ['url']);
      await player.attachView(19);
      expect(player.playing, true);
      expect(player.position, 0.25);
      await player.seek(0.8);
      expect(engine.controls.last.action, 'seek');
      expect(engine.controls.last.position, 0.8);
      await player.togglePlayback();
      expect(engine.controls.last.action, 'pause');
      await player.close();
      expect(engine.controls.last.action, 'stop');
      expect(bridge.calls.last.method, 'release_media');
      expect(bridge.calls.last.params, {'leaseId': 'lease-1'});
      final count = engine.controls.length;
      await player.poll();
      await player.close();
      expect(engine.controls.length, count);
      expect(bridge.calls.where((c) => c.method == 'release_media').length, 1);
    },
  );

  test(
    'paused Resume preserves the input and clock, waiting for acknowledgment and observed playback',
    () async {
      final bridge = MediaBridge();
      final engine = TestMediaEngine();
      final player = controller(bridge, engine);
      addTearDown(player.dispose);
      await player.initialize();
      await player.attachView(30);
      await player.togglePlayback();
      expect(player.playbackLabel, 'Resume');
      expect(player.timeMs, 2500);
      engine.resumeGate = Completer<void>();
      engine.observeResume = false;
      final resuming = player.togglePlayback();
      expect(player.commandPending, true);
      expect(player.playbackLabel, 'Resuming…');
      await player.togglePlayback();
      expect(engine.controls.where((c) => c.action == 'resume').length, 1);
      engine.resumeGate!.complete();
      await Future<void>.delayed(Duration.zero);
      // Native acknowledgment alone does not prove the paused clock restarted.
      expect(player.commandPending, true);
      expect(player.playing, false);
      engine.snapshot = {...engine.snapshot, 'playing': true, 'state': 3};
      await player.poll();
      await resuming;
      expect(player.commandPending, false);
      expect(player.playbackLabel, 'Pause');
      expect(player.timeMs, 2500);
      expect(engine.inputGeneration, 1);
      engine.snapshot = {...engine.snapshot, 'timeMs': 3100, 'position': 0.31};
      await player.poll();
      expect(player.timeMs, greaterThan(2500));
      await player.close();
    },
  );

  test(
    'EOF presents a complete timeline and Replay starts a new input instead of seeking a dead one',
    () async {
      final bridge = MediaBridge();
      final engine = TestMediaEngine();
      final player = controller(bridge, engine);
      addTearDown(player.dispose);
      await player.initialize();
      await player.attachView(31);
      engine.snapshot = {
        ...engine.snapshot,
        'playing': false,
        'state': 6,
        'timeMs': 9732,
        'position': 0.9732,
      };
      await player.poll();
      expect(player.playbackLabel, 'Replay');
      expect(player.timeMs, 10000);
      expect(player.position, 1);
      await player.togglePlayback();
      expect(engine.inputGeneration, 2);
      expect(player.playing, true);
      expect(player.timeMs, 0);
      expect(player.position, 0);
      expect(player.controlError, isNull);
      engine.snapshot = {...engine.snapshot, 'timeMs': 900, 'position': 0.09};
      await player.poll();
      expect(player.timeMs, greaterThan(0));
      expect(engine.controls.where((c) => c.action == 'seek'), isEmpty);
      await player.close();
    },
  );

  test(
    'buffering is an active playback state rather than a paused Resume action',
    () async {
      final bridge = MediaBridge();
      final engine = TestMediaEngine();
      final player = controller(bridge, engine);
      addTearDown(player.dispose);
      await player.initialize();
      await player.attachView(32);
      engine.snapshot = {...engine.snapshot, 'playing': false, 'state': 2};
      await player.poll();
      expect(player.playbackLabel, 'Pause');
      await player.togglePlayback();
      expect(player.stateCode, 4);
      expect(player.playbackLabel, 'Resume');
      await player.close();
    },
  );

  test(
    'acknowledged Resume that stays paused reports a visible timeout instead of silent success',
    () async {
      final bridge = MediaBridge();
      final engine = TestMediaEngine()..observeResume = false;
      final player = MediaPlaybackController(
        bridge: bridge,
        hostId: 'h',
        remotePath: 'clip.mp4',
        engine: engine,
        pollInterval: const Duration(hours: 1),
        commandTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(player.dispose);
      await player.initialize();
      await player.attachView(33);
      await player.togglePlayback();
      await player.togglePlayback();
      expect(player.commandPending, false);
      expect(player.phase, PlaybackPhase.ready);
      expect(player.playbackLabel, 'Resume');
      expect(player.playing, false);
      expect(player.controlError, contains('Resume took too long to confirm'));
      expect(bridge.calls.where((c) => c.method == 'open'), isEmpty);
      await player.close();
    },
  );

  test(
    'native Resume failure preserves its explanation and allows an explicit retry',
    () async {
      final bridge = MediaBridge();
      final engine = TestMediaEngine();
      final player = controller(bridge, engine);
      addTearDown(player.dispose);
      await player.initialize();
      await player.attachView(34);
      await player.togglePlayback();
      engine.failResume = true;
      await player.togglePlayback();
      expect(player.controlError, contains('The input could not resume.'));
      expect(player.playbackLabel, 'Resume');
      expect(player.commandPending, false);
      engine.failResume = false;
      await player.togglePlayback();
      expect(player.playing, true);
      expect(player.controlError, isNull);
      await player.close();
    },
  );

  test(
    'ambiguous native stop failure retains lease instead of risking an active read',
    () async {
      final bridge = MediaBridge();
      final engine = TestMediaEngine();
      final player = controller(bridge, engine);
      addTearDown(player.dispose);
      await player.initialize();
      await player.attachView(12);
      engine.failStop = true;
      await player.close();
      expect(player.leaseRetained, true);
      expect(bridge.calls.where((c) => c.method == 'release_media'), isEmpty);
    },
  );

  test('lease release waits for native stop acknowledgment', () async {
    final bridge = MediaBridge();
    final engine = TestMediaEngine();
    final player = controller(bridge, engine);
    addTearDown(player.dispose);
    await player.initialize();
    await player.attachView(12);
    engine.stopGate = Completer<void>();
    final closing = player.close();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls.where((c) => c.method == 'release_media'), isEmpty);
    engine.stopGate!.complete();
    await closing;
    expect(bridge.calls.last.method, 'release_media');
  });

  test(
    'closing while mount preparation is pending releases the eventual lease',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final bridge = MediaBridge()
        ..handler = (method, params) async =>
            method == 'prepare_media' ? pending.future : {};
      final player = controller(bridge, TestMediaEngine());
      addTearDown(player.dispose);
      final preparing = player.initialize();
      await Future<void>.delayed(Duration.zero);
      await player.close();
      pending.complete({
        'streamUrl':
            'http://127.0.0.1:49199/media/abcdefghijklmnopqrstuvwxyz0123456789',
        'leaseId': 'late-lease',
      });
      await preparing;
      expect(player.phase, PlaybackPhase.closed);
      expect(bridge.calls.last.params, {'leaseId': 'late-lease'});
    },
  );

  test(
    'decoder error stops native playback without external fallback launch',
    () async {
      final bridge = MediaBridge();
      final engine = TestMediaEngine()
        ..snapshot = {
          'playing': false,
          'state': 7,
          'error': 'The codec could not be decoded.',
        };
      final player = controller(bridge, engine);
      addTearDown(player.dispose);
      await player.initialize();
      await player.attachView(3);
      expect(player.phase, PlaybackPhase.failed);
      expect(player.message, contains('codec'));
      expect(engine.controls.last.action, 'stop');
      expect(bridge.calls.map((c) => c.method), isNot(contains('open')));
      // The failed platform view can disappear after its stop acknowledgment.
      // Closing should reuse that acknowledgment rather than retain the lease.
      await Future<void>.delayed(Duration.zero);
      engine.failStop = true;
      await player.close();
      expect(player.leaseRetained, false);
      expect(bridge.calls.last.method, 'release_media');
    },
  );

  testWidgets(
    'audio uses the internal decoder and stops before releasing its stream',
    (tester) async {
      tester.view.physicalSize = const Size(920, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform_views,
            (_) async => null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform_views, null),
      );
      final engine = TestMediaEngine();
      final bridge = MediaBridge();
      bridge.handler = (method, params) async {
        if (method == 'prepare_media') {
          return {
            'streamUrl':
                'http://127.0.0.1:49199/media/abcdefghijklmnopqrstuvwxyz0123456789',
            'leaseId': 'audio-lease',
          };
        }
        if (method == 'release_media') {
          expect(engine.controls.last.action, 'stop');
        }
        return {};
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => FarshoreVideoPlayer(
                    bridge: bridge,
                    hostId: 'host',
                    remotePath: 'track.flac',
                    filename: 'track.flac',
                    dark: false,
                    audioOnly: true,
                    engine: engine,
                  ),
                ),
                child: const Text('Listen'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Listen'));
      await tester.pumpAndSettle();
      expect(find.text('Audio preview'), findsOneWidget);
      final surface = tester.widget<AppKitView>(find.byType(AppKitView));
      expect((surface.creationParams! as Map)['audioOnly'], true);
      expect(tester.getSize(find.byType(AppKitView)), const Size(1, 1));
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();
      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.byTooltip('Close player'));
      await tester.pumpAndSettle();
      expect(find.text('Audio preview'), findsNothing);
      expect(bridge.calls.last.method, 'release_media');
      expect(bridge.calls.where((call) => call.method == 'open'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'video chrome follows theme changes without restarting playback',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform_views,
            (_) async => null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform_views, null),
      );
      final bridge = MediaBridge();
      final engine = TestMediaEngine()..failResume = true;
      Future<void> show(ColorScheme scheme) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(colorScheme: scheme),
            home: Scaffold(
              body: FarshoreVideoPlayer(
                bridge: bridge,
                hostId: 'host',
                remotePath: 'clip.mp4',
                filename: 'clip.mp4',
                // Kept for callers predating the selectable theme palette.
                dark: false,
                engine: engine,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      final first = ColorScheme.fromSeed(
        seedColor: const Color(0xff715b9d),
        brightness: Brightness.dark,
      );
      await show(first);
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      final second = first.copyWith(
        surfaceContainerLow: const Color(0xff29212e),
        onSurfaceVariant: const Color(0xffd9bfdc),
        errorContainer: const Color(0xff3d2633),
        onErrorContainer: const Color(0xfff7d9ec),
      );
      await show(second);
      expect(
        tester.widget<Dialog>(find.byType(Dialog)).backgroundColor,
        second.surfaceContainerLow,
      );
      expect(
        tester.widget<Text>(find.text('VideoLAN LibVLC · test')).style!.color,
        second.onSurfaceVariant,
      );
      final warning = find.textContaining('The input could not resume.');
      expect(
        tester.widget<Text>(warning).style!.color,
        second.onErrorContainer,
      );
      expect(
        tester
            .widget<Container>(
              find
                  .ancestor(of: warning, matching: find.byType(Container))
                  .first,
            )
            .color,
        second.errorContainer,
      );
      expect(
        tester
            .widget<ColoredBox>(
              find
                  .ancestor(
                    of: find.byType(AppKitView),
                    matching: find.byType(ColoredBox),
                  )
                  .first,
            )
            .color,
        Colors.black,
      );
      expect(
        bridge.calls.where((call) => call.method == 'prepare_media'),
        hasLength(1),
      );
      expect(
        engine.controls.where((call) => call.action == 'play'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unavailable player keeps Open With available in a narrow dialog',
    (tester) async {
      tester.view.physicalSize = const Size(920, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = MediaBridge();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FarshoreVideoPlayer(
              bridge: bridge,
              hostId: 'host',
              remotePath: 'clip.mp4',
              filename: 'clip.mp4',
              dark: false,
              engine: TestMediaEngine()..available = false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('LibVLC could not be loaded.'), findsOneWidget);
      expect(find.text('Open With…'), findsOneWidget);
      expect(find.text('Choose an application'), findsOneWidget);
      expect(bridge.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  for (final failedStop in [false, true]) {
    testWidgets(
      'navigation guard ${failedStop ? 'keeps explicit Close usable after ambiguous stop' : 'removes the player route only after acknowledged stop'}',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              SystemChannels.platform_views,
              (_) async => null,
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform_views, null),
        );
        final bridge = MediaBridge();
        final engine = TestMediaEngine()..failStop = failedStop;
        if (!failedStop) engine.stopGate = Completer<void>();
        final key = GlobalKey<NavigatorState>();
        Future<bool> Function()? guard;
        var warnings = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: key,
            home: const Scaffold(body: Text('Browser')),
          ),
        );
        unawaited(
          showDialog<void>(
            context: key.currentContext!,
            barrierDismissible: false,
            builder: (_) => FarshoreVideoPlayer(
              bridge: bridge,
              hostId: 'source-host',
              remotePath: 'clip.mp4',
              filename: 'clip.mp4',
              dark: false,
              engine: engine,
              onNavigationGuard: (value) => guard = value,
              onLeaseRetained: () => warnings++,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(engine.controls.map((c) => c.action), contains('play'));
        // This upper route represents the launcher. Closing the player must never
        // accidentally pop it after asynchronous decoder cleanup.
        unawaited(
          showDialog<void>(
            context: key.currentContext!,
            builder: (_) =>
                const AlertDialog(title: Text('Path launcher stays')),
          ),
        );
        await tester.pumpAndSettle();
        final closing = guard!();
        await tester.pump();
        expect(bridge.calls.where((c) => c.method == 'release_media'), isEmpty);
        if (!failedStop) engine.stopGate!.complete();
        expect(await closing, !failedStop);
        await tester.pumpAndSettle();
        expect(find.text('Path launcher stays'), findsOneWidget);
        key.currentState!.pop();
        await tester.pumpAndSettle();
        if (failedStop) {
          expect(warnings, 1);
          expect(find.byType(FarshoreVideoPlayer), findsOneWidget);
          final close = find.widgetWithIcon(IconButton, Icons.close_rounded);
          expect(tester.widget<IconButton>(close).onPressed, isNotNull);
          await tester.tap(close);
          await tester.pumpAndSettle();
          expect(find.byType(FarshoreVideoPlayer), findsNothing);
          expect(
            bridge.calls.where((c) => c.method == 'release_media'),
            isEmpty,
          );
        } else {
          expect(find.byType(FarshoreVideoPlayer), findsNothing);
          expect(bridge.calls.last.method, 'release_media');
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
