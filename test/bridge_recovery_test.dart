import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:farshore/bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = r'''
import json, os, sys, time
from pathlib import Path
log = Path(__file__).with_suffix('.events')
for line in sys.stdin:
    r = json.loads(line)
    p = r['params']
    records = log.read_text().splitlines() if log.exists() else []
    count = sum(json.loads(s)['method'] == r['method'] for s in records) + 1
    with log.open('a') as f:
        f.write(json.dumps({'method': r['method'], 'pid': os.getpid()}) + '\n')
    if p.get('crash') and count == 1:
        sys.exit(0)
    if p.get('late_exit') and count == 1:
        sys.stdout.close()
        os.close(1)
        time.sleep(.3)
        sys.exit(0)
    if p.get('malformed') and count == 1:
        print('invalid json', flush=True)
        continue
    if p.get('delay'):
        time.sleep(p['delay'])
    out = {'version': 1, 'id': r['id'], 'ok': True,
           'result': {'method': r['method'], 'pid': os.getpid(), 'count': count}}
    if p.get('error') and count <= p.get('failures', 99):
        out.update(ok=False, error={'code': p['error'], 'message': 'Fixture failure'})
    print(json.dumps(out), flush=True)
''';

void main() {
  late Directory directory;
  late File script;
  late ProcessBridge bridge;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('farshore-recovery-');
    script = File('${directory.path}/bridge.py');
    await script.writeAsString(_fixture);
    bridge = ProcessBridge(
      root: directory.path,
      script: script.path,
      retryDelays: const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
      ],
      requestTimeout: const Duration(seconds: 3),
    );
  });
  tearDown(() async {
    bridge.dispose();
    // Children drain stdin before the temporary fixture is removed.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await directory.delete(recursive: true);
  });

  Future<List<Map<String, dynamic>>> events() async => (await File(
    '${directory.path}/bridge.events',
  ).readAsLines()).map((s) => jsonDecode(s) as Map<String, dynamic>).toList();

  test('a dead helper is restarted for a folder read', () async {
    final result = await bridge.call('list', {'crash': true});
    expect(result['count'], 2);
    final records = await events();
    expect(records.map((r) => r['pid']).toSet(), hasLength(2));
    expect(bridge.recovery.value.phase, BridgeRecoveryPhase.ready);
  });

  test(
    'an unsafe file open is never repeated and next call can reconnect',
    () async {
      await expectLater(
        bridge.call('open', {'crash': true}),
        throwsA(
          isA<BridgeFailure>().having((e) => e.code, 'code', 'bridge_closed'),
        ),
      );
      expect((await bridge.call('status'))['method'], 'status');
      expect(
        (await events()).where((r) => r['method'] == 'open'),
        hasLength(1),
      );
    },
  );

  test(
    'late exit from the previous process cannot fail its replacement',
    () async {
      final result = await bridge.call('list', {'late_exit': true});
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((await bridge.call('status'))['pid'], result['pid']);
    },
  );

  test('malformed output resets the process and read can recover', () async {
    expect((await bridge.call('list', {'malformed': true}))['count'], 2);
  });

  test('network reads retry twice with a visible recovery state', () async {
    final attempts = <int>[];
    bridge.recovery.addListener(() {
      if (bridge.recovery.value.phase == BridgeRecoveryPhase.retrying) {
        attempts.add(bridge.recovery.value.attempt);
      }
    });
    expect(
      (await bridge.call('list', {
        'error': 'connection_failed',
        'failures': 2,
      }))['count'],
      3,
    );
    expect(attempts, [1, 2]);
  });

  test(
    'retry limit terminates and authentication failures are never retried',
    () async {
      await expectLater(
        bridge.call('list', {'error': 'timeout'}),
        throwsA(isA<BridgeFailure>()),
      );
      expect((await events()), hasLength(3));
      await expectLater(
        bridge.call('list', {'error': 'host_identity_changed'}),
        throwsA(
          isA<BridgeFailure>().having(
            (e) => e.code,
            'code',
            'host_identity_changed',
          ),
        ),
      );
      await expectLater(
        bridge.call('list', {'error': 'authentication_unavailable'}),
        throwsA(
          isA<BridgeFailure>().having(
            (e) => e.code,
            'code',
            'authentication_unavailable',
          ),
        ),
      );
      expect((await events()), hasLength(5));
    },
  );

  test('cancellation stops a queued retry without replaying it', () async {
    final retrying = Completer<void>();
    bridge.recovery.addListener(() {
      if (bridge.recovery.value.phase == BridgeRecoveryPhase.retrying &&
          !retrying.isCompleted) {
        retrying.complete();
      }
    });
    final request = bridge.call('list', {'error': 'connection_failed'});
    final assertion = expectLater(
      request,
      throwsA(
        isA<BridgeFailure>().having(
          (e) => e.code,
          'code',
          'recovery_cancelled',
        ),
      ),
    );
    await retrying.future;
    bridge.cancelRecovery();
    await assertion;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(await events(), hasLength(1));
    expect((await bridge.call('status'))['method'], 'status');
  });

  test('startup failure does not poison later attempts', () async {
    await script.delete();
    await expectLater(bridge.call('hosts'), throwsA(isA<BridgeFailure>()));
    await script.writeAsString(_fixture);
    expect((await bridge.call('hosts'))['method'], 'hosts');
  });

  test('helper imports ignore modules beside the script', () async {
    await File('${directory.path}/json.py').writeAsString(
      "raise RuntimeError('A local module must not replace the bundled standard library')\n",
    );
    expect((await bridge.call('hosts'))['method'], 'hosts');
    expect(
      await Directory(
        directory.path,
      ).list().any((file) => file.path.endsWith('__pycache__')),
      false,
    );
  });

  test(
    'oversized requests are rejected before writing to the helper',
    () async {
      await expectLater(
        bridge.call('save_workspace', {'value': 'x' * 65536}),
        throwsA(
          isA<BridgeFailure>().having(
            (e) => e.code,
            'code',
            'request_too_large',
          ),
        ),
      );
      expect((await bridge.call('status'))['method'], 'status');
      expect(await events(), hasLength(1));
    },
  );

  test('disposing fails pending requests and never restarts', () async {
    final request = bridge.call('status', {'delay': .5});
    final assertion = expectLater(request, throwsA(isA<BridgeFailure>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    bridge.dispose();
    await assertion;
    await expectLater(bridge.call('hosts'), throwsA(isA<BridgeFailure>()));
  });
}
