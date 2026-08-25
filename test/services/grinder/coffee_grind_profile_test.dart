import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/coffee_grind_profile.dart';
import 'package:reaprime/src/models/device/grinder_operation.dart';
import 'package:reaprime/src/models/device/grinder_setting.dart';
import 'package:reaprime/src/models/device/grinder_snapshot.dart';
import 'package:reaprime/src/services/grinder/grind_switch_state.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);

  CoffeeGrindProfile profile({
    required String id,
    String? beanId,
    String? beanBatchId,
    String? recipeId,
    double setting = 5000,
  }) => CoffeeGrindProfile(
    id: id,
    beanId: beanId,
    beanBatchId: beanBatchId,
    recipeId: recipeId,
    grinderDeviceId: 'e64-1',
    setting: NumericGrinderSetting(
      domain: 'mahlkoenig.dd_dum',
      value: setting,
      unit: 'dum',
    ),
    algorithmVersion: 'gbs-v01.16-24',
    updatedAt: now,
  );

  test('resolver prefers batch and recipe specificity', () {
    final resolver = const CoffeeGrindProfileResolver();
    final result = resolver.resolve(
      [
        profile(id: 'default', setting: 4000),
        profile(id: 'bean', beanId: 'bean-1', setting: 4500),
        profile(
          id: 'batch-recipe',
          beanId: 'bean-1',
          beanBatchId: 'batch-1',
          recipeId: 'espresso',
          setting: 5100,
        ),
      ],
      const CoffeeSelection(
        beanId: 'bean-1',
        beanBatchId: 'batch-1',
        recipeId: 'espresso',
        grinderDeviceId: 'e64-1',
      ),
    );
    expect(result?.id, 'batch-recipe');
  });

  test('resolver gives batch+recipe precedence over batch+bean', () {
    final resolver = const CoffeeGrindProfileResolver();
    final result = resolver.resolve(
      [
        profile(
          id: 'batch-bean',
          beanId: 'bean-1',
          beanBatchId: 'batch-1',
          setting: 4700,
        ),
        profile(
          id: 'batch-recipe',
          beanBatchId: 'batch-1',
          recipeId: 'espresso',
          setting: 4900,
        ),
      ],
      const CoffeeSelection(
        beanId: 'bean-1',
        beanBatchId: 'batch-1',
        recipeId: 'espresso',
        grinderDeviceId: 'e64-1',
      ),
    );
    expect(result?.id, 'batch-recipe');
  });

  test('selection prepares confirmation but never actuates by itself', () {
    final profileValue = profile(id: 'batch', beanBatchId: 'batch-1');
    final selection = const CoffeeSelection(
      beanBatchId: 'batch-1',
      grinderDeviceId: 'e64-1',
    );
    final snapshot = GrinderSnapshot(
      deviceId: 'e64-1',
      observedAt: now,
      connected: true,
      idle: true,
      motorRunning: false,
      revision: '17',
    );
    final plan = const GrindSwitchPlanner().prepare(
      id: 'switch-1',
      selection: selection,
      profile: profileValue,
      snapshot: snapshot,
      now: now,
      maxSnapshotAge: const Duration(seconds: 5),
    );
    expect(plan.status, GrindSwitchStatus.awaitingConfirmation);
    expect(plan.canApply, isTrue);
    expect(
      () => plan.toApplyCommand(confirmed: false, now: now),
      throwsStateError,
    );
    expect(
      plan.toApplyCommand(confirmed: true, now: now).operation,
      GrinderOperationId.applyAbsolute,
    );
    expect(
      plan.toApplyCommand(confirmed: true, now: now).expectedRevision,
      '17',
    );
    expect(plan.canApplyAt(now), isTrue);
    expect(plan.canApplyAt(now.add(const Duration(seconds: 31))), isFalse);
  });

  test('busy grinder remains pending for next safe idle point', () {
    final plan = const GrindSwitchPlanner().prepare(
      id: 'switch-2',
      selection: const CoffeeSelection(grinderDeviceId: 'e64-1'),
      profile: profile(id: 'default'),
      snapshot: GrinderSnapshot(
        deviceId: 'e64-1',
        observedAt: now,
        connected: true,
        idle: false,
        motorRunning: true,
      ),
      now: now,
      maxSnapshotAge: const Duration(seconds: 5),
    );
    expect(plan.status, GrindSwitchStatus.waitingForIdle);
    expect(plan.canApply, isFalse);
  });
}
