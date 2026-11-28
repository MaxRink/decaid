import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../plugins/plugin_test_helpers.dart';

const _managerToken = 'manager-token';

class _Grant implements ExtensionManagementGrant {
  @override
  String get callerId => 'plugin:manager.reaplugin';

  @override
  bool get isActive => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'secret.reaplugin';
  late Directory tempDir;
  late PluginLoaderService loader;
  late PluginSourceService sources;
  late Handler handler;

  Map<String, dynamic> manifestJson({
    String version = '1.0.0',
    List<String> permissions = const ['emit'],
  }) => {
    'id': id,
    'author': 'Test',
    'name': 'Secret plugin',
    'description': 'Stores a token',
    'version': version,
    'apiVersion': 1,
    'permissions': permissions,
    'settings': {
      'token': {'type': 'string', 'secure': true},
    },
    'api': <Object>[],
  };

  String pluginJs([String marker = 'original']) =>
      '''
// $marker
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''';

  List<int> archive({
    String version = '1.0.0',
    List<String> permissions = const ['emit'],
    String marker = 'original',
  }) {
    final zip = Archive()
      ..addFile(
        ArchiveFile.string(
          'repo-main/manifest.json',
          jsonEncode(manifestJson(version: version, permissions: permissions)),
        ),
      )
      ..addFile(ArchiveFile.string('repo-main/plugin.js', pluginJs(marker)));
    return ZipEncoder().encode(zip);
  }

  MockClient gitHub(List<int> package, {String tag = 'v1.0.0'}) =>
      MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/releases/')) {
          return http.Response(
            jsonEncode({
              'tag_name': tag,
              'name': tag,
              'assets': [
                {
                  'name': 'plugin.zip',
                  'browser_download_url': 'https://example.test/plugin.zip',
                },
              ],
            }),
            200,
          );
        }
        if (url.contains('/commits/')) {
          return http.Response(jsonEncode({'sha': 'commit-$tag'}), 200);
        }
        return http.Response.bytes(package, 200);
      });

  Future<({int status, Map<String, dynamic> body})> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool bearer = false,
    bool grant = false,
    List<int>? package,
    String tag = 'v1.0.0',
  }) async {
    final response = await http.runWithClient(
      () async => handler(
        Request(
          method,
          Uri.parse('http://localhost$path'),
          headers: {
            'content-type': 'application/json',
            if (bearer) 'authorization': 'Bearer $_managerToken',
          },
          body: body == null ? null : jsonEncode(body),
          context: {if (grant) extensionManagementGrantContextKey: _Grant()},
        ),
      ),
      () => gitHub(package ?? archive(), tag: tag),
    );
    final text = await response.readAsString();
    return (
      status: response.statusCode,
      body: text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  Future<bool> tokenIsSet() async =>
      ((await loader.pluginSettings(id))['token'] as Map)['isSet'] as bool;

  Future<void> configure() =>
      loader.savePluginSettings(id, {'token': 's3cret'});

  Map<String, dynamic> sourceWrite({
    String version = '1.0.1',
    List<String> permissions = const ['emit'],
    String marker = 'replacement',
    Map<String, dynamic> extra = const {},
  }) => {
    'manifest': manifestJson(version: version, permissions: permissions),
    'plugin': pluginJs(marker),
    ...extra,
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('plugins_handler_replace');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempDir.path,
        );
    loader = PluginLoaderService(kvStore: FakeKeyValueStoreService());
    await loader.initialize();
    sources = PluginSourceService(loader);
    final tokens = ProxyTokenService(skinToken: 'skin-token-0123456789abcdef')
      ..registerToken(
        _managerToken,
        const ProxyCaller(
          id: 'api:manager',
          scopes: {ProxyTokenService.scopeExtensionsManage},
        ),
      );
    final app = Router().plus;
    PluginsHandler(
      pluginManager: loader.pluginManager,
      pluginService: loader,
      pluginSourceService: sources,
    ).addRoutes(app);
    handler = const Pipeline()
        .addMiddleware(
          extensionManagementAuthMiddleware(
            tokens,
            requireExtensionManagementAuthorization: () async => false,
          ),
        )
        .addHandler(app.call);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await loader.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('PUT /api/v1/plugins/<id>/source', () {
    const path = '/api/v1/plugins/$id/source';

    Future<void> installConfigured() async {
      final created = await send(
        'PUT',
        path,
        body: sourceWrite(version: '1.0.0', marker: 'original'),
      );
      expect(created.status, 200);
      await configure();
    }

    test('without a credential a code change clears the secrets', () async {
      await installConfigured();

      final response = await send('PUT', path, body: sourceWrite());

      expect(response.status, 200);
      expect(response.body['secureSettingsCleared'], isTrue);
      expect(await tokenIsSet(), isFalse);
    });

    test('without a credential an added permission gets 409', () async {
      await installConfigured();

      final response = await send(
        'PUT',
        path,
        body: sourceWrite(permissions: ['emit', 'api']),
      );

      expect(response.status, 409);
      expect(response.body['id'], id);
      expect(response.body['addedPermissions'], ['api']);
      expect(response.body['credentialRequired'], isTrue);
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(await tokenIsSet(), isTrue);
    });

    test('without a credential approvals are refused with 403', () async {
      await installConfigured();

      for (final extra in [
        {'keepSecureSettings': true},
        {
          'approvePermissions': ['api'],
        },
      ]) {
        final response = await send(
          'PUT',
          path,
          body: sourceWrite(permissions: ['emit', 'api'], extra: extra),
        );
        expect(response.status, 403, reason: '$extra');
      }
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(await tokenIsSet(), isTrue);
    });

    test('the same code reloads with its secrets', () async {
      await installConfigured();

      final response = await send(
        'PUT',
        path,
        body: sourceWrite(marker: 'original'),
      );

      expect(response.status, 200);
      expect(response.body['secureSettingsCleared'], isFalse);
      expect(await tokenIsSet(), isTrue);
    });

    test('a credential keeps the secrets only when asked to', () async {
      await installConfigured();

      final cleared = await send(
        'PUT',
        path,
        body: sourceWrite(),
        bearer: true,
      );
      expect(cleared.status, 200);
      expect(cleared.body['secureSettingsCleared'], isTrue);
      expect(await tokenIsSet(), isFalse);

      await configure();
      final kept = await send(
        'PUT',
        path,
        body: sourceWrite(
          version: '1.0.2',
          marker: 'again',
          extra: {'keepSecureSettings': true},
        ),
        bearer: true,
      );
      expect(kept.status, 200);
      expect(kept.body['secureSettingsCleared'], isFalse);
      expect(await tokenIsSet(), isTrue);
    });

    test('a credential must name the permissions it approves', () async {
      await installConfigured();

      final refused = await send(
        'PUT',
        path,
        body: sourceWrite(permissions: ['emit', 'api', 'notifications']),
        grant: true,
      );
      expect(refused.status, 409);
      expect(refused.body['addedPermissions'], ['api', 'notifications']);
      expect(refused.body['credentialRequired'], isFalse);

      final partial = await send(
        'PUT',
        path,
        body: sourceWrite(
          permissions: ['emit', 'api', 'notifications'],
          extra: {
            'approvePermissions': ['api'],
          },
        ),
        grant: true,
      );
      expect(partial.status, 409);

      final approved = await send(
        'PUT',
        path,
        body: sourceWrite(
          permissions: ['emit', 'api', 'notifications'],
          extra: {
            'approvePermissions': ['api', 'notifications'],
            'keepSecureSettings': true,
          },
        ),
        grant: true,
      );
      expect(approved.status, 200);
      expect(loader.getPluginManifest(id)?.version, '1.0.1');
      expect(await tokenIsSet(), isTrue);
    });
  });

  for (final kind in ['github-release', 'github-branch']) {
    group('POST /api/v1/plugins/install/$kind over an installed plugin', () {
      final path = '/api/v1/plugins/install/$kind';

      Future<void> installConfigured() async {
        final installed = await send('POST', path, body: {'repo': 'acme/x'});
        expect(installed.status, 200, reason: '${installed.body}');
        await configure();
      }

      test('without a credential a code change clears the secrets', () async {
        await installConfigured();

        final response = await send(
          'POST',
          path,
          body: {'repo': 'acme/x'},
          package: archive(version: '1.1.0', marker: 'replacement'),
          tag: 'v1.1.0',
        );

        expect(response.status, 200, reason: '${response.body}');
        expect(response.body['secureSettingsCleared'], isTrue);
        expect(await tokenIsSet(), isFalse);
      });

      test('without a credential an added permission gets 409', () async {
        await installConfigured();

        final response = await send(
          'POST',
          path,
          body: {'repo': 'acme/x'},
          package: archive(version: '1.1.0', permissions: ['emit', 'api']),
          tag: 'v1.1.0',
        );

        expect(response.status, 409);
        expect(response.body['addedPermissions'], ['api']);
        expect(loader.getPluginManifest(id)?.version, '1.0.0');
        expect(await tokenIsSet(), isTrue);
      });

      test('another repository keeps secrets only when told to', () async {
        await installConfigured();

        final response = await send(
          'POST',
          path,
          body: {'repo': 'mallory/x', 'keepSecureSettings': true},
          bearer: true,
        );
        expect(response.status, 200);
        expect(await tokenIsSet(), isTrue);

        await configure();
        final unattended = await send('POST', path, body: {'repo': 'eve/x'});
        expect(unattended.status, 200);
        expect(unattended.body['secureSettingsCleared'], isTrue);
        expect(await tokenIsSet(), isFalse);
      });

      test('a credential that approves keeps secrets and grants', () async {
        await installConfigured();

        final response = await send(
          'POST',
          path,
          body: {
            'repo': 'acme/x',
            'approvePermissions': ['api'],
            'keepSecureSettings': true,
          },
          bearer: true,
          package: archive(
            version: '1.1.0',
            permissions: ['emit', 'api'],
            marker: 'replacement',
          ),
          tag: 'v1.1.0',
        );

        expect(response.status, 200, reason: '${response.body}');
        expect(loader.getPluginManifest(id)?.version, '1.1.0');
        expect(await tokenIsSet(), isTrue);
      });
    });
  }

  group('POST /api/v1/plugins/<id>/update/approve', () {
    const path = '/api/v1/plugins/$id/update/approve';

    Future<void> pendingUpdateOfConfiguredPlugin() async {
      final installed = await send(
        'POST',
        '/api/v1/plugins/install/github-release',
        body: {'repo': 'acme/x'},
      );
      expect(installed.status, 200);
      await configure();
      final check = await send(
        'POST',
        '/api/v1/plugins/update',
        package: archive(version: '1.1.0', marker: 'replacement'),
        tag: 'v1.1.0',
      );
      expect(check.status, 200);
      expect(
        sources.sourceFor(id)?.pendingUpdate?.handsOverSecureSettings,
        isTrue,
      );
    }

    test('without a credential approval is refused with 403', () async {
      await pendingUpdateOfConfiguredPlugin();

      final response = await send(
        'POST',
        path,
        package: archive(version: '1.1.0', marker: 'replacement'),
        tag: 'v1.1.0',
      );

      expect(response.status, 403);
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(await tokenIsSet(), isTrue);
    });

    test('a credential decides whether the secrets are kept', () async {
      await pendingUpdateOfConfiguredPlugin();

      final response = await send(
        'POST',
        path,
        body: {'keepSecureSettings': true},
        bearer: true,
        package: archive(version: '1.1.0', marker: 'replacement'),
        tag: 'v1.1.0',
      );

      expect(response.status, 200, reason: '${response.body}');
      expect(response.body['secureSettingsCleared'], isFalse);
      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(await tokenIsSet(), isTrue);
    });
  });
}
