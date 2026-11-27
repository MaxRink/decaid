import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';

import 'plugin_test_helpers.dart';

void main() {
  late PluginManager manager;

  setUp(() {
    manager = PluginManager(kvStore: FakeKeyValueStoreService());
  });

  tearDown(() async => manager.dispose());

  Future<List<String>> collectEvents(Duration window) async {
    final events = <String>[];
    final sub = manager.emitStream.listen(
      (e) => events.add(e['event'] as String),
    );
    await Future<void>.delayed(window);
    await sub.cancel();
    return events;
  }

  // The JS timer registry lives in the plugin's realm. Once the plugin is
  // gone (unload or failed load) the realm must be disposed with it.
  void expectNoJsTimers() {
    if (manager.loadedPlugins.isEmpty) {
      expect(manager.liveRealmCount, 0);
      expect(() => manager.jsRealmOf('timer.plugin'), throwsStateError);
      return;
    }
    expect(
      manager
          .jsRealmOf('timer.plugin')
          .evaluate('String(globalThis.__debugTimerCount())')
          .stringResult,
      '0',
    );
  }

  Future<void> loadTimerPlugin(String jsBody) async {
    await manager.loadPlugin(
      id: 'timer.plugin',
      manifest: testManifest('timer.plugin'),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "timer.plugin",
            onLoad() {
              $jsBody
            }
          };
        }
      ''',
    );
  }

  test(
    'setTimeout fires exactly once and removes the registry entry',
    () async {
      await loadTimerPlugin('''
      setTimeout(() => host.emit("fired", "once"), 20);
    ''');

      final events = await collectEvents(const Duration(milliseconds: 300));

      expect(events, ['fired']);
      expect(manager.activeTimerCount, 0);
      expectNoJsTimers();
    },
  );

  test('clearTimeout cancels the matching timer', () async {
    await loadTimerPlugin('''
      const id = setTimeout(() => host.emit("bad", "fired"), 20);
      clearTimeout(id);
      setTimeout(() => host.emit("good", "fired"), 60);
    ''');

    final events = await collectEvents(const Duration(milliseconds: 300));

    expect(events, ['good']);
    expect(manager.activeTimerCount, 0);
    expectNoJsTimers();
  });

  test('plugin unload cancels armed timers', () async {
    await loadTimerPlugin('''
      setTimeout(() => host.emit("ghost", "fired"), 60);
    ''');

    await manager.unloadPlugin('timer.plugin');
    final events = await collectEvents(const Duration(milliseconds: 200));

    expect(events, isEmpty);
    expect(manager.activeTimerCount, 0);
    expectNoJsTimers();
  });

  test('throwing callback still removes timer and registry entry', () async {
    await loadTimerPlugin('''
      setTimeout(() => { throw new Error("boom"); }, 20);
      setTimeout(() => host.emit("afterThrow", "stillFired"), 60);
    ''');

    final events = await collectEvents(const Duration(milliseconds: 300));

    expect(events, ['afterThrow']);
    expect(manager.activeTimerCount, 0);
    expectNoJsTimers();
  });

  test(
    'failed plugin load cleans up async work created during onLoad',
    () async {
      await expectLater(
        manager.loadPlugin(
          id: 'timer.plugin',
          manifest: testManifest('timer.plugin'),
          settings: {},
          jsCode: r'''
          function createPlugin(host) {
            return {
              id: "timer.plugin",
              onLoad() {
                setTimeout(() => host.emit("ghost", "fired"), 1000);
                throw new Error("onLoad boom");
              }
            };
          }
        ''',
        ),
        throwsA(isA<Exception>()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(manager.activeTimerCount, 0);
      expect(manager.activePendingOpCount, 0);
      expectNoJsTimers();
    },
  );

  test('unload sweeps timers scheduled by rejection handlers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await Future<void>.delayed(const Duration(seconds: 10));
      try {
        await req.response.close();
      } catch (_) {}
    });
    addTearDown(server.close);

    await manager.loadPlugin(
      id: 'timer.plugin',
      manifest: testManifest('timer.plugin'),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "timer.plugin",
            onLoad() {
              fetch("http://127.0.0.1:${server.port}/slow")
                .then(() => host.emit("r", "unexpected"))
                .catch(() => {
                  setTimeout(() => host.emit("ghost", "fired"), 1000);
                });
            }
          };
        }
      ''',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await manager.unloadPlugin('timer.plugin');

    expect(manager.activeTimerCount, 0);
    expectNoJsTimers();

    final events = await collectEvents(const Duration(milliseconds: 1100));
    expect(events, isEmpty);
    expect(manager.activeTimerCount, 0);
    expectNoJsTimers();
  });

  test('timer from a previous plugin generation is not registered', () async {
    await loadTimerPlugin(
      'setTimeout(() => host.emit("ghost", "fired"), 1000);',
    );
    await manager.unloadPlugin('timer.plugin');
    await manager.loadPlugin(
      id: 'timer.plugin',
      manifest: testManifest('timer.plugin'),
      settings: {},
      jsCode: 'function createPlugin(host) { return { id: "timer.plugin" }; }',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(manager.activeTimerCount, 0);
    expectNoJsTimers();

    final events = await collectEvents(const Duration(milliseconds: 1100));
    expect(events, isEmpty);
  });

  test('cancelAllOperations cancels multiple plugin-owned timers', () async {
    await loadTimerPlugin('''
      setTimeout(() => host.emit("a", "fired"), 1000);
      setTimeout(() => host.emit("b", "fired"), 1000);
    ''');

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(manager.activeTimerCount, 2);
    manager.cancelAllOperations();
    expect(manager.activeTimerCount, 0);

    final events = await collectEvents(const Duration(milliseconds: 200));

    expect(events, isEmpty);
    expectNoJsTimers();
  });
}
