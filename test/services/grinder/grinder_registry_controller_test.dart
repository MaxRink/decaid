import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/grinder_capabilities.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/models/device/grinder_operation.dart';
import 'package:reaprime/src/models/device/grinder_snapshot.dart';
import 'package:reaprime/src/services/grinder/grinder_controller.dart';
import 'package:reaprime/src/services/grinder/grinder_registry.dart';

class _FakeGrinder implements GrinderDevice {
  _FakeGrinder(this.deviceId, this.snapshot);

  @override
  final String deviceId;

  final GrinderSnapshot snapshot;

  @override
  String get name => 'Fake grinder';

  @override
  GrinderCapabilities get capabilities => GrinderCapabilities.e64Ws;

  @override
  Stream<GrinderSnapshot> get snapshots => Stream.value(snapshot);

  @override
  Future<GrinderSnapshot> readSnapshot() async => snapshot;

  @override
  Future<GrinderOperationResult> execute(GrinderCommand command) {
    fail('read-only controller must not execute commands');
  }
}

void main() {
  final snapshot = GrinderSnapshot(
    deviceId: 'e64-1',
    observedAt: DateTime.utc(2026, 1, 1),
    connected: true,
    idle: true,
    motorRunning: false,
  );

  test('registry rejects duplicate and empty identities', () {
    final registry = InMemoryGrinderRegistry();
    final device = _FakeGrinder('e64-1', snapshot);
    registry.register(device);

    expect(() => registry.register(device), throwsStateError);
    expect(
      () => registry.register(_FakeGrinder('', snapshot)),
      throwsArgumentError,
    );
    expect(registry.find('e64-1'), same(device));
    expect(registry.unregister('e64-1'), isTrue);
    expect(registry.unregister('e64-1'), isFalse);
    registry.dispose();
  });

  test('read-only controller reads only registered snapshots', () async {
    final registry = InMemoryGrinderRegistry();
    registry.register(_FakeGrinder('e64-1', snapshot));
    final controller = ReadOnlyGrinderController(registry);

    expect(await controller.readSnapshot('e64-1'), same(snapshot));
    expect(await controller.snapshots('e64-1').first, same(snapshot));
    expect(() => controller.readSnapshot('missing'), throwsStateError);
    registry.dispose();
  });

  test('E64 static capabilities gate every physical write', () {
    final capabilities = GrinderCapabilities.e64Ws;
    expect(capabilities.allows(GrinderOperationId.readSnapshot), isTrue);
    expect(capabilities.allows(GrinderOperationId.readConfig), isTrue);
    expect(
      capabilities.allows(GrinderOperationId.requestNativeGbsReport),
      isTrue,
    );
    expect(capabilities.allows(GrinderOperationId.applyAbsolute), isFalse);
    expect(capabilities.allows(GrinderOperationId.applyRelative), isFalse);
    expect(capabilities.allows(GrinderOperationId.stop), isFalse);
    expect(capabilities.allows(GrinderOperationId.addBrewEvidence), isFalse);
  });
}
