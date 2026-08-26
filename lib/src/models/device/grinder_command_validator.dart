import 'grinder_capabilities.dart';
import 'grinder_operation.dart';
import 'grinder_setting.dart';
import 'grinder_snapshot.dart';

/// Shared validation used by concrete device adapters immediately before I/O.
///
/// A recommendation is advisory data; this validator is the second, device
/// boundary gate. It rejects stale optimistic-concurrency revisions and
/// invalid numeric targets even when a plugin bypasses the assistant.
class GrinderCommandValidator {
  const GrinderCommandValidator();

  String? validate({
    required GrinderCommand command,
    required GrinderCapabilities capabilities,
    required GrinderSnapshot snapshot,
    required DateTime now,
  }) {
    if (!capabilities.allows(command.operation)) {
      return 'operation is not enabled by grinder capabilities';
    }
    if (!snapshot.connected) return 'grinder is disconnected';
    final isAdjustment = command.operation == GrinderOperationId.applyRelative ||
        command.operation == GrinderOperationId.applyAbsolute ||
        command.operation == GrinderOperationId.prepareApply;
    if (isAdjustment && capabilities.safety.requiresIdleForAdjustment &&
        (!snapshot.idle || snapshot.motorRunning)) {
      return 'grinder must be idle for adjustment';
    }
    if (isAdjustment &&
        !snapshot.isFresh(now, capabilities.safety.freshSnapshotAge)) {
      return 'grinder snapshot is stale';
    }
    if (command.expectedRevision != null &&
        command.expectedRevision != snapshot.revision) {
      return 'grinder revision changed';
    }
    if (command.operation == GrinderOperationId.applyRelative) {
      final delta = command.relativeDelta;
      if (delta == null || delta == 0) return 'relative adjustment is empty';
      final current = snapshot.currentSetting;
      if (current is! NumericGrinderSetting) {
        return 'relative adjustment needs a numeric current setting';
      }
      final target = capabilities.relativeTarget(current, delta);
      if (target == null) {
        return 'relative adjustment unit does not match grinder setting';
      }
      if (!capabilities.safety.accepts(target)) {
        return 'relative adjustment exceeds grinder safety bounds';
      }
    }
    if (command.operation == GrinderOperationId.applyAbsolute) {
      final setting = command.setting;
      if (setting == null) return 'absolute adjustment needs a setting';
      if (setting is NumericGrinderSetting &&
          !capabilities.safety.accepts(setting.value)) {
        return 'absolute setting exceeds grinder safety bounds';
      }
    }
    if (command.operation == GrinderOperationId.applyRelative ||
        command.operation == GrinderOperationId.applyAbsolute ||
        command.operation == GrinderOperationId.prepareApply) {
      if (!command.confirmed) return 'adjustment requires explicit confirmation';
    }
    return null;
  }
}
