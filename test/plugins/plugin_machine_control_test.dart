import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

void main() {
  late HttpServer api;
  late PluginManager manager;
  late List<String> hits;
  late Set<String> granted;

  setUp(() async {
    hits = [];
    granted = {};
    api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api.listen((request) async {
      hits.add('${request.method} ${request.uri.path}');
      await request.drain<void>();
      request.response.write('{}');
      await request.response.close();
    });
    manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      hostApiPort: api.port,
      fetchTimeout: const Duration(seconds: 5),
    )..machineControlGranted = granted.contains;
  });

  tearDown(() async {
    await manager.dispose();
    await api.close(force: true);
  });

  Future<Object?> run(
    String id,
    String jsBody, {
    Set<PluginPermissions> permissions = const {
      PluginPermissions.api,
      PluginPermissions.emit,
    },
  }) async {
    final result = Completer<Object?>();
    final sub = manager.emitStream.listen((event) {
      if (event['pluginId'] == id && !result.isCompleted) {
        result.complete(event['payload']);
      }
    });
    addTearDown(sub.cancel);
    await manager.loadPlugin(
      id: id,
      manifest: testManifest(id, permissions: permissions),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          const report = (value) => host.emit("result", value);
          const fail = (e) => report({ error: String(e && e.message || e) });
          return { id: "$id", onLoad() { $jsBody } };
        }
      ''',
    );
    return result.future.timeout(const Duration(seconds: 10));
  }

  Future<Object?> fetchAs(
    String id,
    String method,
    String path, {
    String host = '127.0.0.1',
  }) => run(
    id,
    'fetch("http://$host:${api.port}$path", { method: "$method" })'
    '.then((r) => r.text().then((t) => report({ status: r.status, '
    'body: t ? JSON.parse(t) : null })), fail);',
  );

  test('machine writes need the user grant', () async {
    var n = 0;
    for (final (method, path) in [
      ('PUT', '/api/v1/machine/state/espresso'),
      ('POST', '/api/v1/machine/settings'),
      ('POST', '/API/v1/machine/settings/advanced'),
      ('POST', '/api/v1/./machine/calibration'),
      ('POST', '/api/v1//machine/profile'),
      ('POST', '/api/v1/%6dachine/shotSettings'),
      ('DELETE', '/api/v1/machine/settings/reset'),
    ]) {
      final result = await fetchAs('writer${n++}.plugin', method, path);
      expect(result, {
        'status': 403,
        'body': {
          'error': contains('not allowed to control the machine'),
          'code': 'machine_control_not_granted',
        },
      }, reason: '$method $path');
    }
    for (final host in ['localhost', '0.0.0.0']) {
      final result = await fetchAs(
        'named${n++}.plugin',
        'PUT',
        '/api/v1/machine/state/idle',
        host: host,
      );
      expect((result as Map)['status'], 403, reason: host);
    }
    expect(hits, isEmpty);
  });

  test('a refused plugin raises a notice asking the user', () async {
    await fetchAs('skale.plugin', 'PUT', '/api/v1/machine/state/espresso');
    await manager.notifications.settled;
    final notice = manager.notifications.value.singleWhere(
      (notice) => notice.sourceId == 'skale.plugin',
    );
    expect(notice.id, machineControlNoticeId);
    expect(notice.message, contains('control the machine'));
  });

  test('the grant is checked for the realm the request came from', () async {
    granted.add('skale.plugin');
    final allowed = await fetchAs(
      'skale.plugin',
      'PUT',
      '/api/v1/machine/state/espresso',
    );
    expect((allowed as Map)['status'], 200);
    expect(hits, ['PUT /api/v1/machine/state/espresso']);

    // A second plugin cannot borrow the grant by naming the granted plugin.
    final borrowed = await run(
      'other.plugin',
      'globalThis.__reaprimePluginHostBridge.fetch("skale.plugin", 1, '
          '"http://127.0.0.1:${api.port}/api/v1/machine/state/idle", '
          '{ method: "PUT" }).then((r) => report({ status: r.status }), fail);',
    );
    expect(borrowed, isNot({'status': 200}));
    final own = await fetchAs(
      'other.plugin2',
      'PUT',
      '/api/v1/machine/state/idle',
    );
    expect((own as Map)['status'], 403);
    expect(hits, ['PUT /api/v1/machine/state/espresso']);
  });

  test('a revoked grant refuses again', () async {
    granted.add('skale.plugin');
    await fetchAs('skale.plugin', 'PUT', '/api/v1/machine/state/espresso');
    granted.remove('skale.plugin');
    await manager.unloadPlugin('skale.plugin');
    final again = await fetchAs(
      'skale.plugin',
      'PUT',
      '/api/v1/machine/state/idle',
    );
    expect((again as Map)['status'], 403);
    expect(hits, ['PUT /api/v1/machine/state/espresso']);
  });

  test(
    'firmware, grants and the raw socket stay refused with the grant',
    () async {
      var n = 0;
      for (final (method, path, error) in [
        ('POST', '/api/v1/machine/firmware', 'firmware'),
        ('POST', '/api/v1/machine/firmware/apply', 'firmware'),
        ('PUT', '/api/v1/plugins/flasher0.plugin/machine-control', 'grants'),
        ('PUT', '/api/v1/plugins/other.plugin/machine-control/', 'grants'),
        ('GET', '/ws/v1/machine/raw', 'raw machine socket'),
      ]) {
        final id = 'flasher${n++}.plugin';
        granted.add(id);
        final result = await fetchAs(id, method, path);
        expect(result, {
          'status': 403,
          'body': {
            'error': contains(error),
            'code': 'machine_control_forbidden',
          },
        }, reason: '$method $path');
      }
      expect(hits, isEmpty);
    },
  );

  test('machine reads and other routes keep working without a grant', () async {
    expect(
      ((await fetchAs('reader.plugin', 'GET', '/api/v1/machine/info'))
          as Map)['status'],
      200,
    );
    expect(
      ((await fetchAs('other.plugin', 'PUT', '/api/v1/workflow'))
          as Map)['status'],
      200,
    );
    expect(hits, ['GET /api/v1/machine/info', 'PUT /api/v1/workflow']);
  });

  test('another server on the API port number is not the host', () async {
    // Same port, different peer: only this device's addresses count. The
    // loopback server stands in for "this device", so the check is
    // exercised from the other side: another port is never the host API.
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    other.listen((request) async {
      hits.add('other ${request.method} ${request.uri.path}');
      await request.response.close();
    });
    final result = await run(
      'remote.plugin',
      'fetch("http://127.0.0.1:${other.port}/api/v1/machine/state/idle", '
          '{ method: "PUT" }).then((r) => report({ status: r.status }), fail);',
    );
    expect(result, {'status': 200});
    expect(hits, ['other PUT /api/v1/machine/state/idle']);
  });

  test('raw TCP to the host API and the raw machine socket are refused', () async {
    granted.addAll(['tcp.plugin', 'ws.plugin', 'wsname.plugin']);
    const transport = {
      PluginPermissions.emit,
      PluginPermissions.networkTcp,
      PluginPermissions.networkWebsocket,
    };
    final tcp = await run(
      'tcp.plugin',
      'host.transport.open({ kind: "tcp", host: "127.0.0.1", port: ${api.port} })'
          '.then(() => report("opened"), (e) => report({ error: e.message, code: e.code }));',
      permissions: transport,
    );
    expect(tcp, {
      'error': contains('raw connections to the host API'),
      'code': 'machine_control_forbidden',
    });
    for (final (id, host) in [
      ('ws.plugin', '127.0.0.1'),
      ('wsname.plugin', 'rebind.example'),
    ]) {
      final ws = await run(
        id,
        'host.transport.open({ kind: "websocket", '
        'url: "ws://$host:${api.port}/ws/v1/machine/raw" })'
        '.then(() => report("opened"), (e) => report({ error: e.message, code: e.code }));',
        permissions: transport,
      );
      expect(ws, {
        'error': contains('raw machine socket'),
        'code': 'machine_control_forbidden',
      }, reason: host);
    }
    expect(hits, isEmpty);
  });
}
