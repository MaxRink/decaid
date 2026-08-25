import 'grinder_setting.dart';
import 'grinder_snapshot.dart';

/// Stable host operation identifiers.  Plugins use these names rather than
/// raw E64 action suffixes or arbitrary JSON dispatch.
enum GrinderOperationId {
  readSnapshot('grinder.snapshot.read'),
  readConfig('grinder.config.read'),
  requestNativeGbsReport('grinder.gbs.report'),
  prepareApply('grinder.apply.prepare'),
  applyAbsolute('grinder.apply.absolute'),
  applyRelative('grinder.apply.relative'),
  stop('grinder.stop'),
  addBrewEvidence('grinder.brewEvidence.add');

  final String wireName;
  const GrinderOperationId(this.wireName);
}

class GrinderCommand {
  final GrinderOperationId operation;
  final GrinderSetting? setting;
  final int? relativeDelta;
  final String operationId;
  final String? expectedRevision;
  final bool confirmed;
  final String reason;
  final Map<String, dynamic> evidence;

  const GrinderCommand({
    required this.operation,
    required this.operationId,
    this.setting,
    this.relativeDelta,
    this.expectedRevision,
    this.confirmed = false,
    this.reason = '',
    this.evidence = const {},
  });

  Map<String, dynamic> toJson() => {
    'operation': operation.wireName,
    'operationId': operationId,
    if (setting != null) 'setting': setting!.toJson(),
    if (relativeDelta != null) 'relativeDelta': relativeDelta,
    if (expectedRevision != null) 'expectedRevision': expectedRevision,
    'confirmed': confirmed,
    if (reason.isNotEmpty) 'reason': reason,
    if (evidence.isNotEmpty) 'evidence': evidence,
  };
}

enum GrinderOperationStatus {
  prepared,
  awaitingConfirmation,
  pending,
  verified,
  rejected,
  mismatch,
  timeout,
  disconnected,
  unknown,
}

class GrinderOperationResult {
  final String operationId;
  final GrinderOperationStatus status;
  final String? message;
  final GrinderSnapshot? snapshot;
  final Map<String, dynamic> audit;

  const GrinderOperationResult({
    required this.operationId,
    required this.status,
    this.message,
    this.snapshot,
    this.audit = const {},
  });

  bool get isVerified => status == GrinderOperationStatus.verified;

  Map<String, dynamic> toJson() => {
    'operationId': operationId,
    'status': status.name,
    if (message != null) 'message': message,
    if (snapshot != null) 'snapshot': snapshot!.toJson(),
    'audit': audit,
  };
}
