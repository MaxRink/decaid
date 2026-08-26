import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/grinder_capabilities.dart';
import 'package:reaprime/src/models/device/grinder_setting.dart';
import 'package:reaprime/src/models/device/grinder_snapshot.dart';
import 'package:reaprime/src/services/grinder/grind_assistant.dart';

GrinderSnapshot snapshot({DateTime? observedAt}) => GrinderSnapshot(
  deviceId: 'e64-sim',
  observedAt: observedAt ?? DateTime.utc(2026, 1, 1),
  firmwareBuild: 'V01.16-24-mock',
  connected: true,
  idle: true,
  motorRunning: false,
  currentSetting: const NumericGrinderSetting(
    domain: 'dd',
    value: 5000,
    unit: 'dum',
  ),
  revision: 'r1',
);

const metrics = ShotMetrics(
  doseGrams: 18,
  yieldGrams: 36,
  durationSeconds: 40,
  targetDurationSeconds: 30,
  targetYieldGrams: 36,
);

void main() {
  const assistant = GrindAssistant();
  final now = DateTime.utc(2026, 1, 1, 0, 0, 1);

  test('off records evidence but never recommends or automates', () {
    final result = assistant.recommend(
      policy: const GrindAssistantPolicy(mode: GrindAssistantMode.off),
      metrics: metrics,
      feedback: const {SensoryFeedback.tooAcidic},
      snapshot: snapshot(),
      capabilities: GrinderCapabilities.e64Ws,
      now: now,
    );
    expect(result.direction, GrindDirection.hold);
    expect(result.automationEligible, isFalse);
    expect(result.reasons, contains('policy:off'));
  });

  test('slow shot recommends coarser with a transparent reason', () {
    final result = assistant.recommend(
      policy: const GrindAssistantPolicy(),
      metrics: metrics,
      feedback: const {},
      snapshot: snapshot(),
      capabilities: GrinderCapabilities.e64Ws,
      now: now,
    );
    expect(result.direction, GrindDirection.coarser);
    expect(result.relativeSteps, 2);
    expect(result.reasons, contains('duration:slow'));
    expect(result.automationEligible, isFalse);
  });

  test('sensory acidity recommends finer when metrics are neutral', () {
    final result = assistant.recommend(
      policy: const GrindAssistantPolicy(),
      metrics: const ShotMetrics(
        doseGrams: 18,
        yieldGrams: 36,
        durationSeconds: 30,
        targetDurationSeconds: 30,
      ),
      feedback: const {SensoryFeedback.tooAcidic},
      snapshot: snapshot(),
      capabilities: GrinderCapabilities.manualDf64,
      now: now,
    );
    expect(result.direction, GrindDirection.finer);
    expect(result.instruction, contains('finer'));
  });

  test('conflicting metric and sensory votes hold safely', () {
    final result = assistant.recommend(
      policy: const GrindAssistantPolicy(),
      metrics: metrics,
      feedback: const {SensoryFeedback.tooAcidic},
      snapshot: snapshot(),
      capabilities: GrinderCapabilities.manualDf54,
      now: now,
    );
    expect(result.direction, GrindDirection.hold);
    expect(result.relativeSteps, 0);
  });

  test('E64 remains ineligible before physical capability validation', () {
    final result = assistant.recommend(
      policy: const GrindAssistantPolicy(mode: GrindAssistantMode.automate),
      metrics: const ShotMetrics(
        doseGrams: 18,
        yieldGrams: 36,
        durationSeconds: 20,
        targetDurationSeconds: 30,
      ),
      feedback: const {},
      snapshot: snapshot(),
      capabilities: GrinderCapabilities.e64Ws,
      now: now,
    );
    expect(result.direction, GrindDirection.finer);
    expect(result.automationEligible, isFalse);
    expect(
      result.toApprovedCommand(
        operationId: 'op-1',
        snapshot: snapshot(),
        capabilities: GrinderCapabilities.e64Ws,
        now: now,
        userApprovedAutomation: true,
      ),
      isNull,
    );
  });

  test('validated relative adapter still requires explicit approval', () {
    const capabilities = GrinderCapabilities(
      adjustment: GrinderAdjustmentMode.relative,
      readsCurrentSetting: true,
      safety: GrinderSafetyConstraints(requiresReadback: true),
    );
    final result = assistant.recommend(
      policy: const GrindAssistantPolicy(mode: GrindAssistantMode.automate),
      metrics: const ShotMetrics(
        doseGrams: 18,
        yieldGrams: 36,
        durationSeconds: 20,
        targetDurationSeconds: 30,
      ),
      feedback: const {},
      snapshot: snapshot(),
      capabilities: capabilities,
      now: now,
    );
    expect(result.automationEligible, isTrue);
    expect(
      result.toApprovedCommand(
        operationId: 'op-2',
        snapshot: snapshot(),
        capabilities: capabilities,
        now: now,
        userApprovedAutomation: false,
      ),
      isNull,
    );
    final command = result.toApprovedCommand(
      operationId: 'op-3',
      snapshot: snapshot(),
      capabilities: capabilities,
      now: now,
      userApprovedAutomation: true,
    );
    expect(command?.relativeDelta, -2);
    expect(command?.confirmed, isTrue);
  });

  test('stale or busy snapshots cannot produce an approved command', () {
    const capabilities = GrinderCapabilities(
      adjustment: GrinderAdjustmentMode.relative,
      safety: GrinderSafetyConstraints(requiresReadback: true),
    );
    final result = assistant.recommend(
      policy: const GrindAssistantPolicy(mode: GrindAssistantMode.automate),
      metrics: metrics,
      feedback: const {},
      snapshot: snapshot(observedAt: DateTime.utc(2025, 1, 1)),
      capabilities: capabilities,
      now: now,
    );
    expect(result.automationEligible, isFalse);
  });
}
