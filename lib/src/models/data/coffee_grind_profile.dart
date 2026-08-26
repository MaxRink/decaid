import '../device/grinder_setting.dart';

/// A saved setting for one coffee scope on one grinder binding.
///
/// This is a domain contract first; persistence is deliberately separate so
/// legacy catalog `Grinder` records remain compatible.
class CoffeeGrindProfile {
  final String id;
  final String? beanId;
  final String? beanBatchId;
  final String? recipeId;
  final String grinderDeviceId;
  final GrinderSetting setting;
  final String algorithmVersion;
  final String? firmwareBuild;
  final int revision;
  final DateTime updatedAt;
  final Map<String, dynamic> extras;

  const CoffeeGrindProfile({
    required this.id,
    this.beanId,
    this.beanBatchId,
    this.recipeId,
    required this.grinderDeviceId,
    required this.setting,
    required this.algorithmVersion,
    this.firmwareBuild,
    this.revision = 0,
    required this.updatedAt,
    this.extras = const {},
  });

  factory CoffeeGrindProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final grinderDeviceId = json['grinderDeviceId'];
    final algorithmVersion = json['algorithmVersion'];
    final updatedAt = json['updatedAt'];
    final setting = json['setting'];
    final revision = json['revision'];
    if (id is! String || id.isEmpty ||
        grinderDeviceId is! String || grinderDeviceId.isEmpty ||
        algorithmVersion is! String || algorithmVersion.isEmpty ||
        updatedAt is! String || setting is! Map ||
        (revision != null &&
            (revision is! num || !revision.isFinite || revision < 0 ||
                revision != revision.truncateToDouble()))) {
      throw const FormatException('Invalid coffee grind profile');
    }
    return CoffeeGrindProfile(
      id: id,
      beanId: json['beanId'] as String?,
      beanBatchId: json['beanBatchId'] as String?,
      recipeId: json['recipeId'] as String?,
      grinderDeviceId: grinderDeviceId,
      setting: GrinderSetting.fromJson(
        setting.map((key, value) => MapEntry(key.toString(), value)),
      ),
      algorithmVersion: algorithmVersion,
      firmwareBuild: json['firmwareBuild'] as String?,
      revision: (revision as num?)?.toInt() ?? 0,
      updatedAt: DateTime.parse(updatedAt),
      extras: (json['extras'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value),
          ) ??
          const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    if (beanId != null) 'beanId': beanId,
    if (beanBatchId != null) 'beanBatchId': beanBatchId,
    if (recipeId != null) 'recipeId': recipeId,
    'grinderDeviceId': grinderDeviceId,
    'setting': setting.toJson(),
    'algorithmVersion': algorithmVersion,
    if (firmwareBuild != null) 'firmwareBuild': firmwareBuild,
    'revision': revision,
    'updatedAt': updatedAt.toIso8601String(),
    if (extras.isNotEmpty) 'extras': extras,
  };
}

class CoffeeSelection {
  final String? beanId;
  final String? beanBatchId;
  final String? recipeId;
  final String grinderDeviceId;

  const CoffeeSelection({
    this.beanId,
    this.beanBatchId,
    this.recipeId,
    required this.grinderDeviceId,
  });
}

class CoffeeGrindProfileResolver {
  const CoffeeGrindProfileResolver();

  CoffeeGrindProfile? resolve(
    Iterable<CoffeeGrindProfile> profiles,
    CoffeeSelection selection,
  ) {
    final candidates = profiles
        .where(
          (profile) => profile.grinderDeviceId == selection.grinderDeviceId,
        )
        .where((profile) => _matches(profile, selection))
        .toList();
    candidates.sort((a, b) {
      final specificity = _specificity(b).compareTo(_specificity(a));
      if (specificity != 0) return specificity;
      final updated = b.updatedAt.compareTo(a.updatedAt);
      if (updated != 0) return updated;
      final revision = b.revision.compareTo(a.revision);
      if (revision != 0) return revision;
      return a.id.compareTo(b.id);
    });
    return candidates.isEmpty ? null : candidates.first;
  }

  bool _matches(CoffeeGrindProfile profile, CoffeeSelection selection) {
    if (profile.beanBatchId != null &&
        profile.beanBatchId != selection.beanBatchId) {
      return false;
    }
    if (profile.beanId != null && profile.beanId != selection.beanId) {
      return false;
    }
    if (profile.recipeId != null && profile.recipeId != selection.recipeId) {
      return false;
    }
    return true;
  }

  /// Explicit precedence keeps a batch+recipe profile ahead of a merely
  /// batch- or bean-specific profile.  The bit weights also make an exact
  /// batch+bean+recipe match win over every less-specific fallback.
  int _specificity(CoffeeGrindProfile profile) =>
      (profile.beanBatchId != null ? 8 : 0) +
      (profile.recipeId != null ? 4 : 0) +
      (profile.beanId != null ? 2 : 0) +
      1;
}
