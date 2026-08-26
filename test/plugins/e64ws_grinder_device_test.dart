import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/grinder_capabilities.dart';
import 'package:reaprime/src/models/device/grinder_operation.dart';
import 'package:reaprime/src/plugins/e64ws_grinder_device.dart';

Map<String, dynamic> state({
  required num dd,
  String? revision = 'r1',
}) => {
  'type': 'RequestDriverStateResult',
  'data': _stateData(dd, revision),
};

Map<String, dynamic> _stateData(num dd, String? revision) {
  final data = <String, dynamic>{'grindState': 'Idle', 'ddValueDum': dd};
  if (revision != null) data['revision'] = revision;
  return data;
}

const validatedRelative = GrinderCapabilities(
  readsCurrentSetting: true,
  adjustment: GrinderAdjustmentMode.relative,
  relativeStepUnit: 'dum',
  safety: GrinderSafetyConstraints(
    minimumSetting: 0,
    maximumSetting: 10000,
    readbackTolerance: 0.5,
  ),
);

void main() {
  test('reads config and GBS only from their exact response types', () async {
    final device = E64WsGrinderDevice(
      deviceId: 'e64-test',
      name: 'E64 test',
      capabilities: const GrinderCapabilities(
        readsCurrentSetting: true,
        exposesNativeGbsReport: true,
      ),
      request: (operation, _) async {
        if (operation == 'driver_config') {
          return {
            'type': 'RequestDriverConfigResult',
            'data': {'ddMaxDum': 10000},
          };
        }
        return {
          'type': 'GbsCreateReport',
          'data': {'algorithm': 'GbS1'},
        };
      },
    );

    final config = await device.execute(
      const GrinderCommand(
        operation: GrinderOperationId.readConfig,
        operationId: 'config',
      ),
    );
    final gbs = await device.execute(
      const GrinderCommand(
        operation: GrinderOperationId.requestNativeGbsReport,
        operationId: 'gbs',
      ),
    );

    expect(config.status, GrinderOperationStatus.verified);
    expect(gbs.status, GrinderOperationStatus.verified);
    await device.close();
  });

  test('translates assistant steps into native E64 DUM and verifies readback',
      () async {
    final operations = <String>[];
    var stateReads = 0;
    final device = E64WsGrinderDevice(
      deviceId: 'e64-test',
      name: 'E64 test',
      capabilities: validatedRelative,
      request: (operation, arguments) async {
        operations.add(operation);
        if (operation == 'driver_state') {
          stateReads++;
          return state(dd: stateReads == 1 ? 5000 : 4998);
        }
        expect(operation, 'action');
        expect(arguments['data'], {
          'targetDdValue': 4998,
          'unit': 'dum',
          'domain': 'e64.dd',
        });
        return {
          'type': 'GrinderActionResult',
          'refId': 1,
          'data': {'success': true},
        };
      },
    );

    final result = await device.execute(
      const GrinderCommand(
        operation: GrinderOperationId.applyRelative,
        operationId: 'adjust',
        relativeDelta: -2,
        expectedRevision: 'r1',
        confirmed: true,
      ),
    );

    expect(
      result.status,
      GrinderOperationStatus.verified,
      reason: result.message,
    );
    expect(operations, ['driver_state', 'action', 'driver_state']);
    await device.close();
  });

  test('rejects malformed action responses and fake preparation', () async {
    final device = E64WsGrinderDevice(
      deviceId: 'e64-test',
      name: 'E64 test',
      capabilities: validatedRelative,
      request: (operation, _) async {
        if (operation == 'driver_state') return state(dd: 5000);
        return {
          'type': 'UnknownType',
          'data': {'success': true},
        };
      },
    );
    final malformed = await device.execute(
      const GrinderCommand(
        operation: GrinderOperationId.applyRelative,
        operationId: 'malformed',
        relativeDelta: 1,
        expectedRevision: 'r1',
        confirmed: true,
      ),
    );
    expect(malformed.status, GrinderOperationStatus.rejected);

    final preparation = await device.execute(
      const GrinderCommand(
        operation: GrinderOperationId.prepareApply,
        operationId: 'prepare',
        confirmed: true,
      ),
    );
    expect(preparation.status, GrinderOperationStatus.rejected);
    expect(preparation.message, contains('preparation tokens'));
    await device.close();
  });

  test('capability modes do not cross-enable absolute and relative writes', () {
    const relative = GrinderCapabilities(
      adjustment: GrinderAdjustmentMode.relative,
    );
    const absolute = GrinderCapabilities(
      adjustment: GrinderAdjustmentMode.absolute,
    );
    expect(relative.allows(GrinderOperationId.applyRelative), isTrue);
    expect(relative.allows(GrinderOperationId.applyAbsolute), isFalse);
    expect(absolute.allows(GrinderOperationId.applyAbsolute), isTrue);
    expect(absolute.allows(GrinderOperationId.applyRelative), isFalse);
  });
}
