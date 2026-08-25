import 'grinder_setting.dart';

class GrinderSnapshot {
  final String deviceId;
  final DateTime observedAt;
  final String? firmwareBuild;
  final bool connected;
  final bool idle;
  final bool motorRunning;
  final GrinderSetting? currentSetting;
  final String? fault;
  final String? revision;
  final Map<String, dynamic> raw;

  const GrinderSnapshot({
    required this.deviceId,
    required this.observedAt,
    this.firmwareBuild,
    required this.connected,
    required this.idle,
    required this.motorRunning,
    this.currentSetting,
    this.fault,
    this.revision,
    this.raw = const {},
  });

  bool isFresh(DateTime now, Duration maxAge) {
    final age = now.difference(observedAt);
    return connected && age >= Duration.zero && age <= maxAge;
  }

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'observedAt': observedAt.toIso8601String(),
    if (firmwareBuild != null) 'firmwareBuild': firmwareBuild,
    'connected': connected,
    'idle': idle,
    'motorRunning': motorRunning,
    if (currentSetting != null) 'currentSetting': currentSetting!.toJson(),
    if (fault != null) 'fault': fault,
    if (revision != null) 'revision': revision,
    'raw': raw,
  };
}
