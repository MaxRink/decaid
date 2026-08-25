import '../../models/device/grinder_operation.dart';
import '../../models/device/grinder_snapshot.dart';
import '../../models/data/coffee_grind_profile.dart';

/// Safe coffee-selection-to-grinder state machine.
enum GrindSwitchStatus {
  selected,
  waitingForIdle,
  awaitingConfirmation,
  applying,
  verified,
  mismatch,
  rejected,
  unknown,
}

class GrindSwitchPlan {
  final String id;
  final CoffeeSelection selection;
  final CoffeeGrindProfile? profile;
  final GrinderSnapshot? preparedSnapshot;
  final DateTime? preparedAt;
  final DateTime? confirmationExpiresAt;
  final GrindSwitchStatus status;
  final String? reason;

  const GrindSwitchPlan({
    required this.id,
    required this.selection,
    required this.profile,
    this.preparedSnapshot,
    this.preparedAt,
    this.confirmationExpiresAt,
    this.status = GrindSwitchStatus.selected,
    this.reason,
  });

  bool get canApply =>
      profile != null &&
      status == GrindSwitchStatus.awaitingConfirmation &&
      preparedSnapshot != null;

  bool canApplyAt(DateTime now) =>
      canApply &&
      preparedAt != null &&
      confirmationExpiresAt != null &&
      !now.isBefore(preparedAt!) &&
      now.isBefore(confirmationExpiresAt!);

  GrindSwitchPlan copyWith({
    GrinderSnapshot? preparedSnapshot,
    GrindSwitchStatus? status,
    String? reason,
  }) => GrindSwitchPlan(
    id: id,
    selection: selection,
    profile: profile,
    preparedSnapshot: preparedSnapshot ?? this.preparedSnapshot,
    preparedAt: preparedAt,
    confirmationExpiresAt: confirmationExpiresAt,
    status: status ?? this.status,
    reason: reason ?? this.reason,
  );

  GrinderCommand toApplyCommand({
    required bool confirmed,
    required DateTime now,
  }) {
    if (!canApply) {
      throw StateError('grind switch is not prepared for application');
    }
    if (!canApplyAt(now)) {
      throw StateError('grind switch confirmation has expired');
    }
    if (!confirmed) {
      throw StateError('grind switch requires explicit confirmation');
    }
    final selected = profile;
    if (selected == null) throw StateError('no saved profile for selection');
    return GrinderCommand(
      operation: GrinderOperationId.applyAbsolute,
      operationId: id,
      setting: selected.setting,
      expectedRevision: preparedSnapshot!.revision,
      confirmed: confirmed,
      reason:
          'coffee-profile:${selection.beanBatchId ?? selection.beanId ?? 'default'}',
      evidence: {
        'profileId': selected.id,
        'profileRevision': selected.revision,
        'preparedAt': preparedAt!.toIso8601String(),
      },
    );
  }
}

class GrindSwitchPlanner {
  final Duration confirmationLifetime;

  const GrindSwitchPlanner({
    this.confirmationLifetime = const Duration(seconds: 30),
  });

  GrindSwitchPlan prepare({
    required String id,
    required CoffeeSelection selection,
    required CoffeeGrindProfile? profile,
    required GrinderSnapshot snapshot,
    required DateTime now,
    required Duration maxSnapshotAge,
  }) {
    if (profile == null) {
      return GrindSwitchPlan(
        id: id,
        selection: selection,
        profile: profile,
        status: GrindSwitchStatus.rejected,
        reason: 'no profile resolved',
      );
    }
    if (!snapshot.connected) {
      return GrindSwitchPlan(
        id: id,
        selection: selection,
        profile: profile,
        status: GrindSwitchStatus.unknown,
        reason: 'grinder disconnected',
      );
    }
    if (!snapshot.idle || snapshot.motorRunning) {
      return GrindSwitchPlan(
        id: id,
        selection: selection,
        profile: profile,
        status: GrindSwitchStatus.waitingForIdle,
        reason: 'grinder is busy',
      );
    }
    if (!snapshot.isFresh(now, maxSnapshotAge)) {
      return GrindSwitchPlan(
        id: id,
        selection: selection,
        profile: profile,
        status: GrindSwitchStatus.unknown,
        reason: 'snapshot is stale',
      );
    }
    return GrindSwitchPlan(
      id: id,
      selection: selection,
      profile: profile,
      preparedSnapshot: snapshot,
      preparedAt: now,
      confirmationExpiresAt: now.add(confirmationLifetime),
      status: GrindSwitchStatus.awaitingConfirmation,
    );
  }
}
