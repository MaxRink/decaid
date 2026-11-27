import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

class _CountingWorkflowController extends WorkflowController {
  int addListenerCalls = 0;
  int removeListenerCalls = 0;

  @override
  void addListener(VoidCallback listener) {
    addListenerCalls += 1;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    removeListenerCalls += 1;
    super.removeListener(listener);
  }
}

Future<void> _loadPlugin(
  PluginManager manager,
  String id, {
  bool permitted = true,
  String onLoad = '',
}) {
  return manager.loadPlugin(
    id: id,
    manifest: testManifest(
      id,
      permissions: {if (permitted) PluginPermissions.eventsWorkflow},
    ),
    settings: const {},
    jsCode:
        '''
      function createPlugin(host) {
        return {
          id: "$id",
          onLoad() { $onLoad },
          onEvent(event) {
            if (event.name !== "workflowUpdated") return;
            globalThis.__workflowEvents ??= {};
            globalThis.__workflowEvents["$id"] ??= [];
            globalThis.__workflowEvents["$id"].push(event.payload);
          }
        };
      }
    ''',
  );
}

List<Map<String, dynamic>> _events(PluginManager manager, String id) {
  final result = manager
      .jsRealmOf(id)
      .evaluate('JSON.stringify(globalThis.__workflowEvents?.["$id"] ?? [])');
  return (jsonDecode(result.stringResult) as List<dynamic>)
      .cast<Map<String, dynamic>>();
}

void _advance(WorkflowController controller) {
  controller.setWorkflow(controller.currentWorkflow.copyWith());
}

void main() {
  test(
    'host broadcasts skip a plugin without the permission silently',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final controller = WorkflowController();
      addTearDown(manager.dispose);
      addTearDown(controller.dispose);
      final denials = <String>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord
          .where((record) => record.message.contains('denied permission'))
          .listen((record) => denials.add(record.message));
      addTearDown(() {
        Logger.root.level = previousLevel;
        return subscription.cancel();
      });

      manager.attachWorkflowController(controller);
      await _loadPlugin(manager, 'quiet.plugin', permitted: false);
      _advance(controller);
      await _loadPlugin(manager, 'other.plugin');

      expect(_events(manager, 'quiet.plugin'), isEmpty);
      expect(denials, isEmpty);
    },
  );

  test('a plugin-reported denial is still logged', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    final denials = <String>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord
        .where((record) => record.message.contains('denied permission'))
        .listen((record) => denials.add(record.message));
    addTearDown(() {
      Logger.root.level = previousLevel;
      return subscription.cancel();
    });

    await _loadPlugin(
      manager,
      'asking.plugin',
      permitted: false,
      onLoad: 'host.transport.open({ kind: "tcp", host: "127.0.0.1", port: 9 }).catch(() => {});',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(denials, [contains('asking.plugin denied permission network.tcp')]);
  });

  test('permission gates snapshots and workflow change events', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = WorkflowController();
    addTearDown(manager.dispose);
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    await _loadPlugin(manager, 'permitted.plugin');
    await _loadPlugin(manager, 'denied.plugin', permitted: false);
    final initialWorkflow = controller.currentWorkflow.toJson();
    controller.notifyListeners();
    controller.setWorkflow(
      controller.currentWorkflow.copyWith(name: 'Selected workflow'),
    );
    final selectedWorkflow = controller.currentWorkflow.toJson();
    controller.updateWorkflow(
      context: controller.currentWorkflow.context!.copyWith(targetYield: 42),
    );
    final updatedWorkflow = controller.currentWorkflow.toJson();

    expect(_events(manager, 'permitted.plugin'), [
      initialWorkflow,
      selectedWorkflow,
      updatedWorkflow,
    ]);
    expect(_events(manager, 'denied.plugin'), isEmpty);
  });

  test('late load and reload each receive one current snapshot', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = WorkflowController();
    addTearDown(manager.dispose);
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    _advance(controller);
    _advance(controller);
    final currentWorkflow = controller.currentWorkflow.toJson();
    await _loadPlugin(manager, 'reloaded.plugin');
    expect(_events(manager, 'reloaded.plugin'), [currentWorkflow]);
    await _loadPlugin(manager, 'reloaded.plugin');

    // The reload runs in a fresh realm, so it must hold exactly its own one.
    expect(_events(manager, 'reloaded.plugin'), [currentWorkflow]);
  });

  test('loading another plugin does not repeat existing snapshots', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = WorkflowController();
    addTearDown(manager.dispose);
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    await _loadPlugin(manager, 'first.plugin');
    await _loadPlugin(manager, 'second.plugin');

    expect(_events(manager, 'first.plugin'), hasLength(1));
    expect(_events(manager, 'second.plugin'), hasLength(1));
  });

  test(
    'attachment snapshots once and replacement or detach removes listeners',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final first = _CountingWorkflowController();
      final second = _CountingWorkflowController();
      addTearDown(manager.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await _loadPlugin(manager, 'events.plugin');
      expect(_events(manager, 'events.plugin'), isEmpty);

      manager.attachWorkflowController(first);
      final firstWorkflow = first.currentWorkflow.toJson();
      manager.attachWorkflowController(first);
      manager.attachWorkflowController(second);
      final secondWorkflow = second.currentWorkflow.toJson();
      _advance(first);
      _advance(second);
      final updatedSecondWorkflow = second.currentWorkflow.toJson();
      manager.attachWorkflowController(null);
      _advance(second);

      expect(first.addListenerCalls, 1);
      expect(first.removeListenerCalls, 1);
      expect(second.addListenerCalls, 1);
      expect(second.removeListenerCalls, 1);
      expect(_events(manager, 'events.plugin'), [
        firstWorkflow,
        secondWorkflow,
        updatedSecondWorkflow,
      ]);
    },
  );

  test('dispose removes the listener and blocks later events', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = _CountingWorkflowController();
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    await _loadPlugin(manager, 'events.plugin');
    await manager.dispose();
    _advance(controller);

    expect(controller.addListenerCalls, 1);
    expect(controller.removeListenerCalls, 1);
  });

  test('failed loads do not receive snapshots', () async {
    // A failed load disposes its realm, so record deliveries on the Dart side.
    final delivered = <String, List<Object?>>{};
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      debugPrepareRealm: (pluginId, js) {
        js.onMessage(
          'workflowEvents',
          (payload) => (delivered[pluginId] ??= []).add(payload),
        );
        final result = js.evaluate('''
          const sink = [];
          sink.push = (payload) =>
            sendMessage("workflowEvents", JSON.stringify(payload));
          globalThis.__workflowEvents = { [${jsonEncode(pluginId)}]: sink };
        ''');
        expect(result.isError, isFalse, reason: result.stringResult);
      },
    );
    final controller = WorkflowController();
    addTearDown(manager.dispose);
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    await _loadPlugin(manager, 'control.plugin');
    expect(delivered['control.plugin'], hasLength(1));
    await expectLater(
      _loadPlugin(manager, 'failed.plugin', onLoad: 'throw new Error("boom");'),
      throwsException,
    );

    expect(delivered['failed.plugin'], isNull);
  });
}
