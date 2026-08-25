import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/e64ws_plugin_bridge.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

PluginManifest manifest({bool actuate = false}) {
  return PluginManifest(
    id: 'test.e64',
    name: 'test.e64',
    author: 'test',
    description: 'test',
    version: '1.0.0',
    apiVersion: 1,
    permissions: {
      PluginPermissions.deviceGrinderRead,
      if (actuate) PluginPermissions.deviceGrinderActuate,
    },
    settings: const {},
    api: PluginApi(endpoints: const []),
  );
}

void main() {
  const bridge = E64WsPluginBridge();

  test(
    'rejects missing host and token without contacting the network',
    () async {
      await expectLater(
        bridge.request(
          pluginId: 'test.e64',
          manifest: manifest(),
          request: const {
            'operation': 'driver_state',
            'arguments': {'host': '10.0.0.2'},
          },
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('rejects an unknown named operation before opening WSS', () async {
    await expectLater(
      bridge.request(
        pluginId: 'test.e64',
        manifest: manifest(),
        request: const {
          'operation': 'raw_socket_send',
          'arguments': {'host': '127.0.0.1', 'token': 'redacted-test-token'},
        },
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'restricts plaintext transport to loopback and explicit opt-in',
    () async {
      await expectLater(
        bridge.request(
          pluginId: 'test.e64',
          manifest: manifest(),
          request: const {
            'operation': 'driver_state',
            'arguments': {
              'host': '10.0.0.2',
              'token': 'redacted-test-token',
              'scheme': 'ws',
              'allowInsecureTls': true,
            },
          },
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('rejects an unknown action before opening WSS', () async {
    await expectLater(
      bridge.request(
        pluginId: 'test.e64',
        manifest: manifest(actuate: true),
        request: const {
          'operation': 'action',
          'arguments': {
            'host': '10.0.0.2',
            'token': 'redacted-test-token',
            'suffix': 'NotARecoveredAction',
          },
        },
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('does not treat a hostname beginning with 127 as loopback', () async {
    await expectLater(
      bridge.request(
        pluginId: 'test.e64',
        manifest: manifest(),
        request: const {
          'operation': 'driver_state',
          'arguments': {
            'host': '127.example.invalid',
            'token': 'redacted-test-token',
            'scheme': 'ws',
            'allowInsecureTls': true,
          },
        },
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('requires confirmation for hazardous action', () async {
    await expectLater(
      bridge.request(
        pluginId: 'test.e64',
        manifest: manifest(actuate: true),
        request: const {
          'operation': 'action',
          'arguments': {
            'host': '10.0.0.2',
            'token': 'redacted-test-token',
            'suffix': 'StartGrindManual',
          },
        },
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('requires actuation permission for actions', () async {
    await expectLater(
      bridge.request(
        pluginId: 'test.e64',
        manifest: manifest(),
        request: const {
          'operation': 'action',
          'arguments': {
            'host': '10.0.0.2',
            'token': 'redacted-test-token',
            'suffix': 'Stop',
            'confirmed': true,
          },
        },
      ),
      throwsA(isA<StateError>()),
    );
  });
}
