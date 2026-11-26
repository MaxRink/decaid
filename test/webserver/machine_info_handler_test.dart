import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';

void main() {
  test('machine info answers 503 while no machine is connected', () async {
    final devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    final de1Controller = De1Controller(controller: devices);
    final scaleController = ScaleController();
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    addTearDown(() async {
      await de1Controller.dispose();
      devices.dispose();
      scaleController.dispose();
    });
    final app = Router().plus;
    De1Handler(
      controller: de1Controller,
      settingsController: settings,
      scaleController: scaleController,
      workflowController: WorkflowController(),
    ).addRoutes(app);

    final response = await app.call(
      Request('GET', Uri.parse('http://localhost/api/v1/machine/info')),
    );

    expect(response.statusCode, 503);
    expect(jsonDecode(await response.readAsString()), {
      'error': 'No machine connected',
    });
  });
}
