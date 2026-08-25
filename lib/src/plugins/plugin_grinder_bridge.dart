import 'package:reaprime/src/plugins/plugin_manifest.dart';

/// Exact operations exposed by the host bridge.  The JavaScript string is
/// parsed into this closed set before a permission or transport is selected.
enum PluginGrinderOperation {
  driverState('driver_state', false),
  driverConfig('driver_config', false),
  gbsReport('gbs_report', false),
  action('action', true);

  final String wireName;
  final bool requiresActuation;

  const PluginGrinderOperation(this.wireName, this.requiresActuation);

  static PluginGrinderOperation? fromWire(Object? value) {
    if (value is! String) return null;
    for (final operation in values) {
      if (operation.wireName == value) return operation;
    }
    return null;
  }
}

/// Host-owned bridge for a local grinder capability.
///
/// Plugins submit named operations only.  Implementations must keep device
/// credentials out of logs and must enforce the manifest capability set again
/// at the host boundary; JavaScript-side checks are only a usability layer.
abstract interface class PluginGrinderBridge {
  Future<Map<String, dynamic>> request({
    required String pluginId,
    required PluginManifest manifest,
    required Map<String, dynamic> request,
  });
}
