import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bridge.dart';
import 'slider.dart';

abstract class MediaEngine {
  Future<Map<String, dynamic>> availability();
  Future<Map<String, dynamic>> state(int viewId);
  Future<void> control(
    int viewId,
    String action, {
    double? position,
    int? volume,
  });
}

class NativeMediaEngine implements MediaEngine {
  const NativeMediaEngine();
  static const _channel = MethodChannel('farshore/media');

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic>? params,
  ]) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>(method, params) ?? {},
  );

  @override
  Future<Map<String, dynamic>> availability() => _call('availability');
  @override
  Future<Map<String, dynamic>> state(int viewId) =>
      _call('state', {'viewId': viewId});
  @override
  Future<void> control(
    int viewId,
    String action, {
    double? position,
    int? volume,
  }) async {
    await _channel.invokeMethod<Object?>('control', {
      'viewId': viewId,
      'action': action,
      'position': ?position,
      'volume': ?volume,
    });
  }
}

enum PlaybackPhase { checking, preparing, ready, failed, closed }

/// Owns the internal-reader lease separately from any browser tab. The lease is
/// released only after native playback stops, including during failed startup.
class MediaPlaybackController extends ChangeNotifier {
  MediaPlaybackController({
    required this.bridge,
    required this.hostId,
    required this.remotePath,
    this.engine = const NativeMediaEngine(),
    this.pollInterval = const Duration(milliseconds: 750),
    this.commandTimeout = const Duration(seconds: 12),
  });
  final BridgeClient bridge;
  final String hostId, remotePath;
  final MediaEngine engine;
  final Duration pollInterval;
  final Duration commandTimeout;
  PlaybackPhase phase = PlaybackPhase.checking;
  String? mountPath, streamUrl, leaseId;
  String version = '', message = '';
  bool playing = false;
  bool leaseRetained = false;
  String? controlError;
  double position = 0;
  int timeMs = 0, lengthMs = 0, stateCode = 0, volume = 100;
  int? viewId;
  Timer? _timer;
  bool _closed = false, _polling = false, _released = false;
  bool _stopAcknowledged = false;
  Future<bool>? _stopping;
  Future<void>? _closing;
  String? _pendingAction;
  bool _commandAcknowledged = false;
  int _commandSerial = 0;
  Timer? _commandDeadline;
  Completer<void>? _commandCompletion;
  bool get commandPending => _pendingAction != null;
  bool get hasEnded => stateCode == 6;
  bool get canPause => stateCode == 1 || stateCode == 2 || stateCode == 3;
  String get playbackAction => hasEnded
      ? 'replay'
      : stateCode == 4
      ? 'resume'
      : canPause
      ? 'pause'
      : 'play';
  String get playbackLabel => switch (_pendingAction ?? playbackAction) {
    'pause' => commandPending ? 'Pausing…' : 'Pause',
    'resume' => commandPending ? 'Resuming…' : 'Resume',
    'replay' => commandPending ? 'Restarting…' : 'Replay',
    _ => commandPending ? 'Starting…' : 'Play',
  };
  Map<String, String> get nativeSource =>
      streamUrl != null ? {'url': streamUrl!} : {'path': mountPath!};
  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      final available = await engine.availability();
      if (_closed) return;
      version = available['version'] as String? ?? '';
      if (available['available'] != true) {
        _fail(
          available['message'] as String? ??
              'LibVLC is unavailable. Rebuild Farshore with its media engine, or use Open With.',
        );
        return;
      }
      phase = PlaybackPhase.preparing;
      _changed();
      final media = await bridge.call('prepare_media', {
        'hostId': hostId,
        'path': remotePath,
      });
      mountPath = media['mountPath'] as String?;
      streamUrl = media['streamUrl'] as String?;
      leaseId = media['leaseId'] as String?;
      if (_closed) {
        await _release();
        return;
      }
      if (leaseId == null || leaseId!.isEmpty) {
        throw const BridgeFailure(
          'invalid_media_lease',
          'The connection did not provide a usable playback session.',
        );
      }
      if (streamUrl != null && !isPrivateMediaUrl(streamUrl!)) {
        throw const BridgeFailure(
          'invalid_media_url',
          'The connection did not provide a protected local playback source.',
        );
      }
      if (streamUrl == null &&
          (mountPath == null || !mountPath!.startsWith('/'))) {
        throw const BridgeFailure(
          'invalid_media_path',
          'The connection did not provide a usable playback source.',
        );
      }
      phase = PlaybackPhase.ready;
      _changed();
    } catch (error) {
      if (!_closed) _fail(_message(error));
    }
  }

  Future<void> attachView(int id) async {
    viewId = id;
    if (_closed) {
      await _stop();
      return;
    }
    _timer = Timer.periodic(pollInterval, (_) => poll());
    await _requestPlayback('play');
  }

  Future<void> poll() async {
    if (_closed || _polling || viewId == null || phase != PlaybackPhase.ready) {
      return;
    }
    _polling = true;
    try {
      final data = await engine.state(viewId!);
      if (_closed) return;
      playing = data['playing'] == true;
      position = (data['position'] as num? ?? 0).toDouble().clamp(0, 1);
      lengthMs = math.max(0, (data['lengthMs'] as num? ?? 0).toInt());
      timeMs = math.max(0, (data['timeMs'] as num? ?? 0).toInt());
      stateCode = (data['state'] as num? ?? 0).toInt();
      if (hasEnded) {
        position = 1;
        if (lengthMs > 0) timeMs = lengthMs;
        playing = false;
      }
      if (stateCode == 7 || data['error'] != null) {
        _fail(
          data['error'] as String? ??
              'LibVLC could not play this file. Try opening it in another application.',
        );
      } else {
        _confirmPlaybackState();
        _changed();
      }
    } catch (error) {
      if (!_closed) _fail(_message(error));
    } finally {
      _polling = false;
    }
  }

  Future<void> togglePlayback() async {
    await _requestPlayback(playbackAction);
  }

  Future<void> _requestPlayback(String action) {
    final id = viewId;
    if (_closed ||
        phase != PlaybackPhase.ready ||
        id == null ||
        commandPending) {
      return Future.value();
    }
    _pendingAction = action;
    _commandAcknowledged = false;
    controlError = null;
    final serial = ++_commandSerial;
    final completion = Completer<void>();
    _commandCompletion = completion;
    _commandDeadline = Timer(commandTimeout, () {
      if (_isCurrentCommand(serial)) {
        _finishCommand(
          error:
              '${_actionName(action)} took too long to confirm. Try again or use Open With.',
        );
      }
    });
    _changed();
    unawaited(_sendPlayback(id, action, serial));
    return completion.future;
  }

  bool _isCurrentCommand(int serial) =>
      !_closed && commandPending && serial == _commandSerial;

  Future<void> _sendPlayback(int id, String action, int serial) async {
    try {
      // Resume and replay are distinct native operations: paused playback keeps
      // its input/time, while EOF replay creates a fresh input from the start.
      await engine.control(id, action);
      if (!_isCurrentCommand(serial)) return;
      _commandAcknowledged = true;
      await poll();
    } catch (error) {
      if (_isCurrentCommand(serial)) {
        _finishCommand(
          error: '${_actionName(action)} failed. ${_message(error)}',
        );
      }
    }
  }

  String _actionName(String action) => switch (action) {
    'resume' => 'Resume',
    'replay' => 'Replay',
    'pause' => 'Pause',
    _ => 'Playback',
  };

  void _confirmPlaybackState() {
    if (!commandPending || !_commandAcknowledged) return;
    final confirmed = switch (_pendingAction) {
      'pause' => stateCode == 4 || hasEnded,
      'replay' => playing && stateCode == 3 && position < 0.99,
      _ => playing && stateCode == 3,
    };
    if (confirmed) _finishCommand();
  }

  void _finishCommand({String? error}) {
    _commandDeadline?.cancel();
    _pendingAction = null;
    _commandAcknowledged = false;
    controlError = error;
    final completion = _commandCompletion;
    _commandCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    _changed();
  }

  Future<void> seek(double value) async {
    final id = viewId;
    if (_closed ||
        phase != PlaybackPhase.ready ||
        id == null ||
        lengthMs <= 0 ||
        commandPending) {
      return;
    }
    try {
      await engine.control(id, 'seek', position: value.clamp(0, 1));
      position = value.clamp(0, 1);
      timeMs = (lengthMs * position).round();
      _changed();
    } catch (error) {
      if (!_closed) _fail(_message(error));
    }
  }

  Future<void> setVolume(int value) async {
    final id = viewId;
    if (_closed || phase != PlaybackPhase.ready || id == null) return;
    try {
      await engine.control(id, 'volume', volume: value.clamp(0, 100));
      volume = value.clamp(0, 100);
      _changed();
    } catch (error) {
      if (!_closed) _fail(_message(error));
    }
  }

  void _fail(String problem) {
    phase = PlaybackPhase.failed;
    message = problem;
    _timer?.cancel();
    _finishCommand();
    unawaited(_stop());
    _changed();
  }

  String _message(Object error) {
    if (error is BridgeFailure) return error.message;
    if (error is PlatformException) {
      return error.message ??
          'The media engine could not complete this operation.';
    }
    return 'In-app playback is unavailable in this build. Use Open With to choose another application.';
  }

  Future<bool> _stop() async {
    if (_stopAcknowledged || viewId == null) return true;
    final waiting = _stopping;
    if (waiting != null) return waiting;
    final operation = _stopNative();
    _stopping = operation;
    final stopped = await operation;
    _stopping = null;
    return stopped;
  }

  Future<bool> _stopNative() async {
    try {
      await engine.control(viewId!, 'stop');
      _stopAcknowledged = true;
      return true;
    } catch (_) {
      // Missing/disposed platform-view errors do not prove that its asynchronous
      // decoder teardown finished. Preserve the lease on any ambiguous failure.
      return false;
    }
  }

  Future<void> _release() async {
    if (_released || leaseId == null || leaseId!.isEmpty) return;
    _released = true;
    await bridge.call('release_media', {'leaseId': leaseId});
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    phase = PlaybackPhase.closed;
    _timer?.cancel();
    _finishCommand();
    final stopped = await _stop();
    if (!stopped) {
      leaseRetained = true;
      return;
    }
    try {
      await _release();
    } catch (_) {
      // Never unmount automatically. A failed release preserves mounted access.
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

class FarshoreVideoPlayer extends StatefulWidget {
  const FarshoreVideoPlayer({
    super.key,
    required this.bridge,
    required this.hostId,
    required this.remotePath,
    required this.filename,
    required this.dark,
    this.audioOnly = false,
    this.engine = const NativeMediaEngine(),
    this.onLeaseRetained,
    this.onNavigationGuard,
  });
  final BridgeClient bridge;
  final String hostId, remotePath, filename;

  /// Retained for callers; player chrome follows the inherited theme.
  final bool dark;
  final bool audioOnly;
  final MediaEngine engine;
  final VoidCallback? onLeaseRetained;
  final ValueChanged<Future<bool> Function()?>? onNavigationGuard;
  @override
  State<FarshoreVideoPlayer> createState() => _FarshoreVideoPlayerState();
}

class _FarshoreVideoPlayerState extends State<FarshoreVideoPlayer> {
  late final MediaPlaybackController player;
  bool _closing = false;
  bool _guardRegistered = false;
  double? _seeking;
  @override
  void initState() {
    super.initState();
    player = MediaPlaybackController(
      bridge: widget.bridge,
      hostId: widget.hostId,
      remotePath: widget.remotePath,
      engine: widget.engine,
    )..initialize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_guardRegistered) {
      _guardRegistered = true;
      widget.onNavigationGuard?.call(_closeForNavigation);
    }
  }

  @override
  void dispose() {
    widget.onNavigationGuard?.call(null);
    player.dispose();
    super.dispose();
  }

  Future<bool> _closeForNavigation() async {
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (!_closing) setState(() => _closing = true);
    await player.close();
    if (player.leaseRetained) {
      widget.onLeaseRetained?.call();
      if (mounted) setState(() => _closing = false);
      return false;
    }
    // The launcher is above this route. Never pop the current top route here.
    if (navigator.mounted && route != null && route.isActive) {
      navigator.removeRoute(route);
    }
    return true;
  }

  Future<void> _dismiss({bool openWith = false}) async {
    if (_closing) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    setState(() => _closing = true);
    await player.close();
    if (player.leaseRetained) widget.onLeaseRetained?.call();
    if (navigator.mounted && route != null && route.isActive) {
      if (route.isCurrent) {
        navigator.pop(openWith);
      } else {
        navigator.removeRoute(route, openWith);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final colors = Theme.of(context).colorScheme;
    final muted = colors.onSurfaceVariant;
    return Dialog(
      backgroundColor: colors.surfaceContainerLow,
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(widget.audioOnly ? 860 : 1120, screen.width - 48),
        height: math.min(widget.audioOnly ? 440 : 800, screen.height - 48),
        child: AnimatedBuilder(
          animation: player,
          builder: (context, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 11, 10, 11),
                child: Row(
                  children: [
                    Icon(
                      widget.audioOnly
                          ? Icons.music_note_rounded
                          : Icons.play_circle_outline_rounded,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'VideoLAN LibVLC${player.version.isEmpty ? '' : ' · ${player.version}'}',
                            style: TextStyle(fontSize: 9, color: muted),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _closing
                          ? null
                          : () => _dismiss(openWith: true),
                      icon: const Icon(Icons.open_in_new_rounded, size: 14),
                      label: const Text(
                        'Open With…',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close player',
                      onPressed: _closing ? null : _dismiss,
                      icon: const Icon(Icons.close_rounded, size: 19),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ColoredBox(
                  color: Colors.black,
                  child: SizedBox.expand(
                    child: switch (player.phase) {
                      PlaybackPhase.ready || PlaybackPhase.closed
                          when player.phase == PlaybackPhase.ready ||
                              player.viewId != null =>
                        widget.audioOnly ? _audioSurface() : _nativeSurface(),
                      PlaybackPhase.failed => Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(36),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.ondemand_video_outlined,
                                size: 42,
                                color: Colors.white70,
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                'Playback needs another route',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                ),
                              ),
                              const SizedBox(height: 12),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 560,
                                ),
                                child: Text(
                                  player.message,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    height: 1.7,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 22),
                              OutlinedButton.icon(
                                onPressed: _closing
                                    ? null
                                    : () => _dismiss(openWith: true),
                                icon: const Icon(
                                  Icons.open_in_new_rounded,
                                  size: 15,
                                ),
                                label: const Text('Choose an application'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      _ => Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              _closing
                                  ? 'Closing playback…'
                                  : player.phase == PlaybackPhase.checking
                                  ? 'Checking media engine…'
                                  : 'Preparing playback over SSH…',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    },
                  ),
                ),
              ),
              if (player.controlError != null)
                Container(
                  width: double.infinity,
                  color: colors.errorContainer,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 11,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 16,
                        color: colors.onErrorContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          player.controlError!,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: colors.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              _controls(muted),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 11),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 10, color: muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        player.streamUrl != null
                            ? 'Streamed over your SSH connection'
                            : 'Read-only playback · media may buffer as it is read',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 9, color: muted),
                      ),
                    ),
                    if (player.hasEnded)
                      Text(
                        'Finished',
                        style: TextStyle(fontSize: 9, color: muted),
                      ),
                    if (player.stateCode == 1 || player.stateCode == 2)
                      Text(
                        'Buffering…',
                        style: TextStyle(fontSize: 9, color: muted),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nativeSurface() => AppKitView(
    key: ObjectKey(player),
    viewType: 'farshore/libvlc',
    creationParams: {
      ...player.nativeSource,
      if (widget.audioOnly) 'audioOnly': true,
    },
    creationParamsCodec: const StandardMessageCodec(),
    onPlatformViewCreated: player.attachView,
  );

  Widget _audioSurface() => Stack(
    fit: StackFit.expand,
    children: [
      // Keep the decoder mounted until its stop acknowledgment, as for video.
      Positioned(
        right: 0,
        bottom: 0,
        width: 1,
        height: 1,
        child: _nativeSurface(),
      ),
      const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq_rounded, size: 64, color: Colors.white70),
            SizedBox(height: 18),
            Text(
              'Audio preview',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Listen over your SSH connection',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _controls(Color muted) {
    final ready =
        player.phase == PlaybackPhase.ready &&
        player.viewId != null &&
        !_closing &&
        !player.commandPending;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 20, 5),
      child: LayoutBuilder(
        builder: (context, bounds) => Row(
          children: [
            Tooltip(
              message: player.playbackLabel,
              child: TextButton.icon(
                onPressed: ready ? player.togglePlayback : null,
                icon: player.commandPending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        player.hasEnded
                            ? Icons.replay_rounded
                            : player.canPause
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 23,
                      ),
                label: Text(
                  player.playbackLabel,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
            const SizedBox(width: 5),
            Text(
              mediaTime(
                _seeking == null
                    ? player.timeMs
                    : (player.lengthMs * _seeking!).round(),
              ),
              style: TextStyle(
                fontSize: 10,
                color: muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Expanded(
              child: FarshoreSlider(
                child: Slider(
                  value: _seeking ?? player.position,
                  semanticFormatterCallback: (value) =>
                      mediaTime((player.lengthMs * value).round()),
                  onChanged: ready && player.lengthMs > 0
                      ? (value) => setState(() => _seeking = value)
                      : null,
                  onChangeEnd: ready && player.lengthMs > 0
                      ? (value) {
                          setState(() => _seeking = null);
                          player.seek(value);
                        }
                      : null,
                ),
              ),
            ),
            Text(
              mediaTime(player.lengthMs),
              style: TextStyle(
                fontSize: 10,
                color: muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (bounds.maxWidth > 650) ...[
              const SizedBox(width: 19),
              Icon(
                player.volume == 0
                    ? Icons.volume_off_outlined
                    : Icons.volume_up_outlined,
                size: 17,
                color: muted,
              ),
              SizedBox(
                width: 90,
                child: FarshoreSlider(
                  child: Slider(
                    value: player.volume.toDouble(),
                    min: 0,
                    max: 100,
                    semanticFormatterCallback: (value) =>
                        'Volume ${value.round()} percent',
                    onChanged: ready
                        ? (value) => player.setVolume(value.round())
                        : null,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Backend media capabilities are accepted only from a private loopback URL.
/// Tokens stay inside the controller and native player, never in visible UI.
bool isPrivateMediaUrl(String value) {
  if (value.length > 512 || value.contains('%')) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'http' &&
      uri.host == '127.0.0.1' &&
      uri.hasPort &&
      uri.port >= 1024 &&
      uri.port <= 65535 &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      RegExp(r'^/media/[A-Za-z0-9_-]{32,128}$').hasMatch(uri.path);
}

String mediaTime(int milliseconds) {
  final seconds = math.max(0, milliseconds ~/ 1000);
  final minutes = seconds ~/ 60;
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return minutes >= 60
      ? '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}:$remainder'
      : '$minutes:$remainder';
}
