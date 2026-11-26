import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_tls_pin.dart';

import 'plugin_test_helpers.dart';

Future<Map<String, dynamic>> runPlugin(
  PluginManager manager, {
  required String id,
  required Set<PluginPermissions> permissions,
  required String jsBody,
}) async {
  final result = Completer<Object?>();
  final sub = manager.emitStream.listen((e) {
    if (!result.isCompleted) result.complete(e['payload']);
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
  return jsonDecode(payload as String) as Map<String, dynamic>;
}

void main() {
  var certsReady = false;
  late SecurityContext serverContext;
  late String pin;
  const wrongPin =
      '0000000000000000000000000000000000000000000000000000000000000000';

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('plugin_tls_pin');
    final cert = '${dir.path}/cert.pem';
    final key = '${dir.path}/key.pem';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-keyout',
      key,
      '-out',
      cert,
      '-days',
      '2',
      '-nodes',
      '-subj',
      '/CN=self-signed.invalid',
    ]);
    certsReady = result.exitCode == 0;
    if (!certsReady) return;
    serverContext = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    final pem = File(cert).readAsStringSync();
    final body = pem
        .split('\n')
        .where((line) => line.isNotEmpty && !line.startsWith('-----'))
        .join();
    pin = sha256.convert(base64Decode(body)).toString();
    await dir.delete(recursive: true);
  });

  late PluginManager manager;
  late HttpServer server;
  var hits = 0;

  setUp(() async {
    hits = 0;
    manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      fetchTimeout: const Duration(seconds: 5),
    );
    if (!certsReady) return;
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    server.listen((req) async {
      try {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          ws.listen((data) => ws.add(data), onError: (Object _) {});
          return;
        }
        hits++;
        req.response.write('pinned hello');
        await req.response.close();
      } catch (_) {}
    });
  });

  tearDown(() async {
    await manager.dispose();
    if (certsReady) await server.close(force: true);
  });

  bool skipWithoutOpenssl() {
    if (certsReady) return false;
    markTestSkipped('openssl unavailable');
    return true;
  }

  String fetchJs(String url, {String? tlsPin}) {
    final init = tlsPin == null
        ? '{}'
        : '{ tlsPinSha256: ${jsonEncode(tlsPin)} }';
    return 'fetch(${jsonEncode(url)}, $init)'
        '.then((r) => r.text().then((body) => ({ status: r.status, body })))';
  }

  group('parseTlsPinSha256', () {
    test('accepts upper case and colon separated hex', () {
      final colons = [for (var i = 0; i < 64; i += 2) 'AB'].join(':');
      expect(parseTlsPinSha256(colons), 'ab' * 32);
      expect(parseTlsPinSha256(null), isNull);
    });

    test('rejects anything that is not 32 bytes of hex', () {
      for (final bad in <Object>['', 'abc', 'g' * 64, 'a' * 63, 'a' * 66, 5]) {
        expect(
          () => parseTlsPinSha256(bad),
          throwsA(isA<FormatException>()),
          reason: '$bad',
        );
      }
    });
  });

  group('fetch', () {
    test('a matching pin admits the self-signed certificate', () async {
      if (skipWithoutOpenssl()) return;
      final result = await runPlugin(
        manager,
        id: 'pin.ok',
        permissions: {PluginPermissions.api},
        jsBody:
            '${fetchJs('https://127.0.0.1:${server.port}/', tlsPin: pin)}'
            '.then(report, fail);',
      );
      expect(result, {'status': 200, 'body': 'pinned hello'});
    });

    test('a pin is compared case-insensitively and may carry colons', () async {
      if (skipWithoutOpenssl()) return;
      final spaced = [
        for (var i = 0; i < pin.length; i += 2) pin.substring(i, i + 2),
      ].join(':').toUpperCase();
      final result = await runPlugin(
        manager,
        id: 'pin.colons',
        permissions: {PluginPermissions.api},
        jsBody:
            '${fetchJs('https://127.0.0.1:${server.port}/', tlsPin: spaced)}'
            '.then(report, fail);',
      );
      expect(result['status'], 200);
    });

    test('a wrong pin is refused', () async {
      if (skipWithoutOpenssl()) return;
      final result = await runPlugin(
        manager,
        id: 'pin.wrong',
        permissions: {PluginPermissions.api},
        jsBody:
            '${fetchJs('https://127.0.0.1:${server.port}/', tlsPin: wrongPin)}'
            '.then(report, fail);',
      );
      expect(result['error'], contains('HandshakeException'));
      expect(hits, 0);
    });

    test('a wrong pin reports the presented certificate digest', () async {
      if (skipWithoutOpenssl()) return;
      final result = await runPlugin(
        manager,
        id: 'pin.mismatch',
        permissions: {PluginPermissions.api},
        jsBody:
            '${fetchJs('https://127.0.0.1:${server.port}/', tlsPin: wrongPin)}'
            '.then(report, (e) => report({ code: e.code, '
            'peerSha256: e.peerSha256, message: e.message }));',
      );
      expect(result['code'], 'tls_pin_mismatch');
      expect(result['peerSha256'], pin);
      expect(result['message'], contains('HandshakeException'));
      expect(hits, 0);
    });

    test('an unpinned failure carries no presented digest', () async {
      if (skipWithoutOpenssl()) return;
      final result = await runPlugin(
        manager,
        id: 'pin.none.digest',
        permissions: {PluginPermissions.api},
        jsBody:
            '${fetchJs('https://127.0.0.1:${server.port}/')}'
            '.then(report, (e) => report({ code: e.code ?? null, '
            'peerSha256: e.peerSha256 ?? null }));',
      );
      expect(result, {'code': null, 'peerSha256': null});
    });

    test('without a pin the platform validation refuses', () async {
      if (skipWithoutOpenssl()) return;
      final result = await runPlugin(
        manager,
        id: 'pin.none',
        permissions: {PluginPermissions.api},
        jsBody:
            '${fetchJs('https://127.0.0.1:${server.port}/')}'
            '.then(report, fail);',
      );
      expect(result['error'], contains('HandshakeException'));
      expect(hits, 0);
    });

    test('a pin does not carry over to a later request without one', () async {
      if (skipWithoutOpenssl()) return;
      final url = 'https://127.0.0.1:${server.port}/';
      final result = await runPlugin(
        manager,
        id: 'pin.leak',
        permissions: {PluginPermissions.api},
        jsBody:
            '''
        ${fetchJs(url, tlsPin: pin)}.then((first) =>
          ${fetchJs(url)}.then(
            (second) => report({ first, second }),
            (e) => report({ first, error: String(e.message) })
          ), fail);
      ''',
      );
      expect(result['first'], {'status': 200, 'body': 'pinned hello'});
      expect(result['error'], contains('HandshakeException'));
      expect(hits, 1);
    });

    test('a malformed pin rejects the request before connecting', () async {
      if (skipWithoutOpenssl()) return;
      final result = await runPlugin(
        manager,
        id: 'pin.malformed',
        permissions: {PluginPermissions.api},
        jsBody:
            '${fetchJs('https://127.0.0.1:${server.port}/', tlsPin: 'abc')}'
            '.then(report, fail);',
      );
      expect(result['error'], contains('tlsPinSha256'));
      expect(hits, 0);
    });

    test('a pin on a plain http url is rejected', () async {
      final result = await runPlugin(
        manager,
        id: 'pin.http',
        permissions: {PluginPermissions.api},
        jsBody:
            '${fetchJs('http://127.0.0.1:9/', tlsPin: wrongPin)}'
            '.then(report, fail);',
      );
      expect(result['error'], contains('tlsPinSha256'));
      expect(result['error'], contains('https'));
    });

    test('a pin does not lift the api permission requirement', () async {
      final result = await runPlugin(
        manager,
        id: 'pin.noapi',
        permissions: {},
        jsBody:
            '${fetchJs('https://127.0.0.1:9/', tlsPin: wrongPin)}'
            '.then(report, fail);',
      );
      expect(result['error'], contains('api'));
    });
  });

  group('host.transport', () {
    String openJs(Map<String, Object?> options) =>
        'host.transport.open(${jsonEncode(options)})';

    test('a pinned tls connection round-trips bytes', () async {
      if (skipWithoutOpenssl()) return;
      final tls = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      tls.listen(
        (socket) => socket.listen(socket.add, onError: (Object _) {}),
        onError: (Object _) {},
      );
      addTearDown(tls.close);
      final payload = base64Encode(utf8.encode('ping'));
      final result = await runPlugin(
        manager,
        id: 'pin.tls',
        permissions: {PluginPermissions.networkTls},
        jsBody:
            '''
        ${openJs({'kind': 'tls', 'host': '127.0.0.1', 'port': tls.port, 'tlsPinSha256': pin})}
          .then((opened) => {
            host.transport.onEvent(opened.handle, (event) => {
              if (event.type === "data") report(event);
            });
            host.transport.send(opened.handle, { type: "binary", data: "$payload" });
          }, fail);
      ''',
      );
      expect(utf8.decode(base64Decode(result['data'] as String)), 'ping');
    });

    test('a wrong pin refuses a tls connection', () async {
      if (skipWithoutOpenssl()) return;
      final tls = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      tls.listen((_) {}, onError: (Object _) {});
      addTearDown(tls.close);
      final result = await runPlugin(
        manager,
        id: 'pin.tls.wrong',
        permissions: {PluginPermissions.networkTls},
        jsBody:
            '${openJs({'kind': 'tls', 'host': '127.0.0.1', 'port': tls.port, 'tlsPinSha256': wrongPin})}'
            '.then(() => report({ opened: true }), fail);',
      );
      expect(result['error'], contains('HandshakeException'));
      expect(manager.liveTransportCount, 0);
    });

    test('a wrong pin reports the presented digest on tls and wss', () async {
      if (skipWithoutOpenssl()) return;
      final tls = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      tls.listen((_) {}, onError: (Object _) {});
      addTearDown(tls.close);
      const reportError = '(e) => ({ code: e.code, peerSha256: e.peerSha256 })';
      final result = await runPlugin(
        manager,
        id: 'pin.transport.mismatch',
        permissions: {
          PluginPermissions.networkTls,
          PluginPermissions.networkWebsocket,
        },
        jsBody:
            '''
        Promise.all([
          ${openJs({'kind': 'tls', 'host': '127.0.0.1', 'port': tls.port, 'tlsPinSha256': wrongPin})}
            .then(() => ({ opened: true }), $reportError),
          ${openJs({'kind': 'websocket', 'url': 'wss://127.0.0.1:${server.port}/echo', 'tlsPinSha256': wrongPin})}
            .then(() => ({ opened: true }), $reportError),
        ]).then((both) => report({ tls: both[0], wss: both[1] }), fail);
      ''',
      );
      final expected = {'code': 'tls_pin_mismatch', 'peerSha256': pin};
      expect(result, {'tls': expected, 'wss': expected});
      expect(manager.liveTransportCount, 0);
    });

    test('a pinned wss connection round-trips text', () async {
      if (skipWithoutOpenssl()) return;
      final result = await runPlugin(
        manager,
        id: 'pin.wss',
        permissions: {PluginPermissions.networkWebsocket},
        jsBody:
            '''
        ${openJs({'kind': 'websocket', 'url': 'wss://127.0.0.1:${server.port}/echo', 'tlsPinSha256': pin})}
          .then((opened) => {
            host.transport.onEvent(opened.handle, (event) => {
              if (event.type === "data") report(event);
            });
            host.transport.send(opened.handle, { type: "text", data: "hello" });
          }, fail);
      ''',
      );
      expect(result['data'], 'hello');
    });

    test('an unpinned wss connection to the same server is refused', () async {
      if (skipWithoutOpenssl()) return;
      final result = await runPlugin(
        manager,
        id: 'pin.wss.none',
        permissions: {PluginPermissions.networkWebsocket},
        jsBody:
            '${openJs({'kind': 'websocket', 'url': 'wss://127.0.0.1:${server.port}/echo'})}'
            '.then(() => report({ opened: true }), fail);',
      );
      expect(result['error'], contains('HandshakeException'));
    });

    test('a pin on ws:// or tcp is rejected', () async {
      final ws = await runPlugin(
        manager,
        id: 'pin.ws',
        permissions: {PluginPermissions.networkWebsocket},
        jsBody:
            '${openJs({'kind': 'websocket', 'url': 'ws://127.0.0.1:9/', 'tlsPinSha256': wrongPin})}'
            '.then(() => report({ opened: true }), fail);',
      );
      expect(ws['error'], contains('tlsPinSha256'));
      final tcp = await runPlugin(
        manager,
        id: 'pin.tcp',
        permissions: {PluginPermissions.networkTcp},
        jsBody:
            '${openJs({'kind': 'tcp', 'host': '127.0.0.1', 'port': 9, 'tlsPinSha256': wrongPin})}'
            '.then(() => report({ opened: true }), fail);',
      );
      expect(tcp['error'], contains('tlsPinSha256'));
    });

    test('a malformed pin rejects the open', () async {
      final result = await runPlugin(
        manager,
        id: 'pin.tls.malformed',
        permissions: {PluginPermissions.networkTls},
        jsBody:
            '${openJs({'kind': 'tls', 'host': '127.0.0.1', 'port': 9, 'tlsPinSha256': 'xyz'})}'
            '.then(() => report({ opened: true }), fail);',
      );
      expect(result['error'], contains('tlsPinSha256'));
    });

    test('a pin does not lift the transport permission requirement', () async {
      final result = await runPlugin(
        manager,
        id: 'pin.tls.noperm',
        permissions: {},
        jsBody:
            '${openJs({'kind': 'tls', 'host': '127.0.0.1', 'port': 9, 'tlsPinSha256': wrongPin})}'
            '.then(() => report({ opened: true }), fail);',
      );
      expect(result['error'], contains('network.tls'));
    });
  });
}
