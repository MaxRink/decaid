import '../../models/device/grinder_device.dart';
import '../../models/device/grinder_snapshot.dart';
import 'grinder_registry.dart';

/// Normalized native controller boundary for grinder observations.
/// It intentionally has no generic command method and cannot actuate devices.
abstract interface class GrinderController {
  Future<GrinderSnapshot> readSnapshot(String deviceId);
  Stream<GrinderSnapshot> snapshots(String deviceId);
}

class ReadOnlyGrinderController implements GrinderController {
  final GrinderRegistry registry;

  const ReadOnlyGrinderController(this.registry);

  @override
  Future<GrinderSnapshot> readSnapshot(String deviceId) =>
      _device(deviceId).readSnapshot();

  @override
  Stream<GrinderSnapshot> snapshots(String deviceId) =>
      _device(deviceId).snapshots;

  GrinderDevice _device(String deviceId) {
    final device = registry.find(deviceId);
    if (device == null) {
      throw StateError('grinder is not registered: $deviceId');
    }
    return device;
  }
}
