import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginLoaderService source updates', () {
    late Directory tempDir;
    late PluginLoaderService service;

    Map<String, dynamic> manifestJson(String id, {String version = '1.0.0'}) =>
        {
          'id': id,
          'author': 'Test',
          'name': 'Test plugin',
          'description': 'Test plugin',
          'version': version,
          'apiVersion': 1,
          'permissions': <String>[],
          'settings': <String, dynamic>{},
          'api': <Object>[],
        };

    String pluginJs(String id) =>
        '''
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''';

    Future<void> install(String id, {String version = '1.0.0'}) async {
      final dir = Directory('${tempDir.path}/source_${id}_$version')
        ..createSync(recursive: true);
      File('${dir.path}/manifest.json')
          .writeAsStringSync(jsonEncode(manifestJson(id, version: version)));
      File('${dir.path}/plugin.js').writeAsStringSync(pluginJs(id));
      await service.addPlugin(dir.path);
    }

    Future<void> update(String id, String version) =>
        service.updatePluginSource(
          id,
          manifestJson: manifestJson(id, version: version),
          pluginJs: '// $version\n${pluginJs(id)}',
        );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('plugin_loader_update');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tempDir.path,
          );
      service = PluginLoaderService(kvStore: FakeKeyValueStoreService());
      await service.initialize();
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await service.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('addPlugin rejects an older version of an installed plugin', () async {
      const id = 'versioned.reaplugin';
      await install(id, version: '2.0.0');

      await expectLater(
        install(id, version: '1.0.0'),
        throwsA(isA<PluginDowngradeException>()),
      );
      expect(service.getPluginManifest(id)?.version, '2.0.0');
    });

    test('addPlugin accepts the same or a newer version', () async {
      const id = 'versioned.reaplugin';
      await install(id, version: '2.0.0');

      await install(id, version: '2.0.0');
      expect(service.getPluginManifest(id)?.version, '2.0.0');

      await install(id, version: '2.0.1');
      expect(service.getPluginManifest(id)?.version, '2.0.1');
    });

    test('prerelease versions rank below their release', () async {
      const id = 'prerelease.reaplugin';
      await install(id, version: '1.0.0-beta.2');

      await expectLater(
        update(id, '1.0.0-beta.1'),
        throwsA(isA<PluginDowngradeException>()),
      );

      await update(id, '1.0.0');
      expect(service.getPluginManifest(id)?.version, '1.0.0');

      await expectLater(
        update(id, '1.0.0-rc.1'),
        throwsA(isA<PluginDowngradeException>()),
      );
    });

    test('updatePluginSource rejects a manifest id mismatch', () async {
      const id = 'mismatch.reaplugin';
      await install(id);

      await expectLater(
        service.updatePluginSource(
          id,
          manifestJson: manifestJson('other.reaplugin'),
          pluginJs: pluginJs(id),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(service.getPluginManifest('other.reaplugin'), isNull);
    });

    test('concurrent updates apply one at a time', () async {
      const id = 'concurrent.reaplugin';
      await install(id);

      await Future.wait([update(id, '1.1.0'), update(id, '1.2.0')]);

      final onDisk = jsonDecode(
        File('${tempDir.path}/plugins/$id/manifest.json').readAsStringSync(),
      );
      expect(onDisk['version'], '1.2.0');
      expect(service.getPluginManifest(id)?.version, '1.2.0');
      expect(
        File('${tempDir.path}/plugins/$id/plugin.js').readAsStringSync(),
        startsWith('// 1.2.0'),
      );
    });

    test('an update does not interleave with a concurrent unload', () async {
      const id = 'lifecycle.reaplugin';
      await install(id);
      await service.loadPlugin(id);

      await Future.wait([update(id, '1.1.0'), service.unloadPlugin(id)]);

      expect(service.isPluginLoaded(id), isFalse);
      expect(service.getPluginManifest(id)?.version, '1.1.0');
    });

    test('an update does not interleave with a concurrent load', () async {
      const id = 'lifecycle2.reaplugin';
      await install(id);

      await Future.wait([update(id, '1.1.0'), service.loadPlugin(id)]);

      expect(service.isPluginLoaded(id), isTrue);
      expect(service.getPluginManifest(id)?.version, '1.1.0');
    });

    test(
      'a failed write leaves the previous version installed and running',
      () async {
        const id = 'writefail.reaplugin';
        await install(id);
        await service.loadPlugin(id);
        Directory('${tempDir.path}/plugins/$id/plugin.js.staged')
            .createSync(recursive: true);

        await expectLater(
          update(id, '2.0.0'),
          throwsA(isA<FileSystemException>()),
        );

        expect(service.isPluginLoaded(id), isTrue);
        expect(service.getPluginManifest(id)?.version, '1.0.0');
        final onDisk = jsonDecode(
          File('${tempDir.path}/plugins/$id/manifest.json').readAsStringSync(),
        );
        expect(onDisk['version'], '1.0.0');
        expect(
          File('${tempDir.path}/plugins/$id/plugin.js').readAsStringSync(),
          pluginJs(id),
        );
      },
    );

    test('enablePlugin sets auto-load and loads under one lock', () async {
      const id = 'enable.reaplugin';
      await install(id);

      await service.enablePlugin(id);

      expect(service.isPluginLoaded(id), isTrue);
      expect(await service.shouldAutoLoad(id), isTrue);
    });

    test('enablePlugin leaves auto-load off when the load fails', () async {
      const id = 'enablefail.reaplugin';
      await install(id);
      File('${tempDir.path}/plugins/$id/plugin.js').writeAsStringSync(
        'function createPlugin() { throw new Error("boom"); }',
      );

      await expectLater(service.enablePlugin(id), throwsA(anything));

      expect(service.isPluginLoaded(id), isFalse);
      expect(await service.shouldAutoLoad(id), isFalse);
    });

    test('disablePlugin unloads and clears auto-load under one lock', () async {
      const id = 'disable.reaplugin';
      await install(id);
      await service.enablePlugin(id);

      await service.disablePlugin(id);

      expect(service.isPluginLoaded(id), isFalse);
      expect(await service.shouldAutoLoad(id), isFalse);
    });

    test('concurrent enable/disable end in a consistent state', () async {
      const id = 'togglerace.reaplugin';
      await install(id);

      await Future.wait([
        service.enablePlugin(id),
        service.disablePlugin(id),
        service.enablePlugin(id),
      ]);

      expect(service.isPluginLoaded(id), await service.shouldAutoLoad(id));
    });

    test('enable/disable do not interleave with a concurrent update', () async {
      const id = 'toggleupdate.reaplugin';
      await install(id);

      await Future.wait([
        service.enablePlugin(id),
        update(id, '1.1.0'),
        service.disablePlugin(id),
      ]);

      expect(service.getPluginManifest(id)?.version, '1.1.0');
      expect(service.isPluginLoaded(id), await service.shouldAutoLoad(id));
    });
    group('source writes and stored secrets', () {
      const id = 'secret.reaplugin';

      Map<String, dynamic> secretManifest({
        String version = '1.0.0',
        List<String> permissions = const [],
      }) => {
        ...manifestJson(id, version: version),
        'permissions': permissions,
        'settings': {
          'token': {'type': 'string', 'secure': true},
          'name': {'type': 'string'},
        },
      };

      Future<void> installWithSecret() async {
        final dir = Directory('${tempDir.path}/source_secret')
          ..createSync(recursive: true);
        File('${dir.path}/manifest.json')
            .writeAsStringSync(jsonEncode(secretManifest()));
        File('${dir.path}/plugin.js').writeAsStringSync(pluginJs(id));
        await service.addPlugin(dir.path);
        await service.savePluginSettings(id, {
          'token': 's3cret',
          'name': 'kept',
        });
      }

      test('an unauthorized code change clears the stored secrets', () async {
        await installWithSecret();

        await service.updatePluginSource(
          id,
          manifestJson: secretManifest(version: '1.0.1'),
          pluginJs: '// changed\n${pluginJs(id)}',
        );

        final settings = await service.pluginSettings(id);
        expect(settings['token'], {'isSet': false});
        expect(settings['name'], 'kept');
      });

      test('an authorized code change keeps the stored secrets', () async {
        await installWithSecret();

        await service.updatePluginSource(
          id,
          manifestJson: secretManifest(version: '1.0.1'),
          pluginJs: '// changed\n${pluginJs(id)}',
          authorized: true,
        );

        expect((await service.pluginSettings(id))['token'], {'isSet': true});
      });

      test('a manifest-only write keeps the stored secrets', () async {
        await installWithSecret();

        await service.updatePluginSource(
          id,
          manifestJson: secretManifest(version: '1.0.1'),
          pluginJs: pluginJs(id),
        );

        expect((await service.pluginSettings(id))['token'], {'isSet': true});
      });

      test('an unauthorized write cannot add permissions', () async {
        await installWithSecret();

        await expectLater(
          service.updatePluginSource(
            id,
            manifestJson: secretManifest(
              version: '1.0.1',
              permissions: ['api'],
            ),
            pluginJs: pluginJs(id),
          ),
          throwsA(isA<PluginPermissionApprovalRequiredException>()),
        );
        expect(service.getPluginManifest(id)?.version, '1.0.0');
        expect((await service.pluginSettings(id))['token'], {'isSet': true});
      });

      test(
        'an unauthorized write may create a plugin with permissions',
        () async {
          await service.updatePluginSource(
            'fresh.reaplugin',
            manifestJson: {
              ...manifestJson('fresh.reaplugin'),
              'permissions': ['api'],
            },
            pluginJs: pluginJs('fresh.reaplugin'),
          );

          expect(service.getPluginManifest('fresh.reaplugin'), isNotNull);
        },
      );

      test('an authorized write may add permissions', () async {
        await installWithSecret();

        await service.updatePluginSource(
          id,
          manifestJson: secretManifest(version: '1.0.1', permissions: ['api']),
          pluginJs: pluginJs(id),
          authorized: true,
        );

        expect(service.getPluginManifest(id)?.version, '1.0.1');
      });
    });
    group('machine control grant', () {
      const id = 'skale.reaplugin';

      test('a grant persists and can be revoked', () async {
        await install(id);
        expect(service.machineControlGranted(id), isFalse);

        await service.setMachineControlGrant(id, true);
        expect(service.machineControlGranted(id), isTrue);
        expect(service.pluginManager.machineControlGranted(id), isTrue);

        await service.setMachineControlGrant(id, false);
        expect(service.machineControlGranted(id), isFalse);
      });

      test('a source write that changes the code clears the grant', () async {
        await install(id);
        await service.setMachineControlGrant(id, true);

        await service.updatePluginSource(
          id,
          manifestJson: manifestJson(id, version: '1.0.1'),
          pluginJs: pluginJs(id),
          authorized: true,
        );
        expect(service.machineControlGranted(id), isTrue);

        await service.updatePluginSource(
          id,
          manifestJson: manifestJson(id, version: '1.0.2'),
          pluginJs: '// changed\n${pluginJs(id)}',
          authorized: true,
        );
        expect(service.machineControlGranted(id), isFalse);
      });

      test('an installed update keeps the grant', () async {
        await install(id);
        await service.setMachineControlGrant(id, true);

        await install(id, version: '1.1.0');

        expect(service.getPluginManifest(id)?.version, '1.1.0');
        expect(service.machineControlGranted(id), isTrue);
      });

      test('removing the plugin clears the grant', () async {
        await install(id);
        await service.setMachineControlGrant(id, true);

        await service.removePlugin(id);
        await install(id);

        expect(service.machineControlGranted(id), isFalse);
      });

      test('an unknown plugin cannot be granted', () async {
        await expectLater(
          service.setMachineControlGrant('missing.reaplugin', true),
          throwsA(isA<Exception>()),
        );
      });
    });
    group('package installs over an installed plugin', () {
      const id = 'reused.reaplugin';

      Directory package({
        String version = '1.1.0',
        List<String> permissions = const [],
        String marker = '',
      }) {
        final dir = Directory('${tempDir.path}/pkg_${version}_$marker')
          ..createSync(recursive: true);
        File('${dir.path}/manifest.json').writeAsStringSync(
          jsonEncode({
            ...manifestJson(id, version: version),
            'permissions': permissions,
            'settings': {
              'token': {'type': 'string', 'secure': true},
            },
          }),
        );
        File('${dir.path}/plugin.js')
            .writeAsStringSync('// $marker\n${pluginJs(id)}');
        return dir;
      }

      Future<void> installWithSecretAndGrant() async {
        await service.installPluginPackage(package(version: '1.0.0'));
        await service.savePluginSettings(id, {'token': 's3cret'});
        await service.setMachineControlGrant(id, true);
      }

      test('an unauthorized install that changes the code clears secrets '
          'and the machine-control grant', () async {
        await installWithSecretAndGrant();

        await service.installPluginPackage(
          package(marker: 'other'),
          authorized: false,
        );

        expect(service.getPluginManifest(id)?.version, '1.1.0');
        expect((await service.pluginSettings(id))['token'], {'isSet': false});
        expect(service.machineControlGranted(id), isFalse);
      });

      test('an unauthorized install cannot add permissions', () async {
        await installWithSecretAndGrant();

        await expectLater(
          service.installPluginPackage(
            package(permissions: ['api']),
            authorized: false,
          ),
          throwsA(isA<PluginPermissionApprovalRequiredException>()),
        );
        expect(service.getPluginManifest(id)?.version, '1.0.0');
        expect((await service.pluginSettings(id))['token'], {'isSet': true});
      });

      test(
        'an authorized install keeps secrets and may add permissions',
        () async {
          await installWithSecretAndGrant();

          await service.installPluginPackage(
            package(permissions: ['api'], marker: 'other'),
          );

          expect((await service.pluginSettings(id))['token'], {'isSet': true});
          expect(service.machineControlGranted(id), isTrue);
        },
      );

      test('an unauthorized fresh install is unaffected', () async {
        await service.installPluginPackage(
          package(permissions: ['api']),
          authorized: false,
        );
        expect(service.getPluginManifest(id)?.version, '1.1.0');
      });
    });
  });
}
