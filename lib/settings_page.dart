import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_style.dart';
import 'browser_model.dart';

Future<void> showSettingsDialog(
  BuildContext context,
  BrowserModel model, {
  ValueChanged<RecentPath>? onOpenFolder,
}) => showDialog<void>(
  context: context,
  builder: (_) => AnimatedBuilder(
    animation: Listenable.merge([
      model,
      model.appearance,
      model.settingsChanges,
      model.statusChanges,
    ]),
    builder: (_, _) => Theme(
      data: buildShoreTheme(model.theme),
      child: SettingsDialog(model: model, onOpenFolder: onOpenFolder),
    ),
  ),
);

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.model, this.onOpenFolder});
  final BrowserModel model;
  final ValueChanged<RecentPath>? onOpenFolder;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  BrowserModel get model => widget.model;
  String? _notice;

  Future<void> _clearCache() async {
    final cleared = await model.clearThumbnailCache();
    if (mounted) {
      setState(() => _notice = cleared ? 'Thumbnail cache cleared.' : null);
    }
  }

  Future<void> _copyDiagnostics() async {
    final report = await model.loadDiagnostics();
    if (report == null || !mounted) return;
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) setState(() => _notice = 'Redacted diagnostics copied.');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cache = model.status['cache'] as Map?;
    final used = cache?['bytesUsed'] as num?;
    final budget =
        model.cacheSettings['thumbnailBudgetBytes'] as num? ??
        cache?['budgetBytes'] as num?;
    final budgetValues = <int>{
      for (final mib in [128, 256, 512, 1024, 2048]) mib * 1024 * 1024,
      if (budget != null) budget.toInt(),
    }.toList()..sort();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 780,
              maxHeight: MediaQuery.sizeOf(context).height - 48,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 12, 14),
                  child: Row(
                    children: [
                      Icon(Icons.tune_rounded, size: 21, color: colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: const Text(
                            'Settings',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close settings',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, size: 19),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colors.outlineVariant),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _section(context, 'Workspace', Icons.tab_rounded, [
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Remember open folders',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: const Text(
                              'Restore tab locations and display preferences next time. Saved folders connect only when you resume them.',
                              style: TextStyle(fontSize: 11, height: 1.6),
                            ),
                            value: model.restoreWorkspace,
                            onChanged: model.setRestoreWorkspace,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${model.tabs.where((tab) => tab.host != null).length} open folder tabs · ${model.view.name} view · ${model.tileSize.round()} thumbnail size',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Only server identifiers, folder paths and display preferences are saved. Passwords, keys, file contents and selections are not saved in the workspace.',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                              height: 1.6,
                            ),
                          ),
                          if (model.workspaceError case final error?) ...[
                            const SizedBox(height: 12),
                            _error(context, error.message),
                            TextButton.icon(
                              onPressed: () =>
                                  unawaited(model.retryWorkspaceSave()),
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('Retry saving workspace'),
                            ),
                          ],
                        ]),
                        const SizedBox(height: 20),
                        _section(
                          context,
                          'Favorite folders',
                          Icons.star_outline_rounded,
                          [
                            if (model.favoritePaths.isEmpty)
                              Text(
                                'No favorite folders yet.',
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            for (final item in model.favoritePaths)
                              _favorite(context, item),
                            if (model.tab.host != null &&
                                !model.tab.hostUnavailable)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed:
                                      model.isFavoritePath(
                                        model.tab.host!.id,
                                        model.tab.path,
                                      )
                                      ? null
                                      : () => unawaited(
                                          model.setFavoritePath(
                                            model.tab.host!.id,
                                            model.tab.path,
                                            true,
                                          ),
                                        ),
                                  icon: const Icon(Icons.add_rounded, size: 16),
                                  label: const Text(
                                    'Favorite the current folder',
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _section(
                          context,
                          'Thumbnail disk cache',
                          Icons.photo_library_outlined,
                          [
                            Text(
                              used == null
                                  ? 'Cache usage has not been checked yet.'
                                  : '${_bytes(used)} of thumbnail PNGs cached.',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 16,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                const Text(
                                  'Cache limit',
                                  style: TextStyle(fontSize: 12),
                                ),
                                DropdownButton<int>(
                                  value: budget?.toInt(),
                                  hint: const Text(
                                    'Not checked yet',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  items: [
                                    for (final value in budgetValues)
                                      DropdownMenuItem(
                                        value: value,
                                        child: Text(
                                          _bytes(value),
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                  ],
                                  onChanged: model.cacheBusy
                                      ? null
                                      : (value) {
                                          if (value != null) {
                                            unawaited(
                                              model.setThumbnailBudget(value),
                                            );
                                          }
                                        },
                                ),
                                OutlinedButton.icon(
                                  onPressed: model.cacheBusy
                                      ? null
                                      : _clearCache,
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 16,
                                  ),
                                  label: Text(
                                    model.cacheBusy
                                        ? 'Updating cache…'
                                        : 'Clear thumbnail cache',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 9),
                            Text(
                              'Clearing removes generated thumbnail PNGs. Remote files and open previews are preserved. Thumbnails are generated again when needed.',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 11,
                                height: 1.6,
                              ),
                            ),
                            if (model.statusError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  'Cache usage is from the last successful status check.',
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            if (model.cacheCleanupPending)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  'The limit was saved, but some thumbnails could not be removed. You can retry Clear thumbnail cache.',
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 11,
                                    height: 1.6,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _section(
                          context,
                          'Diagnostics',
                          Icons.health_and_safety_outlined,
                          [
                            Text(
                              'Copy a redacted report for troubleshooting. It includes runtime versions, counts and health information; server addresses, user names, folder paths, keys and access tokens are excluded.',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 11,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                onPressed: model.diagnosticsBusy
                                    ? null
                                    : _copyDiagnostics,
                                icon: const Icon(
                                  Icons.content_copy_rounded,
                                  size: 16,
                                ),
                                label: Text(
                                  model.diagnosticsBusy
                                      ? 'Preparing report…'
                                      : 'Copy diagnostics',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _section(
                          context,
                          'About Farshore',
                          Icons.info_outline_rounded,
                          [
                            Text(
                              'Farshore 0.2.0 beta · Read-only remote file browser',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => showLicensePage(
                                  context: context,
                                  applicationName: 'Farshore',
                                  applicationVersion: '0.2.0 beta',
                                  applicationLegalese:
                                      '© 2026 Farshore contributors · MIT License',
                                ),
                                icon: const Icon(
                                  Icons.description_outlined,
                                  size: 16,
                                ),
                                label: const Text('Open-source licenses'),
                              ),
                            ),
                          ],
                        ),
                        if (model.settingsError case final error?) ...[
                          const SizedBox(height: 18),
                          _error(context, error.message),
                        ],
                        if (_notice != null) ...[
                          const SizedBox(height: 16),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _notice!,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.primary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, color: colors.outlineVariant),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Done'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _favorite(BuildContext context, RecentPath item) {
    RemoteHost? host;
    for (final candidate in model.hosts) {
      if (candidate.id == item.hostId) host = candidate;
    }
    final label =
        '${host?.alias ?? 'Unavailable server'} · ${item.path.isEmpty ? 'SSH Home' : item.path}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 17,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
          if (host != null && widget.onOpenFolder != null)
            IconButton(
              tooltip: 'Open $label',
              onPressed: () => widget.onOpenFolder!(item),
              icon: const Icon(Icons.arrow_outward_rounded, size: 17),
            ),
          IconButton(
            tooltip: 'Remove favorite $label',
            onPressed: () =>
                unawaited(model.setFavoritePath(item.hostId, item.path, false)),
            icon: const Icon(Icons.star_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    IconData icon,
    List<Widget> children,
  ) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 17, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  Widget _error(BuildContext context, String message) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: TextStyle(
        color: Theme.of(context).colorScheme.error,
        fontSize: 12,
        height: 1.6,
      ),
    ),
  );
}

String _bytes(num value) {
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(value % (1024 * 1024) == 0 ? 0 : 1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(value % (1024 * 1024 * 1024) == 0 ? 0 : 1)} GB';
}
