import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/skale/skale2_scale.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

class _RecordableBleTransport extends BLETransport {
  final List<String> serviceUUIDs = const [
    '0000ff08-0000-1000-8000-00805f9b34fb',
  ];

  final List<String> operations = [];

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.disconnected);

  final Map<String, void Function(Uint8List)> _notifyCallbacks = {};

  Uint8List batteryValue = Uint8List.fromList([80]);
  Uint8List firmwareValue = Uint8List.fromList('1.2.3'.codeUnits);
  Object? batteryError;
  int batteryReadCount = 0;

  _RecordableBleTransport();

  @override
  String get id => 'skale2-test-device';

  @override
  String get name => 'Test Skale2';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  Future<void> emitConnectionState(ConnectionState state) async {
    _connectionState.add(state);
  }

  @override
  Future<ConnectionState> getConnectionState() async => _connectionState.value;

  @override
  Future<void> connect() async {
    _connectionState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => serviceUUIDs;

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    final shortUuid = characteristicUUID.substring(4, 8).toLowerCase();
    operations.add('subscribe:$shortUuid');
    _notifyCallbacks[shortUuid] = callback;
  }

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async {
    final shortUuid = characteristicUUID.substring(4, 8).toLowerCase();
    operations.add('read:$shortUuid');
    if (shortUuid == '2a19') {
      batteryReadCount++;
      if (batteryError != null) throw batteryError!;
      return batteryValue;
    }
    if (shortUuid == '2a26') {
      return firmwareValue;
    }
    return Uint8List(0);
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    final shortUuid = characteristicUUID.substring(4, 8).toLowerCase();
    final hexData = data
        .map((b) => '0x${b.toRadixString(16).toUpperCase()}')
        .join(',');
    operations.add('write:$shortUuid:[$hexData]');
  }

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> dispose() async {
    _connectionState.close();
  }

  void simulateWeightNotification(List<int> data) {
    _notifyCallbacks['ef81']?.call(Uint8List.fromList(data));
  }

  void simulateButtonNotification(List<int> data) {
    _notifyCallbacks['ef82']?.call(Uint8List.fromList(data));
  }

  bool isSubscribed(String shortUuid) =>
      _notifyCallbacks.containsKey(shortUuid.toLowerCase());

  void clearSubscriptions() {
    _notifyCallbacks.clear();
  }
}

void main() {
  group('Skale2Scale initialization sequence', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      scale = Skale2Scale(transport: transport, initStepDelay: Duration.zero);
      await transport.emitConnectionState(ConnectionState.discovered);
      addTearDown(scale.disconnect);
    });

    test(
      'LCD ON (0xED) is sent before subscribing to weight notifications',
      () async {
        await scale.onConnect();

        final lcdOnIndex = transport.operations.indexWhere(
          (op) => op.contains('write:ef80:[0xED]'),
        );
        final weightSubIndex = transport.operations.indexWhere(
          (op) => op == 'subscribe:ef81',
        );

        expect(lcdOnIndex, isNot(equals(-1)), reason: 'LCD ON should be sent');
        expect(
          weightSubIndex,
          isNot(equals(-1)),
          reason: 'weight should be subscribed',
        );
        expect(
          lcdOnIndex,
          lessThan(weightSubIndex),
          reason:
              'LCD ON must be sent before subscribing to weight notifications',
        );
      },
    );

    test(
      'LCD ON (0xEC display weight) is sent before subscribing to weight notifications',
      () async {
        await scale.onConnect();

        final displayWeightIndex = transport.operations.indexWhere(
          (op) => op.contains('write:ef80:[0xEC]'),
        );
        final weightSubIndex = transport.operations.indexWhere(
          (op) => op == 'subscribe:ef81',
        );

        expect(
          displayWeightIndex,
          isNot(equals(-1)),
          reason: 'Display weight should be sent',
        );
        expect(
          weightSubIndex,
          isNot(equals(-1)),
          reason: 'weight should be subscribed',
        );
        expect(
          displayWeightIndex,
          lessThan(weightSubIndex),
          reason:
              'Display weight command must be sent before subscribing to weight',
        );
      },
    );

    test(
      'button notifications are subscribed after weight notifications',
      () async {
        await scale.onConnect();

        final weightSubIndex = transport.operations.indexWhere(
          (op) => op == 'subscribe:ef81',
        );
        final buttonSubIndex = transport.operations.indexWhere(
          (op) => op == 'subscribe:ef82',
        );

        expect(weightSubIndex, isNot(equals(-1)));
        expect(buttonSubIndex, isNot(equals(-1)));
        expect(
          weightSubIndex,
          lessThan(buttonSubIndex),
          reason: 'Button subscription should come after weight subscription',
        );
      },
    );

    test(
      'LCD ON is sent a second time after all subscriptions (double-send)',
      () async {
        await scale.onConnect();

        final lcdOnCount = transport.operations
            .where((op) => op.contains('write:ef80:[0xED]'))
            .length;

        expect(
          lcdOnCount,
          greaterThanOrEqualTo(2),
          reason:
              'LCD ON should be sent at least twice (de1app double-send pattern)',
        );
      },
    );

    test('grams command (0x03) is sent after the second LCD ON', () async {
      await scale.onConnect();

      final gramsIndex = transport.operations.indexWhere(
        (op) => op.contains('write:ef80:[0x3]'),
      );
      final lcdOnIndices = transport.operations
          .asMap()
          .entries
          .where((e) => e.value.contains('write:ef80:[0xED]'))
          .map((e) => e.key)
          .toList();

      expect(
        gramsIndex,
        isNot(equals(-1)),
        reason: 'grams command should be sent',
      );
      expect(
        lcdOnIndices.length,
        greaterThanOrEqualTo(2),
        reason: 'LCD ON should be sent at least twice',
      );
      expect(
        gramsIndex,
        greaterThan(lcdOnIndices.last),
        reason: 'grams command should come after the second LCD ON',
      );
    });

    test('USB-powered mode suppresses battery reads and reporting', () async {
      scale.setUsbPowered(true);

      await scale.onConnect();

      expect(transport.batteryReadCount, 0);
      expect(
        scale.currentDeviceInformation?.powerSource,
        DevicePowerSource.usb,
      );
      expect(scale.currentDeviceInformation?.batteryLevel, isNull);
    });

    test(
      'button notifications are not best-effort — subscription is explicit',
      () async {
        await scale.onConnect();

        expect(
          transport.isSubscribed('ef82'),
          isTrue,
          reason:
              'Button notifications must be subscribed, not silently skipped',
        );
      },
    );
  });

  group('Skale2Scale wakeDisplay re-subscribes notifications', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      scale = Skale2Scale(transport: transport, initStepDelay: Duration.zero);
      await transport.emitConnectionState(ConnectionState.discovered);
      await scale.onConnect();
      transport.operations.clear();
      addTearDown(scale.disconnect);
    });

    test('wakeDisplay sends LCD ON (0xED) and display weight (0xEC)', () async {
      await scale.wakeDisplay();

      expect(transport.operations.any((op) => op.contains('0xED')), isTrue);
      expect(transport.operations.any((op) => op.contains('0xEC')), isTrue);
    });

    test('wakeDisplay re-subscribes to weight notifications', () async {
      await transport.emitConnectionState(ConnectionState.disconnected);
      transport.clearSubscriptions();

      await scale.wakeDisplay();

      expect(
        transport.operations.any((op) => op == 'subscribe:ef81'),
        isTrue,
        reason: 'wakeDisplay should re-subscribe to weight notifications',
      );
      expect(
        transport.isSubscribed('ef81'),
        isTrue,
        reason: 'weight subscription should be active after wake',
      );
    });

    test('wakeDisplay re-subscribes to button notifications', () async {
      await transport.emitConnectionState(ConnectionState.disconnected);
      transport.clearSubscriptions();

      await scale.wakeDisplay();

      expect(
        transport.operations.any((op) => op == 'subscribe:ef82'),
        isTrue,
        reason: 'wakeDisplay should re-subscribe to button notifications',
      );
      expect(
        transport.isSubscribed('ef82'),
        isTrue,
        reason: 'button subscription should be active after wake',
      );
    });

    test(
      'wakeDisplay does NOT re-subscribe if subscriptions are still active',
      () async {
        await scale.wakeDisplay();

        expect(
          transport.operations.any((op) => op == 'subscribe:ef81'),
          isFalse,
          reason:
              'wakeDisplay should not redundantly subscribe if already active',
        );
        expect(
          transport.operations.any((op) => op == 'subscribe:ef82'),
          isFalse,
          reason:
              'wakeDisplay should not redundantly subscribe if already active',
        );
      },
    );
  });

  group('Skale2Scale timer commands', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      scale = Skale2Scale(transport: transport, initStepDelay: Duration.zero);
      await transport.emitConnectionState(ConnectionState.discovered);
      await scale.onConnect();
      transport.operations.clear();
      addTearDown(scale.disconnect);
    });

    test('startTimer sends 0xDD', () async {
      await scale.startTimer();
      expect(transport.operations.any((op) => op.contains('0xDD')), isTrue);
    });

    test('stopTimer sends 0xD1', () async {
      await scale.stopTimer();
      expect(transport.operations.any((op) => op.contains('0xD1')), isTrue);
    });

    test('resetTimer sends 0xD0', () async {
      await scale.resetTimer();
      expect(transport.operations.any((op) => op.contains('0xD0')), isTrue);
    });
  });

  group('Skale2Scale weight notification parsing', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      scale = Skale2Scale(transport: transport, initStepDelay: Duration.zero);
      await transport.emitConnectionState(ConnectionState.discovered);
      await scale.onConnect();
      addTearDown(scale.disconnect);
    });

    test('parses weight notification correctly', () async {
      final completer = Completer<ScaleSnapshot>();

      final sub = scale.currentSnapshot.listen((snapshot) {
        if (!completer.isCompleted) completer.complete(snapshot);
      });

      transport.simulateWeightNotification([0x00, 0xE8, 0x03, 0x00]);

      final snapshot = await completer.future.timeout(
        const Duration(seconds: 1),
      );

      expect(snapshot.weight, closeTo(100.0, 0.1));

      await sub.cancel();
    });

    test('parses canonical signed mantissa and exponent', () async {
      final snapshots = <ScaleSnapshot>[];
      final sub = scale.currentSnapshot.listen(snapshots.add);

      transport.simulateWeightNotification([0, 0xE8, 0x03, 0, 0xFF]);
      transport.simulateWeightNotification([0, 0x18, 0xFC, 0xFF, 0xFF]);
      transport.simulateWeightNotification([0, 0x7B, 0, 0, 0xFE]);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.map((s) => s.weight), [100.0, -100.0, 1.23]);
      await sub.cancel();
    });

    test('ignores malformed weight notifications', () async {
      final snapshots = <ScaleSnapshot>[];
      final sub = scale.currentSnapshot.listen(snapshots.add);

      transport.simulateWeightNotification([0, 1, 2]);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots, isEmpty);
      await sub.cancel();
    });
  });

  group('Skale2Scale buttons and device information', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      scale = Skale2Scale(
        transport: transport,
        initStepDelay: Duration.zero,
        batteryRefreshInterval: const Duration(milliseconds: 20),
      );
      await transport.emitConnectionState(ConnectionState.discovered);
      addTearDown(scale.disconnect);
    });

    test('publishes firmware and device-reported battery', () async {
      transport.firmwareValue = Uint8List.fromList(' 2.5.0\u0000'.codeUnits);
      await scale.onConnect();

      expect(scale.currentDeviceInformation?.firmwareVersion, '2.5.0');
      expect(scale.currentDeviceInformation?.batteryLevel, 80);
    });

    test('keeps battery null when the read fails', () async {
      transport.batteryError = StateError('unsupported');
      await scale.onConnect();

      expect(scale.currentDeviceInformation?.firmwareVersion, '1.2.3');
      expect(scale.currentDeviceInformation?.batteryLevel, isNull);
      expect(scale.currentDeviceInformation?.powerSource, isNull);
    });

    test('refreshes battery while connected', () async {
      await scale.onConnect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(transport.batteryReadCount, greaterThanOrEqualTo(2));
    });

    test('maps button values and ignores unknown values', () async {
      await scale.onConnect();
      final buttons = <ScaleButton>[];
      final sub = scale.buttonPresses.listen(buttons.add);

      transport.simulateButtonNotification([]);
      transport.simulateButtonNotification([1]);
      transport.simulateButtonNotification([2]);
      transport.simulateButtonNotification([3]);
      await Future<void>.delayed(Duration.zero);

      expect(buttons, [ScaleButton.circle, ScaleButton.square]);
      await sub.cancel();
    });

    test('clears live device information on disconnect', () async {
      await scale.onConnect();
      await scale.disconnect();
      await Future<void>.delayed(Duration.zero);

      expect(scale.currentDeviceInformation, isNull);
    });
  });
}
