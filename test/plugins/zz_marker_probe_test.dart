import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

Future<Object?> run(
  PluginManager m, {
  required String id,
  required String jsBody,
}) async {
  final payloads = <Object?>[];
  final sub = m.emitStream.listen((e) {
    if (e['pluginId'] == id) payloads.add(e['payload']);
  });
  addTearDown(sub.cancel);
  await m.loadPlugin(
    id: id,
    manifest: testManifest(id, permissions: {PluginPermissions.emit}),
    settings: {},
    jsCode:
        '''
      function createPlugin(host) {
        const report = (value) => host.emit("result", JSON.stringify(value));
        return { id: "$id", onLoad() { $jsBody } };
      }
    ''',
  );
  await Future<void>.delayed(const Duration(milliseconds: 60));
  return payloads.isEmpty ? null : jsonDecode(payloads.last! as String);
}

String marker(PluginManager m) =>
    m.js.evaluate('typeof globalThis.__reaprimePluginHostBridge').stringResult;

const sniffer = '''
  globalThis.__stolen = [];
  const steal = (value) => { globalThis.__stolen.push(String(value)); };
  const attempt = (fn) => { try { fn(); } catch (e) {} };
  const realBtoa = globalThis.btoa;
  attempt(() => { globalThis.btoa = (v) => { steal(v); return realBtoa(v); }; });
  attempt(() => {
    Object.defineProperty(globalThis, "btoa", {
      value: (v) => { steal(v); return realBtoa(v); }, writable: true, configurable: true
    });
  });
  attempt(() => {
    Object.defineProperty(globalThis, "btoa", {
      value: (v) => { steal(v); return realBtoa(v); }
    });
  });
  host.emit("result", JSON.stringify(true));
''';

const credentials = '''
  const auth = btoa("user:pass");
  report({ auth, decoded: atob(auth) });
''';

void main() {
  final out = <String, Object?>{};

  test('marker readings and forger', () async {
    // (1)(2) marker across a load and across a context boundary.
    final m1 = PluginManager(kvStore: FakeKeyValueStoreService());
    out['1_m1_before_first_load'] = marker(m1);
    await run(
      m1,
      id: 'throwaway.plugin',
      jsBody: 'host.emit("result", JSON.stringify(true));',
    );
    out['2_m1_after_first_load'] = marker(m1);
    out['2_m1_btoa_writable'] = m1.js
        .evaluate(
          'String(Object.getOwnPropertyDescriptor(globalThis,"btoa").writable)',
        )
        .stringResult;
    m1.dispose();

    final m2 = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(() => m2.dispose());
    out['3_m2_after_m1_dispose_before_load'] = marker(m2);

    // (3a) forger inside one runtime, then a sniffer in the same runtime.
    final m3 = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(() => m3.dispose());
    out['4_m3_before'] = marker(m3);
    await run(
      m3,
      id: 'forger.plugin',
      jsBody:
          'globalThis.__reaprimePluginHostBridge = {}; '
          'host.emit("result", JSON.stringify(true));',
    );
    out['4_m3_after_forger'] = marker(m3);
    await run(m3, id: 'sniffer.plugin', jsBody: sniffer);
    await run(m3, id: 'credentials.plugin', jsBody: credentials);
    out['4_sameRuntimeStolen'] = m3.js
        .evaluate('JSON.stringify(globalThis.__stolen)')
        .stringResult;

    // (3b) forger in one runtime, then the sniffer in a *new* runtime.
    final a = PluginManager(kvStore: FakeKeyValueStoreService());
    await run(
      a,
      id: 'forger.plugin',
      jsBody:
          'globalThis.__reaprimePluginHostBridge = {}; '
          'host.emit("result", JSON.stringify(true));',
    );
    out['5_forgerRuntimeMarker'] = marker(a);
    a.dispose();
    final b = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(() => b.dispose());
    out['5_newRuntimeAfterForger'] = marker(b);
    await run(b, id: 'sniffer.plugin', jsBody: sniffer);
    out['5_newRuntimeBtoaWritableBefore'] = b.js
        .evaluate(
          'String(Object.getOwnPropertyDescriptor(globalThis,"btoa").writable)',
        )
        .stringResult;
    await run(b, id: 'credentials.plugin', jsBody: credentials);
    out['5_crossRuntimeStolen'] = b.js
        .evaluate('JSON.stringify(globalThis.__stolen)')
        .stringResult;

    // ignore: avoid_print
    print('MARKER-PROBE ${jsonEncode(out)}');
  });
}
