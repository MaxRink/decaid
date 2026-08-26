import '../../models/device/grinder_capabilities.dart';
import '../../models/device/grinder_operation.dart';
import '../../models/device/grinder_snapshot.dart';

/// The user-selectable authority of the grind assistant.
enum GrindAssistantMode { off, recommend, automate }

enum GrindDirection { finer, coarser, hold }

/// Normalized sensory labels. These are Decaid policy inputs, not claims about
/// a Mahlkönig firmware rule table.
enum SensoryFeedback {
  tooBitter,
  tooAcidic,
  tooSour,
  weak,
  harsh,
  astringent,
  channeling,
}

class ShotMetrics {
  final double doseGrams;
  final double yieldGrams;
  final double durationSeconds;
  final double targetDurationSeconds;
  final double? targetYieldGrams;

  const ShotMetrics({
    required this.doseGrams,
    required this.yieldGrams,
    required this.durationSeconds,
    required this.targetDurationSeconds,
    this.targetYieldGrams,
  });

  double? get brewRatio => doseGrams > 0 ? yieldGrams / doseGrams : null;

  bool get isFiniteAndValid =>
      doseGrams.isFinite &&
      doseGrams > 0 &&
      yieldGrams.isFinite &&
      yieldGrams >= 0 &&
      durationSeconds.isFinite &&
      durationSeconds > 0 &&
      targetDurationSeconds.isFinite &&
      targetDurationSeconds > 0 &&
      (targetYieldGrams == null ||
          (targetYieldGrams!.isFinite && targetYieldGrams! >= 0));

  Map<String, dynamic> toJson() => {
    'doseGrams': doseGrams,
    'yieldGrams': yieldGrams,
    'durationSeconds': durationSeconds,
    'targetDurationSeconds': targetDurationSeconds,
    if (targetYieldGrams != null) 'targetYieldGrams': targetYieldGrams,
    if (brewRatio != null) 'brewRatio': brewRatio,
  };
}

class GrindAssistantPolicy {
  final GrindAssistantMode mode;
  final int maxRelativeSteps;
  final double durationToleranceFraction;
  final bool requireFreshSnapshot;
  final Duration maxSnapshotAge;

  const GrindAssistantPolicy({
    this.mode = GrindAssistantMode.recommend,
    this.maxRelativeSteps = 2,
    this.durationToleranceFraction = 0.15,
    this.requireFreshSnapshot = true,
    this.maxSnapshotAge = const Duration(seconds: 5),
  }) : assert(maxRelativeSteps > 0),
       assert(durationToleranceFraction >= 0 && durationToleranceFraction < 1);

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'maxRelativeSteps': maxRelativeSteps,
    'durationToleranceFraction': durationToleranceFraction,
    'requireFreshSnapshot': requireFreshSnapshot,
    'maxSnapshotAgeMs': maxSnapshotAge.inMilliseconds,
  };
}

class GrindAssistantRecommendation {
  final GrindAssistantMode mode;
  final GrindDirection direction;
  final int relativeSteps;
  final double confidence;
  final bool automationEligible;
  final String instruction;
  final List<String> reasons;
  final ShotMetrics metrics;
  final Set<SensoryFeedback> feedback;

  const GrindAssistantRecommendation({
    required this.mode,
    required this.direction,
    required this.relativeSteps,
    required this.confidence,
    required this.automationEligible,
    required this.instruction,
    required this.reasons,
    required this.metrics,
    required this.feedback,
  });

  bool get isActionable =>
      direction != GrindDirection.hold && relativeSteps > 0;

  /// Builds a host command only after the caller has explicitly approved the
  /// automate policy. A recommendation alone never actuates a grinder.
  GrinderCommand? toApprovedCommand({
    required String operationId,
    required GrinderSnapshot snapshot,
    required GrinderCapabilities capabilities,
    required DateTime now,
    required bool userApprovedAutomation,
  }) {
    if (!automationEligible || !userApprovedAutomation || !isActionable)
      return null;
    if (!snapshot.connected || !snapshot.idle || snapshot.motorRunning)
      return null;
    if (!snapshot.isFresh(now, capabilities.safety.freshSnapshotAge))
      return null;
    if (!capabilities.allows(GrinderOperationId.applyRelative)) return null;
    return GrinderCommand(
      operation: GrinderOperationId.applyRelative,
      operationId: operationId,
      relativeDelta: direction == GrindDirection.finer
          ? -relativeSteps
          : relativeSteps,
      expectedRevision: snapshot.revision,
      confirmed: true,
      reason: 'opt-in-grind-assistant',
      evidence: {
        'confidence': confidence,
        'metrics': metrics.toJson(),
        'sensoryFeedback': feedback.map((value) => value.name).toList()..sort(),
        'instruction': instruction,
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'direction': direction.name,
    'relativeSteps': relativeSteps,
    'confidence': confidence,
    'automationEligible': automationEligible,
    'instruction': instruction,
    'reasons': reasons,
    'metrics': metrics.toJson(),
    'sensoryFeedback': feedback.map((value) => value.name).toList()..sort(),
  };
}

/// Transparent, deterministic policy layer shared by connected and manual
/// grinder adapters.
class GrindAssistant {
  const GrindAssistant();

  GrindAssistantRecommendation recommend({
    required GrindAssistantPolicy policy,
    required ShotMetrics metrics,
    required Set<SensoryFeedback> feedback,
    required GrinderSnapshot snapshot,
    required GrinderCapabilities capabilities,
    required DateTime now,
  }) {
    if (policy.mode == GrindAssistantMode.off) {
      return _result(
        policy,
        metrics,
        feedback,
        GrindDirection.hold,
        0,
        0,
        false,
        'Grind assistant is disabled; feedback was recorded only.',
        const ['policy:off'],
      );
    }
    if (!metrics.isFiniteAndValid) {
      return _result(
        policy,
        metrics,
        feedback,
        GrindDirection.hold,
        0,
        0,
        false,
        'Insufficient shot metrics; no grind change is recommended.',
        const ['metrics:invalid'],
      );
    }

    final votes = <GrindDirection>[];
    final reasons = <String>[];
    final tolerance =
        metrics.targetDurationSeconds * policy.durationToleranceFraction;
    final durationDelta =
        metrics.durationSeconds - metrics.targetDurationSeconds;
    if (durationDelta > tolerance) {
      votes.add(GrindDirection.coarser);
      reasons.add('duration:slow');
    } else if (durationDelta < -tolerance) {
      votes.add(GrindDirection.finer);
      reasons.add('duration:fast');
    } else {
      reasons.add('duration:within-target');
    }

    for (final signal in feedback) {
      switch (signal) {
        case SensoryFeedback.tooBitter:
        case SensoryFeedback.harsh:
        case SensoryFeedback.astringent:
          votes.add(GrindDirection.coarser);
          reasons.add('sensory:${signal.name}:coarser');
        case SensoryFeedback.tooAcidic:
        case SensoryFeedback.tooSour:
        case SensoryFeedback.weak:
          votes.add(GrindDirection.finer);
          reasons.add('sensory:${signal.name}:finer');
        case SensoryFeedback.channeling:
          // Channeling is not a reliable one-dimensional grind signal; keep
          // it as evidence without automatically moving the burrs.
          reasons.add('sensory:channeling:manual-diagnosis');
      }
    }

    if (metrics.targetYieldGrams != null) {
      final yieldDelta = metrics.yieldGrams - metrics.targetYieldGrams!;
      final yieldTolerance = metrics.targetYieldGrams! * 0.05;
      reasons.add(
        yieldDelta.abs() <= yieldTolerance
            ? 'yield:within-target'
            : yieldDelta > 0
            ? 'yield:above-target'
            : 'yield:below-target',
      );
    }

    final finerVotes = votes
        .where((vote) => vote == GrindDirection.finer)
        .length;
    final coarserVotes = votes
        .where((vote) => vote == GrindDirection.coarser)
        .length;
    final direction = finerVotes == coarserVotes
        ? GrindDirection.hold
        : finerVotes > coarserVotes
        ? GrindDirection.finer
        : GrindDirection.coarser;
    final voteCount = finerVotes + coarserVotes;
    final winningVotes = direction == GrindDirection.finer
        ? finerVotes
        : coarserVotes;
    final confidence = voteCount == 0 ? 0.0 : winningVotes / voteCount;
    final int steps = direction == GrindDirection.hold
        ? 0
        : (durationDelta.abs() > tolerance * 2 ? 2 : 1).clamp(
                1,
                policy.maxRelativeSteps,
              )
              as int;
    final canAutomate =
        policy.mode == GrindAssistantMode.automate &&
        direction != GrindDirection.hold &&
        capabilities.adjustment == GrinderAdjustmentMode.relative &&
        capabilities.safety.requiresReadback &&
        snapshot.connected &&
        snapshot.idle &&
        !snapshot.motorRunning &&
        (!policy.requireFreshSnapshot ||
            snapshot.isFresh(now, policy.maxSnapshotAge));
    final displayDirection = direction == GrindDirection.finer
        ? 'finer'
        : direction == GrindDirection.coarser
        ? 'coarser'
        : 'no change';
    final instruction = direction == GrindDirection.hold
        ? 'Keep the current grind setting; collect another shot or resolve conflicting signals.'
        : 'Move the grind setting $displayDirection by $steps marked step${steps == 1 ? '' : 's'}.';
    return _result(
      policy,
      metrics,
      feedback,
      direction,
      steps,
      confidence,
      canAutomate,
      instruction,
      reasons,
    );
  }

  GrindAssistantRecommendation _result(
    GrindAssistantPolicy policy,
    ShotMetrics metrics,
    Set<SensoryFeedback> feedback,
    GrindDirection direction,
    int steps,
    double confidence,
    bool automationEligible,
    String instruction,
    List<String> reasons,
  ) => GrindAssistantRecommendation(
    mode: policy.mode,
    direction: direction,
    relativeSteps: steps,
    confidence: confidence,
    automationEligible: automationEligible,
    instruction: instruction,
    reasons: List.unmodifiable(reasons),
    metrics: metrics,
    feedback: Set.unmodifiable(feedback),
  );
}
