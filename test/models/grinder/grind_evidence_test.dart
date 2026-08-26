import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/coffee_grind_profile.dart';
import 'package:reaprime/src/models/device/grind_evidence.dart';
import 'package:reaprime/src/models/device/grinder_scale_binding.dart';
import 'package:reaprime/src/models/device/grinder_setting.dart';

Map<String, dynamic> evidenceJson() => {
  'shotId': 'shot-1',
  'observedAt': '2026-01-01T00:00:00Z',
  'doseGrams': 18.0,
  'yieldGrams': 36.0,
  'durationSeconds': 30.0,
  'targetDurationSeconds': 30.0,
  'flowCurve': [
    {'elapsedSeconds': 0.0, 'flowMlPerSecond': 0.0},
    {'elapsedSeconds': 10.0, 'flowMlPerSecond': 1.5},
  ],
  'massSource': const GrinderScaleBinding(
    sourceId: 'decent-scale',
    owner: GrinderScaleOwner.decentMachine,
    phase: GrinderMassPhase.shotOutput,
  ).toJson(),
  'sensoryFeedback': ['tooAcidic'],
};

void main() {
  test('evidence parser round trips mass, flow, and scale binding', () {
    final evidence = GrindEvidence.fromJson(evidenceJson());
    expect(evidence.hasMass, isTrue);
    expect(evidence.hasFlow, isTrue);
    expect(evidence.isFlowOnly, isFalse);
    expect(evidence.massSource?.owner, GrinderScaleOwner.decentMachine);
    expect(GrindEvidence.fromJson(evidence.toJson()).toJson(), evidence.toJson());
  });

  test('flow-only evidence remains explicit', () {
    final json = evidenceJson()
      ..remove('doseGrams')
      ..remove('yieldGrams');
    final evidence = GrindEvidence.fromJson(json);
    expect(evidence.isFlowOnly, isTrue);
  });

  test('invalid numeric and non-monotonic flow input is rejected', () {
    expect(
      () => GrindEvidence.fromJson({...evidenceJson(), 'doseGrams': double.nan}),
      throwsFormatException,
    );
    expect(
      () => GrindEvidence.fromJson({
        ...evidenceJson(),
        'flowCurve': [
          {'elapsedSeconds': 2, 'flowMlPerSecond': 1},
          {'elapsedSeconds': 1, 'flowMlPerSecond': 1},
        ],
      }),
      throwsFormatException,
    );
  });

  test('profile resolver tie-breaks by update time, revision, then id', () {
    final setting = const NumericGrinderSetting(
      domain: 'e64.dd',
      value: 5000,
      unit: 'dum',
    );
    final older = CoffeeGrindProfile(
      id: 'a',
      grinderDeviceId: 'e64',
      setting: setting,
      algorithmVersion: 'gbs-1',
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    final newer = CoffeeGrindProfile(
      id: 'b',
      grinderDeviceId: 'e64',
      setting: setting,
      algorithmVersion: 'gbs-1',
      updatedAt: DateTime.utc(2026, 1, 2),
    );
    final selected = const CoffeeGrindProfileResolver().resolve(
      [older, newer],
      const CoffeeSelection(grinderDeviceId: 'e64'),
    );
    expect(selected?.id, 'b');
  });
}
