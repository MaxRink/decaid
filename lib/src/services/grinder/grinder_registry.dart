import 'dart:async';

import '../../models/device/grinder_device.dart';

/// Application-owned registry for normalized grinder devices.
/// Registration does not connect a device or grant write authority.
abstract interface class GrinderRegistry {
  List<GrinderDevice> get devices;
  Stream<List<GrinderDevice>> get deviceStream;
  GrinderDevice? find(String deviceId);
  void register(GrinderDevice device);
  bool unregister(String deviceId);
}

/// In-memory registry for native controllers and tests.
class InMemoryGrinderRegistry implements GrinderRegistry {
  final Map<String, GrinderDevice> _devices = {};
  final StreamController<List<GrinderDevice>> _changes =
      StreamController<List<GrinderDevice>>.broadcast();

  @override
  List<GrinderDevice> get devices => List.unmodifiable(_devices.values);

  @override
  Stream<List<GrinderDevice>> get deviceStream => _changes.stream;

  @override
  GrinderDevice? find(String deviceId) => _devices[deviceId];

  @override
  void register(GrinderDevice device) {
    if (device.deviceId.isEmpty) {
      throw ArgumentError.value(device.deviceId, 'deviceId');
    }
    if (_devices.containsKey(device.deviceId)) {
      throw StateError('grinder already registered: ${device.deviceId}');
    }
    _devices[device.deviceId] = device;
    _publish();
  }

  @override
  bool unregister(String deviceId) {
    final removed = _devices.remove(deviceId) != null;
    if (removed) _publish();
    return removed;
  }

  void dispose() {
    _changes.close();
    _devices.clear();
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(devices);
  }
}
