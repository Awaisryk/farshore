import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/home_page.dart';

const servers = [
  RemoteHost('studio', 'studio', 'studio.example.invalid', 'artist', 22),
  RemoteHost('render', 'render', 'render.example.invalid', 'worker', 2222),
  RemoteHost('archive', 'archive', 'archive.example.invalid', 'reader', 22),
];

class HomeBridge implements BridgeClient {
  final calls = <String>[];
  final favorites = <String>{'render'};
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add(method);
    if (method == 'hosts') {
      return {
        'hosts': [
          for (final h in servers)
            {
              'id': h.id,
              'alias': h.alias,
              'hostname': h.hostname,
              'user': h.user,
              'port': h.port,
            },
        ],
        'favoriteHostIds': favorites.toList(),
        'recentPaths': [
          {'hostId': 'render', 'path': '/data2/renders'},
          {'hostId': 'studio', 'path': ''},
          {'hostId': 'studio', 'path': '/'},
          {'hostId': 'removed', 'path': '/past-project'},
          {'hostId': 'archive', 'path': '/data/2026'},
        ],
      };
    }
    if (method == 'set_favorite') {
      if (params['favorite'] == true) {
        favorites.add(params['hostId'] as String);
      } else {
        favorites.remove(params['hostId']);
      }
      return {'favoriteHostIds': favorites.toList()};
    }
    return {};
  }

  @override
  void dispose() {}
}

const sessionStatus = <String, dynamic>{
  'cache': {'bytesUsed': 13631488, 'budgetBytes': 536870912},
  'mounts': [
    {'hostId': 'studio', 'state': 'mounted', 'externalAccess': true},
    {'hostId': 'render', 'state': 'disconnected', 'externalAccess': false},
    {'hostId': 'archive', 'state': 'access-blocked', 'externalAccess': false},
  ],
  'activePreviews': 2,
  'readBytes': 4096,
  'activity': [
    {
      'kind': 'playback',
      'message': 'Opened an image in an external application.',
    },
    {'kind': 'playback', 'message': 'Opened a read-only mounted file.'},
    {'kind': 'playback', 'message': 'Released an in-app preview session.'},
    {'kind': 'playback', 'message': 'Prepared a video preview over SSH.'},
  ],
};

Future<BrowserModel> populated() async {
  final model = BrowserModel(HomeBridge());
  await model.discover();
  model.tabs[0] = BrowserTab(host: servers[0], path: '/data/artwork');
  model.tabs.add(BrowserTab(host: servers[1], path: '/data2/renders'));
  model.statusChanges.value = sessionStatus;
  model.lastStatusSuccess = DateTime(2026, 10, 22, 12, 34);
  return model;
}

class HomeActions {
  final opened = <String>[];
  final recent = <(String, String)>[];
  final resumed = <int>[];
  int paths = 0, refreshes = 0, activities = 0;
  Widget page(BrowserModel model) => FarshoreHomePage(
    model: model,
    onOpenServer: (h) => opened.add(h.id),
    onOpenRecent: (r) => recent.add((r.hostId, r.path)),
    onResumeTab: resumed.add,
    onOpenPath: () => paths++,
    onRefreshConnections: () => refreshes++,
    onShowActivity: () => activities++,
  );
}

const captureKey = ValueKey('home-capture');
Future<void> showHome(
  WidgetTester tester,
  BrowserModel model,
  HomeActions actions, {
  Size size = const Size(1400, 900),
  bool dark = false,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final background = dark ? const Color(0xff141b1c) : const Color(0xfffaf9f6);
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme:
            theme ??
            ThemeData(
              useMaterial3: true,
              fontFamily: '.AppleSystemUIFont',
              visualDensity: VisualDensity.compact,
              colorScheme: ColorScheme.fromSeed(
                seedColor: dark
                    ? const Color(0xff9fd8c5)
                    : const Color(0xff327f6c),
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              scaffoldBackgroundColor: background,
            ),
        home: Scaffold(body: actions.page(model)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = File('/System/Library/Fonts/SFNS.ttf');
    if (font.existsSync()) {
      final loader = FontLoader('.AppleSystemUIFont')
        ..addFont(
          font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
    final icons = File(
      '.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          icons.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
  });

  testWidgets(
    'Home follows inherited color roles when the selected theme changes',
    (tester) async {
      final model = await populated();
      model.statusError = const BridgeFailure(
        'status',
        'Theme status warning.',
      );
      addTearDown(model.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final actions = HomeActions();
      for (final seed in [const Color(0xff805020), const Color(0xff5c429e)]) {
        final scheme = ColorScheme.fromSeed(seedColor: seed).copyWith(
          primary: seed,
          onSurface: seed.withRed(23),
          onSurfaceVariant: seed.withGreen(81),
          surfaceContainerLow: seed.withValues(alpha: 0.12),
          surfaceContainerHigh: seed.withValues(alpha: 0.21),
          outlineVariant: seed.withValues(alpha: 0.38),
          error: seed.withBlue(41),
        );
        await showHome(
          tester,
          model,
          actions,
          theme: ThemeData(colorScheme: scheme),
        );
        expect(
          tester.widget<Text>(find.text('Your remote workspace.')).style!.color,
          scheme.onSurface,
        );
        expect(
          tester.widget<Text>(find.text('HOME')).style!.color,
          scheme.onSurfaceVariant,
        );
        expect(
          tester.widget<Icon>(find.byIcon(Icons.waves_rounded)).color,
          scheme.primary,
        );
        final panel = tester.widget<Material>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('home-server-render')),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(panel.color, scheme.surfaceContainerLow);
        expect(
          (panel.shape! as RoundedRectangleBorder).side.color,
          scheme.outlineVariant,
        );
        expect(
          tester
              .widget<Text>(find.textContaining('Theme status warning.'))
              .style!
              .color,
          scheme.error,
        );
        final serverIcon = find.descendant(
          of: find.byKey(const ValueKey('home-server-render')),
          matching: find.byIcon(Icons.dns_outlined),
        );
        final iconBox = tester.widget<Container>(
          find.ancestor(of: serverIcon, matching: find.byType(Container)).first,
        );
        expect(
          (iconBox.decoration! as BoxDecoration).color,
          scheme.surfaceContainerHigh,
        );
      }
      expect(
        (model.bridge as HomeBridge).calls.where((m) => m == 'list'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Home shows real saved servers, five host-aware recents and workspace without starting a remote listing',
    (tester) async {
      final model = await populated();
      addTearDown(model.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showHome(tester, model, HomeActions());
      expect(find.text('Your remote workspace.'), findsOneWidget);
      expect(find.text('worker@render.example.invalid:2222'), findsOneWidget);
      final renderPosition = tester.getTopLeft(
        find.byKey(const ValueKey('home-server-render')),
      );
      final studioPosition = tester.getTopLeft(
        find.byKey(const ValueKey('home-server-studio')),
      );
      expect(renderPosition.dy <= studioPosition.dy, isTrue);
      expect(renderPosition.dx < studioPosition.dx, isTrue);
      for (var i = 0; i < 5; i++) {
        expect(find.byKey(ValueKey('home-recent-$i')), findsOneWidget);
      }
      expect(
        find.text('Server no longer in SSH configuration'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-tab-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-tab-1')), findsOneWidget);
      expect(
        (model.bridge as HomeBridge).calls.where((m) => m == 'list'),
        isEmpty,
      );
      expect(find.textContaining('online'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Home actions navigate explicitly, favorites stay separate, and unavailable recents have no pointer or accessibility action',
    (tester) async {
      final model = await populated();
      addTearDown(model.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final actions = HomeActions();
      final semantics = tester.ensureSemantics();
      await showHome(tester, model, actions);
      final server = find.byKey(const ValueKey('home-server-render'));
      expect(
        tester
            .getSemantics(server)
            .getSemanticsData()
            .hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      await tester.tap(server);
      expect(actions.opened, ['render']);
      await tester.tap(find.byTooltip('Favorite studio'));
      await tester.pumpAndSettle();
      expect(model.favoriteHostIds, {'render', 'studio'});
      expect(actions.opened, ['render']);
      await tester.tap(find.byKey(const ValueKey('home-recent-0')));
      expect(actions.recent, [('render', '/data2/renders')]);
      final unavailable = find.byKey(const ValueKey('home-recent-3'));
      expect(
        tester
            .getSemantics(unavailable)
            .getSemanticsData()
            .hasAction(ui.SemanticsAction.tap),
        isFalse,
      );
      await tester.tap(unavailable);
      expect(actions.recent.length, 1);
      await tester.tap(find.byKey(const ValueKey('home-tab-1')));
      expect(actions.resumed, [1]);
      await tester.tap(find.widgetWithText(FilledButton, 'Go to folder'));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Activity'));
      await tester.tap(find.text('Refresh connections'));
      expect((actions.paths, actions.activities, actions.refreshes), (1, 1, 1));
      semantics.dispose();
    },
  );

  testWidgets(
    'status values remain scoped, count only mounted filesystems, and refresh independently of server cards',
    (tester) async {
      final model = await populated();
      addTearDown(model.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showHome(tester, model, HomeActions());
      final serverBefore = tester.widget(
        find.byKey(const ValueKey('home-server-render')),
      );
      expect(find.text('1 kept for external apps'), findsOneWidget);
      expect(find.text('1 disconnected'), findsOneWidget);
      expect(find.text('1 access blocked'), findsOneWidget);
      expect(find.text('13 MB'), findsOneWidget);
      expect(find.text('Current filesystem sessions only'), findsOneWidget);
      model.statusError = const BridgeFailure(
        'status_failed',
        'The helper did not respond.',
      );
      model.statusChanges.value = {...sessionStatus, 'readBytes': null};
      await tester.pump();
      expect(
        find.textContaining('Showing last check at 12:34'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The helper did not respond.'),
        findsOneWidget,
      );
      expect(find.text('Unavailable'), findsOneWidget);
      expect(
        identical(
          serverBefore,
          tester.widget(find.byKey(const ValueKey('home-server-render'))),
        ),
        isTrue,
      );
      await tester.scrollUntilVisible(
        find.text('View activity'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Prepared a video preview over SSH.'), findsOneWidget);
      expect(find.text('Released an in-app preview session.'), findsOneWidget);
      expect(
        find.text('Opened an image in an external application.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty and loading Home are honest, missing status is unavailable, and discovery can be retried',
    (tester) async {
      final model = BrowserModel(HomeBridge());
      addTearDown(model.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final actions = HomeActions();
      model.discovering = false;
      await showHome(tester, model, actions, size: const Size(620, 620));
      expect(find.text('No SSH servers configured.'), findsOneWidget);
      expect(find.text('No recent folders yet.'), findsOneWidget);
      await tester.tap(find.text('Refresh connections'));
      expect(actions.refreshes, 1);
      model.discovering = true;
      model.changed();
      await tester.pump();
      expect(find.text('Reading SSH configuration…'), findsOneWidget);
      model.discovering = false;
      model.changed();
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Session status not checked yet.'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Unavailable'), findsNWidgets(4));
      expect(find.text('No open folders yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large SSH configuration initially shows six favorites-first servers; expanding and collapsing performs no I/O',
    (tester) async {
      final bridge = HomeBridge();
      final model = BrowserModel(bridge)..discovering = false;
      model.hosts = [
        for (var i = 0; i < 25; i++)
          RemoteHost(
            'server-$i',
            'Server $i',
            'server$i.example.invalid',
            'user',
            22,
          ),
      ];
      await model.setFavorite(model.hosts.last, true);
      bridge.calls.clear();
      addTearDown(model.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showHome(tester, model, HomeActions());
      final cards = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith('home-server-'),
      );
      expect(cards, findsNWidgets(6));
      expect(find.text('25 configured'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-server-server-24')),
        findsOneWidget,
      );
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('home-server-server-24')))
            .dx,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('home-server-server-0')))
              .dx,
        ),
      );
      await tester.tap(find.text('Show all 25 servers'));
      await tester.pumpAndSettle();
      expect(cards, findsNWidgets(25));
      await tester.scrollUntilVisible(
        find.text('Show fewer servers'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Show fewer servers'));
      await tester.pumpAndSettle();
      expect(cards, findsNWidgets(6));
      expect(find.text('Show all 25 servers'), findsOneWidget);
      expect(find.text('25 configured'), findsOneWidget);
      expect(bridge.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, size, dark) in [
    ('light', const Size(1400, 900), false),
    ('dark', const Size(1400, 900), true),
    ('narrow', const Size(920, 620), false),
  ]) {
    testWidgets(
      'Home fits $name desktop and produces a fixture review screenshot',
      (tester) async {
        final model = await populated();
        addTearDown(model.dispose);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await showHome(tester, model, HomeActions(), size: size, dark: dark);
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(captureKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('.build/home-fixture-$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      },
    );
  }
}
