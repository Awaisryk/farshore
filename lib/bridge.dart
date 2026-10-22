import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract class BridgeClient {
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]);
  void dispose();
}

class BridgeFailure implements Exception {
  const BridgeFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

enum BridgeRecoveryPhase { idle, starting, ready, retrying, failed, closed }

class BridgeRecoveryState {
  const BridgeRecoveryState(this.phase, {this.attempt = 0, this.message = ''});
  final BridgeRecoveryPhase phase;
  final int attempt;
  final String message;
}

/// Optional so in-memory clients do not need a subprocess lifecycle.
abstract interface class BridgeRecovery {
  ValueListenable<BridgeRecoveryState> get recovery;
  void cancelRecovery();
}

class _PendingRequest {
  _PendingRequest(this.generation, this.completer);
  final int generation;
  final Completer<Map<String, dynamic>> completer;
}

class _RecoveryOperation {
  final cancelled = Completer<void>();
  bool retrying = false;
  String? requestId;
}

/// Versioned newline-delimited RPC. Only idempotent reads can be replayed.
/// Each subprocess has a generation so a late exit cannot kill its successor.
class ProcessBridge implements BridgeClient, BridgeRecovery {
  ProcessBridge({
    String? root,
    String? python,
    String? script,
    this.requestTimeout = const Duration(seconds: 90),
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 3)],
  }) : _root =
           root ??
           Platform.environment['FARSHORE_ROOT'] ??
           Directory.current.path,
       _python =
           python ??
           Platform.environment['FARSHORE_PYTHON'] ??
           '/usr/bin/python3',
       _script = script ?? Platform.environment['FARSHORE_BRIDGE_SCRIPT'];

  final String _root, _python;
  final String? _script;
  final Duration requestTimeout;
  final List<Duration> retryDelays;
  Process? _process;
  Future<void>? _starting;
  final _pending = <String, _PendingRequest>{};
  final _operations = <_RecoveryOperation>{};
  final _recovery = ValueNotifier<BridgeRecoveryState>(
    const BridgeRecoveryState(BridgeRecoveryPhase.idle),
  );
  int _nextId = 0, _generation = 0;
  bool _disposed = false;

  @override
  ValueListenable<BridgeRecoveryState> get recovery => _recovery;

  void _state(
    BridgeRecoveryPhase phase, {
    int attempt = 0,
    String message = '',
  }) {
    if (_disposed && phase != BridgeRecoveryPhase.closed) return;
    // Background status polling must not hide an active folder recovery.
    if ((phase == BridgeRecoveryPhase.ready ||
            phase == BridgeRecoveryPhase.starting) &&
        _operations.any((op) => op.retrying)) {
      return;
    }
    _recovery.value = BridgeRecoveryState(
      phase,
      attempt: attempt,
      message: message,
    );
  }

  Future<void> _ensureStarted() async {
    if (_disposed) throw const BridgeFailure('closed', 'The bridge is closed.');
    if (_process != null) return;
    if (_starting != null) return _starting!;
    final starting = _start();
    _starting = starting;
    try {
      await starting;
    } finally {
      if (identical(_starting, starting)) _starting = null;
    }
  }

  Future<void> _start() async {
    final script = File(_script ?? '$_root/backend/farshore_bridge.py');
    if (!script.existsSync()) {
      throw const BridgeFailure(
        'helper_missing',
        'The local bridge was not found. Reinstall Farshore or rebuild the app.',
      );
    }
    _state(BridgeRecoveryPhase.starting);
    final generation = ++_generation;
    try {
      final process = await Process.start(_python, [
        '-I',
        '-B',
        script.path,
        'serve',
      ], workingDirectory: _root);
      if (_disposed || generation != _generation) {
        unawaited(process.stdin.close().catchError((_) {}));
        return;
      }
      _process = process;
      // stderr may contain connection details; never copy it into diagnostics.
      unawaited(process.stderr.drain<void>().catchError((_) {}));
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => _response(generation, line),
            onError: (_) => _failSession(generation),
            onDone: () => _failSession(generation),
          );
      unawaited(
        process.stdin.done.then<void>(
          (_) {},
          onError: (Object _) => _failSession(generation),
        ),
      );
      unawaited(process.exitCode.then((_) => _failSession(generation)));
    } on ProcessException {
      _state(
        BridgeRecoveryPhase.failed,
        message: 'The local helper could not start.',
      );
      throw const BridgeFailure(
        'helper_missing',
        'The local helper could not start. Reinstall Farshore or check its permissions.',
      );
    }
  }

  void _response(int generation, String line) {
    if (_disposed || generation != _generation) return;
    if (line.length > 8 * 1024 * 1024) {
      _failSession(generation);
      return;
    }
    try {
      final data = jsonDecode(line) as Map<String, dynamic>;
      final request = _pending[data['id']];
      if (request == null || request.generation != generation) return;
      // Validate before removing the waiter, including malformed success data.
      if (data['version'] != 1) {
        _pending.remove(data['id']);
        request.completer.completeError(
          const BridgeFailure(
            'protocol_version',
            'The local bridge version is incompatible.',
          ),
        );
      } else if (data['ok'] == true) {
        final result = Map<String, dynamic>.from(data['result'] as Map);
        _pending.remove(data['id']);
        request.completer.complete(result);
      } else {
        final error = data['error'] as Map? ?? {};
        final failure = BridgeFailure(
          error['code'] as String? ?? 'error',
          error['message'] as String? ?? 'The operation could not complete.',
        );
        _pending.remove(data['id']);
        request.completer.completeError(failure);
      }
    } catch (_) {
      _failSession(generation);
    }
  }

  void _failSession(int generation) {
    if (_disposed || generation != _generation) return;
    final old = _process;
    _process = null;
    ++_generation;
    if (old != null) unawaited(old.stdin.close().catchError((_) {}));
    final ids = _pending.entries
        .where((entry) => entry.value.generation == generation)
        .map((entry) => entry.key)
        .toList();
    for (final id in ids) {
      _pending
          .remove(id)!
          .completer
          .completeError(
            const BridgeFailure(
              'bridge_closed',
              'The local helper stopped. Retry to reconnect.',
            ),
          );
    }
    _state(
      BridgeRecoveryPhase.failed,
      message: 'The local helper stopped. Retry to reconnect.',
    );
  }

  static const _replayable = {
    'hosts',
    'status',
    'list',
    'recent_paths',
    'diagnostics',
  };
  bool _canRetry(String method, BridgeFailure error) =>
      _replayable.contains(method) &&
      (error.code == 'bridge_closed' ||
          (method == 'list' &&
              {'connection_failed', 'timeout'}.contains(error.code)));

  Future<T> _cancellable<T>(Future<T> future, _RecoveryOperation op) =>
      Future.any([
        future,
        op.cancelled.future.then<T>(
          (_) => throw const BridgeFailure(
            'recovery_cancelled',
            'Reconnection cancelled. Retry when you are ready.',
          ),
        ),
      ]);

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final op = _RecoveryOperation();
    _operations.add(op);
    try {
      for (var attempt = 0; ; attempt++) {
        try {
          final result = await _cancellable(_callOnce(method, params, op), op);
          op.retrying = false;
          _state(BridgeRecoveryPhase.ready);
          return result;
        } on BridgeFailure catch (error) {
          if (_disposed ||
              op.cancelled.isCompleted ||
              !_canRetry(method, error) ||
              attempt >= retryDelays.length) {
            if (op.retrying) {
              op.retrying = false;
              _state(BridgeRecoveryPhase.failed, message: error.message);
            }
            rethrow;
          }
          op.retrying = true;
          _state(
            BridgeRecoveryPhase.retrying,
            attempt: attempt + 1,
            message: error.code == 'bridge_closed'
                ? 'Restarting the local helper…'
                : 'Connection interrupted. Reconnecting…',
          );
          await _cancellable(Future<void>.delayed(retryDelays[attempt]), op);
        }
      }
    } finally {
      _operations.remove(op);
    }
  }

  Future<Map<String, dynamic>> _callOnce(
    String method,
    Map<String, dynamic> params,
    _RecoveryOperation op,
  ) async {
    await _ensureStarted();
    if (_disposed || _process == null) {
      throw const BridgeFailure('bridge_closed', 'The local bridge is closed.');
    }
    if (op.cancelled.isCompleted) {
      throw const BridgeFailure(
        'recovery_cancelled',
        'Reconnection cancelled.',
      );
    }
    final id = '${++_nextId}';
    final message = jsonEncode({
      'version': 1,
      'id': id,
      'method': method,
      'params': params,
    });
    if (utf8.encode(message).length > 64 * 1024) {
      throw const BridgeFailure(
        'request_too_large',
        'The request is too large. Close some saved tabs and retry.',
      );
    }
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = _PendingRequest(_generation, completer);
    op.requestId = id;
    try {
      _process!.stdin.writeln(message);
    } catch (_) {
      _failSession(_generation);
    }
    return completer.future.timeout(
      method == 'choose_application'
          ? const Duration(minutes: 5)
          : requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw const BridgeFailure(
          'timeout',
          'The operation is taking too long. Check the connection and retry.',
        );
      },
    );
  }

  @override
  void cancelRecovery() {
    final retrying = _operations.where((op) => op.retrying).toList();
    if (retrying.isEmpty) return;
    for (final op in retrying) {
      if (!op.cancelled.isCompleted) op.cancelled.complete();
      final pending = _pending.remove(op.requestId);
      pending?.completer.completeError(
        const BridgeFailure(
          'recovery_cancelled',
          'Reconnection cancelled. Retry when you are ready.',
        ),
      );
    }
    _state(
      BridgeRecoveryPhase.failed,
      message: 'Reconnection cancelled. Retry when you are ready.',
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    // stdin closure drains requests. Detached external mounts stay available.
    unawaited(
      _process?.stdin.close().catchError((_) {}) ?? Future<void>.value(),
    );
    _process = null;
    for (final request in _pending.values) {
      request.completer.completeError(
        const BridgeFailure('closed', 'The bridge is closed.'),
      );
    }
    _pending.clear();
    for (final op in _operations) {
      if (!op.cancelled.isCompleted) op.cancelled.complete();
    }
    _state(BridgeRecoveryPhase.closed);
    _recovery.dispose();
  }
}
