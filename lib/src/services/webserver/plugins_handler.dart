part of '../webserver_service.dart';

final class PluginsHandler {
  final PluginManager pluginManager;
  final PluginLoaderService pluginService;
  final PluginSourceService pluginSourceService;

  final Logger _log = Logger("PluginsHandler");

  final Random _random = Random();

  PluginsHandler({
    required this.pluginManager,
    required PluginLoaderService pluginService,
    PluginSourceService? pluginSourceService,
  }) : pluginService = pluginService,
       pluginSourceService =
           pluginSourceService ?? PluginSourceService(pluginService);

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/plugins', (Request req) async {
      final list = <Map<String, dynamic>>[];
      for (final manifest in pluginService.availablePlugins) {
        final json = manifest.toJson();
        json['loaded'] = pluginService.isPluginLoaded(manifest.id);
        json['autoLoad'] = await pluginService.shouldAutoLoad(manifest.id);
        final source = pluginSourceService.sourceFor(manifest.id);
        json['source'] = source == null ? null : _sourceJson(source);
        json['pendingUpdate'] = source?.pendingUpdate?.toJson();
        json['machineControl'] = pluginService.machineControlGranted(
          manifest.id,
        );
        if (manifest.surfaces.isNotEmpty) {
          json['surfaces'] = pluginSurfaceLinks(manifest);
        }
        final setupReason = pluginSetupReason(
          manifest,
          pluginManager.notifications.value,
        );
        json['needsSetup'] = setupReason != null;
        if (setupReason != null) json['setupReason'] = setupReason;
        list.add(json);
      }
      return jsonOk(list);
    });

    app.post('/api/v1/plugins/install', (Request request) async {
      return jsonNotImplemented({
        'error':
            'Plugin install from an arbitrary URL is not supported. Use '
            '/api/v1/plugins/install/github-release or '
            '/api/v1/plugins/install/github-branch',
      });
    });

    app.post(
      '/api/v1/plugins/install/github-release',
      _handleInstallFromGitHubRelease,
    );

    app.post(
      '/api/v1/plugins/install/github-branch',
      _handleInstallFromGitHubBranch,
    );

    app.post('/api/v1/plugins/update', (Request request) async {
      try {
        final report = await pluginSourceService.checkForPluginUpdates();
        return jsonOk({
          'message': 'Plugin update check complete',
          'results': report.results.map((r) => r.toJson()).toList(),
        });
      } catch (e, st) {
        _log.warning('Plugin update check failed', e, st);
        return jsonError({
          'error': remoteErrorMessage(e, action: 'check for plugin updates'),
        });
      }
    });

    app.get('/api/v1/plugins/<id>/settings', _handlePluginSettingsGet);
    app.post('/api/v1/plugins/<id>/settings', _handlePluginSettingsPost);

    app.put('/api/v1/plugins/<id>/source', _handlePluginSourceWrite);

    app.put('/api/v1/plugins/<id>/machine-control', _handleMachineControlGrant);

    app.post('/api/v1/plugins/<id>/enable', (Request request, String id) async {
      try {
        if (pluginService.getPluginManifest(id) == null) {
          return jsonNotFound({'error': 'Plugin not found: $id'});
        }
        await pluginService.enablePlugin(id);
        return jsonOk({'message': 'Plugin enabled', 'id': id});
      } catch (e) {
        return jsonError({'error': 'Failed to enable plugin: $e'});
      }
    });

    app.post('/api/v1/plugins/<id>/disable', (
      Request request,
      String id,
    ) async {
      try {
        if (pluginService.getPluginManifest(id) == null) {
          return jsonNotFound({'error': 'Plugin not found: $id'});
        }
        await pluginService.disablePlugin(id);
        return jsonOk({'message': 'Plugin disabled', 'id': id});
      } catch (e) {
        return jsonError({'error': 'Failed to disable plugin: $e'});
      }
    });

    app.post('/api/v1/plugins/<id>/update/approve', _handleApproveUpdate);

    app.delete('/api/v1/plugins/<id>', (Request request, String id) async {
      try {
        if (pluginService.getPluginManifest(id) == null) {
          return jsonNotFound({'error': 'Plugin not found: $id'});
        }
        await pluginService.removePlugin(id);
        return jsonOk({'message': 'Plugin removed', 'id': id});
      } catch (e) {
        return jsonError({'error': 'Failed to remove plugin: $e'});
      }
    });

    app.get('/ws/v1/plugins/<id>/<endpoint>', _handlePluginSocketEndpoint);
    app.all('/api/v1/plugins/<id>/<endpoint>', _handlePluginApiEndpoint);
  }

  Future<Response> _handleApproveUpdate(Request request, String id) async {
    if (pluginService.getPluginManifest(id) == null) {
      return jsonNotFound({'error': 'Plugin not found: $id'});
    }
    final _ReplacementApproval approval;
    try {
      final body = await readBoundedRequestBodyString(
        request,
        maxBytes: smallRequestBodyBytes,
        timeout: smallRequestBodyTimeout,
      );
      approval = _ReplacementApproval(
        request,
        body.trim().isEmpty ? const {} : _jsonObject(body),
        acceptsPermissions: false,
      );
    } on RequestBodyReadException {
      rethrow;
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.message});
    }
    final refusal =
        approval.refusal ?? await _unattendedApprovalRefusal(id, approval);
    if (refusal != null) return refusal;

    try {
      final heldSecureSettings = await pluginService.hasStoredSecureSettings(
        id,
      );
      final manifest = await pluginSourceService.approvePendingUpdate(
        id,
        keepSecureSettings: approval.keepSecureSettings,
      );
      return jsonOk({
        'message': 'Plugin updated',
        'id': id,
        'version': manifest.version,
        'loaded': pluginService.isPluginLoaded(id),
        'secureSettingsCleared':
            heldSecureSettings &&
            !await pluginService.hasStoredSecureSettings(id),
      });
    } on PluginApprovalRequiredException catch (e) {
      return jsonConflict({'error': e.message});
    } on PluginReplacementApprovalRequiredException catch (e) {
      return approval.conflict(e);
    } on FormatException catch (e, st) {
      _log.warning('Invalid plugin update', e, st);
      return jsonBadRequest({
        'error': remoteErrorMessage(e, action: 'update the plugin'),
      });
    } catch (e, st) {
      _log.warning('Failed to approve update of plugin $id', e, st);
      return jsonError({
        'error': remoteErrorMessage(e, action: 'update the plugin'),
      });
    }
  }

  Future<Response?> _unattendedApprovalRefusal(
    String id,
    _ReplacementApproval approval,
  ) async {
    if (approval.credential) return null;
    final pending = pluginSourceService.sourceFor(id)?.pendingUpdate;
    if (pending == null) return null;
    if (pending.addedPermissions.isEmpty &&
        !await pluginService.hasStoredSecureSettings(id)) {
      return null;
    }
    return jsonForbidden({
      'error':
          'Approving an update that adds permissions or reaches stored '
          'secure settings needs the native Plugins screen or an '
          'extensions:manage credential',
    });
  }

  Map<String, dynamic> _sourceJson(PluginSource source) {
    final json = source.toJson();
    json.remove('pendingUpdate');
    return json;
  }

  Future<Response> _handleInstallFromGitHubRelease(Request request) async {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(
        await readBoundedRequestBodyString(
          request,
          maxBytes: smallRequestBodyBytes,
          timeout: smallRequestBodyTimeout,
        ),
      ) as Map<String, dynamic>;
    } on RequestBodyReadException {
      rethrow;
    } catch (e) {
      return jsonBadRequest({'error': 'Invalid JSON body: $e'});
    }

    final repo = json['repo'];
    if (repo is! String || repo.isEmpty) {
      return jsonBadRequest({'error': 'repo is required (owner/repo)'});
    }
    final assetName = json['assetName'];
    if (assetName != null && assetName is! String) {
      return jsonBadRequest({'error': 'assetName must be a string'});
    }
    final includePrerelease = json['includePrerelease'];
    if (includePrerelease != null && includePrerelease is! bool) {
      return jsonBadRequest({'error': 'includePrerelease must be a boolean'});
    }

    return _install(
      request,
      json,
      (approval) => pluginSourceService.installFromGitHubRelease(
        repo,
        assetName: assetName as String?,
        includePrerelease: (includePrerelease as bool?) ?? false,
        approveReplacement: approval.decide,
      ),
    );
  }

  Future<Response> _handleInstallFromGitHubBranch(Request request) async {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(
        await readBoundedRequestBodyString(
          request,
          maxBytes: smallRequestBodyBytes,
          timeout: smallRequestBodyTimeout,
        ),
      ) as Map<String, dynamic>;
    } on RequestBodyReadException {
      rethrow;
    } catch (e) {
      return jsonBadRequest({'error': 'Invalid JSON body: $e'});
    }

    final repo = json['repo'];
    if (repo is! String || repo.isEmpty) {
      return jsonBadRequest({'error': 'repo is required (owner/repo)'});
    }
    final branch = json['branch'];
    if (branch != null && branch is! String) {
      return jsonBadRequest({'error': 'branch must be a string'});
    }

    return _install(
      request,
      json,
      (approval) => pluginSourceService.installFromGitHubBranch(
        repo,
        branch: (branch as String?) ?? 'main',
        approveReplacement: approval.decide,
      ),
    );
  }

  Future<Response> _install(
    Request request,
    Map<String, dynamic> json,
    Future<PluginManifest> Function(_ReplacementApproval approval) install,
  ) async {
    final _ReplacementApproval approval;
    try {
      approval = _ReplacementApproval(request, json);
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.message});
    }
    final refusal = approval.refusal;
    if (refusal != null) return refusal;

    try {
      final manifest = await install(approval);
      return jsonOk({
        'message': 'Plugin installed',
        'id': manifest.id,
        'version': manifest.version,
        'loaded': pluginService.isPluginLoaded(manifest.id),
        'secureSettingsCleared': approval.clearedSecureSettings,
      });
    } on PluginDowngradeException catch (e) {
      return jsonConflict({'error': e.message});
    } on PluginReplacementApprovalRequiredException catch (e) {
      return approval.conflict(e);
    } on FormatException catch (e, st) {
      _log.warning('Invalid plugin installation', e, st);
      return jsonBadRequest({
        'error': remoteErrorMessage(e, action: 'install the plugin'),
      });
    } catch (e, st) {
      _log.warning('Plugin installation failed', e, st);
      return jsonError({
        'error': remoteErrorMessage(e, action: 'install the plugin'),
      });
    }
  }

  Future<Response> _handleMachineControlGrant(
    Request request,
    String id,
  ) async {
    final Object? json;
    try {
      json = jsonDecode(
        await readBoundedRequestBodyString(
          request,
          maxBytes: smallRequestBodyBytes,
          timeout: smallRequestBodyTimeout,
        ),
      );
    } on RequestBodyReadException {
      rethrow;
    } catch (e) {
      return jsonBadRequest({'error': 'Invalid JSON body: $e'});
    }
    final granted = json is Map ? json['granted'] : null;
    if (granted is! bool) {
      return jsonBadRequest({'error': 'granted must be a boolean'});
    }
    if (pluginService.getPluginManifest(id) == null) {
      return jsonNotFound({'error': 'Plugin not found: $id'});
    }
    await pluginService.setMachineControlGrant(id, granted);
    return jsonOk({'id': id, 'machineControl': granted});
  }

  Future<Response> _handlePluginSourceWrite(Request request, String id) async {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(
        await readBoundedRequestBodyString(
          request,
          maxBytes: largeRequestBodyBytes,
          timeout: largeRequestBodyTimeout,
        ),
      ) as Map<String, dynamic>;
    } on RequestBodyReadException {
      rethrow;
    } catch (e) {
      return jsonBadRequest({'error': 'Invalid JSON body: $e'});
    }

    final manifestJson = json['manifest'];
    final pluginJs = json['plugin'];
    if (manifestJson is! Map<String, dynamic>) {
      return jsonBadRequest({'error': 'manifest object is required'});
    }
    if (pluginJs is! String || pluginJs.isEmpty) {
      return jsonBadRequest({'error': 'plugin source is required'});
    }
    final _ReplacementApproval approval;
    try {
      approval = _ReplacementApproval(request, json);
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.message});
    }
    final refusal = approval.refusal;
    if (refusal != null) return refusal;

    try {
      final manifest = await pluginService.updatePluginSource(
        id,
        manifestJson: manifestJson,
        pluginJs: pluginJs,
        approveReplacement: approval.decide,
      );
      return jsonOk({
        'message': 'Plugin source updated',
        'id': id,
        'version': manifest.version,
        'loaded': pluginService.isPluginLoaded(id),
        'secureSettingsCleared': approval.clearedSecureSettings,
      });
    } on PluginDowngradeException catch (e) {
      return jsonConflict({'error': e.message});
    } on PluginReplacementApprovalRequiredException catch (e) {
      return approval.conflict(e);
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.message});
    } catch (e) {
      _log.warning('Failed to update source of plugin $id', e);
      return jsonError({
        'error': 'Failed to update plugin source: $e',
        'id': id,
        'loaded': pluginService.isPluginLoaded(id),
      });
    }
  }

  Future<Response> _handlePluginSocketEndpoint(Request req) async {
    _log.info("handling $req");
    final id = decodeOpaquePathComponent(req.params['id']!);
    final endpoint = decodeOpaquePathComponent(req.params['endpoint']!);
    final manifest = pluginManager.loadedPlugins
        .firstWhereOrNull((e) => e.pluginId == id)
        ?.manifest;
    if (manifest == null) {
      return jsonNotFound({'error': 'plugin with $id not loaded'});
    }
    final apiEndpoint = manifest.api?.endpoints.firstWhereOrNull(
      (e) => e.id == endpoint,
    );
    if (apiEndpoint == null) {
      return jsonNotFound({'error': 'endpoint $endpoint not available'});
    }
    if (apiEndpoint.type != ApiEndpointType.websocket) {
      return jsonBadRequest({
        'error': 'endpoint $endpoint is not a websocket type',
      });
    }

    return admittedWebSocketHandler((
      WebSocketChannel socket,
      String? protocol,
    ) {
      StreamSubscription<Map<String, dynamic>>? sub;
      sub = pluginManager.emitStream
          .where((e) {
            return e['pluginId'] == id && e['event'] == endpoint;
          })
          .listen(
            (data) {
              socket.sink.add(jsonEncode(data['payload']));
            },
            onDone: () {
              socket.sink.close();
              sub?.cancel();
            },
            onError: (e) {
              _log.warning("plugin $id listen errored out:", e);
              sub?.cancel();
            },
          );
      socket.stream.listen(
        (msg) {},
        onDone: () {
          sub?.cancel();
        },
        onError: (e, _) {
          sub?.cancel();
          _log.warning("socket connection error: ", e);
        },
      );
    })(req);
  }

  Future<Response> _handlePluginApiEndpoint(Request req) async {
    _log.info("handling ${req.toString()}");

    final rawId = req.params['id'];
    final rawEndpoint = req.params['endpoint'];

    if (rawId == null || rawEndpoint == null) {
      return jsonBadRequest({'error': 'id and endpoint required'});
    }
    final id = decodeOpaquePathComponent(rawId);
    final endpoint = decodeOpaquePathComponent(rawEndpoint);

    final manifest = pluginManager.loadedPlugins
        .firstWhereOrNull((e) => e.pluginId == id)
        ?.manifest;

    if (manifest == null) {
      return jsonNotFound({'error': 'plugin with $id not loaded'});
    }
    if (!manifest.permissions.contains(PluginPermissions.api)) {
      _log.warning('Plugin $id denied permission api');
      return jsonForbidden({
        'error':
            'PluginPermissionError: Plugin $id requires manifest permission api',
      });
    }

    final apiEndpoint = manifest.api?.endpoints.firstWhereOrNull(
      (e) => e.id == endpoint,
    );

    if (apiEndpoint == null) {
      return jsonNotFound({'error': 'endpoint $endpoint not available'});
    }

    if (apiEndpoint.type != ApiEndpointType.http) {
      return jsonBadRequest({'error': 'endpoint $endpoint is not a http type'});
    }

    final method = req.method;
    final headers = <String, String>{};
    req.headers.forEach((name, values) {
      headers[name] = values;
    });

    final body = await readBoundedRequestBodyString(
      req,
      maxBytes: largeRequestBodyBytes,
    );

    final requestId =
        '${id}_${endpoint}_${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(100000)}';

    try {
      final requestData = {
        'requestId': requestId,
        'endpoint': endpoint,
        'method': method,
        'headers': headers,
        'body': body.isNotEmpty ? jsonDecode(body) : null,
        'query': req.url.queryParameters,
      };

      final responseFuture = pluginManager.registerPendingHttp(id, requestId);

      pluginManager.dispatchEvent(id, 'httpRequest', requestData);

      final response = await responseFuture;

      final status = response['status'] as int? ?? 200;
      final responseHeaders =
          (response['headers'] as Map<String, dynamic>? ?? {}).map(
            (k, v) => MapEntry(k, v.toString()),
          );
      final responseBody = response['body'];

      return Response(status, body: responseBody, headers: responseHeaders);
    } on PluginHttpError catch (e) {
      _log.warning("Plugin $id HTTP request failed", e);
      return jsonError({'error': e.message});
    } catch (e) {
      _log.warning("Error handling HTTP request for plugin $id", e);
      return jsonError({'error': 'Error processing request: ${e.toString()}'});
    }
  }

  Future<Response> _extractPluginId(
    Request req,
    Future<Response> Function(Request, String) call,
  ) async {
    final id = req.params['id'];
    if (id == null) {
      return jsonBadRequest({'error': 'plugin id is required'});
    }
    return call(req, id);
  }

  Future<Response> _handlePluginSettingsGet(Request req) async {
    return _extractPluginId(req, (r, id) async {
      final settings = await pluginService.pluginSettings(id);
      return jsonOk(settings);
    });
  }

  Future<Response> _handlePluginSettingsPost(Request req) async {
    return _extractPluginId(req, (req, id) async {
      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
        timeout: largeRequestBodyTimeout,
      );
      final json = await jsonDecode(body);
      try {
        await pluginService.savePluginSettings(id, json);
      } on PluginSettingsValidationException catch (e) {
        return jsonBadRequest({'error': e.message});
      }
      return jsonOk(await pluginService.pluginSettings(id));
    });
  }
}

Map<String, dynamic> _jsonObject(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Request body must be a JSON object');
  }
  return decoded;
}

final class _ReplacementApproval {
  _ReplacementApproval(
    Request request,
    Map<String, dynamic> json, {
    bool acceptsPermissions = true,
  }) : credential = holdsExtensionManagementCredential(request),
       approvedPermissions = acceptsPermissions
           ? _permissionNames(json['approvePermissions'])
           : const {},
       keepSecureSettings = _flag(json['keepSecureSettings']);

  final bool credential;
  final Set<String> approvedPermissions;
  final bool keepSecureSettings;
  bool clearedSecureSettings = false;

  Response? get refusal {
    if (credential || (approvedPermissions.isEmpty && !keepSecureSettings)) {
      return null;
    }
    return jsonForbidden({
      'error':
          'approvePermissions and keepSecureSettings need an '
          'extensions:manage credential',
    });
  }

  PluginReplacementDecision decide(PluginReplacement replacement) {
    final decision = credential
        ? PluginReplacementDecision(
            approvedPermissions: approvedPermissions,
            keepSecureSettings: keepSecureSettings,
          )
        : PluginReplacementDecision.unattended;
    clearedSecureSettings =
        replacement.handsOverSecureSettings && !decision.keepSecureSettings;
    return decision;
  }

  Response conflict(PluginReplacementApprovalRequiredException e) =>
      jsonConflict({
        'error': e.message,
        'id': e.replacement.candidate.id,
        'addedPermissions': e.replacement.addedPermissions,
        'credentialRequired': !credential,
      });

  static Set<String> _permissionNames(Object? value) {
    if (value == null) return const {};
    if (value is! List || value.any((name) => name is! String)) {
      throw const FormatException(
        'approvePermissions must be an array of permission names',
      );
    }
    return value.cast<String>().toSet();
  }

  static bool _flag(Object? value) {
    if (value == null) return false;
    if (value is! bool) {
      throw const FormatException('keepSecureSettings must be a boolean');
    }
    return value;
  }
}
