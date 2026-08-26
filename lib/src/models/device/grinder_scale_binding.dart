/// Ownership of a mass sensor used by a grinder workflow.
enum GrinderScaleOwner { grinder, external, decentMachine, openScale, unknown }

/// What physical phase a mass reading describes. Flow is intentionally absent:
/// a flow signal is not a mass measurement.
enum GrinderMassPhase {
  preGrindBeans,
  dispensingOutput,
  postGrindOutput,
  shotOutput,
  unknown,
}

/// Negotiated scale capability; a binding can point at the scale already
/// attached to the Decent machine without making that scale a grinder device.
class GrinderScaleBinding {
  final String sourceId;
  final GrinderScaleOwner owner;
  final GrinderMassPhase phase;
  final bool readsMass;
  final bool stableReadingRequired;
  final bool calibrationRequired;
  final double? resolutionGrams;

  const GrinderScaleBinding({
    required this.sourceId,
    required this.owner,
    required this.phase,
    this.readsMass = true,
    this.stableReadingRequired = true,
    this.calibrationRequired = true,
    this.resolutionGrams,
  });

  factory GrinderScaleBinding.fromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId'];
    final owner = _enumValue(GrinderScaleOwner.values, json['owner']);
    final phase = _enumValue(GrinderMassPhase.values, json['phase']);
    final resolution = json['resolutionGrams'];
    if (sourceId is! String || sourceId.trim().isEmpty ||
        owner == null || phase == null ||
        json['readsMass'] is! bool ||
        json['stableReadingRequired'] is! bool ||
        json['calibrationRequired'] is! bool ||
        (resolution != null &&
            (resolution is! num || !resolution.isFinite || resolution <= 0))) {
      throw const FormatException('Invalid grinder scale binding');
    }
    return GrinderScaleBinding(
      sourceId: sourceId,
      owner: owner,
      phase: phase,
      readsMass: json['readsMass'] as bool,
      stableReadingRequired: json['stableReadingRequired'] as bool,
      calibrationRequired: json['calibrationRequired'] as bool,
      resolutionGrams: (resolution as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'owner': owner.name,
    'phase': phase.name,
    'readsMass': readsMass,
    'stableReadingRequired': stableReadingRequired,
    'calibrationRequired': calibrationRequired,
    if (resolutionGrams != null) 'resolutionGrams': resolutionGrams,
  };
}

T? _enumValue<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return null;
}
