import 'dart:async';
import 'package:flutter/material.dart';
import 'app_style.dart';
import 'app_theme.dart';
import 'browser_model.dart';

Future<void> showThemePicker(BuildContext context, BrowserModel model) =>
    showDialog<void>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: Listenable.merge([model.appearance, model]),
        builder: (context, _) => Theme(
          data: buildShoreTheme(model.theme),
          child: _ThemePicker(model: model),
        ),
      ),
    );

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.model});
  final BrowserModel model;

  @override
  Widget build(BuildContext context) {
    final c = ShoreColors.forTheme(model.theme);
    return Dialog(
      backgroundColor: c.canvas,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 740,
          maxHeight: MediaQuery.sizeOf(context).height - 64,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.palette_outlined, size: 20, color: c.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Choose your theme',
                        style: TextStyle(
                          color: c.ink,
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close themes',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Make the workspace yours. Your choice is saved for next time.',
                style: TextStyle(color: c.muted, fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 22),
              Flexible(
                child: SingleChildScrollView(
                  child: LayoutBuilder(
                    builder: (context, bounds) {
                      final columns = bounds.maxWidth >= 600
                          ? 3
                          : bounds.maxWidth >= 390
                          ? 2
                          : 1;
                      final width =
                          (bounds.maxWidth - (columns - 1) * 12) / columns;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final theme in ShoreTheme.values)
                            SizedBox(
                              width: width,
                              child: _ThemeCard(
                                theme: theme,
                                selected: model.theme == theme,
                                onTap: () => unawaited(model.setTheme(theme)),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (model.themeError case final error?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '${error.message} Your previous theme was restored.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.theme,
    required this.selected,
    required this.onTap,
  });
  final ShoreTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ShoreColors.forTheme(theme);
    final current = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('theme-card-${theme.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? current.primary : current.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: _ThemePreview(colors: c)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        theme.label,
                        style: TextStyle(
                          color: c.ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(
                        Icons.check_circle_rounded,
                        color: c.accent,
                        size: 16,
                        semanticLabel: 'Selected',
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  theme.description,
                  style: TextStyle(color: c.muted, fontSize: 10, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.colors});
  final ShoreColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Container(
      height: 82,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.canvas,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.line),
      ),
      child: Row(
        children: [
          Container(
            width: 37,
            color: c.sidebar,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.waves_rounded, size: 14, color: c.accent),
                const SizedBox(height: 11),
                Container(height: 4, color: c.accent),
                const SizedBox(height: 7),
                Container(height: 3, color: c.line),
                const SizedBox(height: 7),
                Container(height: 3, color: c.line),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    widthFactor: 0.58,
                    child: Container(height: 4, color: c.ink),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Row(
                      children: [
                        for (var i = 0; i < 3; i++) ...[
                          if (i > 0) const SizedBox(width: 5),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: i == 0 ? c.selection : c.soft,
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Icon(
                                Icons.folder_rounded,
                                size: 16,
                                color: i == 0 ? c.accent : c.muted,
                              ),
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
        ],
      ),
    );
  }
}
