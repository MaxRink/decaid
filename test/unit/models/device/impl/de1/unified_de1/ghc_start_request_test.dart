import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

void main() {
  late List<LogRecord> records;

  setUp(() {
    records = [];
    final logs = Logger.root.onRecord
        .where((record) => record.loggerName == 'DE1')
        .listen(records.add);
    addTearDown(logs.cancel);
  });

  Future<(UnifiedDe1, FakeBleTransport)> connect({required int ghcInfo}) async {
    final transport = FakeBleTransport()
      ..queueOnConnectResponses(ghcInfo: ghcInfo);
    final de1 = UnifiedDe1(transport: transport);
    await de1.onConnect();
    records.clear();
    transport.writes.clear();
    return (de1, transport);
  }

  Iterable<String> ghcNotices() => records
      .map((record) => record.message)
      .where((message) => message.contains('group head controller'));

  int stateWrites(FakeBleTransport transport) => transport.writes
      .where(
        (write) => write.characteristicUUID == Endpoint.requestedState.uuid,
      )
      .length;

  for (final state in [
    MachineState.espresso,
    MachineState.steam,
    MachineState.hotWater,
    MachineState.flush,
  ]) {
    test(
      'a remote ${state.name} start on an active GHC is sent and logged',
      () async {
        final (de1, transport) = await connect(ghcInfo: 0x04);

        await de1.requestState(state);

        expect(stateWrites(transport), 1);
        expect(ghcNotices(), hasLength(1));
        expect(ghcNotices().single, contains(state.name));
      },
    );
  }

  test('stopping an active-GHC machine is not flagged', () async {
    final (de1, transport) = await connect(ghcInfo: 0x04);

    await de1.requestState(MachineState.idle);

    expect(stateWrites(transport), 1);
    expect(ghcNotices(), isEmpty);
  });

  test('a start without an active GHC is not flagged', () async {
    final (de1, transport) = await connect(ghcInfo: 0);

    await de1.requestState(MachineState.espresso);

    expect(stateWrites(transport), 1);
    expect(ghcNotices(), isEmpty);
  });
}
