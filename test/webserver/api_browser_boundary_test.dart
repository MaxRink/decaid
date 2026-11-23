import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

class _Peer implements HttpConnectionInfo {
  _Peer(String address) : remoteAddress = InternetAddress(address);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 51000;

  @override
  int get localPort => 8080;
}

const _connectionInfoKey = 'shelf.io.connection_info';
const _deviceAddress = '192.168.12.64';
const _skinPort = 25707;
const _managerToken = 'manager-token';
const _crossOriginError =
    'This API does not accept requests from this browser origin';
const _hostError = 'This API only answers browsers on the device address';

void main() {
  late List<String> reached;
  late bool protectedMode;
  late Handler handler;

  setUp(() {
    reached = [];
    protectedMode = false;
    final routes = Router()
      ..get('/api/v1/machine/state', (Request r) {
        reached.add('GET state');
        return Response.ok('{}');
      })
      ..put('/api/v1/machine/state/<s>', (Request r, String s) {
        reached.add('PUT state');
        return Response.ok('{}');
      })
      ..post('/api/v1/plugins/<id>/<endpoint>', (
        Request r,
        String id,
        String e,
      ) {
        reached.add('POST plugin');
        return Response.ok('{}');
      })
      ..get('/ws/v1/machine/raw', (Request r) {
        reached.add('GET raw');
        return Response.ok('upgraded');
      })
      ..get('/ws/v1/machine/snapshot', (Request r) {
        reached.add('GET snapshot');
        return Response.ok('upgraded');
      })
      ..post('/api/v1/machine/firmware', (Request r) {
        reached.add('POST firmware');
        return Response.ok('{}');
      })
      ..post('/api/v1/machine/firmware/apply', (Request r) {
        reached.add('POST firmware/apply');
        return Response.ok('{}');
      })
      ..post('/api/v1/machine/calibration', (Request r) {
        reached.add('POST calibration');
        return Response.ok('{}');
      })
      ..put('/api/v1/machine/calibration/<t>', (Request r, String t) {
        reached.add('PUT calibration/target');
        return Response.ok('{}');
      })
      ..put('/api/v1/machine/scaleCalibration', (Request r) {
        reached.add('PUT scaleCalibration');
        return Response.ok('{}');
      })
      ..post('/api/v1/machine/settings/advanced', (Request r) {
        reached.add('POST advanced');
        return Response.ok('{}');
      })
      ..delete('/api/v1/machine/settings/reset', (Request r) {
        reached.add('DELETE reset');
        return Response.ok('{}');
      });
    final tokens = ProxyTokenService(skinToken: 'skin-token')
      ..registerToken(
        _managerToken,
        const ProxyCaller(
          id: 'api:manager',
          scopes: {ProxyTokenService.scopeExtensionsManage},
        ),
      );
    handler = buildWebServerHandler(
      routes.call,
      proxyTokenService: tokens,
      requireExtensionManagementAuthorization: () async => protectedMode,
      browserOrigins: ExtensionManagementBrowserOrigins(
        apiListenerPort: () => 8080,
        pagePorts: () => const {_skinPort},
        deviceAddresses: () async => const {_deviceAddress},
      ),
    );
  });

  Future<Response> send(
    String method,
    String path, {
    String host = 'localhost:8080',
    String? origin,
    String peer = '127.0.0.1',
    Map<String, String> headers = const {},
  }) async => handler(
    Request(
      method,
      Uri.parse('http://$host$path'),
      headers: {'host': host, 'origin': ?origin, ...headers},
      context: {_connectionInfoKey: _Peer(peer)},
    ),
  );

  Future<String?> errorOf(Response response) async {
    final body = await response.readAsString();
    try {
      return (jsonDecode(body) as Map)['error'] as String?;
    } on FormatException {
      return null;
    }
  }

  const websocket = {'connection': 'Upgrade', 'upgrade': 'websocket'};

  group('cross-origin browser requests', () {
    test('a foreign origin cannot change machine state', () async {
      final response = await send(
        'PUT',
        '/api/v1/machine/state/espresso',
        origin: 'https://evil.example',
        peer: '192.168.12.20',
        host: '$_deviceAddress:8080',
      );
      expect(response.statusCode, 403);
      expect(await errorOf(response), _crossOriginError);
      expect(response.headers['access-control-allow-origin'], isNull);
      expect(reached, isEmpty);
    });

    test('a simple cross-site POST without a preflight is refused', () async {
      final response = await send(
        'POST',
        '/api/v1/plugins/x.reaplugin/run',
        origin: 'http://attacker.lan',
        headers: {'content-type': 'text/plain'},
      );
      expect(response.statusCode, 403);
      expect(reached, isEmpty);
    });

    test('a foreign preflight gets no CORS grant', () async {
      final response = await send(
        'OPTIONS',
        '/api/v1/machine/state/espresso',
        origin: 'https://evil.example',
        headers: {'access-control-request-method': 'PUT'},
      );
      expect(response.statusCode, 403);
      expect(response.headers['access-control-allow-origin'], isNull);
      expect(response.headers['access-control-allow-credentials'], isNull);
    });

    test('a foreign origin cannot read API responses', () async {
      final response = await send(
        'GET',
        '/api/v1/machine/state',
        origin: 'https://evil.example',
      );
      expect(response.statusCode, 200);
      expect(response.headers['access-control-allow-origin'], isNull);
      expect(response.headers['access-control-allow-credentials'], isNull);
    });

    test('the literal null origin is foreign', () async {
      final response = await send(
        'POST',
        '/api/v1/machine/calibration',
        origin: 'null',
      );
      expect(response.statusCode, 403);
    });

    test('a foreign WebSocket upgrade is refused on every socket', () async {
      for (final path in ['/ws/v1/machine/raw', '/ws/v1/machine/snapshot']) {
        final response = await send(
          'GET',
          path,
          origin: 'https://evil.example',
          headers: websocket,
        );
        expect(response.statusCode, 403, reason: path);
      }
      expect(reached, isEmpty);
    });
  });

  group('the device and its own pages keep working', () {
    final trustedOrigins = {
      'skin page in the in-app WebView': (
        'http://localhost:$_skinPort',
        '127.0.0.1',
        'localhost:8080',
      ),
      'skin page from a LAN browser': (
        'http://$_deviceAddress:$_skinPort',
        '192.168.12.20',
        '$_deviceAddress:8080',
      ),
      'plugin page served on the API port': (
        'http://$_deviceAddress:8080',
        '192.168.12.20',
        '$_deviceAddress:8080',
      ),
      'plugin page in the in-app WebView': (
        'http://localhost:8080',
        '127.0.0.1',
        'localhost:8080',
      ),
    };
    for (final entry in trustedOrigins.entries) {
      final (origin, peer, host) = entry.value;

      test(
        '${entry.key} can change state and reads with a CORS grant',
        () async {
          final write = await send(
            'PUT',
            '/api/v1/machine/state/espresso',
            origin: origin,
            peer: peer,
            host: host,
          );
          expect(write.statusCode, 200);
          final read = await send(
            'GET',
            '/api/v1/machine/state',
            origin: origin,
            peer: peer,
            host: host,
          );
          expect(read.headers['access-control-allow-origin'], origin);
          final preflight = await send(
            'OPTIONS',
            '/api/v1/machine/state/espresso',
            origin: origin,
            peer: peer,
            host: host,
            headers: {'access-control-request-method': 'PUT'},
          );
          expect(preflight.statusCode, 200);
          expect(preflight.headers['access-control-allow-origin'], origin);
          final socket = await send(
            'GET',
            '/ws/v1/machine/snapshot',
            origin: origin,
            peer: peer,
            host: host,
            headers: websocket,
          );
          expect(socket.statusCode, 200);
        },
      );
    }

    test('a localhost origin from another machine is foreign', () async {
      final response = await send(
        'PUT',
        '/api/v1/machine/state/espresso',
        origin: 'http://localhost:$_skinPort',
        peer: '192.168.12.20',
        host: '$_deviceAddress:8080',
      );
      expect(response.statusCode, 403);
    });

    test(
      'clients without an Origin, such as Home Assistant, are unchanged',
      () async {
        for (final host in ['decaid.lan:8080', '$_deviceAddress:8080']) {
          final response = await send(
            'PUT',
            '/api/v1/machine/state/espresso',
            host: host,
            peer: '192.168.12.30',
          );
          expect(response.statusCode, 200, reason: host);
          final socket = await send(
            'GET',
            '/ws/v1/machine/raw',
            host: host,
            peer: '192.168.12.30',
            headers: websocket,
          );
          expect(socket.statusCode, 200, reason: host);
        }
      },
    );
  });

  group('DNS rebinding', () {
    test('a browser request under a foreign host name is refused', () async {
      final response = await send(
        'GET',
        '/api/v1/machine/state',
        host: 'rebind.attacker.example:8080',
        peer: '192.168.12.20',
        headers: {'sec-fetch-site': 'same-origin', 'sec-fetch-mode': 'cors'},
      );
      expect(response.statusCode, 403);
      expect(await errorOf(response), _hostError);
      expect(reached, isEmpty);
    });

    test('a same-origin rebound write is refused', () async {
      final response = await send(
        'POST',
        '/api/v1/machine/calibration',
        host: 'rebind.attacker.example:8080',
        origin: 'http://rebind.attacker.example:8080',
        peer: '192.168.12.20',
      );
      expect(response.statusCode, 403);
      expect(reached, isEmpty);
    });

    test(
      'a numeric host that is not this device is refused for browsers',
      () async {
        final response = await send(
          'GET',
          '/api/v1/machine/state',
          host: '10.9.9.9:8080',
          peer: '192.168.12.20',
          headers: {'sec-fetch-site': 'same-origin'},
        );
        expect(response.statusCode, 403);
      },
    );

    test('browsers on the device address and on loopback pass', () async {
      for (final host in [
        '$_deviceAddress:8080',
        'localhost:8080',
        '127.0.0.1:8080',
        '[::1]:8080',
      ]) {
        final response = await send(
          'GET',
          '/api/v1/machine/state',
          host: host,
          headers: {'sec-fetch-site': 'none', 'sec-fetch-mode': 'navigate'},
        );
        expect(response.statusCode, 200, reason: host);
      }
    });
  });

  group('machine control routes in protected mode', () {
    final routes = <(String, String, Map<String, String>)>[
      ('GET', '/ws/v1/machine/raw', websocket),
      ('POST', '/api/v1/machine/firmware', {}),
      ('POST', '/api/v1/machine/firmware/apply', {}),
      ('POST', '/api/v1/machine/calibration', {}),
      ('PUT', '/api/v1/machine/calibration/flow', {}),
      ('PUT', '/api/v1/machine/scaleCalibration', {}),
      ('POST', '/api/v1/machine/settings/advanced', {}),
      ('DELETE', '/api/v1/machine/settings/reset', {}),
    ];

    for (final (method, path, headers) in routes) {
      test('$method $path needs an extensions:manage token', () async {
        protectedMode = true;
        final refused = await send(method, path, headers: headers);
        expect(refused.statusCode, 401);
        final accepted = await send(
          method,
          path,
          headers: {...headers, 'authorization': 'Bearer $_managerToken'},
        );
        expect(accepted.statusCode, 200);
      });

      test('$method $path stays tokenless in compatibility mode', () async {
        final response = await send(method, path, headers: headers);
        expect(response.statusCode, 200);
      });
    }

    test(
      'ordinary machine control stays tokenless in protected mode',
      () async {
        protectedMode = true;
        final response = await send('PUT', '/api/v1/machine/state/idle');
        expect(response.statusCode, 200);
      },
    );
  });
}
