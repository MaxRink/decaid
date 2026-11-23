import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    final bundles = Directory('assets/plugins')
        .listSync()
        .whereType<Directory>()
        .where((dir) => File('${dir.path}/plugin.js').existsSync())
        .toList();
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
        '.then((r) => report({ status: r.status }), fail);';

    test('machine control writes through fetch are refused', () async {
      for (final (method, path) in [
        ('PUT', '/api/v1/machine/state/espresso'),
        ('POST', '/api/v1/machine/firmware'),
        ('POST', '/api/v1/machine/calibration'),
        ('POST', '/API/v1/machine/settings/advanced'),
        ('POST', '/api/v1/./machine/settings/advanced'),
      ]) {
        final result = await _run(
          manager,
          id: 'writer.${path.hashCode}.${method.toLowerCase()}',
          permissions: {PluginPermissions.api},
          jsBody: fetchJs(method, path),
        );
        expect(
          (result as Map)['error'],
          contains('machine control'),
          reason: '$method $path',
        );
      }
      for (final host in ['localhost', '0.0.0.0']) {
        final result = await _run(
          manager,
          id: 'writer.$host',
          permissions: {PluginPermissions.api},
          jsBody: fetchJs('PUT', '/api/v1/machine/state/idle', host: host),
        );
        expect(
          (result as Map)['error'],
          contains('machine control'),
          reason: host,
        );
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
      expect(read, {'status': 200});
      final other = await _run(
        manager,
        id: 'other.plugin',
        permissions: {PluginPermissions.api},
        jsBody: fetchJs('POST', '/api/v1/workflow'),
      );
      expect(other, {'status': 200});
      expect(hits, ['GET /api/v1/machine/info', 'POST /api/v1/workflow']);
    });

    test('raw machine sockets and raw TCP to the host API are refused', () async {
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
