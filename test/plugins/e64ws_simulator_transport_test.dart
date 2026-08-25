import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/e64ws_plugin_bridge.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

void main() {
  final enabled = Platform.environment['E64WS_SIMULATOR_TEST'] == '1';

  test(
    'Dart host bridge reads the loopback simulator envelope',
    () async {
      final result = await const E64WsPluginBridge().request(
        pluginId: 'test.e64-simulator',
        manifest: PluginManifest(
          id: 'test.e64-simulator',
          name: 'test.e64-simulator',
          author: 'test',
          description: 'loopback simulator test',
          version: '1.0.0',
          apiVersion: 1,
          permissions: {PluginPermissions.deviceGrinderRead},
          settings: const {},
          api: PluginApi(endpoints: const []),
        ),
        request: const {
          'operation': 'driver_state',
          'arguments': {
            'host': '127.0.0.1',
            'port': 9997,
            'scheme': 'ws',
            'allowInsecureTls': true,
            'token': 'mock-e64-token-0001',
          },
        },
      );

      expect(result['type'], 'RequestDriverStateResult');
      expect((result['data'] as Map)['simulator'], isTrue);
    },
    skip: enabled
        ? false
        : 'set E64WS_SIMULATOR_TEST=1 with the local simulator running',
  );
}
