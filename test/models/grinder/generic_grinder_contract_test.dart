import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/grinder_capabilities.dart';
import 'package:reaprime/src/models/device/grinder_operation.dart';
import 'package:reaprime/src/models/device/grinder_setting.dart';
import 'package:reaprime/src/models/device/grinder_snapshot.dart';

void main() {
  test(
    'E64 capability remains calibration-only before physical validation',
    () {
      expect(
        GrinderCapabilities.e64Ws.adjustment,
        GrinderAdjustmentMode.calibrationOnly,
      );
      expect(GrinderCapabilities.e64Ws.safety.minimumSetting, isNull);
      expect(GrinderCapabilities.e64Ws.safety.maximumSetting, isNull);
      expect(
        GrinderCapabilities.e64Ws.observedProtocolFeatures,
        contains('grind-by-weight.action'),
      );
      expect(GrinderCapabilities.e64Ws.supportsGrindByWeight, isFalse);
      expect(GrinderCapabilities.e64Ws.acceptsBrewEvidence, isFalse);
    },
  );

  test('generic command preserves a typed setting and operation id', () {
    final command = GrinderCommand(
      operation: GrinderOperationId.applyAbsolute,
      operationId: 'op-1',
      setting: const NumericGrinderSetting(
        domain: 'mahlkoenig.dd_dum',
        value: 5120,
        unit: 'dum',
      ),
      confirmed: true,
    );
    expect(command.toJson()['operation'], 'grinder.apply.absolute');
    expect(command.toJson()['setting']['value'], 5120);
  });

  test('snapshot freshness preserves connected and stale boundaries', () {
    final now = DateTime.utc(2026, 1, 1, 12);
    final snapshot = GrinderSnapshot(
      deviceId: 'sim-e64',
      observedAt: now.subtract(const Duration(seconds: 2)),
      connected: true,
      idle: true,
      motorRunning: false,
    );
    expect(snapshot.isFresh(now, const Duration(seconds: 2)), isTrue);
    expect(snapshot.isFresh(now, const Duration(seconds: 1)), isFalse);
    final futureSnapshot = GrinderSnapshot(
      deviceId: 'sim-e64',
      observedAt: now.add(const Duration(seconds: 1)),
      connected: true,
      idle: true,
      motorRunning: false,
    );
    expect(futureSnapshot.isFresh(now, const Duration(seconds: 2)), isFalse);
  });

  test('safety bounds accept numeric settings without inventing limits', () {
    const bounded = GrinderSafetyConstraints(
      minimumSetting: 0,
      maximumSetting: 10000,
    );
    expect(bounded.accepts(0), isTrue);
    expect(bounded.accepts(10000.0), isTrue);
    expect(bounded.accepts(10000.1), isFalse);
    expect(GrinderCapabilities.e64Ws.safety.accepts(100000), isTrue);
  });
}
