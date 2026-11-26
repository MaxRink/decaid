import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

const _forms = <String, String>{
  'valueOnly': 'Object.defineProperty(globalThis, name, { value: f });',
  'valueWritableFalse':
      'Object.defineProperty(globalThis, name, { value: f, writable: false });',
  'accessorGet': 'Object.defineProperty(globalThis, name, { get: function () { return f; } });',
};

String _probeJs(String target, String form) =>
    '''
  (function () {
    const name = ${jsonEncode(target)};
    const original = globalThis[name];
    let threw = false, threwMsg = null;
    const f = function () { return "__HOOKED__"; };
    try {
      ${_forms[form]}
    } catch (e) {
      threw = true;
      threwMsg = String((e && e.message) || e).slice(0, 70);
    }
    const d = Object.getOwnPropertyDescriptor(globalThis, name);
    let call = null;
    try {
      if (name === "btoa") call = String(globalThis.btoa("user:pass"));
      if (name === "atob") call = String(globalThis.atob("dXNlcjpwYXNz"));
      if (name === "JSON") call = String(globalThis.JSON.stringify({a: 1}));
      if (name === "Object") call = String(typeof globalThis.Object);
    } catch (e) { call = "threw:" + String((e && e.message) || e); }
    return JSON.stringify({
      threw: threw,
      threwMsg: threwMsg,
      sameIdentity: globalThis[name] === original,
      kind: d ? (("value" in d) ? "data" : "accessor") : null,
      writable: d ? d.writable : null,
      configurable: d ? d.configurable : null,
      call: call,
    });
  })();
''';

Future<String> _freshLockedProbe(String target, String form) async {
  final m = PluginManager(kvStore: FakeKeyValueStoreService());
  final payloads = <Object?>[];
  final sub = m.emitStream.listen((e) => payloads.add(e['payload']));
  addTearDown(sub.cancel);
  addTearDown(m.dispose);
  await m.loadPlugin(
    id: 'locker.plugin',
    manifest: testManifest(
      'locker.plugin',
      permissions: {PluginPermissions.emit},
    ),
    settings: {},
    jsCode: '''
      function createPlugin(host) {
        return { id: "locker.plugin", onLoad() { host.emit("result", "ok"); } };
      }
    ''',
  );
  final out = m.js.evaluate(_probeJs(target, form)).stringResult;
  return out;
}

void main() {
  test('defineProperty forms against pinned globals', () async {
    final results = <String, Object?>{};
    for (final target in ['btoa', 'atob', 'JSON', 'Object']) {
      results['${target}_valueOnly'] = await _freshLockedProbe(
        target,
        'valueOnly',
      );
    }
    for (final target in ['btoa', 'atob']) {
      results['${target}_valueWritableFalse'] = await _freshLockedProbe(
        target,
        'valueWritableFalse',
      );
      results['${target}_accessorGet'] = await _freshLockedProbe(
        target,
        'accessorGet',
      );
    }
    // ignore: avoid_print
    print('DEFINEPROP-PROBE ${jsonEncode(results)}');
  });
}
