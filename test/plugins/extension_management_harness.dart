import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/util/remote_update_report.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';

import 'plugin_test_helpers.dart';

const managerToken = 'extensions-manager-token-0123456789abcdef';
const accountToken = 'account-proxy-token-0123456789abcdef';
const recordedSkinId = 'recorded-skin';

const unprivilegedPermissions = [
  'emit',
  'api',
  'network.tcp',
  'network.websocket',
];
const privilegedPermissions = ['emit', 'api', 'manage.extensions'];
const managementOnlyPermissions = ['emit', 'manage.extensions'];

const fixtureEcho = '/api/v1/plugins/echo.fixture/settings';
const fixtureEchoSource = '/api/v1/plugins/echo.fixture/source';
const fixtureMarker = '/api/v1/webui/skins/marker.fixture';
const fixtureRedirect = '/api/v1/webui/skins/redirect.fixture';
const machineStatePath = '/api/v1/machine/state/espresso';

String fixtureSlow(String name) => '/api/v1/plugins/slow.$name/enable';

class RecordingWebUIStorage extends Fake implements WebUIStorage {
  final List<String> mutations = [];
  final WebUISkin skin = WebUISkin(
    id: recordedSkinId,
    name: 'Recorded skin',
    path: '/recorded-skin',
  );

  @override
  List<WebUISkin> get installedSkins => [skin];

  @override
  WebUISkin? get defaultSkin => skin;

  @override
  WebUISkin? getSkin(String id) => id == skin.id ? skin : null;

  @override
  bool isSkinInstalled(String skinId) => skinId == skin.id;

  @override
  Future<void> setDefaultSkin(String skinId) async {
    mutations.add('setDefaultSkin $skinId');
  }

  @override
  Future<void> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    mutations.add('installFromGitHubRelease $repo');
  }

  @override
  Future<void> installFromGitHub(String repo, {String branch = 'main'}) async {
    mutations.add('installFromGitHub $repo');
  }

  @override
  Future<void> installFromUrl(
    String url, {
    String? sourceIdentifier,
    String? releaseAssetName,
    bool? includePrerelease,
  }) async {
    mutations.add('installFromUrl $url');
  }

  @override
  Future<void> removeSkin(String skinId) async {
    mutations.add('removeSkin $skinId');
  }

  @override
  Future<void> updateAllSkins() async {
    mutations.add('updateAllSkins');
  }

  @override
  Future<RemoteUpdateReport> checkForSkinUpdates() async {
    mutations.add('checkForSkinUpdates');
    return const RemoteUpdateReport([]);
  }
}

class RecordingWebUIService extends Fake implements WebUIService {
  final List<String> mutations = [];
  bool serving = true;
  Set<String> browserOriginAddresses = const {};

  @override
  bool get isServing => serving;

  @override
  int get port => 3000;

  @override
  Set<int> get browserOriginPorts => serving ? {port} : const {};

  @override
  Future<Set<String>> currentBrowserOriginAddresses() async =>
      browserOriginAddresses;

  @override
  Set<String> admittedHostNames() => const {};

  @override
  String serverPath() => '/recorded-skin';

  @override
  String serverIP() => '127.0.0.1';

  @override
  Future<void> serveFolderAtPath(String path, {int port = 3000}) async {
    mutations.add('serveFolderAtPath $path');
    serving = true;
  }

  @override
  Future<void> stopServing() async {
    mutations.add('stopServing');
    serving = false;
  }
}

class SeenRequest {
  final String method;
  final String path;
  final Map<String, String> headers;
  final String body;
  final ExtensionManagementGrant? grant;
  final bool mayManage;

  SeenRequest({
    required this.method,
    required this.path,
    required this.headers,
    required this.body,
    required this.grant,
    required this.mayManage,
  });

  Map<String, Object?> toJson() => {
    'method': method,
    'path': path,
    'headers': headers,
    'body': body,
    'hasGrant': grant != null,
    'mayManage': mayManage,
  };
}

class SlowRoute {
  final entered = Completer<SeenRequest>();
  final release = Completer<void>();
  final finished = Completer<bool>();
}

Map<String, dynamic> pluginManifestJson(
  String id, {
  List<String> permissions = unprivilegedPermissions,
  String version = '1.0.0',
}) => {
  'id': id,
  'author': 'Test',
  'name': id,
  'description': 'Test plugin',
  'version': version,
  'apiVersion': 1,
  'permissions': permissions,
  'settings': {
    'mode': {'type': 'string'},
  },
  'api': [
    {'id': 'echo', 'type': 'http', 'data': <String, dynamic>{}},
  ],
};

String probePluginJs(String id, {String onLoad = '', String onUnload = ''}) =>
    '''
function createPlugin(host) {
  const probe = {
    emit: (event, payload) => host.emit(event, payload),
    run: (source) => eval(source)
  };
  globalThis.__probes = globalThis.__probes || {};
  globalThis.__probes[${jsonEncode(id)}] = probe;
  return {
    id: ${jsonEncode(id)},
    onLoad(settings) { $onLoad },
    onUnload() { $onUnload },
    handleHttpRequest(request) {
      return {
        status: 200,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ headers: request.headers, body: request.body })
      };
    }
  };
}
''';

typedef ProbeOutcome = Map<String, dynamic>;

extension ProbeOutcomeReading on ProbeOutcome {
  bool get resolved => containsKey('resolved');

  Object? get value => this['resolved'];

  Map<String, dynamic> get response => this['resolved'] as Map<String, dynamic>;

  int get status => response['status'] as int;

  Map<String, dynamic> get jsonBody =>
      jsonDecode(response['body'] as String) as Map<String, dynamic>;

  String? header(String name) {
    final headers = response['headers'] as Map<String, dynamic>;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value as String;
    }
    return null;
  }

  String get errorName => (this['rejected'] as Map)['name'].toString();

  String get errorMessage => (this['rejected'] as Map)['message'].toString();
}

class ExtensionManagementHarness {
  final Directory tempDir;
  final PluginLoaderService loader;
  final PluginSourceService sourceService;
  final ProxyTokenService tokens;
  final RecordingWebUIStorage skins;
  final RecordingWebUIService skinServer;
  final Handler handler;
  final HttpServer server;
  final List<SeenRequest> routed;
  final List<String> bridged;
  final List<Future<Response>> bridgedResponses;
  final List<String> socketHits;
  final List<SeenRequest> accountProxyHits;
  final List<SeenRequest> machineHits;
  final List<SeenRequest> settingsPosts;
  final Map<String, SlowRoute> slowRoutes;
  int _probeSeq = 0;
  final Map<String, Completer<ProbeOutcome>> _probeReports = {};
  final Map<
    String,
    ({String pluginId, JavascriptRuntime realm, int generation})
  >
  _stashes = {};

  ExtensionManagementHarness._({
    required this.tempDir,
    required this.loader,
    required this.sourceService,
    required this.tokens,
    required this.skins,
    required this.skinServer,
    required this.handler,
    required this.server,
    required this.routed,
    required this.bridged,
    required this.bridgedResponses,
    required this.socketHits,
    required this.accountProxyHits,
    required this.machineHits,
    required this.settingsPosts,
    required this.slowRoutes,
  });

  PluginManager get manager => loader.pluginManager;

  int get port => server.port;

  String url(String host, String path) => 'http://$host:$port$path';

  String get loopback => '127.0.0.1';

  static Future<ExtensionManagementHarness> start({
    bool? requireExtensionManagementAuthorization,
  }) async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    final tempDir = Directory.systemTemp.createTempSync('extension_mgmt');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempDir.path,
        );
    final loader = PluginLoaderService(kvStore: FakeKeyValueStoreService());
    await loader.initialize();
    for (final plugin in loader.availablePlugins) {
      await loader.removePlugin(plugin.id);
    }
    final sourceService = PluginSourceService(loader);
    final tokens = ProxyTokenService(skinToken: 'skin-token-0123456789abcdef')
      ..registerToken(
        managerToken,
        const ProxyCaller(
          id: 'api:manager',
          scopes: {ProxyTokenService.scopeExtensionsManage},
          label: 'Fleet',
        ),
      )
      ..registerToken(
        accountToken,
        const ProxyCaller(
          id: 'api:account',
          scopes: {
            ProxyTokenService.scopeAccountProxy,
            ProxyTokenService.scopeAccountProxyWrite,
          },
        ),
      );
    final skins = RecordingWebUIStorage();
    final skinServer = RecordingWebUIService();
    final routed = <SeenRequest>[];
    final bridged = <String>[];
    final bridgedResponses = <Future<Response>>[];
    final socketHits = <String>[];
    final accountProxyHits = <SeenRequest>[];
    final machineHits = <SeenRequest>[];
    final settingsPosts = <SeenRequest>[];
    final slowRoutes = <String, SlowRoute>{};

    Future<SeenRequest> see(Request request) async => SeenRequest(
      method: request.method,
      path: '/${request.url.path}',
      headers: Map.of(request.headers),
      body: await request.readAsString(),
      grant:
          request.context[extensionManagementGrantContextKey]
              as ExtensionManagementGrant?,
      mayManage: await mayManageExtensions(request),
    );

    final app = Router().plus;
    app.all('/api/v1/plugins/echo.fixture/<operation>', (
      Request request,
      String operation,
    ) async {
      final seen = await see(request);
      routed.add(seen);
      return Response.ok(
        jsonEncode(seen.toJson()),
        headers: {'content-type': 'application/json', 'x-echo': 'yes'},
      );
    });
    app.get(fixtureMarker, (Request request) => Response.ok('marker'));
    app.get(
      fixtureRedirect,
      (Request request) =>
          Response(307, headers: {'location': fixtureEcho}, body: 'moved'),
    );
    app.put('/api/v1/machine/state/<state>', (
      Request request,
      String state,
    ) async {
      machineHits.add(await see(request));
      return Response.ok('machine state requested');
    });
    app.post('/api/v1/settings', (Request request) async {
      settingsPosts.add(await see(request));
      return Response.ok('settings changed');
    });
    app.post('/api/v1/plugins/slow.<name>/enable', (
      Request request,
      String name,
    ) async {
      final slow = slowRoutes[name]!;
      slow.entered.complete(await see(request));
      await slow.release.future;
      slow.finished.complete(await mayManageExtensions(request));
      return Response.ok('slow done');
    });
    app.all('/api/v1/account/proxy/<rest|.*>', (Request request) async {
      accountProxyHits.add(await see(request));
      return Response.ok('proxied');
    });
    PluginsHandler(
      pluginManager: loader.pluginManager,
      pluginService: loader,
      pluginSourceService: sourceService,
    ).addRoutes(app);
    WebUIHandler(storage: skins, service: skinServer).addRoutes(app);

    final requirement = requireExtensionManagementAuthorization;
    int? apiListenerPort;
    final handler = buildWebServerHandler(
      app.call,
      proxyTokenService: tokens,
      requireExtensionManagementAuthorization: requirement == null
          ? null
          : () async => requirement,
      browserOrigins: extensionManagementBrowserOrigins(
        skinServer,
        apiListenerPort: () => apiListenerPort,
      ),
    );
    loader.pluginManager.attachLocalApi((request) {
      bridged.add('${request.method} ${request.requestedUri.path}');
      final response = Future.sync(() => handler(request));
      bridgedResponses.add(response);
      return response;
    });
    final server = await shelf_io.serve(
      (request) {
        socketHits.add('${request.method} ${request.requestedUri.path}');
        return handler(request);
      },
      InternetAddress.anyIPv4,
      0,
    );
    apiListenerPort = server.port;

    return ExtensionManagementHarness._(
      tempDir: tempDir,
      loader: loader,
      sourceService: sourceService,
      tokens: tokens,
      skins: skins,
      skinServer: skinServer,
      handler: handler,
      server: server,
      routed: routed,
      bridged: bridged,
      bridgedResponses: bridgedResponses,
      socketHits: socketHits,
      accountProxyHits: accountProxyHits,
      machineHits: machineHits,
      settingsPosts: settingsPosts,
      slowRoutes: slowRoutes,
    );
  }

  Future<void> dispose() async {
    await server.close(force: true);
    for (final slow in slowRoutes.values) {
      if (!slow.release.isCompleted) slow.release.complete();
    }
    await loader.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }

  Future<void> settleBridgedHandlers() => Future.wait(bridgedResponses);

  SlowRoute slowRoute(String name) => slowRoutes[name] = SlowRoute();

  Future<void> install(
    String id, {
    List<String> permissions = unprivilegedPermissions,
    String version = '1.0.0',
    String onLoad = '',
    String onUnload = '',
    bool load = true,
  }) async {
    await loader.updatePluginSource(
      id,
      manifestJson: pluginManifestJson(
        id,
        permissions: permissions,
        version: version,
      ),
      pluginJs: probePluginJs(id, onLoad: onLoad, onUnload: onUnload),
      authorized: true,
    );
    if (load) await loader.enablePlugin(id);
  }

  static const _probeChannel = 'extensionManagementProbe';

  /// [pluginId]'s current JS realm, wired to report probe outcomes straight
  /// to Dart so they still arrive while the probed plugin unloads itself.
  JavascriptRuntime realmOf(String pluginId) {
    final realm = manager.jsRealmOf(pluginId);
    realm.onMessage(_probeChannel, (message) {
      final report = message as Map<String, dynamic>;
      _probeReports
          .remove(report['tag'])
          ?.complete(Map<String, dynamic>.from(report['outcome'] as Map));
    });
    return realm;
  }

  void evaluate(String pluginId, String source) {
    final realm = realmOf(pluginId);
    final result = realm.evaluate(source);
    if (result.isError) {
      throw StateError('JS evaluation failed: ${result.stringResult}');
    }
    while (realm.executePendingJob() > 0) {}
  }

  Future<ProbeOutcome> probe(
    String pluginId,
    String expression, {
    String probeGlobal = '__probes',
    Duration timeout = const Duration(seconds: 15),
  }) {
    final tag = 'probe-${++_probeSeq}';
    final report = _probeReports[tag] = Completer<ProbeOutcome>();
    try {
      evaluate(pluginId, '''
      (function () {
        const report = (value) => sendMessage(
          ${jsonEncode(_probeChannel)},
          JSON.stringify({ tag: ${jsonEncode(tag)}, outcome: value })
        );
        let pending;
        try {
          pending = Promise.resolve(
            globalThis.$probeGlobal[${jsonEncode(pluginId)}].run(${jsonEncode(expression)})
          );
        } catch (error) {
          pending = Promise.reject(error);
        }
        pending.then(
          (value) => report({ resolved: value === undefined ? null : value }),
          (error) => report({
            rejected: {
              name: error && error.name ? String(error.name) : "",
              message: String(error && error.message !== undefined ? error.message : error)
            }
          })
        );
      })();
    ''');
    } catch (_) {
      _probeReports.remove(tag);
      rethrow;
    }
    return report.future.timeout(timeout);
  }

  Future<ProbeOutcome> localApi(
    String pluginId,
    Object? path, {
    Map<String, Object?> options = const {},
  }) => probe(
    pluginId,
    'host.localApi(${jsonEncode(path)}, ${jsonEncode(options)})',
  );

  Future<ProbeOutcome> fetch(
    String pluginId,
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
  }) => probe(pluginId, '''
      fetch(${jsonEncode(url)}, ${jsonEncode({'method': method, 'headers': headers, 'body': ?body})})
        .then((response) => response.text().then((text) => ({ status: response.status, body: text })))
    ''');

  /// Starts [expression] in [actorId]'s realm (default: [observerId]), lets a
  /// marker request from [observerId] pass the bridge after it, and returns
  /// how the attempt had settled by then.
  Future<String> settledState(
    String observerId,
    String expression, {
    String? actorId,
  }) async {
    final actor = actorId ?? observerId;
    final key = '__settledState${++_probeSeq}';
    evaluate(actor, '''
      (() => {
        globalThis.$key = "pending";
        let attempt;
        try {
          attempt = Promise.resolve(
            globalThis.__probes[${jsonEncode(actor)}].run(${jsonEncode(expression)})
          );
        } catch (error) {
          attempt = Promise.reject(error);
        }
        attempt.then(
          (value) => { globalThis.$key = "resolved:" + JSON.stringify(value); },
          (error) => { globalThis.$key = "rejected:" + String(error && error.message); }
        );
      })();
    ''');
    final marker = await localApi(observerId, fixtureMarker);
    expect(marker.resolved, isTrue, reason: '$marker');
    final realm = realmOf(actor);
    while (realm.executePendingJob() > 0) {}
    return realm.evaluate('globalThis.$key').stringResult;
  }

  /// Remembers [pluginId]'s current realm and generation so that
  /// [staleLocalApiState] can later try to act as that identity.
  void stash(String pluginId, {String as = '__stale'}) {
    _stashes[as] = (
      pluginId: pluginId,
      realm: realmOf(pluginId),
      generation: manager.pluginGeneration(pluginId)!,
    );
  }

  /// Tries a local API call as the identity stashed under [stash], lets a
  /// marker from [observerId] through, and returns how the attempt settled.
  ///
  /// While the stashed realm is live, its own closure makes the call. Once
  /// the identity is retired its realm is disposed, so no stale closure can
  /// run at all; the call is then replayed from the plugin's current realm,
  /// if it has one, under the stashed (retired) generation.
  Future<String> staleLocalApiState(
    String observerId,
    String path, {
    Map<String, Object?> options = const {},
    String stash = '__stale',
  }) async {
    final stashed = _stashes[stash]!;
    final pluginId = stashed.pluginId;
    if (stashed.realm.isRuntimeActive) {
      return settledState(
        observerId,
        'host.localApi(${jsonEncode(path)}, ${jsonEncode(options)})',
        actorId: pluginId,
      );
    }
    expect(() => stashed.realm.evaluate('0'), throwsStateError);
    if (!loader.isPluginLoaded(pluginId)) {
      final marker = await localApi(observerId, fixtureMarker);
      expect(marker.resolved, isTrue, reason: '$marker');
      return 'retired: realm disposed';
    }
    return settledState(
      observerId,
      'globalThis.__reaprimePluginBridge.localApi(pluginId, '
      '${stashed.generation}, pluginBridgeToken, ${jsonEncode(path)}, '
      '${jsonEncode(options['method'] ?? 'GET')}, '
      '${jsonEncode(options['body'])}, null)',
      actorId: pluginId,
    );
  }

  Future<({int status, String body, Map<String, String> headers})>
  externalRequest(
    String method,
    String path, {
    String? bearer,
    Object? body,
    Map<String, String> headers = const {},
  }) => externalRequestFrom(
    loopback,
    method,
    path,
    bearer: bearer,
    body: body,
    headers: headers,
  );

  Future<({int status, String body, Map<String, String> headers})>
  externalRequestFrom(
    String host,
    String method,
    String path, {
    String? bearer,
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse(url(host, path)));
      headers.forEach(request.headers.set);
      if (bearer != null) {
        request.headers.set('authorization', 'Bearer $bearer');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final received = <String, String>{};
      response.headers.forEach(
        (name, values) => received[name.toLowerCase()] = values.join(', '),
      );
      return (
        status: response.statusCode,
        body: await response.transform(utf8.decoder).join(),
        headers: received,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> extensionState() async => {
    'plugins': {
      for (final manifest in loader.availablePlugins)
        manifest.id: {
          'version': manifest.version,
          'permissions': manifest.permissions.map((p) => p.wireName).toList()
            ..sort(),
          'loaded': loader.isPluginLoaded(manifest.id),
          'autoLoad': await loader.shouldAutoLoad(manifest.id),
          'settings': await loader.pluginSettings(manifest.id),
          'pendingUpdate': sourceService
              .sourceFor(manifest.id)
              ?.pendingUpdate
              ?.toJson(),
        },
    },
    'skinMutations': List.of(skins.mutations),
    'skinServerMutations': List.of(skinServer.mutations),
  };
}

({String method, String path, Object? body}) concreteManagementRequest(
  ExtensionManagementRoute route, {
  required String targetId,
  required String dormantId,
}) {
  final isSkinRoute = route.path.startsWith('/api/v1/webui/');
  final id = isSkinRoute
      ? recordedSkinId
      : route.path.endsWith('/enable')
      ? dormantId
      : targetId;
  final path = route.path.replaceAll('<id>', id);
  final Object? body = switch (path) {
    _ when path.endsWith('/settings') => {'mode': 'changed'},
    _ when path.endsWith('/source') => {
      'manifest': pluginManifestJson(
        targetId,
        permissions: const ['emit', 'api', 'manage.extensions'],
        version: '9.0.0',
      ),
      'plugin': probePluginJs(targetId),
    },
    _ when path.endsWith('/skins/default') => {'skinId': recordedSkinId},
    _ when path.endsWith('/machine-control') => {'granted': true},
    _ when path.contains('/install') => {
      'repo': 'acme/never',
      'url': 'https://example.test/never.zip',
    },
    _ => null,
  };
  return (method: route.method, path: path, body: body);
}
