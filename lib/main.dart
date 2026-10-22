import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart'
    show kPrimaryButton, kDoubleTapTimeout, kDoubleTapMinTime, kDoubleTapSlop;
import 'bridge.dart';
import 'browser_model.dart';
import 'video_player.dart';
import 'slider.dart';
import 'path_launcher.dart';
import 'home_page.dart';
import 'app_theme.dart';
import 'app_style.dart';
import 'theme_picker.dart';
import 'file_preview.dart';
import 'settings_page.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    final path = Platform.environment['FARSHORE_NOTICES'];
    if (path != null) {
      try {
        yield LicenseEntryWithLineBreaks([
          'Farshore bundled dependencies',
        ], await File(path).readAsString());
      } on FileSystemException {
        // Flutter's embedded notices remain available if this file is absent.
      }
    }
  });
  runApp(
    FarshoreApp(
      model: BrowserModel(
        ProcessBridge(),
        scheduleThumbnailUpdates: (callback) =>
            WidgetsBinding.instance.scheduleFrameCallback((_) => callback()),
      ),
    ),
  );
}

/// Each visible preview owns its listener and requests work once on insertion.
/// Loading an image never rebuilds the browser, theme, or adjacent file cards.
class _RemoteThumbnail extends StatefulWidget {
  const _RemoteThumbnail({
    super.key,
    required this.model,
    required this.entry,
    required this.small,
    required this.placeholder,
  });
  final BrowserModel model;
  final RemoteEntry entry;
  final bool small;
  final Widget placeholder;
  @override
  State<_RemoteThumbnail> createState() => _RemoteThumbnailState();
}

class _RemoteThumbnailState extends State<_RemoteThumbnail> {
  late final VoidCallback _stopObserving;
  ThumbnailSnapshot? _failedCacheSnapshot;
  @override
  void initState() {
    super.initState();
    _stopObserving = widget.model.observeThumbnail(widget.entry);
  }

  @override
  void dispose() {
    _stopObserving();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ThumbnailSnapshot>(
        valueListenable: widget.model.thumbnailStateFor(widget.entry),
        builder: (context, state, _) {
          final path = state.path;
          if (state.status == ThumbnailStatus.ready && path != null) {
            return Image.file(
              File(path),
              fit: BoxFit.contain,
              cacheWidth: widget.small ? 80 : 500,
              errorBuilder: (context, error, stack) {
                if (!identical(_failedCacheSnapshot, state)) {
                  _failedCacheSnapshot = state;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      widget.model.thumbnailFileUnavailable(
                        widget.entry,
                        expected: state,
                      );
                    }
                  });
                }
                return widget.placeholder;
              },
            );
          }
          if (state.status == ThumbnailStatus.idle) return widget.placeholder;
          final retry =
              state.status == ThumbnailStatus.retryable ||
              state.status == ThumbnailStatus.deferred;
          final label = state.status == ThumbnailStatus.loading
              ? 'Generating preview'
              : state.status == ThumbnailStatus.queued
              ? 'Preview queued'
              : state.status == ThumbnailStatus.unsupported
              ? 'Preview unavailable'
              : state.reason == 'playback_active'
              ? 'Waiting for preview to close'
              : 'Retry preview';
          final message = state.message.isEmpty
              ? '$label for ${widget.entry.name}'
              : state.message;
          if (widget.small) {
            return Tooltip(message: message, child: widget.placeholder);
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              widget.placeholder,
              Positioned(
                right: 5,
                bottom: 5,
                child: Tooltip(
                  message: message,
                  child: retry
                      ? IconButton(
                          tooltip: 'Retry preview for ${widget.entry.name}',
                          style: IconButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0.9),
                          ),
                          onPressed: () =>
                              widget.model.retryThumbnail(widget.entry),
                          icon: const Icon(Icons.refresh_rounded, size: 15),
                          constraints: const BoxConstraints.tightFor(
                            width: 29,
                            height: 29,
                          ),
                          padding: EdgeInsets.zero,
                        )
                      : Semantics(
                          label: '$label for ${widget.entry.name}',
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              state.status == ThumbnailStatus.unsupported
                                  ? Icons.info_outline_rounded
                                  : Icons.more_horiz_rounded,
                              size: 15,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                ),
              ),
            ],
          );
        },
      );
}

class FarshoreApp extends StatefulWidget {
  const FarshoreApp({super.key, required this.model, this.initialize = true});
  final BrowserModel model;
  final bool initialize;
  @override
  State<FarshoreApp> createState() => _FarshoreAppState();
}

class _FarshoreAppState extends State<FarshoreApp> {
  static const _lifecycle = MethodChannel('farshore/lifecycle');
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final PathLauncherCoordinator _pathLauncher;
  @override
  void initState() {
    super.initState();
    _pathLauncher = PathLauncherCoordinator(widget.model, _navigatorKey);
    _lifecycle.setMethodCallHandler((call) async {
      if (call.method == 'flushWorkspace') {
        if (widget.model.workspaceError != null) {
          await widget.model.retryWorkspaceSave();
        } else {
          await widget.model.flushWorkspace();
        }
        return widget.model.workspaceError == null;
      }
      throw MissingPluginException();
    });
    if (widget.initialize) widget.model.initialize();
  }

  @override
  void dispose() {
    _lifecycle.setMethodCallHandler(null);
    _pathLauncher.dispose();
    widget.model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.model.appearance,
    child: BrowserScreen(model: widget.model, launcher: _pathLauncher),
    builder: (context, child) {
      return MaterialApp(
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'Farshore',
        theme: buildShoreTheme(widget.model.theme),
        home: child,
      );
    },
  );
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.model, required this.launcher});
  final BrowserModel model;
  final PathLauncherCoordinator launcher;
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final _browserFocus = FocusNode(debugLabel: 'File browser');
  final _searchFocus = FocusNode(debugLabel: 'Filter files');
  final _search = TextEditingController();
  double _inspectorWidth = 278;
  int _columns = 4;
  String _typed = '';
  Timer? _typeTimer;
  bool _playerOpen = false;
  ({BrowserTab tab, int generation, String path, Offset position})?
  _lastFileDown;
  Timer? _fileTapTimeout, _fileTapMinimum;
  BrowserModel get m => widget.model;
  ShoreColors get c => ShoreColors.forTheme(m.theme);

  @override
  void dispose() {
    _browserFocus.dispose();
    _searchFocus.dispose();
    _search.dispose();
    _typeTimer?.cancel();
    _fileTapTimeout?.cancel();
    _fileTapMinimum?.cancel();
    super.dispose();
  }

  bool get _editing {
    final focus = FocusManager.instance.primaryFocus;
    return focus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
            null ||
        _searchFocus.hasFocus;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isMetaPressed || keyboard.isControlPressed;
    final key = event.logicalKey;
    if (command && key == LogicalKeyboardKey.keyF) {
      if (m.isHome) {
        widget.launcher.open(seed: '/', selectAll: false);
      } else {
        _searchFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    // The app-wide launcher owns these keys, including while a modal is open.
    if ((command && key == LogicalKeyboardKey.keyL) ||
        (!command && !keyboard.isAltPressed && event.character == '/')) {
      return KeyEventResult.ignored;
    }
    if (_editing) return KeyEventResult.ignored;
    if (m.isHome) {
      if (command && key == LogicalKeyboardKey.keyR) {
        _refreshHome();
      } else if (command && key == LogicalKeyboardKey.keyT) {
        _newTab();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyR) {
      m.navigate(m.tab.path, record: false);
    } else if (command && key == LogicalKeyboardKey.keyT) {
      _newTab();
    } else if (command && key == LogicalKeyboardKey.keyW) {
      m.closeTab(m.activeTab);
    } else if (command && key == LogicalKeyboardKey.keyA) {
      m.tab.selection.addAll(m.visibleEntries.map((e) => e.path));
      m.selectionChanged();
    } else if (command &&
        key == LogicalKeyboardKey.keyC &&
        m.selected != null) {
      _copyPaths();
    } else if (key == LogicalKeyboardKey.backspace ||
        (command && key == LogicalKeyboardKey.arrowUp)) {
      m.parent();
    } else if (key == LogicalKeyboardKey.space && m.selected != null) {
      _preview(m.selected!);
    } else if (key == LogicalKeyboardKey.enter && m.selected != null) {
      _activate(m.selected!);
    } else if (key == LogicalKeyboardKey.escape) {
      m.tab.selection.clear();
      m.selectionChanged();
    } else if ({
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    }.contains(key)) {
      final rows = m.view == BrowserView.grid ? _columns : 1;
      final delta = key == LogicalKeyboardKey.arrowUp
          ? -rows
          : key == LogicalKeyboardKey.arrowDown
          ? rows
          : key == LogicalKeyboardKey.arrowLeft
          ? -1
          : 1;
      m.moveSelection(delta, range: keyboard.isShiftPressed);
    } else if (!command &&
        event.character != null &&
        event.character!.isNotEmpty) {
      _typed += event.character!.toLowerCase();
      _typeTimer?.cancel();
      _typeTimer = Timer(const Duration(milliseconds: 750), () => _typed = '');
      final matches = m.visibleEntries.where(
        (e) => e.name.toLowerCase().startsWith(_typed),
      );
      if (matches.isNotEmpty) m.select(matches.first);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _copyPaths() {
    final paths = m.visibleEntries
        .where((e) => m.tab.selection.contains(e.path))
        .map((e) => e.path);
    Clipboard.setData(ClipboardData(text: paths.join('\n')));
  }

  void _select(RemoteEntry entry) {
    _browserFocus.requestFocus();
    m.select(
      entry,
      additive:
          HardwareKeyboard.instance.isMetaPressed ||
          HardwareKeyboard.instance.isControlPressed,
      range: HardwareKeyboard.instance.isShiftPressed,
    );
  }

  void _filePointerDown(RemoteEntry entry, PointerDownEvent event) {
    if (event.buttons & kPrimaryButton == 0) return;
    final previous = _lastFileDown;
    final secondTap =
        previous != null &&
        previous.tab == m.tab &&
        previous.generation == m.tab.generation &&
        previous.path == entry.path &&
        _fileTapTimeout?.isActive == true &&
        _fileTapMinimum?.isActive == false &&
        (previous.position - event.position).distance <= kDoubleTapSlop;
    _fileTapTimeout?.cancel();
    _fileTapMinimum?.cancel();
    if (secondTap) {
      _lastFileDown = null;
      return; // A double-click opens; it must not apply the additive toggle twice.
    }
    _lastFileDown = (
      tab: m.tab,
      generation: m.tab.generation,
      path: entry.path,
      position: event.position,
    );
    _fileTapMinimum = Timer(kDoubleTapMinTime, () {});
    _select(entry);
  }

  void _filePointerUp(RemoteEntry entry) {
    if (_lastFileDown?.path != entry.path) return;
    _fileTapTimeout = Timer(kDoubleTapTimeout, () => _lastFileDown = null);
  }

  void _doubleActivate(RemoteEntry entry) {
    if (!m.tab.selection.contains(entry.path)) m.select(entry, additive: true);
    _activate(entry);
  }

  Future<void> _context(RemoteEntry entry, Offset point) async {
    if (!m.tab.selection.contains(entry.path)) m.select(entry);
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(point.dx, point.dy, point.dx, point.dy),
      items: [
        PopupMenuItem(
          value: 'open',
          child: Text(
            entry.isDirectory
                ? 'Open folder'
                : entry.openIntent == EntryOpenIntent.playInternally
                ? 'Play in Farshore'
                : entry.openIntent == EntryOpenIntent.previewInternally
                ? 'Open in Farshore'
                : 'Open',
          ),
        ),
        if (!entry.isDirectory)
          const PopupMenuItem(value: 'with', child: Text('Open With…')),
        if (!entry.isDirectory)
          const PopupMenuItem(value: 'preview', child: Text('Quick preview')),
        if (entry.kind == FileKind.image || entry.kind == FileKind.video)
          const PopupMenuItem(
            value: 'retry-thumbnail',
            child: Text('Retry thumbnail'),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'copy', child: Text('Copy remote path')),
      ],
    );
    if (!mounted) return;
    switch (value) {
      case 'open':
        await _activate(entry);
      case 'with':
        await _openWith(entry);
      case 'preview':
        _preview(entry);
      case 'retry-thumbnail':
        m.retryThumbnail(entry);
      case 'copy':
        _copyPaths();
    }
  }

  Future<void> _activate(RemoteEntry entry) async {
    if (entry.openIntent == EntryOpenIntent.playInternally) {
      await _play(entry);
    } else if (entry.openIntent == EntryOpenIntent.previewInternally) {
      await _openFilePreview(entry);
    } else {
      await m.openEntry(entry);
    }
  }

  Future<void> _play(RemoteEntry entry) async {
    if (_playerOpen || m.tab.host == null) return;
    _playerOpen = true;
    final hostId = m.tab.host!.id;
    try {
      final openWith = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => FarshoreVideoPlayer(
          bridge: m.bridge,
          hostId: hostId,
          remotePath: entry.path,
          filename: entry.name,
          dark: m.dark,
          audioOnly: entry.kind == FileKind.audio,
          onNavigationGuard: widget.launcher.setMediaNavigationGuard,
          onLeaseRetained: () {
            m.globalError = const BridgeFailure(
              'media_stop_unconfirmed',
              'Playback cleanup could not be confirmed. The connection was kept active to protect any remaining reads.',
            );
            m.changed();
          },
        ),
      );
      if (openWith == true && mounted && !widget.launcher.isOpen) {
        await _openWith(entry);
      }
    } finally {
      _playerOpen = false;
      await m.refreshStatus();
      m.resumeDeferredThumbnailsAfterPlayback();
    }
  }

  Future<void> _openFilePreview(RemoteEntry entry) async {
    if (_playerOpen || entry.isDirectory || m.tab.host == null) return;
    _playerOpen = true;
    final hostId = m.tab.host!.id;
    try {
      final openWith = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => FilePreviewDialog(
          bridge: m.bridge,
          hostId: hostId,
          remotePath: entry.path,
          filename: entry.name,
          onNavigationGuard: widget.launcher.setMediaNavigationGuard,
          onLeaseRetained: () {
            m.globalError = const BridgeFailure(
              'preview_close_unconfirmed',
              'Preview cleanup could not be confirmed. Its temporary file was kept available until Farshore closes.',
            );
            m.changed();
          },
        ),
      );
      if (openWith == true && mounted && !widget.launcher.isOpen) {
        await _openWith(entry);
      }
    } finally {
      _playerOpen = false;
      await m.refreshStatus();
      m.resumeDeferredThumbnailsAfterPlayback();
    }
  }

  Future<void> _openWith(RemoteEntry entry) async {
    final future = m.applications(entry);
    var remember = false;
    if (!mounted) return;
    final app = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Open With'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 16),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: future,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Text(
                        BrowserModel.failure(snapshot.error!).message,
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    return ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.open_in_new_rounded),
                            title: const Text('System default'),
                            dense: true,
                            onTap: () => Navigator.pop(context, 'default'),
                          ),
                          for (final app in snapshot.data!)
                            ListTile(
                              leading: const Icon(Icons.apps_rounded),
                              dense: true,
                              title: Text(
                                app['name'] as String? ?? 'Application',
                              ),
                              onTap: () =>
                                  Navigator.pop(context, app['id'] as String),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.folder_open_rounded),
                  dense: true,
                  title: const Text('Choose Application…'),
                  onTap: () => Navigator.pop(context, 'choose'),
                ),
                CheckboxListTile(
                  value: remember,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    'Remember for .${entry.extension.isEmpty ? 'this file type' : entry.extension} in Farshore',
                  ),
                  onChanged: (value) =>
                      setDialogState(() => remember = value ?? false),
                ),
                Text(
                  'Opens through a read-only mounted path. Applications may read or buffer data.',
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    if (app == null) return;
    await m.openEntry(
      entry,
      applicationId: app == 'default' || app == 'choose' ? null : app,
      remember: remember,
      choose: app == 'choose',
      systemDefault: app == 'default',
    );
  }

  void _preview(RemoteEntry entry) {
    if (entry.openIntent == EntryOpenIntent.playInternally) {
      _play(entry);
      return;
    }
    _openFilePreview(entry);
  }

  Future<void> _enterPath() => widget.launcher.open(seed: m.tab.path);

  void _showHome() {
    _searchFocus.unfocus();
    _browserFocus.requestFocus();
    m.showHome();
  }

  void _resumeTab(int index) {
    m.activateTab(index, preserveQuery: index == m.activeTab);
    _search.text = m.query;
    _browserFocus.requestFocus();
  }

  Future<void> _openServer(RemoteHost host) async {
    await m.selectHost(host);
    if (!mounted) return;
    _search.text = m.query;
    if (!m.isHome) _browserFocus.requestFocus();
  }

  void _newTab() {
    if (m.isHome && m.tab.host == null) {
      widget.launcher.open(seed: '/', selectAll: false);
    } else {
      m.addTab();
    }
  }

  Future<void> _refreshHome() async {
    await Future.wait([m.discover(), m.refreshStatus()]);
  }

  void _showActivity() {
    m.activityExpanded = true;
    m.changed();
  }

  void _cancelFolderRequest() {
    final bridge = m.bridge;
    if (bridge is BridgeRecovery) {
      (bridge as BridgeRecovery).cancelRecovery();
    }
    m.cancelNavigation();
  }

  Widget _recoveryBanner() {
    final bridge = m.bridge;
    if (bridge is! BridgeRecovery) return const SizedBox.shrink();
    final recovery = bridge as BridgeRecovery;
    return ValueListenableBuilder<BridgeRecoveryState>(
      valueListenable: recovery.recovery,
      builder: (context, state, _) {
        if (state.phase != BridgeRecoveryPhase.retrying) {
          return const SizedBox.shrink();
        }
        return Container(
          color: c.selection,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${state.message} Attempt ${state.attempt} of 2',
                  style: TextStyle(color: c.ink, fontSize: 11),
                ),
              ),
              TextButton(
                onPressed: recovery.cancelRecovery,
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([m, m.appearance, m.settingsChanges]),
    builder: (context, _) => Scaffold(
      body: Focus(
        focusNode: _browserFocus,
        autofocus: true,
        onKeyEvent: _key,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 1030;
            final showInspector = m.inspector && constraints.maxWidth >= 900;
            return Row(
              children: [
                _sidebar(narrow ? 190 : 220),
                Expanded(
                  child: Column(
                    children: [
                      _tabs(),
                      _recoveryBanner(),
                      if (!m.isHome) _toolbar(narrow),
                      if (m.globalError != null)
                        _error(
                          m.globalError!,
                          onRetry: () {
                            m.globalError = null;
                            m.changed();
                          },
                          retryText: 'Dismiss',
                        ),
                      if (m.isHome)
                        Expanded(
                          child: FarshoreHomePage(
                            model: m,
                            onOpenServer: _openServer,
                            onOpenRecent: widget.launcher.openRecent,
                            onResumeTab: _resumeTab,
                            onOpenPath: () => widget.launcher.open(
                              seed: '/',
                              selectAll: false,
                            ),
                            onRefreshConnections: _refreshHome,
                            onShowActivity: _showActivity,
                          ),
                        )
                      else
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    _folderHeading(),
                                    _thumbnailBatchControls(),
                                    if (m.tab.error != null)
                                      _error(
                                        m.tab.error!,
                                        onRetry: () => m.navigate(
                                          m.tab.path,
                                          record: false,
                                        ),
                                      ),
                                    if (m.tab.loading)
                                      LinearProgressIndicator(
                                        minHeight: 2,
                                        color: c.accent,
                                        backgroundColor: c.line,
                                      ),
                                    Expanded(
                                      child: AnimatedBuilder(
                                        animation: m.selectionChanges,
                                        builder: (context, _) => _content(),
                                      ),
                                    ),
                                    AnimatedBuilder(
                                      animation: m.selectionChanges,
                                      builder: (context, _) => _statusBar(),
                                    ),
                                  ],
                                ),
                              ),
                              if (showInspector)
                                MouseRegion(
                                  cursor: SystemMouseCursors.resizeLeftRight,
                                  child: GestureDetector(
                                    onHorizontalDragUpdate: (event) => setState(
                                      () => _inspectorWidth =
                                          (_inspectorWidth - event.delta.dx)
                                              .clamp(230, 400),
                                    ),
                                    child: Container(
                                      width: 5,
                                      color: c.line.withValues(alpha: 0.45),
                                    ),
                                  ),
                                ),
                              if (showInspector)
                                SizedBox(
                                  width: _inspectorWidth,
                                  child: AnimatedBuilder(
                                    animation: m.selectionChanges,
                                    builder: (context, _) => _inspector(),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      _activity(),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _sidebar(double width) => AnimatedBuilder(
    animation: m.hostChanges,
    builder: (context, _) => _sidebarContent(width),
  );

  Widget _sidebarContent(double width) => Container(
    key: const ValueKey('farshore-sidebar'),
    width: width,
    decoration: BoxDecoration(
      color: c.sidebar,
      border: Border(right: BorderSide(color: c.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(23, 32, 20, 28),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Image.asset(
                  'assets/branding/farshore-mark.png',
                  width: 32,
                  height: 32,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'farshore',
                    style: TextStyle(
                      fontSize: 23,
                      letterSpacing: -1.1,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 22),
          child: Semantics(
            label: 'Go to Farshore Home',
            button: true,
            selected: m.isHome,
            onTap: _showHome,
            excludeSemantics: true,
            child: Tooltip(
              message: 'Go to Farshore Home',
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: ListTile(
                  selected: m.isHome,
                  selectedTileColor: c.selection,
                  selectedColor: c.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  leading: const Icon(Icons.home_outlined, size: 19),
                  title: const Text('Home', style: TextStyle(fontSize: 12)),
                  onTap: _showHome,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Expanded(child: _eyebrow('CONNECTIONS')),
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  tooltip: 'Refresh SSH aliases',
                  onPressed: m.discovering ? null : m.discover,
                  icon: Icon(Icons.refresh_rounded, size: 15, color: c.muted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 11),
        Expanded(
          child: m.discovering
              ? Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.accent,
                    ),
                  ),
                )
              : m.hosts.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No SSH aliases found.\nAdd a Host entry to your existing SSH config, then refresh.',
                    style: TextStyle(color: c.muted, height: 1.6, fontSize: 12),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: [for (final host in m.orderedHosts) _host(host)],
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded, color: c.muted, size: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Read-only beta',
                        style: TextStyle(
                          fontSize: 11,
                          color: c.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (MediaQuery.textScalerOf(context).scale(10) <= 14) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Your SSH. Your files.\nExisting trust stays intact.',
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.5,
                            color: c.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 17),
          child: Row(
            children: [
              Icon(Icons.circle, size: 5, color: c.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'FARSHORE 0.2',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 8,
                    letterSpacing: 1.1,
                    color: c.muted,
                  ),
                ),
              ),
              _icon(
                Icons.palette_outlined,
                'Choose theme',
                () => showThemePicker(context, m),
              ),
              _icon(
                Icons.settings_outlined,
                'Settings',
                () => showSettingsDialog(
                  context,
                  m,
                  onOpenFolder: widget.launcher.openRecent,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _host(RemoteHost host) {
    final active = !m.isHome && m.tab.host?.id == host.id;
    final favorite = m.favoriteHostIds.contains(host.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: active ? c.selection : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openServer(host),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
            child: Row(
              children: [
                Icon(
                  Icons.dns_outlined,
                  size: 18,
                  color: active ? c.accent : c.muted,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        host.alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        active && m.tab.loading
                            ? 'Connecting…'
                            : active && m.tab.error != null
                            ? 'Connection needs attention'
                            : active && m.tab.fresh
                            ? 'Current location'
                            : 'SSH configuration',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 9, color: c.muted),
                      ),
                    ],
                  ),
                ),
                if (active)
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: m.tab.error != null ? Colors.orange : c.accent,
                    ),
                  ),
                SizedBox(
                  width: 27,
                  height: 29,
                  child: IconButton(
                    tooltip: favorite
                        ? 'Remove ${host.alias} from favorites'
                        : 'Favorite ${host.alias}',
                    padding: EdgeInsets.zero,
                    isSelected: favorite,
                    selectedIcon: Icon(
                      Icons.star_rounded,
                      size: 16,
                      color: c.accent,
                    ),
                    icon: Icon(
                      Icons.star_outline_rounded,
                      size: 16,
                      color: c.muted,
                    ),
                    onPressed: () => m.toggleFavorite(host),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabs() => Container(
    height: 52,
    decoration: BoxDecoration(
      color: c.sidebar.withValues(alpha: 0.35),
      border: Border(bottom: BorderSide(color: c.line)),
    ),
    child: Row(
      children: [
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(17, 10, 0, 0),
            children: [
              _homeTab(),
              for (var i = 0; i < m.tabs.length; i++)
                if (m.tabs[i].host != null || !m.isHome) _tab(i),
              Padding(
                padding: const EdgeInsets.only(left: 5, bottom: 7),
                child: _icon(Icons.add_rounded, 'New tab · ⌘T', _newTab),
              ),
            ],
          ),
        ),
        if (!m.isHome)
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: _icon(
              Icons.vertical_split_outlined,
              m.inspector ? 'Hide inspector' : 'Show inspector',
              () {
                m.inspector = !m.inspector;
                m.changed();
              },
            ),
          ),
      ],
    ),
  );

  Widget _homeTab() => Padding(
    padding: const EdgeInsets.only(right: 5),
    child: Material(
      color: m.isHome ? c.canvas : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        side: BorderSide(color: m.isHome ? c.line : Colors.transparent),
      ),
      child: Semantics(
        label: 'Farshore Home tab',
        button: true,
        selected: m.isHome,
        onTap: _showHome,
        excludeSemantics: true,
        child: Tooltip(
          message: 'Farshore Home tab',
          child: InkWell(
            onTap: _showHome,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Row(
                children: [
                  Icon(
                    Icons.home_outlined,
                    size: 15,
                    color: m.isHome ? c.accent : c.muted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Home',
                    style: TextStyle(
                      fontSize: 10,
                      color: m.isHome ? c.ink : c.muted,
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

  Widget _tab(int index) {
    final tab = m.tabs[index];
    final active = !m.isHome && index == m.activeTab;
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Material(
        color: active ? c.canvas : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          side: BorderSide(color: active ? c.line : Colors.transparent),
        ),
        child: InkWell(
          onTap: () => _resumeTab(index),
          child: SizedBox(
            width: 196,
            child: Padding(
              padding: const EdgeInsets.only(left: 13, right: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 14,
                    color: active ? c.accent : c.muted,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      tab.host == null
                          ? 'New connection'
                          : '${tab.path.isEmpty
                                ? 'Home'
                                : tab.path == '/'
                                ? 'Root'
                                : tab.path.split('/').last} · ${tab.host!.alias}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: active ? c.ink : c.muted,
                      ),
                    ),
                  ),
                  if (m.tabs.length > 1)
                    SizedBox(
                      width: 26,
                      child: IconButton(
                        tooltip: 'Close tab',
                        padding: EdgeInsets.zero,
                        onPressed: () => m.closeTab(index),
                        icon: Icon(Icons.close, size: 12, color: c.muted),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(bool narrow) => Container(
    height: 67,
    padding: const EdgeInsets.symmetric(horizontal: 19),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: c.line)),
    ),
    child: Row(
      children: [
        _icon(
          Icons.arrow_back_rounded,
          'Back',
          m.tab.back.isEmpty ? null : m.goBack,
        ),
        _icon(
          Icons.arrow_forward_rounded,
          'Forward',
          m.tab.forward.isEmpty ? null : m.goForward,
        ),
        const SizedBox(width: 9),
        _locationButton('SSH Home', 'Go to SSH home folder', ''),
        _locationButton('Root', 'Go to filesystem root /', '/'),
        const SizedBox(width: 7),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _crumb(
                  m.tab.host == null
                      ? 'Connections'
                      : m.tab.path.startsWith('/')
                      ? 'Root'
                      : 'Home',
                  () => m.navigate(m.tab.path.startsWith('/') ? '/' : ''),
                  icon: m.tab.path.startsWith('/')
                      ? Icons.storage_outlined
                      : Icons.home_outlined,
                ),
                for (final part in _breadcrumbs()) ...[
                  Icon(Icons.chevron_right_rounded, size: 14, color: c.muted),
                  _crumb(part.$1, () => m.navigate(part.$2)),
                ],
                if (m.tab.host != null)
                  _icon(
                    Icons.edit_outlined,
                    'Go to folder… · ⌘L',
                    _enterPath,
                    size: 14,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: narrow ? 156 : 210,
          height: 34,
          child: TextField(
            controller: _search,
            focusNode: _searchFocus,
            style: const TextStyle(fontSize: 11),
            onChanged: (value) {
              m.query = value;
              m.changed();
            },
            decoration: InputDecoration(
              hintText: 'Filter this folder',
              hintStyle: TextStyle(fontSize: 11, color: c.muted),
              prefixIcon: Icon(Icons.search_rounded, size: 15, color: c.muted),
              prefixIconConstraints: const BoxConstraints(minWidth: 31),
              suffixIcon: m.query.isNotEmpty
                  ? IconButton(
                      tooltip: 'Clear filter',
                      onPressed: () {
                        _search.clear();
                        m.query = '';
                        m.changed();
                      },
                      icon: const Icon(Icons.close, size: 13),
                    )
                  : null,
              filled: true,
              fillColor: c.soft,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: BorderSide(color: c.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          height: 30,
          decoration: BoxDecoration(
            color: c.soft,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              _viewButton(
                BrowserView.grid,
                Icons.grid_view_rounded,
                'Grid view',
              ),
              _viewButton(
                BrowserView.list,
                Icons.view_list_rounded,
                'List view',
              ),
              _viewButton(
                BrowserView.gallery,
                Icons.view_carousel_outlined,
                'Gallery view',
              ),
            ],
          ),
        ),
      ],
    ),
  );

  List<(String, String)> _breadcrumbs() {
    final parts = m.tab.path.split('/').where((p) => p.isNotEmpty).toList();
    final absolute = m.tab.path.startsWith('/');
    return [
      for (var i = 0; i < parts.length; i++)
        (parts[i], '${absolute ? '/' : ''}${parts.take(i + 1).join('/')}'),
    ];
  }

  Widget _locationButton(String label, String tooltip, String path) => Tooltip(
    message: tooltip,
    child: TextButton(
      onPressed: m.tab.host == null ? null : () => m.navigate(path),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 7),
        foregroundColor: c.muted,
      ),
      child: Text(label, style: const TextStyle(fontSize: 10)),
    ),
  );

  Widget _crumb(
    String text,
    VoidCallback onTap, {
    IconData? icon,
  }) => TextButton(
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      minimumSize: const Size(0, 30),
      foregroundColor: c.ink,
    ),
    onPressed: m.tab.host == null ? null : onTap,
    child: Row(
      children: [
        if (icon != null) ...[Icon(icon, size: 14), const SizedBox(width: 7)],
        Text(text, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );

  Widget _viewButton(BrowserView view, IconData icon, String label) => Tooltip(
    message: label,
    child: Semantics(
      button: true,
      selected: m.view == view,
      label: label,
      child: InkWell(
        onTap: () {
          m.view = view;
          m.changed();
        },
        child: Container(
          width: 31,
          height: 27,
          margin: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            color: m.view == view ? c.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 15,
            color: m.view == view ? c.accent : c.muted,
          ),
        ),
      ),
    ),
  );

  Widget _folderHeading() {
    final path = m.tab.path;
    final name = path.isEmpty
        ? 'Home'
        : path == '/'
        ? 'Root'
        : path.split('/').last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(27, 22, 19, 17),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.tab.host == null ? 'Your next connection' : name,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.9,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  m.tab.host == null
                      ? 'Familiar hosts. A little closer.'
                      : '${m.visibleEntries.length} items${m.query.isNotEmpty || m.kindFilter != null ? ' matching filter' : ''}  ·  ${m.tab.host!.alias}${!m.tab.fresh ? '  ·  stale metadata' : ''}',
                  style: TextStyle(fontSize: 10, color: c.muted),
                ),
              ],
            ),
          ),
          if (m.tab.host != null)
            _icon(
              m.isFavoritePath(m.tab.host!.id, m.tab.path)
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              m.isFavoritePath(m.tab.host!.id, m.tab.path)
                  ? 'Remove favorite folder'
                  : 'Favorite this folder',
              () => m.setFavoritePath(
                m.tab.host!.id,
                m.tab.path,
                !m.isFavoritePath(m.tab.host!.id, m.tab.path),
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'Filter by file type',
            icon: Icon(
              Icons.filter_list_rounded,
              size: 18,
              color: m.kindFilter == null ? c.muted : c.accent,
            ),
            onSelected: (value) {
              m.kindFilter = value == 'all'
                  ? null
                  : FileKind.values.byName(value);
              m.changed();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'all', child: Text('All types')),
              for (final kind in FileKind.values)
                PopupMenuItem(
                  value: kind.name,
                  child: Text(
                    '${kind.name[0].toUpperCase()}${kind.name.substring(1)}',
                  ),
                ),
            ],
          ),
          PopupMenuButton<EntrySort>(
            tooltip: 'Sort files',
            icon: Icon(Icons.sort_rounded, size: 17, color: c.muted),
            onSelected: (value) {
              m.sort = value;
              m.changed();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: EntrySort.name, child: Text('Name')),
              const PopupMenuItem(
                value: EntrySort.newest,
                child: Text('Newest first'),
              ),
              const PopupMenuItem(
                value: EntrySort.largest,
                child: Text('Largest first'),
              ),
            ],
          ),
          _icon(
            m.showHidden
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            m.showHidden ? 'Hide hidden files' : 'Show hidden files',
            () {
              m.showHidden = !m.showHidden;
              m.changed();
            },
            size: 17,
          ),
          _icon(
            m.tab.loading ? Icons.close_rounded : Icons.refresh_rounded,
            m.tab.loading ? 'Cancel folder request' : 'Refresh folder · ⌘R',
            m.tab.host == null
                ? null
                : m.tab.loading
                ? _cancelFolderRequest
                : () => m.navigate(m.tab.path, record: false),
            size: 17,
          ),
        ],
      ),
    );
  }

  Widget _thumbnailBatchControls() {
    final count = m.tab.videoEntries.length;
    if (m.tab.host == null || count == 0) return const SizedBox.shrink();
    return ValueListenableBuilder<ThumbnailBatchProgress?>(
      valueListenable: m.thumbnailBatch,
      builder: (context, batch, _) {
        final current =
            batch != null &&
            identical(batch.tab, m.tab) &&
            batch.generation == m.tab.generation;
        return Container(
          padding: const EdgeInsets.fromLTRB(27, 0, 19, 11),
          child: current
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            liveRegion: false,
                            child: Text(
                              '${batch.ready} / ${batch.total} video thumbnails ready'
                              '${batch.cancelled
                                  ? ' · folder generation canceled'
                                  : batch.waitingForPlayback && batch.running
                                  ? ' · waiting for preview to close'
                                  : batch.failed > 0
                                  ? ' · ${batch.failed} need retry'
                                  : ''}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.muted,
                                fontSize: 10,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ),
                        if (batch.running)
                          TextButton(
                            onPressed: m.cancelThumbnailBatch,
                            child: const Text(
                              'Cancel generation',
                              style: TextStyle(fontSize: 10),
                            ),
                          )
                        else if (batch.ready < batch.total)
                          TextButton(
                            onPressed: () =>
                                m.generateVideoThumbnails(retryMissing: true),
                            child: const Text(
                              'Retry missing',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                    if (batch.cancelled && batch.inFlight > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(
                          '${batch.inFlight} preview request finishing',
                          style: TextStyle(color: c.muted, fontSize: 9),
                        ),
                      ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: batch.total == 0 ? 0 : batch.ready / batch.total,
                        minHeight: 2,
                        color: c.accent,
                        backgroundColor: c.line,
                      ),
                    ),
                  ],
                )
              : Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('generate-video-thumbnails'),
                    onPressed: m.tab.loading
                        ? null
                        : () => m.generateVideoThumbnails(),
                    icon: const Icon(Icons.photo_library_outlined, size: 15),
                    label: Text(
                      'Generate video thumbnails ($count)',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                ),
        );
      },
    );
  }

  Widget _content() {
    if (m.tab.needsLoad) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open_outlined, color: c.accent, size: 36),
              const SizedBox(height: 18),
              Text(
                'Saved folder',
                style: TextStyle(color: c.ink, fontSize: 20),
              ),
              const SizedBox(height: 10),
              Text(
                m.tab.hostUnavailable
                    ? 'This SSH alias is unavailable. Refresh your connections after restoring it.'
                    : 'Your workspace is restored. Connect when you are ready.',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: m.tab.hostUnavailable
                    ? m.discover
                    : () => m.activateTab(m.activeTab),
                icon: Icon(
                  m.tab.hostUnavailable
                      ? Icons.refresh
                      : Icons.play_arrow_rounded,
                ),
                label: Text(
                  m.tab.hostUnavailable
                      ? 'Refresh connections'
                      : 'Connect to saved folder',
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (m.tab.host == null) {
      return _empty(
        Icons.travel_explore_rounded,
        'A window to your other machines',
        'Choose an SSH alias in the sidebar to browse its home folder.\nConnections use your existing authentication and verified host keys.',
      );
    }
    if (m.tab.loading && m.tab.entries.isEmpty) {
      return _empty(
        Icons.folder_open_rounded,
        'Opening this shore…',
        'Reading folder metadata through your existing SSH connection.',
      );
    }
    final entries = m.visibleEntries;
    if (entries.isEmpty) {
      return _empty(
        m.query.isNotEmpty || m.kindFilter != null
            ? Icons.search_off_rounded
            : Icons.folder_open_rounded,
        m.tab.error != null
            ? 'This folder could not be reached'
            : m.query.isNotEmpty || m.kindFilter != null
            ? 'No matching files'
            : 'A little quiet here',
        m.tab.error != null
            ? 'Your location is preserved. Resolve the error above and retry.'
            : m.query.isNotEmpty || m.kindFilter != null
            ? 'Try another name or file type. The filter only searches this folder.'
            : 'This folder has no visible items.',
      );
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        _columns = math.max(1, (bounds.maxWidth / m.tileSize).floor());
        return switch (m.view) {
          BrowserView.grid => GridView.builder(
            key: PageStorageKey('grid:${m.tab.host!.id}:${m.tab.path}'),
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _columns,
              childAspectRatio: 0.9,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: entries.length,
            itemBuilder: (context, index) => _tile(entries[index]),
          ),
          BrowserView.list => _list(entries),
          BrowserView.gallery => Column(
            children: [
              Expanded(
                child: m.selected == null
                    ? _empty(
                        Icons.panorama_outlined,
                        'Select a file to take a closer look',
                        'Use the filmstrip below or the arrow keys.',
                      )
                    : Padding(
                        padding: const EdgeInsets.all(22),
                        child: _previewContent(m.selected!, large: true),
                      ),
              ),
              SizedBox(
                height: 134,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  itemCount: entries.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 8),
                  itemBuilder: (context, index) => SizedBox(
                    width: 110,
                    child: _tile(entries[index], compact: true),
                  ),
                ),
              ),
            ],
          ),
        };
      },
    );
  }

  Widget _tile(RemoteEntry entry, {bool compact = false}) {
    final selected = m.tab.selection.contains(entry.path);
    return Semantics(
      label:
          '${entry.name}, ${entry.isDirectory ? 'folder' : formatBytes(entry.size)}',
      selected: selected,
      button: true,
      onTap: () {
        _select(entry);
        _activate(entry);
      },
      child: Listener(
        onPointerDown: (event) => _filePointerDown(entry, event),
        onPointerUp: (_) => _filePointerUp(entry),
        child: GestureDetector(
          excludeFromSemantics: true,
          onDoubleTap: () => _doubleActivate(entry),
          onSecondaryTapDown: (event) => _context(entry, event.globalPosition),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: selected ? c.selection : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? c.accent.withValues(alpha: 0.65)
                      : Colors.transparent,
                ),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: entry.isDirectory ? Colors.transparent : c.soft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: _thumbnail(entry),
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 6 : 10),
                  Text(
                    entry.name,
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 9 : 11,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      height: 1.35,
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry.isDirectory ? 'Folder' : formatBytes(entry.size),
                      style: TextStyle(fontSize: 9, color: c.muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _list(List<RemoteEntry> entries) => Column(
    children: [
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 25),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        child: Row(
          children: [
            Expanded(child: _eyebrow('NAME')),
            SizedBox(width: 100, child: _eyebrow('KIND')),
            SizedBox(width: 75, child: _eyebrow('SIZE')),
          ],
        ),
      ),
      Expanded(
        child: ListView.builder(
          key: PageStorageKey('list:${m.tab.host!.id}:${m.tab.path}'),
          padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 5),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final e = entries[index];
            final selected = m.tab.selection.contains(e.path);
            return Semantics(
              selected: selected,
              button: true,
              label: e.name,
              onTap: () {
                _select(e);
                _activate(e);
              },
              child: Listener(
                onPointerDown: (event) => _filePointerDown(e, event),
                onPointerUp: (_) => _filePointerUp(e),
                child: GestureDetector(
                  excludeFromSemantics: true,
                  onDoubleTap: () => _doubleActivate(e),
                  onSecondaryTapDown: (event) =>
                      _context(e, event.globalPosition),
                  child: Container(
                    height: 43,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? c.selection
                          : index.isEven
                          ? c.soft.withValues(alpha: 0.4)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 27,
                          height: 27,
                          child: _thumbnail(e, small: true),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(
                            e.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        SizedBox(
                          width: 100,
                          child: Text(
                            e.kind.name,
                            style: TextStyle(fontSize: 10, color: c.muted),
                          ),
                        ),
                        SizedBox(
                          width: 75,
                          child: Text(
                            e.isDirectory ? '—' : formatBytes(e.size),
                            style: TextStyle(fontSize: 10, color: c.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget _thumbnail(RemoteEntry entry, {bool small = false}) =>
      _RemoteThumbnail(
        key: ValueKey((m.tab, m.tab.generation, m.thumbnailKey(entry))),
        model: m,
        entry: entry,
        small: small,
        placeholder: _fileIcon(entry, small),
      );

  Widget _fileIcon(RemoteEntry entry, bool small) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          switch (entry.kind) {
            FileKind.folder => Icons.folder_rounded,
            FileKind.image => Icons.image_outlined,
            FileKind.video => Icons.movie_outlined,
            FileKind.audio => Icons.audio_file_outlined,
            FileKind.document => Icons.description_outlined,
            FileKind.other => Icons.insert_drive_file_outlined,
          },
          size: small
              ? 21
              : entry.isDirectory
              ? 68
              : 41,
          color: entry.isDirectory
              ? c.accent.withValues(alpha: 0.68)
              : c.muted.withValues(alpha: 0.6),
        ),
        if (!small && !entry.isDirectory && entry.extension.isNotEmpty) ...[
          const SizedBox(height: 9),
          Text(
            entry.extension.toUpperCase(),
            style: TextStyle(fontSize: 8, letterSpacing: 1.2, color: c.muted),
          ),
        ],
      ],
    ),
  );

  Widget _previewContent(RemoteEntry entry, {bool large = false}) {
    if (entry.openIntent == EntryOpenIntent.playInternally) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              entry.kind == FileKind.audio
                  ? Icons.audio_file_outlined
                  : Icons.movie_outlined,
              size: large ? 48 : 32,
              color: c.muted,
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => _play(entry),
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: const Text(
                'Play in Farshore',
                style: TextStyle(fontSize: 11),
              ),
            ),
            if (large)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'VideoLAN LibVLC · streamed over SSH',
                  style: TextStyle(fontSize: 10, color: c.muted),
                ),
              ),
          ],
        ),
      );
    }
    if (entry.kind == FileKind.image) {
      return SizedBox.expand(child: _thumbnail(entry));
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _fileIcon(entry, false),
          const SizedBox(height: 22),
          if (entry.openIntent == EntryOpenIntent.previewInternally)
            OutlinedButton.icon(
              onPressed: () => _openFilePreview(entry),
              icon: const Icon(Icons.visibility_outlined, size: 16),
              label: const Text(
                'Open in Farshore',
                style: TextStyle(fontSize: 11),
              ),
            )
          else
            Text(
              entry.isDirectory
                  ? 'Folder'
                  : 'Open in your preferred application',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: large ? 14 : 11, color: c.muted),
            ),
        ],
      ),
    );
  }

  Widget _inspector() => Container(
    color: c.surface.withValues(alpha: 0.5),
    child: m.selected == null
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(23),
                child: _eyebrow('INSPECTOR'),
              ),
              Expanded(
                child: _empty(
                  Icons.touch_app_outlined,
                  'A closer look',
                  'Select a file to view its details\nand available preview.',
                ),
              ),
            ],
          )
        : _inspectorEntry(m.selected!),
  );

  Widget _inspectorEntry(RemoteEntry e) => ListView(
    padding: const EdgeInsets.all(23),
    children: [
      Row(
        children: [
          _eyebrow('INSPECTOR'),
          const Spacer(),
          _icon(
            Icons.open_in_full_rounded,
            'Quick preview · Space',
            () => _preview(e),
            size: 14,
          ),
        ],
      ),
      const SizedBox(height: 20),
      Container(
        height: 190,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: c.soft,
          borderRadius: BorderRadius.circular(9),
        ),
        child: _previewContent(e),
      ),
      const SizedBox(height: 22),
      SelectableText(
        e.name,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w500,
          height: 1.35,
          letterSpacing: -0.3,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        e.isDirectory
            ? 'Remote folder'
            : '${e.extension.isEmpty ? e.kind.name : e.extension.toUpperCase()} file',
        style: TextStyle(fontSize: 11, color: c.muted),
      ),
      const SizedBox(height: 22),
      Divider(color: c.line),
      const SizedBox(height: 15),
      _detail('Size', e.isDirectory ? '—' : formatBytes(e.size)),
      _detail('Modified', _date(e.modified)),
      _detail('Host', m.tab.host!.alias),
      _detail('Access', 'Read only'),
      const SizedBox(height: 12),
      _eyebrow('REMOTE PATH'),
      const SizedBox(height: 8),
      SelectableText(
        e.path,
        style: TextStyle(fontSize: 10, height: 1.7, color: c.muted),
      ),
      const SizedBox(height: 22),
      FilledButton.icon(
        onPressed: m.opening ? null : () => _activate(e),
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.canvas,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        icon: Icon(
          e.isDirectory
              ? Icons.folder_open_rounded
              : e.openIntent == EntryOpenIntent.playInternally
              ? Icons.play_arrow_rounded
              : e.openIntent == EntryOpenIntent.previewInternally
              ? Icons.visibility_outlined
              : Icons.open_in_new_rounded,
          size: 15,
        ),
        label: Text(
          m.opening
              ? 'Opening…'
              : e.isDirectory
              ? 'Open folder'
              : e.openIntent == EntryOpenIntent.playInternally
              ? 'Play in Farshore'
              : e.openIntent == EntryOpenIntent.previewInternally
              ? 'Open in Farshore'
              : 'Open',
          style: const TextStyle(fontSize: 11),
        ),
      ),
      if (!e.isDirectory) ...[
        const SizedBox(height: 7),
        OutlinedButton(
          onPressed: m.opening ? null : () => _openWith(e),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: c.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: const Text('Open With…', style: TextStyle(fontSize: 11)),
        ),
        const SizedBox(height: 15),
        Text(
          e.openIntent == EntryOpenIntent.playInternally
              ? 'Play inside Farshore, or choose another application with Open With.'
              : e.openIntent == EntryOpenIntent.previewInternally
              ? 'Preview inside Farshore. Open With is available for another application or unsupported files.'
              : 'External apps receive a read-only mounted path. Read and cache metrics appear in Activity when available.',
          style: TextStyle(fontSize: 9, color: c.muted, height: 1.6),
        ),
      ],
    ],
  );

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 13),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 65,
          child: Text(label, style: TextStyle(fontSize: 10, color: c.muted)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 10),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );

  String _date(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return value.isEmpty ? 'Unavailable' : value;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  Widget _statusBar() => Container(
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 27),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: c.line)),
    ),
    child: Row(
      children: [
        Text(
          m.tab.selection.isEmpty
              ? '${m.visibleEntries.length} items'
              : '${m.tab.selection.length} selected',
          style: TextStyle(fontSize: 9, color: c.muted),
        ),
        const Spacer(),
        if (m.view == BrowserView.grid) ...[
          Icon(Icons.grid_view_rounded, size: 11, color: c.muted),
          SizedBox(
            width: 100,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: FarshoreSlider(
                child: Slider(
                  semanticFormatterCallback: (v) =>
                      'Thumbnail size ${v.round()}',
                  value: m.tileSize,
                  min: 125,
                  max: 240,
                  activeColor: c.accent,
                  onChanged: (value) {
                    m.tileSize = value;
                    m.changed();
                  },
                ),
              ),
            ),
          ),
          Icon(Icons.grid_view_rounded, size: 15, color: c.muted),
        ],
      ],
    ),
  );

  Widget _activity() => ValueListenableBuilder<Map<String, dynamic>>(
    valueListenable: m.statusChanges,
    builder: (context, status, child) => _activityContent(),
  );

  Widget _activityContent() {
    final cache = m.status['cache'] as Map? ?? {};
    final events = m.status['activity'] as List? ?? [];
    final mounts = m.status['mounts'] as List? ?? [];
    return Container(
      decoration: BoxDecoration(
        color: c.sidebar.withValues(alpha: 0.6),
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () {
              m.activityExpanded = !m.activityExpanded;
              m.changed();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 11),
              child: Row(
                children: [
                  Icon(
                    m.activityExpanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_up_rounded,
                    size: 16,
                    color: c.muted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Activity',
                    style: TextStyle(fontSize: 10, color: c.ink),
                  ),
                  const SizedBox(width: 10),
                  if (m.opening)
                    Text(
                      'Preparing mounted access…',
                      style: TextStyle(fontSize: 9, color: c.accent),
                    ),
                  const Spacer(),
                  Text(
                    'Read-only SSH',
                    style: TextStyle(fontSize: 9, color: c.muted),
                  ),
                  const SizedBox(width: 18),
                  Icon(Icons.shield_outlined, size: 12, color: c.accent),
                ],
              ),
            ),
          ),
          if (m.activityExpanded)
            Container(
              height: 174,
              padding: const EdgeInsets.fromLTRB(27, 0, 27, 15),
              child: ListView(
                children: [
                  const SizedBox(height: 3),
                  Text(
                    'Thumbnail cache: ${formatBytes((cache['bytesUsed'] as num? ?? 0).toInt())} / ${formatBytes((cache['budgetBytes'] as num? ?? 0).toInt())}',
                    style: TextStyle(fontSize: 10, color: c.muted),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'SFTP payload read: ${m.status['readBytes'] == null ? 'measurement unavailable' : formatBytes((m.status['readBytes'] as num).toInt())}  ·  Media disk cache: ${m.status['mediaDiskCache'] ?? 'unavailable'}',
                    style: TextStyle(fontSize: 10, color: c.muted),
                  ),
                  for (final mount in mounts)
                    Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Text(
                        'Mount ${mount['state']}: ${mount['path']}',
                        style: TextStyle(fontSize: 10, color: c.muted),
                      ),
                    ),
                  if (events.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 17),
                      child: Text(
                        'No external opening activity yet.',
                        style: TextStyle(fontSize: 10, color: c.muted),
                      ),
                    ),
                  for (final event in events.reversed)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '${event['message']}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _error(
    BridgeFailure failure, {
    required VoidCallback onRetry,
    String retryText = 'Retry',
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onErrorContainer;
    return Container(
      color: scheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(22, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            failure.code == 'host_identity_changed'
                ? Icons.gpp_bad_outlined
                : Icons.info_outline_rounded,
            size: 19,
            color: color,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              failure.message,
              style: TextStyle(fontSize: 11, height: 1.5, color: color),
            ),
          ),
          const SizedBox(width: 15),
          TextButton(
            onPressed: onRetry,
            child: Text(
              retryText,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(IconData icon, String title, String description) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 65,
              height: 65,
              decoration: BoxDecoration(
                color: c.soft,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                icon,
                size: 28,
                color: c.accent.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 21),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.25,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: c.muted, height: 1.8),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _eyebrow(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 8,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.2,
      color: c.muted,
    ),
  );

  Widget _icon(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    double size = 17,
  }) => SizedBox(
    width: 30,
    height: 30,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      icon: Icon(icon, size: size),
      color: c.muted,
    ),
  );
}
