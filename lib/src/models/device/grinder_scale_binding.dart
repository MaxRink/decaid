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
