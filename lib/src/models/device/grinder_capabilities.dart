import 'grinder_operation.dart';
import 'grinder_scale_binding.dart';
import 'grinder_setting.dart';

/// Capability vocabulary shared by connected and guidance-only grinders.
///
/// A grinder must not be classified by one boolean such as "smart".  In
/// particular, a device can expose its current DD value while still being
/// unsafe to actuate until physical direction, bounds, and readback have been
/// validated for that firmware revision.
enum GrinderAdjustmentMode {
  none,
  manualGuidance,
  relative,
  absolute,
  calibrationOnly,
}

class GrinderSafetyConstraints {
  final double? minimumSetting;
  final double? maximumSetting;
  final Duration freshSnapshotAge;
  final bool requiresIdleForAdjustment;
  final bool requiresReadback;
  final bool supportsEmergencyStop;
  /// Maximum permitted difference between a commanded numeric setting and
  /// the subsequent device readback, in the setting's native unit.
  final double readbackTolerance;

  const GrinderSafetyConstraints({
    this.minimumSetting,
    this.maximumSetting,
    this.freshSnapshotAge = const Duration(seconds: 5),
    this.requiresIdleForAdjustment = true,
    this.requiresReadback = true,
    this.supportsEmergencyStop = false,
    this.readbackTolerance = 0,
  }) : assert(readbackTolerance >= 0);

  bool accepts(num value) {
    if (!value.isFinite) return false;
    if (minimumSetting != null && value < minimumSetting!) return false;
    if (maximumSetting != null && value > maximumSetting!) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {
    if (minimumSetting != null) 'minimumSetting': minimumSetting,
    if (maximumSetting != null) 'maximumSetting': maximumSetting,
    'freshSnapshotAgeMs': freshSnapshotAge.inMilliseconds,
    'requiresIdleForAdjustment': requiresIdleForAdjustment,
    'requiresReadback': requiresReadback,
    'supportsEmergencyStop': supportsEmergencyStop,
    'readbackTolerance': readbackTolerance,
  };
}

class GrinderCapabilities {
  /// Features observed in static protocol/binary evidence.  These are not
  /// automatically enabled host capabilities.
  final Set<String> observedProtocolFeatures;
  final bool readsCurrentSetting;
  final GrinderAdjustmentMode adjustment;
  final bool readsDose;
  final bool controlsDose;
  final bool readsRpm;
  final bool controlsRpm;
  final bool supportsGrindByWeight;
  final bool acceptsBrewEvidence;
  final bool exposesNativeGbsReport;
  final bool supportsStop;
  /// Number of native setting units represented by one assistant step.
  ///
  /// A relative command remains expressed in assistant steps at the generic
  /// boundary. Adapters convert it into their native dial unit using this
  /// value, instead of adding an untyped step count to a device reading.
  final double relativeStepSize;
  /// Optional native unit required by relative adjustments. A null unit means
  /// "the current numeric setting's unit" for generic adapters.
  final String? relativeStepUnit;
  final List<GrinderScaleBinding> scaleBindings;
  final GrinderSafetyConstraints safety;

  const GrinderCapabilities({
    this.observedProtocolFeatures = const {},
    this.readsCurrentSetting = false,
    this.adjustment = GrinderAdjustmentMode.none,
    this.readsDose = false,
    this.controlsDose = false,
    this.readsRpm = false,
    this.controlsRpm = false,
    this.supportsGrindByWeight = false,
    this.acceptsBrewEvidence = false,
    this.exposesNativeGbsReport = false,
    this.supportsStop = false,
    this.relativeStepSize = 1,
    this.relativeStepUnit,
    this.scaleBindings = const [],
    this.safety = const GrinderSafetyConstraints(),
  }) : assert(relativeStepSize > 0);

  /// Whether the host may expose an operation through this contract.
  /// Static protocol evidence never enables physical actuation by itself.
  bool allows(GrinderOperationId operation) {
    switch (operation) {
      case GrinderOperationId.readSnapshot:
      case GrinderOperationId.readConfig:
        return readsCurrentSetting;
      case GrinderOperationId.requestNativeGbsReport:
        return exposesNativeGbsReport;
      case GrinderOperationId.stop:
        return supportsStop;
      case GrinderOperationId.addBrewEvidence:
        return acceptsBrewEvidence;
      case GrinderOperationId.prepareApply:
        return adjustment == GrinderAdjustmentMode.absolute ||
            adjustment == GrinderAdjustmentMode.relative;
      case GrinderOperationId.applyAbsolute:
        return adjustment == GrinderAdjustmentMode.absolute;
      case GrinderOperationId.applyRelative:
        return adjustment == GrinderAdjustmentMode.relative;
    }
  }

  Map<String, dynamic> toJson() => {
    'observedProtocolFeatures': observedProtocolFeatures.toList()..sort(),
    'readsCurrentSetting': readsCurrentSetting,
    'adjustment': adjustment.name,
    'readsDose': readsDose,
    'controlsDose': controlsDose,
    'readsRpm': readsRpm,
    'controlsRpm': controlsRpm,
    'supportsGrindByWeight': supportsGrindByWeight,
    'acceptsBrewEvidence': acceptsBrewEvidence,
    'exposesNativeGbsReport': exposesNativeGbsReport,
    'supportsStop': supportsStop,
    'relativeStepSize': relativeStepSize,
    if (relativeStepUnit != null) 'relativeStepUnit': relativeStepUnit,
    'scaleBindings': scaleBindings.map((binding) => binding.toJson()).toList(),
    'safety': safety.toJson(),
  };

  /// Converts an assistant relative step count to the native numeric setting.
  /// Returns null when the setting is non-numeric or has the wrong unit.
  double? relativeTarget(GrinderSetting current, int delta) {
    if (current is! NumericGrinderSetting) return null;
    if (relativeStepUnit != null && current.unit != relativeStepUnit) {
      return null;
    }
    final target = current.value + delta * relativeStepSize;
    return target.isFinite ? target : null;
  }

  /// The static profile for an E64 WS before physical validation.
  ///
  /// `calibrationOnly` is intentional: static firmware evidence proves the
  /// DD/AGSA command exists, but does not prove which physical direction or
  /// safe range applies to a particular unit.
  static const e64Ws = GrinderCapabilities(
    observedProtocolFeatures: {
      'dd.read',
      'dd.target.action',
      'dose.read',
      'grind-by-weight.action',
      'grind-by-time.action',
      'gbs.report.action',
      'brew-event.action',
      'stop.action',
    },
    readsCurrentSetting: true,
    adjustment: GrinderAdjustmentMode.calibrationOnly,
    readsDose: true,
    // The binary contains these action names, but the host must not expose
    // them as enabled capabilities before physical/runtime validation.
    controlsDose: false,
    supportsGrindByWeight: false,
    acceptsBrewEvidence: false,
    exposesNativeGbsReport: true,
    supportsStop: false,
    // The firmware extraction does not establish the physical safe range.
    // Keep both limits unset until a matching unit is measured.
    safety: GrinderSafetyConstraints(),
  );

  /// DF54/DF64 are guidance-only until a separate physical adapter is built.
  static const manualDf54 = GrinderCapabilities(
    adjustment: GrinderAdjustmentMode.manualGuidance,
  );

  static const manualDf64 = GrinderCapabilities(
    adjustment: GrinderAdjustmentMode.manualGuidance,
  );
}
