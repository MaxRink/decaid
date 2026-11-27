import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

/// The realm of the test's only loaded plugin.
JavascriptRuntime _js(PluginManager manager) =>
    manager.jsRealmOf(manager.loadedPlugins.single.pluginId);

/// Mirrors writes to the named JS globals into [values], so a test can still
/// read what a plugin recorded after unload has disposed its realm.
void Function(String, JavascriptRuntime) _recordGlobals(
  List<String> names,
  Map<String, Object?> values,
) => (_, js) {
  js.onMessage('recordedGlobal', (message) {
    final entry = message as Map<String, dynamic>;
    values[entry['name'] as String] = entry['value'];
  });
  final result = js.evaluate('''
    for (const name of ${jsonEncode(names)}) {
      let value;
      Object.defineProperty(globalThis, name, {
        configurable: true,
        get: () => value,
        set: (next) => {
          value = next;
          sendMessage("recordedGlobal", JSON.stringify({ name, value: next }));
        },
      });
    }
  ''');
  expect(result.isError, isFalse, reason: result.stringResult);
};

void main() {
  test(
    'declared plugin sensor connects, publishes, and executes commands',
    () async {
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final sensorController = SensorController(controller: deviceController);
      final recorded = <String, Object?>{};
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
        debugPrepareRealm: _recordGlobals(['disconnectCalls'], recorded),
      );
      addTearDown(() async {
        await manager.dispose();
        sensorController.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .first;
      await manager.loadPlugin(
        id: 'humidity.plugin',
        manifest: testManifest(
          'humidity.plugin',
          permissions: const {PluginPermissions.emit},
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode: '''
        function createPlugin(host) {
          return {
            id: "humidity.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [
                  { key: "relativeHumidity", type: "number", unit: "%RH" }
                ],
                commands: [
                  { id: "sampleNow" },
                  { id: "wait" },
                  { id: "badResult" }
                ]
              }, {
                connect() {},
                disconnect() {
                  globalThis.disconnectCalls = (globalThis.disconnectCalls || 0) + 1;
                },
                execute(command) {
                  if (command.commandId === "wait") return new Promise(() => {});
                  if (command.commandId === "badResult") return false;
                  return { relativeHumidity: 53.1, commandId: command.commandId };
                }
              }).then((device) => {
                globalThis.testHumidityDevice = device;
                host.emit("registered", device.deviceId);
              });
            },
            onUnload() {
              throw new Error("unload failed");
            }
          };
        }
      ''',
      );

      final deviceId = await registered.timeout(const Duration(seconds: 2));
      expect(deviceId, 'plugin:humidity.plugin:humidity:office');
      final sensor = await sensorController.sensorRegistry
          .map((sensors) => sensors[deviceId])
          .where((sensor) => sensor != null)
          .cast<Sensor>()
          .first;
      await sensor.connectionState
          .where((state) => state == ConnectionState.connected)
          .first;

      expect(await sensor.execute('sampleNow', null), {
        'relativeHumidity': 53.1,
        'commandId': 'sampleNow',
      });
      await expectLater(
        sensor.execute('badResult', null),
        throwsA(
          isA<PluginDeviceException>().having(
            (error) => error.message,
            'message',
            contains('must return an object'),
          ),
        ),
      );
      final snapshot = sensor.data.first;
      _js(manager).evaluate(
        'globalThis.testHumidityDevice.publish({ relativeHumidity: 52.4 });',
      );
      expect(await snapshot.timeout(const Duration(seconds: 2)), {
        'relativeHumidity': 52.4,
      });

      final pendingCommand = expectLater(
        sensor.execute('wait', null),
        throwsA(
          isA<PluginDeviceException>().having(
            (error) => error.message,
            'message',
            contains('unloaded'),
          ),
        ),
      );
      await manager.unloadPlugin('humidity.plugin');
      await pendingCommand;
      await sensorController.sensorRegistry
          .where((sensors) => !sensors.containsKey(deviceId))
          .first;
      expect(deviceController.devices, isEmpty);
      expect(recorded['disconnectCalls'], 1);
    },
  );

  test('undeclared driver registration is rejected', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    final error = manager.emitStream
        .where((event) => event['event'] == 'result')
        .map((event) => event['payload'] as String)
        .first;

    await manager.loadPlugin(
      id: 'undeclared.plugin',
      manifest: testManifest(
        'undeclared.plugin',
        permissions: const {PluginPermissions.emit},
      ),
      settings: const {},
      jsCode: '''
        function createPlugin(host) {
          return {
            id: "undeclared.plugin",
            onLoad() {
              __deviceSetHandlers("direct_registration", {
                pluginId: "undeclared.plugin",
                generation: pluginGeneration,
                bridgeToken: pluginBridgeToken,
                handlers: { connect() {}, disconnect() {}, execute() {} }
              });
              __deviceRegisterPending("direct_request", {
                bridgeToken: pluginBridgeToken,
                resolve: () => host.emit("result", "unexpected"),
                reject: (error) => host.emit("result", error.message)
              });
              pluginHostBridge.deviceRequest(
                pluginBridgeToken,
                pluginGeneration,
                "direct_request",
                "register",
                {
                  registrationHandle: "direct_registration",
                  definition: {
                    driverId: "humidity",
                    instanceId: "office",
                    name: "Office humidity",
                    vendor: "Test",
                    dataChannels: [{ key: "relativeHumidity", type: "number" }]
                  }
                }
              );
            }
          };
        }
      ''',
    );

    expect(
      await error.timeout(const Duration(seconds: 2)),
      contains('not declared'),
    );
    expect(await manager.deviceService.devices.first, isEmpty);
  });

  test('device command times out', () async {
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
      deviceInvocationTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(() async {
      await manager.dispose();
      sensorController.dispose();
      deviceController.dispose();
    });

    final registered = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .first;
    await manager.loadPlugin(
      id: 'timeout.plugin',
      manifest: testManifest(
        'timeout.plugin',
        permissions: const {PluginPermissions.emit},
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode: '''
        function createPlugin(host) {
          return {
            id: "timeout.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }],
                commands: [{ id: "sampleNow" }]
              }, {
                connect() {},
                disconnect() {},
                execute() { return new Promise(() => {}); }
              }).then((device) => host.emit("registered", device.deviceId));
            }
          };
        }
      ''',
    );
    final deviceId = await registered.timeout(const Duration(seconds: 2));
    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[deviceId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await sensor.connectionState
        .where((state) => state == ConnectionState.connected)
        .first;

    await expectLater(
      sensor.execute('sampleNow', null),
      throwsA(
        isA<PluginDeviceException>().having(
          (error) => error.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });

  test(
    'direct device.unregister calls disconnect once and removes device',
    () async {
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final sensorController = SensorController(controller: deviceController);
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
      );
      addTearDown(() async {
        await manager.dispose();
        sensorController.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .first;
      await manager.loadPlugin(
        id: 'unregister.plugin',
        manifest: testManifest(
          'unregister.plugin',
          permissions: const {PluginPermissions.emit},
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode: '''
        function createPlugin(host) {
          return {
            id: "unregister.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect() {},
                disconnect() {
                  globalThis.disconnectCalls = (globalThis.disconnectCalls || 0) + 1;
                },
                execute() { return {}; }
              }).then((device) => {
                globalThis.testUnregisterDevice = device;
                globalThis.performReportDisconnected = () => device.reportDisconnected();
                globalThis.performUnregister = () => device.unregister().then(() => {
                  host.emit("unregistered", device.deviceId);
                });
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
      );

      final deviceId = await registered.timeout(const Duration(seconds: 2));
      final sensor = await sensorController.sensorRegistry
          .map((sensors) => sensors[deviceId])
          .where((sensor) => sensor != null)
          .cast<Sensor>()
          .first;
      await sensor.connectionState
          .where((state) => state == ConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 2));
      final disconnected = sensor.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .first;
      _js(manager).evaluate('globalThis.performReportDisconnected();');
      await disconnected.timeout(const Duration(seconds: 2));

      final unregistered = manager.emitStream
          .where((event) => event['event'] == 'unregistered')
          .map((event) => event['payload'] as String)
          .first;
      _js(manager).evaluate('globalThis.performUnregister();');
      expect(await unregistered.timeout(const Duration(seconds: 2)), deviceId);
      expect(
        _js(manager)
            .evaluate('String(globalThis.disconnectCalls || 0)')
            .stringResult,
        '1',
      );
      await sensorController.sensorRegistry
          .where((sensors) => !sensors.containsKey(deviceId))
          .first;
      expect(deviceController.devices, isEmpty);
    },
  );

  test('unregister removes the device even when disconnect fails', () async {
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
    );
    addTearDown(() async {
      await manager.dispose();
      sensorController.dispose();
      deviceController.dispose();
    });

    final registered = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .first;
    await manager.loadPlugin(
      id: 'unregister-failure.plugin',
      manifest: testManifest(
        'unregister-failure.plugin',
        permissions: const {PluginPermissions.emit},
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode: '''
        function createPlugin(host) {
          return {
            id: "unregister-failure.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect() {},
                disconnect() {
                  globalThis.disconnectCalls = (globalThis.disconnectCalls || 0) + 1;
                  throw new Error("transport busy");
                },
                execute() { return {}; }
              }).then((device) => {
                globalThis.performFailingUnregister = () => device.unregister().then(
                  () => host.emit("unregistered", "unexpected success"),
                  (error) => host.emit("unregistered-failed", String(error))
                );
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
    );

    final deviceId = await registered.timeout(const Duration(seconds: 2));
    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[deviceId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await sensor.connectionState
        .where((state) => state == ConnectionState.connected)
        .first
        .timeout(const Duration(seconds: 2));

    final failure = manager.emitStream
        .where((event) => event['event'] == 'unregistered-failed')
        .map((event) => event['payload'] as String)
        .first;
    _js(manager).evaluate('globalThis.performFailingUnregister();');
    expect(
      await failure.timeout(const Duration(seconds: 2)),
      contains('transport busy'),
    );
    expect(
      _js(manager)
          .evaluate('String(globalThis.disconnectCalls || 0)')
          .stringResult,
      '1',
    );
    await sensorController.sensorRegistry
        .where((sensors) => !sensors.containsKey(deviceId))
        .first;
    expect(deviceController.devices, isEmpty);
  });

  test(
    'unload lets a device disconnect handler close its own transport',
    () async {
      final server = await _startWsServer((ws) {
        ws.listen((data) {});
      });
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final sensorController = SensorController(controller: deviceController);
      final recorded = <String, Object?>{};
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
        debugPrepareRealm: _recordGlobals(['disconnectClosed'], recorded),
      );
      addTearDown(() async {
        await manager.dispose();
        sensorController.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .first;
      await manager.loadPlugin(
        id: 'cleanup-transport.plugin',
        manifest: testManifest(
          'cleanup-transport.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode:
            '''
        function createPlugin(host) {
          return {
            id: "cleanup-transport.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect(transport) {
                  return transport.open({
                    kind: "websocket",
                    url: "ws://127.0.0.1:${server.port}/x"
                  }).then((opened) => {
                    globalThis.cleanupTransportHandle = opened.handle;
                    return {};
                  });
                },
                disconnect() {
                  return host.transport.close(globalThis.cleanupTransportHandle)
                    .then(() => {
                      globalThis.disconnectClosed =
                        (globalThis.disconnectClosed || 0) + 1;
                      return {};
                    });
                },
                execute() { return {}; }
              }).then((device) => {
                globalThis.cleanupDevice = device;
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
      );

      final deviceId = await registered.timeout(const Duration(seconds: 2));
      final sensor = await sensorController.sensorRegistry
          .map((sensors) => sensors[deviceId])
          .where((sensor) => sensor != null)
          .cast<Sensor>()
          .first;
      await sensor.connectionState
          .where((state) => state == ConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 2));
      expect(manager.liveTransportCount, 1);

      await manager.unloadPlugin('cleanup-transport.plugin');

      expect(recorded['disconnectClosed'] ?? 0, 1);
      expect(manager.liveTransportCount, 0);
      await sensorController.sensorRegistry
          .where((sensors) => !sensors.containsKey(deviceId))
          .first;
      expect(deviceController.devices, isEmpty);
    },
  );

  test(
    'direct unregister after reportDisconnected closes device transport',
    () async {
      final server = await _startWsServer((ws) {
        ws.listen((data) {});
      });
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final sensorController = SensorController(controller: deviceController);
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
      );
      addTearDown(() async {
        await manager.dispose();
        sensorController.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .first;
      await manager.loadPlugin(
        id: 'direct-cleanup-transport.plugin',
        manifest: testManifest(
          'direct-cleanup-transport.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode:
            '''
        function createPlugin(host) {
          return {
            id: "direct-cleanup-transport.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect(transport) {
                  return transport.open({
                    kind: "websocket",
                    url: "ws://127.0.0.1:${server.port}/x"
                  }).then((opened) => {
                    globalThis.directCleanupHandle = opened.handle;
                  });
                },
                disconnect() {
                  return host.transport.close(globalThis.directCleanupHandle)
                    .then(() => {
                      globalThis.directDisconnectClosed =
                        (globalThis.directDisconnectClosed || 0) + 1;
                    });
                },
                execute() { return {}; }
              }).then((device) => {
                globalThis.directCleanupDevice = device;
                globalThis.performDirectUnregister = () =>
                  device.unregister().then(() => {
                    host.emit("unregistered", device.deviceId);
                  });
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
      );

      final deviceId = await registered.timeout(const Duration(seconds: 2));
      final sensor = await sensorController.sensorRegistry
          .map((sensors) => sensors[deviceId])
          .where((sensor) => sensor != null)
          .cast<Sensor>()
          .first;
      await sensor.connectionState
          .where((state) => state == ConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 2));
      expect(manager.liveTransportCount, 1);

      final disconnected = sensor.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .first;
      _js(manager)
          .evaluate('globalThis.directCleanupDevice.reportDisconnected();');
      await disconnected.timeout(const Duration(seconds: 2));

      final unregistered = manager.emitStream
          .where((event) => event['event'] == 'unregistered')
          .map((event) => event['payload'] as String)
          .first;
      _js(manager).evaluate('globalThis.performDirectUnregister();');
      expect(await unregistered.timeout(const Duration(seconds: 2)), deviceId);
      expect(manager.liveTransportCount, 0);
      expect(
        _js(manager)
            .evaluate('String(globalThis.directDisconnectClosed || 0)')
            .stringResult,
        '1',
      );
      await sensorController.sensorRegistry
          .where((sensors) => !sensors.containsKey(deviceId))
          .first;
      expect(deviceController.devices, isEmpty);
    },
  );

  test(
    'unload settles a retiring connect invocation before its timeout',
    () async {
      final server = await _startWsServer((ws) {
        ws.listen((data) {});
      });
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final sensorController = SensorController(controller: deviceController);
      final recorded = <String, Object?>{};
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
        debugPrepareRealm: _recordGlobals([
          'openRejected',
          'openAllowed',
          'disconnectCalls',
        ], recorded),
        deviceInvocationTimeout: const Duration(seconds: 20),
      );
      addTearDown(() async {
        await manager.dispose();
        sensorController.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .first;
      await manager.loadPlugin(
        id: 'unload-delayed-connect.plugin',
        manifest: testManifest(
          'unload-delayed-connect.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode:
            '''
        function createPlugin(host) {
          let transportHandle;
          return {
            id: "unload-delayed-connect.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect(transport) {
                  globalThis.connectStarted = true;
                  return new Promise((resolve, reject) => {
                    globalThis.releaseConnect = () => {
                      transport.open({
                        kind: "websocket",
                        url: "ws://127.0.0.1:${server.port}/x"
                      }).then((opened) => {
                        transportHandle = opened.handle;
                        globalThis.openAllowed = true;
                        resolve({});
                      }, (error) => {
                        globalThis.openRejected = true;
                        reject(error);
                      });
                    };
                  });
                },
                disconnect() {
                  const handle = transportHandle;
                  transportHandle = null;
                  globalThis.disconnectCalls =
                    (globalThis.disconnectCalls || 0) + 1;
                  return handle
                    ? host.transport.close(handle)
                    : Promise.resolve();
                },
                execute() { return {}; }
              }).then((device) => host.emit("registered", device.deviceId));
            },
            onUnload() {
              globalThis.unloadStarted = true;
            }
          };
        }
      ''',
      );

      final deviceId = await registered.timeout(const Duration(seconds: 2));
      final sensor = await sensorController.sensorRegistry
          .map((sensors) => sensors[deviceId])
          .where((sensor) => sensor != null)
          .cast<Sensor>()
          .first;
      await sensor.connectionState
          .where((state) => state == ConnectionState.connecting)
          .first
          .timeout(const Duration(seconds: 2));

      final unloading = manager.unloadPlugin('unload-delayed-connect.plugin');
      var unloadStarted = false;
      for (
        var i = 0;
        i < 100 && manager.lifecycle == PluginManagerLifecycle.active;
        i++
      ) {
        final result = _js(manager)
            .evaluate('String(globalThis.unloadStarted || false)');
        if (!result.isError && result.stringResult == 'true') {
          unloadStarted = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(unloadStarted, isTrue);

      _js(manager).evaluate('globalThis.releaseConnect();');
      while (_js(manager).executePendingJob() > 0) {}
      await expectLater(
        unloading.timeout(const Duration(seconds: 2)),
        completes,
      );
      expect(recorded['openRejected'] ?? false, true);
      expect(recorded['openAllowed'] ?? false, false);
      expect(recorded['disconnectCalls'] ?? 0, 1);
      expect(manager.liveTransportCount, 0);
      await sensorController.sensorRegistry
          .where((sensors) => !sensors.containsKey(deviceId))
          .first;
      expect(deviceController.devices, isEmpty);
    },
  );

  test('direct unregister retires a timed-out connect transport', () async {
    final server = await _startWsServer((ws) {
      ws.listen((data) {});
    });
    final nativeOpen = Completer<WebSocket>();
    final connectorStarted = Completer<void>();
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
      deviceInvocationTimeout: const Duration(milliseconds: 30),
      connectWebSocket: (url, {protocols}) {
        if (!connectorStarted.isCompleted) connectorStarted.complete();
        return nativeOpen.future;
      },
    );
    addTearDown(() async {
      await manager.dispose();
      sensorController.dispose();
      deviceController.dispose();
    });

    final registered = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .first;
    await manager.loadPlugin(
      id: 'timeout-connect.plugin',
      manifest: testManifest(
        'timeout-connect.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode:
          '''
        function createPlugin(host) {
          let transportHandle;
          return {
            id: "timeout-connect.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect(transport) {
                  return transport.open({
                    kind: "websocket",
                    url: "ws://127.0.0.1:${server.port}/x"
                  }).then((opened) => {
                    transportHandle = opened.handle;
                    globalThis.connectCompleted = true;
                    return {};
                  }, (error) => {
                    globalThis.connectRejected = true;
                    throw error;
                  });
                },
                disconnect() {
                  const handle = transportHandle;
                  transportHandle = null;
                  globalThis.disconnectCalls =
                    (globalThis.disconnectCalls || 0) + 1;
                  return handle
                    ? host.transport.close(handle)
                    : Promise.resolve();
                },
                execute() { return {}; }
              }).then((device) => {
                globalThis.timeoutDevice = device;
                globalThis.performUnregister = () =>
                  device.unregister().then(() => {
                    host.emit("unregistered", device.deviceId);
                  });
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
    );

    final deviceId = await registered.timeout(const Duration(seconds: 2));
    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[deviceId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await sensor.connectionState
        .where((state) => state == ConnectionState.connecting)
        .first
        .timeout(const Duration(seconds: 2));
    await connectorStarted.future.timeout(const Duration(seconds: 2));
    final states = <ConnectionState>[];
    final stateSubscription = sensor.connectionState.listen(states.add);
    addTearDown(stateSubscription.cancel);

    final unregistered = manager.emitStream
        .where((event) => event['event'] == 'unregistered')
        .map((event) => event['payload'] as String)
        .first;
    _js(manager).evaluate('globalThis.performUnregister();');
    expect(await unregistered.timeout(const Duration(seconds: 2)), deviceId);
    expect(manager.liveTransportCount, 0);
    expect(
      _js(manager)
          .evaluate('String(globalThis.disconnectCalls || 0)')
          .stringResult,
      '1',
    );
    await sensorController.sensorRegistry
        .where((sensors) => !sensors.containsKey(deviceId))
        .first;
    expect(deviceController.devices, isEmpty);
    expect(states, isNot(contains(ConnectionState.connected)));

    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/x');
    nativeOpen.complete(socket);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    while (_js(manager).executePendingJob() > 0) {}
    expect(manager.liveTransportCount, 0);
    expect(
      _js(manager)
          .evaluate('String(globalThis.connectRejected || false)')
          .stringResult,
      'true',
    );
    expect(states, isNot(contains(ConnectionState.connected)));
  });

  test(
    'stale async connect transport is retired once the attempt settles',
    () async {
      final server = await _startWsServer((ws) {
        ws.listen((data) {});
      });
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
        deviceInvocationTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(() async {
        await manager.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .first;
      await manager.loadPlugin(
        id: 'async-timeout-connect.plugin',
        manifest: testManifest(
          'async-timeout-connect.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode:
            '''
        function createPlugin(host) {
          let transportHandle;
          return {
            id: "async-timeout-connect.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                async connect(transport) {
                  await new Promise((resolve) => {
                    globalThis.releaseAsyncConnect = resolve;
                  });
                  try {
                    const opened = await transport.open({
                      kind: "websocket",
                      url: "ws://127.0.0.1:${server.port}/x"
                    });
                    transportHandle = opened.handle;
                    globalThis.connectCompleted = true;
                    return {};
                  } catch (error) {
                    globalThis.connectRejected = true;
                    throw error;
                  }
                },
                disconnect() {
                  const handle = transportHandle;
                  transportHandle = null;
                  globalThis.disconnectCalls =
                    (globalThis.disconnectCalls || 0) + 1;
                  return handle
                    ? host.transport.close(handle)
                    : Promise.resolve();
                },
                execute() { return {}; }
              }).then((device) => {
                globalThis.performAsyncUnregister = () =>
                  device.unregister().then(() => {
                    host.emit("unregistered", device.deviceId);
                  });
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
      );

      final deviceId = await registered.timeout(const Duration(seconds: 2));
      final devices = await deviceService.devices
          .where(
            (devices) => devices.any((device) => device.deviceId == deviceId),
          )
          .first;
      final sensor = devices.single as Sensor;
      unawaited(sensor.onConnect().catchError((_) {}));
      await sensor.connectionState
          .where((state) => state == ConnectionState.connecting)
          .first
          .timeout(const Duration(seconds: 2));
      await sensor.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .first
          .timeout(const Duration(seconds: 2));

      final states = <ConnectionState>[];
      final stateSubscription = sensor.connectionState.listen(states.add);
      addTearDown(stateSubscription.cancel);
      final unregistered = manager.emitStream
          .where((event) => event['event'] == 'unregistered')
          .map((event) => event['payload'] as String)
          .first;
      _js(manager).evaluate('globalThis.performAsyncUnregister();');
      expect(await unregistered.timeout(const Duration(seconds: 2)), deviceId);
      expect(manager.liveTransportCount, 0);
      await deviceService.devices.where((devices) => devices.isEmpty).first;
      expect(deviceController.devices, isEmpty);
      expect(
        _js(manager)
            .evaluate('String(globalThis.disconnectCalls || 0)')
            .stringResult,
        '1',
      );

      _js(manager).evaluate('globalThis.releaseAsyncConnect();');
      var connectRejected = false;
      for (var i = 0; i < 100 && !connectRejected; i++) {
        while (_js(manager).executePendingJob() > 0) {}
        final result = _js(manager)
            .evaluate('String(globalThis.connectRejected || false)');
        connectRejected = !result.isError && result.stringResult == 'true';
        if (!connectRejected) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      expect(connectRejected, isTrue);
      for (var i = 0; i < 100 && manager.liveTransportCount != 0; i++) {
        while (_js(manager).executePendingJob() > 0) {}
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(manager.liveTransportCount, 0);
      expect(states, isNot(contains(ConnectionState.connected)));
      expect(
        _js(manager)
            .evaluate('String(globalThis.disconnectCalls || 0)')
            .stringResult,
        '1',
      );
    },
  );

  test(
    'retired A cannot open a transport while B remains pending and B connects',
    () async {
      final server = await _startWsServer((ws) {
        ws.listen((data) {});
      });
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
        deviceInvocationTimeout: const Duration(milliseconds: 500),
      );
      addTearDown(() async {
        await manager.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .take(2)
          .toList();
      await manager.loadPlugin(
        id: 'overlap-connect.plugin',
        manifest: testManifest(
          'overlap-connect.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode:
            '''
        function createPlugin(host) {
          function makeHandlers(instanceKey) {
            let transportHandle;
            return {
              async connect(transport) {
                await new Promise((resolve) => {
                  globalThis.connectGates[instanceKey] = resolve;
                });
                try {
                  const opened = await transport.open({
                    kind: "websocket",
                    url: "ws://127.0.0.1:${server.port}/x"
                  });
                  transportHandle = opened.handle;
                  globalThis.connectOutcomes[instanceKey] = "opened";
                  return {};
                } catch (error) {
                  globalThis.connectOutcomes[instanceKey] = "rejected";
                  throw error;
                }
              },
              disconnect() {
                const handle = transportHandle;
                transportHandle = null;
                globalThis.disconnectCounts[instanceKey] =
                  (globalThis.disconnectCounts[instanceKey] || 0) + 1;
                return handle
                  ? host.transport.close(handle)
                  : Promise.resolve();
              },
              execute() { return {}; }
            };
          }
          return {
            id: "overlap-connect.plugin",
            onLoad() {
              globalThis.connectGates = {};
              globalThis.connectOutcomes = {};
              globalThis.disconnectCounts = {};
              const define = (instanceId) => ({
                driverId: "humidity",
                instanceId: instanceId,
                name: "Humidity " + instanceId,
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              });
              Promise.all([
                host.devices.register(
                  define("office"),
                  makeHandlers("office")
                ),
                host.devices.register(define("lab"), makeHandlers("lab"))
              ]).then((devices) => {
                globalThis.performUnregister = (key) =>
                  devices[key === "office" ? 0 : 1].unregister().then(() => {
                    host.emit(
                      "unregistered",
                      devices[key === "office" ? 0 : 1].deviceId
                    );
                  });
                host.emit("registered", devices[0].deviceId);
                host.emit("registered", devices[1].deviceId);
              });
            }
          };
        }
      ''',
      );

      final ids = await registered.timeout(const Duration(seconds: 2));
      final officeId = ids.firstWhere((id) => id.endsWith(':office'));
      final labId = ids.firstWhere((id) => id.endsWith(':lab'));
      final sensors = await deviceService.devices
          .where((devices) => devices.length == 2)
          .first;
      final office = sensors.singleWhere(
        (device) => device.deviceId == officeId,
      ) as Sensor;
      final lab =
          sensors.singleWhere((device) => device.deviceId == labId) as Sensor;
      final officeStates = <ConnectionState>[];
      final officeStatesSubscription = office.connectionState.listen(
        officeStates.add,
      );
      addTearDown(officeStatesSubscription.cancel);
      final labStates = <ConnectionState>[];
      final labStatesSubscription = lab.connectionState.listen(labStates.add);
      addTearDown(labStatesSubscription.cancel);
      unawaited(office.onConnect().catchError((_) {}));
      await office.connectionState
          .where((state) => state == ConnectionState.connecting)
          .first
          .timeout(const Duration(seconds: 2));
      await office.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .first
          .timeout(const Duration(seconds: 2));

      final unregistered = manager.emitStream
          .where(
            (event) =>
                event['event'] == 'unregistered' &&
                event['payload'] == officeId,
          )
          .map((event) => event['payload'] as String)
          .first;
      _js(manager).evaluate('globalThis.performUnregister("office");');
      expect(await unregistered.timeout(const Duration(seconds: 2)), officeId);
      expect(manager.liveTransportCount, 0);
      expect(
        _js(manager)
            .evaluate('String(globalThis.disconnectCounts.office || 0)')
            .stringResult,
        '1',
      );
      await deviceService.devices
          .where(
            (devices) =>
                devices.length == 1 && devices.single.deviceId == labId,
          )
          .first;
      expect(labStates, isNot(contains(ConnectionState.connected)));

      unawaited(lab.onConnect().catchError((_) {}));
      await lab.connectionState
          .where((state) => state == ConnectionState.connecting)
          .first
          .timeout(const Duration(seconds: 2));
      _js(manager).evaluate('globalThis.connectGates.office();');
      while (_js(manager).executePendingJob() > 0) {}
      var officeRejected = false;
      for (var i = 0; i < 100 && !officeRejected; i++) {
        while (_js(manager).executePendingJob() > 0) {}
        final result = _js(manager)
            .evaluate('String(globalThis.connectOutcomes.office || "")');
        officeRejected = !result.isError && result.stringResult == 'rejected';
        if (!officeRejected) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      expect(officeRejected, isTrue);
      expect(manager.liveTransportCount, 0);
      expect(labStates, isNot(contains(ConnectionState.connected)));
      expect(
        _js(manager)
            .evaluate('String(globalThis.disconnectCounts.office || 0)')
            .stringResult,
        '1',
      );
      expect(officeStates, isNot(contains(ConnectionState.connected)));

      _js(manager).evaluate('globalThis.connectGates.lab();');
      while (_js(manager).executePendingJob() > 0) {}
      await lab.connectionState
          .where((state) => state == ConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 2));
      expect(manager.liveTransportCount, 1);
      expect(labStates, contains(ConnectionState.connected));
    },
  );

  test('persistent unrelated plugin transport stays usable after retired A settles', () async {
    final server = await _startWsServer((ws) {
      ws.listen((data) {
        try {
          ws.add(data);
        } catch (_) {}
      });
    });
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
      deviceInvocationTimeout: const Duration(milliseconds: 500),
    );
    addTearDown(() async {
      await manager.dispose();
      deviceController.dispose();
    });

    final registered = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .take(2)
        .toList();
    await manager.loadPlugin(
      id: 'retired-window.plugin',
      manifest: testManifest(
        'retired-window.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode:
          '''
        function createPlugin(host) {
          function makeHandlers(instanceKey) {
            let transportHandle;
            return {
              async connect(transport) {
                await new Promise((resolve) => {
                  globalThis.connectGates[instanceKey] = resolve;
                });
                try {
                  const opened = await transport.open({
                    kind: "websocket",
                    url: "ws://127.0.0.1:${server.port}/x"
                  });
                  transportHandle = opened.handle;
                  globalThis.connectOutcomes[instanceKey] = "opened";
                  return {};
                } catch (error) {
                  globalThis.connectOutcomes[instanceKey] = "rejected";
                  throw error;
                }
              },
              disconnect() {
                const handle = transportHandle;
                transportHandle = null;
                globalThis.disconnectCounts[instanceKey] =
                  (globalThis.disconnectCounts[instanceKey] || 0) + 1;
                return handle
                  ? host.transport.close(handle)
                  : Promise.resolve();
              },
              execute() { return {}; }
            };
          }
          return {
            id: "retired-window.plugin",
            onLoad() {
              globalThis.connectGates = {};
              globalThis.connectOutcomes = {};
              globalThis.disconnectCounts = {};
              const define = (instanceId) => ({
                driverId: "humidity",
                instanceId: instanceId,
                name: "Humidity " + instanceId,
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              });
              Promise.all([
                host.devices.register(
                  define("office"),
                  makeHandlers("office")
                ),
                host.devices.register(define("lab"), makeHandlers("lab"))
              ]).then((devices) => {
                globalThis.performUnregisterOffice = () =>
                  devices[0].unregister().then(() => {
                    host.emit("unregistered", devices[0].deviceId);
                  });
                globalThis.performUnrelatedOpen = () =>
                  host.transport.open({
                    kind: "websocket",
                    url: "ws://127.0.0.1:${server.port}/x"
                  }).then((opened) => {
                    globalThis.unrelatedHandle = opened.handle;
                    host.transport.onEvent(opened.handle, (event) => {
                      if (event.type === "data" && event.data === "still-live") {
                        host.emit("unrelated-roundtrip", event.data);
                      }
                    });
                    globalThis.unrelatedOpened = true;
                  });
                globalThis.performUnrelatedRoundTrip = () =>
                  host.transport.send(globalThis.unrelatedHandle, {
                    type: "text",
                    data: "still-live"
                  });
                globalThis.performUnrelatedClose = () =>
                  host.transport.close(globalThis.unrelatedHandle);
                host.emit("registered", devices[0].deviceId);
                host.emit("registered", devices[1].deviceId);
              });
            }
          };
        }
      ''',
    );

    final ids = await registered.timeout(const Duration(seconds: 2));
    final officeId = ids.firstWhere((id) => id.endsWith(':office'));
    final labId = ids.firstWhere((id) => id.endsWith(':lab'));
    final sensors = await deviceService.devices
        .where((devices) => devices.length == 2)
        .first;
    final office =
        sensors.singleWhere((device) => device.deviceId == officeId) as Sensor;
    final lab =
        sensors.singleWhere((device) => device.deviceId == labId) as Sensor;
    final officeStates = <ConnectionState>[];
    final officeStatesSubscription = office.connectionState.listen(
      officeStates.add,
    );
    addTearDown(officeStatesSubscription.cancel);
    final labStates = <ConnectionState>[];
    final labStatesSubscription = lab.connectionState.listen(labStates.add);
    addTearDown(labStatesSubscription.cancel);
    unawaited(office.onConnect().catchError((_) {}));
    await office.connectionState
        .where((state) => state == ConnectionState.connecting)
        .first
        .timeout(const Duration(seconds: 2));
    await office.connectionState
        .where((state) => state == ConnectionState.disconnected)
        .first
        .timeout(const Duration(seconds: 2));

    final unregistered = manager.emitStream
        .where(
          (event) =>
              event['event'] == 'unregistered' && event['payload'] == officeId,
        )
        .map((event) => event['payload'] as String)
        .first;
    _js(manager).evaluate('globalThis.performUnregisterOffice();');
    expect(await unregistered.timeout(const Duration(seconds: 2)), officeId);
    await deviceService.devices
        .where(
          (devices) => devices.length == 1 && devices.single.deviceId == labId,
        )
        .first;

    _js(manager).evaluate('globalThis.performUnrelatedOpen();');
    var unrelatedOpened = false;
    for (var i = 0; i < 100 && !unrelatedOpened; i++) {
      while (_js(manager).executePendingJob() > 0) {}
      final result = _js(manager)
          .evaluate('String(globalThis.unrelatedOpened || false)');
      unrelatedOpened = !result.isError && result.stringResult == 'true';
      if (!unrelatedOpened) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    expect(unrelatedOpened, isTrue);
    expect(manager.liveTransportCount, 1);

    _js(manager).evaluate('globalThis.connectGates.office();');
    while (_js(manager).executePendingJob() > 0) {}
    var officeRejected = false;
    for (var i = 0; i < 100 && !officeRejected; i++) {
      while (_js(manager).executePendingJob() > 0) {}
      final result = _js(manager)
          .evaluate('String(globalThis.connectOutcomes.office || "")');
      officeRejected = !result.isError && result.stringResult == 'rejected';
      if (!officeRejected) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    expect(officeRejected, isTrue);
    expect(manager.liveTransportCount, 1);
    expect(officeStates, isNot(contains(ConnectionState.connected)));
    expect(
      _js(manager)
          .evaluate('String(globalThis.disconnectCounts.office || 0)')
          .stringResult,
      '1',
    );

    final roundTrip = manager.emitStream
        .where((event) => event['event'] == 'unrelated-roundtrip')
        .map((event) => event['payload'] as String)
        .first;
    _js(manager).evaluate('globalThis.performUnrelatedRoundTrip();');
    expect(await roundTrip.timeout(const Duration(seconds: 2)), 'still-live');
    expect(manager.liveTransportCount, 1);

    _js(manager).evaluate('globalThis.performUnrelatedClose();');
    for (var i = 0; i < 100 && manager.liveTransportCount != 0; i++) {
      while (_js(manager).executePendingJob() > 0) {}
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(manager.liveTransportCount, 0);
  });

  test('device disconnect cleanup runs again after reconnect', () async {
    final server = await _startWsServer((ws) {
      ws.listen((data) {});
    });
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
    );
    addTearDown(() async {
      await manager.dispose();
      sensorController.dispose();
      deviceController.dispose();
    });

    final registered = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .first;
    await manager.loadPlugin(
      id: 'reconnect-cleanup.plugin',
      manifest: testManifest(
        'reconnect-cleanup.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode:
          '''
        function createPlugin(host) {
          let transportHandle;
          return {
            id: "reconnect-cleanup.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect(transport) {
                  return transport.open({
                    kind: "websocket",
                    url: "ws://127.0.0.1:${server.port}/x"
                  }).then((opened) => {
                    transportHandle = opened.handle;
                    globalThis.connectCalls =
                      (globalThis.connectCalls || 0) + 1;
                    return {};
                  });
                },
                disconnect() {
                  const handle = transportHandle;
                  transportHandle = null;
                  return host.transport.close(handle).then(() => {
                    globalThis.disconnectCalls =
                      (globalThis.disconnectCalls || 0) + 1;
                    return {};
                  });
                },
                execute() { return {}; }
              }).then((device) => host.emit("registered", device.deviceId));
            }
          };
        }
      ''',
    );

    final deviceId = await registered.timeout(const Duration(seconds: 2));
    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[deviceId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await sensor.connectionState
        .where((state) => state == ConnectionState.connected)
        .first
        .timeout(const Duration(seconds: 2));
    expect(manager.liveTransportCount, 1);

    final firstDisconnect = sensor.disconnect();
    final repeatedDisconnect = sensor.disconnect();
    expect(identical(firstDisconnect, repeatedDisconnect), isTrue);
    await firstDisconnect;
    expect(manager.liveTransportCount, 0);
    expect(
      _js(manager)
          .evaluate('String(globalThis.disconnectCalls || 0)')
          .stringResult,
      '1',
    );

    await sensor.onConnect();
    expect(manager.liveTransportCount, 1);
    expect(
      _js(manager)
          .evaluate('String(globalThis.connectCalls || 0)')
          .stringResult,
      '2',
    );

    await sensor.disconnect();
    expect(manager.liveTransportCount, 0);
    expect(
      _js(manager)
          .evaluate('String(globalThis.disconnectCalls || 0)')
          .stringResult,
      '2',
    );
  });

  test(
    'direct unregister waits for an in-flight connect before cleanup',
    () async {
      final server = await _startWsServer((ws) {
        ws.listen((data) {});
      });
      final deviceService = PluginDeviceService();
      final deviceController = DeviceController([deviceService]);
      await deviceController.initialize();
      final sensorController = SensorController(controller: deviceController);
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: deviceService,
      );
      addTearDown(() async {
        await manager.dispose();
        sensorController.dispose();
        deviceController.dispose();
      });

      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .map((event) => event['payload'] as String)
          .first;
      await manager.loadPlugin(
        id: 'delayed-connect.plugin',
        manifest: testManifest(
          'delayed-connect.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          drivers: const [
            PluginDriverDeclaration(
              id: 'humidity',
              type: PluginDriverType.sensor,
            ),
          ],
        ),
        settings: const {},
        jsCode:
            '''
        function createPlugin(host) {
          let transportHandle;
          return {
            id: "delayed-connect.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect(transport) {
                  globalThis.connectStarted = true;
                  return new Promise((resolve) => {
                    globalThis.continueConnect = () => {
                      transport.open({
                        kind: "websocket",
                        url: "ws://127.0.0.1:${server.port}/x"
                      }).then((opened) => {
                        transportHandle = opened.handle;
                        globalThis.connectCompleted =
                          (globalThis.connectCompleted || 0) + 1;
                        resolve({});
                      });
                    };
                  });
                },
                disconnect() {
                  const handle = transportHandle;
                  transportHandle = null;
                  globalThis.disconnectCalls =
                    (globalThis.disconnectCalls || 0) + 1;
                  return handle
                    ? host.transport.close(handle)
                    : Promise.resolve();
                },
                execute() { return {}; }
              }).then((device) => {
                globalThis.delayedDevice = device;
                globalThis.performUnregister = () =>
                  device.unregister().then(() => {
                    host.emit("unregistered", device.deviceId);
                  });
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
      );

      final deviceId = await registered.timeout(const Duration(seconds: 2));
      final sensor = await sensorController.sensorRegistry
          .map((sensors) => sensors[deviceId])
          .where((sensor) => sensor != null)
          .cast<Sensor>()
          .first;
      await sensor.connectionState
          .where((state) => state == ConnectionState.connecting)
          .first
          .timeout(const Duration(seconds: 2));
      final states = <ConnectionState>[];
      final stateSubscription = sensor.connectionState.listen(states.add);
      addTearDown(stateSubscription.cancel);

      final unregistered = manager.emitStream
          .where((event) => event['event'] == 'unregistered')
          .map((event) => event['payload'] as String)
          .first;
      _js(manager).evaluate('globalThis.performUnregister();');
      _js(manager).evaluate('globalThis.continueConnect();');
      while (_js(manager).executePendingJob() > 0) {}

      expect(await unregistered.timeout(const Duration(seconds: 10)), deviceId);
      expect(manager.liveTransportCount, 0);
      expect(
        _js(manager)
            .evaluate('String(globalThis.connectCompleted || 0)')
            .stringResult,
        '1',
      );
      expect(
        _js(manager)
            .evaluate('String(globalThis.disconnectCalls || 0)')
            .stringResult,
        '1',
      );
      await sensorController.sensorRegistry
          .where((sensors) => !sensors.containsKey(deviceId))
          .first;
      expect(deviceController.devices, isEmpty);
      expect(states, isNot(contains(ConnectionState.connected)));
    },
  );

  test('dispose runs plugin device disconnect cleanup', () async {
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
    );
    addTearDown(() async {
      await manager.dispose();
      sensorController.dispose();
      deviceController.dispose();
    });

    final registered = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .first;
    await manager.loadPlugin(
      id: 'dispose-device.plugin',
      manifest: testManifest(
        'dispose-device.plugin',
        permissions: const {PluginPermissions.emit},
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode: '''
        function createPlugin(host) {
          return {
            id: "dispose-device.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [{ key: "relativeHumidity", type: "number" }]
              }, {
                connect() {},
                disconnect() {
                  globalThis.disposeDisconnectCalls =
                    (globalThis.disposeDisconnectCalls || 0) + 1;
                  return new Promise((resolve) => {
                    globalThis.resolveDisposeDisconnect = () => {
                      globalThis.disposeDisconnectCompleted =
                        (globalThis.disposeDisconnectCompleted || 0) + 1;
                      resolve();
                    };
                  });
                },
                execute() { return {}; }
              }).then((device) => host.emit("registered", device.deviceId));
            }
          };
        }
      ''',
    );

    final deviceId = await registered.timeout(const Duration(seconds: 2));
    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[deviceId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await sensor.connectionState
        .where((state) => state == ConnectionState.connected)
        .first
        .timeout(const Duration(seconds: 2));

    final js = _js(manager);
    final disposal = manager.dispose();
    var disconnectStarted = false;
    for (
      var i = 0;
      i < 1000 && manager.lifecycle == PluginManagerLifecycle.disposing;
      i++
    ) {
      final calls = js.evaluate(
        'String(globalThis.disposeDisconnectCalls || 0)',
      );
      if (!calls.isError && calls.stringResult == '1') {
        disconnectStarted = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(disconnectStarted, isTrue);
    expect(
      js
          .evaluate('String(globalThis.disposeDisconnectCalls || 0)')
          .stringResult,
      '1',
    );

    js.evaluate('globalThis.resolveDisposeDisconnect();');
    while (js.executePendingJob() > 0) {}
    expect(
      js
          .evaluate('String(globalThis.disposeDisconnectCompleted || 0)')
          .stringResult,
      '1',
    );
    await expectLater(disposal, completes);
    expect(manager.lifecycle, PluginManagerLifecycle.disposed);
    await sensorController.sensorRegistry
        .where((sensors) => !sensors.containsKey(deviceId))
        .first;
    expect(deviceController.devices, isEmpty);
  });

  test('unregister rejects only pending invocations for its device', () async {
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
    );
    addTearDown(() async {
      await manager.dispose();
      sensorController.dispose();
      deviceController.dispose();
    });

    final registrations = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .take(2)
        .toList();
    await manager.loadPlugin(
      id: 'pending-device.plugin',
      manifest: testManifest(
        'pending-device.plugin',
        permissions: const {PluginPermissions.emit},
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode: '''
        function createPlugin(host) {
          function register(instanceId, key) {
            return host.devices.register({
              driverId: "humidity",
              instanceId: instanceId,
              name: instanceId,
              vendor: "Test",
              dataChannels: [{ key: "relativeHumidity", type: "number" }],
              commands: [{ id: "wait" }]
            }, {
              connect() {},
              disconnect() { return {}; },
              execute() {
                return new Promise((resolve) => {
                  globalThis["resolve" + key] = resolve;
                  host.emit(key + "-started", null);
                });
              }
            }).then((device) => {
              globalThis[key + "Device"] = device;
              host.emit("registered", key + ":" + device.deviceId);
            });
          }
          return {
            id: "pending-device.plugin",
            onLoad() {
              globalThis.performFirstUnregister = () =>
                globalThis.FirstDevice.unregister().then(() => {
                  host.emit("unregistered", globalThis.FirstDevice.deviceId);
                });
              register("one", "First");
              register("two", "Second");
            }
          };
        }
      ''',
    );

    final ids = await registrations.timeout(const Duration(seconds: 10));
    final firstId = ids
        .firstWhere((id) => id.startsWith('First:'))
        .substring('First:'.length);
    final secondId = ids
        .firstWhere((id) => id.startsWith('Second:'))
        .substring('Second:'.length);
    final firstSensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[firstId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    final secondSensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[secondId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await Future.wait([
      firstSensor.connectionState
          .where((state) => state == ConnectionState.connected)
          .first,
      secondSensor.connectionState
          .where((state) => state == ConnectionState.connected)
          .first,
    ]);

    final firstStarted = manager.emitStream
        .where((event) => event['event'] == 'First-started')
        .first;
    final secondStarted = manager.emitStream
        .where((event) => event['event'] == 'Second-started')
        .first;
    final firstCommand = firstSensor.execute('wait', null);
    final secondCommand = secondSensor.execute('wait', null);
    await Future.wait([firstStarted, secondStarted])
        .timeout(const Duration(seconds: 10));
    final firstFailure = expectLater(
      firstCommand,
      throwsA(
        isA<PluginDeviceException>().having(
          (error) => error.message,
          'message',
          'Plugin device unregistered',
        ),
      ),
    );
    final secondResult = expectLater(secondCommand, completion(isEmpty));

    final unregistered = manager.emitStream
        .where((event) => event['event'] == 'unregistered')
        .map((event) => event['payload'] as String)
        .first;
    _js(manager).evaluate('globalThis.performFirstUnregister();');
    while (_js(manager).executePendingJob() > 0) {}
    expect(await unregistered.timeout(const Duration(seconds: 10)), firstId);
    await firstFailure;
    _js(manager).evaluate('globalThis.resolveFirst({});');
    _js(manager).evaluate('globalThis.resolveSecond({});');
    while (_js(manager).executePendingJob() > 0) {}
    await secondResult.timeout(const Duration(seconds: 10));
    await sensorController.sensorRegistry
        .where((sensors) => !sensors.containsKey(firstId))
        .first;
    expect(deviceController.devices.map((device) => device.deviceId), [
      secondId,
    ]);
  });
}

Future<HttpServer> _startWsServer(void Function(WebSocket ws) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    try {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        handler(ws);
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    } catch (_) {}
  });
  addTearDown(() => server.close(force: true));
  return server;
}
