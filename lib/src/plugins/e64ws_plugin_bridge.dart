import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:reaprime/src/plugins/plugin_grinder_bridge.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

/// Named-operation bridge for the owner-controlled local Mahlkönig E64 WS.
///
/// This intentionally does not expose a raw WebSocket API to plugin code.
/// Each request opens one short-lived WSS session, sends one recovered JSON
/// envelope, correlates the response, and closes the session.  This is less
/// efficient than a long-lived session but keeps lifecycle, cancellation, and
/// credential ownership simple until a native device manager exists.
class E64WsPluginBridge implements PluginGrinderBridge {
  static const actionSuffixes = <String>{
    'Stop',
    'StartGrindManual',
    'StartGrindGbw',
    'StartGrindGbt',
    'StartCalibration',
    'StartTara',
    'SaveLog',
    'ResetLog',
    'SetFanTemperatureCtrlEnabled',
    'CalibrateFan1',
    'CalibrateFan2',
    'ToggleBacklightPower',
    'SetBacklightBrightness',
    'SetFan1Duty',
    'SetFan2Duty',
    'SetAgsaTargetDdValue',
    'StopAgsa',
    'CalibrateDdSensor',
    'ResetDriverConfig',
    'SetLanguage',
    'StartEnduranceTest',
    'StopEnduranceTest',
    'SetSetupWizardState',
    'AddBrewEvent',
    'EspFlashApp',
    'EspEraseFlash',
    'EspReset',
    'NozzleLightRunStandby',
    'NozzleLightStop',
    'RcTopLeftClick',
    'RcTopLeftLong',
    'RcTopLeftPress',
    'RcTopLeftRelease',
    'RcBottomLeftClick',
    'RcRotaryClick',
    'RcRotaryLong',
    'RcRotaryDouble',
    'RcRotary',
    'GbsCreateReport',
  };

  static const hazardousActions = <String>{
    'StartGrindManual',
    'StartGrindGbw',
    'StartGrindGbt',
    'StartCalibration',
    'StartTara',
    'CalibrateFan1',
    'CalibrateFan2',
    'SetFan1Duty',
    'SetFan2Duty',
    'SetAgsaTargetDdValue',
    'StopAgsa',
    'CalibrateDdSensor',
    'AddBrewEvent',
    'ResetDriverConfig',
    'SetSetupWizardState',
    'EspFlashApp',
    'EspEraseFlash',
    'EspReset',
    'StartEnduranceTest',
    'StopEnduranceTest',
    'RcTopLeftClick',
    'RcTopLeftLong',
    'RcTopLeftPress',
    'RcTopLeftRelease',
    'RcBottomLeftClick',
    'RcRotaryClick',
    'RcRotaryLong',
    'RcRotaryDouble',
    'RcRotary',
  };

  final Duration requestTimeout;
  final int maxUnrelatedMessages;

  const E64WsPluginBridge({
    this.requestTimeout = const Duration(seconds: 10),
    this.maxUnrelatedMessages = 100,
  });

  @override
  Future<Map<String, dynamic>> request({
    required String pluginId,
    required PluginManifest manifest,
    required Map<String, dynamic> request,
  }) async {
    final operation = PluginGrinderOperation.fromWire(request['operation']);
    if (operation == null) {
      throw const FormatException('Unknown E64 grinder operation');
    }
    final args = _map(request['arguments']);
    final host = _host(args['host']);
    final token = _requiredString(args['token'], 'token');
    final port = _port(args['port']);
    final allowInsecure = args['allowInsecureTls'] == true;
    final scheme = _scheme(args['scheme']);
    if (scheme == 'ws' && (!allowInsecure || !_isLoopback(host))) {
      throw StateError(
        'plaintext ws is restricted to loopback simulator use with allowInsecureTls=true',
      );
    }

    final message = switch (operation) {
      PluginGrinderOperation.driverState => _message('RequestDriverState'),
      PluginGrinderOperation.driverConfig => _message('RequestDriverConfig'),
      PluginGrinderOperation.gbsReport => _action('GbsCreateReport'),
      PluginGrinderOperation.action => _actionRequest(args, manifest),
    };

    // Keep the plugin id in the error context only; never include args because
    // they contain the bearer token.
    try {
      return await _request(
        host: host,
        port: port,
        token: token,
        allowInsecure: allowInsecure,
        scheme: scheme,
        message: message,
      );
    } on TimeoutException {
      throw StateError('E64 grinder request timed out for plugin $pluginId');
    } on FormatException {
      rethrow;
    } catch (_) {
      // Do not propagate platform socket messages: some implementations echo
      // the URI, which would disclose the bearer token through plugin errors.
      throw StateError('E64 grinder request failed for plugin $pluginId');
    }
  }

  static Map<String, dynamic> _message(String type, [Object? data]) {
    final message = <String, dynamic>{'type': type, 'msgId': 1};
    if (data != null) message['data'] = data;
    return message;
  }

  static Map<String, dynamic> _action(String suffix, [Object? data]) {
    final payload = <String, dynamic>{'actionType': suffix};
    if (data is Map) payload.addAll(_map(data));
    return _message('GrinderAction', payload);
  }

  static Map<String, dynamic> _actionRequest(
    Map<String, dynamic> args,
    PluginManifest manifest,
  ) {
    final suffix = args['suffix'];
    if (suffix is! String || !actionSuffixes.contains(suffix)) {
      throw FormatException('Unknown E64 grinder action: $suffix');
    }
    if (!manifest.permissions.contains(
      PluginPermissions.deviceGrinderActuate,
    )) {
      throw StateError('Plugin permission required: device.grinder.actuate');
    }
    if (hazardousActions.contains(suffix) && args['confirmed'] != true) {
      throw StateError('Hazardous E64 action requires confirmed=true');
    }
    final data = _map(args['data']);
    return _action(suffix, data);
  }

  static String _host(Object? value) {
    final host = _requiredString(value, 'host');
    if (host.contains('/') || host.contains('\\') || host.contains('@')) {
      throw const FormatException('E64 host must be a hostname or IP address');
    }
    return host;
  }

  static String _requiredString(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('E64 $field is required');
    }
    return value.trim();
  }

  static int _port(Object? value) {
    final port = value is num ? value.toInt() : 9997;
    if (port < 1 || port > 65535) {
      throw const FormatException('E64 port is outside 1..65535');
    }
    return port;
  }

  static String _scheme(Object? value) {
    final scheme = value is String && value.isNotEmpty ? value : 'wss';
    if (scheme != 'ws' && scheme != 'wss') {
      throw const FormatException('E64 scheme must be ws or wss');
    }
    return scheme;
  }

  static bool _isLoopback(String host) {
    if (host.toLowerCase() == 'localhost') return true;
    return InternetAddress.tryParse(host)?.isLoopback ?? false;
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value == null) return <String, dynamic>{};
    if (value is! Map) {
      throw const FormatException('E64 arguments must be an object');
    }
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<Map<String, dynamic>> _request({
    required String host,
    required int port,
    required String token,
    required bool allowInsecure,
    required String scheme,
    required Map<String, dynamic> message,
  }) async {
    final client = HttpClient()..connectionTimeout = requestTimeout;
    if (allowInsecure) {
      client.badCertificateCallback = (certificate, host, port) => true;
    }

    final uri = Uri(
      scheme: scheme,
      host: host,
      port: port,
      queryParameters: {'token': token},
    );
    WebSocket? socket;
    try {
      socket = await WebSocket.connect(
        uri.toString(),
        customClient: client,
      ).timeout(requestTimeout);
      socket.pingInterval = const Duration(seconds: 10);
      socket.add(jsonEncode(message));

      var unrelated = 0;
      await for (final raw in socket.timeout(requestTimeout)) {
        final response = _decode(raw);
        if (response['pong'] == true) continue;
        if (_matches(message, response)) return response;
        if (response['type'] == 'UnknownType') return response;
        unrelated += 1;
        if (unrelated >= maxUnrelatedMessages) {
          throw StateError('too many unrelated E64 messages');
        }
      }
      throw StateError('E64 WSS closed before the response');
    } finally {
      try {
        await socket?.close();
      } finally {
        client.close(force: true);
      }
    }
  }

  static Map<String, dynamic> _decode(Object? raw) {
    final decoded = jsonDecode(
      raw is String ? raw : utf8.decode(raw as List<int>),
    );
    if (decoded is! Map) {
      throw const FormatException('E64 WSS returned non-object JSON');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  static bool _matches(
    Map<String, dynamic> request,
    Map<String, dynamic> response,
  ) {
    final type = request['type'];
    final expected = type == 'GrinderAction'
        ? ((request['data'] as Map?)?['actionType'] == 'GbsCreateReport'
              ? 'GbsCreateReport'
              : 'GrinderActionResult')
        : '${type}Result';
    if (response['type'] != expected) return false;
    if (!response.containsKey('refId')) {
      return type == 'GrinderAction' &&
          (request['data'] as Map?)?['actionType'] == 'GbsCreateReport';
    }
    return response['refId'] == request['msgId'];
  }
}
