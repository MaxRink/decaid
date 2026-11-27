import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_replacement.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_test_helpers.dart';

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      values[key] = value;

  @override
  Future<void> delete({required String key}) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'secret.reaplugin';
  late Directory tempDir;
  late PluginLoaderService loader;

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
      'name': {'type': 'string'},
    },
    'api': <Object>[],
  };

  String pluginJs({String marker = 'original', bool throwOnLoad = false}) =>
      '''
// $marker
function createPlugin(host) {
  return {
    id: "$id",
    onLoad(settings) {
      ${throwOnLoad ? 'throw new Error("broken");' : ''}
      host.emit("loaded", { marker: "$marker", settings: settings });
    }
  };
}
''';

  Directory package({
    String version = '1.0.0',
    List<String> permissions = const ['emit'],
    String marker = 'original',
  }) {
    final dir = Directory('${tempDir.path}/pkg_${version}_$marker')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync(
      jsonEncode(manifestJson(version: version, permissions: permissions)),
    );
    File('${dir.path}/plugin.js').writeAsStringSync(pluginJs(marker: marker));
    return dir;
  }

  Future<Map<String, dynamic>> nextLoad(Future<void> Function() action) async {
    final loaded = loader.pluginManager.emitStream.firstWhere(
      (event) => event['pluginId'] == id && event['event'] == 'loaded',
    );
    await action();
    final event = await loaded.timeout(const Duration(seconds: 5));
    return Map<String, dynamic>.from(event['payload'] as Map);
  }

  Future<void> installConfigured() async {
    await loader.installPluginPackage(package());
    await loader.savePluginSettings(id, {'token': 's3cret', 'name': 'kept'});
    await loader.enablePlugin(id);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('plugin_replacement_gate');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempDir.path,
        );
    loader = PluginLoaderService(kvStore: FakeKeyValueStoreService());
    await loader.initialize();
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

  group('source writes', () {
    test('changed code without a decision is refused', () async {
      await installConfigured();

      await expectLater(
        loader.updatePluginSource(
          id,
          manifestJson: manifestJson(version: '1.0.1'),
          pluginJs: pluginJs(marker: 'replacement'),
        ),
        throwsA(
          isA<PluginReplacementApprovalRequiredException>().having(
            (e) => e.replacement.handsOverSecureSettings,
            'handsOverSecureSettings',
            isTrue,
          ),
        ),
      );
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect((await loader.pluginSettings(id))['token'], {'isSet': true});
    });

    test('an unattended code change never hands the secret over', () async {
      await installConfigured();

      final loaded = await nextLoad(
        () => loader.updatePluginSource(
          id,
          manifestJson: manifestJson(version: '1.0.1'),
          pluginJs: pluginJs(marker: 'replacement'),
          approveReplacement: (_) => PluginReplacementDecision.unattended,
        ),
      );

      expect(loaded['marker'], 'replacement');
      expect(loaded['settings'], isNot(contains('token')));
      expect(loaded['settings'], containsPair('name', 'kept'));
      final settings = await loader.pluginSettings(id);
      expect(settings['token'], {'isSet': false});
      expect(settings['name'], 'kept');
    });

    test('a decision that keeps secrets hands them to the new code', () async {
      await installConfigured();

      final loaded = await nextLoad(
        () => loader.updatePluginSource(
          id,
          manifestJson: manifestJson(version: '1.0.1'),
          pluginJs: pluginJs(marker: 'replacement'),
          approveReplacement: (_) =>
              const PluginReplacementDecision(keepSecureSettings: true),
        ),
      );

      expect(loaded['marker'], 'replacement');
      expect(loaded['settings'], containsPair('token', 's3cret'));
    });

    test('the same code reloads with its secrets and asks nobody', () async {
      await installConfigured();
      var asked = 0;

      final loaded = await nextLoad(
        () => loader.updatePluginSource(
          id,
          manifestJson: manifestJson(version: '1.0.1'),
          pluginJs: pluginJs(),
          approveReplacement: (_) {
            asked++;
            return null;
          },
        ),
      );

      expect(asked, 0);
      expect(loaded['settings'], containsPair('token', 's3cret'));
      expect(loader.getPluginManifest(id)?.version, '1.0.1');
    });

    test('an added permission is refused unless approved', () async {
      await installConfigured();

      await expectLater(
        loader.updatePluginSource(
          id,
          manifestJson: manifestJson(
            version: '1.0.1',
            permissions: ['emit', 'api'],
          ),
          pluginJs: pluginJs(),
          approveReplacement: (_) => PluginReplacementDecision.unattended,
        ),
        throwsA(
          isA<PluginReplacementApprovalRequiredException>().having(
            (e) => e.replacement.addedPermissions,
            'addedPermissions',
            ['api'],
          ),
        ),
      );
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(loader.isPluginLoaded(id), isTrue);
      expect((await loader.pluginSettings(id))['token'], {'isSet': true});

      await loader.updatePluginSource(
        id,
        manifestJson: manifestJson(
          version: '1.0.1',
          permissions: ['emit', 'api'],
        ),
        pluginJs: pluginJs(),
        approveReplacement: (_) =>
            const PluginReplacementDecision(approvedPermissions: {'api'}),
      );
      expect(loader.getPluginManifest(id)?.version, '1.0.1');
      expect((await loader.pluginSettings(id))['token'], {'isSet': true});
    });

    test('a failed replacement restores the cleared secrets', () async {
      await installConfigured();

      await expectLater(
        loader.updatePluginSource(
          id,
          manifestJson: manifestJson(version: '1.0.1'),
          pluginJs: pluginJs(marker: 'broken', throwOnLoad: true),
          approveReplacement: (_) => PluginReplacementDecision.unattended,
        ),
        throwsA(anything),
      );

      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect((await loader.pluginSettings(id))['token'], {'isSet': true});
    });

    test('a first install is not reviewed', () async {
      var asked = 0;
      await loader.updatePluginSource(
        id,
        manifestJson: manifestJson(permissions: ['emit', 'api']),
        pluginJs: pluginJs(),
        approveReplacement: (_) {
          asked++;
          return null;
        },
      );

      expect(asked, 0);
      expect(loader.getPluginManifest(id), isNotNull);
    });
  });

  group('package installs', () {
    test('a changed package without a decision is refused', () async {
      await installConfigured();

      await expectLater(
        loader.installPluginPackage(
          package(version: '1.1.0', marker: 'replacement'),
        ),
        throwsA(isA<PluginReplacementApprovalRequiredException>()),
      );
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect((await loader.pluginSettings(id))['token'], {'isSet': true});
    });

    test('an unattended package install clears the secrets first', () async {
      await installConfigured();

      final loaded = await nextLoad(
        () => loader.installPluginPackage(
          package(version: '1.1.0', marker: 'replacement'),
          approveReplacement: (_) => PluginReplacementDecision.unattended,
        ),
      );

      expect(loaded['marker'], 'replacement');
      expect(loaded['settings'], isNot(contains('token')));
    });

    test('the same code from another source is a new principal', () async {
      await installConfigured();
      PluginReplacement? reviewed;

      final loaded = await nextLoad(
        () => loader.installPluginPackage(
          package(version: '1.1.0'),
          sourceChanged: true,
          approveReplacement: (replacement) {
            reviewed = replacement;
            return PluginReplacementDecision.unattended;
          },
        ),
      );

      expect(reviewed?.codeChanged, isFalse);
      expect(reviewed?.sourceChanged, isTrue);
      expect(loaded['settings'], isNot(contains('token')));
    });

    test('the same package from the same source keeps its secrets', () async {
      await installConfigured();

      final loaded = await nextLoad(
        () => loader.installPluginPackage(package(version: '1.1.0')),
      );

      expect(loaded['settings'], containsPair('token', 's3cret'));
    });

    test('a fresh install never inherits secrets left behind', () async {
      final store = _MemoryCredentialStore();
      await loader.dispose();
      loader = PluginLoaderService(
        kvStore: FakeKeyValueStoreService(),
        credentialStore: store,
      );
      await loader.initialize();
      await installConfigured();
      expect(store.values, isNotEmpty);

      await loader.dispose();
      Directory('${tempDir.path}/plugins/$id').deleteSync(recursive: true);
      loader = PluginLoaderService(
        kvStore: FakeKeyValueStoreService(),
        credentialStore: store,
      );
      await loader.initialize();
      expect(loader.getPluginManifest(id), isNull);

      final loaded = await nextLoad(() async {
        await loader.installPluginPackage(package(marker: 'stranger'));
        await loader.enablePlugin(id);
      });

      expect(loaded['settings'], isNot(contains('token')));
      expect(store.values, isEmpty);
    });
  });
}
