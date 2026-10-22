import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bridge.dart';
import 'browser_model.dart';

typedef MediaNavigationGuard = Future<bool> Function();

/// One application-wide route and keyboard entry point, shared by every modal.
class PathLauncherCoordinator {
  PathLauncherCoordinator(this.model, this.navigatorKey) {
    HardwareKeyboard.instance.addHandler(_handleKey);
  }
  final BrowserModel model;
  final GlobalKey<NavigatorState> navigatorKey;
  bool _open = false, _disposed = false;
  MediaNavigationGuard? _mediaGuard;
  bool get isOpen => _open;
  void setMediaNavigationGuard(MediaNavigationGuard? guard) =>
      _mediaGuard = guard;

  bool _handleKey(KeyEvent event) {
    if (_disposed || event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    final focus = FocusManager.instance.primaryFocus?.context;
    final editable = focus?.widget is EditableText
        ? focus!.widget as EditableText
        : focus?.findAncestorWidgetOfExactType<EditableText>();
    final editing = editable != null && !editable.readOnly;
    final slash =
        !keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        event.character == '/';
    final location =
        (keyboard.isMetaPressed || keyboard.isControlPressed) &&
        !keyboard.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.keyL;
    if ((editing && !location) || (!slash && !location)) return false;
    open(seed: slash ? '/' : model.tab.path, selectAll: !slash);
    return true;
  }

  Future<void> open({
    String? seed,
    bool selectAll = true,
    String? hostId,
    bool submitOnOpen = false,
  }) async {
    final navigator = navigatorKey.currentState;
    if (_open || _disposed || navigator == null) return;
    _open = true;
    try {
      final accepted = await showDialog<bool>(
        context: navigator.context,
        barrierColor: Colors.black.withValues(alpha: 0.24),
        builder: (context) => PathPalette(
          coordinator: this,
          seed: seed ?? model.tab.path,
          selectAll: selectAll,
          hostId: hostId,
          submitOnOpen: submitOnOpen,
        ),
      );
      if (accepted == true && !_disposed && navigator.mounted) {
        // The media guard has already stopped and removed its specific route.
        // Dismiss older preview/chooser dialogs so the destination is visible.
        navigator.popUntil((route) => route.isFirst);
      }
    } finally {
      _open = false;
    }
  }

  Future<void> openRecent(RecentPath location) =>
      open(seed: location.path, hostId: location.hostId, submitOnOpen: true);

  Future<PathNavigationResult> navigate(
    RemoteHost host,
    String path,
    PathNavigationAttempt attempt,
  ) async {
    if (attempt.cancelled || _disposed) {
      return const PathNavigationResult(success: false, cancelled: true);
    }
    try {
      final guard = _mediaGuard;
      if (guard != null && !await guard()) {
        return const PathNavigationResult(
          success: false,
          error: BridgeFailure(
            'playback_stop_unconfirmed',
            'Playback could not confirm a safe stop. Close the player and retry.',
          ),
        );
      }
      if (attempt.cancelled || _disposed) {
        return const PathNavigationResult(success: false, cancelled: true);
      }
      return await model.navigateFromLauncher(host, path, attempt);
    } catch (error) {
      return PathNavigationResult(
        success: false,
        error: BrowserModel.failure(error),
      );
    }
  }

  void dispose() {
    _disposed = true;
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _mediaGuard = null;
  }
}

class PathPalette extends StatefulWidget {
  const PathPalette({
    super.key,
    required this.coordinator,
    required this.seed,
    required this.selectAll,
    this.hostId,
    this.submitOnOpen = false,
  });
  final PathLauncherCoordinator coordinator;
  final String seed;
  final bool selectAll;
  final String? hostId;
  final bool submitOnOpen;
  @override
  State<PathPalette> createState() => _PathPaletteState();
}

class _PathPaletteState extends State<PathPalette> {
  late final TextEditingController _path;
  final _attempt = PathNavigationAttempt();
  String? _hostId, _error;
  int _selectedRecent = -1;
  bool _busy = false;
  BrowserModel get model => widget.coordinator.model;
  List<RemoteHost> get _hosts {
    final result = model.orderedHosts;
    final current = model.tab.host;
    if (current != null && !result.any((h) => h.id == current.id)) {
      result.insert(0, current);
    }
    return result;
  }

  RemoteHost? _host(String? id) {
    for (final host in _hosts) {
      if (host.id == id) return host;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(text: widget.seed);
    _path.selection = widget.selectAll
        ? TextSelection(baseOffset: 0, extentOffset: widget.seed.length)
        : TextSelection.collapsed(offset: widget.seed.length);
    _hostId = widget.hostId ?? model.tab.host?.id;
    if (widget.submitOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_attempt.cancelled) _submit();
      });
    }
  }

  @override
  void dispose() {
    _attempt.cancel();
    _path.dispose();
    super.dispose();
  }

  void _ensureHost() {
    if (_host(_hostId) != null) return;
    if (widget.hostId != null) {
      // A saved destination must never fall back to another server silently.
      _hostId = null;
      return;
    }
    for (final recent in model.recentPaths) {
      if (_host(recent.hostId) != null) {
        _hostId = recent.hostId;
        return;
      }
    }
    _hostId = _hosts.isEmpty ? null : _hosts.first.id;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final host = _host(_hostId);
    if (host == null) {
      setState(() => _error = 'Choose a server to open this folder.');
      return;
    }
    final path =
        _path.text; // Remote whitespace and shell metacharacters are literal.
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.coordinator.navigate(host, path, _attempt);
    if (!mounted || _attempt.cancelled) return;
    if (result.success) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error =
          result.error?.message ??
          'The location changed before navigation completed. Try again.';
    });
  }

  void _cancel() {
    _attempt.cancel();
    Navigator.of(context).pop(false);
  }

  void _chooseRecent(int index, {bool submit = false}) {
    if (_busy || index < 0 || index >= model.recentPaths.length) return;
    final recent = model.recentPaths[index];
    if (_host(recent.hostId) == null) return;
    setState(() {
      _selectedRecent = index;
      _hostId = recent.hostId;
      _path.text = recent.path;
      _path.selection = TextSelection.collapsed(offset: recent.path.length);
      _error = null;
    });
    if (submit) _submit();
  }

  void _moveRecent(int direction) {
    if (model.recentPaths.isEmpty || _busy) return;
    final next = _selectedRecent < 0
        ? (direction > 0 ? 0 : model.recentPaths.length - 1)
        : (_selectedRecent + direction).clamp(0, model.recentPaths.length - 1);
    _chooseRecent(next);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      model,
      model.hostChanges,
      model.recentChanges,
    ]),
    builder: (context, _) {
      _ensureHost();
      final theme = Theme.of(context);
      final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
      return PopScope<bool>(
        onPopInvokedWithResult: (didPop, result) {
          if (didPop && result != true) _attempt.cancel();
        },
        child: Dialog(
          alignment: Alignment.topCenter,
          insetPadding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 640,
              maxHeight: MediaQuery.sizeOf(context).height - 96,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 13, 14, 15),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.folder_open_rounded, size: 21),
                      const SizedBox(width: 11),
                      const Expanded(
                        child: Text(
                          'Go to folder',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Semantics(
                        label: 'Close path launcher',
                        button: true,
                        onTap: _cancel,
                        excludeSemantics: true,
                        child: IconButton(
                          tooltip: 'Close path launcher',
                          onPressed: _cancel,
                          icon: const Icon(Icons.close_rounded, size: 19),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      Text(
                        'Server',
                        style: TextStyle(color: muted, fontSize: 11),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Semantics(
                          label: 'Server',
                          child: DropdownButton<String>(
                            value: _hostId,
                            isExpanded: true,
                            underline: const SizedBox.shrink(),
                            hint: Text(
                              model.discovering
                                  ? 'Discovering SSH servers…'
                                  : 'Choose a server',
                            ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 12,
                            ),
                            items: [
                              for (final host in _hosts)
                                DropdownMenuItem(
                                  value: host.id,
                                  child: Text(host.alias),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (id) => setState(() {
                                    _hostId = id;
                                    _selectedRecent = -1;
                                    _error = null;
                                  }),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                          _moveRecent(1),
                      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                          _moveRecent(-1),
                      const SingleActivator(LogicalKeyboardKey.enter): _submit,
                      const SingleActivator(LogicalKeyboardKey.numpadEnter):
                          _submit,
                      const SingleActivator(LogicalKeyboardKey.escape): _cancel,
                    },
                    child: TextField(
                      controller: _path,
                      autofocus: true,
                      readOnly: _busy,
                      style: const TextStyle(fontSize: 18),
                      decoration: InputDecoration(
                        labelText: 'Remote folder path',
                        hintText: '/data2',
                        helperText:
                            'Absolute paths start with /. Empty opens Home.',
                        prefixIcon: const Icon(
                          Icons.folder_open_outlined,
                          size: 21,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onChanged: (_) => setState(() {
                        _selectedRecent = -1;
                        _error = null;
                      }),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 13, right: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: theme.colorScheme.error,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  if (model.recentPaths.isNotEmpty) ...[
                    const SizedBox(height: 21),
                    Text(
                      'RECENT LOCATIONS',
                      style: TextStyle(
                        color: muted,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (
                            var index = 0;
                            index < model.recentPaths.length;
                            index++
                          )
                            _recentRow(index, muted),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _hosts.isEmpty && !model.discovering
                              ? 'Add an SSH alias, then refresh connections.'
                              : '↑ ↓ recent locations    esc close',
                          style: TextStyle(color: muted, fontSize: 10),
                        ),
                      ),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(_error == null ? 'Go' : 'Retry'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _recentRow(int index, Color muted) {
    final recent = model.recentPaths[index];
    final host = _host(recent.hostId);
    final alias = host?.alias ?? 'Unavailable server';
    final path = recent.path.isEmpty ? 'Home' : recent.path;
    void select() => _chooseRecent(index, submit: true);
    return Semantics(
      label: '$alias · $path',
      button: true,
      enabled: host != null && !_busy,
      selected: _selectedRecent == index,
      onTap: host == null || _busy ? null : select,
      excludeSemantics: true,
      child: ListTile(
        dense: true,
        selected: _selectedRecent == index,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        leading: Icon(Icons.history_rounded, size: 17, color: muted),
        title: Text(
          path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        subtitle: Text(alias, style: TextStyle(color: muted, fontSize: 10)),
        onTap: host == null || _busy ? null : select,
      ),
    );
  }
}
