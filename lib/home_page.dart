import 'package:flutter/material.dart';
import 'browser_model.dart';

/// A starting point built entirely from saved SSH configuration and session data.
class FarshoreHomePage extends StatelessWidget {
  const FarshoreHomePage({
    super.key,
    required this.model,
    required this.onOpenServer,
    required this.onOpenRecent,
    required this.onResumeTab,
    required this.onOpenPath,
    required this.onRefreshConnections,
    required this.onShowActivity,
  });

  final BrowserModel model;
  final ValueChanged<RemoteHost> onOpenServer;
  final ValueChanged<RecentPath> onOpenRecent;
  final ValueChanged<int> onResumeTab;
  final VoidCallback onOpenPath, onRefreshConnections, onShowActivity;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      model,
      model.hostChanges,
      model.recentChanges,
    ]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, bounds) {
        final colors = _HomeColors(Theme.of(context));
        final wide = bounds.maxWidth >= 940;
        final padding = bounds.maxWidth < 650 ? 20.0 : 34.0;
        return SingleChildScrollView(
          key: const PageStorageKey('farshore-home-scroll'),
          padding: EdgeInsets.fromLTRB(padding, 32, padding, 30),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, colors, bounds.maxWidth),
                  const SizedBox(height: 29),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 8,
                          child: _destinations(context, colors),
                        ),
                        const SizedBox(width: 24),
                        Expanded(flex: 5, child: _workspace(context, colors)),
                      ],
                    )
                  else ...[
                    _destinations(context, colors),
                    const SizedBox(height: 25),
                    _workspace(context, colors),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _header(BuildContext context, _HomeColors c, double width) {
    final compact = width < 650;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.waves_rounded, color: c.accent, size: 21),
            const SizedBox(width: 9),
            Text(
              'HOME',
              style: TextStyle(
                color: c.muted,
                fontSize: 10,
                letterSpacing: 1.7,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Icon(Icons.lock_outline_rounded, color: c.muted, size: 12),
            const SizedBox(width: 5),
            Text(
              'Read-only SSH',
              style: TextStyle(color: c.muted, fontSize: 10),
            ),
          ],
        ),
        const SizedBox(height: 23),
        Semantics(
          header: true,
          child: Text(
            'Your remote workspace.',
            style: TextStyle(
              fontSize: compact ? 27 : 32,
              letterSpacing: -0.8,
              height: 1.15,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
        ),
        const SizedBox(height: 11),
        Text(
          'Open a server, revisit a folder, or pick up where you left off.',
          style: TextStyle(color: c.muted, fontSize: 12, height: 1.7),
        ),
        const SizedBox(height: 21),
        Wrap(
          spacing: 9,
          runSpacing: 9,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: onOpenPath,
              icon: const Icon(Icons.folder_open_rounded, size: 17),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Go to folder', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 17),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.onPrimary.withValues(alpha: 0.35),
                      ),
                    ),
                    child: const Text('/', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: onShowActivity,
              icon: const Icon(Icons.monitor_heart_outlined, size: 16),
              label: const Text('Activity', style: TextStyle(fontSize: 12)),
            ),
            TextButton.icon(
              onPressed: model.discovering ? null : onRefreshConnections,
              icon: model.discovering
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  : const Icon(Icons.refresh_rounded, size: 16),
              label: Text(
                model.discovering ? 'Refreshing…' : 'Refresh connections',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _destinations(BuildContext context, _HomeColors c) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionHeading(
        c,
        'Saved servers',
        trailing: '${model.hosts.length} configured',
      ),
      const SizedBox(height: 12),
      if (model.hosts.isEmpty)
        _panel(
          c,
          child: _empty(
            c,
            icon: model.discovering ? Icons.search_rounded : Icons.dns_outlined,
            title: model.discovering
                ? 'Reading SSH configuration…'
                : 'No SSH servers configured.',
            description: model.discovering
                ? 'Saved SSH aliases will appear here.'
                : 'Add a host alias to ~/.ssh/config, then refresh connections.',
          ),
        )
      else
        _HomeServerCollection(
          hosts: model.orderedHosts,
          serverBuilder: (host) => _server(c, host),
        ),
      const SizedBox(height: 27),
      _sectionHeading(c, 'Recent folders', trailing: 'From Go to folder'),
      const SizedBox(height: 12),
      _panel(
        c,
        child: model.recentPaths.isEmpty
            ? _empty(
                c,
                icon: Icons.history_rounded,
                title: 'No recent folders yet.',
                description:
                    'Folders opened with / or Go to folder appear here. Only successful visits are saved.',
                action: TextButton(
                  onPressed: onOpenPath,
                  child: const Text('Open a folder'),
                ),
              )
            : Column(
                children: [
                  for (
                    var i = 0;
                    i < model.recentPaths.take(5).length;
                    i++
                  ) ...[
                    if (i > 0) Divider(height: 1, color: c.line),
                    _recent(c, model.recentPaths[i], i),
                  ],
                ],
              ),
      ),
    ],
  );

  Widget _server(_HomeColors c, RemoteHost host) {
    final favorite = model.favoriteHostIds.contains(host.id);
    final address =
        '${host.user.isEmpty ? '' : '${host.user}@'}${host.hostname.isEmpty ? host.alias : host.hostname}:${host.port}';
    return _panel(
      c,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              key: ValueKey('home-server-${host.id}'),
              label: 'Open server ${host.alias}, $address',
              onTap: () => onOpenServer(host),
              button: true,
              excludeSemantics: true,
              child: InkWell(
                onTap: () => onOpenServer(host),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(15, 17, 2, 17),
                  child: Row(
                    children: [
                      Container(
                        width: 33,
                        height: 36,
                        decoration: BoxDecoration(
                          color: c.soft,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.dns_outlined,
                          size: 18,
                          color: c.accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              host.alias,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.ink,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Tooltip(
                              message: address,
                              child: Text(
                                address,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: c.muted, fontSize: 10),
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
          Padding(
            padding: const EdgeInsets.only(right: 5),
            child: IconButton(
              tooltip: '${favorite ? 'Unfavorite' : 'Favorite'} ${host.alias}',
              isSelected: favorite,
              onPressed: () => model.toggleFavorite(host),
              icon: Icon(
                favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                size: 18,
                color: favorite ? c.accent : c.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recent(_HomeColors c, RecentPath recent, int index) {
    RemoteHost? host;
    for (final candidate in model.hosts) {
      if (candidate.id == recent.hostId) {
        host = candidate;
        break;
      }
    }
    final path = recent.path.isEmpty ? 'Home' : recent.path;
    final label = host == null ? 'Unavailable server' : host.alias;
    return Semantics(
      key: ValueKey('home-recent-$index'),
      onTap: host == null ? null : () => onOpenRecent(recent),
      label:
          '$label · $path${host == null ? ', server no longer configured' : ''}',
      button: host != null,
      enabled: host != null,
      excludeSemantics: true,
      child: InkWell(
        onTap: host == null ? null : () => onOpenRecent(recent),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
          child: Row(
            children: [
              Icon(
                host == null ? Icons.link_off_rounded : Icons.folder_outlined,
                size: 19,
                color: host == null ? c.muted : c.accent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.ink, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      host == null
                          ? 'Server no longer in SSH configuration'
                          : label,
                      style: TextStyle(color: c.muted, fontSize: 10),
                    ),
                  ],
                ),
              ),
              if (host != null)
                Icon(Icons.north_east_rounded, color: c.muted, size: 14),
            ],
          ),
        ),
      ),
    );
  }

  Widget _workspace(BuildContext context, _HomeColors c) {
    final tabs = [
      for (var i = 0; i < model.tabs.length; i++)
        if (model.tabs[i].host != null) i,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading(
          c,
          'Continue browsing',
          trailing: '${tabs.length} open ${tabs.length == 1 ? 'tab' : 'tabs'}',
        ),
        const SizedBox(height: 12),
        _panel(
          c,
          child: tabs.isEmpty
              ? _empty(
                  c,
                  icon: Icons.tab_rounded,
                  title: 'No open folders yet.',
                  description:
                      'Your open folders stay here while you explore Home.',
                )
              : Column(
                  children: [
                    for (var n = 0; n < tabs.length; n++) ...[
                      if (n > 0) Divider(height: 1, color: c.line),
                      _tab(c, tabs[n]),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 27),
        ValueListenableBuilder<Map<String, dynamic>>(
          valueListenable: model.statusChanges,
          builder: (context, status, _) => Column(
            children: [
              _status(c, status),
              const SizedBox(height: 24),
              _activity(c, status),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _sectionHeading(c, 'Keyboard shortcuts'),
        const SizedBox(height: 10),
        _panel(
          c,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 6),
            child: Column(
              children: [
                _shortcut(
                  c,
                  'Go to folder',
                  '/  or  ⌘ L',
                  'Slash or Command L',
                ),
                _shortcut(c, 'Filter this folder', '⌘ F', 'Command F'),
                _shortcut(c, 'Quick preview', 'Space', 'Space'),
                _shortcut(c, 'Open selected file', 'Return', 'Return'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tab(_HomeColors c, int index) {
    final tab = model.tabs[index];
    final host = tab.host!;
    final path = tab.path.isEmpty ? 'Home' : tab.path;
    return Semantics(
      key: ValueKey('home-tab-$index'),
      label: 'Resume ${host.alias} at $path',
      onTap: () => onResumeTab(index),
      button: true,
      excludeSemantics: true,
      child: InkWell(
        onTap: () => onResumeTab(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.tab_rounded, size: 18, color: c.accent),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            host.alias,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.ink,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (index == model.activeTab)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              'LAST ACTIVE',
                              style: TextStyle(
                                color: c.muted,
                                fontSize: 8,
                                letterSpacing: 0.7,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.muted, fontSize: 10),
                    ),
                    if (tab.loading || tab.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          tab.loading
                              ? 'Loading folder…'
                              : 'Folder needs attention',
                          style: TextStyle(
                            color: tab.error == null ? c.muted : c.warning,
                            fontSize: 10,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward_rounded, size: 15, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _status(_HomeColors c, Map<String, dynamic> status) {
    final cache = status['cache'] as Map?;
    final used = cache?['bytesUsed'] as num?;
    final budget = cache?['budgetBytes'] as num?;
    final mounts = status['mounts'] as List?;
    final mounted = mounts
        ?.where((m) => m is Map && m['state'] == 'mounted')
        .length;
    final protected = mounts
        ?.where((m) => m is Map && m['externalAccess'] == true)
        .length;
    final disconnected = mounts
        ?.where((m) => m is Map && m['state'] == 'disconnected')
        .length;
    final blocked = mounts
        ?.where((m) => m is Map && m['state'] == 'access-blocked')
        .length;
    final previews = status['activePreviews'] as num?;
    final read = status['readBytes'] as num?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading(c, 'Access & storage'),
        const SizedBox(height: 12),
        _panel(
          c,
          child: Padding(
            padding: const EdgeInsets.all(17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _metric(
                  c,
                  Icons.photo_library_outlined,
                  'Thumbnail disk cache',
                  used == null ? 'Unavailable' : formatBytes(used.toInt()),
                ),
                if (used != null && budget != null && budget > 0) ...[
                  const SizedBox(height: 11),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      value: (used / budget).clamp(0, 1),
                      backgroundColor: c.soft,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'of ${formatBytes(budget.toInt())} budget',
                    style: TextStyle(color: c.muted, fontSize: 9),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Divider(height: 1, color: c.line),
                ),
                _metric(
                  c,
                  Icons.folder_shared_outlined,
                  'Mounted filesystems',
                  mounted?.toString() ?? 'Unavailable',
                ),
                if (protected != null && protected > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 5),
                    child: Text(
                      '$protected kept for external apps',
                      style: TextStyle(color: c.muted, fontSize: 9),
                    ),
                  ),
                if (disconnected != null && disconnected > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 5),
                    child: Text(
                      '$disconnected disconnected',
                      style: TextStyle(color: c.warning, fontSize: 9),
                    ),
                  ),
                if (blocked != null && blocked > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 5),
                    child: Text(
                      '$blocked access blocked',
                      style: TextStyle(color: c.warning, fontSize: 9),
                    ),
                  ),
                const SizedBox(height: 14),
                _metric(
                  c,
                  Icons.play_circle_outline_rounded,
                  'Open preview sessions',
                  previews?.toInt().toString() ?? 'Unavailable',
                ),
                const SizedBox(height: 14),
                _metric(
                  c,
                  Icons.data_usage_rounded,
                  'SFTP payload read',
                  read == null ? 'Unavailable' : formatBytes(read.toInt()),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 28, top: 5),
                  child: Text(
                    'Current filesystem sessions only',
                    style: TextStyle(color: c.muted, fontSize: 9),
                  ),
                ),
                const SizedBox(height: 15),
                Divider(height: 1, color: c.line),
                const SizedBox(height: 12),
                _statusFreshness(c, status),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _activity(_HomeColors c, Map<String, dynamic> status) {
    final events = (status['activity'] as List? ?? const [])
        .whereType<Map>()
        .where((event) => event['message'] is String)
        .toList();
    final latest = events.reversed.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading(c, 'Recent activity'),
        const SizedBox(height: 12),
        _panel(
          c,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(17, 8, 17, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (latest.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No file-opening activity this session.',
                      style: TextStyle(
                        color: c.muted,
                        fontSize: 10,
                        height: 1.6,
                      ),
                    ),
                  ),
                for (var i = 0; i < latest.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: c.line),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.arrow_outward_rounded,
                            size: 12,
                            color: c.accent,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            latest[i]['message'] as String,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 10,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                TextButton(
                  onPressed: onShowActivity,
                  child: const Text(
                    'View activity',
                    style: TextStyle(fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusFreshness(_HomeColors c, Map<String, dynamic> status) {
    final checked = model.lastStatusSuccess;
    final error = model.statusError;
    final time = checked == null
        ? null
        : '${checked.toLocal().hour.toString().padLeft(2, '0')}:${checked.toLocal().minute.toString().padLeft(2, '0')}';
    return Semantics(
      liveRegion: error != null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (model.statusRefreshing)
            const Padding(
              padding: EdgeInsets.only(right: 8, top: 1),
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.2),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 7, top: 1),
              child: Icon(
                error == null
                    ? Icons.schedule_rounded
                    : Icons.info_outline_rounded,
                size: 12,
                color: error == null ? c.muted : c.warning,
              ),
            ),
          Expanded(
            child: Text(
              error != null
                  ? '${time == null ? 'Status unavailable' : 'Showing last check at $time'}. ${error.message}'
                  : model.statusRefreshing
                  ? 'Checking session status…'
                  : time != null
                  ? 'Last checked at $time'
                  : status.isEmpty
                  ? 'Session status not checked yet.'
                  : 'Session status available.',
              style: TextStyle(
                color: error == null ? c.muted : c.warning,
                fontSize: 9,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(_HomeColors c, IconData icon, String label, String value) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: c.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: c.muted, fontSize: 10, height: 1.5),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              color: c.ink,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
        ],
      );

  Widget _shortcut(_HomeColors c, String label, String key, String spokenKey) =>
      Semantics(
        label: '$label, $spokenKey',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: c.muted, fontSize: 10),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: c.soft,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(key, style: TextStyle(color: c.ink, fontSize: 9)),
              ),
            ],
          ),
        ),
      );

  Widget _sectionHeading(_HomeColors c, String title, {String? trailing}) =>
      Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: TextStyle(
                  color: c.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (trailing != null)
            Text(trailing, style: TextStyle(color: c.muted, fontSize: 9)),
        ],
      );

  Widget _panel(_HomeColors c, {required Widget child}) => Material(
    color: c.surface,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: c.line),
    ),
    child: child,
  );

  Widget _empty(
    _HomeColors c, {
    required IconData icon,
    required String title,
    required String description,
    Widget? action,
  }) => Padding(
    padding: const EdgeInsets.all(23),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 24, color: c.accent),
        const SizedBox(height: 14),
        Text(
          title,
          style: TextStyle(
            color: c.ink,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: TextStyle(color: c.muted, fontSize: 11, height: 1.7),
        ),
        if (action != null) ...[const SizedBox(height: 9), action],
      ],
    ),
  );
}

/// Keep frequently used destinations within reach even with a large SSH config.
class _HomeServerCollection extends StatefulWidget {
  const _HomeServerCollection({
    required this.hosts,
    required this.serverBuilder,
  });
  final List<RemoteHost> hosts;
  final Widget Function(RemoteHost) serverBuilder;
  @override
  State<_HomeServerCollection> createState() => _HomeServerCollectionState();
}

class _HomeServerCollectionState extends State<_HomeServerCollection> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LayoutBuilder(
        builder: (context, bounds) {
          final columns = bounds.maxWidth >= 580 ? 2 : 1;
          final width = (bounds.maxWidth - (columns - 1) * 10) / columns;
          final visible = _expanded ? widget.hosts : widget.hosts.take(6);
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final host in visible)
                SizedBox(width: width, child: widget.serverBuilder(host)),
            ],
          );
        },
      ),
      if (widget.hosts.length > 6)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextButton.icon(
            key: const ValueKey('home-servers-toggle'),
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 17,
            ),
            label: Text(
              _expanded
                  ? 'Show fewer servers'
                  : 'Show all ${widget.hosts.length} servers',
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
    ],
  );
}

class _HomeColors {
  _HomeColors(ThemeData theme) : scheme = theme.colorScheme;
  final ColorScheme scheme;
  Color get ink => scheme.onSurface;
  Color get muted => scheme.onSurfaceVariant;
  Color get accent => scheme.primary;
  Color get surface => scheme.surfaceContainerLow;
  Color get soft => scheme.surfaceContainerHigh;
  Color get line => scheme.outlineVariant;
  Color get warning => scheme.error;
}
