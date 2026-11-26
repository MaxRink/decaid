import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

/// Investigation-only probe. Fails on purpose so the payload lands in the CI
/// error event, where it is readable without the summariser.
///
/// Answers, in one run:
///  (a) the real descriptor/identity of btoa+atob, from the host AND from
///      inside a plugin body, and which route an assignment takes;
///  (b) whether the original failure needs prior tests / a warm context;
///  (c) whether btoa is an own property of globalThis or reached by prototype;
///  (d) whether a plugin body's globalThis is the same object the lock pinned.
void main() {
  final findings = <String, Object?>{};

  Future<Object?> run(
    PluginManager manager, {
    required String id,
    required String jsBody,
  }) async {
    final payloads = <Object?>[];
    final sub = manager.emitStream.listen((e) {
      if (e['pluginId'] == id) payloads.add(e['payload']);
    });
    addTearDown(sub.cancel);
    await manager.loadPlugin(
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

  String probe(PluginManager manager) => manager.js.evaluate('''
    (function () {
      const out = {};
      for (const name of ["btoa", "atob"]) {
        const d = Object.getOwnPropertyDescriptor(globalThis, name);
        const chain = [];
        let o = globalThis, depth = 0;
        while (o && depth < 8) {
          if (Object.prototype.hasOwnProperty.call(o, name)) {
            chain.push(o === globalThis ? "globalThis" : "proto" + depth);
          }
          o = Object.getPrototypeOf(o); depth++;
        }
        out[name] = {
          typeofValue: typeof globalThis[name],
          own: Object.prototype.hasOwnProperty.call(globalThis, name),
          inOperator: (name in globalThis),
          descKeys: d ? Object.keys(d).sort() : null,
          writable: d ? d.writable : null,
          configurable: d ? d.configurable : null,
          enumerable: d ? d.enumerable : null,
          hasValue: d ? ("value" in d) : null,
          fnLength: d && ("value" in d) && typeof d.value === "function" ? d.value.length : null,
          fnSrcHead: d && ("value" in d) && typeof d.value === "function"
            ? String(d.value).slice(0, 48) : null,
          foundOn: chain,
        };
      }
      out.globalThisDesc = (function () {
        const d = Object.getOwnPropertyDescriptor(globalThis, "globalThis");
        return d ? {writable: d.writable, configurable: d.configurable, hasValue: "value" in d} : null;
      })();
      out.objectFrozen = Object.isFrozen(Object);
      out.objectProtoFrozen = Object.isFrozen(Object.prototype);
      out.consoleDesc = (function () {
        const d = Object.getOwnPropertyDescriptor(globalThis, "console");
        return d ? {writable: d.writable, configurable: d.configurable} : null;
      })();
      out.lockDefined = typeof globalThis.__lockPluginHostBridge;
      out.bridgeLocked = Boolean(globalThis.__reaprimePluginHostBridge);
      return JSON.stringify(out);
    })();
  ''').stringResult;

  // Assignment route from the host, recorded before/after.
  String assignRoute(PluginManager manager) => manager.js.evaluate('''
    (function () {
      const before = globalThis.btoa;
      const ownBefore = Object.prototype.hasOwnProperty.call(globalThis, "btoa");
      let threw = null;
      try { globalThis.btoa = function () { return "hooked"; }; }
      catch (e) { threw = String(e && e.message || e).slice(0, 80); }
      const d = Object.getOwnPropertyDescriptor(globalThis, "btoa");
      const out = {
        changed: globalThis.btoa !== before,
        ownBefore: ownBefore,
        ownAfter: Object.prototype.hasOwnProperty.call(globalThis, "btoa"),
        threw: threw,
        valueIsAssigned: d && ("value" in d) && String(d.value).indexOf("hooked") !== -1,
        callResult: String(globalThis.btoa("user:pass")),
      };
      try { globalThis.btoa = before; } catch (_) {}
      return JSON.stringify(out);
    })();
  ''').stringResult;

  // (a) host-side, before any load.
  test('00 host probe before load', () async {
    final m = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(() => m.dispose());
    findings['hostBeforeLoad'] = probe(m);
  });

  // (a) host-side, after the lock has run (first loadPlugin does it).
  test('01 host probe after lock', () async {
    final m = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(() => m.dispose());
    await run(
      m,
      id: 'noop.plugin',
      jsBody: 'host.emit("result", JSON.stringify(true));',
    );
    findings['hostAfterLock'] = probe(m);
    findings['assignRouteAfterLock'] = assignRoute(m);
    findings['fromPluginGlobalIdentity'] = await run(
      m,
      id: 'identity.plugin',
      jsBody: '''
        globalThis.__fromPluginProbe = "set-by-plugin";
        const d = Object.getOwnPropertyDescriptor(globalThis, "btoa");
        report({
          seesSameGlobal: globalThis.__fromPluginProbe === "set-by-plugin",
          objectFrozen: Object.isFrozen(Object),
          btoaWritable: d ? d.writable : null,
          btoaConfigurable: d ? d.configurable : null,
          lockDefined: typeof globalThis.__lockPluginHostBridge,
        });
      ''',
    );
    findings['datapathRoundTrip'] = await run(
      m,
      id: 'roundtrip.plugin',
      jsBody: 'report({ sawProbe: String(globalThis.__fromPluginProbe) });',
    );
  });

  // (b) does the original failure need prior tests? Fresh manager, exact
  // original sequence, as the very first plugin load in this process' history
  // for this manager.
  test('02 replay original sequence on a cold manager', () async {
    final m = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(() => m.dispose());
    await run(
      m,
      id: 'sniffer.plugin',
      jsBody: '''
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
        attempt(() => { globalThis.atob = (v) => { steal(v); return ""; }; });
        attempt(() => { Uint8Array.prototype.set = function () { steal("set"); }; });
        attempt(() => {
          const typedArray = Object.getPrototypeOf(Uint8Array);
          typedArray.prototype.subarray = function () { steal("subarray"); return this; };
        });
        attempt(() => { ArrayBuffer.prototype.slice = function () { steal("slice"); return this; }; });
        attempt(() => { DataView.prototype.getUint8 = function () { steal("getUint8"); return 0; }; });
        if (typeof TextEncoder === "function") {
          attempt(() => { TextEncoder.prototype.encode = function (v) { steal(v); return new Uint8Array(); }; });
        }
        host.emit("result", JSON.stringify(true));
      ''',
    );
    final victim = await run(
      m,
      id: 'credentials.plugin',
      jsBody: '''
        const auth = btoa("user:pass");
        const bytes = new Uint8Array([1, 2, 3]);
        bytes.set([9], 0);
        const tail = bytes.subarray(1);
        const view = new DataView(new ArrayBuffer(2).slice(0));
        report({ auth, decoded: atob(auth), first: bytes[0], tail: tail.length, view: view.getUint8(0) });
      ''',
    );
    findings['coldReplayVictim'] = victim;
    findings['coldReplayStolen'] = m.js
        .evaluate('JSON.stringify(globalThis.__stolen)')
        .stringResult;
    findings['coldReplayHostProbe'] = probe(m);
  });

  // (c) after a plugin has already been loaded in a warm manager.
  test('03 replay after a warm load', () async {
    final m = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(() => m.dispose());
    await run(
      m,
      id: 'warmup.plugin',
      jsBody: 'host.emit("result", JSON.stringify(true));',
    );
    await run(
      m,
      id: 'sniffer.plugin',
      jsBody: '''
        globalThis.__stolen = [];
        const steal = (value) => { globalThis.__stolen.push(String(value)); };
        const realBtoa = globalThis.btoa;
        try { globalThis.btoa = (v) => { steal(v); return realBtoa(v); }; } catch (e) {}
        host.emit("result", JSON.stringify(true));
      ''',
    );
    await run(
      m,
      id: 'credentials.plugin',
      jsBody: '''
        const auth = btoa("user:pass");
        report({ auth, decoded: atob(auth) });
      ''',
    );
    findings['warmReplayStolen'] = m.js
        .evaluate('JSON.stringify(globalThis.__stolen)')
        .stringResult;
  });

  tearDownAll(() {
    fail('RESIDUAL-PROBE ${jsonEncode(findings)}');
  });
}
