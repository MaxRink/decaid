import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver/request_host.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
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
const _crossSiteError =
    'This API does not accept browser requests started by another site';

void main() {
  late List<String> reached;
  late bool protectedMode;
  late Handler handler;
  late Set<String> allowedNames;

  setUp(() {
    reached = [];
    protectedMode = false;
    allowedNames = {};
    final routes = Router()
      ..get('/api/v1/devices/scan', (Request r) {
        reached.add('GET scan');
        return Response.ok('{}');
      })
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
      ..delete('/api/v1/machine/firmware', (Request r) {
        reached.add('DELETE firmware');
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
      ..get('/api/v1/plugins/<id>/ui', (Request r, String id) {
        return Response.ok(
          '<html></html>',
          headers: {
            'content-type': 'text/html',
            if (id == 'csp.reaplugin')
              'content-security-policy': "default-src 'self'",
          },
        );
      })
      ..get('/dashboard', (Request r) {
        return Response.ok(
          '<html></html>',
          headers: {'content-type': 'text/html'},
        );
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
        allowedHostNames: () => allowedNames,
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

    test('a foreign origin cannot read or trigger GET routes', () async {
      final response = await send(
        'GET',
        '/api/v1/machine/state',
        origin: 'https://evil.example',
      );
      expect(response.statusCode, 403);
      expect(await errorOf(response), _crossOriginError);
      expect(response.headers['access-control-allow-origin'], isNull);
      expect(response.headers['access-control-allow-credentials'], isNull);
      expect(reached, isEmpty);
    });

    test('a foreign origin with a token is still refused', () async {
      final response = await send(
        'POST',
        '/api/v1/machine/calibration',
        origin: 'https://evil.example',
        headers: {'authorization': 'Bearer $_managerToken'},
      );
      expect(response.statusCode, 403);
      expect(reached, isEmpty);
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
          expect(read.headers['access-control-allow-credentials'], 'true');
          expect(read.headers['vary'], contains('Origin'));
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
        for (final host in ['decaid.local:8080', '$_deviceAddress:8080']) {
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
    test('forwarding headers cannot vouch for a rebound host', () async {
      for (final forwarded in [
        {'x-forwarded-host': '$_deviceAddress:8080'},
        {'forwarded': 'host=$_deviceAddress:8080'},
        {'x-forwarded-proto': 'http'},
      ]) {
        for (final host in [
          'rebind.attacker.example:8080',
          '$_deviceAddress:8080',
        ]) {
          final response = await send(
            'GET',
            '/api/v1/machine/state',
            host: host,
            peer: '192.168.12.20',
            headers: {'sec-fetch-site': 'same-origin', ...forwarded},
          );
          expect(response.statusCode, 403, reason: '$host $forwarded');
          expect(
            await errorOf(response),
            host.startsWith('rebind') ? unadmittedHostError : _hostError,
          );
        }
      }
      expect(reached, isEmpty);
    });

    test(
      'a request that only carries a Referer is a browser request',
      () async {
        final rebound = await send(
          'GET',
          '/api/v1/machine/state',
          host: 'rebind.attacker.example:8080',
          peer: '192.168.12.20',
          headers: {'referer': 'http://rebind.attacker.example:8080/'},
        );
        expect(rebound.statusCode, 403);
        expect(await errorOf(rebound), unadmittedHostError);
        final foreign = await send(
          'GET',
          '/api/v1/devices/scan',
          host: '$_deviceAddress:8080',
          peer: '192.168.12.20',
          headers: {'referer': 'https://evil.example/page'},
        );
        expect(foreign.statusCode, 403);
        expect(await errorOf(foreign), _crossSiteError);
        expect(reached, isEmpty);
        final own = await send(
          'GET',
          '/api/v1/devices/scan',
          host: '$_deviceAddress:8080',
          peer: '192.168.12.20',
          headers: {'referer': 'http://$_deviceAddress:$_skinPort/'},
        );
        expect(own.statusCode, 200);
      },
    );

    test('a non-browser client may send forwarding headers', () async {
      final response = await send(
        'GET',
        '/api/v1/machine/state',
        host: 'decaid.local:8080',
        peer: '192.168.12.30',
        headers: {'x-forwarded-for': '10.1.1.1', 'x-forwarded-host': 'x'},
      );
      expect(response.statusCode, 200);
    });

    test('a browser request under a foreign host name is refused', () async {
      final response = await send(
        'GET',
        '/api/v1/machine/state',
        host: 'rebind.attacker.example:8080',
        peer: '192.168.12.20',
        headers: {'sec-fetch-site': 'same-origin', 'sec-fetch-mode': 'cors'},
      );
      expect(response.statusCode, 403);
      expect(await errorOf(response), unadmittedHostError);
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

  group('framing', () {
    List<String> frameAncestors(Response response) {
      final policy = response.headers['content-security-policy'] ?? '';
      final directive = policy
          .split(';')
          .map((part) => part.trim())
          .firstWhere((part) => part.startsWith('frame-ancestors'));
      return directive.split(RegExp(r'\s+')).skip(1).toList();
    }

    test(
      'a plugin page may be framed by the device skin origin only',
      () async {
        final viaLoopback = await send('GET', '/api/v1/plugins/x.reaplugin/ui');
        expect(viaLoopback.headers['x-frame-options'], isNull);
        expect(
          frameAncestors(viaLoopback),
          unorderedEquals([
            "'self'",
            'http://localhost:$_skinPort',
            'http://127.0.0.1:$_skinPort',
          ]),
        );

        final viaLan = await send(
          'GET',
          '/api/v1/plugins/x.reaplugin/ui',
          host: '$_deviceAddress:8080',
          peer: '192.168.12.20',
        );
        final allowed = frameAncestors(viaLan);
        expect(allowed, contains('http://$_deviceAddress:$_skinPort'));
        expect(allowed, isNot(contains('https://evil.example')));
        expect(allowed.where((source) => source.contains('*')), isEmpty);
        expect(
          allowed.every(
            (source) =>
                source == "'self'" ||
                source.endsWith(':$_skinPort') &&
                    (source.contains(_deviceAddress) ||
                        source.contains('localhost') ||
                        source.contains('127.0.0.1')),
          ),
          isTrue,
          reason: '$allowed',
        );
      },
    );

    test(
      'frame-ancestors carries no IPv6 literal, which CSP cannot express',
      () async {
        for (final host in [
          '[::1]:8080',
          '[fe80::1]:8080',
          '[fd00::64]:8080',
        ]) {
          final page = await send(
            'GET',
            '/api/v1/plugins/x.reaplugin/ui',
            host: host,
          );
          final allowed = frameAncestors(page);
          expect(allowed, contains('http://localhost:$_skinPort'));
          expect(
            allowed.where((source) => source.contains('[')),
            isEmpty,
            reason: '$host: $allowed',
          );
        }
      },
    );

    test('a plugin CSP keeps its rules and gains frame-ancestors', () async {
      final page = await send('GET', '/api/v1/plugins/csp.reaplugin/ui');
      final policy = page.headers['content-security-policy']!;
      expect(policy, startsWith("default-src 'self'; frame-ancestors 'self'"));
      expect(policy, contains('http://localhost:$_skinPort'));
    });

    test('host pages stay same-origin only', () async {
      for (final path in [
        '/dashboard',
        '/api/v1/plugins/settings.reaplugin/ui',
      ]) {
        final page = await send('GET', path);
        expect(page.headers['x-frame-options'], 'SAMEORIGIN', reason: path);
        expect(
          page.headers['content-security-policy'],
          "frame-ancestors 'self'",
          reason: path,
        );
      }
    });

    test('JSON responses are left alone', () async {
      final json = await send('GET', '/api/v1/machine/state');
      expect(json.headers['content-security-policy'], isNull);
    });

    test('the API server sends no default X-Frame-Options', () async {
      final server = await serveApiHandler(
        (request) => Response.ok(
          '<html></html>',
          headers: {'content-type': 'text/html'},
        ),
        '127.0.0.1',
        0,
      );
      addTearDown(() => server.close(force: true));
      final client = HttpClient();
      addTearDown(client.close);
      final response = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/'),
      )).close();
      await response.drain<void>();
      expect(response.headers.value('x-frame-options'), isNull);
    });
  });

  group('browser requests without an Origin', () {
    const host = '$_deviceAddress:8080';
    const lanPeer = '192.168.12.20';
    const navigation = {
      'sec-fetch-site': 'cross-site',
      'sec-fetch-mode': 'navigate',
      'sec-fetch-dest': 'document',
    };

    test('a cross-site navigation cannot trigger a GET side effect', () async {
      for (final method in ['GET', 'HEAD']) {
        final response = await send(
          method,
          '/api/v1/devices/scan',
          host: host,
          peer: lanPeer,
          headers: navigation,
        );
        expect(response.statusCode, 403, reason: method);
        expect(response.headers['access-control-allow-origin'], isNull);
      }
      final refused = await send(
        'GET',
        '/api/v1/devices/scan',
        host: host,
        peer: lanPeer,
        headers: navigation,
      );
      expect(await errorOf(refused), _crossSiteError);
      expect(reached, isEmpty);
    });

    test('cross-site subresources and prefetches are refused', () async {
      for (final headers in [
        {
          'sec-fetch-site': 'cross-site',
          'sec-fetch-mode': 'no-cors',
          'sec-fetch-dest': 'image',
        },
        {
          'sec-fetch-site': 'cross-site',
          'sec-fetch-mode': 'no-cors',
          'sec-fetch-dest': 'script',
        },
        {
          'sec-fetch-site': 'cross-site',
          'sec-fetch-mode': 'navigate',
          'sec-fetch-dest': 'empty',
          'sec-purpose': 'prefetch',
        },
        {'sec-fetch-site': 'unexpected'},
      ]) {
        final response = await send(
          'GET',
          '/api/v1/devices/scan',
          host: host,
          peer: lanPeer,
          headers: headers,
        );
        expect(response.statusCode, 403, reason: '$headers');
      }
      expect(reached, isEmpty);
    });

    test('a same-site request needs a referrer on a device origin', () async {
      Future<Response> sameSite(String? referer) => send(
        'GET',
        '/api/v1/devices/scan',
        host: host,
        peer: lanPeer,
        headers: {
          'sec-fetch-site': 'same-site',
          'sec-fetch-mode': 'navigate',
          'referer': ?referer,
        },
      );
      expect((await sameSite(null)).statusCode, 403);
      expect(
        (await sameSite('http://$_deviceAddress:9999/page')).statusCode,
        403,
      );
      expect(reached, isEmpty);
      expect(
        (await sameSite('http://$_deviceAddress:$_skinPort/index.html'))
            .statusCode,
        200,
      );
      expect(reached, ['GET scan']);
    });

    test('a typed URL and a same-origin page are admitted', () async {
      for (final site in ['none', 'same-origin']) {
        final response = await send(
          'GET',
          '/api/v1/devices/scan',
          host: host,
          peer: lanPeer,
          headers: {'sec-fetch-site': site, 'sec-fetch-mode': 'navigate'},
        );
        expect(response.statusCode, 200, reason: site);
      }
      expect(reached, ['GET scan', 'GET scan']);
    });

    test('a client without browser headers is admitted', () async {
      final response = await send(
        'GET',
        '/api/v1/devices/scan',
        host: 'decaid.local:8080',
        peer: lanPeer,
      );
      expect(response.statusCode, 200);
      expect(reached, ['GET scan']);
    });
  });

  group('Host names on every request', () {
    test('a rebound name is refused without any browser header', () async {
      for (final (method, path, extra) in [
        ('GET', '/api/v1/devices/scan', const <String, String>{}),
        ('PUT', '/api/v1/machine/state/espresso', const <String, String>{}),
        ('GET', '/ws/v1/machine/snapshot', websocket),
      ]) {
        final response = await send(
          method,
          path,
          host: 'rebind.attacker.example:8080',
          peer: '192.168.12.20',
          headers: extra,
        );
        expect(response.statusCode, 403, reason: '$method $path');
        expect(await errorOf(response), unadmittedHostError);
      }
      expect(reached, isEmpty);
    });

    test('numeric, loopback and .local hosts are admitted', () async {
      for (final host in [
        '$_deviceAddress:8080',
        '10.9.9.9:8080',
        '[2001:db8::5]:8080',
        'localhost:8080',
        'app.localhost:8080',
        'decaid.local:8080',
        'DECAID.LOCAL.:8080',
      ]) {
        final response = await send(
          'GET',
          '/api/v1/devices/scan',
          host: host,
          peer: '192.168.12.20',
        );
        expect(response.statusCode, 200, reason: host);
      }
    });

    test('the unspecified address is not a host', () async {
      for (final host in ['0.0.0.0:8080', '[::]:8080']) {
        final response = await send('GET', '/api/v1/devices/scan', host: host);
        expect(response.statusCode, 403, reason: host);
      }
      expect(reached, isEmpty);
    });

    test('a DNS name is admitted only while it is allow-listed', () async {
      Future<int> status() async => (await send(
        'GET',
        '/api/v1/devices/scan',
        host: 'decaid.lan:8080',
        peer: '192.168.12.20',
      )).statusCode;
      expect(await status(), 403);
      allowedNames = {'decaid.lan'};
      expect(await status(), 200);
      final browser = await send(
        'GET',
        '/api/v1/devices/scan',
        host: 'decaid.lan:8080',
        peer: '192.168.12.20',
        headers: {'referer': 'http://$_deviceAddress:$_skinPort/'},
      );
      expect(
        browser.statusCode,
        200,
        reason:
            'a native client that sends a Referer under an allow-listed '
            'name is admitted',
      );
      allowedNames = {};
      expect(await status(), 403);
    });

    test('in-process callers without a Host header keep working', () async {
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/v1/devices/scan')),
      );
      expect(response.statusCode, 200);
    });
  });

  group('privileged machine routes in protected mode', () {
    final routes = <(String, String, Map<String, String>)>[
      ('GET', '/ws/v1/machine/raw', websocket),
      ('POST', '/api/v1/machine/firmware', {}),
      ('POST', '/api/v1/machine/firmware/apply', {}),
      ('DELETE', '/api/v1/machine/firmware', {}),
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

  group('the WebSocket upgrade path', () {
    test('refuses a browser upgrade that the API did not admit', () async {
      var opened = false;
      final upgrade = admittedWebSocketHandler((channel, _) => opened = true);
      final response = await upgrade(
        Request(
          'GET',
          Uri.parse('http://localhost:8080/ws/v1/machine/raw'),
          headers: {'origin': 'https://evil.example', ...websocket},
        ),
      );
      expect(response.statusCode, 403);
      expect(await errorOf(response), _crossOriginError);
      expect(opened, isFalse);
    });
  });

  group('over a real loopback socket', () {
    late HttpServer server;
    late List<String> served;

    setUp(() async {
      served = [];
      final routes = Router()
        ..get('/api/v1/data/export', (Request r) {
          served.add('export');
          return Response.ok('{}');
        })
        ..put('/api/v1/machine/state/<s>', (Request r, String s) {
          served.add('PUT state');
          return Response.ok('{}');
        })
        ..post('/api/v1/machine/profile', (Request r) {
          served.add('POST profile');
          return Response.ok('{}');
        })
        ..get(
          '/ws/v1/machine/raw',
          admittedWebSocketHandler((channel, _) {
            served.add('raw');
            channel.sink.add('raw');
          }),
        );
      final tokens = ProxyTokenService(skinToken: 'skin-token')
        ..registerToken(
          _managerToken,
          const ProxyCaller(
            id: 'api:manager',
            scopes: {ProxyTokenService.scopeExtensionsManage},
          ),
        );
      server = await shelf_io.serve(
        buildWebServerHandler(
          routes.call,
          proxyTokenService: tokens,
          requireExtensionManagementAuthorization: () async => protectedMode,
          browserOrigins: ExtensionManagementBrowserOrigins(
            apiListenerPort: () => server.port,
            pagePorts: () => const {_skinPort},
            deviceAddresses: () async => const {},
            allowedHostNames: () => allowedNames,
          ),
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
    });

    Future<HttpClientResponse> request(
      String method,
      String path, {
      Map<String, String> headers = const {},
      String? body,
    }) async {
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.open(method, '127.0.0.1', server.port, path);
      headers.forEach(request.headers.set);
      if (body != null) request.write(body);
      final response = await request.close();
      await response.drain<void>();
      return response;
    }

    Future<WebSocket> openRaw(Map<String, String> headers) async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/ws/v1/machine/raw',
        headers: headers,
      );
      addTearDown(socket.close);
      return socket;
    }

    const foreign = 'https://evil.example';
    const skin = 'http://localhost:$_skinPort';

    test('a foreign preflight is refused without a CORS grant', () async {
      final response = await request(
        'OPTIONS',
        '/api/v1/machine/state/espresso',
        headers: {'origin': foreign, 'access-control-request-method': 'PUT'},
      );
      expect(response.statusCode, 403);
      expect(response.headers.value('access-control-allow-origin'), isNull);
      expect(
        response.headers.value('access-control-allow-credentials'),
        isNull,
      );
    });

    test('a foreign text/plain POST never reaches the handler', () async {
      final response = await request(
        'POST',
        '/api/v1/machine/profile',
        headers: {'origin': foreign, 'content-type': 'text/plain'},
        body: '{}',
      );
      expect(response.statusCode, 403);
      expect(served, isEmpty);
    });

    test('a foreign WebSocket upgrade is refused', () async {
      await expectLater(
        openRaw({'origin': foreign}),
        throwsA(isA<WebSocketException>()),
      );
      expect(served, isEmpty);
    });

    test('a cross-site navigation is refused', () async {
      final response = await request(
        'PUT',
        '/api/v1/machine/state/espresso',
        headers: const {
          'sec-fetch-site': 'cross-site',
          'sec-fetch-mode': 'navigate',
        },
      );
      expect(response.statusCode, 403);
      expect(served, isEmpty);
      final typed = await request(
        'PUT',
        '/api/v1/machine/state/espresso',
        headers: const {'sec-fetch-site': 'none'},
      );
      expect(typed.statusCode, 200);
      expect(served, ['PUT state']);
    });

    test('X-Forwarded-Host and Forwarded cannot pass the host check', () async {
      for (final forwarded in [
        {'x-forwarded-host': '127.0.0.1:${server.port}'},
        {'forwarded': 'host=127.0.0.1:${server.port}'},
      ]) {
        final plain = await request(
          'PUT',
          '/api/v1/machine/state/espresso',
          headers: {
            'host': 'rebind.attacker.example:${server.port}',
            'sec-fetch-site': 'same-origin',
          },
        );
        expect(plain.statusCode, 403);
        final forged = await request(
          'PUT',
          '/api/v1/machine/state/espresso',
          headers: {
            'host': 'rebind.attacker.example:${server.port}',
            'sec-fetch-site': 'same-origin',
            ...forwarded,
          },
        );
        expect(forged.statusCode, 403, reason: '$forwarded');
        await expectLater(
          openRaw({
            'host': 'rebind.attacker.example:${server.port}',
            'origin': 'http://rebind.attacker.example:${server.port}',
            ...forwarded,
          }),
          throwsA(isA<WebSocketException>()),
        );
      }
      expect(served, isEmpty);
    });

    test('a rebound host name is refused for a browser', () async {
      final read = await request(
        'PUT',
        '/api/v1/machine/state/espresso',
        headers: {
          'host': 'rebind.attacker.example:${server.port}',
          'origin': 'http://rebind.attacker.example:${server.port}',
        },
      );
      expect(read.statusCode, 403);
      await expectLater(
        openRaw({
          'host': 'rebind.attacker.example:${server.port}',
          'origin': 'http://rebind.attacker.example:${server.port}',
        }),
        throwsA(isA<WebSocketException>()),
      );
      expect(served, isEmpty);
    });

    test('the device skin origin and originless clients work', () async {
      final preflight = await request(
        'OPTIONS',
        '/api/v1/machine/state/espresso',
        headers: {'origin': skin, 'access-control-request-method': 'PUT'},
      );
      expect(preflight.statusCode, 200);
      expect(preflight.headers.value('access-control-allow-origin'), skin);
      final write = await request(
        'PUT',
        '/api/v1/machine/state/espresso',
        headers: {'origin': skin},
      );
      expect(write.statusCode, 200);
      final plain = await request(
        'POST',
        '/api/v1/machine/profile',
        headers: {'host': 'decaid.local:${server.port}'},
        body: '{}',
      );
      expect(plain.statusCode, 200);
      for (final headers in [
        {'origin': skin},
        <String, String>{},
      ]) {
        final socket = await openRaw(headers);
        expect(await socket.first, 'raw', reason: '$headers');
      }
      expect(served, ['PUT state', 'POST profile', 'raw', 'raw']);
    });

    test('a rebound GET without browser headers is refused', () async {
      final noSignals = await request(
        'GET',
        '/api/v1/data/export',
        headers: {'host': 'rebind.attacker.example:${server.port}'},
      );
      expect(noSignals.statusCode, 403);
      final numeric = await request(
        'GET',
        '/api/v1/data/export',
        headers: {'host': '192.168.12.64:${server.port}'},
      );
      expect(numeric.statusCode, 200);
      expect(served, ['export']);
    });

    test('only numeric, local and allow-listed hosts are answered', () async {
      allowedNames = {'decaid.lan'};
      for (final host in [
        '127.0.0.1',
        '[::1]',
        'localhost',
        'decaid.local',
        'decaid.lan',
      ]) {
        final response = await request(
          'GET',
          '/api/v1/data/export',
          headers: {'host': '$host:${server.port}'},
        );
        expect(response.statusCode, 200, reason: host);
      }
      for (final host in ['rebind.attacker.example', 'other.lan']) {
        final get = await request(
          'GET',
          '/api/v1/data/export',
          headers: {'host': '$host:${server.port}'},
        );
        expect(get.statusCode, 403, reason: host);
        final post = await request(
          'POST',
          '/api/v1/machine/profile',
          headers: {'host': '$host:${server.port}'},
          body: '{}',
        );
        expect(post.statusCode, 403, reason: host);
        await expectLater(
          openRaw({'host': '$host:${server.port}'}),
          throwsA(isA<WebSocketException>()),
        );
      }
      expect(served, List.filled(5, 'export'));
    });

    test(
      'a request without a Host header is refused on a wildcard bind',
      () async {
        final wildcard = await shelf_io.serve(
          buildWebServerHandler(
            (Request r) => Response.ok('{}'),
            browserOrigins: ExtensionManagementBrowserOrigins(
              apiListenerPort: () => null,
              pagePorts: () => const {},
              deviceAddresses: () async => const {},
            ),
          ),
          InternetAddress.anyIPv4,
          0,
        );
        addTearDown(() => wildcard.close(force: true));
        for (final extra in ['', 'X-Forwarded-Host: 127.0.0.1\r\n']) {
          final socket = await Socket.connect('127.0.0.1', wildcard.port);
          addTearDown(socket.destroy);
          socket.write('GET /api/v1/data/export HTTP/1.0\r\n$extra\r\n');
          final reply = await utf8.decoder.bind(socket).join();
          expect(reply, startsWith('HTTP/1.0 403'), reason: extra);
        }
      },
    );

    test('protected mode gates the raw socket on extensions:manage', () async {
      protectedMode = true;
      await expectLater(openRaw(const {}), throwsA(isA<WebSocketException>()));
      await expectLater(
        openRaw(const {'origin': skin}),
        throwsA(isA<WebSocketException>()),
      );
      expect(served, isEmpty);
      final socket = await openRaw(const {
        'authorization': 'Bearer $_managerToken',
      });
      expect(await socket.first, 'raw');
    });
  });
}
