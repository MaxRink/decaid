import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../plugins/plugin_test_helpers.dart';

const _pluginId = 'visualizer.reaplugin';
const _managerToken = 'manager-token';
const _deviceAddress = '192.168.200.64';
const _lanPeer = '192.168.200.10';

class _Peer implements HttpConnectionInfo {
  _Peer(String address) : remoteAddress = InternetAddress(address);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 51000;

  @override
  int get localPort => 8080;
}

void main() {
  late FakeKeyValueStoreService store;
  late Handler handler;

  setUp(() async {
    store = FakeKeyValueStoreService();
    await store.set(namespace: _pluginId, key: 'token', value: 'secret');
    await store.set(
      namespace: 'streamlineSettings',
      key: 'theme',
      value: 'dark',
    );
    final app = Router().plus;
    KvStoreHandler(
      store: store,
      isPluginNamespace: (namespace) => namespace.toLowerCase() == _pluginId,
      deviceOrigins: ExtensionManagementBrowserOrigins(
        apiListenerPort: () => 8080,
        pagePorts: () => const {},
        deviceAddresses: () async => {_deviceAddress},
      ),
    ).addRoutes(app);
    final tokens = ProxyTokenService(skinToken: 'skin-token')
      ..registerToken(
        _managerToken,
        const ProxyCaller(
          id: 'api:manager',
          scopes: {ProxyTokenService.scopeExtensionsManage},
        ),
      );
    handler = buildWebServerHandler(
      app.call,
      proxyTokenService: tokens,
      requireExtensionManagementAuthorization: () async => false,
      browserOrigins: ExtensionManagementBrowserOrigins(
        apiListenerPort: () => 8080,
        pagePorts: () => const {},
        deviceAddresses: () async => const {},
      ),
    );
  });

  Future<Response> send(
    String method,
    String path, {
    String? bearer,
    Object? body,
    String? peer = _lanPeer,
  }) async => handler(
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {'authorization': ?(bearer == null ? null : 'Bearer $bearer')},
      body: body == null ? null : jsonEncode(body),
      context: {
        'shelf.io.connection_info': ?(peer == null ? null : _Peer(peer)),
      },
    ),
  );

  test('a plugin namespace cannot be read or written by a LAN client without a '
      'token', () async {
    for (final (method, path, body) in <(String, String, Object?)>[
      ('GET', '/api/v1/store/$_pluginId', null),
      ('GET', '/api/v1/store/$_pluginId?full=1', null),
      ('GET', '/api/v1/store/$_pluginId/token', null),
      ('GET', '/api/v1/store/VISUALIZER.reaplugin/token', null),
      ('POST', '/api/v1/store/$_pluginId/token', 'stolen'),
      ('DELETE', '/api/v1/store/$_pluginId/token', null),
    ]) {
      final response = await send(method, path, body: body);
      expect(response.statusCode, 403, reason: '$method $path');
      expect(await response.readAsString(), isNot(contains('secret')));
    }
    expect(await store.get(namespace: _pluginId, key: 'token'), 'secret');
  });

  test('requests without a socket peer are refused', () async {
    final response = await send(
      'GET',
      '/api/v1/store/$_pluginId/token',
      peer: null,
    );
    expect(response.statusCode, 403);
  });

  for (final peer in ['127.0.0.1', '::1', _deviceAddress]) {
    test('the device itself ($peer) may use a plugin namespace', () async {
      final read = await send(
        'GET',
        '/api/v1/store/$_pluginId/token',
        peer: peer,
      );
      expect(read.statusCode, 200);
      expect(jsonDecode(await read.readAsString()), 'secret');

      final write = await send(
        'POST',
        '/api/v1/store/$_pluginId/recipes',
        body: [1, 2],
        peer: peer,
      );
      expect(write.statusCode, 200);
      expect(await store.get(namespace: _pluginId, key: 'recipes'), [1, 2]);

      final all = await send(
        'GET',
        '/api/v1/store/$_pluginId?full=1',
        peer: peer,
      );
      expect(all.statusCode, 200);
    });
  }

  test('an extensions:manage token may use a plugin namespace', () async {
    final read = await send(
      'GET',
      '/api/v1/store/$_pluginId/token',
      bearer: _managerToken,
    );
    expect(read.statusCode, 200);
    expect(jsonDecode(await read.readAsString()), 'secret');
  });

  test('skin namespaces stay open', () async {
    final read = await send('GET', '/api/v1/store/streamlineSettings/theme');
    expect(read.statusCode, 200);
    final write = await send(
      'POST',
      '/api/v1/store/streamlineSettings/theme',
      body: 'light',
    );
    expect(write.statusCode, 200);
    expect(
      await store.get(namespace: 'streamlineSettings', key: 'theme'),
      'light',
    );
  });
}
