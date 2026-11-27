import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeKeyValueStoreService implements KeyValueStoreService {
  final Map<String, Map<String, Object>> _store = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<void> set({
    String namespace = 'default',
    required String key,
    required Object value,
  }) async {
    _store.putIfAbsent(namespace, () => {})[key] = value;
  }

  @override
  Future<bool> delete({
    String namespace = 'default',
    required String key,
  }) async {
    return _store[namespace]?.remove(key) != null;
  }

  @override
  Future<Object?> get({
    String namespace = 'default',
    required String key,
  }) async {
    return _store[namespace]?[key];
  }

  @override
  Future<List<String>> keys({String namespace = 'default'}) async {
    return _store[namespace]?.keys.toList() ?? [];
  }

  @override
  List<String> get namespaces => _store.keys.toList();

  @override
  Future<Map<String, Object>> getAll({String namespace = 'default'}) async {
    return Map<String, Object>.from(_store[namespace] ?? {});
  }
}

/// Ids of every plugin shipped in `assets/plugins/`.
///
/// Read from the asset manifest so the list follows the bundle instead of
/// drifting behind it.
Future<List<String>> bundledPluginIds() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final ids = <String>[];
  for (final asset in manifest.listAssets()) {
    if (!asset.startsWith('assets/plugins/') ||
        !asset.endsWith('/manifest.json')) {
      continue;
    }
    final json = jsonDecode(await rootBundle.loadString(asset));
    ids.add((json as Map<String, dynamic>)['id'] as String);
  }
  return ids;
}

/// Keeps the shipped plugins out of a test's PluginLoaderService.
///
/// `initialize` copies and auto-loads the whole bundled set, and a few of those
/// plugins act on load: Mahlkönig E64 publishes its "needs setup" notice and
/// Skale registers a BLE driver. A test that asserts on its own notification
/// centre or BLE registry must silence them first, exactly as a real profile
/// does when the user turns auto-load off.
///
/// Call after `SharedPreferences.setMockInitialValues` and before
/// `initialize`: the loader only defaults a bundled plugin to auto-load when
/// the preference is absent.
Future<void> disableBundledPluginAutoLoad() async {
  final preferences = await SharedPreferences.getInstance();
  for (final id in await bundledPluginIds()) {
    await preferences.setBool('plugin.autoload.$id', false);
  }
}

PluginManifest testManifest(
  String id, {
  Set<PluginPermissions> permissions = const {
    PluginPermissions.log,
    PluginPermissions.api,
    PluginPermissions.emit,
    PluginPermissions.pluginStorage,
  },
  List<PluginDriverDeclaration> drivers = const [],
  PluginApi? api,
  Map<String, dynamic> settings = const {},
}) {
  return PluginManifest(
    id: id,
    name: id,
    author: 'Test',
    description: 'Test',
    version: '1.0.0',
    apiVersion: 1,
    permissions: permissions,
    drivers: drivers,
    settings: settings,
    api: api ?? PluginApi(endpoints: []),
  );
}

final _defaultEngineIsQuickJs =
    Platform.isAndroid || Platform.isLinux || Platform.isWindows;

bool get defaultEngineIsQuickJs => _defaultEngineIsQuickJs;

/// The engines plugin realm tests run on: the platform default, plus QuickJS
/// through the bridge library at `LIBQUICKJSC_PATH` when the default is not
/// already QuickJS.
Map<String, JavascriptRuntime Function()> pluginTestEngines() {
  final quickJsLibrary = Platform.environment['LIBQUICKJSC_PATH'];
  return {
    _defaultEngineIsQuickJs
        ? 'QuickJS (default engine)'
        : 'default engine': () =>
        getJavascriptRuntime(xhr: false),
    if (!_defaultEngineIsQuickJs && quickJsLibrary != null)
      'QuickJS ($quickJsLibrary)': () =>
          QuickJsRuntime2()..enableHandlePromises(),
  };
}
