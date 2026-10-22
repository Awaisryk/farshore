import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:farshore/slider.dart';
import 'dart:async';
import 'package:farshore/bridge.dart';
import 'package:farshore/browser_model.dart';
import 'package:farshore/main.dart';

class RecordedSemantics {
  final graph = <int, List<int>>{};
  final pending = <int, List<int>>{};
  final orphans = <int>[];
  int batches = 0;
  void finish() {
    if (pending.isEmpty) return;
    batches++;
    graph.addAll(pending);
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in graph[id] ?? const <int>[]) {
        visit(child);
      }
    }

    visit(0);
    orphans.addAll(pending.keys.where((id) => !reachable.contains(id)));
    pending.clear();
  }

  void reset() {
    graph.clear();
    pending.clear();
    orphans.clear();
    batches = 0;
  }
}

/// Record the exact serialized updates passed to the native bridge, including
/// nodes absent from the framework's final in-memory tree.
class RecordingSemanticsBuilder implements ui.SemanticsUpdateBuilder {
  RecordingSemanticsBuilder(this.delegate, this.recording);
  final ui.SemanticsUpdateBuilder delegate;
  final RecordedSemantics recording;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final args = invocation.namedArguments;
      recording.pending[args[#id] as int] = List<int>.of(
        args[#childrenInTraversalOrder] as List<int>,
      );
      return Function.apply(
        delegate.updateNode,
        invocation.positionalArguments,
        args,
      );
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(
        delegate.updateCustomAction,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    if (invocation.memberName == #build) {
      recording.finish();
      return delegate.build();
    }
    return super.noSuchMethod(invocation);
  }
}

class RecordingSemanticsBinding extends AutomatedTestWidgetsFlutterBinding {
  final recording = RecordedSemantics();
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      RecordingSemanticsBuilder(
        super.createSemanticsUpdateBuilder(),
        recording,
      );
}

class AccessibilityBridgeStub implements BridgeClient {
  final hosts = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method == 'hosts') return hosts.future;
    if (method == 'set_favorite') {
      return {
        'favoriteHostIds': ['a', 'b'],
      };
    }
    if (method == 'list') {
      return {'path': params['path'], 'entries': [], 'fresh': true};
    }
    return {};
  }

  @override
  void dispose() {}
}

void main() {
  final binding = RecordingSemanticsBinding();
  testWidgets(
    'slider serializes no orphan nodes during incremental route updates',
    (tester) async {
      final semantics = tester.ensureSemantics();
      binding.recording.reset();
      final navigator = GlobalKey<NavigatorState>();
      var value = 0.3;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (context) => StatefulBuilder(
            builder: (context, setState) {
              return Scaffold(
                body: FarshoreSlider(
                  child: Slider(
                    value: value,
                    onChanged: (next) => setState(() => value = next),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      debugPrint(
        'AX_WRAPPED orphanIds=${binding.recording.orphans} batches=${binding.recording.batches}',
      );
      expect(binding.recording.orphans, isEmpty);
      SemanticsNode? adjustable;
      bool visit(SemanticsNode node) {
        if (node.getSemanticsData().hasAction(ui.SemanticsAction.increase)) {
          adjustable = node;
        }
        node.visitChildren(visit);
        return true;
      }

      visit(tester.getSemantics(find.byType(Slider)).owner!.rootSemanticsNode!);
      expect(adjustable, isNotNull);
      final sliderNode = adjustable!;
      expect(
        sliderNode.getSemanticsData().hasAction(ui.SemanticsAction.decrease),
        true,
      );
      sliderNode.owner!.performAction(
        sliderNode.id,
        ui.SemanticsAction.increase,
      );
      await tester.pump();
      expect(value, greaterThan(0.3));
      final drag = await tester.startGesture(
        tester.getCenter(find.byType(Slider)),
      );
      await drag.moveBy(const Offset(100, 0));
      await tester.pump(const Duration(milliseconds: 16));
      expect(binding.recording.orphans, isEmpty);
      await drag.up();
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(binding.recording.orphans, isEmpty);
      semantics.dispose();
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'two sliders remain connected to native semantics while a dialog opens, changes, and closes',
    (tester) async {
      final semantics = tester.ensureSemantics();
      binding.recording.reset();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Browser')),
        ),
      );
      var seek = 0.2, volume = 0.8;
      unawaited(
        showDialog<void>(
          context: navigator.currentContext!,
          builder: (context) => AlertDialog(
            content: SizedBox(
              width: 500,
              child: StatefulBuilder(
                builder: (context, setState) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FarshoreSlider(
                      child: Slider(
                        value: seek,
                        onChanged: (next) => setState(() => seek = next),
                      ),
                    ),
                    FarshoreSlider(
                      child: Slider(
                        value: volume,
                        onChanged: (next) => setState(() => volume = next),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Slider).first, const Offset(75, 0));
      await tester.pumpAndSettle();
      expect(binding.recording.orphans, isEmpty);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(binding.recording.orphans, isEmpty);
      semantics.dispose();
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'real browser startup, favorite reorder, views, and accessibility reenable serialize connected trees',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var semantics = tester.ensureSemantics();
      binding.recording.reset();
      final bridge = AccessibilityBridgeStub();
      final model = BrowserModel(bridge);
      await tester.pumpWidget(FarshoreApp(model: model));
      await tester.pump();
      bridge.hosts.complete({
        'hosts': [
          {
            'id': 'a',
            'alias': 'alpha',
            'hostname': 'alpha',
            'user': 'u',
            'port': 22,
          },
          {
            'id': 'b',
            'alias': 'beta',
            'hostname': 'beta',
            'user': 'u',
            'port': 22,
          },
        ],
        'favoriteHostIds': ['b'],
      });
      await tester.pumpAndSettle();
      await model.toggleFavorite(model.hosts.first);
      await tester.pumpAndSettle();
      await model.selectHost(model.hosts.first);
      await model.navigate('/');
      await tester.pumpAndSettle();
      model.view = BrowserView.list;
      model.changed();
      await tester.pumpAndSettle();
      model.view = BrowserView.grid;
      model.changed();
      await tester.pumpAndSettle();
      expect(binding.recording.orphans, isEmpty);
      semantics.dispose();
      await tester.pump();
      binding.recording.reset();
      semantics = tester.ensureSemantics();
      await tester.pump();
      expect(binding.recording.orphans, isEmpty);
      debugPrint(
        'AX_BROWSER connectedBatches=${binding.recording.batches} orphanIds=${binding.recording.orphans}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    },
    semanticsEnabled: false,
  );
}
