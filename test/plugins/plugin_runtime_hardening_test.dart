import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

Future<Object?> _run(
  PluginManager manager, {
  required String id,
  required String jsBody,
  Set<PluginPermissions> permissions = const {PluginPermissions.emit},
}) async {
  final result = Completer<Object?>();
  final sub = manager.emitStream.listen((e) {
    if (e['pluginId'] == id && !result.isCompleted) {
      result.complete(e['payload']);
    }
  });
  addTearDown(sub.cancel);
  await manager.loadPlugin(
    id: id,
    manifest: testManifest(
      id,
      permissions: {PluginPermissions.emit, ...permissions},
    ),
    settings: {},
    jsCode:
        '''
      function createPlugin(host) {
        const report = (value) => host.emit("result", JSON.stringify(value));
        const fail = (e) => report({ error: String(e && e.message || e) });
        return {
          id: "$id",
          onLoad() {
            $jsBody
          }
        };
      }
    ''',
  );
  final payload = await result.future.timeout(const Duration(seconds: 10));
  return jsonDecode(payload as String);
}

void main() {
  group('shared runtime intrinsics', () {
    late PluginManager manager;

    setUp(() => manager = PluginManager(kvStore: FakeKeyValueStoreService()));
    tearDown(() => manager.dispose());

    test(
      'a plugin cannot replace built-ins another plugin relies on',
      () async {
        await _run(
          manager,
          id: 'hooker.plugin',
          jsBody: '''
          const attempts = {};
          const tryIt = (name, fn) => {
            try { fn(); attempts[name] = "changed"; } catch (e) { attempts[name] = "refused"; }
          };
          tryIt("JSON.stringify", () => { JSON.stringify = () => "stolen"; });
          tryIt("JSON.parse", () => { JSON.parse = () => ({}); });
          tryIt("Promise.prototype.then", () => { Promise.prototype.then = () => {}; });
          tryIt("Function.prototype.call", () => { Function.prototype.call = () => {}; });
          tryIt("Array.prototype.push", () => { Array.prototype.push = () => 0; });
          tryIt("Object.defineProperty", () => { Object.defineProperty = () => {}; });
          tryIt("Object.prototype setter", () => {
            Object.defineProperty(Object.prototype, "token", { set(v) {} });
          });
          tryIt("Map.prototype.get", () => { Map.prototype.get = () => undefined; });
          tryIt("fetch response hook", () => { globalThis.__handleFetchResponse = () => {}; });
          tryIt("fetch request hook", () => { globalThis.__fetchFor = () => {}; });
          host.emit("result", JSON.stringify(attempts));
        ''',
        );

        final victim = await _run(
          manager,
          id: 'victim.plugin',
          jsBody: '''
          const seen = [];
          seen.push(JSON.stringify({ a: 1 }));
          seen.push(typeof Promise.prototype.then);
          const box = {};
          box.token = "secret";
          seen.push(Object.getOwnPropertyDescriptor(box, "token").value);
          report(seen);
        ''',
        );
        expect(victim, ['{"a":1}', 'function', 'secret']);
        expect(
          manager.js
              .evaluate('String(globalThis.__handleFetchResponse).length > 30')
              .stringResult,
          'true',
        );
      },
    );

    test('base64 helpers and binary built-ins cannot be hooked', () async {
      await _run(
        manager,
        id: 'sniffer.plugin',
        jsBody: '''
          globalThis.__stolen = [];
          const steal = (value) => { globalThis.__stolen.push(String(value)); };
          const attempt = (fn) => { try { fn(); } catch (e) {} };
          const realBtoa = globalThis.btoa;
          attempt(() => { globalThis.btoa = (v) => { steal(v); return realBtoa(v); }; });
          attempt(() => { Object.defineProperty(globalThis, "btoa", { value: (v) => { steal(v); return realBtoa(v); } }); });
          attempt(() => { globalThis.atob = (v) => { steal(v); return ""; }; });
          attempt(() => { Uint8Array.prototype.set = function () { steal("set"); }; });
          const typedArray = Object.getPrototypeOf(Uint8Array);
          attempt(() => { typedArray.prototype.subarray = function () { steal("subarray"); return this; }; });
          attempt(() => { ArrayBuffer.prototype.slice = function () { steal("slice"); return this; }; });
          attempt(() => { DataView.prototype.getUint8 = function () { steal("getUint8"); return 0; }; });
          if (typeof TextEncoder === "function") {
            attempt(() => { TextEncoder.prototype.encode = function (v) { steal(v); return new Uint8Array(); }; });
          }
          host.emit("result", JSON.stringify(true));
        ''',
      );

      final victim = await _run(
        manager,
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
      expect(victim, {
        'auth': 'dXNlcjpwYXNz',
        'decoded': 'user:pass',
        'first': 9,
        'tail': 2,
        'view': 0,
      });
      expect(
        manager.js.evaluate('JSON.stringify(globalThis.__stolen)').stringResult,
        '[]',
      );
    });

    test(
      'loaded plugin objects are not reachable from other plugins',
      () async {
        await _run(
          manager,
          id: 'victim.events',
          jsBody: '''
          globalThis.__victimEvents = 0;
          host.emit("result", JSON.stringify(true));
        ''',
        );
        final probe = await _run(
          manager,
          id: 'prober.plugin',
          jsBody: '''
          const seen = {
            registry: typeof globalThis.__plugins__,
            names: Object.getOwnPropertyNames(globalThis)
              .filter((name) => name.toLowerCase().includes("plugins")),
          };
          try {
            globalThis.__registerPlugin("guessed-token", { onEvent() {} });
            seen.registered = true;
          } catch (e) {
            seen.registered = false;
          }
          try { globalThis.__unregisterPlugin("guessed-token"); } catch (e) {}
          report(seen);
        ''',
        );
        expect((probe as Map)['registry'], 'undefined');
        expect(probe['names'], isEmpty);
      },
    );

    test('ordinary plugin code still runs on frozen built-ins', () async {
      final result = await _run(
        manager,
        id: 'ordinary.plugin',
        jsBody: '''
          class AppError extends Error {
            constructor(message) { super(message); this.name = "AppError"; }
          }
          const values = [3, 1, 2].sort().map((n) => n * 2);
          const map = new Map([["k", 1]]);
          const err = new AppError("boom");
          Promise.resolve(values).then((v) => report({
            v, k: map.get("k"), name: err.name, json: JSON.parse("[1]")
          }));
        ''',
      );
      expect(result, {
        'v': [2, 4, 6],
        'k': 1,
        'name': 'AppError',
        'json': [1],
      });
    });
  });

  test('every bundled plugin still loads on the frozen runtime', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    final extra = Platform.environment['DECAID_EXTRA_PLUGIN_DIRS'];
    final bundles = [
      ...Directory('assets/plugins').listSync().whereType<Directory>(),
      if (extra != null)
        for (final path in extra.split(':'))
          if (path.isNotEmpty) Directory(path),
    ].where((dir) => File('${dir.path}/plugin.js').existsSync()).toList();
    expect(bundles, isNotEmpty);
    for (final bundle in bundles) {
      final manifest = PluginManifest.fromJson(
        jsonDecode(File('${bundle.path}/manifest.json').readAsStringSync())
            as Map<String, dynamic>,
      );
      await manager.loadPlugin(
        id: manifest.id,
        manifest: manifest,
        settings: {},
        jsCode: File('${bundle.path}/plugin.js').readAsStringSync(),
      );
      expect(
        manager.loadedPlugins.map((plugin) => plugin.pluginId),
        contains(manifest.id),
        reason: bundle.path,
      );
    }
  });

  group('host API machine control from plugins', () {
    late HttpServer api;
    late PluginManager manager;
    final hits = <String>[];

    setUp(() async {
      hits.clear();
      api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      api.listen((request) async {
        hits.add('${request.method} ${request.uri.path}');
        request.response.write('{}');
        await request.response.close();
      });
      manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        hostApiPort: api.port,
      );
    });

    tearDown(() async {
      await manager.dispose();
      await api.close(force: true);
    });

    String fetchJs(String method, String path, {String host = '127.0.0.1'}) =>
        'fetch("http://$host:${api.port}$path", { method: "$method" })'
        '.then((r) => r.json().then((body) => report({ status: r.status, body })), fail);';

    final granted = <String>{};
    setUp(() {
      granted.clear();
      manager.machineControlGranted = granted.contains;
    });

    test('machine control writes need the user grant', () async {
      for (final (method, path) in [
        ('PUT', '/api/v1/machine/state/espresso'),
        ('POST', '/api/v1/machine/calibration'),
        ('POST', '/API/v1/machine/settings/advanced'),
        ('POST', '/api/v1/./machine/settings/advanced'),
      ]) {
        final id = 'writer.${path.hashCode}.${method.toLowerCase()}';
        final result = await _run(
          manager,
          id: id,
          permissions: {PluginPermissions.api},
          jsBody: fetchJs(method, path),
        );
        expect(result, {
          'status': 403,
          'body': {
            'error': contains('not allowed to control the machine'),
            'code': 'machine_control_not_granted',
          },
        }, reason: '$method $path');
      }
      for (final host in ['localhost', '0.0.0.0']) {
        final result = await _run(
          manager,
          id: 'writer.$host',
          permissions: {PluginPermissions.api},
          jsBody: fetchJs('PUT', '/api/v1/machine/state/idle', host: host),
        );
        expect((result as Map)['status'], 403, reason: host);
      }
      expect(hits, isEmpty);
    });

    test('a refused plugin raises a notice asking the user', () async {
      await _run(
        manager,
        id: 'skale.plugin',
        permissions: {PluginPermissions.api},
        jsBody: fetchJs('PUT', '/api/v1/machine/state/espresso'),
      );
      await manager.notifications.settled;
      final notice = manager.notifications.value.singleWhere(
        (notice) => notice.sourceId == 'skale.plugin',
      );
      expect(notice.id, machineControlNoticeId);
      expect(notice.message, contains('control the machine'));
      expect(
        notice.actions.single.type,
        NotificationActionType.reviewMachineControl,
      );
      expect(manager.notifications.isConfirmed(notice), isTrue);
    });

    test('a granted plugin may change machine state', () async {
      granted.add('skale.plugin');
      final start = await _run(
        manager,
        id: 'skale.plugin',
        permissions: {PluginPermissions.api},
        jsBody: fetchJs('PUT', '/api/v1/machine/state/espresso'),
      );
      expect((start as Map)['status'], 200);
      expect(hits, ['PUT /api/v1/machine/state/espresso']);
    });

    test('a revoked grant refuses again', () async {
      granted.add('skale.plugin');
      await _run(
        manager,
        id: 'skale.plugin',
        permissions: {PluginPermissions.api},
        jsBody: fetchJs('PUT', '/api/v1/machine/state/espresso'),
      );
      granted.remove('skale.plugin');
      final again = await _run(
        manager,
        id: 'skale.again',
        permissions: {PluginPermissions.api},
        jsBody: fetchJs('PUT', '/api/v1/machine/state/idle'),
      );
      expect((again as Map)['status'], 403);
      expect(hits, ['PUT /api/v1/machine/state/espresso']);
    });

    test('firmware stays refused even with the grant', () async {
      for (final path in [
        '/api/v1/machine/firmware',
        '/api/v1/machine/firmware/apply',
      ]) {
        granted.add('flasher.${path.length}');
        final result = await _run(
          manager,
          id: 'flasher.${path.length}',
          permissions: {PluginPermissions.api},
          jsBody: fetchJs('POST', path),
        );
        expect(result, {
          'status': 403,
          'body': {
            'error': contains('firmware'),
            'code': 'machine_control_forbidden',
          },
        }, reason: path);
      }
      expect(hits, isEmpty);
    });

    test('machine reads and other routes stay reachable', () async {
      final read = await _run(
        manager,
        id: 'reader.plugin',
        permissions: {PluginPermissions.api},
        jsBody: fetchJs('GET', '/api/v1/machine/info'),
      );
      expect((read as Map)['status'], 200);
      final other = await _run(
        manager,
        id: 'other.plugin',
        permissions: {PluginPermissions.api},
        jsBody: fetchJs('POST', '/api/v1/workflow'),
      );
      expect((other as Map)['status'], 200);
      expect(hits, ['GET /api/v1/machine/info', 'POST /api/v1/workflow']);
    });

    test('raw machine sockets and raw TCP to the host API are refused', () async {
      granted.addAll(['ws.plugin', 'tcp.plugin']);
      final ws = await _run(
        manager,
        id: 'ws.plugin',
        permissions: {PluginPermissions.networkWebsocket},
        jsBody:
            'host.transport.open({ kind: "websocket", url: "ws://127.0.0.1:${api.port}/ws/v1/machine/raw" })'
            '.then(() => report({ opened: true }), fail);',
      );
      expect((ws as Map)['error'], contains('machine control'));
      final tcp = await _run(
        manager,
        id: 'tcp.plugin',
        permissions: {PluginPermissions.networkTcp},
        jsBody:
            'host.transport.open({ kind: "tcp", host: "localhost", port: ${api.port} })'
            '.then(() => report({ opened: true }), fail);',
      );
      expect((tcp as Map)['error'], contains('machine control'));
      expect(hits, isEmpty);
    });
  });
}
