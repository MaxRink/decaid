import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

const _binary = [0x00, 0xff, 0xc3, 0x28, 0x80, 0x00, 0x7f, 0xfe, 0x0a, 0x00];

Future<Map<String, dynamic>> _run(
  PluginManager manager, {
  required String id,
  required String jsBody,
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
      permissions: {PluginPermissions.emit, PluginPermissions.api},
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

Future<void> _serve(HttpRequest request) async {
  switch (request.uri.path) {
    case '/bin':
      request.response.headers.contentType = ContentType.binary;
      request.response.add(_binary);
    case '/big':
      request.response.add(List<int>.filled(65, 0x41));
    default:
      request.response.headers.contentType = ContentType.text;
      request.response.write('héllo');
  }
  await request.response.close();
}

void main() {
  late PluginManager manager;
  late HttpServer server;

  setUp(() async {
    manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      maxFetchResponseBytes: 64,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
  });

  tearDown(() async {
    await manager.dispose();
    await server.close(force: true);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  test('a base64 response round-trips binary bytes exactly', () async {
    final result = await _run(
      manager,
      id: 'binary.plugin',
      jsBody:
          '''
        fetch("${url('/bin')}", { responseType: "base64" })
          .then((r) => r.base64().then((b) => report({ status: r.status, b })), fail);
      ''',
    );
    expect(result['status'], 200);
    expect(base64Decode(result['b'] as String), _binary);
  });

  test('text and json refuse a base64 response', () async {
    final result = await _run(
      manager,
      id: 'misuse.plugin',
      jsBody:
          '''
        fetch("${url('/bin')}", { responseType: "base64" })
          .then((r) => r.text())
          .then(() => report({ ok: true }), fail);
      ''',
    );
    expect(result['error'], contains('base64()'));
  });

  test('the response size limit applies to base64 responses', () async {
    final result = await _run(
      manager,
      id: 'big.plugin',
      jsBody:
          '''
        fetch("${url('/big')}", { responseType: "base64" })
          .then(() => report({ ok: true }), fail);
      ''',
    );
    expect(result['error'], contains('maxFetchResponseBytes'));
  });

  test('the default text path is unchanged', () async {
    final result = await _run(
      manager,
      id: 'text.plugin',
      jsBody:
          '''
        fetch("${url('/text')}")
          .then((r) => r.text().then((t) => report({
            t, hasBase64: typeof r.base64
          })), fail);
      ''',
    );
    expect(result, {'t': 'héllo', 'hasBase64': 'undefined'});
  });

  test('an unknown responseType is rejected', () async {
    final result = await _run(
      manager,
      id: 'unknown.plugin',
      jsBody:
          '''
        fetch("${url('/bin')}", { responseType: "blob" })
          .then(() => report({ ok: true }), fail);
      ''',
    );
    expect(result['error'], contains('responseType'));
  });

  test('a pinned https request can return base64', () async {
    final dir = await Directory.systemTemp.createTemp('fetch_binary_tls');
    addTearDown(() => dir.delete(recursive: true));
    final cert = '${dir.path}/cert.pem';
    final key = '${dir.path}/key.pem';
    final openssl = await Process.run('openssl', [
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
    if (openssl.exitCode != 0) {
      markTestSkipped('openssl unavailable');
      return;
    }
    final der = base64Decode(
      File(cert)
          .readAsLinesSync()
          .where((line) => line.isNotEmpty && !line.startsWith('-----'))
          .join(),
    );
    final pin = sha256.convert(der).toString();
    final secure = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key),
    );
    addTearDown(() => secure.close(force: true));
    secure.listen(_serve);

    final result = await _run(
      manager,
      id: 'pinned.plugin',
      jsBody:
          '''
        fetch("https://127.0.0.1:${secure.port}/bin", {
          responseType: "base64",
          tlsPinSha256: "$pin"
        }).then((r) => r.base64().then((b) => report({ b })), fail);
      ''',
    );
    expect(base64Decode(result['b'] as String), _binary);
  });
}
