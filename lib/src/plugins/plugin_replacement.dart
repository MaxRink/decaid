import 'dart:async';

import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';

final class PluginReplacement {
  const PluginReplacement({
    required this.installed,
    required this.candidate,
    required this.addedPermissions,
    required this.codeChanged,
    required this.sourceChanged,
    required this.holdsSecureSettings,
  });

  final PluginManifest installed;
  final PluginManifest candidate;

  final List<String> addedPermissions;
  final bool codeChanged;
  final bool sourceChanged;
  final bool holdsSecureSettings;

  bool get handsOverSecureSettings =>
      holdsSecureSettings && (codeChanged || sourceChanged);

  bool get needsReview =>
      addedPermissions.isNotEmpty || handsOverSecureSettings;
}

final class PluginReplacementDecision {
  const PluginReplacementDecision({
    this.approvedPermissions = const {},
    this.keepSecureSettings = false,
  });

  static const unattended = PluginReplacementDecision();

  final Set<String> approvedPermissions;
  final bool keepSecureSettings;

  bool approvesPermissionsOf(PluginReplacement replacement) =>
      replacement.addedPermissions.every(approvedPermissions.contains);
}

typedef PluginReplacementApprover =
    FutureOr<PluginReplacementDecision?> Function(
      PluginReplacement replacement,
    );

class PluginReplacementApprovalRequiredException
    implements UserFacingException {
  PluginReplacementApprovalRequiredException(this.replacement);

  final PluginReplacement replacement;

  @override
  String get message {
    final id = replacement.candidate.id;
    final added = replacement.addedPermissions;
    if (added.isNotEmpty) {
      return 'Replacing $id adds permissions that need approval: '
          '${added.join(', ')}';
    }
    return 'Replacing $id hands its stored secure settings to new code and '
        'needs approval';
  }

  @override
  String toString() => message;
}

List<String> addedPluginPermissions(
  PluginManifest installed,
  PluginManifest candidate,
) =>
    candidate.permissions
        .difference(installed.permissions)
        .map((permission) => permission.wireName)
        .toList()
      ..sort();
