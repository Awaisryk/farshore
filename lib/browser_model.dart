import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'bridge.dart';
import 'app_theme.dart';

enum BrowserView { grid, list, gallery }

enum FileKind { folder, image, video, audio, document, other }

enum EntrySort { name, newest, largest }

enum EntryOpenIntent {
  navigate,
  playInternally,
  previewInternally,
  openExternally,
}

class RecentPath {
  const RecentPath(this.hostId, this.path);
  final String hostId, path;
}

class PathNavigationAttempt {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

class PathNavigationResult {
  const PathNavigationResult({
    required this.success,
    this.error,
    this.cancelled = false,
    this.historySaved,
  });
  final bool success, cancelled;
  final BridgeFailure? error;
  final Future<void>? historySaved;
}

class RemoteHost {
  const RemoteHost(this.id, this.alias, this.hostname, this.user, this.port);
  factory RemoteHost.fromJson(Map<String, dynamic> value) => RemoteHost(
    value['id'] as String,
    value['alias'] as String,
    value['hostname'] as String? ?? '',
    value['user'] as String? ?? '',
    value['port'] as int? ?? 22,
  );
  final String id, alias, hostname, user;
  final int port;
}

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
    this.mimeType = '',
  });
  factory RemoteEntry.fromJson(Map<String, dynamic> value) => RemoteEntry(
    name: value['name'] as String,
    path: value['path'] as String,
    isDirectory: value['isDirectory'] == true,
    size: (value['size'] as num? ?? 0).toInt(),
    modified: '${value['modified'] ?? ''}',
    mimeType: value['mimeType'] as String? ?? '',
  );
  final String name, path, modified, mimeType;
  final bool isDirectory;
  final int size;
  String get extension =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';
  EntryOpenIntent get openIntent => isDirectory
      ? EntryOpenIntent.navigate
      : kind == FileKind.video || kind == FileKind.audio
      ? EntryOpenIntent.playInternally
      : kind == FileKind.image || kind == FileKind.document
      ? EntryOpenIntent.previewInternally
      : EntryOpenIntent.openExternally;
  FileKind get kind {
    if (isDirectory) return FileKind.folder;
    if (mimeType.startsWith('image/') ||
        const {
          'jpg',
          'jpeg',
          'png',
          'webp',
          'gif',
          'heic',
          'heif',
          'tif',
          'tiff',
          'bmp',
          'avif',
          'ico',
          'icns',
          'svg',
          'psd',
        }.contains(extension)) {
      return FileKind.image;
    }
    if (mimeType.startsWith('video/') ||
        const {
          'mp4',
          'mov',
          'mkv',
          'webm',
          'avi',
          'm4v',
          'mpeg',
          'mpg',
          'm2ts',
          'mts',
          '3gp',
          'ogv',
        }.contains(extension)) {
      return FileKind.video;
    }
    if (mimeType.startsWith('audio/') ||
        const {
          'wav',
          'mp3',
          'm4a',
          'flac',
          'aac',
          'ogg',
          'oga',
          'opus',
          'aif',
          'aiff',
          'wma',
          'caf',
          'ac3',
          'mka',
        }.contains(extension)) {
      return FileKind.audio;
    }
    if (mimeType.startsWith('text/') ||
        const {
          'application/json',
          'application/xml',
          'application/javascript',
          'application/x-yaml',
          'application/toml',
          'application/pdf',
        }.contains(mimeType) ||
        const {
          'readme',
          'license',
          'licence',
          'changelog',
          'notice',
          'dockerfile',
          'makefile',
          'gemfile',
          'procfile',
          'jenkinsfile',
        }.contains(name.toLowerCase()) ||
        const {
          'txt',
          'md',
          'markdown',
          'pdf',
          'json',
          'jsonl',
          'ndjson',
          'yaml',
          'yml',
          'toml',
          'ini',
          'conf',
          'config',
          'cfg',
          'env',
          'xml',
          'html',
          'htm',
          'css',
          'scss',
          'sass',
          'less',
          'js',
          'jsx',
          'ts',
          'tsx',
          'py',
          'pyi',
          'dart',
          'swift',
          'java',
          'kt',
          'kts',
          'go',
          'rs',
          'c',
          'cc',
          'cpp',
          'h',
          'hpp',
          'm',
          'mm',
          'cs',
          'rb',
          'php',
          'sh',
          'bash',
          'zsh',
          'fish',
          'ps1',
          'bat',
          'cmd',
          'sql',
          'r',
          'vue',
          'svelte',
          'tex',
          'gitignore',
          'gitattributes',
          'editorconfig',
          'lock',
          'properties',
          'ipynb',
          'csv',
          'tsv',
          'log',
          'rtf',
          'doc',
          'docx',
          'xls',
          'xlsx',
          'ppt',
          'pptx',
          'odt',
          'ods',
          'odp',
          'pages',
          'numbers',
          'key',
        }.contains(extension)) {
      return FileKind.document;
    }
    return FileKind.other;
  }
}

enum ThumbnailStatus {
  idle,
  queued,
  loading,
  ready,
  deferred,
  retryable,
  unsupported,
}

class ThumbnailSnapshot {
  const ThumbnailSnapshot({
    this.status = ThumbnailStatus.idle,
    this.path,
    this.message = '',
    this.reason,
    this.attempts = 0,
    this.deferrals = 0,
    this.retryAt,
  });
  final ThumbnailStatus status;
  final String? path, reason;
  final String message;
  final int attempts, deferrals;
  final DateTime? retryAt;
}

class ThumbnailBatchProgress {
  const ThumbnailBatchProgress({
    required this.tab,
    required this.generation,
    required this.total,
    required this.ready,
    required this.failed,
    required this.running,
    required this.cancelled,
    required this.waitingForPlayback,
    required this.inFlight,
  });
  final BrowserTab tab;
  final int generation, total, ready, failed, inFlight;
  final bool running, cancelled, waitingForPlayback;
}

class _ThumbnailJob {
  const _ThumbnailJob(this.tab, this.generation, this.entry);
  final BrowserTab tab;
  final int generation;
  final RemoteEntry entry;
  (BrowserTab, int, String) identity(BrowserModel model) =>
      (tab, generation, model.thumbnailKey(entry, tab));
}

class _ThumbnailBatch {
  _ThumbnailBatch(this.tab, this.generation, this.entries);
  final BrowserTab tab;
  final int generation;
  final Map<String, RemoteEntry> entries;
  bool cancelled = false;
}

class BrowserTab {
  BrowserTab({this.host, this.path = ''});
  RemoteHost? host;
  String path;
  List<RemoteEntry> _entries = const [];
  int _entriesRevision = 0;
  _DirectoryView? _view;
  List<RemoteEntry>? _videos;
  List<RemoteEntry> get videoEntries => _videos ??= List.unmodifiable(
    _entries.where((entry) => entry.kind == FileKind.video),
  );
  List<RemoteEntry> get entries => _entries;
  set entries(List<RemoteEntry> value) {
    _entries = List.unmodifiable(value);
    _entriesRevision++;
    _view = null;
    _videos = null;
  }

  final selection = <String>{};
  final back = <String>[];
  final forward = <String>[];
  bool loading = false, fresh = true;
  // Restored locations contain no remote entries and connect only on demand.
  bool needsLoad = false, hostUnavailable = false;
  int generation = 0;
  BridgeFailure? error;
  int anchor = 0;
  String? focusedPath;
}

class _DirectoryView {
  const _DirectoryView(this.key, this.entries, this.indexByPath);
  final (int, String, FileKind?, EntrySort, bool) key;
  final List<RemoteEntry> entries;
  final Map<String, int> indexByPath;
}

class BrowserModel extends ChangeNotifier {
  BrowserModel(
    this.bridge, {
    void Function(VoidCallback)? scheduleThumbnailUpdates,
    this.thumbnailRetryBase = const Duration(seconds: 2),
    this.workspaceSaveDelay = const Duration(milliseconds: 350),
    DateTime Function()? thumbnailNow,
  }) : _thumbnailNow = thumbnailNow ?? DateTime.now,
       _scheduleThumbnailUpdates =
           scheduleThumbnailUpdates ?? scheduleMicrotask {
    _workspaceFingerprint = jsonEncode(_workspaceSnapshot());
  }
  final BridgeClient bridge;
  final Duration thumbnailRetryBase;
  final Duration workspaceSaveDelay;
  final DateTime Function() _thumbnailNow;
  final tabs = <BrowserTab>[BrowserTab()];
  List<RemoteHost> hosts = [];
  final hostChanges = ValueNotifier(0);
  Set<String> _confirmedFavorites = {};
  Set<String> _favoriteHostIds = {};
  Set<String> get favoriteHostIds => Set.unmodifiable(_favoriteHostIds);
  List<RemoteHost> get orderedHosts => [
    ...hosts.where((host) => _favoriteHostIds.contains(host.id)),
    ...hosts.where((host) => !_favoriteHostIds.contains(host.id)),
  ];
  final _favoriteMutations =
      Queue<({String hostId, bool favorite, Completer<void> done})>();
  bool _savingFavorites = false;
  int _favoriteRevision = 0;
  final recentChanges = ValueNotifier(0);
  final settingsChanges = ValueNotifier(0);
  bool workspaceRestored = false, restoreWorkspace = true;
  bool _workspaceReady = false, _applyingWorkspace = false;
  int _workspaceRevision = 0;
  String? _workspaceFingerprint;
  Map<String, dynamic>? _pendingWorkspace;
  Timer? _workspaceSaveTimer;
  Future<void>? _workspaceSaveRequest;
  BridgeFailure? workspaceError, settingsError;
  bool get workspaceSaving => _workspaceSaveRequest != null;
  Map<String, dynamic> cacheSettings = const {};
  int _cacheRevision = 0;
  bool cacheBusy = false, diagnosticsBusy = false, cacheCleanupPending = false;
  String? diagnosticsReport;
  final List<RecentPath> _confirmedFavoritePaths = [];
  List<RecentPath> favoritePaths = const [];
  final _favoritePathMutations =
      Queue<({RecentPath location, bool favorite, Completer<void> done})>();
  bool _savingFavoritePaths = false;
  int _favoritePathRevision = 0;
  List<RecentPath> recentPaths = const [];
  int _recentRevision = 0;
  bool _savingRecentPaths = false;
  final _recentMutations =
      Queue<({RecentPath location, Completer<void> done})>();
  int activeTab = 0;
  bool _isHome = true;
  int _viewEpoch = 0;
  BrowserTab? _lastWorkspaceTab;
  bool get isHome => _isHome;
  BrowserTab? get _resumableTab {
    final remembered = _lastWorkspaceTab;
    if (remembered != null &&
        remembered.host != null &&
        tabs.contains(remembered)) {
      return remembered;
    }
    if (tab.host != null) return tab;
    for (final candidate in tabs) {
      if (candidate.host != null) return candidate;
    }
    return null;
  }

  bool get canResumeWorkspace => _resumableTab != null;

  void showHome() {
    if (_closed) return;
    if (!_isHome && tab.host != null) _lastWorkspaceTab = tab;
    _isHome = true;
    // Even an already visible Home must cancel an earlier launcher acceptance.
    _viewEpoch++;
    _clearThumbnailQueue();
    changed();
  }

  bool resumeWorkspace() {
    if (_closed) return false;
    final target = _resumableTab;
    if (target == null) return false;
    activeTab = tabs.indexOf(target);
    _revealWorkspace(target);
    _clearThumbnailQueue();
    changed();
    _loadRestoredTab(target);
    return true;
  }

  void _revealWorkspace(BrowserTab target) {
    if (target.error != null && identical(globalError, target.error)) {
      globalError = null;
    }
    _isHome = false;
    _lastWorkspaceTab = target;
    _viewEpoch++;
  }

  bool discovering = true, showHidden = false, inspector = true;
  final appearance = ValueNotifier(ShoreTheme.shore);
  ShoreTheme _confirmedTheme = ShoreTheme.shore;
  BridgeFailure? themeError;
  final _themeMutations = Queue<({ShoreTheme theme, Completer<void> done})>();
  bool _savingTheme = false;
  int _themeRevision = 0;
  ShoreTheme get theme => appearance.value;
  bool get dark => theme.isDark;
  set dark(bool value) =>
      unawaited(setTheme(value ? ShoreTheme.deepShore : ShoreTheme.shore));

  Future<void> setTheme(ShoreTheme next) {
    if (_closed) return Future.value();
    _clearThemeError();
    if (next == theme) return Future.value();
    final done = Completer<void>();
    _themeRevision++;
    _themeMutations.add((theme: next, done: done));
    appearance.value = next;
    unawaited(_saveThemes());
    return done.future;
  }

  void _clearThemeError() {
    var changedError = themeError != null;
    themeError = null;
    if (globalError?.code == 'theme_save_failed') {
      globalError = null;
      changedError = true;
    }
    if (changedError) changed();
  }

  void _applyThemeOverlay() {
    appearance.value = _themeMutations.isEmpty
        ? _confirmedTheme
        : _themeMutations.last.theme;
  }

  Future<void> _saveThemes() async {
    if (_savingTheme) return;
    _savingTheme = true;
    try {
      while (!_closed && _themeMutations.isNotEmpty) {
        final mutation = _themeMutations.first;
        try {
          final data = await bridge.call('set_theme', {
            'themeId': mutation.theme.id,
          });
          if (_closed) return;
          _confirmedTheme = data['themeId'] is String
              ? ShoreTheme.fromId(data['themeId'] as String)
              : mutation.theme;
          _themeRevision++;
          _clearThemeError();
        } catch (error) {
          if (_closed) return;
          _themeRevision++;
          if (identical(_themeMutations.last.done, mutation.done)) {
            themeError = BridgeFailure(
              'theme_save_failed',
              'The theme could not be saved. ${failure(error).message}',
            );
            globalError = themeError;
            changed();
          }
        }
        _themeMutations.removeFirst();
        _applyThemeOverlay();
        if (!mutation.done.isCompleted) mutation.done.complete();
      }
    } finally {
      _savingTheme = false;
    }
  }

  final selectionChanges = ValueNotifier(0);
  bool activityExpanded = false, opening = false;
  String query = '';
  FileKind? kindFilter;
  EntrySort sort = EntrySort.name;
  BrowserView view = BrowserView.grid;
  double tileSize = 166;
  BridgeFailure? globalError;
  final statusChanges = ValueNotifier<Map<String, dynamic>>(const {});
  Map<String, dynamic> get status => statusChanges.value;
  DateTime? lastStatusSuccess;
  BridgeFailure? statusError;
  bool statusRefreshing = false;
  Future<void>? _statusRequest;
  final thumbnails = <String, String?>{};
  final _thumbnailListeners = <String, ValueNotifier<String?>>{};
  final _pendingThumbnailUpdates = <String>{};
  final void Function(VoidCallback) _scheduleThumbnailUpdates;
  bool _thumbnailUpdateScheduled = false;
  final _thumbQueue = Queue<_ThumbnailJob>();
  final _batchThumbQueue = Queue<_ThumbnailJob>();
  final _activeThumbnailJobs = <_ThumbnailJob>{};
  final _thumbnailStates = <String, ThumbnailSnapshot>{};
  final _thumbnailStateListeners = <String, ValueNotifier<ThumbnailSnapshot>>{};
  final _visibleThumbnails =
      <(BrowserTab, int, String), ({RemoteEntry entry, int count})>{};
  final thumbnailBatch = ValueNotifier<ThumbnailBatchProgress?>(null);
  _ThumbnailBatch? _thumbnailBatch;
  Timer? _thumbnailRetryTimer;
  bool _resumeThumbnailPlaybackWhenIdle = false;
  int _thumbVideoRunning = 0;
  final _thumbPending = <(BrowserTab, int, String)>{};
  int _thumbRunning = 0;
  bool _closed = false;
  Timer? _statusTimer;

  BrowserTab get tab => tabs[activeTab];
  RemoteEntry? get selected {
    final directory = _directoryView;
    final focused = tab.focusedPath;
    if (focused != null && tab.selection.contains(focused)) {
      final index = directory.indexByPath[focused];
      if (index != null) return directory.entries[index];
    }
    int? firstIndex;
    for (final path in tab.selection) {
      final index = directory.indexByPath[path];
      if (index != null && (firstIndex == null || index < firstIndex)) {
        firstIndex = index;
      }
    }
    return firstIndex == null ? null : directory.entries[firstIndex];
  }

  List<RemoteEntry> get visibleEntries => _directoryView.entries;

  _DirectoryView get _directoryView {
    final target = tab;
    final key = (target._entriesRevision, query, kindFilter, sort, showHidden);
    if (target._view?.key == key) return target._view!;
    final needle = query.toLowerCase();
    final result = target.entries
        .where(
          (e) =>
              (showHidden || !e.name.startsWith('.')) &&
              (needle.isEmpty || e.name.toLowerCase().contains(needle)) &&
              (kindFilter == null || e.kind == kindFilter),
        )
        .toList();
    result.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final comparison = switch (sort) {
        EntrySort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        EntrySort.newest => b.modified.compareTo(a.modified),
        EntrySort.largest => b.size.compareTo(a.size),
      };
      return comparison == 0 ? a.name.compareTo(b.name) : comparison;
    });
    final directory = _DirectoryView(key, List.unmodifiable(result), {
      for (var i = 0; i < result.length; i++) result[i].path: i,
    });
    target._view = directory;
    return directory;
  }

  Future<void> initialize() async {
    await discover();
    await refreshStatus();
    if (!_closed) {
      _statusTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => refreshStatus(),
      );
    }
  }

  void changed() {
    if (!_closed) {
      _scheduleWorkspaceSave();
      notifyListeners();
    }
  }

  void selectionChanged() {
    if (!_closed) selectionChanges.value++;
  }

  Future<void> discover() async {
    final favoriteRevision = _favoriteRevision;
    final recentRevision = _recentRevision;
    final themeRevision = _themeRevision;
    final workspaceRevision = _workspaceRevision;
    final favoritePathRevision = _favoritePathRevision;
    final cacheRevision = _cacheRevision;
    discovering = true;
    globalError = null;
    changed();
    try {
      final data = await bridge.call('hosts');
      hosts = (data['hosts'] as List)
          .map((e) => RemoteHost.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (favoriteRevision == _favoriteRevision) {
        _confirmedFavorites = _readFavoriteIds(data);
        _applyFavoriteOverlay();
      }
      if (recentRevision == _recentRevision) _updateRecentPaths(data);
      if (themeRevision == _themeRevision) {
        _confirmedTheme = ShoreTheme.fromId(data['themeId'] as String?);
        _applyThemeOverlay();
      }
      _refreshSavedHosts();
      if (!_workspaceReady && workspaceRevision == _workspaceRevision) {
        _restoreWorkspace(data);
      } else if (!_workspaceReady &&
          (data['workspace'] is Map || data['browserSettings'] is Map)) {
        // A user action made while discovery was pending wins over saved state.
        _workspaceReady = true;
        _workspaceFingerprint = null;
      }
      if (favoritePathRevision == _favoritePathRevision) {
        _confirmedFavoritePaths
          ..clear()
          ..addAll(_readLocations(data['favoritePaths']));
        _applyFavoritePathOverlay();
      }
      if (cacheRevision == _cacheRevision && data['cacheSettings'] is Map) {
        cacheSettings = Map.unmodifiable(
          Map<String, dynamic>.from(data['cacheSettings'] as Map),
        );
      }
      _settingsChanged();
    } catch (e) {
      globalError = failure(e);
    }
    discovering = false;
    changed();
  }

  void _settingsChanged() {
    if (!_closed) settingsChanges.value++;
  }

  List<RecentPath> _readLocations(Object? value) {
    final result = <RecentPath>[];
    final seen = <(String, String)>{};
    for (final item in value is List ? value : const []) {
      if (item is! Map ||
          item['hostId'] is! String ||
          item['path'] is! String) {
        continue;
      }
      final identity = (item['hostId'] as String, item['path'] as String);
      if (identity.$1.isNotEmpty && seen.add(identity)) {
        result.add(RecentPath(identity.$1, identity.$2));
      }
      if (result.length == 50) break;
    }
    return result;
  }

  void _restoreWorkspace(Map<String, dynamic> data) {
    if (data['workspace'] is! Map && data['browserSettings'] is! Map) return;
    _applyingWorkspace = true;
    try {
      final settings = data['browserSettings'] as Map? ?? const {};
      restoreWorkspace = settings['restoreWorkspace'] != false;
      view = BrowserView.values.firstWhere(
        (value) => value.name == settings['view'],
        orElse: () => BrowserView.grid,
      );
      sort = EntrySort.values.firstWhere(
        (value) => value.name == settings['sort'],
        orElse: () => EntrySort.name,
      );
      tileSize =
          (settings['tileSize'] is num ? settings['tileSize'] as num : 166)
              .toDouble()
              .clamp(125, 240);
      showHidden = settings['showHidden'] == true;
      inspector = settings['inspector'] != false;
      final saved = data['workspace'] as Map? ?? const {};
      final locations = saved['tabs'];
      if (restoreWorkspace && saved['version'] == 1 && locations is List) {
        final restored = <BrowserTab>[];
        for (final item in locations.take(32)) {
          if (item is! Map ||
              item['hostId'] is! String ||
              item['path'] is! String) {
            continue;
          }
          final id = item['hostId'] as String;
          if (id.isEmpty) continue;
          RemoteHost? found;
          for (final host in hosts) {
            if (host.id == id) found = host;
          }
          final next =
              BrowserTab(
                  host: found ?? RemoteHost(id, id, '', '', 22),
                  path: item['path'] as String,
                )
                ..needsLoad = true
                ..hostUnavailable = found == null
                ..fresh = false;
          if (found == null) next.error = _missingSavedHost();
          restored.add(next);
        }
        if (restored.isNotEmpty) {
          tabs
            ..clear()
            ..addAll(restored);
          activeTab =
              (saved['activeTab'] is int ? saved['activeTab'] as int : 0).clamp(
                0,
                tabs.length - 1,
              );
          _isHome = saved['isHome'] != false;
          _lastWorkspaceTab = tab;
          workspaceRestored = true;
        }
      }
      _workspaceReady = true;
      _workspaceFingerprint = jsonEncode(_workspaceSnapshot());
    } finally {
      _applyingWorkspace = false;
    }
  }

  static BridgeFailure _missingSavedHost() => const BridgeFailure(
    'saved_host_missing',
    'This saved server is not in the current SSH configuration. Refresh connections after restoring its alias, or choose another server.',
  );

  void _refreshSavedHosts() {
    for (final target in tabs) {
      final id = target.host?.id;
      if (id == null) continue;
      RemoteHost? found;
      for (final host in hosts) {
        if (host.id == id) found = host;
      }
      if (found != null) {
        target.host = found;
        target.hostUnavailable = false;
        if (target.error?.code == 'saved_host_missing') target.error = null;
      } else if (target.needsLoad) {
        target.hostUnavailable = true;
        target.error = _missingSavedHost();
      }
    }
  }

  void _loadRestoredTab(BrowserTab target) {
    if (!target.needsLoad || !identical(tab, target)) return;
    if (target.hostUnavailable) {
      target.error = _missingSavedHost();
      changed();
      return;
    }
    target.needsLoad = false;
    unawaited(navigate(target.path, record: false));
  }

  Map<String, dynamic> _workspaceSnapshot() {
    final locations = <Map<String, dynamic>>[];
    var selected = 0;
    for (var i = 0; i < tabs.length && locations.length < 32; i++) {
      final target = tabs[i];
      if (target.host == null) continue;
      if (i == activeTab) selected = locations.length;
      locations.add({'hostId': target.host!.id, 'path': target.path});
    }
    return {
      'workspace': {
        'version': 1,
        'tabs': locations,
        'activeTab': selected,
        'isHome': _isHome,
      },
      'browserSettings': {
        'view': view.name,
        'tileSize': tileSize.clamp(125, 240),
        'sort': sort.name,
        'showHidden': showHidden,
        'inspector': inspector,
        'restoreWorkspace': restoreWorkspace,
      },
    };
  }

  void _scheduleWorkspaceSave() {
    if (_closed || _applyingWorkspace) return;
    final next = _workspaceSnapshot();
    final fingerprint = jsonEncode(next);
    if (fingerprint == _workspaceFingerprint) return;
    _workspaceFingerprint = fingerprint;
    _workspaceRevision++;
    if (!_workspaceReady) return;
    _pendingWorkspace = next;
    workspaceError = null;
    if (globalError?.code == 'workspace_save_failed') globalError = null;
    _workspaceSaveTimer?.cancel();
    _workspaceSaveTimer = Timer(workspaceSaveDelay, () {
      if (!_closed) unawaited(flushWorkspace());
    });
  }

  /// Await this during graceful quit. Writes are coalesced and always serialized.
  Future<void> flushWorkspace() {
    _workspaceSaveTimer?.cancel();
    if (_closed) return Future.value();
    if (_pendingWorkspace == null) {
      return _workspaceSaveRequest ?? Future.value();
    }
    return _workspaceSaveRequest ??= Future<void>.microtask(_flushWorkspace);
  }

  Future<void> _flushWorkspace() async {
    try {
      while (!_closed && _pendingWorkspace != null) {
        final next = _pendingWorkspace!;
        final revision = _workspaceRevision;
        _pendingWorkspace = null;
        try {
          await bridge.call('save_workspace', next);
          if (_closed) return;
          if (revision == _workspaceRevision) workspaceError = null;
        } catch (error) {
          if (_closed) return;
          if (revision == _workspaceRevision) {
            workspaceError = BridgeFailure(
              'workspace_save_failed',
              'The workspace could not be saved. ${failure(error).message}',
            );
            globalError = workspaceError;
            notifyListeners();
          }
        }
        _settingsChanged();
      }
    } finally {
      _workspaceSaveRequest = null;
      _settingsChanged();
    }
  }

  Future<void> retryWorkspaceSave() {
    _workspaceFingerprint = null;
    changed();
    return flushWorkspace();
  }

  void setRestoreWorkspace(bool enabled) {
    restoreWorkspace = enabled;
    changed();
    _settingsChanged();
  }

  bool isFavoritePath(String hostId, String path) =>
      favoritePaths.any((item) => item.hostId == hostId && item.path == path);

  Future<void> setFavoritePath(String hostId, String path, bool favorite) {
    if (_closed) return Future.value();
    settingsError = null;
    if (globalError?.code == 'favorite_path_save_failed') {
      globalError = null;
      notifyListeners();
    }
    final done = Completer<void>();
    _favoritePathRevision++;
    _favoritePathMutations.add((
      location: RecentPath(hostId, path),
      favorite: favorite,
      done: done,
    ));
    _applyFavoritePathOverlay();
    unawaited(_saveFavoritePaths());
    return done.future;
  }

  void _applyFavoritePathOverlay() {
    final visible = <(String, String), RecentPath>{
      for (final item in _confirmedFavoritePaths)
        (item.hostId, item.path): item,
    };
    for (final mutation in _favoritePathMutations) {
      final item = mutation.location;
      if (mutation.favorite) {
        visible[(item.hostId, item.path)] = item;
      } else {
        visible.remove((item.hostId, item.path));
      }
    }
    favoritePaths = List.unmodifiable(visible.values);
    _settingsChanged();
  }

  Future<void> _saveFavoritePaths() async {
    if (_savingFavoritePaths) return;
    _savingFavoritePaths = true;
    try {
      while (!_closed && _favoritePathMutations.isNotEmpty) {
        final mutation = _favoritePathMutations.first;
        try {
          final data = await bridge.call('set_favorite_path', {
            'hostId': mutation.location.hostId,
            'path': mutation.location.path,
            'favorite': mutation.favorite,
          });
          if (_closed) return;
          _confirmedFavoritePaths
            ..clear()
            ..addAll(_readLocations(data['favoritePaths']));
          _favoritePathRevision++;
          settingsError = null;
        } catch (error) {
          if (_closed) return;
          settingsError = BridgeFailure(
            'favorite_path_save_failed',
            'The folder favorite could not be saved. ${failure(error).message}',
          );
          globalError = settingsError;
          notifyListeners();
        }
        _favoritePathMutations.removeFirst();
        _applyFavoritePathOverlay();
        if (!mutation.done.isCompleted) mutation.done.complete();
      }
    } finally {
      _savingFavoritePaths = false;
    }
  }

  Future<bool> setThumbnailBudget(int bytes) async {
    if (_closed || cacheBusy) return false;
    cacheBusy = true;
    _cacheRevision++;
    settingsError = null;
    _settingsChanged();
    try {
      final data = await bridge.call('set_cache_settings', {
        'thumbnailBudgetBytes': bytes,
      });
      if (_closed) return false;
      _cacheRevision++;
      if (data['cacheSettings'] is Map) {
        cacheSettings = Map.unmodifiable(
          Map<String, dynamic>.from(data['cacheSettings'] as Map),
        );
      }
      cacheCleanupPending = data['cacheCleanupPending'] == true;
      await refreshStatus();
      return true;
    } catch (error) {
      if (!_closed) settingsError = failure(error);
      return false;
    } finally {
      cacheBusy = false;
      _settingsChanged();
    }
  }

  Future<bool> clearThumbnailCache() async {
    if (_closed || cacheBusy) return false;
    cacheBusy = true;
    settingsError = null;
    _settingsChanged();
    try {
      final data = await bridge.call('clear_thumbnail_cache');
      if (_closed) return false;
      if (data['cleared'] != true) {
        throw const BridgeFailure(
          'cache_clear_failed',
          'The thumbnail cache could not be cleared.',
        );
      }
      cacheCleanupPending = false;
      for (final key in thumbnails.keys.toList()) {
        thumbnails.remove(key);
        _thumbnailStates.remove(key);
        _thumbnailListeners[key]?.value = null;
        _thumbnailStateListeners[key]?.value = const ThumbnailSnapshot();
      }
      if (!_isHome) {
        for (final visible in _visibleThumbnails.entries.toList()) {
          if (identical(visible.key.$1, tab) &&
              visible.key.$2 == tab.generation) {
            requestThumbnail(visible.value.entry);
          }
        }
      }
      await refreshStatus();
      return true;
    } catch (error) {
      if (!_closed) settingsError = failure(error);
      return false;
    } finally {
      cacheBusy = false;
      _settingsChanged();
    }
  }

  Future<String?> loadDiagnostics() async {
    if (_closed || diagnosticsBusy) return null;
    diagnosticsBusy = true;
    settingsError = null;
    _settingsChanged();
    try {
      final data = await bridge.call('diagnostics');
      if (_closed) return null;
      diagnosticsReport = const JsonEncoder.withIndent('  ').convert(data);
      return diagnosticsReport;
    } catch (error) {
      if (!_closed) settingsError = failure(error);
      return null;
    } finally {
      diagnosticsBusy = false;
      _settingsChanged();
    }
  }

  void _updateRecentPaths(Map<String, dynamic> data) {
    final seen = <(String, String)>{};
    final recent = <RecentPath>[];
    for (final item in data['recentPaths'] as List? ?? const []) {
      if (item is! Map ||
          item['hostId'] is! String ||
          item['path'] is! String) {
        continue;
      }
      final identity = (item['hostId'] as String, item['path'] as String);
      if (seen.add(identity)) recent.add(RecentPath(identity.$1, identity.$2));
      if (recent.length == 5) break;
    }
    if (listEquals(
      recent.map((e) => (e.hostId, e.path)).toList(),
      recentPaths.map((e) => (e.hostId, e.path)).toList(),
    )) {
      return;
    }
    recentPaths = List.unmodifiable(recent);
    if (!_closed) recentChanges.value++;
  }

  Future<PathNavigationResult> navigateFromLauncher(
    RemoteHost host,
    String path,
    PathNavigationAttempt attempt,
  ) async {
    final original = tab;
    final generation = original.generation;
    final viewEpoch = _viewEpoch;
    final fromHome = _isHome;
    if (fromHome &&
        original.host != null &&
        tabs.length >= 32 &&
        !tabs.any((candidate) => candidate.host?.id == host.id)) {
      return PathNavigationResult(success: false, error: _tabLimit());
    }
    bool current() =>
        !_closed &&
        !attempt.cancelled &&
        _viewEpoch == viewEpoch &&
        identical(tab, original) &&
        original.generation == generation;
    try {
      final data = await bridge.call('list', {'hostId': host.id, 'path': path});
      if (!current()) {
        return const PathNavigationResult(success: false, cancelled: true);
      }
      final canonical = data['path'] as String? ?? path;
      final entries = (data['entries'] as List)
          .map((e) => RemoteEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      BrowserTab? existing;
      if (fromHome) {
        for (final candidate in tabs) {
          if (candidate.host?.id == host.id) {
            existing = candidate;
            break;
          }
        }
      }
      final target =
          existing ??
          (original.host?.id == host.id
              ? original
              : BrowserTab(host: host, path: canonical));
      if (!identical(target, original)) {
        if (fromHome && tabs.contains(target)) {
          activeTab = tabs.indexOf(target);
        } else if (fromHome && original.host != null) {
          tabs.add(target);
          activeTab = tabs.length - 1;
        } else {
          tabs[activeTab] = target;
        }
      }
      if (target.path != canonical) {
        target.back.add(target.path);
        target.forward.clear();
        target.selection.clear();
        target.focusedPath = null;
      }
      target.path = canonical;
      target.needsLoad = false;
      target.hostUnavailable = false;
      target.entries = entries;
      final available = entries.map((e) => e.path).toSet();
      target.selection.removeWhere((path) => !available.contains(path));
      target.error = null;
      target.loading = false;
      target.fresh = data['fresh'] != false;
      target.generation++;
      _revealWorkspace(target);
      _clearThumbnailQueue();
      changed();
      _recentRevision++;
      final saved = Completer<void>();
      _recentMutations.add((
        location: RecentPath(host.id, canonical),
        done: saved,
      ));
      unawaited(_saveRecentPaths());
      return PathNavigationResult(success: true, historySaved: saved.future);
    } catch (error) {
      if (!current()) {
        return const PathNavigationResult(success: false, cancelled: true);
      }
      return PathNavigationResult(success: false, error: failure(error));
    }
  }

  Future<void> _saveRecentPaths() async {
    if (_savingRecentPaths) return;
    _savingRecentPaths = true;
    try {
      while (!_closed && _recentMutations.isNotEmpty) {
        final visit = _recentMutations.first;
        try {
          final data = await bridge.call('record_path_visit', {
            'hostId': visit.location.hostId,
            'path': visit.location.path,
          });
          if (_closed) return;
          _recentRevision++;
          _updateRecentPaths(data);
        } catch (error) {
          if (_closed) return;
          globalError = BridgeFailure(
            'history_save_failed',
            'The folder opened, but its recent location could not be saved. ${failure(error).message}',
          );
          changed();
        }
        _recentMutations.removeFirst();
        if (!visit.done.isCompleted) visit.done.complete();
      }
    } finally {
      _savingRecentPaths = false;
    }
  }

  Set<String> _readFavoriteIds(Map<String, dynamic> data) =>
      (data['favoriteHostIds'] as List? ?? []).whereType<String>().toSet();

  void _applyFavoriteOverlay() {
    final visible = Set<String>.of(_confirmedFavorites);
    for (final mutation in _favoriteMutations) {
      if (mutation.favorite) {
        visible.add(mutation.hostId);
      } else {
        visible.remove(mutation.hostId);
      }
    }
    if (setEquals(visible, _favoriteHostIds)) return;
    _favoriteHostIds = visible;
    if (!_closed) hostChanges.value++;
  }

  Future<void> toggleFavorite(RemoteHost host) =>
      setFavorite(host, !_favoriteHostIds.contains(host.id));

  Future<void> setFavorite(RemoteHost host, bool favorite) {
    if (_closed) return Future.value();
    final done = Completer<void>();
    _favoriteRevision++;
    _favoriteMutations.add((hostId: host.id, favorite: favorite, done: done));
    _applyFavoriteOverlay();
    unawaited(_saveFavorites());
    return done.future;
  }

  Future<void> _saveFavorites() async {
    if (_savingFavorites) return;
    _savingFavorites = true;
    try {
      while (!_closed && _favoriteMutations.isNotEmpty) {
        final mutation = _favoriteMutations.first;
        try {
          final data = await bridge.call('set_favorite', {
            'hostId': mutation.hostId,
            'favorite': mutation.favorite,
          });
          if (_closed) return;
          _confirmedFavorites = _readFavoriteIds(data);
          _favoriteRevision++;
        } catch (error) {
          if (_closed) return;
          globalError = BridgeFailure(
            'favorite_save_failed',
            'The server favorite could not be saved. ${failure(error).message}',
          );
          changed();
        }
        _favoriteMutations.removeFirst();
        _applyFavoriteOverlay();
        if (!mutation.done.isCompleted) mutation.done.complete();
      }
    } finally {
      _savingFavorites = false;
    }
  }

  Future<void> selectHost(RemoteHost host) async {
    if (_closed) return;
    if (_isHome) {
      for (var index = 0; index < tabs.length; index++) {
        final target = tabs[index];
        if (target.host?.id != host.id) continue;
        if (target.loading) return;
        if (index != activeTab) query = '';
        activeTab = index;
        target.host = host;
        target.hostUnavailable = false;
        if (target.needsLoad ||
            (target.error != null && target.entries.isEmpty)) {
          await navigate(target.path, record: false);
        } else {
          _revealWorkspace(target);
          _clearThumbnailQueue();
          changed();
        }
        return;
      }
      if (tab.host != null && tabs.length >= 32) {
        globalError = _tabLimit();
        changed();
        return;
      }
      _viewEpoch++;
      final next = BrowserTab(host: host);
      if (tab.host == null) {
        tab.generation++;
        tabs[activeTab] = next;
      } else {
        tabs.add(next);
        activeTab = tabs.length - 1;
      }
      query = '';
      await navigate('');
      return;
    }
    if (tab.host?.id == host.id) {
      if (tab.needsLoad) {
        tab.host = host;
        tab.hostUnavailable = false;
        await navigate(tab.path, record: false);
      }
      return;
    }
    _viewEpoch++;
    tab.generation++;
    tabs[activeTab] = BrowserTab(host: host);
    query = '';
    await navigate('');
  }

  Future<void> navigate(String path, {bool record = true}) async {
    if (_closed) return;
    final target = tab;
    if (target.host == null) return;
    if (target.hostUnavailable) {
      target.error = _missingSavedHost();
      changed();
      return;
    }
    target.needsLoad = false;
    final viewEpoch = _viewEpoch;
    final fromHome = _isHome;
    if (fromHome) globalError = null;
    if (record && path != target.path) {
      target.back.add(target.path);
      target.forward.clear();
    }
    final previousPath = target.path;
    target.path = path;
    final generation = ++target.generation;
    target.loading = true;
    target.error = null;
    if (previousPath != path) {
      target.entries = [];
      target.selection.clear();
    }
    _clearThumbnailQueue();
    changed();
    try {
      final data = await bridge.call('list', {
        'hostId': target.host!.id,
        'path': path,
      });
      if (_closed || target.generation != generation) return;
      target.path = data['path'] as String? ?? path;
      target.entries = (data['entries'] as List)
          .map((e) => RemoteEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final availablePaths = target.entries.map((e) => e.path).toSet();
      target.selection.removeWhere((path) => !availablePaths.contains(path));
      target.fresh = data['fresh'] != false;
      if (identical(tab, target) && _viewEpoch == viewEpoch) {
        _revealWorkspace(target);
      }
    } catch (e) {
      if (_closed || target.generation != generation) return;
      target.error = failure(e);
      target.fresh = false;
      if (fromHome && identical(tab, target) && _viewEpoch == viewEpoch) {
        globalError = target.error;
      }
    }
    if (target.generation == generation) target.loading = false;
    changed();
  }

  void cancelNavigation() {
    tab.generation++;
    tab.loading = false;
    tab.fresh = false;
    _clearThumbnailQueue();
    changed();
  }

  Future<void> goBack() async {
    if (tab.back.isEmpty) return;
    tab.forward.add(tab.path);
    await navigate(tab.back.removeLast(), record: false);
  }

  Future<void> goForward() async {
    if (tab.forward.isEmpty) return;
    tab.back.add(tab.path);
    await navigate(tab.forward.removeLast(), record: false);
  }

  Future<void> parent() async {
    final path = tab.path;
    if (path.isEmpty || path == '/') return;
    final cut = path.lastIndexOf('/');
    await navigate(
      cut == 0
          ? '/'
          : cut < 0
          ? ''
          : path.substring(0, cut),
    );
  }

  void addTab() {
    if (tabs.length >= 32) {
      globalError = _tabLimit();
      changed();
      return;
    }
    _viewEpoch++;
    tabs.add(BrowserTab(host: tab.host, path: tab.path));
    activeTab = tabs.length - 1;
    changed();
    if (tab.host != null) navigate(tab.path, record: false);
  }

  static BridgeFailure _tabLimit() => const BridgeFailure(
    'workspace_tab_limit',
    'You can keep up to 32 folder tabs open. Close a tab before opening another folder.',
  );

  void closeTab(int index) {
    if (tabs.length == 1) return;
    tabs[index].generation++;
    tabs.removeAt(index);
    if (index < activeTab) activeTab--;
    activeTab = activeTab.clamp(0, tabs.length - 1);
    changed();
    if (!_isHome) _loadRestoredTab(tab);
  }

  void activateTab(int index, {bool preserveQuery = false}) {
    activeTab = index;
    if (!preserveQuery) query = '';
    if (tab.host != null) {
      _revealWorkspace(tab);
    } else {
      _viewEpoch++;
    }
    _clearThumbnailQueue();
    changed();
    _loadRestoredTab(tab);
  }

  void select(RemoteEntry entry, {bool additive = false, bool range = false}) {
    final directory = _directoryView;
    final entries = directory.entries;
    final index = directory.indexByPath[entry.path];
    if (index == null) return;
    tab.focusedPath = entry.path;
    if (range) {
      if (!additive) tab.selection.clear();
      final a = tab.anchor.clamp(0, entries.length - 1);
      for (var i = a < index ? a : index; i <= (a > index ? a : index); i++) {
        tab.selection.add(entries[i].path);
      }
    } else {
      if (additive && tab.selection.contains(entry.path)) {
        tab.selection.remove(entry.path);
      } else {
        if (!additive) tab.selection.clear();
        tab.selection.add(entry.path);
      }
      tab.anchor = index;
    }
    selectionChanged();
  }

  void moveSelection(int delta, {bool range = false}) {
    final entries = visibleEntries;
    if (entries.isEmpty) return;
    final current = _directoryView.indexByPath[tab.focusedPath];
    final next = current == null
        ? 0
        : (current + delta).clamp(0, entries.length - 1);
    select(entries[next], range: range);
  }

  String thumbnailKey(RemoteEntry e, [BrowserTab? target]) =>
      '${(target ?? tab).host?.id}:${e.path}:${e.size}:${e.modified}';

  ValueListenable<String?> thumbnailFor(RemoteEntry entry) {
    final key = thumbnailKey(entry);
    return _thumbnailListeners.putIfAbsent(
      key,
      () => ValueNotifier(thumbnails[key]),
    );
  }

  ValueListenable<ThumbnailSnapshot> thumbnailStateFor(RemoteEntry entry) {
    final key = thumbnailKey(entry);
    return _thumbnailStateListeners.putIfAbsent(
      key,
      () => ValueNotifier(_thumbnailStates[key] ?? const ThumbnailSnapshot()),
    );
  }

  /// Registration tracks only mounted previews, including inspector duplicates.
  VoidCallback observeThumbnail(RemoteEntry entry) {
    if (entry.kind != FileKind.image && entry.kind != FileKind.video) {
      return () {};
    }
    final target = tab;
    final generation = target.generation;
    final identity = (target, generation, thumbnailKey(entry, target));
    final previous = _visibleThumbnails[identity];
    _visibleThumbnails[identity] = (
      entry: entry,
      count: (previous?.count ?? 0) + 1,
    );
    requestThumbnail(entry);
    return () {
      final visible = _visibleThumbnails[identity];
      if (visible == null) return;
      if (visible.count > 1) {
        _visibleThumbnails[identity] = (entry: entry, count: visible.count - 1);
      } else {
        _visibleThumbnails.remove(identity);
        _thumbQueue.removeWhere((job) {
          if (job.identity(this) != identity) return false;
          if (_batchContains(job)) {
            _batchThumbQueue.add(job);
          } else {
            _thumbPending.remove(identity);
          }
          return true;
        });
      }
      _scheduleThumbnailRetries();
    };
  }

  void _setThumbnail(String key, ThumbnailSnapshot state) {
    _thumbnailStates[key] = state;
    if (state.status == ThumbnailStatus.ready) {
      thumbnails[key] = state.path;
    } else if (state.status == ThumbnailStatus.unsupported) {
      thumbnails[key] = null;
    } else {
      thumbnails.remove(key);
    }
    _pendingThumbnailUpdates.add(key);
    _scheduleThumbnailFlush();
  }

  void _scheduleThumbnailFlush() {
    if (_thumbnailUpdateScheduled) return;
    _thumbnailUpdateScheduled = true;
    _scheduleThumbnailUpdates(() {
      _thumbnailUpdateScheduled = false;
      if (_closed) return;
      final completed = _pendingThumbnailUpdates.toList();
      _pendingThumbnailUpdates.clear();
      for (final key in completed) {
        _thumbnailListeners[key]?.value = thumbnails[key];
        _thumbnailStateListeners[key]?.value =
            _thumbnailStates[key] ?? const ThumbnailSnapshot();
      }
      _publishThumbnailBatch();
    });
  }

  bool _validThumbnailJob(_ThumbnailJob job) =>
      !_closed &&
      !isHome &&
      job.tab.host != null &&
      identical(job.tab, tab) &&
      job.generation == job.tab.generation;

  bool _batchContains(_ThumbnailJob job) {
    final batch = _thumbnailBatch;
    return batch != null &&
        !batch.cancelled &&
        identical(batch.tab, job.tab) &&
        batch.generation == job.generation &&
        batch.entries.containsKey(thumbnailKey(job.entry, job.tab));
  }

  void _clearThumbnailQueue() {
    _thumbnailRetryTimer?.cancel();
    _thumbnailRetryTimer = null;
    for (final job in [..._thumbQueue, ..._batchThumbQueue]) {
      _thumbPending.remove(job.identity(this));
    }
    _thumbQueue.clear();
    _batchThumbQueue.clear();
    if (_thumbnailBatch != null) {
      _thumbnailBatch!.cancelled = true;
      _scheduleThumbnailFlush();
    }
  }

  void requestThumbnail(RemoteEntry entry, {bool retry = false}) {
    if (_closed ||
        tab.host == null ||
        (entry.kind != FileKind.image && entry.kind != FileKind.video)) {
      return;
    }
    final job = _ThumbnailJob(tab, tab.generation, entry);
    final key = thumbnailKey(entry);
    if (retry) _setThumbnail(key, const ThumbnailSnapshot());
    final state = _thumbnailStates[key];
    if (state?.status == ThumbnailStatus.ready ||
        state?.status == ThumbnailStatus.unsupported) {
      return;
    }
    if (_thumbPending.contains(job.identity(this))) {
      // A newly visible file moves ahead of folder pre-generation work.
      _batchThumbQueue.removeWhere((queued) {
        if (queued.identity(this) != job.identity(this)) return false;
        _thumbQueue.addFirst(queued);
        return true;
      });
      return;
    }
    if (!retry && state != null && !_mayRetryThumbnail(state)) return;
    _enqueueThumbnail(job, foreground: true);
    _pumpThumbnails();
  }

  void retryThumbnail(RemoteEntry entry) =>
      requestThumbnail(entry, retry: true);

  void thumbnailFileUnavailable(
    RemoteEntry entry, {
    ThumbnailSnapshot? expected,
  }) {
    final key = thumbnailKey(entry);
    if (expected != null && !identical(_thumbnailStates[key], expected)) return;
    _setThumbnail(
      key,
      const ThumbnailSnapshot(
        status: ThumbnailStatus.retryable,
        message: 'The cached preview was removed. Retry to regenerate it.',
      ),
    );
  }

  void generateVideoThumbnails({bool retryMissing = false}) {
    if (_closed || tab.host == null || tab.videoEntries.isEmpty) return;
    cancelThumbnailBatch();
    final entries = {
      for (final entry in tab.videoEntries) thumbnailKey(entry): entry,
    };
    _thumbnailBatch = _ThumbnailBatch(tab, tab.generation, entries);
    for (final pair in entries.entries) {
      final state = _thumbnailStates[pair.key];
      if (state?.status == ThumbnailStatus.ready) continue;
      if (retryMissing) _setThumbnail(pair.key, const ThumbnailSnapshot());
      if (!retryMissing && state?.status == ThumbnailStatus.unsupported) {
        continue;
      }
      if (!retryMissing && state != null && !_mayRetryThumbnail(state)) {
        continue;
      }
      _enqueueThumbnail(
        _ThumbnailJob(tab, tab.generation, pair.value),
        foreground: false,
      );
    }
    _scheduleThumbnailFlush();
    _scheduleThumbnailRetries();
    _pumpThumbnails();
  }

  void cancelThumbnailBatch() {
    final batch = _thumbnailBatch;
    if (batch == null) return;
    batch.cancelled = true;
    for (final job in _batchThumbQueue) {
      _thumbPending.remove(job.identity(this));
    }
    _batchThumbQueue.clear();
    _scheduleThumbnailFlush();
    _scheduleThumbnailRetries();
  }

  bool _mayRetryThumbnail(ThumbnailSnapshot state) {
    if (state.attempts >= 3 || state.deferrals >= 3) return false;
    if (state.status == ThumbnailStatus.deferred &&
        state.reason == 'playback_active' &&
        (status['activePreviews'] as num? ?? 0) > 0) {
      return false;
    }
    return state.retryAt == null || !state.retryAt!.isAfter(_thumbnailNow());
  }

  void _enqueueThumbnail(_ThumbnailJob job, {required bool foreground}) {
    final identity = job.identity(this);
    if (!_validThumbnailJob(job) || !_thumbPending.add(identity)) return;
    final old = _thumbnailStates[identity.$3] ?? const ThumbnailSnapshot();
    _setThumbnail(
      identity.$3,
      ThumbnailSnapshot(
        status: ThumbnailStatus.queued,
        attempts: old.attempts,
        deferrals: old.deferrals,
      ),
    );
    (foreground ? _thumbQueue : _batchThumbQueue).add(job);
  }

  _ThumbnailJob? _takeThumbnailJob(
    Queue<_ThumbnailJob> queue, {
    bool batch = false,
  }) {
    if (batch && (status['activePreviews'] as num? ?? 0) > 0) return null;
    final count = queue.length;
    for (var i = 0; i < count; i++) {
      final job = queue.removeFirst();
      if (!_validThumbnailJob(job)) {
        _thumbPending.remove(job.identity(this));
      } else if (job.entry.kind == FileKind.video && _thumbVideoRunning > 0) {
        queue.add(job);
      } else {
        return job;
      }
    }
    return null;
  }

  void _pumpThumbnails() {
    while (!_closed && _thumbRunning < 3) {
      final job =
          _takeThumbnailJob(_thumbQueue) ??
          _takeThumbnailJob(_batchThumbQueue, batch: true);
      if (job == null) break;
      _thumbRunning++;
      if (job.entry.kind == FileKind.video) _thumbVideoRunning++;
      _activeThumbnailJobs.add(job);
      final key = thumbnailKey(job.entry, job.tab);
      final previous = _thumbnailStates[key] ?? const ThumbnailSnapshot();
      _setThumbnail(
        key,
        ThumbnailSnapshot(
          status: ThumbnailStatus.loading,
          attempts: previous.attempts,
          deferrals: previous.deferrals,
        ),
      );
      bridge
          .call('thumbnail', {
            'hostId': job.tab.host!.id,
            'path': job.entry.path,
            'size': job.entry.size,
            'modified': job.entry.modified,
          })
          .then((data) {
            if (!_closed && job.generation == job.tab.generation) {
              final path = data['path'] as String?;
              final statusName = data['status'] as String?;
              final reason = data['reason'] as String?;
              final status = path != null && path.isNotEmpty
                  ? ThumbnailStatus.ready
                  : statusName == 'unsupported'
                  ? ThumbnailStatus.unsupported
                  : statusName == 'deferred'
                  ? ThumbnailStatus.deferred
                  : ThumbnailStatus.retryable;
              _completeThumbnail(
                job,
                previous,
                status,
                path: path,
                reason: reason,
                retryAfterMs: (data['retryAfterMs'] as num?)?.toInt(),
              );
            }
          })
          .catchError((Object error) {
            if (!_closed && job.generation == job.tab.generation) {
              _completeThumbnail(
                job,
                previous,
                ThumbnailStatus.retryable,
                reason: failure(error).code,
                message: failure(error).message,
              );
            }
          })
          .whenComplete(() {
            _thumbPending.remove(job.identity(this));
            _activeThumbnailJobs.remove(job);
            _thumbRunning--;
            if (job.entry.kind == FileKind.video) _thumbVideoRunning--;
            _scheduleThumbnailFlush();
            _scheduleThumbnailRetries();
            _pumpThumbnails();
          });
    }
  }

  void _completeThumbnail(
    _ThumbnailJob job,
    ThumbnailSnapshot previous,
    ThumbnailStatus next, {
    String? path,
    String? reason,
    String? message,
    int? retryAfterMs,
  }) {
    final deferred = next == ThumbnailStatus.deferred;
    final attempts = previous.attempts + (deferred ? 0 : 1);
    final deferrals = deferred ? previous.deferrals + 1 : 0;
    final delay = Duration(
      milliseconds:
          (retryAfterMs ??
                  thumbnailRetryBase.inMilliseconds *
                      (attempts > 1 || deferrals > 1 ? 4 : 1))
              .clamp(250, 60000),
    );
    _setThumbnail(
      thumbnailKey(job.entry, job.tab),
      ThumbnailSnapshot(
        status: next,
        path: path,
        reason: reason,
        message: message ?? _thumbnailMessage(next, reason),
        attempts: attempts,
        deferrals: deferrals,
        retryAt: next == ThumbnailStatus.retryable || deferred
            ? _thumbnailNow().add(delay)
            : null,
      ),
    );
  }

  String _thumbnailMessage(ThumbnailStatus state, String? reason) {
    if (reason == 'playback_active') {
      return 'Thumbnail generation waits while a file preview or player is open.';
    }
    if (state == ThumbnailStatus.unsupported) {
      return 'A preview is unavailable for this file.';
    }
    if (state == ThumbnailStatus.deferred) {
      return 'The preview worker is busy. This file can retry shortly.';
    }
    if (reason == 'thumbnail_timeout') {
      return 'Preview generation timed out. Retry this file.';
    }
    if (reason == 'source_changed') {
      return 'The file changed while generating its preview. Refresh and retry.';
    }
    return 'A preview could not be generated. Retry this file.';
  }

  Iterable<({_ThumbnailJob job, bool foreground})>
  _thumbnailRetryTargets() sync* {
    final seen = <(BrowserTab, int, String)>{};
    for (final visible in _visibleThumbnails.entries) {
      final job = _ThumbnailJob(
        visible.key.$1,
        visible.key.$2,
        visible.value.entry,
      );
      if (_validThumbnailJob(job) && seen.add(job.identity(this))) {
        yield (job: job, foreground: true);
      }
    }
    final batch = _thumbnailBatch;
    if (batch != null && !batch.cancelled) {
      for (final entry in batch.entries.values) {
        final job = _ThumbnailJob(batch.tab, batch.generation, entry);
        if (_validThumbnailJob(job) && seen.add(job.identity(this))) {
          yield (job: job, foreground: false);
        }
      }
    }
  }

  void _scheduleThumbnailRetries() {
    _thumbnailRetryTimer?.cancel();
    _thumbnailRetryTimer = null;
    if (_closed) return;
    DateTime? next;
    for (final target in _thumbnailRetryTargets()) {
      final state = _thumbnailStates[target.job.identity(this).$3];
      if (state == null ||
          state.retryAt == null ||
          state.attempts >= 3 ||
          state.deferrals >= 3 ||
          _thumbPending.contains(target.job.identity(this))) {
        continue;
      }
      if (state.reason == 'playback_active' &&
          (status['activePreviews'] as num? ?? 0) > 0) {
        continue;
      }
      if (next == null || state.retryAt!.isBefore(next)) next = state.retryAt;
    }
    if (next == null) return;
    final delay = next.difference(_thumbnailNow());
    _thumbnailRetryTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      _retryThumbnails,
    );
  }

  /// Retain the close signal if status verification temporarily fails.
  void resumeDeferredThumbnailsAfterPlayback() {
    _resumeThumbnailPlaybackWhenIdle = true;
    _resumeThumbnailPlaybackIfIdle();
  }

  void _resumeThumbnailPlaybackIfIdle() {
    if (!_resumeThumbnailPlaybackWhenIdle ||
        isHome ||
        statusError != null ||
        status['activePreviews'] != 0) {
      return;
    }
    _resumeThumbnailPlaybackWhenIdle = false;
    _retryThumbnails(playbackEnded: true);
    _scheduleThumbnailFlush();
  }

  void _retryThumbnails({bool playbackEnded = false}) {
    if (_closed) return;
    for (final target in _thumbnailRetryTargets().toList()) {
      final key = target.job.identity(this).$3;
      var state = _thumbnailStates[key];
      if (state == null ||
          (state.status != ThumbnailStatus.deferred &&
              state.status != ThumbnailStatus.retryable)) {
        continue;
      }
      if (playbackEnded && state.reason == 'playback_active') {
        state = ThumbnailSnapshot(
          status: state.status,
          attempts: state.attempts,
          message: state.message,
          reason: state.reason,
        );
        _thumbnailStates[key] = state;
      }
      if (_mayRetryThumbnail(state)) {
        _enqueueThumbnail(target.job, foreground: target.foreground);
      }
    }
    _pumpThumbnails();
    _scheduleThumbnailRetries();
  }

  void _publishThumbnailBatch() {
    final batch = _thumbnailBatch;
    if (batch == null) return;
    var ready = 0, failed = 0, waiting = 0;
    for (final key in batch.entries.keys) {
      final state = _thumbnailStates[key] ?? const ThumbnailSnapshot();
      if (state.status == ThumbnailStatus.ready) {
        ready++;
      } else if (state.status == ThumbnailStatus.deferred &&
          state.reason == 'playback_active' &&
          (status['activePreviews'] as num? ?? 0) > 0) {
        waiting++;
      } else if (state.status == ThumbnailStatus.unsupported ||
          ((state.status == ThumbnailStatus.retryable ||
                  state.status == ThumbnailStatus.deferred) &&
              (state.attempts >= 3 || state.deferrals >= 3))) {
        failed++;
      } else {
        waiting++;
      }
    }
    thumbnailBatch.value = ThumbnailBatchProgress(
      tab: batch.tab,
      generation: batch.generation,
      total: batch.entries.length,
      ready: ready,
      failed: failed,
      running: !batch.cancelled && waiting > 0,
      cancelled: batch.cancelled,
      waitingForPlayback: (status['activePreviews'] as num? ?? 0) > 0,
      inFlight: _activeThumbnailJobs
          .where(
            (job) =>
                identical(job.tab, batch.tab) &&
                job.generation == batch.generation &&
                batch.entries.containsKey(thumbnailKey(job.entry, job.tab)),
          )
          .length,
    );
  }

  Future<void> openEntry(
    RemoteEntry entry, {
    String? applicationId,
    bool remember = false,
    bool choose = false,
    bool systemDefault = false,
  }) async {
    if (entry.isDirectory) {
      await navigate(entry.path);
      return;
    }
    if (tab.host == null || opening) return;
    final hostId = tab.host!.id;
    opening = true;
    globalError = null;
    changed();
    try {
      await bridge.call(choose ? 'choose_application' : 'open', {
        'hostId': hostId,
        'path': entry.path,
        'remember': remember,
        if (systemDefault) 'systemDefault': true,
        'applicationId': ?applicationId,
      });
      await refreshStatus();
    } catch (e) {
      final problem = failure(e);
      if (problem.code != 'selection_cancelled') globalError = problem;
    }
    opening = false;
    changed();
  }

  Future<List<Map<String, dynamic>>> applications(RemoteEntry entry) async {
    final data = await bridge.call('applications', {
      'hostId': tab.host!.id,
      'path': entry.path,
    });
    return (data['applications'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> refreshStatus() {
    if (_closed) return Future.value();
    return _statusRequest ??= _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    statusRefreshing = true;
    var notify = false;
    Map<String, dynamic>? snapshot;
    try {
      final next = await bridge.call('status');
      if (_closed) return;
      snapshot = _sameData(status, next)
          ? status
          : _immutableData(next) as Map<String, dynamic>;
      lastStatusSuccess = DateTime.now();
      statusError = null;
      notify = true;
    } catch (error) {
      if (_closed) return;
      final nextError = failure(error);
      notify =
          statusError?.code != nextError.code ||
          statusError?.message != nextError.message;
      statusError = nextError;
      // Keep the last snapshot and any actionable foreground error intact.
    } finally {
      statusRefreshing = false;
      _statusRequest = null;
      if (!_closed && notify) {
        // A fresh identity also signals health/timestamp changes with equal data.
        final previousPreviews = status['activePreviews'] as num?;
        statusChanges.value = Map.unmodifiable(snapshot ?? status);
        final currentPreviews = status['activePreviews'] as num?;
        if (snapshot != null) {
          if (currentPreviews == 0 &&
              previousPreviews != null &&
              previousPreviews > 0) {
            _resumeThumbnailPlaybackWhenIdle = true;
          }
          _resumeThumbnailPlaybackIfIdle();
        }
        _pumpThumbnails();
        _scheduleThumbnailFlush();
      }
    }
  }

  static BridgeFailure failure(Object e) => e is BridgeFailure
      ? e
      : const BridgeFailure(
          'unexpected_error',
          'The operation could not complete. Refresh and retry.',
        );

  @override
  void dispose() {
    _closed = true;
    _statusTimer?.cancel();
    _workspaceSaveTimer?.cancel();
    _thumbQueue.clear();
    _batchThumbQueue.clear();
    _thumbnailRetryTimer?.cancel();
    _visibleThumbnails.clear();
    for (final mutation in _favoriteMutations) {
      if (!mutation.done.isCompleted) mutation.done.complete();
    }
    _favoriteMutations.clear();
    for (final visit in _recentMutations) {
      if (!visit.done.isCompleted) visit.done.complete();
    }
    _recentMutations.clear();
    for (final mutation in _themeMutations) {
      if (!mutation.done.isCompleted) mutation.done.complete();
    }
    _themeMutations.clear();
    for (final mutation in _favoritePathMutations) {
      if (!mutation.done.isCompleted) mutation.done.complete();
    }
    _favoritePathMutations.clear();
    recentChanges.dispose();
    settingsChanges.dispose();
    hostChanges.dispose();
    appearance.dispose();
    selectionChanges.dispose();
    statusChanges.dispose();
    for (final listener in _thumbnailListeners.values) {
      listener.dispose();
    }
    for (final listener in _thumbnailStateListeners.values) {
      listener.dispose();
    }
    thumbnailBatch.dispose();
    _pendingThumbnailUpdates.clear();
    bridge.dispose();
    super.dispose();
  }
}

bool _sameData(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameData(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameData(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

Object? _immutableData(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, item) => MapEntry(key as String, _immutableData(item))),
    );
  }
  if (value is List) return List.unmodifiable(value.map(_immutableData));
  return value;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[index]}';
}
