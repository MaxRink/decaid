import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

/// Delays openUrl for "/slow-connect" so the request is not yet open
/// (op.request == null) when the plugin is unloaded.
class _SlowConnectClient implements HttpClient {
  _SlowConnectClient(this.inner, this.gate);
  final HttpClient inner;
  final Completer<void> gate;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (url.path == '/slow-connect') await gate.future;
    return inner.openUrl(method, url);
  }

  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;

  @override
  void close({bool force = false}) => inner.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Overrides extends HttpOverrides {
  _Overrides(this.gate);
  final Completer<void> gate;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _SlowConnectClient(super.createHttpClient(context), gate);
}

void main() {
  for (final MapEntry(key: engine, value: createRuntime)
      in pluginTestEngines().entries) {
    test('a retired generation fetch does not steal the next generation '
        'fetch with the same id on $engine', () async {
      final connectGate = Completer<void>();
      final holdGen2 = Completer<void>();
      HttpOverrides.global = _Overrides(connectGate);
      addTearDown(() => HttpOverrides.global = null);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/gen2') await holdGen2.future;
        request.response.write(request.uri.path);
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';

      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        createJsRuntime: createRuntime,
      );
      addTearDown(() async {
        if (manager.lifecycle == PluginManagerLifecycle.active) {
          await manager.dispose();
        }
      });
      final emits = <Map<String, dynamic>>[];
      final sub = manager.emitStream.listen(emits.add);
      addTearDown(sub.cancel);

      Future<void> load(String path) => manager.loadPlugin(
        id: 'p.plugin',
        manifest: testManifest(
          'p.plugin',
          permissions: const {PluginPermissions.api, PluginPermissions.emit},
        ),
        settings: const {},
        jsCode:
            '''
        function createPlugin(host) {
          return {
            id: "p.plugin",
            onLoad() {
              fetch("$base$path")
                .then((r) => r.text())
                .then((t) => host.emit("fetched", t),
                      (e) => host.emit("fetchError", String(e)));
            }
          };
        }
      ''',
      );

      await load('/slow-connect'); // gen 1, fetch id 1, stuck in openUrl
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await load('/gen2'); // reload: gen 2, fetch id 1, held by server
      await Future<void>.delayed(const Duration(milliseconds: 50));

      connectGate.complete(); // gen 1 request now completes
      await Future<void>.delayed(const Duration(milliseconds: 200));
      holdGen2.complete(); // gen 2 response arrives

      for (var i = 0; i < 100; i++) {
        if (emits.any((e) => e['event'] == 'fetched')) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        [
          for (final e in emits)
            if (e['event'] == 'fetched') e['payload'],
        ],
        ['/gen2'],
      );
    });
  }
}
