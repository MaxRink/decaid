import 'grinder_scale_binding.dart';

/// Normalized evidence consumed by a grinder assistant.
///
/// Every field is optional because a Decent shot can provide a flow curve
/// without a mass source, while a bound external or Decent-attached scale can
/// provide dose/yield.  A missing field is represented explicitly rather than
/// being replaced with zero, so a flow-only workflow cannot accidentally be
/// treated as a valid scale event.
class GrindEvidence {
  final String shotId;
  final DateTime observedAt;
  final double? doseGrams;
  final double? yieldGrams;
  final double? durationSeconds;
  final double? targetDurationSeconds;
  final double? targetYieldGrams;
  final List<FlowPoint> flowCurve;
  final GrinderScaleBinding? massSource;
  final Set<String> sensoryFeedback;
  final Map<String, dynamic> machineTelemetry;

  const GrindEvidence({
    required this.shotId,
    required this.observedAt,
    this.doseGrams,
    this.yieldGrams,
    this.durationSeconds,
    this.targetDurationSeconds,
    this.targetYieldGrams,
    this.flowCurve = const [],
    this.massSource,
    this.sensoryFeedback = const {},
    this.machineTelemetry = const {},
  });

  factory GrindEvidence.fromJson(Map<String, dynamic> json) {
    final shotId = json['shotId'];
    final observedAt = json['observedAt'];
    if (shotId is! String || shotId.trim().isEmpty ||
        observedAt is! String) {
      throw const FormatException('Invalid grind evidence identity');
    }
    final flowValue = json['flowCurve'];
    final points = <FlowPoint>[];
    if (flowValue != null) {
      if (flowValue is! List) {
        throw const FormatException('flowCurve must be a list');
      }
      for (final raw in flowValue) {
        if (raw is! Map) {
          throw const FormatException('flowCurve point must be an object');
        }
        points.add(
          FlowPoint.fromJson(
            raw.map((key, value) => MapEntry(key.toString(), value)),
          ),
        );
      }
      for (var index = 1; index < points.length; index++) {
        if (points[index].elapsedSeconds < points[index - 1].elapsedSeconds) {
          throw const FormatException('flowCurve timestamps must be monotonic');
        }
      }
    }
    final sensoryValue = json['sensoryFeedback'];
    final sensory = <String>{};
    if (sensoryValue != null) {
      if (sensoryValue is! List || sensoryValue.any((value) => value is! String)) {
        throw const FormatException('sensoryFeedback must be a string list');
      }
      sensory.addAll(sensoryValue.cast<String>().where((value) => value.isNotEmpty));
    }
    final massSourceValue = json['massSource'];
    final massSource = massSourceValue == null
        ? null
        : massSourceValue is Map
        ? GrinderScaleBinding.fromJson(
            massSourceValue.map((key, value) => MapEntry(key.toString(), value)),
          )
        : throw const FormatException('massSource must be an object');
    final telemetryValue = json['machineTelemetry'];
    final telemetry = telemetryValue == null
        ? <String, dynamic>{}
        : telemetryValue is Map
        ? telemetryValue.map((key, value) => MapEntry(key.toString(), value))
        : throw const FormatException('machineTelemetry must be an object');
    return GrindEvidence(
      shotId: shotId,
      observedAt: DateTime.parse(observedAt),
      doseGrams: _optionalNonNegative(json['doseGrams'], 'doseGrams'),
      yieldGrams: _optionalNonNegative(json['yieldGrams'], 'yieldGrams'),
      durationSeconds: _optionalPositive(json['durationSeconds'], 'durationSeconds'),
      targetDurationSeconds: _optionalPositive(
        json['targetDurationSeconds'],
        'targetDurationSeconds',
      ),
      targetYieldGrams: _optionalNonNegative(
        json['targetYieldGrams'],
        'targetYieldGrams',
      ),
      flowCurve: List.unmodifiable(points),
      massSource: massSource,
      sensoryFeedback: Set.unmodifiable(sensory),
      machineTelemetry: Map.unmodifiable(telemetry),
    );
  }

  bool get hasMass => doseGrams != null && yieldGrams != null;
  bool get hasFlow => flowCurve.isNotEmpty;
  bool get isFlowOnly => !hasMass && hasFlow;

  Map<String, dynamic> toJson() => {
    'shotId': shotId,
    'observedAt': observedAt.toIso8601String(),
    if (doseGrams != null) 'doseGrams': doseGrams,
    if (yieldGrams != null) 'yieldGrams': yieldGrams,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
    if (targetDurationSeconds != null)
      'targetDurationSeconds': targetDurationSeconds,
    if (targetYieldGrams != null) 'targetYieldGrams': targetYieldGrams,
    if (flowCurve.isNotEmpty)
      'flowCurve': flowCurve.map((point) => point.toJson()).toList(),
    if (massSource != null) 'massSource': massSource!.toJson(),
    if (sensoryFeedback.isNotEmpty)
      'sensoryFeedback': sensoryFeedback.toList()..sort(),
    if (machineTelemetry.isNotEmpty) 'machineTelemetry': machineTelemetry,
  };
}

class FlowPoint {
  final double elapsedSeconds;
  final double flowMlPerSecond;

  const FlowPoint({
    required this.elapsedSeconds,
    required this.flowMlPerSecond,
  });

  factory FlowPoint.fromJson(Map<String, dynamic> json) {
    final elapsed = json['elapsedSeconds'];
    final flow = json['flowMlPerSecond'];
    if (elapsed is! num || !elapsed.isFinite || elapsed < 0 ||
        flow is! num || !flow.isFinite || flow < 0) {
      throw const FormatException('Invalid flow point');
    }
    return FlowPoint(
      elapsedSeconds: elapsed.toDouble(),
      flowMlPerSecond: flow.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'elapsedSeconds': elapsedSeconds,
    'flowMlPerSecond': flowMlPerSecond,
  };
}

double? _optionalNonNegative(Object? value, String field) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < 0) {
    throw FormatException('$field must be a finite non-negative number');
  }
  return value.toDouble();
}

double? _optionalPositive(Object? value, String field) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value <= 0) {
    throw FormatException('$field must be a finite positive number');
  }
  return value.toDouble();
}
