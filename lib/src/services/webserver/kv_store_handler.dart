part of '../webserver_service.dart';

final class KvStoreHandler {
  KvStoreHandler({KeyValueStoreService? store, this._isPluginNamespace})
    : store = store ?? HiveStoreService(defaultNamespace: "kvStore");

  final KeyValueStoreService store;
  final bool Function(String namespace)? _isPluginNamespace;

  Response? _pluginNamespaceRefusal(Request req, String? namespace) {
    if (namespace == null) return null;
    if (_isPluginNamespace?.call(namespace) != true) return null;
    if (holdsExtensionManagementCredential(req)) return null;
    return jsonForbidden({
      'error':
          'Namespace $namespace belongs to an installed plugin and is only '
          'available to that plugin or an extensions:manage token',
    });
  }

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/store/<namespace>', (Request req) async {
      final namespace = req.params['namespace'];
      if (namespace == null) {
        return jsonBadRequest({'error': 'Missing namespace'});
      }
      final refusal = _pluginNamespaceRefusal(req, namespace);
      if (refusal != null) return refusal;
      if (req.url.queryParameters['full'] == '1') {
        return jsonOkConditional(req, await store.getAll(namespace: namespace));
      }
      return jsonOk(await store.keys(namespace: namespace));
    });

    app.get('/api/v1/store/<namespace>/<key>', (Request req) async {
      final namespace = req.params['namespace'];
      final key = req.params['key'];
      if (namespace == null || key == null) {
        return jsonBadRequest({'error': 'Missing namespace or key'});
      }
      final refusal = _pluginNamespaceRefusal(req, namespace);
      if (refusal != null) return refusal;
      return jsonOk(await store.get(namespace: namespace, key: key));
    });

    app.delete('/api/v1/store/<namespace>/<key>', (Request req) async {
      final namespace = req.params['namespace'];
      final key = req.params['key'];
      if (namespace == null || key == null) {
        return jsonBadRequest({'error': 'Missing namespace or key'});
      }
      final refusal = _pluginNamespaceRefusal(req, namespace);
      if (refusal != null) return refusal;
      await store.delete(key: key, namespace: namespace);
      return jsonOk({});
    });

    app.post('/api/v1/store/<namespace>/<key>', (Request req) async {
      final namespace = req.params['namespace'];
      final key = req.params['key'];
      final refusal = _pluginNamespaceRefusal(req, namespace);
      if (refusal != null) return refusal;
      final value = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
        timeout: largeRequestBodyTimeout,
      );
      final maybeJson = jsonDecode(value);
      if (namespace == null || key == null) {
        return jsonBadRequest({'error': 'Missing namespace or key'});
      }
      await store.set(
        key: key,
        value: maybeJson ?? value,
        namespace: namespace,
      );
      return jsonOk({});
    });
  }
}
