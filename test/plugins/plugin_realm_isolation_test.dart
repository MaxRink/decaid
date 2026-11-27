import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

final _quickJsLibrary = Platform.environment['LIBQUICKJSC_PATH'];
final _defaultIsQuickJs =
    Platform.isAndroid || Platform.isLinux || Platform.isWindows;

final _engines = <String, JavascriptRuntime Function()>{
  _defaultIsQuickJs ? 'QuickJS (default engine)' : 'default engine': () =>
      getJavascriptRuntime(xhr: false),
  if (!_defaultIsQuickJs && _quickJsLibrary != null)
    'QuickJS ($_quickJsLibrary)': () =>
        QuickJsRuntime2()..enableHandlePromises(),
};

const _victimId = 'victim.plugin';
const _attackerId = 'attacker.plugin';

class _Harness {
  _Harness(this.createRuntime)
    : manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        createJsRuntime: () {
          final runtime = createRuntime();
          createdRuntimes.add(runtime);
          return runtime;
        },
      ) {
    subscription = manager.emitStream.listen(emits.add);
  }

  final JavascriptRuntime Function() createRuntime;
  static final createdRuntimes = <JavascriptRuntime>[];
  final PluginManager manager;
  final emits = <Map<String, dynamic>>[];
  late final StreamSubscription<Map<String, dynamic>> subscription;

  Future<void> load(
    String id,
    String body, {
    Set<PluginPermissions> permissions = const {PluginPermissions.emit},
    Map<String, dynamic> settings = const {},
  }) => manager.loadPlugin(
    id: id,
    manifest: testManifest(id, permissions: permissions),
    settings: settings,
    jsCode:
        '''
      function createPlugin(host) {
        $body
      }
    ''',
  );

  String eval(String pluginId, String expression) {
    final result = manager
        .jsRealmOf(pluginId)
        .evaluate('JSON.stringify($expression)');
    expect(result.isError, isFalse, reason: result.stringResult);
    return result.stringResult;
  }

  List<Object?> emitted(String pluginId, String event) => [
    for (final emit in emits)
      if (emit['pluginId'] == pluginId && emit['event'] == event)
        emit['payload'],
  ];

  Future<void> settle([int milliseconds = 20]) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  Future<void> dispose() async {
    await subscription.cancel();
    if (manager.lifecycle == PluginManagerLifecycle.active) {
      await manager.dispose();
    }
  }
}

const _victimBody = '''
  return {
    id: "victim.plugin",
    onEvent(event) {
      if (event.name !== "probe") return;
      const secret = "user:pass";
      const parts = [];
      for (const part of secret.split(":")) parts.push(part);
      let errorText;
      try { throw new Error("boom"); } catch (e) { errorText = String(e); }
      console.log("victim log line");
      host.emit("result", {
        auth: btoa(secret),
        decoded: atob(btoa(secret)),
        encoded: encodeURIComponent(secret),
        json: JSON.stringify({ secret }),
        keys: Object.keys({ x: 1, y: 2 }),
        parts,
        parsed: parseInt("42", 10),
        errorText,
        leakedGlobals: ["__stolen", "__plugins__", "attackerMarker"]
          .filter((name) => typeof globalThis[name] !== "undefined")
      });
    }
  };
''';

const _expectedVictimResult = {
  'auth': 'dXNlcjpwYXNz',
  'decoded': 'user:pass',
  'encoded': 'user%3Apass',
  'json': '{"secret":"user:pass"}',
  'keys': ['x', 'y'],
  'parts': ['user', 'pass'],
  'parsed': 42,
  'errorText': 'Error: boom',
  'leakedGlobals': <Object?>[],
};

const _attackerBody = r'''
  const stolen = [];
  globalThis.__stolen = stolen;
  globalThis.attackerMarker = true;
  const record = (name) => function () {
    stolen.push(name + ":" + Array.prototype.slice.call(arguments).join(","));
    return "__HOOKED__";
  };
  const define = Object.defineProperty;
  const names = ["btoa", "atob", "JSON", "Object", "encodeURIComponent",
    "parseInt", "console", "host", "fetch", "sendMessage", "globalThis",
    "__reaprimePluginHostBridge", "__reaprimePluginBridge", "__registerPlugin",
    "__unregisterPlugin", "__dispatchToPlugin", "__dispatchPluginHttp",
    "__handleFetchResponse", "__fetchFor", "__handleTransportReply",
    "__dispatchTransportEvent", "__handleDeviceReply",
    "__dispatchDeviceInvocation", "__timerSet", "__fireTimer",
    "__lockPluginHostBridge"];
  for (const name of names) {
    const hook = record(name);
    try { globalThis[name] = hook; } catch (e) {}
    try { define(globalThis, name, { value: hook }); } catch (e) {}
    try { define(globalThis, name, { value: hook, writable: true, configurable: true }); } catch (e) {}
    try { define(globalThis, name, { get: () => hook }); } catch (e) {}
  }
  const unfrozen = [
    [Object.getPrototypeOf([][Symbol.iterator]()), "next"],
    [Error.prototype, "toString"],
    [Map.prototype, "set"],
    [String.prototype, "toLowerCase"]
  ];
  for (const [target, name] of unfrozen) {
    const original = target[name];
    const hook = function () {
      const result = original.apply(this, arguments);
      stolen.push(name + ":" + String(this && this.message) + ":" +
        String(result && result.value) + ":" +
        Array.prototype.slice.call(arguments).join(","));
      return result;
    };
    try { target[name] = hook; } catch (e) {}
    try { define(target, name, { value: hook, writable: true, configurable: true }); } catch (e) {}
  }
  try { console.log = record("console.log"); } catch (e) {}
  return { id: "attacker.plugin" };
''';

void main() {
  for (final MapEntry(key: engine, value: createRuntime) in _engines.entries) {
    group('plugin realms on $engine', () {
      late _Harness harness;

      setUp(() => harness = _Harness(createRuntime));
      tearDown(() => harness.dispose());

      test('each plugin gets its own runtime and global object', () async {
        await harness.load(_victimId, _victimBody);
        await harness.load(_attackerId, _attackerBody);

        final victimRealm = harness.manager.jsRealmOf(_victimId);
        final attackerRealm = harness.manager.jsRealmOf(_attackerId);
        expect(identical(victimRealm, attackerRealm), isFalse);
        expect(harness.manager.liveRealmCount, 2);
        if (_defaultIsQuickJs || engine.startsWith('QuickJS')) {
          expect(victimRealm, isA<QuickJsRuntime2>());
        }
        expect(harness.eval(_victimId, 'typeof attackerMarker'), '"undefined"');
        expect(harness.eval(_attackerId, 'typeof attackerMarker'), '"boolean"');
        expect(harness.eval(_victimId, 'typeof __plugins__'), '"undefined"');
      });

      for (final victimFirst in [true, false]) {
        test('a plugin cannot hook the built-ins or host shims of a plugin '
            'loaded ${victimFirst ? 'before' : 'after'} it', () async {
          if (victimFirst) await harness.load(_victimId, _victimBody);
          await harness.load(
            _attackerId,
            _attackerBody,
            permissions: const {PluginPermissions.log},
          );
          if (!victimFirst) await harness.load(_victimId, _victimBody);

          harness.manager.dispatchEvent(_victimId, 'probe', null);
          await harness.settle();

          expect(harness.emitted(_victimId, 'result'), [_expectedVictimResult]);
          final stolen = jsonDecode(
            harness.eval(_attackerId, 'globalThis.__stolen'),
          ) as List;
          expect(stolen.where((entry) => '$entry'.contains('user')), isEmpty);
        });
      }

      test('a stolen bridge token is useless outside its own realm', () async {
        await harness.load(_victimId, '''
            globalThis.leakedToken = pluginBridgeToken;
            $_victimBody
          ''');
        await harness.load(_attackerId, 'return { id: "$_attackerId" };');
        final victimToken = jsonDecode(
          harness.eval(_victimId, 'globalThis.leakedToken'),
        );

        final forged = harness.manager.jsRealmOf(_attackerId).evaluate('''
            (function () {
              const token = ${jsonEncode(victimToken)};
              const send = (channel, message) =>
                sendMessage(channel, JSON.stringify(message));
              send("host", { bridgeToken: token, generation: 1,
                type: "emit", event: "forged", payload: null });
              send("host", { bridgeToken: token, pluginId: "$_victimId",
                generation: 1, type: "emit", event: "forged", payload: null });
              __reaprimePluginHostBridge.emit(token, 1, "forged", null);
              send("fetch", { id: 1, bridgeToken: token, generation: 1,
                url: "http://127.0.0.1:9/", method: "GET", headers: {} });
              send("transport", { bridgeToken: token, generation: 1,
                requestId: "x", type: "open", payload: { kind: "tcp" } });
              send("devices", { bridgeToken: token, generation: 1,
                requestId: "y", type: "register", payload: {} });
              return "sent";
            })()
          ''');
        expect(forged.stringResult, 'sent');
        await harness.settle();

        expect(harness.emits.where((e) => e['event'] == 'forged'), isEmpty);
        expect(harness.manager.activePendingOpCount, 0);
      });

      test('a forged generation or identity is rejected in the calling realm '
          'and leaves nothing pending', () async {
        await harness.load(
          _attackerId,
          r"""
            globalThis.results = {};
            globalThis.runForged = () => {
              const bridge = globalThis.__reaprimePluginBridge;
              const hostBridge = globalThis.__reaprimePluginHostBridge;
              const gen = pluginGeneration + 1;
              const settle = (name, promise) => promise.then(
                () => { results[name] = "resolved"; },
                (e) => { results[name] = "rejected:" + e.message; });
              const pending = (register, send) => new Promise((resolve, reject) => {
                register({ bridgeToken: pluginBridgeToken, resolve, reject });
                send();
              });
              settle("localApi", bridge.localApi(pluginId, gen, pluginBridgeToken,
                "/api/v1/plugins", "GET", null, null));
              settle("decentProxy", bridge.decentProxy(pluginId, gen, pluginBridgeToken,
                "/x", "GET", {}, null, null, false));
              settle("identity", bridge.localApi("other.plugin", pluginGeneration,
                pluginBridgeToken, "/api/v1/plugins", "GET", null, null));
              settle("fetch", hostBridge.fetch(pluginBridgeToken, gen, "http://127.0.0.1:9/", {}));
              settle("transport", pending(
                (entry) => __transportRegister("forged-transport", entry),
                () => hostBridge.transportRequest(pluginBridgeToken, gen,
                  "forged-transport", "open", { kind: "tcp", host: "127.0.0.1", port: 9 })));
              settle("devices", pending(
                (entry) => __deviceRegisterPending("forged-device", entry),
                () => hostBridge.deviceRequest(pluginBridgeToken, gen,
                  "forged-device", "register", { registrationHandle: "h" })));
              hostBridge.timerSet(pluginBridgeToken, gen, () => { results.timer = "fired"; }, 0);
            };
            return { id: "attacker.plugin" };
          """,
          permissions: const {
            PluginPermissions.api,
            PluginPermissions.networkTcp,
            PluginPermissions.manageExtensions,
            PluginPermissions.proxyDecentApi,
          },
        );

        harness.manager.jsRealmOf(_attackerId).evaluate('runForged()');
        for (var i = 0; i < 100; i++) {
          await harness.settle(10);
          final settled =
              jsonDecode(harness.eval(_attackerId, 'results')) as Map;
          if (settled.length >= 6) break;
        }

        const stale = 'rejected:Plugin generation changed';
        expect(jsonDecode(harness.eval(_attackerId, 'results')), {
          'localApi': stale,
          'decentProxy': stale,
          'identity': 'rejected:Invalid plugin bridge caller',
          'fetch': stale,
          'transport': stale,
          'devices': stale,
        });
        expect(
          jsonDecode(harness.eval(_attackerId, '__debugPendingCounts()')),
          {'decentProxy': 0, 'transport': 0, 'devices': 0, 'timers': 0},
        );
        expect(harness.eval(_attackerId, '__debugPendingFetchCount()'), '0');
        expect(harness.manager.activePendingOpCount, 0);
        expect(harness.manager.activeTimerCount, 0);
        expect(harness.manager.liveTransportCount, 0);
      });

      test('the plugin registry is per realm and not reachable', () async {
        await harness.load(_victimId, _victimBody);
        await harness.load(_attackerId, '''
          return {
            id: "$_attackerId",
            onLoad() {
              const attempts = [];
              for (const call of [
                () => globalThis.__registerPlugin({ id: "$_victimId", onEvent() {} }),
                () => globalThis.__dispatchToPlugin({ name: "probe", payload: null }),
                () => globalThis.__unregisterPlugin()
              ]) {
                try { call(); attempts.push("ok"); } catch (e) { attempts.push("threw"); }
              }
              globalThis.attempts = attempts;
            }
          };
        ''');

        harness.manager.dispatchEvent(_victimId, 'probe', null);
        await harness.settle();

        expect(harness.eval(_attackerId, 'attempts'), '["threw","ok","ok"]');
        expect(harness.emitted(_victimId, 'result'), [_expectedVictimResult]);
      });

      test('timers are routed per realm even when their ids collide', () async {
        for (final id in [_victimId, _attackerId]) {
          await harness.load(id, '''
            return {
              id: "$id",
              onLoad() {
                setTimeout(() => host.emit("fired", "$id"), 10);
              }
            };
          ''');
        }
        harness.manager.jsRealmOf(_attackerId).evaluate('''
          __cancelAllTimers();
          for (let id = 0; id < 50; id++) {
            __timerClear("guess", id);
            __fireTimer(id);
          }
        ''');
        await harness.settle(60);

        expect(harness.emitted(_victimId, 'fired'), [_victimId]);
        expect(harness.emitted(_attackerId, 'fired'), isEmpty);
      });

      test('fetch replies reach only the realm that asked', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          request.response.write(request.uri.path);
          await request.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';
        for (final id in [_victimId, _attackerId]) {
          await harness.load(
            id,
            '''
            return {
              id: "$id",
              onLoad() {
                fetch("$base/$id")
                  .then((response) => response.text())
                  .then((text) => host.emit("fetched", text));
              }
            };
          ''',
            permissions: const {PluginPermissions.api, PluginPermissions.emit},
          );
        }
        harness.manager.jsRealmOf(_attackerId).evaluate('''
          for (let id = 0; id < 5; id++) {
            __handleFetchResponse({ id, status: 200, headers: {}, body: "forged" });
          }
        ''');

        for (var i = 0; i < 200; i++) {
          if (harness.emitted(_victimId, 'fetched').isNotEmpty) break;
          await harness.settle(10);
        }

        expect(harness.emitted(_victimId, 'fetched'), ['/$_victimId']);
        expect(harness.emitted(_attackerId, 'fetched'), ['forged']);
      });

      test('emits are attributed to the realm that sent them', () async {
        await harness.load(_victimId, 'return { id: "$_victimId" };');
        await harness.load(_attackerId, '''
          return {
            id: "$_attackerId",
            onLoad() {
              host.emit("result", "from attacker");
              sendMessage("host", JSON.stringify({
                pluginId: "$_victimId", type: "emit", event: "result",
                payload: "spoofed"
              }));
            }
          };
        ''');
        await harness.settle();

        expect(harness.emitted(_attackerId, 'result'), ['from attacker']);
        expect(harness.emitted(_victimId, 'result'), isEmpty);
      });

      group('defence in depth inside a realm', () {
        const pinned = [
          'btoa',
          'atob',
          'JSON',
          'Object',
          'globalThis',
          'host',
          'fetch',
          'sendMessage',
          '__reaprimePluginHostBridge',
          '__reaprimePluginBridge',
          '__registerPlugin',
          '__dispatchToPlugin',
          '__dispatchPluginHttp',
          '__handleFetchResponse',
          '__fetchFor',
          '__handleTransportReply',
          '__handleDeviceReply',
          '__dispatchDeviceInvocation',
          '__lockPluginHostBridge',
        ];
        const forms = {
          'assignment': 'globalThis[name] = hook;',
          '{value}': 'define(globalThis, name, { value: hook });',
          '{value, writable: false}':
              'define(globalThis, name, { value: hook, writable: false });',
          '{value, writable: true, configurable: true}':
              'define(globalThis, name, '
              '{ value: hook, writable: true, configurable: true });',
          '{get}': 'define(globalThis, name, { get: () => hook });',
        };
        for (final MapEntry(key: form, value: retarget) in forms.entries) {
          test('$form cannot retarget a pinned global', () async {
            await harness.load(_attackerId, '''
              const define = Object.defineProperty;
              const names = ${jsonEncode(pinned)};
              const originals = names.map((name) => globalThis[name]);
              for (const name of names) {
                const hook = function () { return "__HOOKED__"; };
                try { $retarget } catch (e) {}
              }
              globalThis.changed = names.filter(
                (name, i) => globalThis[name] !== originals[i]);
              return { id: "$_attackerId" };
            ''');

            expect(harness.eval(_attackerId, 'changed'), '[]');
          });
        }

        test('built-ins and their prototypes are frozen', () async {
          await harness.load(_attackerId, 'return { id: "$_attackerId" };');
          expect(
            harness.eval(
              _attackerId,
              '[Object, Object.prototype, Array.prototype, Map.prototype, '
              'JSON, Promise.prototype, Uint8Array.prototype, '
              'Object.getPrototypeOf(Uint8Array).prototype]'
              '.every(Object.isFrozen)',
            ),
            'true',
          );
        });

        test('the engine timer ids keep counting after the lock', () async {
          await harness.load(_attackerId, '''
            const ids = [
              globalThis.setTimeout(function () {}, 60000),
              globalThis.setTimeout(function () {}, 60000),
              globalThis.setInterval(function () {}, 60000)
            ];
            globalThis.clearTimeout(ids[0]);
            globalThis.clearTimeout(ids[1]);
            globalThis.clearInterval(ids[2]);
            globalThis.ids = ids;
            return { id: "$_attackerId" };
          ''');
          final ids = jsonDecode(harness.eval(_attackerId, 'ids')) as List;
          expect(ids.toSet(), hasLength(3));
        });
      });

      test('ordinary plugin code keeps working in its realm', () async {
        await harness.load(
          _victimId,
          '''
          class PluginError extends Error {
            constructor(message) { super(message); this.name = "PluginError"; }
          }
          globalThis.counter = 0;
          return {
            id: "$_victimId",
            onLoad(settings) {
              globalThis.counter += 1;
              setTimeout(() => {
                const error = new PluginError("x");
                host.emit("ready", {
                  name: error.name,
                  counter: globalThis.counter,
                  setting: settings.mode,
                  bytes: Array.from(new Uint8Array([111, 107]))
                });
              }, 0);
            }
          };
        ''',
          settings: const {'mode': 'fast'},
        );
        await harness.settle();

        expect(harness.emitted(_victimId, 'ready'), [
          {
            'name': 'PluginError',
            'counter': 1,
            'setting': 'fast',
            'bytes': [111, 107],
          },
        ]);
      });

      group('lifecycle', () {
        test('unload disposes the realm and its engine timers', () async {
          await harness.load(_victimId, '''
            return {
              id: "$_victimId",
              onLoad() {
                globalThis.setTimeout(() => host.emit("late", null), 30);
                setTimeout(() => host.emit("late", null), 30);
              }
            };
          ''');
          final runtime = harness.manager.jsRealmOf(_victimId);

          await harness.manager.unloadPlugin(_victimId);
          await harness.settle(80);

          expect(runtime.isRuntimeActive, isFalse);
          expect(harness.manager.liveRealmCount, 0);
          expect(harness.manager.activeTimerCount, 0);
          expect(harness.emitted(_victimId, 'late'), isEmpty);
          expect(() => harness.manager.jsRealmOf(_victimId), throwsStateError);
        });

        test('reload starts from a fresh realm', () async {
          const body =
              '''
            globalThis.loads = (globalThis.loads || 0) + 1;
            return {
              id: "$_victimId",
              onLoad() { host.emit("loads", globalThis.loads); }
            };
          ''';
          await harness.load(_victimId, body);
          final first = harness.manager.jsRealmOf(_victimId);
          await harness.settle();
          await harness.load(_victimId, body);
          final second = harness.manager.jsRealmOf(_victimId);
          await harness.settle();

          expect(identical(first, second), isFalse);
          expect(first.isRuntimeActive, isFalse);
          expect(harness.manager.liveRealmCount, 1);
          expect(harness.emitted(_victimId, 'loads'), [1, 1]);
        });

        test('a plugin that fails to load leaves no realm behind', () async {
          final before = _Harness.createdRuntimes.length;
          await expectLater(
            harness.load(_victimId, 'throw new Error("broken");'),
            throwsException,
          );

          expect(harness.manager.liveRealmCount, 0);
          expect(harness.manager.loadedPlugins, isEmpty);
          expect(_Harness.createdRuntimes.length, before + 1);
          expect(_Harness.createdRuntimes.last.isRuntimeActive, isFalse);
        });

        test('dispose disposes every realm', () async {
          await harness.load(_victimId, 'return { id: "$_victimId" };');
          await harness.load(_attackerId, 'return { id: "$_attackerId" };');
          final runtimes = [
            harness.manager.jsRealmOf(_victimId),
            harness.manager.jsRealmOf(_attackerId),
          ];

          await harness.manager.dispose();

          expect(harness.manager.liveRealmCount, 0);
          expect(runtimes.map((runtime) => runtime.isRuntimeActive), [
            false,
            false,
          ]);
        });
      });
    });
  }
}
