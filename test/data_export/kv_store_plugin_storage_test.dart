import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/data_export_handler.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:reaprime/src/services/storage/hive_store_service.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/kv_store_export_section.dart';

import 'streaming_test_helpers.dart';

void main() {
  late Directory dir;
  late HiveStoreService pluginStore;
  late HiveStoreService restStore;
  late List<Set<String>> reloads;
  late KvStoreExportSection section;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('kv_plugin_storage');
    Hive.init(dir.path);
    pluginStore = HiveStoreService(defaultNamespace: 'plugins');
    await pluginStore.initialize();
    restStore = HiveStoreService(defaultNamespace: 'kvStore');
    await restStore.initialize();
    reloads = [];
    await pluginStore.set(namespace: 'skale.reaplugin', key: 'k', value: 'v');
    await restStore.set(namespace: 'beanie', key: 'theme', value: 'dark');
    section = KvStoreExportSection(
      store: restStore,
      pluginStore: pluginStore,
      pluginIds: () => const ['skale.reaplugin', 'idle.reaplugin'],
      onPluginStorageImported: (ids) async => reloads.add(ids),
    );
  });

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  Future<Map<String, dynamic>> export({required bool include}) async {
    final sink = CapturingJsonSink();
    await section.exportJson(sink, includePluginStorage: include);
    return (jsonDecode(sink.json) as Map)['namespaces'] as Map<String, dynamic>;
  }

  test('an unauthorized export never contains plugin storage', () async {
    await restStore.get(namespace: 'skale.reaplugin', key: 'k');
    await restStore.get(namespace: 'SKALE.reaplugin', key: 'k');

    final namespaces = await export(include: false);

    expect(namespaces.keys, unorderedEquals(['kvStore', 'beanie']));
  });

  test(
    'an authorized export includes every installed plugin namespace',
    () async {
      final namespaces = await export(include: true);

      expect(namespaces['skale.reaplugin'], {'k': 'v'});
      expect(namespaces['beanie'], {'theme': 'dark'});
      expect(namespaces.containsKey('idle.reaplugin'), isFalse);
    },
  );

  SectionJsonInput archive() => StringJsonInput(
    jsonEncode({
      'namespaces': {
        'skale.reaplugin': {'k': 'restored'},
        'Skale.ReaPlugin': {'other': 'x'},
        'beanie': {'theme': 'light'},
      },
    }),
  );

  test('an unauthorized import skips plugin storage with a warning', () async {
    final result = await section.importJson(
      archive(),
      ConflictStrategy.overwrite,
    );

    expect(await pluginStore.get(namespace: 'skale.reaplugin', key: 'k'), 'v');
    expect(
      await pluginStore.get(namespace: 'skale.reaplugin', key: 'other'),
      isNull,
    );
    expect(await restStore.get(namespace: 'beanie', key: 'theme'), 'light');
    expect(result.imported, 1);
    expect(result.skipped, 2);
    expect(result.warnings, [contains('skale.reaplugin')]);
    expect(reloads, isEmpty);
  });

  test(
    'an authorized import restores plugin storage and reloads the plugin',
    () async {
      final result = await section.importJson(
        archive(),
        ConflictStrategy.overwrite,
        includePluginStorage: true,
      );

      expect(
        await pluginStore.get(namespace: 'skale.reaplugin', key: 'k'),
        'restored',
      );
      expect(result.imported, 3);
      expect(reloads, [
        {'skale.reaplugin'},
      ]);
    },
  );

  group('through the data routes', () {
    late Handler handler;
    late ProxyTokenService tokens;

    setUp(() {
      tokens = ProxyTokenService();
      final app = Router().plus;
      DataExportHandler(sections: [section]).addRoutes(app);
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

    Future<Map<String, dynamic>> exportedNamespaces({String? bearer}) async {
      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/data/export'),
          headers: {
            'authorization': ?(bearer == null ? null : 'Bearer $bearer'),
          },
        ),
      );
      expect(response.statusCode, 200);
      final bytes = await response.read().expand((chunk) => chunk).toList();
      final store = ZipDecoder()
          .decodeBytes(bytes)
          .files
          .singleWhere((file) => file.name == 'store.json');
      final json = jsonDecode(utf8.decode(store.content as List<int>));
      return (json as Map)['namespaces'] as Map<String, dynamic>;
    }

    test('a tokenless export leaves plugin storage out', () async {
      expect(
        (await exportedNamespaces()).containsKey('skale.reaplugin'),
        isFalse,
      );
    });

    test('the native app token exports plugin storage', () async {
      final namespaces = await exportedNamespaces(bearer: tokens.nativeToken);
      expect(namespaces['skale.reaplugin'], {'k': 'v'});
    });

    Future<Response> importArchive({String? bearer}) async {
      final store = utf8.encode(
        jsonEncode({
          'namespaces': {
            'skale.reaplugin': {'k': 'restored'},
          },
        }),
      );
      final zip = ZipEncoder().encode(
        Archive()
          ..addFile(
            ArchiveFile.string(
              'metadata.json',
              jsonEncode({'formatVersion': 1}),
            ),
          )
          ..addFile(ArchiveFile('store.json', store.length, store)),
      );
      return handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/data/import?onConflict=overwrite'),
          headers: {
            'content-type': 'application/zip',
            'authorization': ?(bearer == null ? null : 'Bearer $bearer'),
          },
          body: zip,
        ),
      );
    }

    test('a tokenless import does not touch plugin storage', () async {
      final response = await importArchive();
      expect(response.statusCode, 200, reason: await response.readAsString());
      expect(
        await pluginStore.get(namespace: 'skale.reaplugin', key: 'k'),
        'v',
      );
      expect(reloads, isEmpty);
    });

    test('the native app token restores plugin storage', () async {
      final response = await importArchive(bearer: tokens.nativeToken);
      expect(response.statusCode, 200, reason: await response.readAsString());
      expect(
        await pluginStore.get(namespace: 'skale.reaplugin', key: 'k'),
        'restored',
      );
      expect(reloads, [
        {'skale.reaplugin'},
      ]);
    });
  });
}
