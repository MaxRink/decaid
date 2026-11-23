import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../plugins/plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PluginLoaderService service;
  late Handler handler;

  Map<String, dynamic> manifestJson(String id, {Object? surfaces}) => {
    'id': id,
    'author': 'Test',
    'name': 'Test plugin',
    'description': 'Test plugin',
    'version': '1.0.0',
    'apiVersion': 1,
    'permissions': ['api', 'notifications'],
    'settings': <String, dynamic>{},
    'api': [
      {'id': 'setup', 'type': 'http', 'data': <String, dynamic>{}},
    ],
    'surfaces': ?surfaces,
  };

  Future<void> install(
    String id, {
    Object? surfaces,
    String onLoad = '',
  }) async {
    final dir = Directory('${tempDir.path}/source_$id')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json')
        .writeAsStringSync(jsonEncode(manifestJson(id, surfaces: surfaces)));
    File('${dir.path}/plugin.js').writeAsStringSync('''
function createPlugin(host) {
  return { id: "$id", onLoad() { $onLoad } };
}
''');
    await service.addPlugin(dir.path);
  }

  Future<Map<String, dynamic>> listed(String id) async {
    final res = await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/plugins')),
    );
    expect(res.statusCode, 200);
    final list = jsonDecode(await res.readAsString()) as List;
    return list.cast<Map<String, dynamic>>().firstWhere((p) => p['id'] == id);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('plugins_handler_surfaces');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempDir.path,
        );
    service = PluginLoaderService(kvStore: FakeKeyValueStoreService());
    await service.initialize();
    final app = Router().plus;
    PluginsHandler(
      pluginManager: service.pluginManager,
      pluginService: service,
    ).addRoutes(app);
    handler = app.call;
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

  test('lists declared plugin surfaces with same-origin hrefs', () async {
    await install(
      'surfaces.reaplugin',
      surfaces: [
        {'id': 'setup', 'role': 'setup', 'endpoint': 'setup', 'label': 'Go'},
      ],
    );

    final plugin = await listed('surfaces.reaplugin');

    expect(plugin['surfaces'], [
      {
        'id': 'setup',
        'role': 'setup',
        'label': 'Go',
        'href': '/api/v1/plugins/surfaces.reaplugin/setup?ui=1&surface=setup',
      },
    ]);
  });

  test('omits surfaces when none are declared', () async {
    await install('plain.reaplugin');

    final plugin = await listed('plain.reaplugin');

    expect(plugin.containsKey('surfaces'), isFalse);
  });
}
