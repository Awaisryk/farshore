import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bridge.dart';

abstract class FilePreviewEngine {
  Future<Map<String, dynamic>> availability();
  Future<Map<String, dynamic>> open(int viewId);
  Future<Map<String, dynamic>> state(int viewId);
  Future<bool> close(int viewId);
}

class NativeFilePreviewEngine implements FilePreviewEngine {
  const NativeFilePreviewEngine();
  static const channel = MethodChannel('farshore/preview');
  Future<Map<String, dynamic>> _call(String method, [int? id]) async =>
      Map<String, dynamic>.from(
        await channel
                .invokeMapMethod<String, dynamic>(
                  method,
                  id == null ? null : {'viewId': id},
                )
                .timeout(const Duration(seconds: 8)) ??
            {},
      );
  @override
  Future<Map<String, dynamic>> availability() => _call('availability');
  @override
  Future<Map<String, dynamic>> open(int viewId) => _call('open', viewId);
  @override
  Future<Map<String, dynamic>> state(int viewId) => _call('state', viewId);
  @override
  Future<bool> close(int viewId) async =>
      (await _call('close', viewId))['closed'] == true;
}

enum FilePreviewPhase { loading, ready, failed, closed }

class _PreviewAttempt {
  _PreviewAttempt(this.requestId);
  final String requestId;
  String? previewId, localPath;
  int? viewId;
  bool cancelled = false;
  Future<Map<String, dynamic>>? opening;
  Future<bool>? closing;
}

/// Owns one bounded backend snapshot at a time. Native factories do not read
/// until open, and files are released only after a positive native close reply.
class FilePreviewController extends ChangeNotifier {
  FilePreviewController({
    required this.bridge,
    required this.hostId,
    required this.remotePath,
    this.engine = const NativeFilePreviewEngine(),
  });
  final BridgeClient bridge;
  final String hostId, remotePath;
  final FilePreviewEngine engine;
  static final _random = Random.secure();
  static int _sequence = 0;
  _PreviewAttempt? _attempt;
  bool _closed = false, _disposed = false;
  Future<bool>? _closing;
  FilePreviewPhase phase = FilePreviewPhase.loading;
  String kind = '', mimeType = '', text = '', message = '';
  int sourceBytes = 0;
  bool truncated = false, nativeAttached = false, leaseRetained = false;
  String? get localPath => _attempt?.localPath;
  String? get requestId => _attempt?.requestId;
  bool get canRetry => !_closed && phase == FilePreviewPhase.failed;

  bool _current(_PreviewAttempt attempt) =>
      !_closed &&
      !_disposed &&
      identical(_attempt, attempt) &&
      !attempt.cancelled;
  void _changed() {
    if (!_closed && !_disposed) notifyListeners();
  }

  String _newRequestId() =>
      'file-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}-'
      '${_random.nextInt(1 << 32).toRadixString(16)}${_random.nextInt(1 << 32).toRadixString(16)}';

  Future<void> load() async {
    if (_closed || _disposed) return;
    final previous = _attempt;
    if (previous != null && !await _closeAttempt(previous)) {
      phase = FilePreviewPhase.failed;
      message =
          'The previous preview could not confirm cleanup. Close this preview before trying again.';
      _changed();
      return;
    }
    if (_closed || _disposed) return;
    final attempt = _PreviewAttempt(_newRequestId());
    _attempt = attempt;
    phase = FilePreviewPhase.loading;
    kind = mimeType = text = message = '';
    sourceBytes = 0;
    truncated = nativeAttached = false;
    _changed();
    try {
      final data = await bridge.call('prepare_preview', {
        'hostId': hostId,
        'path': remotePath,
        'requestId': attempt.requestId,
      });
      attempt.previewId = data['previewId'] as String?;
      attempt.localPath = data['localPath'] as String?;
      if (!_current(attempt)) {
        // A backend response can win the cancellation race. Release by both
        // identities again; backend release is idempotent.
        await _release(attempt);
        return;
      }
      kind = data['kind'] as String? ?? '';
      mimeType = data['mimeType'] as String? ?? '';
      sourceBytes = (data['sourceBytes'] as num? ?? 0).toInt();
      if (attempt.previewId == null ||
          attempt.previewId!.isEmpty ||
          !const {'image', 'text', 'document'}.contains(kind)) {
        throw const BridgeFailure(
          'preview_invalid',
          'The connection did not provide a usable preview.',
        );
      }
      if (kind == 'text') {
        final value = data['text'];
        if (value is! String) {
          throw const BridgeFailure(
            'preview_invalid',
            'The text preview was unavailable.',
          );
        }
        // The backend enforces a 512 KiB source prefix. Also bound an invalid
        // response defensively so it cannot create an unbounded text widget.
        text = value.length > 512 * 1024
            ? value.substring(0, 512 * 1024)
            : value;
        truncated = data['truncated'] == true || text.length != value.length;
      } else {
        final path = attempt.localPath;
        if (path == null || !path.startsWith('/') || path.contains('\u0000')) {
          throw const BridgeFailure(
            'preview_invalid',
            'The connection did not provide a usable preview file.',
          );
        }
        final availability = await engine.availability();
        if (!_current(attempt)) return;
        if (availability['available'] != true) {
          throw BridgeFailure(
            'preview_unavailable',
            availability['message'] as String? ??
                'macOS Quick Look is unavailable. Use Open With to choose an application.',
          );
        }
      }
      if (!_current(attempt)) return;
      phase = FilePreviewPhase.ready;
      _changed();
    } catch (error) {
      if (!_current(attempt)) return;
      final problem = _message(error, attempt);
      await _closeAttempt(attempt);
      if (_closed || _disposed || !identical(_attempt, attempt)) return;
      phase = FilePreviewPhase.failed;
      message = problem;
      _changed();
    }
  }

  Future<void> attachView(int viewId, String attemptId) async {
    final attempt = _attempt;
    if (attempt == null || attempt.requestId != attemptId) {
      // A late factory contains no preview item until explicit open.
      try {
        await engine.close(viewId);
      } catch (_) {}
      return;
    }
    attempt.viewId = viewId;
    if (!_current(attempt)) {
      try {
        await engine.close(viewId);
      } catch (_) {}
      return;
    }
    try {
      final opening = engine.open(viewId);
      attempt.opening = opening;
      final state = await opening;
      if (!_current(attempt)) return;
      final accepted = state['status'] == 'attached'
          ? state
          : await engine.state(viewId);
      if (!_current(attempt)) return;
      if (accepted['status'] != 'attached') {
        throw BridgeFailure(
          'preview_unavailable',
          accepted['error'] as String? ??
              'macOS could not attach this preview. Use Open With to choose another application.',
        );
      }
      nativeAttached = true;
      _changed();
    } catch (error) {
      if (!_current(attempt)) return;
      final problem = _message(error, attempt);
      await _closeAttempt(attempt);
      if (_closed || _disposed || !identical(_attempt, attempt)) return;
      phase = FilePreviewPhase.failed;
      message = problem;
      _changed();
    }
  }

  String _message(Object error, _PreviewAttempt attempt) {
    var result = error is BridgeFailure
        ? error.message
        : error is PlatformException
        ? error.message ?? 'macOS could not display this preview.'
        : 'This file could not be previewed. Use Open With to choose an application.';
    for (final private in [
      attempt.localPath,
      attempt.previewId,
      attempt.requestId,
    ]) {
      if (private != null && private.isNotEmpty) {
        result = result.replaceAll(private, 'the preview');
      }
    }
    return result;
  }

  Future<bool> _release(_PreviewAttempt attempt) async {
    try {
      final result = await bridge.call('release_preview', {
        'requestId': attempt.requestId,
        if (attempt.previewId != null) 'previewId': attempt.previewId,
      });
      if (result['released'] == true) return true;
      leaseRetained = true;
      return false;
    } catch (_) {
      leaseRetained = true;
      return false;
    }
  }

  Future<bool> _closeAttempt(_PreviewAttempt attempt) =>
      attempt.closing ??= _stopAndRelease(attempt);
  Future<bool> _stopAndRelease(_PreviewAttempt attempt) async {
    attempt.cancelled = true;
    final viewId = attempt.viewId;
    if (viewId != null) {
      // Drain any open request before requesting close, including native setup
      // that reported a failure after allocating a Quick Look view.
      try {
        await attempt.opening;
      } catch (_) {}
      try {
        if (!await engine.close(viewId)) {
          leaseRetained = true;
          return false;
        }
      } catch (_) {
        leaseRetained = true;
        return false;
      }
    }
    return _release(attempt);
  }

  Future<bool> close() => _closing ??= _close();
  Future<bool> _close() async {
    _closed = true;
    final attempt = _attempt;
    final safe = attempt == null || await _closeAttempt(attempt);
    phase = safe ? FilePreviewPhase.closed : FilePreviewPhase.failed;
    if (!safe) {
      message =
          'Preview cleanup could not be confirmed. Its temporary file has been kept safe.';
    }
    return safe;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

typedef FilePreviewViewBuilder =
    Widget Function(
      BuildContext context,
      String path,
      ValueChanged<int> onCreated,
    );

class FilePreviewDialog extends StatefulWidget {
  const FilePreviewDialog({
    super.key,
    required this.bridge,
    required this.hostId,
    required this.remotePath,
    required this.filename,
    this.onNavigationGuard,
    this.onLeaseRetained,
    this.engine = const NativeFilePreviewEngine(),
    this.viewBuilder,
  });
  final BridgeClient bridge;
  final String hostId, remotePath, filename;
  final ValueChanged<Future<bool> Function()?>? onNavigationGuard;
  final VoidCallback? onLeaseRetained;
  final FilePreviewEngine engine;
  final FilePreviewViewBuilder? viewBuilder;
  @override
  State<FilePreviewDialog> createState() => _FilePreviewDialogState();
}

class _FilePreviewDialogState extends State<FilePreviewDialog> {
  late final FilePreviewController preview;
  final _textScroll = ScrollController();
  bool _closing = false,
      _allowPop = false,
      _registered = false,
      _warned = false;
  @override
  void initState() {
    super.initState();
    preview = FilePreviewController(
      bridge: widget.bridge,
      hostId: widget.hostId,
      remotePath: widget.remotePath,
      engine: widget.engine,
    )..load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_registered) {
      _registered = true;
      widget.onNavigationGuard?.call(_closeForNavigation);
    }
  }

  @override
  void dispose() {
    widget.onNavigationGuard?.call(null);
    _textScroll.dispose();
    preview.dispose();
    super.dispose();
  }

  void _warn() {
    if (preview.leaseRetained && !_warned) {
      _warned = true;
      widget.onLeaseRetained?.call();
    }
  }

  Future<bool> _closeForNavigation() async {
    final navigator = Navigator.of(context), route = ModalRoute.of(context);
    if (!_closing) setState(() => _closing = true);
    final safe = await preview.close();
    _warn();
    if (!safe) {
      if (mounted) setState(() => _closing = false);
      return false;
    }
    if (navigator.mounted && route != null && route.isActive) {
      navigator.removeRoute(route);
    }
    return true;
  }

  Future<void> _dismiss({bool openWith = false}) async {
    if (_closing) return;
    final navigator = Navigator.of(context), route = ModalRoute.of(context);
    setState(() => _closing = true);
    await preview.close();
    _warn();
    if (!mounted || !navigator.mounted || route == null || !route.isActive) {
      return;
    }
    if (route.isCurrent) {
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (navigator.mounted && route.isActive) {
        if (route.isCurrent) {
          navigator.pop(openWith);
        } else {
          navigator.removeRoute(route, openWith);
        }
      }
    } else {
      navigator.removeRoute(route, openWith);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    return PopScope<bool>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _dismiss(openWith: result == true);
      },
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _dismiss},
        child: Focus(
          autofocus: true,
          debugLabel: 'File preview',
          child: Dialog(
            clipBehavior: Clip.antiAlias,
            insetPadding: const EdgeInsets.all(24),
            child: SizedBox(
              width: min(1120, size.width - 48),
              height: min(820, size.height - 48),
              child: AnimatedBuilder(
                animation: preview,
                builder: (context, _) => Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 10, 11),
                      child: Row(
                        children: [
                          Icon(
                            preview.kind == 'text'
                                ? Icons.subject_rounded
                                : Icons.preview_outlined,
                            size: 19,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 11),
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
                                  preview.phase == FilePreviewPhase.loading
                                      ? 'Preparing a bounded preview over SSH…'
                                      : preview.mimeType.isEmpty
                                      ? 'File preview'
                                      : '${preview.mimeType} · ${_size(preview.sourceBytes)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          TextButton.icon(
                            onPressed: _closing
                                ? null
                                : () => _dismiss(openWith: true),
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 15,
                            ),
                            label: const Text(
                              'Open With…',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close preview',
                            onPressed: _closing ? null : _dismiss,
                            icon: const Icon(Icons.close_rounded, size: 19),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: colors.outlineVariant),
                    Expanded(child: _content(context)),
                    Divider(height: 1, color: colors.outlineVariant),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 12,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              preview.kind == 'text'
                                  ? 'Plain text only. Markdown, HTML and source files are displayed without execution.'
                                  : 'macOS Quick Look controls this preview. If it cannot display the file, use Open With.',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 10,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (preview.phase == FilePreviewPhase.loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 23,
              height: 23,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 18),
            Text(
              _closing ? 'Canceling preview…' : 'Reading a bounded preview…',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _closing ? null : _dismiss,
              child: const Text('Cancel preview'),
            ),
          ],
        ),
      );
    }
    if (preview.phase == FilePreviewPhase.failed) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.info_outline_rounded, size: 38, color: colors.primary),
              const SizedBox(height: 17),
              const Text(
                'Preview unavailable',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 13),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Text(
                  preview.message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.7,
                  ),
                ),
              ),
              const SizedBox(height: 19),
              Wrap(
                spacing: 9,
                runSpacing: 9,
                alignment: WrapAlignment.center,
                children: [
                  if (preview.canRetry)
                    OutlinedButton.icon(
                      onPressed: _closing ? null : preview.load,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Retry preview'),
                    ),
                  FilledButton.icon(
                    onPressed: _closing ? null : () => _dismiss(openWith: true),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Choose an application'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (preview.kind == 'text') {
      return Column(
        children: [
          if (preview.truncated)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 11, 20, 11),
              color: colors.secondaryContainer,
              child: Semantics(
                liveRegion: true,
                child: Text(
                  'This is a bounded text excerpt (up to 512 KB). Use Open With for the complete file.',
                  style: TextStyle(
                    color: colors.onSecondaryContainer,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Scrollbar(
              controller: _textScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _textScroll,
                padding: const EdgeInsets.all(23),
                child: SizedBox(
                  width: double.infinity,
                  child: SelectionArea(
                    child: SelectableText(
                      preview.text.isEmpty ? '(Empty file)' : preview.text,
                      style: TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 12,
                        height: 1.7,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (preview.phase == FilePreviewPhase.closed || preview.localPath == null) {
      return const SizedBox.shrink();
    }
    final id = preview.requestId!;
    void created(int viewId) => preview.attachView(viewId, id);
    return Stack(
      fit: StackFit.expand,
      children: [
        KeyedSubtree(
          key: ValueKey(id),
          child:
              widget.viewBuilder?.call(context, preview.localPath!, created) ??
              AppKitView(
                viewType: 'farshore/file_preview',
                creationParams: {'path': preview.localPath!},
                creationParamsCodec: const StandardMessageCodec(),
                onPlatformViewCreated: created,
              ),
        ),
        if (!preview.nativeAttached)
          IgnorePointer(
            child: ColoredBox(
              color: colors.surface,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(height: 15),
                    Text(
                      'Opening macOS preview…',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
