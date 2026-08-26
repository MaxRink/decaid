import 'dart:async';

import 'package:reaprime/src/models/device/grinder_capabilities.dart';
import 'package:reaprime/src/models/device/grinder_command_validator.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/models/device/grinder_operation.dart';
import 'package:reaprime/src/models/device/grinder_setting.dart';
import 'package:reaprime/src/models/device/grinder_snapshot.dart';
import 'package:reaprime/src/plugins/e64ws_plugin_bridge.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

typedef E64WsRequest = Future<Map<String, dynamic>> Function(
  String operation,
  Map<String, dynamic> arguments,
);

/// Typed `GrinderDevice` adapter for the local E64 WS WebSocket surface.
///
/// The default static E64 profile is read-only/calibration-only. A caller
/// must inject a separately validated capability profile before this adapter
/// can issue a dial adjustment. Every write is checked again here, then a
/// fresh snapshot is read back when the capability profile requires it.
class E64WsGrinderDevice implements GrinderDevice {
  E64WsGrinderDevice({
    required this.deviceId,
    required this.name,
    required E64WsRequest request,
    this.capabilities = GrinderCapabilities.e64Ws,
  }) : _request = request;

  factory E64WsGrinderDevice.fromPluginBridge({
    required String deviceId,
    required String name,
    required String pluginId,
    required PluginManifest manifest,
    required E64WsPluginBridge bridge,
    required String host,
    String token = '',
    int port = 9997,
    String scheme = 'wss',
    bool allowInsecureTls = false,
    GrinderCapabilities capabilities = GrinderCapabilities.e64Ws,
  }) {
    return E64WsGrinderDevice(
      deviceId: deviceId,
      name: name,
      capabilities: capabilities,
      request: (operation, arguments) => bridge.request(
        pluginId: pluginId,
        manifest: manifest,
        request: {
          'operation': operation,
          'arguments': {
            'host': host,
            'token': token,
            'port': port,
            'scheme': scheme,
            'allowInsecureTls': allowInsecureTls,
            ...arguments,
          },
        },
      ),
    );
  }

  @override
  final String deviceId;

  @override
  final String name;

  @override
  final GrinderCapabilities capabilities;

  final E64WsRequest _request;
  final GrinderCommandValidator _validator = const GrinderCommandValidator();
  final StreamController<GrinderSnapshot> _snapshotController =
      StreamController<GrinderSnapshot>.broadcast();
  Future<void> _operationTail = Future<void>.value();

  @override
  Stream<GrinderSnapshot> get snapshots => _snapshotController.stream;

  @override
  Future<GrinderSnapshot> readSnapshot() => _withOperationLock(_readSnapshot);

  Future<GrinderSnapshot> _readSnapshot() async {
    final response = await _request('driver_state', const {});
    final snapshot = _snapshotFromResponse(response);
    if (!_snapshotController.isClosed) _snapshotController.add(snapshot);
    return snapshot;
  }

  @override
  Future<GrinderOperationResult> execute(GrinderCommand command) =>
      _withOperationLock(() => _execute(command));

  Future<GrinderOperationResult> _execute(GrinderCommand command) async {
    if (command.operation == GrinderOperationId.readSnapshot) {
      final snapshot = await _readSnapshot();
      return GrinderOperationResult(
        operationId: command.operationId,
        status: GrinderOperationStatus.verified,
        snapshot: snapshot,
      );
    }
    if (command.operation == GrinderOperationId.readConfig) {
      if (!capabilities.allows(command.operation)) {
        return _rejected(command, 'read-config is not enabled by capabilities');
      }
      final response = await _request('driver_config', const {});
      return GrinderOperationResult(
        operationId: command.operationId,
        status: _successful(
          response,
          expectedType: 'RequestDriverConfigResult',
        )
            ? GrinderOperationStatus.verified
            : GrinderOperationStatus.rejected,
        message: _message(response),
        audit: _safeAudit(response),
      );
    }
    if (command.operation == GrinderOperationId.requestNativeGbsReport) {
      if (!capabilities.allows(command.operation)) {
        return _rejected(command, 'native GBS report is not enabled by capabilities');
      }
      final response = await _request('gbs_report', const {});
      return GrinderOperationResult(
        operationId: command.operationId,
        status: _successful(
          response,
          expectedType: 'GbsCreateReport',
        )
            ? GrinderOperationStatus.verified
            : GrinderOperationStatus.rejected,
        message: _message(response),
        audit: _safeAudit(response),
      );
    }

    if (command.operation == GrinderOperationId.prepareApply) {
      return _rejected(
        command,
        'E64 preparation tokens are not implemented; use a confirmed apply command',
      );
    }

    final before = await _readSnapshot();
    final now = DateTime.now();
    final validation = _validator.validate(
      command: command,
      capabilities: capabilities,
      snapshot: before,
      now: now,
    );
    if (validation != null) {
      return GrinderOperationResult(
        operationId: command.operationId,
        status: validation == 'grinder revision changed'
            ? GrinderOperationStatus.mismatch
            : GrinderOperationStatus.rejected,
        message: validation,
        snapshot: before,
      );
    }
    final action = _actionFor(command, before, capabilities);
    if (action == null) {
      return GrinderOperationResult(
        operationId: command.operationId,
        status: GrinderOperationStatus.rejected,
        message: 'command cannot be represented by the E64 action surface',
        snapshot: before,
      );
    }
    final response = await _request('action', action);
    if (!_successful(
      response,
      expectedType: 'GrinderActionResult',
      requireSuccess: true,
    )) {
      return GrinderOperationResult(
        operationId: command.operationId,
        status: GrinderOperationStatus.rejected,
        message: _message(response),
        snapshot: before,
        audit: _safeAudit(response),
      );
    }
    final after = await _readSnapshot();
    if (capabilities.safety.requiresReadback &&
        !_readbackMatches(command, action, after, capabilities)) {
      return GrinderOperationResult(
        operationId: command.operationId,
        status: GrinderOperationStatus.mismatch,
        message: 'E64 action succeeded but readback did not match',
        snapshot: after,
        audit: _safeAudit(response),
      );
    }
    return GrinderOperationResult(
      operationId: command.operationId,
      status: GrinderOperationStatus.verified,
      snapshot: after,
      audit: _safeAudit(response),
    );
  }

  Future<void> close() async {
    await _operationTail;
    await _snapshotController.close();
  }

  Future<T> _withOperationLock<T>(Future<T> Function() operation) {
    final waitFor = _operationTail;
    final done = Completer<void>();
    _operationTail = done.future;
    return waitFor.then((_) async {
      try {
        return await operation();
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
  }

  GrinderOperationResult _rejected(GrinderCommand command, String message) =>
      GrinderOperationResult(
        operationId: command.operationId,
        status: GrinderOperationStatus.rejected,
        message: message,
      );

  GrinderSnapshot _snapshotFromResponse(Map<String, dynamic> response) {
    final raw = response['data'];
    final data = raw is Map
        ? raw.map((key, value) => MapEntry(key.toString(), value))
        : <String, dynamic>{};
    final state = data['grindState']?.toString() ?? 'Unknown';
    final numeric = data['ddValueDum'] ?? data['agsaHallSensorCounts'];
    final setting = numeric is num
        ? NumericGrinderSetting(
            domain: 'e64.dd',
            value: numeric.toDouble(),
            unit: 'dum',
          )
        : null;
    final failure = data['grindFailure'] == true || data['ddSensorFailed'] == true;
    final expectedType = response['type'] == 'RequestDriverStateResult';
    final rawSnapshot = <String, dynamic>{
      ...data,
      '_observedAtSource': 'host',
    };
    return GrinderSnapshot(
      deviceId: deviceId,
      observedAt: DateTime.now(),
      firmwareBuild: data['firmwareBuild']?.toString() ??
          data['espVersionNo']?.toString(),
      connected: expectedType && !failure,
      idle: state != 'Grinding' && state != 'Running',
      motorRunning: state == 'Grinding' || state == 'Running',
      currentSetting: setting,
      fault: failure
          ? 'driver fault reported'
          : expectedType
          ? null
          : 'unexpected driver-state response type',
      // hmiTime is a display/runtime value, not a proven optimistic-concurrency
      // revision. Leave revision null until the protocol exposes one.
      revision: data['revision']?.toString(),
      raw: rawSnapshot,
    );
  }

  Map<String, dynamic>? _actionFor(
    GrinderCommand command,
    GrinderSnapshot snapshot,
    GrinderCapabilities capabilities,
  ) {
    switch (command.operation) {
      case GrinderOperationId.stop:
        return {'suffix': 'Stop', 'confirmed': command.confirmed};
      case GrinderOperationId.addBrewEvidence:
        return {
          'suffix': 'AddBrewEvent',
          'confirmed': command.confirmed,
          'data': command.evidence,
        };
      case GrinderOperationId.applyAbsolute:
        final setting = command.setting;
        if (setting is! NumericGrinderSetting || setting.domain != 'e64.dd') {
          return null;
        }
        return {
          'suffix': 'SetAgsaTargetDdValue',
          'confirmed': command.confirmed,
          'data': {
            'targetDdValue': setting.value.round(),
            'unit': setting.unit,
            'domain': setting.domain,
          },
        };
      case GrinderOperationId.applyRelative:
        final current = snapshot.currentSetting;
        final delta = command.relativeDelta;
        if (current is! NumericGrinderSetting || delta == null) return null;
        final target = capabilities.relativeTarget(current, delta);
        if (target == null) return null;
        return {
          'suffix': 'SetAgsaTargetDdValue',
          'confirmed': command.confirmed,
          'data': {
            'targetDdValue': target.round(),
            'unit': current.unit,
            'domain': current.domain,
          },
        };
      case GrinderOperationId.readSnapshot:
      case GrinderOperationId.readConfig:
      case GrinderOperationId.requestNativeGbsReport:
      case GrinderOperationId.prepareApply:
        return null;
    }
  }

  bool _readbackMatches(
    GrinderCommand command,
    Map<String, dynamic> action,
    GrinderSnapshot snapshot,
    GrinderCapabilities capabilities,
  ) {
    if (command.operation != GrinderOperationId.applyAbsolute &&
        command.operation != GrinderOperationId.applyRelative) {
      return true;
    }
    final expected = (action['data'] as Map?)?['targetDdValue'];
    final expectedUnit = (action['data'] as Map?)?['unit'];
    final expectedDomain = (action['data'] as Map?)?['domain'];
    final actual = snapshot.currentSetting;
    return expected is num &&
        actual is NumericGrinderSetting &&
        (expectedUnit is! String || actual.unit == expectedUnit) &&
        (expectedDomain is! String || actual.domain == expectedDomain) &&
        (actual.value - expected.toDouble()).abs() <=
            capabilities.safety.readbackTolerance;
  }

  static bool _successful(
    Map<String, dynamic> response, {
    required String expectedType,
    bool requireSuccess = false,
  }) {
    if (response['type'] != expectedType) return false;
    final data = response['data'];
    if (data is! Map) return false;
    if (!requireSuccess) return true;
    return data['success'] == true;
  }

  static String? _message(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is Map && data['error'] != null) return data['error'].toString();
    return null;
  }

  static Map<String, dynamic> _safeAudit(Map<String, dynamic> response) => {
    'responseType': response['type'],
    if (response['refId'] != null) 'refId': response['refId'],
  };
}
