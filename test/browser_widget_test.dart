import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/main.dart';

class WidgetBridge implements BridgeClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async => {};
  @override
  void dispose() {}
}

class RecoveringWidgetBridge extends WidgetBridge implements BridgeRecovery {
  @override
  final ValueNotifier<BridgeRecoveryState> recovery = ValueNotifier(
    const BridgeRecoveryState(
      BridgeRecoveryPhase.retrying,
      attempt: 1,
      message: 'Reconnecting…',
    ),
  );
  int cancellations = 0;
  @override
  void cancelRecovery() => cancellations++;
  @override
  void dispose() => recovery.dispose();
}

void main() {
  testWidgets(
    'folder cancel also stops bridge retries and invalidates late reads',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = RecoveringWidgetBridge();
      final model = BrowserModel(bridge)..discovering = false;
      model.tab.host = const RemoteHost(
        'fixture',
        'fixture',
        'fixture.invalid',
        'fixture',
        22,
      );
      model.resumeWorkspace();
      model.tab.loading = true;
      final generation = model.tab.generation;
      await tester.pumpWidget(FarshoreApp(model: model, initialize: false));
      await tester.tap(find.byTooltip('Cancel folder request'));
      await tester.pump();
      expect(bridge.cancellations, 1);
      expect(model.tab.loading, false);
      expect(model.tab.generation, greaterThan(generation));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'empty launch is honest and fits narrow desktop window in both themes',
    (tester) async {
      tester.view.physicalSize = const Size(920, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = BrowserModel(WidgetBridge())..discovering = false;
      await tester.pumpWidget(FarshoreApp(model: m, initialize: false));
      expect(find.text('Your remote workspace.'), findsOneWidget);
      expect(find.text('Read-only beta'), findsOneWidget);
      expect(find.textContaining('No SSH aliases found.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Choose theme'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('theme-card-deep-shore')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(m.dark, true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard selects real entries, filter updates and persistent error stays visible',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = BrowserModel(WidgetBridge())..discovering = false;
      m.tab.host = const RemoteHost('h', 'real-alias', 'host', 'user', 22);
      m.tab.entries = const [
        RemoteEntry(
          name: 'alpha.txt',
          path: 'alpha.txt',
          isDirectory: false,
          size: 21,
          modified: '',
        ),
        RemoteEntry(
          name: 'beta.txt',
          path: 'beta.txt',
          isDirectory: false,
          size: 32,
          modified: '',
        ),
      ];
      m.tab.error = const BridgeFailure(
        'host_identity_changed',
        'Server identity changed. Trusted keys were preserved.',
      );
      m.resumeWorkspace();
      await tester.pumpWidget(FarshoreApp(model: m, initialize: false));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(m.selected?.name, 'alpha.txt');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(m.selected?.name, 'beta.txt');
      expect(
        find.textContaining('Trusted keys were preserved.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pump();
      expect(m.visibleEntries.single.name, 'alpha.txt');
      expect(
        find.textContaining('Trusted keys were preserved.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
