import 'dart:convert';

import 'package:reaprime/src/services/storage/kv_store_service.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

class KvStoreExportSection implements DataExportSection {
  final KeyValueStoreService _store;
  final DataTransferLimits _limits;
  final KeyValueStoreService? _pluginStore;
  final Iterable<String> Function() _pluginIds;
  final Future<void> Function(Set<String> pluginIds)? _onPluginStorageImported;

  KvStoreExportSection({
    required this._store,
    this._limits = const DataTransferLimits(),
    this._pluginStore,
    Iterable<String> Function()? pluginIds,
    this._onPluginStorageImported,
  }) : _pluginIds = pluginIds ?? _noPlugins;

  static Iterable<String> _noPlugins() => const [];

  String? _pluginIdFor(String namespace) {
    final lower = namespace.toLowerCase();
    for (final id in _pluginIds()) {
      if (id.toLowerCase() == lower) return id;
    }
    return null;
  }

  @override
  String get filename => 'store.json';

  @override
  Future<void> exportJson(
    JsonSink output, {
    bool includePluginStorage = false,
  }) async {
    final pluginStore = _pluginStore;
    final sources = <(String, KeyValueStoreService)>[
      for (final namespace in _store.namespaces)
        if (_pluginIdFor(namespace) == null) (namespace, _store),
      if (includePluginStorage && pluginStore != null)
        for (final id in _pluginIds())
          if ((await pluginStore.keys(namespace: id)).isNotEmpty)
            (id, pluginStore),
    ];
    output.writeRaw('{"namespaces":{');
    var firstNamespace = true;
    for (final (namespace, store) in sources) {
      output.writeRaw(firstNamespace ? '' : ',');
      _writeKey(output, namespace);
      output.writeRaw(':{');
      var firstKey = true;
      final keys = await store.keys(namespace: namespace);
      for (final key in keys) {
        final value = await store.get(namespace: namespace, key: key);
        if (value == null) continue;
        final encodedValue = jsonEncode(value);
        final parser = IncrementalJsonParser(
          eventDepth: _limits.maxNestingDepth + 1,
          maxValueBytes: _limits.maxRecordBytes,
          maxKeyBytes: _limits.maxKeyBytes,
          maxNestingDepth: _limits.maxNestingDepth,
        );
        parser.feed('{"":{"":{"":$encodedValue}}}');
        parser.finish();
        output.writeRaw(firstKey ? '' : ',');
        _writeKey(output, key);
        output.writeRaw(':');
        output.writeRaw(encodedValue);
        firstKey = false;
      }
      output.writeRaw('}');
      firstNamespace = false;
    }
    output.writeRaw('}}');
  }

  void _writeKey(JsonSink output, String key) {
    final encoded = jsonEncode(key);
    final byteLength = encoded.runes.fold(
      0,
      (length, rune) => length + utf8CodePointByteLength(rune),
    );
    if (byteLength > _limits.maxKeyBytes) {
      throw StateError('Encoded KV key exceeds ${_limits.maxKeyBytes} bytes.');
    }
    output.writeRaw(encoded);
  }

  @override
  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy, {
    bool includePluginStorage = false,
  }) async {
    await validateJson(input);

    int imported = 0;
    int skipped = 0;
    final errors = SectionImportErrors();
    final skippedPlugins = <String>{};
    final restoredPlugins = <String>{};

    await for (final event in input.valuesAtDepth(3)) {
      if (event.keys.length != 3 || event.keys[0] != 'namespaces') {
        errors.add('Unexpected store entry structure in store.json');
        continue;
      }
      final namespace = event.keys[1];
      final key = event.keys[2];
      final pluginId = _pluginIdFor(namespace);
      if (pluginId != null && !includePluginStorage) {
        skippedPlugins.add(pluginId);
        skipped++;
        continue;
      }
      final store = pluginId == null ? _store : (_pluginStore ?? _store);
      final target = pluginId ?? namespace;
      try {
        final existing = await store.get(namespace: target, key: key);
        if (existing != null && strategy == ConflictStrategy.skip) {
          skipped++;
        } else {
          await store.set(namespace: target, key: key, value: event.value!);
          imported++;
          if (pluginId != null) restoredPlugins.add(pluginId);
        }
      } catch (e) {
        errors.add('Failed to import $namespace/$key: $e');
      }
    }

    if (restoredPlugins.isNotEmpty) {
      await _onPluginStorageImported?.call(restoredPlugins);
    }
    return SectionImportResult(
      imported: imported,
      skipped: skipped,
      errors: errors.toList(),
      warnings: [
        for (final id in skippedPlugins)
          'Plugin storage for $id was not imported: restoring plugin storage '
              'needs the app itself or an extensions:manage token',
      ],
    );
  }

  Future<void> validateJson(SectionJsonInput input) async {
    if (await input.open() != JsonContainerKind.object) {
      throw const JsonStreamFormatException(
        'store.json must contain a root object.',
      );
    }

    var sawNamespaces = false;
    String? shapeError;
    await for (final _ in input.valuesAtDepth(
      3,
      onValueStart: (depth, keys, containerKind) {
        if (depth == 1 && keys.length == 1 && keys.first == 'namespaces') {
          sawNamespaces = true;
          if (containerKind != JsonContainerKind.object) {
            shapeError = '"namespaces" must be an object.';
          }
        }
        if (depth == 2 &&
            keys.length == 2 &&
            keys.first == 'namespaces' &&
            containerKind != JsonContainerKind.object) {
          shapeError = 'Every namespace value must be an object.';
        }
      },
    )) {}

    if (!sawNamespaces) {
      throw const JsonStreamFormatException(
        'store.json must contain "namespaces".',
      );
    }
    if (shapeError != null) throw JsonStreamFormatException(shapeError!);
  }
}
