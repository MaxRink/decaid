import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_js/flutter_js.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'plugin_manifest.dart';
import 'plugin_notifications.dart';
import '../notifications/native_notification.dart';
import '../notifications/notification_center.dart';
import 'plugin_ble_bridge.dart';
import 'plugin_ble_registry.dart';
import 'plugin_ble_service.dart';
import 'plugin_ble_session.dart';
import 'plugin_decent_proxy_bridge.dart';
import 'plugin_discovery.dart';
import 'plugin_device_service.dart';
import 'plugin_local_api_bridge.dart';
import 'plugin_log.dart';
import 'plugin_runtime.dart';
import 'plugin_tls_pin.dart';
import 'plugin_transport_service.dart';
import 'plugin_types.dart';
import '../services/storage/kv_store_service.dart';
import '../controllers/de1_controller.dart';
import '../controllers/workflow_controller.dart';
import '../models/device/de1_interface.dart';
import '../models/device/machine.dart';
import '../services/account/decent_proxy_service.dart';
import '../services/ble/ble_exception_mapper.dart';
import '../services/webserver/extension_management_auth.dart';

enum _PendingOpKind { fetch, pluginHttp, decentProxy, localApi, discovery }

/// Notice id the host uses to ask the user for a plugin's machine-control
/// grant.
const machineControlNoticeId = 'host.machine-control';

bool _noMachineControl(String _) => false;

enum PluginManagerLifecycle { active, disposing, disposed }

class _PendingOp {
  _PendingOp({
    required this.kind,
    required this.pluginId,
    required this.generation,
    required this.requestId,
  });

  final _PendingOpKind kind;
  final String pluginId;
  final int generation;
  final String requestId;

  Timer? timeout;
  HttpClientRequest? request;
  Completer<Map<String, dynamic>>? completer;

  String get key => _PendingOp.keyFor(kind, pluginId, generation, requestId);

  static String keyFor(
    _PendingOpKind kind,
    String pluginId,
    int generation,
    String requestId,
  ) => '${kind.name}:$pluginId:$generation:$requestId';
}

final class _PluginRealm {
  _PluginRealm({
    required this.pluginId,
    required this.generation,
    required this.bridgeToken,
    required this.js,
  });

  final String pluginId;
  final int generation;
  final String bridgeToken;
  final JavascriptRuntime js;

  JsEvalResult evaluate(String code) {
    final result = js.evaluate(code);
    while (js.executePendingJob() > 0) {}
    return result;
  }
}

class _PendingDeviceInvocation {
  _PendingDeviceInvocation({
    required this.pluginId,
    required this.generation,
    required this.registrationHandle,
    required this.operation,
    required this.completer,
    required this.timer,
  });

  final String pluginId;
  final int generation;
  final String registrationHandle;
  final PluginDeviceOperation operation;
  final Completer<Map<String, dynamic>> completer;
  final Timer? timer;
}

final class _PluginExtensionGrant implements ExtensionManagementGrant {
  final PluginManager _manager;
  final PluginRuntime _runtime;
  final int _generation;

  _PluginExtensionGrant(this._manager, this._runtime, this._generation);

  @override
  String get callerId => 'plugin:${_runtime.pluginId}';

  @override
  bool get isActive => _manager._holdsExtensionGrant(this);
}

class PluginHttpError implements Exception {
  final String message;

  const PluginHttpError(this.message);

  @override
  String toString() => message;
}

class PluginManager {
  final _log = Logger("PluginManager");

  final Map<String, PluginRuntime> _plugins = {};
  final Map<String, PluginLogLimiter> _pluginLogLimiters = {};
  final Map<String, PluginLogLimiter> _pluginErrorLimiters = {};
  final Map<String, List<String>> _pluginLogSecrets = {};
  final Map<String, _PluginRealm> _realms = {};
  final JavascriptRuntime Function() _createJsRuntime;
  @visibleForTesting
  final void Function(String pluginId, JavascriptRuntime js)? debugPrepareRealm;
  final KeyValueStoreService kvStore;
  final DecentProxyService? decentProxyService;
  final NotificationCenter notifications;
  late final PluginDecentProxyBridge _decentProxyBridge;
  late final PluginLocalApiBridge _localApiBridge;
  final Map<String, _PluginExtensionGrant> _extensionGrants = {};
  final Set<String> _loggedPermissionDenials = {};
  final Map<String, Set<PluginPermissions>> _closingPluginPermissions = {};

  final StreamController<Map<String, dynamic>> _emitController =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get emitStream => _emitController.stream;

  final Duration fetchTimeout;
  final int maxFetchResponseBytes;
  final Duration pluginHttpTimeout;

  /// Port of the host's own REST API, the target of the machine-control
  /// checks on plugin `fetch` and `host.transport`.
  final int hostApiPort;

  /// Whether the user allowed [pluginId] to write machine routes through
  /// `fetch`. Asked with the id of the realm the request came from.
  bool Function(String pluginId) machineControlGranted = _noMachineControl;
  final Duration decentProxyTimeout;
  final Duration localApiTimeout;
  final PluginMdnsBrowser mdnsBrowser;
  final Set<String> _discoveryBrowsing = {};
  final Duration transportCloseTimeout;
  final Duration deviceInvocationTimeout;
  final PluginDeviceService deviceService;
  late final PluginBleService bleService;

  De1Controller? _de1controller;
  StreamSubscription<De1Interface?>? _de1Subscription;
  StreamSubscription<MachineSnapshot>? _snapshotSubscription;
  Future<void> _attachmentQueue = Future.value();
  Future<void> _snapshotQueue = Future.value();
  int _attachmentGeneration = 0;
  int _snapshotGeneration = 0;
  WorkflowController? _workflowController;
  void Function()? _workflowListener;
  int? _lastWorkflowRevision;
  int _workflowAttachmentGeneration = 0;
  PluginManagerLifecycle _lifecycle = PluginManagerLifecycle.active;
  Future<void>? _disposeFuture;
  final Map<String, int> _retiringPluginGenerations = {};
  final Map<(String, int), Set<Future<void>>> _pluginStorageOperations = {};
  late final PluginTransportService _transportService;
  final Map<String, _PendingDeviceInvocation> _pendingDeviceInvocations = {};
  final Map<
    String,
    ({String pluginId, int generation, String registrationHandle})
  >
  _deviceConnectAttempts = {};
  final Map<(String, int, String), Set<String>> _timedOutDeviceConnects = {};
  int _deviceInvocationSequence = 0;

  final Set<(String, int)> _deviceDisconnectCleanup = {};
  final Map<String, Set<Future<void>>> _bleRegistrations = {};

  De1Controller? get de1Controller => _de1controller;
  PluginManagerLifecycle get lifecycle => _lifecycle;
  int get liveTransportCount => _transportService.liveTransportCount;
  int get deviceConnectAttemptCount => _deviceConnectAttempts.length;
  int get retiredDeviceConnectCount =>
      _transportService.retiredDeviceConnectCount;
  int get attachmentGeneration => _attachmentGeneration;
  int get activeSubscriptionCount =>
      (_de1Subscription == null ? 0 : 1) +
      (_snapshotSubscription == null ? 0 : 1);
  int get trackedPluginGenerationCount => _pluginGenerations.length;
  int get bridgeTokenCount => _realms.length;
  int get liveRealmCount => _realms.length;
  int? pluginGeneration(String pluginId) => _pluginGenerations[pluginId];

  PluginManager({
    required this.kvStore,
    NotificationCenter? notifications,
    this.decentProxyService,
    this.fetchTimeout = const Duration(seconds: 30),
    this.maxFetchResponseBytes = 10 * 1024 * 1024,
    this.pluginHttpTimeout = const Duration(seconds: 30),
    this.decentProxyTimeout = const Duration(seconds: 30),
    this.localApiTimeout = const Duration(seconds: 60),
    this.mdnsBrowser = browseMdnsWithBonsoir,
    JavascriptRuntime Function()? createJsRuntime,
    @visibleForTesting this.debugPrepareRealm,
    WebSocketConnector? connectWebSocket,
    SocketConnector? connectSocket,
    SecureSocketConnector? connectSecureSocket,
    this.transportCloseTimeout = const Duration(seconds: 5),
    this.hostApiPort = 8080,
    this.deviceInvocationTimeout = const Duration(seconds: 10),
    PluginDeviceService? deviceService,
    PluginBleRegistry? bleRegistry,
  }) : notifications = notifications ?? NotificationCenter(),
       _createJsRuntime =
           createJsRuntime ?? (() => getJavascriptRuntime(xhr: false)),
       deviceService = deviceService ?? PluginDeviceService() {
    _decentProxyBridge = PluginDecentProxyBridge(
      decentProxyService: decentProxyService,
      log: _log,
    );
    _localApiBridge = PluginLocalApiBridge(
      maxResponseBytes: maxFetchResponseBytes,
    );
    _transportService = PluginTransportService(
      eventSink: _dispatchTransportEvent,
      connectWebSocket: connectWebSocket,
      connectSocket: (host, port) async => _refuseHostApiSocket(
        await (connectSocket ?? Socket.connect)(host, port),
      ),
      connectSecureSocket: (host, port) async => _refuseHostApiSocket(
        await (connectSecureSocket ?? SecureSocket.connect)(host, port),
      ),
      closeTimeout: transportCloseTimeout,
    );
    bleService = PluginBleService(
      registry: bleRegistry ?? PluginBleRegistry(),
      invocationTimeout: deviceInvocationTimeout,
      invoke: (driver, handle, operation, payload) => _invokeDeviceHandler(
        driver.pluginId,
        driver.generation,
        handle,
        operation,
        payload,
        protocolBoundsConnectStartup:
            operation == PluginDeviceOperation.connect,
      ),
      runtimeAlive: (driver) =>
          (_pluginGenerations[driver.pluginId] == driver.generation &&
              _plugins[driver.pluginId]?.isAlive == true) ||
          _isDeviceDisconnectCleanup(driver.pluginId, driver.generation),
      hasHandler: (driver, handle, operation) => _deviceHasHandler(
        driver.pluginId,
        driver.generation,
        handle,
        operation,
      ),
      eventSink: (driver, handle, event) async {
        await _invokeDeviceHandler(
          driver.pluginId,
          driver.generation,
          handle,
          PluginDeviceOperation.bleEvent,
          event,
        );
      },
      removeHandlers: (driver, handle) {
        if (_lifecycle == PluginManagerLifecycle.disposed) return;
        _realmOf(driver.pluginId, driver.generation)?.evaluate(
          'globalThis.__deviceRemoveHandlers(${jsonEncode(handle)});',
        );
      },
    );
  }

  _PluginRealm? _realmOf(String pluginId, [int? generation]) {
    final realm = _realms[pluginId];
    if (realm == null) return null;
    if (generation != null && realm.generation != generation) return null;
    return realm;
  }

  @visibleForTesting
  JavascriptRuntime jsRealmOf(String pluginId) {
    final realm = _realms[pluginId];
    if (realm == null) {
      throw StateError('Plugin has no JavaScript realm: $pluginId');
    }
    return realm.js;
  }

  bool _deviceHasHandler(
    String pluginId,
    int generation,
    String handle,
    String operation,
  ) =>
      _realmOf(pluginId, generation)
          ?.evaluate(
            'globalThis.__deviceHasHandler(${jsonEncode(handle)},'
            '${jsonEncode(pluginId)},$generation,${jsonEncode(operation)})',
          )
          .stringResult ==
      'true';

  void _ensureActive() {
    if (_lifecycle != PluginManagerLifecycle.active) {
      throw StateError('PluginManager is ${_lifecycle.name}');
    }
  }

  Future<void> dispose() {
    bleService.registry.stopConnections();
    final existing = _disposeFuture;
    if (existing != null) return existing;

    _lifecycle = PluginManagerLifecycle.disposing;
    _attachmentGeneration += 1;
    final disposal = _dispose();
    _disposeFuture = disposal;
    return disposal;
  }

  Future<void> _dispose() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> runStage(String name, FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
        _log.warning(
          'PluginManager disposal failed during $name',
          error,
          stackTrace,
        );
      }
    }

    try {
      await runStage(
        'workflow controller detachment',
        _detachWorkflowController,
      );
      await runStage('attachment queue', () => _attachmentQueue);
      await runStage('snapshot queue', () => _snapshotQueue);
      await runStage('controller detachment', _cancelControllerSubscriptions);
      for (final pluginId in _plugins.keys.toList()) {
        await runStage(
          'plugin unload: $pluginId',
          () => _unloadPlugin(pluginId),
        );
      }
      await runStage('async operation cleanup', _cancelAllOperations);
      await runStage('event stream closure', _emitController.close);
      await runStage('notification storage drain', () => notifications.settled);
      for (final realm in _realms.values.toList()) {
        await runStage(
          'JavaScript realm disposal: ${realm.pluginId}',
          () => _disposeRealm(realm),
        );
      }
    } finally {
      for (final record in _timers.values) {
        record.timer.cancel();
      }
      _timers.clear();
      for (final op in _pendingOps.values) {
        op.timeout?.cancel();
        try {
          op.request?.abort();
        } catch (_) {}
      }
      _pendingOps.clear();
      _httpClient?.close(force: true);
      _httpClient = null;
      _plugins.clear();
      _pluginGenerations.clear();
      _retiringPluginGenerations.clear();
      _deviceDisconnectCleanup.clear();
      _deviceConnectAttempts.clear();
      _timedOutDeviceConnects.clear();
      _pluginStorageOperations.clear();
      _realms.clear();
      _extensionGrants.clear();
      _localApiBridge.handler = null;
      for (final pending in _pendingDeviceInvocations.values) {
        pending.timer?.cancel();
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(
            const PluginDeviceException('Plugin manager disposed'),
          );
        }
      }
      _pendingDeviceInvocations.clear();
      _de1Subscription = null;
      _snapshotSubscription = null;
      _de1controller = null;
      _workflowController = null;
      _workflowListener = null;
      _lastWorkflowRevision = null;
      _lifecycle = PluginManagerLifecycle.disposed;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  bool _holdsPermission(String pluginId, PluginPermissions permission) {
    final permissions =
        _plugins[pluginId]?.manifest.permissions ??
        _closingPluginPermissions[pluginId];
    return permissions?.contains(permission) ?? false;
  }

  bool _hasPermission(String pluginId, PluginPermissions permission) {
    final allowed = _holdsPermission(pluginId, permission);
    if (!allowed) {
      final denial = '$pluginId:${permission.wireName}';
      if (_loggedPermissionDenials.add(denial)) {
        _log.warning(
          'Plugin $pluginId denied permission ${permission.wireName}',
        );
      }
    }
    return allowed;
  }

  void attachLocalApi(shelf.Handler handler) {
    _ensureActive();
    _localApiBridge.handler = handler;
  }

  bool _holdsExtensionGrant(_PluginExtensionGrant grant) {
    final pluginId = grant._runtime.pluginId;
    return _lifecycle == PluginManagerLifecycle.active &&
        identical(_extensionGrants[pluginId], grant) &&
        identical(_plugins[pluginId], grant._runtime) &&
        _pluginGenerations[pluginId] == grant._generation &&
        grant._runtime.isAlive &&
        grant._runtime.manifest.permissions.contains(
          PluginPermissions.manageExtensions,
        );
  }

  Object? _withoutBridgeToken(Object? message) =>
      message is Map ? ({...message}..remove('bridgeToken')) : message;

  String _permissionError(String pluginId, PluginPermissions permission) =>
      'PluginPermissionError: Plugin $pluginId requires manifest permission ${permission.wireName}';

  String? _pluginIdForBridgeMessage(
    _PluginRealm realm,
    Map<String, dynamic> msg,
    String channel,
  ) {
    if (!identical(_realms[realm.pluginId], realm)) {
      _log.warning(
        'Rejected $channel message from a retired realm of ${realm.pluginId}',
      );
      return null;
    }
    if (msg['bridgeToken'] != realm.bridgeToken) {
      _log.warning(
        'Rejected $channel message with invalid bridge token from ${realm.pluginId}',
      );
      _rejectInRealm(realm, channel, msg, 'Invalid plugin bridge caller');
      return null;
    }
    final claimedPluginId = msg['pluginId'];
    if (claimedPluginId != null && claimedPluginId != realm.pluginId) {
      _log.warning(
        'Rejected $channel message claiming plugin $claimedPluginId as ${realm.pluginId}',
      );
      _rejectInRealm(realm, channel, msg, 'Invalid plugin bridge caller');
      return null;
    }
    final generation = msg['generation'];
    if (generation != null &&
        (generation is! num || generation.toInt() != realm.generation)) {
      _log.warning(
        'Rejected $channel message for generation $generation of ${realm.pluginId}',
      );
      _rejectInRealm(realm, channel, msg, 'Plugin generation changed');
      return null;
    }
    return realm.pluginId;
  }

  void _rejectInRealm(
    _PluginRealm realm,
    String channel,
    Map<String, dynamic> msg,
    String error,
  ) {
    final requestId = msg['requestId'];
    final payload = msg['payload'];
    final String? reply = switch ((channel, msg['type'])) {
      ('fetch', _) when msg['id'] is num =>
        'globalThis.__handleFetchResponse('
            '${jsonEncode({'id': msg['id'], 'error': error})});',
      ('transport', 'onEvent')
          when payload is Map && payload['handle'] is String =>
        'globalThis.__transportRemoveListener(${jsonEncode(payload['handle'])});',
      ('transport', _) when requestId is String =>
        'globalThis.__handleTransportReply('
            '${jsonEncode({'requestId': requestId, 'bridgeToken': msg['bridgeToken'], 'error': error})});',
      ('devices', _) when requestId is String =>
        'globalThis.__handleDeviceReply('
            '${jsonEncode({'requestId': requestId, 'bridgeToken': msg['bridgeToken'], 'error': error})});',
      ('host', 'decentProxy' || 'localApi' || 'discoveryBrowse')
          when requestId is String =>
        'globalThis.__reaprimePluginBridge.completeDecentProxyRequest('
            '${jsonEncode(msg['pluginId'] ?? realm.pluginId)}, '
            '${jsonEncode(requestId)}, ${jsonEncode({'error': error})});',
      ('host', 'timerSet') when msg['timerId'] is num =>
        'globalThis.__timerClear('
            '${jsonEncode(msg['bridgeToken'])}, ${jsonEncode(msg['timerId'])});',
      _ => null,
    };
    if (reply == null) return;
    unawaited(
      Future<void>.delayed(Duration.zero, () {
        if (!identical(_realms[realm.pluginId], realm)) return;
        try {
          realm.evaluate(reply);
        } catch (e, st) {
          _log.warning('Failed to reject $channel message in its realm', e, st);
        }
      }),
    );
  }

  _PluginRealm _createRealm(String pluginId, int generation) {
    final JavascriptRuntime js;
    try {
      js = _createJsRuntime();
    } catch (error, stackTrace) {
      _log.warning(
        'Could not create a JavaScript realm for $pluginId',
        error,
        stackTrace,
      );
      throw StateError('Plugin realm could not be created: $error');
    }
    final realm = _PluginRealm(
      pluginId: pluginId,
      generation: generation,
      bridgeToken: _newBridgeToken(),
      js: js,
    );
    try {
      final probe = js.evaluate('1 + 1');
      if (probe.isError || probe.stringResult != '2') {
        throw StateError('Plugin realm is not usable: ${probe.stringResult}');
      }
      _bootstrapRealm(realm);
      debugPrepareRealm?.call(pluginId, realm.js);
      final lock = realm.js.evaluate('globalThis.__lockPluginHostBridge();');
      if (lock.isError) {
        throw StateError('Plugin realm lock failed: ${lock.stringResult}');
      }
    } catch (_) {
      realm.js.dispose();
      rethrow;
    }
    return realm;
  }

  void _disposeRealm(_PluginRealm realm) {
    if (identical(_realms[realm.pluginId], realm)) {
      _realms.remove(realm.pluginId);
    }
    realm.js.dispose();
  }

  void _bootstrapRealm(_PluginRealm realm) {
    final js = realm.js;
    _requireBootstrap(
      js.evaluate(r'''
      (function () {
        "use strict";
        const __pinGlobal = (name, value, enumerable = false) => {
          Object.defineProperty(globalThis, name, {
            get: () => value,
            set: undefined,
            enumerable: enumerable,
            configurable: false
          });
        };

        const __nativeSendMessage = sendMessage;
        const __nativeJsonStringify = JSON.stringify.bind(JSON);
        const __nativeNumberIsFinite = Number.isFinite;
        const __nativeNumberValueOf = Number.prototype.valueOf;
        const __nativeBigIntValueOf = typeof BigInt === "function" ? BigInt.prototype.valueOf : null;
        const __NativePromise = Promise;
        const __NativeError = Error;
        const __nativeFreeze = Object.freeze.bind(Object);
        const __nativeReflectApply = Reflect.apply.bind(Reflect);
        const __nativePromiseThen = Promise.prototype.then;
        const __nativePromiseResolve = Promise.resolve;
        const __nativePromiseCatch = Promise.prototype.catch;
        const __nativePromiseFinally = Promise.prototype.finally;
        const __nativeMapHas = Map.prototype.has;
        const __nativeMapGet = Map.prototype.get;
        const __nativeMapSet = Map.prototype.set;
        const __nativeMapDelete = Map.prototype.delete;
        const __nativeMapClear = Map.prototype.clear;
        const __nativeMapForEach = Map.prototype.forEach;
        const __nativeMapSize = Object.getOwnPropertyDescriptor(Map.prototype, "size").get;
        const __NativeString = String;
        const __NativeNumber = Number;
        const __nativeMathMax = Math.max;
        const __nativeMathTrunc = Math.trunc;

        const __pendingDecentProxyRequests = new Map();
        let __decentProxySeq = 0;
        const __decentProxyNonce =
          Date.now().toString(36) + "_" + Math.random().toString(36).slice(2);

        function __mapHas(map, key) {
          return __nativeReflectApply(__nativeMapHas, map, [key]);
        }

        function __mapGet(map, key) {
          return __nativeReflectApply(__nativeMapGet, map, [key]);
        }

        function __mapSet(map, key, value) {
          return __nativeReflectApply(__nativeMapSet, map, [key, value]);
        }

        function __mapDelete(map, key) {
          return __nativeReflectApply(__nativeMapDelete, map, [key]);
        }

        function __mapClear(map) {
          return __nativeReflectApply(__nativeMapClear, map, []);
        }

        function __mapForEach(map, callback) {
          return __nativeReflectApply(__nativeMapForEach, map, [callback]);
        }

        let __plugin = null;
        __pinGlobal("__registerPlugin", function (plugin) {
          if (__plugin !== null) {
            throw new __NativeError("Plugin registration refused");
          }
          __plugin = plugin;
        });
        __pinGlobal("__unregisterPlugin", function () {
          const plugin = __plugin;
          __plugin = null;
          plugin?.onUnload?.();
        });

        function __pendingDecentProxyByPlugin(pluginId) {
          if (!__mapHas(__pendingDecentProxyRequests, pluginId)) {
            __mapSet(__pendingDecentProxyRequests, pluginId, new Map());
          }
          return __mapGet(__pendingDecentProxyRequests, pluginId);
        }

        function __sendHostMessage(message) {
          __nativeSendMessage("host", __nativeJsonStringify(message));
        }

        function __wrapDecentProxyPromise(promise) {
          const wrapped = {
            then(onFulfilled, onRejected) {
              return __nativeReflectApply(__nativePromiseThen, promise, [
                onFulfilled,
                onRejected
              ]);
            },
            catch(onRejected) {
              return __nativeReflectApply(__nativePromiseCatch, promise, [
                onRejected
              ]);
            }
          };
          if (typeof __nativePromiseFinally === "function") {
            wrapped.finally = function (onFinally) {
              return __nativeReflectApply(__nativePromiseFinally, promise, [
                onFinally
              ]);
            };
          }
          return __nativeFreeze(wrapped);
        }

        function __decentProxy(pluginId, generation, bridgeToken, path, method, query, body, contentType, gzip) {
          const requestId = "__decent_proxy_" + __decentProxyNonce + "_" + (++__decentProxySeq);
          const promise = new __NativePromise((resolve, reject) => {
            const pendingByPlugin = __pendingDecentProxyByPlugin(pluginId);
            __mapSet(pendingByPlugin, requestId, { generation: generation, resolve: resolve, reject: reject });
            try {
              __sendHostMessage({
                pluginId: pluginId,
                generation: generation,
                bridgeToken: bridgeToken,
                type: "decentProxy",
                requestId: requestId,
                path: path,
                method: method,
                query: query,
                body: body,
                contentType: contentType,
                gzip: gzip
              });
            } catch (e) {
              __mapDelete(pendingByPlugin, requestId);
              reject(e);
            }
          });
          return __wrapDecentProxyPromise(promise);
        }

        function __localApi(pluginId, generation, bridgeToken, path, method, body, contentType) {
          const requestId = "__local_api_" + __decentProxyNonce + "_" + (++__decentProxySeq);
          const promise = new __NativePromise((resolve, reject) => {
            const pendingByPlugin = __pendingDecentProxyByPlugin(pluginId);
            __mapSet(pendingByPlugin, requestId, { generation: generation, resolve: resolve, reject: reject });
            try {
              __sendHostMessage({
                pluginId: pluginId,
                generation: generation,
                bridgeToken: bridgeToken,
                type: "localApi",
                requestId: requestId,
                path: path,
                method: method,
                body: body,
                contentType: contentType
              });
            } catch (e) {
              __mapDelete(pendingByPlugin, requestId);
              reject(e);
            }
          });
          return __wrapDecentProxyPromise(promise);
        }

        function __discoveryBrowse(pluginId, generation, bridgeToken, options) {
          const requestId = "__discovery_" + __decentProxyNonce + "_" + (++__decentProxySeq);
          const promise = new __NativePromise((resolve, reject) => {
            const pendingByPlugin = __pendingDecentProxyByPlugin(pluginId);
            __mapSet(pendingByPlugin, requestId, { generation: generation, resolve: resolve, reject: reject });
            try {
              __sendHostMessage({
                pluginId: pluginId,
                generation: generation,
                bridgeToken: bridgeToken,
                type: "discoveryBrowse",
                requestId: requestId,
                options: options
              });
            } catch (e) {
              __mapDelete(pendingByPlugin, requestId);
              reject(e);
            }
          });
          return __wrapDecentProxyPromise(
            __nativeReflectApply(__nativePromiseThen, promise, [
              (response) => response.services
            ])
          );
        }

        function __completeDecentProxyRequest(pluginId, requestId, response) {
          const pendingByPlugin = __mapGet(__pendingDecentProxyRequests, pluginId);
          if (!pendingByPlugin) return;
          const pending = __mapGet(pendingByPlugin, requestId);
          if (!pending) return;
          __mapDelete(pendingByPlugin, requestId);
          if (__nativeReflectApply(__nativeMapSize, pendingByPlugin, []) === 0) {
            __mapDelete(__pendingDecentProxyRequests, pluginId);
          }
          if (response && response.error) {
            const error = new __NativeError(response.error);
            if (response.code) error.code = response.code;
            pending.reject(error);
            return;
          }
          pending.resolve(response);
        }

        function __cancelDecentProxyRequestsForPlugin(pluginId, error) {
          const pendingByPlugin = __mapGet(__pendingDecentProxyRequests, pluginId);
          if (!pendingByPlugin) return;
          __mapDelete(__pendingDecentProxyRequests, pluginId);
          __mapForEach(pendingByPlugin, (pending) => {
            pending.reject(new __NativeError(error));
          });
        }

        function __cancelAllDecentProxyRequests(error) {
          const pluginIds = [];
          __mapForEach(__pendingDecentProxyRequests, (_, pluginId) => {
            pluginIds[pluginIds.length] = pluginId;
          });
          for (let i = 0; i < pluginIds.length; i++) {
            __cancelDecentProxyRequestsForPlugin(pluginIds[i], error);
          }
        }

        __pinGlobal("__reaprimePluginBridge", __nativeFreeze({
          decentProxy: __decentProxy,
          localApi: __localApi,
          discoveryBrowse: __discoveryBrowse,
          completeDecentProxyRequest: __completeDecentProxyRequest,
          cancelForPlugin: __cancelDecentProxyRequestsForPlugin,
          cancelAll: __cancelAllDecentProxyRequests
        }));
        
        function __sendApiResponse(bridgeToken, generation, requestId, response) {
          __sendHostMessage({
            bridgeToken: bridgeToken,
            generation: generation,
            type: "httpResponse",
            requestId: requestId,
            payload: response
          });
        }

        function __sendApiError(bridgeToken, generation, requestId, error) {
          __sendApiResponse(bridgeToken, generation, requestId, {
            status: 500,
            headers: { "Content-Type": "application/json" },
            body: __nativeJsonStringify({ error: __NativeString(error) })
          });
        }

        __pinGlobal("__dispatchPluginHttp", function (bridgeToken, generation, requestId, event) {
          const plugin = __plugin;
          if (!plugin || typeof plugin.__httpRequestHandler !== "function") return;
          try {
            const response = plugin.__httpRequestHandler(event);
            if (response && typeof response.then === "function") {
              const promise = __nativeReflectApply(
                __nativePromiseResolve,
                __NativePromise,
                [response]
              );
              __nativeReflectApply(__nativePromiseThen, promise, [
                (result) => __sendApiResponse(bridgeToken, generation, requestId, result),
                (error) => __sendApiError(bridgeToken, generation, requestId, error)
              ]);
            } else if (response) {
              __sendApiResponse(bridgeToken, generation, requestId, response);
            }
          } catch (error) {
            __sendApiError(bridgeToken, generation, requestId, error);
          }
        });

        // Provide btoa function if not available
        if (typeof globalThis.btoa === 'undefined') {
            globalThis.btoa = function (input) {
              // 1. Convert to string (per spec)
              const str = String(input);

              // 2. Reject non-Latin-1 characters
              for (let i = 0; i < str.length; i++) {
                if (str.charCodeAt(i) > 0xFF) {
                  throw new DOMException(
                    "The string to be encoded contains characters outside of the Latin1 range.",
                    "InvalidCharacterError"
                  );
                }
              }

              const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
              let output = "";
              let i = 0;

              // 3. Encode
              while (i < str.length) {
                const byte1 = str.charCodeAt(i++);
                const byte2 = i < str.length ? str.charCodeAt(i++) : undefined;
                const byte3 = i < str.length ? str.charCodeAt(i++) : undefined;

                const enc1 = byte1 >> 2;
                const enc2 = ((byte1 & 0x03) << 4) | (byte2 !== undefined ? byte2 >> 4 : 0);
                const enc3 = byte2 !== undefined
                  ? ((byte2 & 0x0f) << 2) | (byte3 !== undefined ? byte3 >> 6 : 0)
                  : 64;
                const enc4 = byte3 !== undefined ? (byte3 & 0x3f) : 64;

                output +=
                  chars.charAt(enc1) +
                  chars.charAt(enc2) +
                  (enc3 === 64 ? "=" : chars.charAt(enc3)) +
                  (enc4 === 64 ? "=" : chars.charAt(enc4));
              }

              return output;
            };
        }

        if (typeof globalThis.atob === 'undefined') {
          globalThis.atob = function (input) {
            const chars =
              "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            const str = String(input).replace(/[\t\n\f\r ]/g, "");
            const clean = str.length % 4 === 0 ? str.replace(/==?$/, "") : str;
            if (clean.length % 4 === 1 || /[^A-Za-z0-9+/]/.test(clean)) {
              throw new Error("The string to be decoded is not correctly encoded.");
            }
            let output = "";
            let buffer = 0;
            let bits = 0;
            for (let i = 0; i < clean.length; i++) {
              buffer = (buffer << 6) | chars.indexOf(clean.charAt(i));
              bits += 6;
              if (bits >= 8) {
                bits -= 8;
                output += String.fromCharCode((buffer >> bits) & 0xff);
              }
            }
            return output;
          };
        }

        // Host error reports return to Dart instead of going through the
        // plugin's console, which is the plugin's own (log-gated) output.
        const __errorText = (e) => {
          try { return __NativeString(e); } catch (_) { return "unprintable error"; }
        };
        __pinGlobal("__dispatchToPlugin", function (evt) {
          const plugin = __plugin;
          if (!plugin || typeof plugin.onEvent !== "function") return "";
          try {
            plugin.onEvent(evt);
            return "";
          } catch (e) {
            return __errorText(e);
          }
        });

        // Timer bridge: JS holds callbacks, Dart owns real Timers.
        const __timers = new Map();
        let __timerSeq = 0;
        __pinGlobal("__debugTimerCount", () => __timers.size);
        __pinGlobal("__debugPendingCounts", () => {
          let decentProxy = 0;
          __mapForEach(__pendingDecentProxyRequests, (pending) => {
            decentProxy += pending.size;
          });
          return {
            decentProxy: decentProxy,
            transport: __transportPending.size,
            devices: __devicePending.size,
            timers: __timers.size
          };
        });
        globalThis.__timerSet = function (bridgeToken, generation, callback, delay) {
          const id = ++__timerSeq;
          __mapSet(__timers, id, { bridgeToken: bridgeToken, generation: generation, callback: callback });
          __sendHostMessage({
            bridgeToken: bridgeToken,
            generation: generation,
            type: "timerSet",
            timerId: id,
            delay: __nativeMathMax(0, __nativeMathTrunc(__NativeNumber(delay) || 0))
          });
          return id;
        };
        globalThis.__timerClear = function (bridgeToken, id) {
          const record = __mapGet(__timers, id);
          if (record && record.bridgeToken === bridgeToken && __mapDelete(__timers, id)) {
            __sendHostMessage({
              bridgeToken: bridgeToken,
              generation: record.generation,
              type: "timerClear",
              timerId: id
            });
          }
        };
        __pinGlobal("__fireTimer", function (id) {
          const record = __mapGet(__timers, id);
          if (!record) return;
          try {
            record.callback();
          } finally {
            __mapDelete(__timers, id);
          }
        });
        __pinGlobal("__cancelTimersForBridgeToken", function (bridgeToken) {
          __mapForEach(__timers, (record, id) => {
            if (record.bridgeToken === bridgeToken) __mapDelete(__timers, id);
          });
        });
        __pinGlobal("__cancelAllTimers", function () {
          __mapClear(__timers);
        });

        const __transportListeners = new Map();
        const __transportPending = new Map();
        function __sendTransportMessage(message) {
          __nativeSendMessage("transport", __nativeJsonStringify(message));
        }
        __pinGlobal("__transportRequest", function (
          bridgeToken,
          generation,
          requestId,
          type,
          payload,
          deviceRegistrationHandle,
          deviceInvocationId
        ) {
          const message = {
            bridgeToken: bridgeToken,
            generation: generation,
            requestId: requestId,
            type: type,
            payload: payload
          };
          if (typeof deviceRegistrationHandle === "string" &&
              typeof deviceInvocationId === "string") {
            message.deviceRegistrationHandle = deviceRegistrationHandle;
            message.deviceInvocationId = deviceInvocationId;
          }
          __sendTransportMessage(message);
        });
        __pinGlobal("__transportRegister", function (requestId, entry) {
          __mapSet(__transportPending, requestId, entry);
        });
        __pinGlobal("__transportSetListener", function (handle, pluginId, listener) {
          __mapSet(__transportListeners, handle, { pluginId: pluginId, listener: listener });
        });
        __pinGlobal("__transportRemoveListener", function (handle) {
          __mapDelete(__transportListeners, handle);
        });
        __pinGlobal("__handleTransportReply", function (msg) {
          const pending = __mapGet(__transportPending, msg.requestId);
          if (!pending || pending.bridgeToken !== msg.bridgeToken) return;
          __mapDelete(__transportPending, msg.requestId);
          if (msg.error) {
            const error = new __NativeError(msg.error);
            if (msg.code) error.code = msg.code;
            if (msg.peerSha256) error.peerSha256 = msg.peerSha256;
            pending.reject(error);
            return;
          }
          pending.resolve(msg.result || {});
        });
        __pinGlobal("__dispatchTransportEvent", function (pluginId, handle, event) {
          const record = __mapGet(__transportListeners, handle);
          if (!record || record.pluginId !== pluginId || !record.listener) return "";
          try {
            record.listener(event);
            return "";
          } catch (e) {
            return __errorText(e);
          }
        });
        __pinGlobal("__rejectTransportPendingForToken", function (bridgeToken, error) {
          __mapForEach(__transportPending, (pending, requestId) => {
            if (pending.bridgeToken !== bridgeToken) return;
            __mapDelete(__transportPending, requestId);
            pending.reject(new __NativeError(error));
          });
        });
        __pinGlobal("__rejectAllTransportPending", function (error) {
          __mapForEach(__transportPending, (pending) => {
            pending.reject(new __NativeError(error));
          });
          __mapClear(__transportPending);
        });
        __pinGlobal("__clearTransportListenersForPlugin", function (pluginId) {
          __mapForEach(__transportListeners, (record, handle) => {
            if (record.pluginId === pluginId) __mapDelete(__transportListeners, handle);
          });
        });
        __pinGlobal("__clearAllTransportListeners", function () {
          __mapClear(__transportListeners);
        });

        const __devicePending = new Map();
        const __deviceHandlers = new Map();
        function __isBoxedNumericValue(value) {
          if (value === null || typeof value !== "object") return false;
          try {
            __nativeReflectApply(__nativeNumberValueOf, value, []);
            return true;
          } catch (_) {}
          if (__nativeBigIntValueOf !== null) {
            try {
              __nativeReflectApply(__nativeBigIntValueOf, value, []);
              return true;
            } catch (_) {}
          }
          return false;
        }
        function __deviceJsonValue(key, value) {
          if ((typeof value === "number" && !__nativeNumberIsFinite(value)) || typeof value === "bigint" || __isBoxedNumericValue(value)) {
            const error = new __NativeError("Device payload numbers must be finite, unboxed and not BigInt");
            error.code = "invalid_argument";
            throw error;
          }
          return value;
        }
        function __sendDeviceMessage(message, replacer) {
          __nativeSendMessage("devices", __nativeJsonStringify(message, replacer));
        }
        __pinGlobal("__deviceRequest", function (bridgeToken, generation, requestId, type, payload) {
          try {
            __sendDeviceMessage({
              bridgeToken: bridgeToken,
              generation: generation,
              requestId: requestId,
              type: type,
              payload: payload
            }, __deviceJsonValue);
          } catch (error) {
            __mapDelete(__devicePending, requestId);
            throw error;
          }
        });
        __pinGlobal("__deviceRegisterPending", function (requestId, entry) {
          __mapSet(__devicePending, requestId, entry);
        });
        __pinGlobal("__deviceSetHandlers", function (handle, entry) {
          __mapSet(__deviceHandlers, handle, entry);
        });
        __pinGlobal("__deviceRemoveHandlers", function (handle) {
          __mapGet(__deviceHandlers, handle)?.dispose?.();
          __mapDelete(__deviceHandlers, handle);
        });
        __pinGlobal("__deviceHasHandler", function (handle, pluginId, generation, operation) {
          const entry = __mapGet(__deviceHandlers, handle);
          return !!entry && entry.pluginId === pluginId && entry.generation === generation &&
            typeof entry.handlers[operation] === "function";
        });
        __pinGlobal("__handleDeviceReply", function (msg) {
          const pending = __mapGet(__devicePending, msg.requestId);
          if (!pending || pending.bridgeToken !== msg.bridgeToken) return;
          __mapDelete(__devicePending, msg.requestId);
          if (msg.error) {
            const error = new __NativeError(msg.error);
            if (msg.code) error.code = msg.code;
            pending.reject(error);
            return;
          }
          pending.resolve(msg.result || {});
        });
        __pinGlobal("__dispatchDeviceInvocation", function (pluginId, generation, handle, invocationId, operation, payload) {
          const entry = __mapGet(__deviceHandlers, handle);
          if (!entry || entry.pluginId !== pluginId || entry.generation !== generation) return;
          const handler = entry.handlers[operation];
          if (typeof handler !== "function") {
            __sendDeviceMessage({
              bridgeToken: entry.bridgeToken,
              generation: generation,
              type: "invocationResult",
              payload: { invocationId: invocationId, error: "Missing device " + operation + " handler" }
            });
            return;
          }
          try {
            const handlerResult = operation === "connect"
              ? handler(entry.connectTransport(invocationId, payload))
              : operation === "setGrindSetting"
              ? handler(payload.setting)
              : operation === "setRpm"
              ? handler(payload.rpm)
              : handler(payload);
            const promise = __nativeReflectApply(
              __nativePromiseResolve,
              __NativePromise,
              [handlerResult]
            );
            __nativeReflectApply(__nativePromiseThen, promise, [
              (result) => __sendDeviceMessage({
                bridgeToken: entry.bridgeToken,
                generation: generation,
                type: "invocationResult",
                payload: { invocationId: invocationId, result: result }
              }),
              (error) => __sendDeviceMessage({
                bridgeToken: entry.bridgeToken,
                generation: generation,
                type: "invocationResult",
                payload: { invocationId: invocationId, error: __NativeString(error) }
              })
            ]);
          } catch (error) {
            __sendDeviceMessage({
              bridgeToken: entry.bridgeToken,
              generation: generation,
              type: "invocationResult",
              payload: { invocationId: invocationId, error: __NativeString(error) }
            });
          }
        });
        __pinGlobal("__rejectDevicePendingForToken", function (bridgeToken, error) {
          __mapForEach(__devicePending, (pending, requestId) => {
            if (pending.bridgeToken !== bridgeToken) return;
            __mapDelete(__devicePending, requestId);
            pending.reject(new __NativeError(error));
          });
        });
        __pinGlobal("__rejectAllDevicePending", function (error) {
          __mapForEach(__devicePending, (pending) => pending.reject(new __NativeError(error)));
          __mapClear(__devicePending);
        });
        __pinGlobal("__clearDeviceHandlersForPlugin", function (pluginId) {
          __mapForEach(__deviceHandlers, (entry, handle) => {
            if (entry.pluginId === pluginId) {
              entry.dispose?.();
              __mapDelete(__deviceHandlers, handle);
            }
          });
        });
        __pinGlobal("__clearAllDeviceHandlers", function () {
          __mapForEach(__deviceHandlers, entry => entry.dispose?.());
          __mapClear(__deviceHandlers);
        });

        let __notificationSeq = 0;
        __pinGlobal("host", __nativeFreeze({
          log(bridgeToken, generation, message) {
            __sendHostMessage({
              bridgeToken: bridgeToken,
              generation: generation,
              type: "log",
              payload: { message: __NativeString(message) }
            });
          },
          emit(bridgeToken, generation, eventName, payload) {
            __sendHostMessage({
              bridgeToken: bridgeToken,
              generation: generation,
              type: "emit",
              event: eventName,
              payload: payload
            });
          },
          notify(bridgeToken, generation, payload) {
            const requestId = "notice_" + (++__notificationSeq);
            __sendHostMessage({bridgeToken, generation, requestId, type: "notification", payload});
            return requestId;
          },
          dismissNotification(bridgeToken, generation, id) {
            __sendHostMessage({bridgeToken, generation, type: "notificationDismiss", payload: id ?? null});
          },
          storage(bridgeToken, generation, command) {
            __sendHostMessage({
              bridgeToken: bridgeToken,
              generation: generation,
              type: "pluginStorage",
              payload: command
            });
          },
          permissionDenied(bridgeToken, generation, permission) {
            __sendHostMessage({
              bridgeToken: bridgeToken,
              generation: generation,
              type: "permissionDenied",
              payload: permission
            });
          }
        }), true);
      })();
  '''),
    );

    _requireBootstrap(
      js.evaluate(r'''
      (function () {
        "use strict";
        const __pinGlobal = (name, value, enumerable = false) => {
          Object.defineProperty(globalThis, name, {
            get: () => value,
            set: undefined,
            enumerable: enumerable,
            configurable: false
          });
        };

        const nativeSendMessage = sendMessage;
        const nativeJsonStringify = JSON.stringify.bind(JSON);
        const nativeJsonParse = JSON.parse.bind(JSON);
        const nativeReflectApply = Reflect.apply.bind(Reflect);
        const nativeMapGet = Map.prototype.get;
        const nativeMapSet = Map.prototype.set;
        const nativeMapDelete = Map.prototype.delete;
        const nativeMapClear = Map.prototype.clear;
        const nativeMapForEach = Map.prototype.forEach;
        const nativeToLowerCase = String.prototype.toLowerCase;
        const NativeMap = Map;
        const NativePromise = Promise;
        const NativeError = Error;
        const mapGet = (map, key) => nativeReflectApply(nativeMapGet, map, [key]);
        const mapSet = (map, key, value) => nativeReflectApply(nativeMapSet, map, [key, value]);
        const mapDelete = (map, key) => nativeReflectApply(nativeMapDelete, map, [key]);
        const lowerCase = (value) => nativeReflectApply(nativeToLowerCase, String(value), []);
        let _fetchSeq = 0;
        const _pendingFetches = new NativeMap();

        function makeHeaders(headersObj) {
          const map = new NativeMap();
          for (const k in headersObj || {}) {
            mapSet(map, lowerCase(k), String(headersObj[k]));
          }
          return {
            get(name) {
              return mapGet(map, lowerCase(name)) ?? null;
            }
          };
        }

        globalThis.__fetchFor = function (bridgeToken, generation, input, init = {}) {
          const id = ++_fetchSeq;
          return new NativePromise((resolve, reject) => {
            if (!bridgeToken) {
              reject(new NativeError("fetch is only available to plugins"));
              return;
            }
            mapSet(_pendingFetches, id, { bridgeToken: bridgeToken, generation: generation, resolve: resolve, reject: reject });

            nativeSendMessage("fetch", nativeJsonStringify({
              id,
              bridgeToken,
              generation,
              url: String(input),
              method: init.method || "GET",
              headers: init.headers || {},
              body: init.body ?? null,
              tlsPinSha256: init.tlsPinSha256 ?? null,
              responseType: init.responseType ?? null
            }));
          });
        };

        globalThis.fetch = function fetch(input, init = {}) {
          return globalThis.__fetchFor(null, 0, input, init);
        };

        __pinGlobal("__handleFetchResponse", function (msg) {
          const pending = mapGet(_pendingFetches, msg.id);
          if (!pending) return;
          mapDelete(_pendingFetches, msg.id);

          if (msg.error) {
            const error = new NativeError(msg.error);
            if (msg.code) error.code = msg.code;
            if (msg.peerSha256) error.peerSha256 = msg.peerSha256;
            pending.reject(error);
            return;
          }

          const headers = makeHeaders(msg.headers);
          const isBase64 = typeof msg.bodyBase64 === "string";
          const base64Only =
            "This response was requested with responseType base64; use base64()";

          const response = {
            status: msg.status,
            ok: msg.status >= 200 && msg.status < 300,
            headers,
            text: async () => {
              if (isBase64) throw new TypeError(base64Only);
              return msg.body ?? "";
            },
            json: async () => {
              if (isBase64) throw new TypeError(base64Only);
              return nativeJsonParse(msg.body ?? "null");
            }
          };
          if (isBase64) response.base64 = async () => msg.bodyBase64;
          pending.resolve(response);
        });

        __pinGlobal("__cancelFetchesForBridgeToken", function (bridgeToken, error) {
          nativeReflectApply(nativeMapForEach, _pendingFetches, [(pending, id) => {
            if (pending.bridgeToken !== bridgeToken) return;
            mapDelete(_pendingFetches, id);
            pending.reject(new NativeError(error));
          }]);
        });

        __pinGlobal("__debugPendingFetchCount", () => _pendingFetches.size);

        __pinGlobal("__cancelAllFetches", function (error) {
          nativeReflectApply(nativeMapForEach, _pendingFetches, [(pending) => {
            pending.reject(new NativeError(error));
          }]);
          nativeReflectApply(nativeMapClear, _pendingFetches, []);
        });

        const hostGlobalNames = Object.getOwnPropertyNames(globalThis).filter(
          (name) => (name.startsWith("__") && !name.startsWith("__NATIVE_FLUTTER_JS__")) ||
            name === "host" || name === "fetch" || name === "sendMessage"
        );
        __pinGlobal("__lockPluginHostBridge", function () {
          if (globalThis.__reaprimePluginHostBridge) return;
          __pinGlobal("__reaprimePluginHostBridge", Object.freeze({
            log: globalThis.host.log,
            emit: globalThis.host.emit,
            notify: globalThis.host.notify,
            dismissNotification: globalThis.host.dismissNotification,
            storage: globalThis.host.storage,
            permissionDenied: globalThis.host.permissionDenied,
            fetch: globalThis.__fetchFor,
            timerSet: globalThis.__timerSet,
            timerClear: globalThis.__timerClear,
            transportRequest: globalThis.__transportRequest,
            deviceRequest: globalThis.__deviceRequest
          }));
          for (const name of [...hostGlobalNames, "globalThis"]) {
            const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
            if (!descriptor || !descriptor.configurable) continue;
            if ("value" in descriptor) {
              __pinGlobal(name, descriptor.value, descriptor.enumerable);
            } else {
              Object.defineProperty(globalThis, name, { configurable: false });
            }
          }
        });
      })();
    '''),
    );

    js.onMessage("host", (raw) {
      try {
        _log.finest("receiving: ${_withoutBridgeToken(raw)}");
        final msg = raw as Map<String, dynamic>;
        final pluginId = _pluginIdForBridgeMessage(realm, msg, 'host');

        if (pluginId == null) {
          return;
        }

        final operation = _handleMessageSafely(pluginId, msg);
        final generation = _messageGeneration(pluginId, msg);
        if (msg['type'] == 'pluginStorage' && generation != null) {
          _trackPluginStorageOperation(pluginId, generation, operation);
        } else {
          unawaited(operation);
        }
      } catch (e, st) {
        _log.warning("Invalid JS message", e, st);
      }
    });

    js.onMessage("fetch", (raw) {
      try {
        final msg = raw as Map<String, dynamic>;
        final pluginId = _pluginIdForBridgeMessage(realm, msg, 'fetch');
        if (pluginId != null) {
          unawaited(_handleFetchSafely(pluginId, msg));
        }
      } catch (e, st) {
        _log.warning("Invalid fetch message", e, st);
      }
    });

    js.onMessage("transport", (raw) {
      try {
        final msg = raw as Map<String, dynamic>;
        final pluginId = _pluginIdForBridgeMessage(realm, msg, 'transport');
        if (pluginId != null) {
          unawaited(_handleTransportSafely(pluginId, msg));
        }
      } catch (e, st) {
        _log.warning("Invalid transport message", e, st);
      }
    });

    js.onMessage("devices", (raw) {
      try {
        final msg = raw as Map<String, dynamic>;
        final pluginId = _pluginIdForBridgeMessage(realm, msg, 'devices');
        if (pluginId != null) {
          final operation = _handleDeviceMessage(pluginId, msg);
          if (msg['type'] == 'bindDriver') {
            final pending = _bleRegistrations.putIfAbsent(pluginId, () => {});
            pending.add(operation);
            unawaited(
              operation.whenComplete(() {
                pending.remove(operation);
                if (pending.isEmpty) _bleRegistrations.remove(pluginId);
              }),
            );
          } else {
            unawaited(operation);
          }
        }
      } catch (e, st) {
        _log.warning("Invalid plugin device message", e, st);
      }
    });

    // flutter_js prints console output without saying who wrote it. Each realm
    // holds one plugin, so its console lines are that plugin's, whatever they
    // claim; route them through the plugin log with that attribution.
    js.channelFunctions.remove('ConsoleLog');
    js.onMessageVoid('ConsoleLog', (args) => _writeConsoleLog(realm, args));
  }

  void _writeConsoleLog(_PluginRealm realm, Object? args) {
    if (!identical(_realms[realm.pluginId], realm) || args is! List) return;
    if (!_holdsPermission(realm.pluginId, PluginPermissions.log)) return;
    _writePluginLog(
      realm.pluginId,
      'console.${args.firstOrNull}: ${args.skip(1).join(' ')}',
      level: Level.FINE,
    );
  }

  void _requireBootstrap(JsEvalResult result) {
    if (result.isError) {
      throw StateError('Plugin realm bootstrap failed: ${result.stringResult}');
    }
  }

  Future<void> _handleMessageSafely(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    final retiringStorageWrite = _isRetiringPluginStorageWrite(pluginId, msg);
    if (_lifecycle != PluginManagerLifecycle.active && !retiringStorageWrite) {
      return;
    }
    try {
      final type = msg['type'];
      if (type == 'log') {
        if (_messageGeneration(pluginId, msg) != _pluginGenerations[pluginId] ||
            !_plugins.containsKey(pluginId)) {
          return;
        }
        if (_hasPermission(pluginId, PluginPermissions.log)) {
          _writePluginLog(pluginId, '${msg['payload']?['message']}');
        }
        return;
      }
      await Future<void>.delayed(Duration.zero);
      if (type == 'decentProxy') {
        await _handleDecentProxyMessage(pluginId, msg);
        return;
      }
      if (type == 'localApi') {
        await _handleLocalApiMessage(pluginId, msg);
        return;
      }
      if (type == 'discoveryBrowse') {
        await _handleDiscoveryMessage(pluginId, msg);
        return;
      }
      if (!_isCurrentPluginMessage(pluginId, msg) && !retiringStorageWrite) {
        return;
      }
      if (type == 'httpResponse') {
        if (_hasPermission(pluginId, PluginPermissions.api)) {
          _handlePluginApiResponse(pluginId, msg);
        }
        return;
      }
      final permission = switch (type) {
        'emit' => PluginPermissions.emit,
        'notification' ||
        'notificationDismiss' => PluginPermissions.notifications,
        'pluginStorage' => PluginPermissions.pluginStorage,
        _ => null,
      };
      if (permission == null || _hasPermission(pluginId, permission)) {
        await _handleMessage(pluginId, msg);
      }
    } catch (e, st) {
      _log.warning("Error handling message from $pluginId", e, st);
    }
  }

  Future<void> _handleFetchSafely(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    await Future<void>.delayed(Duration.zero);
    if (_lifecycle != PluginManagerLifecycle.active) return;
    try {
      await _handleFetch(pluginId, msg);
    } catch (e, st) {
      _log.warning("Invalid fetch message", e, st);
    }
  }

  Future<void> _handleTransportSafely(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    await Future<void>.delayed(Duration.zero);
    final generation = msg['generation'];
    final cleanupTransportClose =
        msg['type'] == 'close' &&
        generation is num &&
        _isDeviceDisconnectCleanup(pluginId, generation.toInt()) &&
        _plugins[pluginId]?.state == PluginRuntimeState.stopping;
    if (_lifecycle != PluginManagerLifecycle.active && !cleanupTransportClose) {
      return;
    }
    try {
      await _handleTransportMessage(pluginId, msg);
    } catch (e, st) {
      _log.warning("Invalid transport message", e, st);
    }
  }

  Future<void> _handleDeviceMessage(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    await Future<void>.delayed(Duration.zero);
    final bridgeToken = msg['bridgeToken'];
    final generation = msg['generation'] is num
        ? (msg['generation'] as num).toInt()
        : 0;
    final type = msg['type'];
    final payload = msg['payload'];
    if (payload is! Map) return;
    final data = Map<String, dynamic>.from(payload);
    final invocationId = data['invocationId'];
    final pending = invocationId is String
        ? _pendingDeviceInvocations[invocationId]
        : null;
    final cleanupInvocation =
        type == 'invocationResult' &&
        pending != null &&
        (pending.operation == PluginDeviceOperation.connect ||
            pending.operation == PluginDeviceOperation.disconnect ||
            pending.operation == PluginDeviceOperation.bleEvent) &&
        _isDeviceDisconnectCleanup(pluginId, generation);
    final cleanupGatt =
        type == 'gatt' && _isDeviceDisconnectCleanup(pluginId, generation);
    if (_lifecycle != PluginManagerLifecycle.active &&
        !cleanupInvocation &&
        !cleanupGatt) {
      return;
    }
    if (type == 'invocationResult') {
      if (invocationId is String) {
        _timedOutDeviceConnects.removeWhere(
          (key, ids) =>
              key.$1 == pluginId && ids.remove(invocationId) && ids.isEmpty,
        );
        final attempt = _deviceConnectAttempts[invocationId];
        if (attempt != null &&
            attempt.pluginId == pluginId &&
            attempt.generation == generation) {
          _deviceConnectAttempts.remove(invocationId);
          _transportService.finishDeviceConnect(
            attempt.pluginId,
            attempt.generation,
            attempt.registrationHandle,
            invocationId,
          );
        }
      }
      if ((generation != _pluginGenerations[pluginId] ||
              _plugins[pluginId]?.isAlive != true) &&
          !cleanupInvocation) {
        return;
      }
      _completeDeviceInvocation(pluginId, generation, data);
      return;
    }
    if ((generation != _pluginGenerations[pluginId] ||
            _plugins[pluginId]?.isAlive != true) &&
        !cleanupGatt) {
      return;
    }
    final requestId = msg['requestId'];
    if (requestId is! String) return;

    try {
      final registrationHandle = data['registrationHandle'];
      if (registrationHandle is! String) {
        throw const PluginDeviceException('Invalid registration handle');
      }
      switch (type) {
        case 'bindDriver':
          final declarations = _plugins[pluginId]!.manifest.drivers.where(
            (driver) => driver.id == data['driverId'],
          );
          if (declarations.isEmpty ||
              !_deviceHasHandler(
                pluginId,
                generation,
                registrationHandle,
                'create',
              )) {
            throw const PluginDeviceException(
              'BLE factory must name a declared driver',
            );
          }
          bleService.registry.register(
            pluginId: pluginId,
            generation: generation,
            declaration: declarations.single,
            factoryHandle: registrationHandle,
            permissions: _plugins[pluginId]!.manifest.permissions,
          );
          _replyDevice(pluginId, requestId, bridgeToken, result: const {});
        case 'gatt':
          final authority = data['authority'];
          final operation = data['operation'];
          final args = data['args'];
          if (authority is! String || operation is! String || args is! Map) {
            throw const PluginBleException(
              'invalid_argument',
              'Invalid GATT request',
            );
          }
          final value = await bleService.call(
            pluginId,
            generation,
            registrationHandle,
            authority,
            operation,
            Map<String, dynamic>.from(args),
          );
          _replyDevice(
            pluginId,
            requestId,
            bridgeToken,
            result: {'value': value},
          );
        case 'blePublish':
          final snapshot = data['snapshot'];
          final sample = data['sample'];
          if (snapshot is! Map || (sample != null && sample is! String)) {
            throw const PluginBleException(
              'invalid_argument',
              'Invalid BLE snapshot',
            );
          }
          bleService.publish(
            pluginId,
            generation,
            registrationHandle,
            Map<String, dynamic>.from(snapshot),
            data['session'] as String?,
            sample: sample as String?,
          );
          _replyDevice(pluginId, requestId, bridgeToken, result: const {});
        case 'blePublishInfo':
          final info = data['info'];
          if (info is! Map) {
            throw const PluginBleException(
              'invalid_argument',
              'Invalid BLE info',
            );
          }
          bleService.publishInfo(
            pluginId,
            generation,
            registrationHandle,
            Map<String, dynamic>.from(info),
            data['session'] as String?,
          );
          _replyDevice(pluginId, requestId, bridgeToken, result: const {});
        case 'bleDisconnected':
          bleService.reportDisconnected(
            pluginId,
            generation,
            registrationHandle,
            data['session'] as String?,
          );
          _replyDevice(pluginId, requestId, bridgeToken, result: const {});
        case 'register':
          final definition = data['definition'];
          if (definition is! Map) {
            throw const PluginDeviceException(
              'Invalid plugin device definition',
            );
          }
          final typedDefinition = Map<String, dynamic>.from(definition);
          final driverId = typedDefinition['driverId'];
          final declarations = _plugins[pluginId]!.manifest.drivers.where(
            (driver) => driver.id == driverId,
          );
          if (declarations.isEmpty) {
            throw const PluginDeviceException(
              'Device driver is not declared by this plugin',
            );
          }
          final driver = declarations.single;
          if (driver.type == PluginDriverType.scale ||
              driver.type == PluginDriverType.grinder) {
            final requiredHandlers = {
              'connect',
              'disconnect',
              if (driver.capabilities.contains(PluginScaleCapability.tare))
                'tare',
              if (driver.capabilities.contains(
                PluginScaleCapability.timerControl,
              )) ...[
                'startTimer',
                'stopTimer',
                'resetTimer',
              ],
              if (driver.capabilities.contains(
                PluginScaleCapability.displayControl,
              )) ...[
                'sleepDisplay',
                'wakeDisplay',
              ],
              if (driver.grinderCapabilities.contains(
                PluginGrinderCapability.startStop,
              )) ...[
                'start',
                'stop',
              ],
              if (driver.grinderCapabilities.contains(
                PluginGrinderCapability.grindSetting,
              ))
                'setGrindSetting',
              if (driver.grinderCapabilities.contains(
                PluginGrinderCapability.rpmControl,
              ))
                'setRpm',
            };
            for (final operation in PluginDeviceOperation.values) {
              final present = _deviceHasHandler(
                pluginId,
                generation,
                registrationHandle,
                operation.name,
              );
              if (present != requiredHandlers.contains(operation.name)) {
                throw PluginDeviceException(
                  '${driver.type.name} handler ${operation.name} does not match declared capabilities',
                  code: 'invalid_argument',
                );
              }
            }
          }
          final registered = await deviceService.register(
            pluginId: pluginId,
            generation: generation,
            registrationHandle: registrationHandle,
            definition: typedDefinition,
            driver: driver,
            invoke: (operation, parameters) => _invokeDeviceHandler(
              pluginId,
              generation,
              registrationHandle,
              operation,
              parameters,
            ),
          );
          _replyDevice(
            pluginId,
            requestId,
            bridgeToken,
            result: {'deviceId': registered.deviceId},
          );
        case 'publish':
          final snapshot = data['snapshot'];
          if (snapshot is! Map) {
            throw const PluginDeviceException('Invalid plugin device snapshot');
          }
          deviceService.publish(
            pluginId: pluginId,
            generation: generation,
            registrationHandle: registrationHandle,
            snapshot: Map<String, dynamic>.from(snapshot),
            session: data['session'] is String
                ? data['session'] as String
                : null,
          );
          _replyDevice(pluginId, requestId, bridgeToken, result: const {});
        case 'publishInfo':
          final info = data['info'];
          if (info is! Map) {
            throw const PluginDeviceException(
              'Invalid plugin device info',
              code: 'invalid_argument',
            );
          }
          deviceService.publishInfo(
            pluginId: pluginId,
            generation: generation,
            registrationHandle: registrationHandle,
            info: Map<String, dynamic>.from(info),
            session: data['session'] is String
                ? data['session'] as String
                : null,
          );
          _replyDevice(pluginId, requestId, bridgeToken, result: const {});
        case 'reportDisconnected':
          deviceService.reportDisconnected(
            pluginId: pluginId,
            generation: generation,
            registrationHandle: registrationHandle,
            session: data['session'] is String
                ? data['session'] as String
                : null,
          );
          _replyDevice(pluginId, requestId, bridgeToken, result: const {});
        case 'unregister':
          _rejectDeviceInvocations(
            pluginId,
            generation,
            'Plugin device unregistered',
            registrationHandle: registrationHandle,
            excludeOperations: {
              PluginDeviceOperation.connect,
              PluginDeviceOperation.disconnect,
            },
          );
          await deviceService.unregister(
            pluginId: pluginId,
            generation: generation,
            registrationHandle: registrationHandle,
          );
          _replyDevice(pluginId, requestId, bridgeToken, result: const {});
        default:
          throw const PluginDeviceException('Unknown plugin device operation');
      }
    } on PluginBleException catch (error) {
      _replyDevice(
        pluginId,
        requestId,
        bridgeToken,
        error: error.message,
        code: error.code,
      );
    } on PluginDeviceException catch (error) {
      _replyDevice(
        pluginId,
        requestId,
        bridgeToken,
        error: error.message,
        code: error.code,
      );
    } catch (error) {
      _replyDevice(
        pluginId,
        requestId,
        bridgeToken,
        error: error.toString(),
        code: type == 'gatt' ? bleBridgeErrorCode(error) : null,
      );
    }
  }

  void _replyDevice(
    String pluginId,
    String requestId,
    Object? bridgeToken, {
    Map<String, dynamic>? result,
    String? error,
    String? code,
  }) {
    try {
      _realmOf(pluginId)?.evaluate(
        'globalThis.__handleDeviceReply('
        '${jsonEncode({'requestId': requestId, 'bridgeToken': ?bridgeToken, 'result': result, 'error': error, 'code': code})});',
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to deliver plugin device reply', error, stackTrace);
    }
  }

  Future<Map<String, dynamic>> _invokeDeviceHandler(
    String pluginId,
    int generation,
    String registrationHandle,
    PluginDeviceOperation operation,
    Map<String, dynamic> payload, {
    bool protocolBoundsConnectStartup = false,
  }) {
    final isCurrent =
        _lifecycle == PluginManagerLifecycle.active &&
        generation == _pluginGenerations[pluginId] &&
        _plugins[pluginId]?.isAlive == true;
    final cleanupDisconnect =
        (operation == PluginDeviceOperation.disconnect ||
            operation == PluginDeviceOperation.bleEvent) &&
        _isDeviceDisconnectCleanup(pluginId, generation);
    if (!isCurrent && !cleanupDisconnect) {
      return Future.error(
        const PluginDeviceException('Plugin generation changed'),
      );
    }
    final retiredConnectInvocations = <String>[];
    if (operation == PluginDeviceOperation.disconnect) {
      final key = (pluginId, generation, registrationHandle);
      retiredConnectInvocations.addAll({
        ...?_timedOutDeviceConnects.remove(key),
        if (payload['session'] is String)
          ..._transportService.deviceConnectInvocations(
            pluginId,
            generation,
            registrationHandle,
          ),
        for (final entry in _deviceConnectAttempts.entries)
          if (entry.value.pluginId == pluginId &&
              entry.value.generation == generation &&
              entry.value.registrationHandle == registrationHandle)
            entry.key,
      });
      for (final connectInvocationId in retiredConnectInvocations) {
        _deviceConnectAttempts.remove(connectInvocationId);
        _transportService.retireDeviceConnect(
          pluginId,
          generation,
          registrationHandle,
          connectInvocationId,
        );
        final pending = _pendingDeviceInvocations.remove(connectInvocationId);
        pending?.timer?.cancel();
        pending?.completer.completeError(
          const PluginDeviceException(
            'Plugin device connect retired',
            code: 'stale_session',
          ),
        );
      }
    }
    final invocationId =
        '${pluginId}_${generation}_device_${++_deviceInvocationSequence}';
    final completer = Completer<Map<String, dynamic>>();
    final protocolOwnsStartup =
        protocolBoundsConnectStartup &&
        operation == PluginDeviceOperation.connect;
    final timer = protocolOwnsStartup
        ? null
        : Timer(deviceInvocationTimeout, () {
            final pending = _pendingDeviceInvocations.remove(invocationId);
            if (pending?.operation == PluginDeviceOperation.connect) {
              final key = (
                pending!.pluginId,
                pending.generation,
                pending.registrationHandle,
              );
              _timedOutDeviceConnects
                  .putIfAbsent(key, () => <String>{})
                  .add(invocationId);
              _transportService.retireDeviceConnect(
                pending.pluginId,
                pending.generation,
                pending.registrationHandle,
                invocationId,
              );
            }
            pending?.completer.completeError(
              const PluginDeviceException('Plugin device invocation timed out'),
            );
          });
    _pendingDeviceInvocations[invocationId] = _PendingDeviceInvocation(
      pluginId: pluginId,
      generation: generation,
      registrationHandle: registrationHandle,
      operation: operation,
      completer: completer,
      timer: timer,
    );
    if (operation == PluginDeviceOperation.connect) {
      _deviceConnectAttempts[invocationId] = (
        pluginId: pluginId,
        generation: generation,
        registrationHandle: registrationHandle,
      );
    }
    try {
      final realm = _realmOf(pluginId, generation);
      if (realm == null) {
        throw const PluginDeviceException('Plugin realm retired');
      }
      realm.evaluate(
        'globalThis.__dispatchDeviceInvocation('
        '${jsonEncode(pluginId)}, $generation, '
        '${jsonEncode(registrationHandle)}, ${jsonEncode(invocationId)}, '
        '${jsonEncode(operation.name)}, ${jsonEncode(payload)});',
      );
    } catch (error) {
      final pending = _pendingDeviceInvocations.remove(invocationId);
      pending?.timer?.cancel();
      if (operation == PluginDeviceOperation.connect) {
        _deviceConnectAttempts.remove(invocationId);
      }
      pending?.completer.completeError(error);
    }
    if (retiredConnectInvocations.isEmpty) return completer.future;
    return _awaitRetiredDeviceConnects(
      completer.future,
      pluginId,
      generation,
      registrationHandle,
      retiredConnectInvocations,
    );
  }

  Future<Map<String, dynamic>> _awaitRetiredDeviceConnects(
    Future<Map<String, dynamic>> invocation,
    String pluginId,
    int generation,
    String registrationHandle,
    List<String> invocationIds,
  ) async {
    Future<void> closeTransports() => Future.wait(
      invocationIds.map(
        (invocationId) => _transportService.closeDeviceConnect(
          pluginId,
          generation,
          registrationHandle,
          invocationId,
        ),
      ),
    );

    try {
      final result = await invocation;
      await closeTransports();
      return result;
    } catch (error, stackTrace) {
      try {
        await closeTransports();
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      for (final invocationId in invocationIds) {
        _transportService.finishDeviceConnect(
          pluginId,
          generation,
          registrationHandle,
          invocationId,
        );
      }
    }
  }

  void _completeDeviceInvocation(
    String pluginId,
    int generation,
    Map<String, dynamic> payload,
  ) {
    final invocationId = payload['invocationId'];
    if (invocationId is! String) return;
    final pending = _pendingDeviceInvocations[invocationId];
    if (pending == null ||
        pending.pluginId != pluginId ||
        pending.generation != generation) {
      return;
    }
    _pendingDeviceInvocations.remove(invocationId);
    pending.timer?.cancel();
    final error = payload['error'];
    if (error != null) {
      pending.completer.completeError(PluginDeviceException(error.toString()));
      return;
    }
    if (pending.operation != PluginDeviceOperation.execute &&
        pending.operation != PluginDeviceOperation.create) {
      pending.completer.complete(const {});
      return;
    }
    final result = payload['result'];
    if (result is Map) {
      pending.completer.complete(Map<String, dynamic>.from(result));
    } else {
      pending.completer.completeError(
        const PluginDeviceException(
          'Plugin device handler must return an object',
        ),
      );
    }
  }

  void _rejectDeviceInvocations(
    String pluginId,
    int generation,
    String reason, {
    String? registrationHandle,
    Set<PluginDeviceOperation>? excludeOperations,
  }) {
    final ids = _pendingDeviceInvocations.entries
        .where(
          (entry) =>
              entry.value.pluginId == pluginId &&
              entry.value.generation == generation &&
              (registrationHandle == null ||
                  entry.value.registrationHandle == registrationHandle) &&
              (excludeOperations == null ||
                  !excludeOperations.contains(entry.value.operation)),
        )
        .map((entry) => entry.key)
        .toList();
    for (final id in ids) {
      final pending = _pendingDeviceInvocations.remove(id)!;
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(PluginDeviceException(reason));
      }
    }
  }

  Future<void> _handleTransportMessage(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    final requestId = msg['requestId'];
    if (requestId is! String) {
      _log.warning('Transport message from $pluginId missing requestId');
      return;
    }
    final bridgeToken = msg['bridgeToken'];
    final generation = msg['generation'] is num
        ? (msg['generation'] as num).toInt()
        : 0;
    final type = msg['type'];
    final deviceRegistrationHandle = msg['deviceRegistrationHandle'];
    final deviceInvocationId = msg['deviceInvocationId'];
    final connectAttempt = deviceInvocationId is String
        ? _deviceConnectAttempts[deviceInvocationId]
        : null;
    final hasDeviceConnectClaim =
        type == 'open' &&
        (deviceRegistrationHandle != null || deviceInvocationId != null);
    final validDeviceConnectClaim =
        deviceRegistrationHandle is String && deviceInvocationId is String;
    final ownsDeviceConnect =
        type == 'open' &&
        validDeviceConnectClaim &&
        connectAttempt?.pluginId == pluginId &&
        connectAttempt?.generation == generation &&
        connectAttempt?.registrationHandle == deviceRegistrationHandle;
    final current =
        generation == _pluginGenerations[pluginId] &&
        _plugins[pluginId]?.isAlive == true;
    final cleanupTransportClose =
        type == 'close' &&
        _isDeviceDisconnectCleanup(pluginId, generation) &&
        _plugins[pluginId]?.state == PluginRuntimeState.stopping;
    if (!current && !cleanupTransportClose) {
      _replyTransport(
        pluginId,
        requestId,
        bridgeToken,
        error: 'Plugin generation changed',
      );
      return;
    }
    if (hasDeviceConnectClaim && !ownsDeviceConnect) {
      _replyTransport(
        pluginId,
        requestId,
        bridgeToken,
        error: 'Plugin device connect retired',
      );
      return;
    }
    final payload = msg['payload'];
    if (payload is! Map) {
      _replyTransport(
        pluginId,
        requestId,
        bridgeToken,
        error: 'Invalid transport message payload',
      );
      return;
    }
    try {
      switch (type) {
        case 'open':
          final kind = payload['kind'];
          final permission = switch (kind) {
            'websocket' => PluginPermissions.networkWebsocket,
            'tcp' => PluginPermissions.networkTcp,
            'tls' => PluginPermissions.networkTls,
            _ => null,
          };
          if (permission == null) {
            _replyTransport(
              pluginId,
              requestId,
              bridgeToken,
              error: 'Unknown transport kind',
            );
            return;
          }
          if (!_hasPermission(pluginId, permission)) {
            _replyTransport(
              pluginId,
              requestId,
              bridgeToken,
              error: _permissionError(pluginId, permission),
            );
            return;
          }
          if (kind == 'websocket' &&
              await _isRawMachineSocketUrl(payload['url'])) {
            _replyTransport(
              pluginId,
              requestId,
              bridgeToken,
              error: 'Plugins cannot open the raw machine socket on the host',
              code: 'machine_control_forbidden',
            );
            return;
          }
          final result = await _transportService.open(
            pluginId: pluginId,
            generation: generation,
            options: Map<String, dynamic>.from(payload),
            deviceRegistrationHandle: ownsDeviceConnect
                ? deviceRegistrationHandle
                : null,
            deviceInvocationId: ownsDeviceConnect ? deviceInvocationId : null,
          );
          if (!_isCurrentPluginMessage(pluginId, {'generation': generation})) {
            unawaited(
              _transportService
                  .close(pluginId, generation, result.handle)
                  .catchError((Object _) {}),
            );
            return;
          }
          _replyTransport(
            pluginId,
            requestId,
            bridgeToken,
            result: {
              'handle': result.handle,
              if (result.protocol != null) 'protocol': result.protocol,
            },
          );
        case 'send':
          final handle = payload['handle'];
          final sendPayload = payload['payload'];
          if (handle is! String || sendPayload is! Map) {
            _replyTransport(
              pluginId,
              requestId,
              bridgeToken,
              error: 'Invalid transport send message',
            );
            return;
          }
          await _transportService.send(
            pluginId,
            generation,
            handle,
            Map<String, dynamic>.from(sendPayload),
          );
          _replyTransport(pluginId, requestId, bridgeToken, result: const {});
        case 'close':
          final handle = payload['handle'];
          if (handle is! String) {
            _replyTransport(
              pluginId,
              requestId,
              bridgeToken,
              error: 'Invalid transport close message',
            );
            return;
          }
          await _transportService.close(pluginId, generation, handle);
          _replyTransport(pluginId, requestId, bridgeToken, result: const {});
        case 'onEvent':
          final handle = payload['handle'];
          if (handle is String) {
            try {
              _transportService.onEventRegistered(pluginId, generation, handle);
            } on PluginTransportException {
              _removeTransportListener(pluginId, handle);
            }
          }
        default:
          _log.warning('Unknown transport message type from $pluginId: $type');
      }
    } on PluginTransportException catch (e) {
      _replyTransport(
        pluginId,
        requestId,
        bridgeToken,
        error: e.message,
        code: e.code,
      );
    } on TlsPinMismatchException catch (e) {
      _replyTransport(
        pluginId,
        requestId,
        bridgeToken,
        error: e.toString(),
        code: TlsPinMismatchException.code,
        peerSha256: e.peerSha256,
      );
    } catch (e) {
      _replyTransport(pluginId, requestId, bridgeToken, error: e.toString());
    }
  }

  void _replyTransport(
    String pluginId,
    String requestId,
    Object? bridgeToken, {
    Map<String, dynamic>? result,
    String? error,
    String? code,
    String? peerSha256,
  }) {
    try {
      _realmOf(pluginId)?.evaluate(
        'globalThis.__handleTransportReply('
        '${jsonEncode({'requestId': requestId, 'bridgeToken': ?bridgeToken, 'result': result, 'error': error, 'code': code, 'peerSha256': ?peerSha256})});',
      );
    } catch (e, st) {
      _log.warning('Failed to deliver transport reply', e, st);
    }
  }

  void _dispatchTransportEvent(
    String pluginId,
    int generation,
    String handle,
    Map<String, dynamic> event,
  ) {
    if (_lifecycle != PluginManagerLifecycle.active) return;
    if (_plugins[pluginId]?.isAlive != true) return;
    if (_pluginGenerations[pluginId] != generation) return;
    try {
      _logPluginError(
        pluginId,
        'transport listener',
        _realmOf(pluginId, generation)?.evaluate(
          'globalThis.__dispatchTransportEvent('
          '${jsonEncode(pluginId)}, ${jsonEncode(handle)}, ${jsonEncode(event)});',
        ),
      );
      if (event['type'] == 'close') {
        _removeTransportListener(pluginId, handle);
      }
    } catch (e, st) {
      _log.warning('Failed to dispatch transport event to $pluginId', e, st);
    }
  }

  void _removeTransportListener(String pluginId, String handle) {
    try {
      _realmOf(pluginId)?.evaluate(
        'globalThis.__transportRemoveListener(${jsonEncode(handle)});',
      );
    } catch (e, st) {
      _log.warning('Failed to remove transport listener', e, st);
    }
  }

  bool _isDeviceDisconnectCleanup(String pluginId, int generation) =>
      (_lifecycle == PluginManagerLifecycle.active ||
          _lifecycle == PluginManagerLifecycle.disposing) &&
      _deviceDisconnectCleanup.contains((pluginId, generation));

  int? _messageGeneration(String pluginId, Map<String, dynamic> msg) {
    final generation = msg['generation'];
    if (generation is num) return generation.toInt();
    final bridgeToken = msg['bridgeToken'];
    if (bridgeToken is! String ||
        _realms[pluginId]?.bridgeToken != bridgeToken) {
      return null;
    }
    return _retiringPluginGenerations[pluginId] ?? _pluginGenerations[pluginId];
  }

  bool _isCurrentPluginMessage(String pluginId, Map<String, dynamic> msg) {
    return _messageGeneration(pluginId, msg) == _pluginGenerations[pluginId] &&
        _plugins[pluginId]?.isAlive == true;
  }

  bool _isRetiringPluginStorageWrite(
    String pluginId,
    Map<String, dynamic> msg,
  ) {
    final payload = msg['payload'];
    return msg['type'] == 'pluginStorage' &&
        _messageGeneration(pluginId, msg) ==
            _retiringPluginGenerations[pluginId] &&
        payload is Map &&
        payload['type'] == 'write' &&
        _plugins[pluginId]?.state == PluginRuntimeState.stopping;
  }

  void _trackPluginStorageOperation(
    String pluginId,
    int generation,
    Future<void> operation,
  ) {
    final key = (pluginId, generation);
    final operations = _pluginStorageOperations.putIfAbsent(key, () => {});
    operations.add(operation);
    unawaited(
      operation.whenComplete(() {
        operations.remove(operation);
        if (operations.isEmpty) _pluginStorageOperations.remove(key);
      }),
    );
  }

  Future<void> _drainPluginStorageOperations(
    String pluginId,
    int generation,
  ) async {
    final key = (pluginId, generation);
    while (true) {
      final operations = _pluginStorageOperations[key]?.toList() ?? const [];
      if (operations.isEmpty) return;
      await Future.wait(operations);
    }
  }

  Future<void> loadPlugin({
    required String id,
    required PluginManifest manifest,
    required String jsCode,
    required Map<String, dynamic> settings,
  }) async {
    _ensureActive();
    await _unloadPlugin(id);
    _ensureActive();
    while (_plugins.containsKey(id) || _realms.containsKey(id)) {
      await _unloadPlugin(id);
      _ensureActive();
    }
    final generation = (_pluginGenerations[id] ?? 0) + 1;
    _pluginGenerations[id] = generation;
    final realm = _createRealm(id, generation);
    final pluginBridgeToken = realm.bridgeToken;

    final runtime = PluginRuntime(pluginId: id, manifest: manifest);
    _pluginLogSecrets[id] = [
      for (final key in manifest.secureSettingKeys)
        if (settings[key] case final String value) value,
    ];

    _plugins[id] = runtime;
    _realms[id] = realm;
    if (manifest.permissions.contains(PluginPermissions.manageExtensions)) {
      _extensionGrants[id] = _PluginExtensionGrant(this, runtime, generation);
    }

    try {
      final wrapperCode =
          '''
      (function () {
        const pluginId = "$id";
        const pluginGeneration = $generation;
        const pluginBridgeToken = ${jsonEncode(pluginBridgeToken)};
        const pluginHostBridge = globalThis.__reaprimePluginHostBridge;
        class PluginPermissionError extends Error {
          constructor(permission) {
            super("Plugin " + pluginId + " requires manifest permission " + permission);
            this.name = "PluginPermissionError";
          }
        }
        const requirePermission = (permission) => {
          pluginHostBridge.permissionDenied(pluginBridgeToken, pluginGeneration, permission);
          throw new PluginPermissionError(permission);
        };
        const rejectPermission = (permission) => {
          pluginHostBridge.permissionDenied(pluginBridgeToken, pluginGeneration, permission);
          return Promise.reject(new PluginPermissionError(permission));
        };
        const setTimeout = (callback, delay) => pluginHostBridge.timerSet(pluginBridgeToken, pluginGeneration, callback, delay);
        const clearTimeout = (id) => pluginHostBridge.timerClear(pluginBridgeToken, id);
        const fetch = ${manifest.permissions.contains(PluginPermissions.api)}
          ? (input, init) => pluginHostBridge.fetch(pluginBridgeToken, pluginGeneration, input, init)
          : () => rejectPermission("api");
        
        let __transportSeq = 0;
        const __transportNonce = Math.random().toString(36).slice(2);
        const __transportCall = (type, payload, deviceConnect) => {
          return new Promise((resolve, reject) => {
            const requestId = pluginId + "_" + pluginGeneration + "_" + __transportNonce + "_" + (++__transportSeq);
            __transportRegister(requestId, { bridgeToken: pluginBridgeToken, resolve: resolve, reject: reject });
            pluginHostBridge.transportRequest(
              pluginBridgeToken,
              pluginGeneration,
              requestId,
              type,
              payload,
              deviceConnect && deviceConnect.registrationHandle,
              deviceConnect && deviceConnect.invocationId
            );
          });
        };
        const __transportOpen = (options, deviceConnect) => {
          const kind = options && options.kind;
          if (kind === "websocket" && !${manifest.permissions.contains(PluginPermissions.networkWebsocket)}) {
            return rejectPermission("network.websocket");
          }
          if (kind === "tcp" && !${manifest.permissions.contains(PluginPermissions.networkTcp)}) {
            return rejectPermission("network.tcp");
          }
          if (kind === "tls" && !${manifest.permissions.contains(PluginPermissions.networkTls)}) {
            return rejectPermission("network.tls");
          }
          if (kind !== "websocket" && kind !== "tcp" && kind !== "tls") {
            return Promise.reject(new Error("transport.open: unknown transport kind"));
          }
          return __transportCall("open", options || {}, deviceConnect);
        };
        const __transportOnEvent = (handle, callback) => {
          if (typeof callback !== "function") {
            throw new Error("transport.onEvent: callback must be a function");
          }
          __transportSetListener(handle, pluginId, callback);
          pluginHostBridge.transportRequest(
            pluginBridgeToken, pluginGeneration, "onEvent_" + (++__transportSeq), "onEvent", { handle: handle }
          );
        };
        const __transportSend = (handle, payload) =>
          __transportCall("send", { handle: handle, payload: payload });
        const __transportClose = (handle) =>
          __transportCall("close", { handle: handle });
        const transport = {
          open(options) { return __transportOpen(options, null); },
          onEvent: __transportOnEvent,
          send: __transportSend,
          close: __transportClose
        };
        const __connectTransport = (registrationHandle, invocationId) => Object.freeze({
          open(options) {
            return __transportOpen(options, {
              registrationHandle: registrationHandle,
              invocationId: invocationId
            });
          },
          onEvent: __transportOnEvent,
          send: __transportSend,
          close: __transportClose
        });

        let __deviceSeq = 0;
        const __deviceNonce = Math.random().toString(36).slice(2);
        const __deviceCall = (type, payload) => {
          return new Promise((resolve, reject) => {
            const requestId = pluginId + "_device_" + pluginGeneration + "_" + __deviceNonce + "_" + (++__deviceSeq);
            __deviceRegisterPending(requestId, { bridgeToken: pluginBridgeToken, resolve: resolve, reject: reject });
            pluginHostBridge.deviceRequest(pluginBridgeToken, pluginGeneration, requestId, type, payload);
          });
        };
        const declaredDrivers = ${jsonEncode(manifest.drivers.map((driver) => driver.toJson()).toList())};
        $pluginBleBridgeJs
        const devices = {
          bindDriver: ${manifest.permissions.contains(PluginPermissions.transportBle)}
            ? __bindBleDriver
            : () => rejectPermission("transport.ble"),
          register(definition, handlers) {
            const driver = definition && declaredDrivers.find((entry) => entry.id === definition.driverId);
            if (!driver || !["sensor", "scale", "grinder"].includes(driver.type)) {
              return Promise.reject(new Error("Device driver is not declared by this plugin"));
            }
            if (!handlers || typeof handlers.connect !== "function" ||
                typeof handlers.disconnect !== "function" ||
                (driver.type === "sensor" && typeof handlers.execute !== "function")) {
              return Promise.reject(new Error("Device handlers connect, disconnect, and execute are required"));
            }
            const registrationHandle = "device_" + pluginGeneration + "_" + __deviceNonce + "_" + (++__deviceSeq);
            let retired = false;
            const sessionCall = (type, payload) => retired
              ? Promise.reject(Object.assign(new Error('Device session retired'), {code: 'stale_session'}))
              : __deviceCall(type, payload);
            __deviceSetHandlers(registrationHandle, {
              pluginId: pluginId,
              generation: pluginGeneration,
              bridgeToken: pluginBridgeToken,
              handlers: handlers,
              dispose: () => { retired = true; },
              connectTransport: (invocationId, payload) => {
                const transport = __connectTransport(registrationHandle, invocationId);
                if (driver.type === "sensor") return transport;
                const session = payload.session;
                return Object.freeze({
                  transport: transport,
                  publish(snapshot) {
                    return sessionCall("publish", {
                      registrationHandle: registrationHandle, session: session, snapshot: snapshot
                    });
                  },
                  publishInfo(info) {
                    return sessionCall("publishInfo", {
                      registrationHandle: registrationHandle, session: session, info: info
                    });
                  },
                  reportDisconnected() {
                    return sessionCall("reportDisconnected", {
                      registrationHandle: registrationHandle, session: session
                    });
                  }
                });
              }
            });
            return __deviceCall("register", {
              registrationHandle: registrationHandle,
              definition: definition
            }).then(
              (result) => {
                const device = {
                  deviceId: result.deviceId,
                  publish(snapshot) {
                    return __deviceCall("publish", {
                      registrationHandle: registrationHandle,
                      snapshot: snapshot
                    });
                  },
                  reportDisconnected() {
                    return __deviceCall("reportDisconnected", {
                      registrationHandle: registrationHandle
                    });
                  },
                  unregister() {
                    return __deviceCall("unregister", {
                      registrationHandle: registrationHandle
                    }).then(
                      () => __deviceRemoveHandlers(registrationHandle),
                      (error) => {
                        __deviceRemoveHandlers(registrationHandle);
                        throw error;
                      }
                    );
                  }
                };
                if (driver.type === "scale" || driver.type === "grinder") {
                  delete device.publish;
                  delete device.reportDisconnected;
                }
                return Object.freeze(device);
              },
              (error) => {
                __deviceRemoveHandlers(registrationHandle);
                throw error;
              }
            );
          }
        };
        
        // Create the host object for this plugin
        const host = {
          log: ${manifest.permissions.contains(PluginPermissions.log)}
            ? (msg) => pluginHostBridge.log(pluginBridgeToken, pluginGeneration, msg)
            : () => requirePermission("log"),
          emit: ${manifest.permissions.contains(PluginPermissions.emit)}
            ? (type, payload) => pluginHostBridge.emit(pluginBridgeToken, pluginGeneration, type, payload)
            : () => requirePermission("emit"),
          notify: ${manifest.permissions.contains(PluginPermissions.notifications)}
            ? (notice) => pluginHostBridge.notify(pluginBridgeToken, pluginGeneration, notice)
            : () => requirePermission("notifications"),
          dismissNotification: ${manifest.permissions.contains(PluginPermissions.notifications)}
            ? (id) => pluginHostBridge.dismissNotification(pluginBridgeToken, pluginGeneration, id)
            : () => requirePermission("notifications"),
          storage: ${manifest.permissions.contains(PluginPermissions.pluginStorage)}
            ? (cmd) => pluginHostBridge.storage(pluginBridgeToken, pluginGeneration, cmd)
            : () => requirePermission("pluginStorage"),
          decentProxy: (path, options = {}) => {
            const method = String(options.method || "GET").toUpperCase();
            if (method === "GET" && !${manifest.permissions.contains(PluginPermissions.proxyDecentApi)}) {
              return rejectPermission("proxy.decent_api");
            }
            if (method === "POST" && !${manifest.permissions.contains(PluginPermissions.proxyDecentApiWrite)}) {
              return rejectPermission("proxy.decent_api.write");
            }
            if (options.gzip !== undefined && typeof options.gzip !== "boolean") {
              return Promise.reject(new TypeError("gzip must be a boolean"));
            }
            return globalThis.__reaprimePluginBridge.decentProxy(
              pluginId,
              pluginGeneration,
              pluginBridgeToken,
              path,
              options.method || "GET",
              options.query || {},
              options.body ?? null,
              options.contentType ?? null,
              options.gzip === undefined ? false : options.gzip
            );
          },
          localApi: (path, options = {}) => {
            if (!${manifest.permissions.contains(PluginPermissions.manageExtensions)}) {
              return rejectPermission("manage.extensions");
            }
            return globalThis.__reaprimePluginBridge.localApi(
              pluginId,
              pluginGeneration,
              pluginBridgeToken,
              path,
              options.method || "GET",
              options.body ?? null,
              options.contentType ?? null
            );
          },
          transport: transport,
          devices: devices,
          discovery: Object.freeze({
            browse: (options = {}) =>
              globalThis.__reaprimePluginBridge.discoveryBrowse(
                pluginId,
                pluginGeneration,
                pluginBridgeToken,
                options
              )
          })
        };
        
        // Inject and evaluate the plugin code
        $jsCode
        
        // The plugin must export a function named 'createPlugin'
        if (typeof createPlugin !== 'function') {
          throw new Error("Plugin must export a 'createPlugin' function. Got: " + typeof createPlugin);
        }
        
        // Call the factory function with the host object
        const plugin = createPlugin(host);
        
        if (!plugin || typeof plugin !== "object") {
          throw new Error("createPlugin did not return an object, got: " + typeof plugin);
        }
        
        // Verify the plugin has the required id
        if (plugin.id !== pluginId) {
          throw new Error("Plugin ID mismatch. Expected: " + pluginId + ", Got: " + plugin.id);
        }
        
        // Store the plugin object
        globalThis.__registerPlugin(plugin);
        
        // Add HTTP API handler if the plugin defines one
        if (typeof plugin.handleHttpRequest === "function") {
          // Register HTTP request handler
          plugin.__httpRequestHandler = plugin.handleHttpRequest;
        }
        
        // Call onLoad if it exists
        if (typeof plugin.onLoad === "function") {
          plugin.onLoad(${jsonEncode(settings)});
        }
        
        return plugin;
      })();
    ''';

      final result = realm.js.evaluate(wrapperCode);
      _log.fine("Plugin evaluation result: ${result.stringResult}");
      _log.fine("Is error: ${result.isError}");

      if (result.isError) {
        throw Exception("JS evaluation error: ${result.stringResult}");
      }
      while (realm.js.executePendingJob() > 0) {}

      runtime.markRunning();
      while (_bleRegistrations[id]?.isNotEmpty == true) {
        await Future.wait(_bleRegistrations[id]!.toList());
      }
      if (identical(_plugins[id], runtime) &&
          generation == _pluginGenerations[id]) {
        final workflowController = _workflowController;
        if (workflowController != null) {
          dispatchEvent(
            id,
            'workflowUpdated',
            workflowController.currentWorkflow.toJson(),
          );
        }
        if (!manifest.permissions.contains(PluginPermissions.notifications)) {
          await notifications.removeSource(NotificationNamespace.plugin, id);
        }
      }
      _log.info("loaded: $id");
    } catch (e, st) {
      try {
        if (identical(_plugins[id], runtime) && identical(_realms[id], realm)) {
          await _unloadPlugin(id);
        }
      } catch (cleanupError, cleanupStackTrace) {
        _log.warning(
          'Failed to clean up plugin after load failure: $id',
          cleanupError,
          cleanupStackTrace,
        );
      }
      _log.warning("Failed to load plugin $id", e, st);
      rethrow;
    }
  }

  Future<void> unloadPlugin(
    String id, {
    bool preserveNotifications = false,
  }) async {
    _ensureActive();
    await _unloadPlugin(id);
    if (!preserveNotifications) {
      await notifications.removeSource(NotificationNamespace.plugin, id);
    }
  }

  void _writePluginLog(
    String pluginId,
    String message, {
    Level level = Level.INFO,
    Map<String, PluginLogLimiter>? limiters,
  }) {
    final admission =
        ((limiters ?? _pluginLogLimiters)[pluginId] ??= PluginLogLimiter())
            .admit();
    _logSuppressedPluginLines(pluginId, admission.suppressed);
    if (!admission.write) return;
    _log.log(
      level,
      '[JS:$pluginId] '
      '${redactPluginLog(message, _pluginLogSecrets[pluginId] ?? const [])}',
    );
  }

  void _logSuppressedPluginLines(String pluginId, int suppressed) {
    if (suppressed == 0) return;
    _log.info('[JS:$pluginId] suppressed $suppressed plugin log lines');
  }

  Future<void> _unloadPlugin(String id) async {
    _logSuppressedPluginLines(id, _pluginLogLimiters.remove(id)?.drain() ?? 0);
    _logSuppressedPluginLines(
      id,
      _pluginErrorLimiters.remove(id)?.drain() ?? 0,
    );
    _pluginLogSecrets.remove(id);
    notifications.retireSource(NotificationNamespace.plugin, id);
    _loggedPermissionDenials.removeWhere((denial) => denial.startsWith('$id:'));
    final realm = _realms[id];
    final pluginBridgeToken = realm?.bridgeToken;
    final runtime = _plugins[id];
    if (runtime == null) {
      if (realm != null) _disposeRealm(realm);
      return;
    }
    _closingPluginPermissions[id] = runtime.manifest.permissions;
    _extensionGrants.remove(id);

    final retiringGeneration = _pluginGenerations[id] ?? 0;
    runtime.markStopping();
    _retiringPluginGenerations[id] = retiringGeneration;
    _pluginGenerations[id] = retiringGeneration + 1;

    try {
      try {
        final result = realm?.evaluate('globalThis.__unregisterPlugin();');
        if (result != null && result.isError) {
          _log.warning('Plugin onUnload failed: $id: ${result.stringResult}');
        }
      } catch (e, st) {
        _log.warning("Error during plugin unload: $id", e, st);
      }
      try {
        await _cleanupPluginResources(
          id,
          pluginBridgeToken,
          retiringGeneration,
        );
      } finally {
        await _drainPluginStorageOperations(id, retiringGeneration);
      }
    } finally {
      _retiringPluginGenerations.remove(id);
      runtime.markDisposed();
      _plugins.remove(id);
      _closingPluginPermissions.remove(id);
      _deviceConnectAttempts.removeWhere(
        (_, attempt) =>
            attempt.pluginId == id && attempt.generation == retiringGeneration,
      );
      _timedOutDeviceConnects.removeWhere(
        (key, _) => key.$1 == id && key.$2 == retiringGeneration,
      );
      if (realm != null) _disposeRealm(realm);
      _log.info("unloaded: $id");
    }
  }

  Future<void> _cleanupPluginResources(
    String pluginId,
    String? pluginBridgeToken,
    int retiringGeneration,
  ) async {
    Object? firstError;
    StackTrace? firstStackTrace;

    void attempt(void Function() action) {
      try {
        action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    attempt(() => _rejectOpsForPlugin(pluginId));
    attempt(() {
      _realmOf(pluginId, retiringGeneration)?.evaluate('''
        globalThis.__cancelFetchesForBridgeToken(
          ${jsonEncode(pluginBridgeToken)}, "plugin unloaded"
        );
        globalThis.__reaprimePluginBridge.cancelForPlugin(
          ${jsonEncode(pluginId)}, "plugin unloaded"
        );
        globalThis.__rejectTransportPendingForToken(
          ${jsonEncode(pluginBridgeToken)}, "plugin unloaded"
        );
        globalThis.__clearTransportListenersForPlugin(
          ${jsonEncode(pluginId)}
        );
        globalThis.__rejectDevicePendingForToken(
          ${jsonEncode(pluginBridgeToken)}, "plugin unloaded"
        );
      ''');
    });
    attempt(() => _cancelTimersForPlugin(pluginId, pluginBridgeToken));
    attempt(
      () => _rejectDeviceInvocations(
        pluginId,
        retiringGeneration,
        'Plugin unloaded',
        excludeOperations: const {PluginDeviceOperation.connect},
      ),
    );
    _deviceDisconnectCleanup.add((pluginId, retiringGeneration));
    try {
      try {
        await bleService.removeGeneration(pluginId, retiringGeneration);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
      await deviceService.removeAllForPlugin(
        pluginId,
        retiringGeneration,
        runDisconnect:
            _lifecycle == PluginManagerLifecycle.active ||
            _lifecycle == PluginManagerLifecycle.disposing,
      );
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    } finally {
      _deviceDisconnectCleanup.remove((pluginId, retiringGeneration));
    }
    attempt(() {
      _realmOf(pluginId, retiringGeneration)?.evaluate('''
        globalThis.__clearDeviceHandlersForPlugin(
          ${jsonEncode(pluginId)}
        );
      ''');
    });
    try {
      await _transportService.closeAllForPlugin(pluginId, retiringGeneration);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  void broadcastEvent(String name, dynamic payload) {
    _ensureActive();
    for (final plugin in _plugins.values) {
      if (plugin.isAlive) {
        dispatchEvent(plugin.pluginId, name, payload);
      }
    }
  }

  void dispatchEvent(String pluginId, String name, dynamic payload) {
    _ensureActive();
    final runtime = _plugins[pluginId];
    if (runtime?.isAlive != true) return;
    final generation = _pluginGenerations[pluginId] ?? 0;
    final permission = switch (name) {
      'stateUpdate' => PluginPermissions.eventsMachine,
      'shotStored' || 'shotUpdated' => PluginPermissions.eventsShots,
      'workflowUpdated' => PluginPermissions.eventsWorkflow,
      'decentAccountChanged' => PluginPermissions.proxyDecentApi,
      'notificationAction' ||
      'notificationResult' => PluginPermissions.notifications,
      _ => null,
    };
    if (permission != null && !_holdsPermission(pluginId, permission)) return;

    final requestIdValue = payload is Map<String, dynamic>
        ? payload['requestId']
        : null;
    final requestId = requestIdValue is String ? requestIdValue : null;
    final realm = _realmOf(pluginId, generation);
    if (realm == null) return;
    final httpDispatch = name == 'httpRequest' && requestId != null
        ? '''globalThis.__dispatchPluginHttp(
          ${jsonEncode(realm.bridgeToken)},
          $generation,
          ${jsonEncode(requestId)},
          ${jsonEncode(payload)}
        );'''
        : '';

    final result = realm.evaluate('''
    (function () {
      const error = globalThis.__dispatchToPlugin({
        name: ${jsonEncode(name)},
        payload: ${jsonEncode(payload)}
      });
      $httpDispatch
      return error;
    })();
  ''');
    _logPluginError(pluginId, 'onEvent($name)', result);
  }

  /// Host-side report of a plugin failure. Written whatever the plugin's
  /// `log` permission, with its own rate limit so plugin output cannot
  /// crowd it out.
  void _logPluginError(String pluginId, String where, JsEvalResult? result) {
    if (result == null) return;
    final text = result.stringResult;
    if (!result.isError && (text.isEmpty || text == 'undefined')) return;
    _writePluginLog(
      pluginId,
      'Plugin error in $where: $text',
      level: Level.WARNING,
      limiters: _pluginErrorLimiters,
    );
  }

  Future<void> _handleMessage(String pluginId, Map<String, dynamic> msg) async {
    _log.finest("handle message: ${_withoutBridgeToken(msg)}");
    final type = msg['type'];
    final payload = msg['payload'];

    switch (type) {
      case 'notification':
        final generation = _pluginGenerations[pluginId];
        void dispatchNotificationEvent(
          String name,
          Map<String, dynamic> event,
        ) {
          if (_lifecycle == PluginManagerLifecycle.active &&
              _pluginGenerations[pluginId] == generation) {
            dispatchEvent(pluginId, name, event);
          }
        }

        String? id;
        String? reason;
        try {
          if (payload is Map) id = notificationText(payload['id'], 128);
          final notice = parsePluginNotification(
            pluginId: pluginId,
            pluginName: _plugins[pluginId]!.manifest.name,
            payload: payload,
            canOpenAccount: _plugins[pluginId]!.manifest.permissions.contains(
              PluginPermissions.proxyDecentApi,
            ),
            manifest: _plugins[pluginId]!.manifest,
          );
          await notifications.publish(
            notice,
            binding: NotificationBinding(
              owner: (pluginId, generation),
              isAlive: () =>
                  _lifecycle == PluginManagerLifecycle.active &&
                  _pluginGenerations[pluginId] == generation &&
                  _plugins[pluginId]?.isAlive == true,
              onAction: (action, phase) => dispatchNotificationEvent(
                'notificationAction',
                {'id': notice.id, 'actionId': action.id, 'phase': phase},
              ),
            ),
          );
        } on NotificationCapacityException {
          reason = 'capacity';
        } on NotificationStorageException {
          reason = 'storage';
        } on FormatException {
          reason = 'validation';
        }
        dispatchNotificationEvent('notificationResult', {
          'requestId': msg['requestId'],
          'id': ?id,
          'status': reason == null ? 'accepted' : 'rejected',
          'reason': ?reason,
        });
        break;

      case 'notificationDismiss':
        if (payload == null || payload is String) {
          await notifications.removeSource(
            NotificationNamespace.plugin,
            pluginId,
            payload as String?,
          );
        }
        break;

      case 'emit':
        final Map<String, dynamic> eventData = {
          'pluginId': pluginId,
          'event': msg['event'],
          'payload': payload,
        };
        _log.finest("emitting: $eventData");
        _emitController.add(eventData);
        break;

      case 'pluginStorage':
        final cmd = PluginStorageCommand.fromPlugin(payload);
        final generation = _messageGeneration(pluginId, msg);
        if (generation == null) return;
        await _handlePluginStorage(pluginId, generation, cmd);
        break;

      case 'permissionDenied':
        final permission = payload is String
            ? PluginPermissions.fromString(payload)
            : null;
        if (permission != null) _hasPermission(pluginId, permission);
        break;

      case 'timerSet':
        _setTimer(
          pluginId,
          msg['generation'] is num ? (msg['generation'] as num).toInt() : 0,
          (msg['timerId'] as num?)?.toInt() ?? 0,
          (msg['delay'] as num?)?.toInt() ?? 0,
        );
        break;

      case 'timerClear':
        _clearTimer(
          pluginId,
          msg['generation'] is num ? (msg['generation'] as num).toInt() : 0,
          (msg['timerId'] as num?)?.toInt() ?? 0,
        );
        break;

      case 'decentProxy':
        await _handleDecentProxyMessage(pluginId, msg);
        break;
    }
  }

  final Map<(String, int, int), ({String pluginId, Timer timer})> _timers = {};

  int get activeTimerCount => _timers.length;

  Map<String, int> get activeTimersByPlugin {
    final counts = <String, int>{};
    for (final record in _timers.values) {
      counts[record.pluginId] = (counts[record.pluginId] ?? 0) + 1;
    }
    return counts;
  }

  void _setTimer(String pluginId, int generation, int id, int delayMs) {
    if (!_plugins.containsKey(pluginId)) return;
    if (generation != (_pluginGenerations[pluginId] ?? 0)) return;
    final key = (pluginId, generation, id);
    _timers[key]?.timer.cancel();
    late final Timer timer;
    timer = Timer(Duration(milliseconds: delayMs < 0 ? 0 : delayMs), () {
      _fireTimer(pluginId, generation, id, timer);
    });
    _timers[key] = (pluginId: pluginId, timer: timer);
  }

  void _clearTimer(String pluginId, int generation, int id) {
    _timers.remove((pluginId, generation, id))?.timer.cancel();
  }

  void _fireTimer(String pluginId, int generation, int id, Timer timer) {
    final key = (pluginId, generation, id);
    if (!identical(_timers[key]?.timer, timer)) return;
    _timers.remove(key);
    if (_lifecycle != PluginManagerLifecycle.active) return;
    _realmOf(pluginId, generation)?.evaluate('globalThis.__fireTimer($id);');
  }

  void _cancelTimersForPlugin(String pluginId, String? pluginBridgeToken) {
    _timers.removeWhere((key, record) {
      if (record.pluginId == pluginId) {
        record.timer.cancel();
        return true;
      }
      return false;
    });
    if (pluginBridgeToken != null) {
      _realmOf(pluginId)?.evaluate(
        'globalThis.__cancelTimersForBridgeToken('
        '${jsonEncode(pluginBridgeToken)});',
      );
    }
  }

  void cancelAllOperations() {
    _ensureActive();
    unawaited(
      _cancelAllOperations().catchError((Object error, StackTrace stackTrace) {
        _log.warning('cancelAllOperations failed', error, stackTrace);
      }),
    );
  }

  Future<void> _cancelAllOperations() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    void attempt(void Function() action) {
      try {
        action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    for (final op in _pendingOps.values.toList()) {
      attempt(() {
        _completeOp(op, error: 'manager disposal');
      });
    }
    attempt(() {
      _httpClient?.close(force: true);
      _httpClient = null;
    });
    for (final realm in _realms.values.toList()) {
      attempt(() {
        realm.evaluate('''
          globalThis.__cancelAllFetches("manager disposal");
          globalThis.__reaprimePluginBridge.cancelAll("manager disposal");
          globalThis.__rejectAllTransportPending("manager disposal");
          globalThis.__clearAllTransportListeners();
          globalThis.__rejectAllDevicePending("manager disposal");
          globalThis.__clearAllDeviceHandlers();
        ''');
      });
    }
    for (final record in _timers.values) {
      record.timer.cancel();
    }
    _timers.clear();
    for (final realm in _realms.values.toList()) {
      attempt(() {
        realm.evaluate('globalThis.__cancelAllTimers();');
      });
    }
    try {
      await _transportService.dispose();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await bleService.dispose();
      await deviceService.dispose();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  final Map<String, _PendingOp> _pendingOps = {};
  final Map<String, int> _pluginGenerations = {};
  HttpClient? _httpClient;

  int get activePendingOpCount => _pendingOps.length;

  Map<String, int> get activePendingOpsByType {
    final counts = <String, int>{};
    for (final op in _pendingOps.values) {
      counts[op.kind.name] = (counts[op.kind.name] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, int> get activePendingOpsByPlugin {
    final counts = <String, int>{};
    for (final op in _pendingOps.values) {
      counts[op.pluginId] = (counts[op.pluginId] ?? 0) + 1;
    }
    return counts;
  }

  static final _machineControlGrantPath = RegExp(
    r'^/api/v1/plugins/[^/]+/machine-control/?$',
  );

  /// The error a plugin `fetch` gets instead of reaching a machine-control
  /// route on the host API, or null when the request may go out.
  Future<Map<String, String>?> _hostApiFetchRefusal(
    String pluginId,
    String method,
    Uri uri,
    HttpConnectionInfo? peer,
  ) async {
    final path = _routePath(uri);
    final write = method != 'GET' && method != 'HEAD';
    final rawSocket = path.startsWith('/ws/v1/machine/raw');
    final grantRoute = write && _machineControlGrantPath.hasMatch(path);
    final machineWrite =
        write &&
        (path == '/api/v1/machine' || path.startsWith('/api/v1/machine/'));
    if (!rawSocket && !grantRoute && !machineWrite) return null;
    if (peer != null &&
        !await _isHostApiPeer(peer.remoteAddress, peer.remotePort)) {
      return null;
    }
    if (rawSocket) {
      return {
        'error': 'Plugins cannot open the raw machine socket on the host',
        'code': 'machine_control_forbidden',
      };
    }
    if (grantRoute) {
      return {
        'error': 'Plugins cannot change machine-control grants',
        'code': 'machine_control_forbidden',
      };
    }
    if (path.startsWith('/api/v1/machine/firmware')) {
      return {
        'error': 'Plugins cannot update machine firmware',
        'code': 'machine_control_forbidden',
      };
    }
    if (machineControlGranted(pluginId)) return null;
    _askForMachineControl(pluginId);
    return {
      'error':
          'Plugin $pluginId is not allowed to control the machine; the user '
          'can allow it in Settings > Plugins',
      'code': 'machine_control_not_granted',
    };
  }

  void _askForMachineControl(String pluginId) {
    final name = _plugins[pluginId]?.manifest.name ?? pluginId;
    unawaited(
      notifications
          .publish(
            NativeNotification(
              namespace: NotificationNamespace.plugin,
              sourceId: pluginId,
              sourceName: name,
              id: machineControlNoticeId,
              message:
                  'Allow $name to control the machine? It tried to change the '
                  'machine state. Allow it in Settings > Plugins > $name.',
              actions: const [
                NotificationAction(
                  id: 'review',
                  label: 'Review',
                  type: NotificationActionType.reviewMachineControl,
                ),
              ],
            ),
            binding: NotificationBinding(
              owner: (machineControlNoticeId, pluginId),
              isAlive: () => _lifecycle == PluginManagerLifecycle.active,
            ),
          )
          .catchError(
            (Object error) =>
                _log.fine('Could not ask for machine control: $error'),
          ),
    );
  }

  Future<bool> _isRawMachineSocketUrl(Object? url) async {
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null ||
        uri.scheme.toLowerCase() != 'ws' ||
        uri.port != hostApiPort ||
        !_routePath(uri).startsWith('/ws/v1/machine/raw')) {
      return false;
    }
    // A WebSocket gives no peer to check before its upgrade is sent, and a
    // host name may resolve elsewhere when checked than when connecting, so
    // only another device's numeric address is let through.
    final literal = InternetAddress.tryParse(uri.host);
    return literal == null || await _isHostApiPeer(literal, uri.port);
  }

  Future<T> _refuseHostApiSocket<T extends Socket>(T socket) async {
    if (await _isHostApiPeer(socket.remoteAddress, socket.remotePort)) {
      socket.destroy();
      throw const PluginTransportException(
        'Plugins cannot open raw connections to the host API',
        code: 'machine_control_forbidden',
      );
    }
    return socket;
  }

  /// Lower-cased, percent-decoded path with dot segments and repeated
  /// slashes removed, so spelling variants of a route compare equal.
  static String _routePath(Uri uri) {
    var path = uri.path;
    try {
      path = Uri.decodeFull(path);
    } on ArgumentError {
      // Keep the raw path; the server will not route it either.
    }
    path = path.replaceAll(RegExp('/+'), '/');
    return Uri(path: path).normalizePath().path.toLowerCase();
  }

  /// Whether [address]:[port] is this device's own API: the API port on
  /// loopback, the unspecified address or one of this device's interfaces.
  Future<bool> _isHostApiPeer(InternetAddress address, int port) async {
    if (port != hostApiPort) return false;
    var raw = address.rawAddress;
    if (raw.length == 16 &&
        raw.take(10).every((byte) => byte == 0) &&
        raw[10] == 0xff &&
        raw[11] == 0xff) {
      raw = raw.sublist(12);
      address = InternetAddress.fromRawAddress(raw);
    }
    if (address.isLoopback || raw.every((byte) => byte == 0)) return true;
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        includeLinkLocal: true,
      );
      return interfaces.any(
        (interface) => interface.addresses.any(
          (own) => own.rawAddress.join('.') == raw.join('.'),
        ),
      );
    } catch (error) {
      _log.fine('Could not list network interfaces: $error');
      return true;
    }
  }

  HttpClient _getHttpClient() {
    return _httpClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
  }

  void _rejectOpsForPlugin(String pluginId) {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final op
        in _pendingOps.values.where((op) => op.pluginId == pluginId).toList()) {
      try {
        _completeOp(op, error: 'plugin unloaded');
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  void _completeOp(
    _PendingOp op, {
    Map<String, dynamic>? result,
    String? error,
    String? errorCode,
    String? peerSha256,
  }) {
    op.timeout?.cancel();
    if (!identical(_pendingOps[op.key], op)) return;
    _pendingOps.remove(op.key);
    final payload = error != null
        ? {'error': error, 'code': ?errorCode}
        : result;
    switch (op.kind) {
      case _PendingOpKind.fetch:
        if (error != null) {
          try {
            op.request?.abort();
          } catch (_) {}
        }
        final fetchPayload = error != null
            ? {
                'id': int.parse(op.requestId),
                'error': error,
                'code': ?errorCode,
                'peerSha256': ?peerSha256,
              }
            : result;
        _realmOf(op.pluginId, op.generation)?.evaluate(
          'globalThis.__handleFetchResponse(${jsonEncode(fetchPayload)});',
        );
      case _PendingOpKind.pluginHttp:
        final completer = op.completer;
        if (completer == null || completer.isCompleted) return;
        if (error != null) {
          completer.completeError(PluginHttpError(error));
        } else {
          completer.complete(result);
        }
      case _PendingOpKind.decentProxy ||
          _PendingOpKind.localApi ||
          _PendingOpKind.discovery:
        _realmOf(op.pluginId, op.generation)?.evaluate(
          'globalThis.__reaprimePluginBridge.completeDecentProxyRequest('
          '${jsonEncode(op.pluginId)}, ${jsonEncode(op.requestId)}, '
          '${jsonEncode(payload)});',
        );
    }
  }

  Future<void> _handleDecentProxyMessage(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    final requestId = msg['requestId'] as String?;
    if (requestId == null) {
      _log.warning('Decent proxy message from $pluginId missing requestId');
      return;
    }
    final generation = msg['generation'] is num
        ? (msg['generation'] as num).toInt()
        : 0;
    if (msg['bridgeToken'] != _realms[pluginId]?.bridgeToken) {
      _log.warning('Decent proxy message from $pluginId has invalid token');
      final op = _PendingOp(
        kind: _PendingOpKind.decentProxy,
        pluginId: pluginId,
        generation: generation,
        requestId: requestId,
      );
      _pendingOps[op.key] = op;
      _completeOp(op, error: 'Invalid plugin proxy caller');
      return;
    }

    if (generation != _pluginGenerations[pluginId] ||
        _plugins[pluginId]?.isAlive != true) {
      final op = _PendingOp(
        kind: _PendingOpKind.decentProxy,
        pluginId: pluginId,
        generation: generation,
        requestId: requestId,
      );
      _pendingOps[op.key] = op;
      _completeOp(op, error: 'Plugin generation changed');
      return;
    }

    final op = _PendingOp(
      kind: _PendingOpKind.decentProxy,
      pluginId: pluginId,
      generation: generation,
      requestId: requestId,
    );
    op.timeout = Timer(decentProxyTimeout, () {
      _completeOp(op, error: 'Decent proxy request timed out');
    });
    _pendingOps[op.key] = op;

    try {
      final response = await proxyDecentApiForManifest(
        pluginId: pluginId,
        manifest: _plugins[pluginId]?.manifest,
        path: msg['path'] as String?,
        method: (msg['method'] as String?) ?? 'GET',
        query: _stringMap(msg['query']),
        body: msg['body'] as String?,
        contentType: msg['contentType'] as String?,
        gzipBody: msg.containsKey('gzip') ? msg['gzip'] as bool : false,
      );
      _completeOp(op, result: response);
    } on DecentProxyConsentDeniedException catch (e) {
      _completeOp(
        op,
        error: e.toString(),
        errorCode: DecentProxyConsentDeniedException.code,
      );
    } on DecentAccountAuthInvalidException catch (e) {
      _completeOp(
        op,
        error: e.toString(),
        errorCode: 'account_authentication_required',
      );
    } on DecentAccountNotLinkedException catch (e) {
      _completeOp(
        op,
        error: e.toString(),
        errorCode: 'account_authentication_required',
      );
    } catch (e) {
      _completeOp(op, error: e.toString());
    }
  }

  Future<void> _handleLocalApiMessage(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    final requestId = msg['requestId'] as String?;
    if (requestId == null) {
      _log.warning('Local API message from $pluginId missing requestId');
      return;
    }
    final generation = msg['generation'] is num
        ? (msg['generation'] as num).toInt()
        : 0;
    final op = _PendingOp(
      kind: _PendingOpKind.localApi,
      pluginId: pluginId,
      generation: generation,
      requestId: requestId,
    );
    if (_pendingOps.containsKey(op.key)) {
      _log.warning('Local API message from $pluginId reuses a request id');
      return;
    }
    _pendingOps[op.key] = op;

    if (msg['bridgeToken'] != _realms[pluginId]?.bridgeToken) {
      _log.warning('Local API message from $pluginId has invalid token');
      _completeOp(op, error: 'Invalid plugin local API caller');
      return;
    }
    if (generation != _pluginGenerations[pluginId] ||
        _plugins[pluginId]?.isAlive != true) {
      _completeOp(op, error: 'Plugin generation changed');
      return;
    }
    final grant = _extensionGrants[pluginId];
    if (!_hasPermission(pluginId, PluginPermissions.manageExtensions) ||
        grant == null ||
        !grant.isActive) {
      _completeOp(
        op,
        error: _permissionError(pluginId, PluginPermissions.manageExtensions),
      );
      return;
    }

    op.timeout = Timer(localApiTimeout, () {
      _completeOp(op, error: 'Local API request timed out');
    });
    try {
      final response = await _localApiBridge.request(
        grant: grant,
        path: msg['path'],
        method: msg['method'],
        body: msg['body'],
        contentType: msg['contentType'],
      );
      _completeOp(op, result: response);
    } catch (e) {
      _completeOp(op, error: e.toString());
    }
  }

  static const _discoveryPermissions = {
    PluginPermissions.api,
    PluginPermissions.networkWebsocket,
    PluginPermissions.networkTcp,
    PluginPermissions.networkTls,
  };

  Future<void> _handleDiscoveryMessage(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    final requestId = msg['requestId'] as String?;
    if (requestId == null) return;
    final generation = msg['generation'] is num
        ? (msg['generation'] as num).toInt()
        : 0;
    final op = _PendingOp(
      kind: _PendingOpKind.discovery,
      pluginId: pluginId,
      generation: generation,
      requestId: requestId,
    );
    if (_pendingOps.containsKey(op.key)) return;
    _pendingOps[op.key] = op;

    final runtime = _plugins[pluginId];
    if (msg['bridgeToken'] != _realms[pluginId]?.bridgeToken) {
      _completeOp(op, error: 'Invalid plugin discovery caller');
      return;
    }
    if (generation != _pluginGenerations[pluginId] ||
        runtime?.isAlive != true) {
      _completeOp(op, error: 'Plugin generation changed');
      return;
    }
    if (!runtime!.manifest.permissions.any(_discoveryPermissions.contains)) {
      _completeOp(
        op,
        error:
            'host.discovery requires the api permission or a network.* '
            'permission',
        errorCode: 'permission',
      );
      return;
    }
    final PluginDiscoveryRequest request;
    try {
      request = resolvePluginDiscoveryRequest(
        runtime.manifest.mdnsDiscovery,
        msg['options'],
      );
    } on FormatException catch (e) {
      _completeOp(op, error: e.message, errorCode: 'validation');
      return;
    }
    if (!_discoveryBrowsing.add(pluginId)) {
      _completeOp(
        op,
        error: 'A discovery browse is already running',
        errorCode: 'busy',
      );
      return;
    }
    op.timeout = Timer(request.timeout + const Duration(seconds: 5), () {
      _completeOp(op, error: 'Discovery timed out');
    });
    bool accepts(String name) =>
        pluginDiscoveryNameMatches(name, request.namePrefixes);
    try {
      final services = await mdnsBrowser(
        request.serviceType,
        request.timeout,
        accepts,
      );
      _completeOp(
        op,
        result: {
          'services': services
              .where((service) => accepts(service.name))
              .take(maxPluginDiscoveryResults)
              .map((service) => service.toJson())
              .toList(),
        },
      );
    } catch (e) {
      _completeOp(op, error: 'Discovery failed: $e');
    } finally {
      _discoveryBrowsing.remove(pluginId);
    }
  }

  String _newBridgeToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<Map<String, dynamic>> proxyDecentApiForManifest({
    required String pluginId,
    required PluginManifest? manifest,
    required String? path,
    String method = 'GET',
    Map<String, String>? query,
    String? body,
    String? contentType,
    bool gzipBody = false,
  }) async {
    _ensureActive();
    return _decentProxyBridge.proxyForPlugin(
      pluginId: pluginId,
      manifest: manifest,
      path: path,
      method: method,
      query: query,
      body: body,
      contentType: contentType,
      gzipBody: gzipBody,
    );
  }

  Map<String, String>? _stringMap(dynamic value) {
    if (value is! Map) return null;
    final out = <String, String>{};
    value.forEach((key, value) {
      if (value != null) {
        out[key.toString()] = value.toString();
      }
    });
    return out.isEmpty ? null : out;
  }

  Future<void> _handlePluginStorage(
    String pluginId,
    int generation,
    PluginStorageCommand cmd,
  ) async {
    final namespace = pluginId;

    switch (cmd.type) {
      case PluginStorageCommandType.read:
        final value = await kvStore.get(key: cmd.key, namespace: namespace);
        if (!_isCurrentPluginMessage(pluginId, {'generation': generation})) {
          return;
        }
        dispatchEvent(pluginId, "storageRead", {
          "key": cmd.key,
          "value": value,
        });
        break;

      case PluginStorageCommandType.write:
        await kvStore.set(key: cmd.key, namespace: namespace, value: cmd.data);
        if (!_isCurrentPluginMessage(pluginId, {'generation': generation})) {
          return;
        }
        dispatchEvent(pluginId, "storageWrite", cmd.data);
        break;
    }
  }

  void _handlePluginApiResponse(String pluginId, Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String?;
    final response = msg['payload'] as Map<String, dynamic>?;

    if (requestId == null || response == null) {
      _log.warning("Invalid HTTP response from plugin $pluginId");
      return;
    }

    final messageGeneration = _messageGeneration(pluginId, msg);
    final op = messageGeneration == null
        ? null
        : _pendingOps[_PendingOp.keyFor(
            _PendingOpKind.pluginHttp,
            pluginId,
            messageGeneration,
            requestId,
          )];
    if (op == null) {
      _log.fine(
        'Late or unknown HTTP response for request $requestId from $pluginId',
      );
      return;
    }
    final generation = _messageGeneration(pluginId, msg);
    if (op.pluginId != pluginId) {
      _log.warning(
        'Rejected HTTP response for $requestId from $pluginId; owned by ${op.pluginId}',
      );
      return;
    }
    if (generation != op.generation ||
        generation != _pluginGenerations[pluginId]) {
      _log.warning(
        'Rejected stale HTTP response for $requestId from $pluginId',
      );
      return;
    }
    _completeOp(op, result: response);
  }

  Future<Map<String, dynamic>> registerPendingHttp(
    String pluginId,
    String requestId,
  ) {
    _ensureActive();
    if (_plugins[pluginId]?.isAlive != true) {
      throw StateError('Plugin is not loaded: $pluginId');
    }
    final op = _PendingOp(
      kind: _PendingOpKind.pluginHttp,
      pluginId: pluginId,
      generation: _pluginGenerations[pluginId] ?? 0,
      requestId: requestId,
    );
    final completer = Completer<Map<String, dynamic>>();
    op.completer = completer;
    op.timeout = Timer(pluginHttpTimeout, () {
      _completeOp(op, error: 'Plugin did not respond in time');
    });
    _pendingOps[op.key] = op;
    return completer.future;
  }

  bool isPluginRuntimeActive(String pluginId) =>
      _plugins[pluginId]?.isAlive == true;

  List<PluginRuntime> get loadedPlugins => _plugins.values.toList();

  void attachWorkflowController(WorkflowController? controller) {
    _ensureActive();
    if (identical(controller, _workflowController)) return;

    _detachWorkflowController();
    if (controller == null) return;
    final generation = _workflowAttachmentGeneration;
    _workflowController = controller;
    _lastWorkflowRevision = controller.revision;

    void listener() {
      if (_lifecycle != PluginManagerLifecycle.active ||
          !identical(controller, _workflowController) ||
          generation != _workflowAttachmentGeneration) {
        return;
      }
      final revision = controller.revision;
      if (revision == _lastWorkflowRevision) return;
      _lastWorkflowRevision = revision;
      broadcastEvent('workflowUpdated', controller.currentWorkflow.toJson());
    }

    _workflowListener = listener;
    controller.addListener(listener);
    broadcastEvent('workflowUpdated', controller.currentWorkflow.toJson());
  }

  void _detachWorkflowController() {
    _workflowAttachmentGeneration += 1;
    final controller = _workflowController;
    final listener = _workflowListener;
    _workflowController = null;
    _workflowListener = null;
    _lastWorkflowRevision = null;
    if (controller != null && listener != null) {
      controller.removeListener(listener);
    }
  }

  Future<void> attachDe1Controller(De1Controller? controller) {
    _ensureActive();
    final generation = ++_attachmentGeneration;
    final attachment = _attachmentQueue.then(
      (_) => _replaceDe1Controller(controller, generation),
    );
    _attachmentQueue = attachment.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return attachment;
  }

  Future<void> _replaceDe1Controller(
    De1Controller? controller,
    int generation,
  ) async {
    await _cancelControllerSubscriptions();
    if (_lifecycle != PluginManagerLifecycle.active ||
        generation != _attachmentGeneration) {
      return;
    }

    _de1controller = controller;
    if (controller == null) return;

    _de1Subscription = controller.de1.listen((de1) {
      final snapshotGeneration = ++_snapshotGeneration;
      if (_lifecycle != PluginManagerLifecycle.active ||
          generation != _attachmentGeneration) {
        return;
      }
      final replacement = _snapshotQueue.then(
        (_) =>
            _replaceSnapshotSubscription(de1, generation, snapshotGeneration),
      );
      _snapshotQueue = replacement.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          _log.warning(
            'Failed to replace plugin snapshot subscription',
            error,
            stackTrace,
          );
        },
      );
    });
  }

  Future<void> _replaceSnapshotSubscription(
    De1Interface? de1,
    int attachmentGeneration,
    int snapshotGeneration,
  ) async {
    final previous = _snapshotSubscription;
    _snapshotSubscription = null;
    await previous?.cancel();
    if (_lifecycle != PluginManagerLifecycle.active ||
        attachmentGeneration != _attachmentGeneration ||
        snapshotGeneration != _snapshotGeneration ||
        de1 == null) {
      return;
    }

    _snapshotSubscription = de1.currentSnapshot.listen((snapshot) {
      if (_lifecycle != PluginManagerLifecycle.active ||
          attachmentGeneration != _attachmentGeneration ||
          snapshotGeneration != _snapshotGeneration) {
        return;
      }
      broadcastEvent('stateUpdate', snapshot.toJson());
    });
  }

  Future<void> _cancelControllerSubscriptions() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final snapshot = _snapshotSubscription;
    _snapshotSubscription = null;
    try {
      await snapshot?.cancel();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }

    final de1 = _de1Subscription;
    _de1Subscription = null;
    try {
      await de1?.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _de1controller = null;

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _handleFetch(String pluginId, Map<String, dynamic> msg) async {
    _ensureActive();
    final id = msg['id'];
    if (id is! int) {
      _log.warning('Invalid fetch message');
      return;
    }
    if (!_plugins.containsKey(pluginId)) {
      _realmOf(pluginId)?.evaluate(
        'globalThis.__handleFetchResponse('
        '${jsonEncode({'id': id, 'error': 'plugin not loaded'})});',
      );
      return;
    }
    final generation = msg['generation'] is num
        ? (msg['generation'] as num).toInt()
        : 0;
    if (generation != (_pluginGenerations[pluginId] ?? 0)) {
      _realmOf(pluginId, generation)?.evaluate(
        'globalThis.__handleFetchResponse('
        '${jsonEncode({'id': id, 'error': 'plugin generation changed'})});',
      );
      return;
    }
    if (!_hasPermission(pluginId, PluginPermissions.api)) {
      _realmOf(pluginId, generation)?.evaluate(
        'globalThis.__handleFetchResponse('
        '${jsonEncode({'id': id, 'error': _permissionError(pluginId, PluginPermissions.api)})});',
      );
      return;
    }

    final op = _PendingOp(
      kind: _PendingOpKind.fetch,
      pluginId: pluginId,
      generation: generation,
      requestId: id.toString(),
    );
    op.timeout = Timer(fetchTimeout, () {
      _completeOp(op, error: 'fetch timeout');
    });
    _pendingOps[op.key] = op;

    try {
      final response = await _performFetch(op, msg);
      _completeOp(op, result: response);
    } on TlsPinMismatchException catch (e) {
      _completeOp(
        op,
        error: e.toString(),
        errorCode: TlsPinMismatchException.code,
        peerSha256: e.peerSha256,
      );
    } catch (e) {
      _completeOp(op, error: e.toString());
    }
  }

  Future<Map<String, dynamic>> _performFetch(
    _PendingOp op,
    Map<String, dynamic> msg,
  ) async {
    final uri = Uri.parse(msg['url'] as String);
    final method = ((msg['method'] as String?) ?? 'GET').toUpperCase();
    final headers = msg['headers'] as Map? ?? {};
    final body = msg['body'];
    final binary = switch (msg['responseType']) {
      null || 'text' => false,
      'base64' => true,
      _ => throw const FormatException(
        'responseType must be "base64" or omitted',
      ),
    };
    final pin = parseTlsPinSha256(msg[tlsPinOption]);
    requireTlsScheme(pin, uri.scheme == 'https', 'an https:// url');
    final check = pin == null ? null : TlsPinCheck(pin);
    final client = check == null
        ? _getHttpClient()
        : (pinnedHttpClient(check)
            ..connectionTimeout = const Duration(seconds: 10));
    Future<Map<String, dynamic>> send() =>
        _sendFetch(op, client, method, uri, headers, body, binary);
    try {
      return await (check == null ? send() : check.guard(send));
    } finally {
      if (pin != null) client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _sendFetch(
    _PendingOp op,
    HttpClient client,
    String method,
    Uri uri,
    Map headers,
    Object? body,
    bool binary,
  ) async {
    final request = await client.openUrl(method, uri);
    op.request = request;
    // Checked against the peer this request is connected to, before any
    // header is sent, so no host name can resolve one way here and another
    // way for the connection.
    final refusal = await _hostApiFetchRefusal(
      op.pluginId,
      method,
      uri,
      request.connectionInfo,
    );
    if (refusal != null) {
      request.abort();
      return {
        'id': int.parse(op.requestId),
        'status': 403,
        'headers': {'content-type': 'application/json'},
        'body': jsonEncode(refusal),
      };
    }
    headers.forEach((k, v) {
      request.headers.set(k.toString(), v.toString());
    });
    if (body != null) {
      request.add(
        body is String ? utf8.encode(body) : utf8.encode(jsonEncode(body)),
      );
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>([], (acc, chunk) {
      if (acc.length + chunk.length > maxFetchResponseBytes) {
        throw StateError(
          'response exceeds maxFetchResponseBytes ($maxFetchResponseBytes)',
        );
      }
      return acc..addAll(chunk);
    });

    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      responseHeaders[name] = values.join(', ');
    });
    return {
      'id': int.parse(op.requestId),
      'status': response.statusCode,
      'headers': responseHeaders,
      if (binary)
        'bodyBase64': base64Encode(bytes)
      else
        'body': utf8.decode(bytes, allowMalformed: true),
    };
  }
}
