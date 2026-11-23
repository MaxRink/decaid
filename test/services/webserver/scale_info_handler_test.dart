import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';

void main() {
  late DeviceController deviceController;
  late De1Controller de1Controller;
  late SettingsController settingsController;

  setUp(() async {
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
    settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
  });

  tearDown(() => deviceController.dispose());

  Future<Response> requestInfo(
    ScaleController controller, {
    bool Function(String pluginId)? isPluginRuntimeActive,
  }) async {
    final app = Router().plus;
    final registry = AuxiliaryScaleRegistry();
    addTearDown(registry.dispose);
    ScaleHandler(
      controller: controller,
      de1Controller: de1Controller,
      settingsController: settingsController,
      auxiliaryScaleRegistry: registry,
      isPluginRuntimeActive: isPluginRuntimeActive,
    ).addRoutes(app);
    return app.call(
      Request('GET', Uri.parse('http://localhost/api/v1/scale/info')),
    );
  }

  test('returns 503 when no scale is connected', () async {
    final controller = _DisconnectedScaleController();
    addTearDown(controller.dispose);

    final response = await requestInfo(controller);

    expect(response.statusCode, 503);
    expect(jsonDecode(await response.readAsString()), {
      'error': 'No scale connected',
    });
  });

  test('returns opaque firmwareVersion and optional batteryLevel', () async {
    for (final batteryLevel in [null, 0, 100]) {
      final scale = _InfoScale(
        DeviceInformation(firmwareVersion: 'R029', batteryLevel: batteryLevel),
      );
      addTearDown(scale.dispose);
      final controller = _FixedScaleController(scale);
      addTearDown(controller.dispose);

      final response = await requestInfo(controller);
      final json =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(json['firmwareVersion'], 'R029');
      if (batteryLevel == null) {
        expect(json.containsKey('batteryLevel'), isFalse);
      } else {
        expect(json['batteryLevel'], batteryLevel);
      }
    }
  });

  test('returns empty info for a scale without metadata capability', () async {
    final scale = TestScale();
    addTearDown(scale.dispose);
    final controller = _FixedScaleController(scale);
    addTearDown(controller.dispose);

    final response = await requestInfo(controller);

    expect(response.statusCode, 200);
    expect(jsonDecode(await response.readAsString()), isEmpty);
  });

  group('plugin surfaces', () {
    PluginScale pluginScale({
      List<PluginDeviceSurface> surfaces = const [
        PluginDeviceSurface(
          id: 'settings',
          role: 'settings',
          endpoint: 'device-settings',
          label: 'Skale settings',
        ),
        PluginDeviceSurface(
          id: 'diag',
          role: 'diagnostics',
          endpoint: 'device-diagnostics',
        ),
      ],
    }) {
      final scale = PluginScale(
        deviceId: 'plugin:skale:skale:AA BB',
        name: 'Skale 2',
        pluginId: 'skale',
        capabilities: const {},
        surfaces: surfaces,
        invoke: (_, _) async => const {},
      );
      addTearDown(scale.dispose);
      return scale;
    }

    Future<Map<String, dynamic>> info(
      Scale scale, {
      bool Function(String pluginId)? isPluginRuntimeActive,
    }) async {
      final controller = _FixedScaleController(scale);
      addTearDown(controller.dispose);
      final response = await requestInfo(
        controller,
        isPluginRuntimeActive: isPluginRuntimeActive,
      );
      expect(response.statusCode, 200);
      return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    }

    test('lists declared surfaces of an active plugin scale', () async {
      final json = await info(
        pluginScale(),
        isPluginRuntimeActive: (id) => id == 'skale',
      );

      expect(json['surfaces'], [
        {
          'id': 'settings',
          'role': 'settings',
          'label': 'Skale settings',
          'href':
              '/api/v1/plugins/skale/device-settings?ui=1'
              '&deviceId=plugin%3Askale%3Askale%3AAA+BB&deviceName=Skale+2',
        },
        {
          'id': 'diag',
          'role': 'diagnostics',
          'href':
              '/api/v1/plugins/skale/device-diagnostics?ui=1'
              '&deviceId=plugin%3Askale%3Askale%3AAA+BB&deviceName=Skale+2',
        },
      ]);
    });

    test('omits surfaces while the plugin runtime is inactive', () async {
      expect(
        await info(pluginScale(), isPluginRuntimeActive: (_) => false),
        isNot(contains('surfaces')),
      );
      expect(await info(pluginScale()), isNot(contains('surfaces')));
    });

    test('omits surfaces when the plugin declares none', () async {
      expect(
        await info(
          pluginScale(surfaces: const []),
          isPluginRuntimeActive: (_) => true,
        ),
        isNot(contains('surfaces')),
      );
    });

    test('omits surfaces for native scales', () async {
      final scale = _InfoScale(DeviceInformation(firmwareVersion: 'R029'));
      addTearDown(scale.dispose);

      final json = await info(scale, isPluginRuntimeActive: (_) => true);

      expect(json, {'firmwareVersion': 'R029'});
    });
  });
}

class _InfoScale extends TestScale implements DeviceInformationCapable {
  _InfoScale(this._info);

  final DeviceInformation? _info;

  @override
  DeviceInformation? get currentDeviceInformation => _info;

  @override
  Stream<DeviceInformation?> get deviceInformation => Stream.value(_info);
}

class _FixedScaleController extends ScaleController {
  _FixedScaleController(this._scale);

  final Scale _scale;

  @override
  Scale connectedScale() => _scale;
}

class _DisconnectedScaleController extends ScaleController {
  @override
  Scale connectedScale() => throw const DeviceNotConnectedException.scale();
}
